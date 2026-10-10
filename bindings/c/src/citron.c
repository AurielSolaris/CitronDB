/*
 * CitronDB 🍋 — native implementation of the .citron format (version 2).
 * Mirrors src/citron.perl and src/filesystem.perl; see include/citron.h.
 */
#define CITRON_BUILD
#include "citron.h"

#include <errno.h>
#include <float.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#  include <windows.h>
#  include <io.h>
#else
#  include <fcntl.h>
#  include <sys/file.h>
#  include <unistd.h>
#endif

#define MAGIC "CITRON"
#define MAGIC_LEN 6
#define FORMAT_VERSION 2
#define HEADER_SIZE (MAGIC_LEN + 8)
#define MAX_DEPTH 512
#define DEFAULT_FILE "mainuser.citron"

struct citron {
    char *path;
    char *tmp_path;
    char *lock_path;
    char err[512];
};

static int fail(citron *db, int code, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(db->err, sizeof db->err, fmt, ap);
    va_end(ap);
    return code;
}

static int fail_nomem(citron *db)
{
    return fail(db, CITRON_ENOMEM, "Out of memory");
}

static char *dup_bytes(const char *s, size_t n)
{
    char *p = malloc(n + 1);
    if (p) {
        memcpy(p, s, n);
        p[n] = '\0';
    }
    return p;
}

/* --- growable buffer ---------------------------------------------------- */

typedef struct {
    char *p;
    size_t len, cap;
    int oom;
} buf;

static void buf_put(buf *b, const void *s, size_t n)
{
    if (b->oom)
        return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 64;
        while (cap < b->len + n + 1)
            cap *= 2;
        char *p = realloc(b->p, cap);
        if (!p) {
            b->oom = 1;
            return;
        }
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = '\0';
}

static void buf_putc(buf *b, char c)
{
    buf_put(b, &c, 1);
}

static void buf_u32(buf *b, uint32_t v)
{
    unsigned char be[4] = { v >> 24, v >> 16, v >> 8, v };
    buf_put(b, be, 4);
}

/* --- UTF-8 -------------------------------------------------------------- */

/*
 * Length of the UTF-8 sequence at p, or 0 if invalid, using Perl's lax rules
 * (utf8::decode): surrogates and code points above U+10FFFF are accepted,
 * overlong forms are not. max_len caps the sequence length: JSON::PP only
 * looks at 4 bytes per character inside JSON strings, while plain strings go
 * through utf8::decode whole.
 */
#define UTF8_JSON_MAX 4
#define UTF8_PLAIN_MAX 6

static size_t utf8_len(const unsigned char *p, const unsigned char *end, size_t max_len)
{
    static const unsigned long min_cp[] = { 0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000 };
    unsigned c = p[0];
    unsigned long cp;
    size_t n, i;

    if (c < 0x80)
        return 1;
    if (c >= 0xC2 && c <= 0xDF) {
        n = 2; cp = c & 0x1F;
    } else if (c >= 0xE0 && c <= 0xEF) {
        n = 3; cp = c & 0x0F;
    } else if (c >= 0xF0 && c <= 0xF7) {
        n = 4; cp = c & 0x07;
    } else if (c >= 0xF8 && c <= 0xFB) {
        n = 5; cp = c & 0x03;
    } else if (c >= 0xFC && c <= 0xFD) {
        n = 6; cp = c & 0x01;
    } else {
        return 0;
    }
    if (n > max_len || (size_t)(end - p) < n)
        return 0;
    for (i = 1; i < n; i++) {
        if ((p[i] & 0xC0) != 0x80)
            return 0;
        cp = (cp << 6) | (p[i] & 0x3F);
    }
    return cp < min_cp[n] ? 0 : n;
}

static int utf8_valid(const char *s, size_t n)
{
    const unsigned char *p = (const unsigned char *)s, *end = p + n;
    while (p < end) {
        size_t len = utf8_len(p, end, UTF8_PLAIN_MAX);
        if (!len)
            return 0;
        p += len;
    }
    return 1;
}

static void put_codepoint(buf *b, unsigned cp)
{
    char u[4];
    if (cp < 0x80) {
        u[0] = (char)cp;
        buf_put(b, u, 1);
    } else if (cp < 0x800) {
        u[0] = (char)(0xC0 | cp >> 6);
        u[1] = (char)(0x80 | (cp & 0x3F));
        buf_put(b, u, 2);
    } else if (cp < 0x10000) {
        u[0] = (char)(0xE0 | cp >> 12);
        u[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        u[2] = (char)(0x80 | (cp & 0x3F));
        buf_put(b, u, 3);
    } else {
        u[0] = (char)(0xF0 | cp >> 18);
        u[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        u[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        u[3] = (char)(0x80 | (cp & 0x3F));
        buf_put(b, u, 4);
    }
}

/* Text as UTF-8: kept if already valid, otherwise read as Latin-1 (what
 * Perl does with bytes that utf8::decode rejects). */
static void put_text_utf8(buf *b, const char *s, size_t n)
{
    size_t i;
    if (utf8_valid(s, n)) {
        buf_put(b, s, n);
        return;
    }
    for (i = 0; i < n; i++)
        put_codepoint(b, (unsigned char)s[i]);
}

static void put_latin1(buf *b, const char *s, size_t n)
{
    size_t i;
    for (i = 0; i < n; i++)
        put_codepoint(b, (unsigned char)s[i]);
}

/* --- JSON --------------------------------------------------------------- */

enum { J_NULL, J_FALSE, J_TRUE, J_NUM, J_STR, J_ARR, J_OBJ };

typedef struct jval jval;
typedef struct jmem jmem;

struct jval {
    int type;
    char *s;   /* J_NUM: lexeme, J_STR: UTF-8 bytes */
    size_t n;
    jval *arr;
    jmem *obj; /* sorted by key, no duplicates */
    size_t count;
};

struct jmem {
    char *k;
    size_t kn;
    size_t ord;
    jval v;
};

static void jval_free(jval *v)
{
    size_t i;
    free(v->s);
    for (i = 0; v->arr && i < v->count; i++)
        jval_free(&v->arr[i]);
    for (i = 0; v->obj && i < v->count; i++) {
        free(v->obj[i].k);
        jval_free(&v->obj[i].v);
    }
    free(v->arr);
    free(v->obj);
    memset(v, 0, sizeof *v);
}

static int bytes_cmp(const char *a, size_t an, const char *b, size_t bn)
{
    int c = memcmp(a, b, an < bn ? an : bn);
    if (c)
        return c;
    return an < bn ? -1 : an > bn;
}

typedef struct {
    const unsigned char *p, *end;
    int oom;
} jparser;

static int parse_value(jparser *jp, jval *out, int depth);

static void skip_ws(jparser *jp)
{
    while (jp->p < jp->end && (*jp->p == ' ' || *jp->p == '\t' || *jp->p == '\n' || *jp->p == '\r'))
        jp->p++;
}

static int hex4(jparser *jp, unsigned *out)
{
    unsigned v = 0;
    int i;
    if (jp->end - jp->p < 4)
        return -1;
    for (i = 0; i < 4; i++) {
        unsigned c = *jp->p++;
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return -1;
    }
    *out = v;
    return 0;
}

static int parse_string(jparser *jp, char **s, size_t *n)
{
    buf b = { 0 };

    jp->p++; /* opening quote */
    for (;;) {
        unsigned c, cp, lo;
        size_t len;

        if (jp->p >= jp->end)
            goto bad;
        c = *jp->p;
        if (c == '"') {
            jp->p++;
            break;
        }
        if (c < 0x20)
            goto bad;
        if (c != '\\') {
            len = utf8_len(jp->p, jp->end, UTF8_JSON_MAX);
            if (!len)
                goto bad;
            buf_put(&b, jp->p, len);
            jp->p += len;
            continue;
        }
        if (++jp->p >= jp->end)
            goto bad;
        switch (*jp->p++) {
        case '"':  buf_putc(&b, '"'); break;
        case '\\': buf_putc(&b, '\\'); break;
        case '/':  buf_putc(&b, '/'); break;
        case 'b':  buf_putc(&b, '\b'); break;
        case 'f':  buf_putc(&b, '\f'); break;
        case 'n':  buf_putc(&b, '\n'); break;
        case 'r':  buf_putc(&b, '\r'); break;
        case 't':  buf_putc(&b, '\t'); break;
        case 'u':
            if (hex4(jp, &cp))
                goto bad;
            if (cp >= 0xDC00 && cp <= 0xDFFF)
                goto bad;
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                if (jp->end - jp->p < 2 || jp->p[0] != '\\' || jp->p[1] != 'u')
                    goto bad;
                jp->p += 2;
                if (hex4(jp, &lo) || lo < 0xDC00 || lo > 0xDFFF)
                    goto bad;
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            }
            put_codepoint(&b, cp);
            break;
        default:
            goto bad;
        }
    }

    if (b.oom) {
        jp->oom = 1;
        goto bad;
    }
    if (!b.p && !(b.p = dup_bytes("", 0))) {
        jp->oom = 1;
        return -1;
    }
    *s = b.p;
    *n = b.len;
    return 0;

bad:
    free(b.p);
    return -1;
}

static int is_digit(const unsigned char *p, const unsigned char *end)
{
    return p < end && *p >= '0' && *p <= '9';
}

/* Perl's stringification of a floating point value (NV). */
static void format_nv(double v, char *out, size_t size)
{
    if (v == 0)
        snprintf(out, size, "0");
    else if (v > DBL_MAX)
        snprintf(out, size, "Inf");
    else if (v < -DBL_MAX)
        snprintf(out, size, "-Inf");
    else
        snprintf(out, size, "%.15g", v);
}

/* Formats v as an integer if Perl would hold it as one (IV/UV): integral
 * and within [-2^63, 2^64). */
static int format_iv(double v, char *out, size_t size)
{
    if (!(v >= -9223372036854775808.0 && v < 18446744073709551616.0))
        return 0;
    if (v >= 0) {
        unsigned long long u = (unsigned long long)v;
        if ((double)u != v)
            return 0;
        snprintf(out, size, "%llu", u);
    } else {
        long long i = (long long)v;
        if ((double)i != v)
            return 0;
        snprintf(out, size, "%lld", i);
    }
    return 1;
}

/*
 * Number text as JSON::PP writes it back after decoding (number() in
 * JSON/PP.pm). The lexeme goes through Perl's numeric conversion: integers
 * that fit IV/UV stay exact, integers longer than 20 characters become
 * strings, "1.50" is divided by 1.0 and printed as an NV ("1.5"), "1e3" is
 * added to 0 and printed as an integer ("1000").
 */
static int normalize_number(char *lex, size_t n, jval *out)
{
    int has_dot = memchr(lex, '.', n) != NULL;
    int has_exp = memchr(lex, 'e', n) || memchr(lex, 'E', n);
    int neg = lex[0] == '-';
    char text[64];
    double v;

    if (!has_dot && !has_exp) {
        const char *digits = lex + neg;
        size_t dn = n - neg;
        const char *limit = neg ? "9223372036854775808" : "18446744073709551615";
        size_t ln = strlen(limit);

        if (n > 20) {
            out->type = J_STR;
            out->s = lex;
            out->n = n;
            return 0;
        }
        if (dn < ln || (dn == ln && memcmp(digits, limit, dn) <= 0)) {
            out->type = J_NUM;
            if (neg && dn == 1 && digits[0] == '0') { /* -0 */
                lex[0] = '0';
                lex[1] = '\0';
                n = 1;
            }
            out->s = lex;
            out->n = n;
            return 0;
        }
    }

    v = strtod(lex, NULL);
    if (!(!has_dot && has_exp && format_iv(v, text, sizeof text))
        && !(has_dot && has_exp && (v > 9007199254740992.0 || v < -9007199254740992.0)
             && format_iv(v, text, sizeof text)))
        format_nv(v, text, sizeof text);

    free(lex);
    out->type = J_NUM;
    out->n = strlen(text);
    if (!(out->s = dup_bytes(text, out->n)))
        return -1;
    return 0;
}

static int parse_number(jparser *jp, jval *out)
{
    const unsigned char *start = jp->p;
    char *lex;

    if (jp->p < jp->end && *jp->p == '-')
        jp->p++;
    if (!is_digit(jp->p, jp->end))
        return -1;
    if (*jp->p == '0') {
        jp->p++;
        if (is_digit(jp->p, jp->end))
            return -1;
    } else {
        while (is_digit(jp->p, jp->end))
            jp->p++;
    }
    if (jp->p < jp->end && *jp->p == '.') {
        jp->p++;
        if (!is_digit(jp->p, jp->end))
            return -1;
        while (is_digit(jp->p, jp->end))
            jp->p++;
    }
    if (jp->p < jp->end && (*jp->p == 'e' || *jp->p == 'E')) {
        jp->p++;
        if (jp->p < jp->end && (*jp->p == '+' || *jp->p == '-'))
            jp->p++;
        if (!is_digit(jp->p, jp->end))
            return -1;
        while (is_digit(jp->p, jp->end))
            jp->p++;
    }

    if (!(lex = dup_bytes((const char *)start, (size_t)(jp->p - start)))
        || normalize_number(lex, (size_t)(jp->p - start), out)) {
        jp->oom = 1;
        return -1;
    }
    return 0;
}

static int parse_array(jparser *jp, jval *out, int depth)
{
    size_t cap = 0;

    out->type = J_ARR;
    jp->p++;
    skip_ws(jp);
    if (jp->p < jp->end && *jp->p == ']') {
        jp->p++;
        return 0;
    }
    for (;;) {
        if (out->count == cap) {
            size_t ncap = cap ? cap * 2 : 4;
            jval *a = realloc(out->arr, ncap * sizeof *a);
            if (!a) {
                jp->oom = 1;
                return -1;
            }
            out->arr = a;
            cap = ncap;
        }
        memset(&out->arr[out->count], 0, sizeof *out->arr);
        if (parse_value(jp, &out->arr[out->count], depth + 1)) {
            jval_free(&out->arr[out->count]);
            return -1;
        }
        out->count++;
        skip_ws(jp);
        if (jp->p >= jp->end)
            return -1;
        if (*jp->p == ']') {
            jp->p++;
            return 0;
        }
        if (*jp->p++ != ',')
            return -1;
    }
}

static int jmem_cmp(const void *a, const void *b)
{
    const jmem *x = a, *y = b;
    int c = bytes_cmp(x->k, x->kn, y->k, y->kn);
    if (c)
        return c;
    return x->ord < y->ord ? -1 : x->ord > y->ord;
}

/* Sorts members by key; on duplicate keys the last one wins. */
static void sort_members(jval *obj)
{
    size_t i, w = 0;

    if (obj->count < 2)
        return;
    qsort(obj->obj, obj->count, sizeof *obj->obj, jmem_cmp);
    for (i = 0; i < obj->count; i++) {
        jmem *m = &obj->obj[i];
        if (i + 1 < obj->count && !bytes_cmp(m->k, m->kn, m[1].k, m[1].kn)) {
            free(m->k);
            jval_free(&m->v);
            continue;
        }
        obj->obj[w++] = *m;
    }
    obj->count = w;
}

static int parse_object(jparser *jp, jval *out, int depth)
{
    size_t cap = 0;

    out->type = J_OBJ;
    jp->p++;
    skip_ws(jp);
    if (jp->p < jp->end && *jp->p == '}') {
        jp->p++;
        return 0;
    }
    for (;;) {
        jmem *m;

        if (out->count == cap) {
            size_t ncap = cap ? cap * 2 : 4;
            jmem *o = realloc(out->obj, ncap * sizeof *o);
            if (!o) {
                jp->oom = 1;
                return -1;
            }
            out->obj = o;
            cap = ncap;
        }
        m = &out->obj[out->count];
        memset(m, 0, sizeof *m);
        m->ord = out->count;

        skip_ws(jp);
        if (jp->p >= jp->end || *jp->p != '"' || parse_string(jp, &m->k, &m->kn))
            return -1;
        out->count++; /* m->k is owned now; m->v is zeroed so freeing is safe */
        skip_ws(jp);
        if (jp->p >= jp->end || *jp->p++ != ':')
            return -1;
        if (parse_value(jp, &m->v, depth + 1))
            return -1;
        skip_ws(jp);
        if (jp->p >= jp->end)
            return -1;
        if (*jp->p == '}') {
            jp->p++;
            sort_members(out);
            return 0;
        }
        if (*jp->p++ != ',')
            return -1;
    }
}

static int parse_literal(jparser *jp, const char *word, int type, jval *out)
{
    size_t n = strlen(word);
    if ((size_t)(jp->end - jp->p) < n || memcmp(jp->p, word, n))
        return -1;
    jp->p += n;
    out->type = type;
    return 0;
}

static int parse_value(jparser *jp, jval *out, int depth)
{
    if (depth > MAX_DEPTH)
        return -1;
    skip_ws(jp);
    if (jp->p >= jp->end)
        return -1;
    switch (*jp->p) {
    case '{': return parse_object(jp, out, depth);
    case '[': return parse_array(jp, out, depth);
    case '"':
        out->type = J_STR;
        return parse_string(jp, &out->s, &out->n);
    case 't': return parse_literal(jp, "true", J_TRUE, out);
    case 'f': return parse_literal(jp, "false", J_FALSE, out);
    case 'n': return parse_literal(jp, "null", J_NULL, out);
    default:  return parse_number(jp, out);
    }
}

/* Parses a complete JSON document. Returns 0, -1 if invalid, -2 if OOM. */
static int json_parse(const char *s, size_t n, jval *out)
{
    jparser jp = { (const unsigned char *)s, (const unsigned char *)s + n, 0 };

    memset(out, 0, sizeof *out);
    if (parse_value(&jp, out, 1) == 0) {
        skip_ws(&jp);
        if (jp.p == jp.end)
            return 0;
    }
    jval_free(out);
    return jp.oom ? -2 : -1;
}

/* Canonical encoding, matching JSON::PP->canonical: sorted keys, no
 * whitespace, only quote, backslash and control characters escaped. */
static void enc_str(buf *b, const char *s, size_t n)
{
    size_t i, run = 0;

    buf_putc(b, '"');
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        const char *esc = NULL;
        char hex[8];

        if (c >= 0x20 && c != '"' && c != '\\')
            continue;
        buf_put(b, s + run, i - run);
        run = i + 1;
        switch (c) {
        case '"':  esc = "\\\""; break;
        case '\\': esc = "\\\\"; break;
        case '\n': esc = "\\n"; break;
        case '\r': esc = "\\r"; break;
        case '\t': esc = "\\t"; break;
        case '\f': esc = "\\f"; break;
        case '\b': esc = "\\b"; break;
        default:
            snprintf(hex, sizeof hex, "\\u%04x", c);
            esc = hex;
        }
        buf_put(b, esc, strlen(esc));
    }
    buf_put(b, s + run, n - run);
    buf_putc(b, '"');
}

static void enc_val(buf *b, const jval *v)
{
    size_t i;

    switch (v->type) {
    case J_NULL:  buf_put(b, "null", 4); break;
    case J_FALSE: buf_put(b, "false", 5); break;
    case J_TRUE:  buf_put(b, "true", 4); break;
    case J_NUM:   buf_put(b, v->s, v->n); break;
    case J_STR:   enc_str(b, v->s, v->n); break;
    case J_ARR:
        buf_putc(b, '[');
        for (i = 0; i < v->count; i++) {
            if (i)
                buf_putc(b, ',');
            enc_val(b, &v->arr[i]);
        }
        buf_putc(b, ']');
        break;
    case J_OBJ:
        buf_putc(b, '{');
        for (i = 0; i < v->count; i++) {
            if (i)
                buf_putc(b, ',');
            enc_str(b, v->obj[i].k, v->obj[i].kn);
            buf_putc(b, ':');
            enc_val(b, &v->obj[i].v);
        }
        buf_putc(b, '}');
        break;
    }
}

/* A plain string as JSON text. */
static void enc_plain(buf *b, const char *s, size_t n)
{
    buf text = { 0 };
    put_text_utf8(&text, s, n);
    if (text.oom)
        b->oom = 1;
    else
        enc_str(b, text.p ? text.p : "", text.len);
    free(text.p);
}

/* Raw input -> stored JSON text: valid JSON is kept, anything else becomes
 * a JSON string. */
static int encode_input(citron *db, const char *input, buf *out)
{
    jval v;
    size_t n = strlen(input);
    int rc = json_parse(input, n, &v);

    if (rc == -2)
        return fail_nomem(db);
    if (rc == 0) {
        enc_val(out, &v);
        jval_free(&v);
    } else {
        enc_plain(out, input, n);
    }
    return out->oom ? fail_nomem(db) : CITRON_OK;
}

/* --- records ------------------------------------------------------------ */

typedef struct {
    char *k, *v;
    size_t kn, vn;
} rec;

typedef struct {
    rec *r;
    size_t n, cap;
} store;

static void store_free(store *s)
{
    size_t i;
    for (i = 0; i < s->n; i++) {
        free(s->r[i].k);
        free(s->r[i].v);
    }
    free(s->r);
    memset(s, 0, sizeof *s);
}

/* Returns 1 and the index if found, else 0 and the insertion point. */
static int store_find(const store *s, const char *k, size_t kn, size_t *pos)
{
    size_t lo = 0, hi = s->n;

    /* records usually arrive sorted, so check the end first */
    if (s->n && bytes_cmp(s->r[s->n - 1].k, s->r[s->n - 1].kn, k, kn) < 0) {
        *pos = s->n;
        return 0;
    }
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int c = bytes_cmp(s->r[mid].k, s->r[mid].kn, k, kn);
        if (c == 0) {
            *pos = mid;
            return 1;
        }
        if (c < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    *pos = lo;
    return 0;
}

/* Inserts or replaces; copies both key and value. Returns 0 or -1 (OOM). */
static int store_put(store *s, const char *k, size_t kn, const char *v, size_t vn)
{
    size_t pos;
    char *nv = dup_bytes(v, vn);

    if (!nv)
        return -1;
    if (store_find(s, k, kn, &pos)) {
        free(s->r[pos].v);
        s->r[pos].v = nv;
        s->r[pos].vn = vn;
        return 0;
    }
    if (s->n == s->cap) {
        size_t ncap = s->cap ? s->cap * 2 : 16;
        rec *r = realloc(s->r, ncap * sizeof *r);
        if (!r) {
            free(nv);
            return -1;
        }
        s->r = r;
        s->cap = ncap;
    }
    memmove(&s->r[pos + 1], &s->r[pos], (s->n - pos) * sizeof *s->r);
    s->r[pos].k = dup_bytes(k, kn);
    if (!s->r[pos].k) {
        memmove(&s->r[pos], &s->r[pos + 1], (s->n - pos) * sizeof *s->r);
        free(nv);
        return -1;
    }
    s->r[pos].kn = kn;
    s->r[pos].v = nv;
    s->r[pos].vn = vn;
    s->n++;
    return 0;
}

static int store_del(store *s, const char *k, size_t kn)
{
    size_t pos;

    if (!store_find(s, k, kn, &pos))
        return 0;
    free(s->r[pos].k);
    free(s->r[pos].v);
    memmove(&s->r[pos], &s->r[pos + 1], (s->n - pos - 1) * sizeof *s->r);
    s->n--;
    return 1;
}

/* --- file format -------------------------------------------------------- */

static uint32_t get_u32(const unsigned char *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int serialize(const store *s, buf *b)
{
    size_t i;

    buf_put(b, MAGIC, MAGIC_LEN);
    buf_u32(b, FORMAT_VERSION);
    buf_u32(b, (uint32_t)s->n);
    for (i = 0; i < s->n; i++) {
        buf_u32(b, (uint32_t)s->r[i].kn);
        buf_put(b, s->r[i].k, s->r[i].kn);
        buf_u32(b, (uint32_t)s->r[i].vn);
        buf_put(b, s->r[i].v, s->r[i].vn);
    }
    return b->oom ? -1 : 0;
}

static int deserialize(citron *db, const unsigned char *data, size_t total, store *s)
{
    size_t off = MAGIC_LEN;
    uint32_t version, count, i;

#define NEED(len, what)                                                        \
    do {                                                                       \
        if ((len) > total - off)                                               \
            return fail(db, CITRON_ECORRUPT,                                   \
                        "Corrupt CitronDB file: truncated while reading %s",   \
                        what);                                                 \
    } while (0)

    if (total == 0)
        return CITRON_OK;
    if (total < HEADER_SIZE || memcmp(data, MAGIC, MAGIC_LEN))
        return fail(db, CITRON_ECORRUPT, "Not a CitronDB file (bad header)");

    version = get_u32(data + off);
    off += 4;
    if (version > FORMAT_VERSION)
        return fail(db, CITRON_EVERSION,
                    "CitronDB file version %lu is newer than supported version %d",
                    (unsigned long)version, FORMAT_VERSION);
    if (version < 1)
        return fail(db, CITRON_ECORRUPT, "Corrupt CitronDB file: invalid version %lu",
                    (unsigned long)version);

    count = get_u32(data + off);
    off += 4;

    for (i = 0; i < count; i++) {
        const char *k, *v;
        size_t kn, vn;
        buf conv = { 0 };
        int rc;

        NEED(4, "key length");
        kn = get_u32(data + off);
        off += 4;
        NEED(kn, "key");
        k = (const char *)data + off;
        off += kn;

        NEED(4, "value length");
        vn = get_u32(data + off);
        off += 4;
        NEED(vn, "value");
        v = (const char *)data + off;
        off += vn;

        /* v1 stored raw strings; v2 stores JSON */
        if (version == 1) {
            enc_plain(&conv, v, vn);
            if (conv.oom) {
                free(conv.p);
                return fail_nomem(db);
            }
            v = conv.p;
            vn = conv.len;
        }
        rc = store_put(s, k, kn, v, vn);
        free(conv.p);
        if (rc)
            return fail_nomem(db);
    }

    if (off != total)
        return fail(db, CITRON_ECORRUPT, "Corrupt CitronDB file: %lu unexpected trailing bytes",
                    (unsigned long)(total - off));
    return CITRON_OK;
#undef NEED
}

/* --- storage ------------------------------------------------------------ */

static int file_exists(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0;
}

static int load(citron *db, store *s)
{
    FILE *f;
    buf b = { 0 };
    char chunk[65536];
    size_t n;
    int rc;

    if (!file_exists(db->path))
        return CITRON_OK;
    if (!(f = fopen(db->path, "rb")))
        return fail(db, CITRON_EIO, "Could not open file '%s': %s", db->path, strerror(errno));
    while ((n = fread(chunk, 1, sizeof chunk, f)) > 0)
        buf_put(&b, chunk, n);
    if (ferror(f)) {
        fclose(f);
        free(b.p);
        return fail(db, CITRON_EIO, "Could not read file '%s'", db->path);
    }
    fclose(f);
    if (b.oom) {
        free(b.p);
        return fail_nomem(db);
    }
    rc = deserialize(db, (const unsigned char *)b.p, b.len, s);
    free(b.p);
    return rc;
}

static int replace_file(const char *from, const char *to)
{
#ifdef _WIN32
    return MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) ? 0 : -1;
#else
    return rename(from, to);
#endif
}

/* Writes atomically: temp file, fsync, rename over the database. */
static int save(citron *db, const store *s)
{
    buf b = { 0 };
    FILE *f;
    int ok;

    if (serialize(s, &b)) {
        free(b.p);
        return fail_nomem(db);
    }
    if (!(f = fopen(db->tmp_path, "wb"))) {
        free(b.p);
        return fail(db, CITRON_EIO, "Could not write to file '%s': %s", db->tmp_path,
                    strerror(errno));
    }
    ok = fwrite(b.p, 1, b.len, f) == b.len && fflush(f) == 0;
    free(b.p);
#ifdef _WIN32
    ok = ok && _commit(_fileno(f)) == 0;
#else
    ok = ok && fsync(fileno(f)) == 0;
#endif
    if (fclose(f) != 0 || !ok) {
        remove(db->tmp_path);
        return fail(db, CITRON_EIO, "Could not write to file '%s'", db->tmp_path);
    }
    if (replace_file(db->tmp_path, db->path)) {
        remove(db->tmp_path);
        return fail(db, CITRON_EIO, "Could not rename '%s' to '%s'", db->tmp_path, db->path);
    }
    return CITRON_OK;
}

/* A lock on "<db>.lock", compatible with Perl's flock(). A separate lock
 * file is used because writes replace the database file via rename. */
typedef struct {
#ifdef _WIN32
    HANDLE h;
#else
    int fd;
#endif
} lockh;

/* Perl's flock() on Windows locks this byte range (win32/win32.c). */
#define WIN_LOCK_LEN 0xffff0000UL

static int lock_acquire(citron *db, int exclusive, lockh *l)
{
#ifdef _WIN32
    OVERLAPPED ov;

    l->h = CreateFileA(db->lock_path, GENERIC_READ | GENERIC_WRITE,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                       OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (l->h == INVALID_HANDLE_VALUE)
        return fail(db, CITRON_EIO, "Could not open lock file '%s'", db->lock_path);
    memset(&ov, 0, sizeof ov);
    if (!LockFileEx(l->h, exclusive ? LOCKFILE_EXCLUSIVE_LOCK : 0, 0, WIN_LOCK_LEN, 0, &ov)) {
        CloseHandle(l->h);
        return fail(db, CITRON_EIO, "Could not lock '%s'", db->lock_path);
    }
#else
    l->fd = open(db->lock_path, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (l->fd < 0)
        return fail(db, CITRON_EIO, "Could not open lock file '%s': %s", db->lock_path,
                    strerror(errno));
    while (flock(l->fd, exclusive ? LOCK_EX : LOCK_SH) != 0) {
        if (errno != EINTR) {
            close(l->fd);
            return fail(db, CITRON_EIO, "Could not lock '%s': %s", db->lock_path,
                        strerror(errno));
        }
    }
#endif
    return CITRON_OK;
}

static void lock_release(lockh *l)
{
#ifdef _WIN32
    OVERLAPPED ov;
    memset(&ov, 0, sizeof ov);
    UnlockFileEx(l->h, 0, WIN_LOCK_LEN, 0, &ov);
    CloseHandle(l->h);
#else
    flock(l->fd, LOCK_UN);
    close(l->fd);
#endif
}

/* Locks and loads the records. On failure nothing is held. */
static int begin(citron *db, int exclusive, lockh *l, store *s)
{
    int rc = lock_acquire(db, exclusive, l);
    if (rc)
        return rc;
    memset(s, 0, sizeof *s);
    if ((rc = load(db, s))) {
        store_free(s);
        lock_release(l);
    }
    return rc;
}

/* Saves if changed, then releases everything. */
static int finish(citron *db, lockh *l, store *s, int changed, int result)
{
    int rc = changed ? save(db, s) : CITRON_OK;
    store_free(s);
    lock_release(l);
    return rc ? rc : result;
}

/* --- path lookup -------------------------------------------------------- */

static int index_part(const char *p, size_t n, long long *out)
{
    size_t i = 0;
    long long v = 0;
    int neg = 0;

    if (n && p[0] == '-') {
        neg = 1;
        i = 1;
    }
    if (i == n)
        return 0;
    for (; i < n; i++) {
        if (p[i] < '0' || p[i] > '9')
            return 0;
        if (v > 1000000000000LL)
            v = 1000000000000LL; /* far out of range either way */
        else
            v = v * 10 + (p[i] - '0');
    }
    *out = neg ? -v : v;
    return 1;
}

/* Walks a dotted path ("address.city", "tags.0") like resolve_path in
 * citron.perl. Returns NULL if any step is missing. */
static const jval *resolve_path(const jval *v, const char *path)
{
    size_t end;
    const char *p;

    if (!path)
        return v;
    end = strlen(path);
    while (end && path[end - 1] == '.') /* split drops trailing empty fields */
        end--;

    p = path;
    while (end && p <= path + end) {
        const char *dot = memchr(p, '.', (size_t)(path + end - p));
        size_t n = dot ? (size_t)(dot - p) : (size_t)(path + end - p);
        long long idx;

        if (v->type == J_OBJ) {
            size_t lo = 0, hi = v->count;
            const jval *next = NULL;
            while (lo < hi) {
                size_t mid = lo + (hi - lo) / 2;
                int c = bytes_cmp(v->obj[mid].k, v->obj[mid].kn, p, n);
                if (c == 0) {
                    next = &v->obj[mid].v;
                    break;
                }
                if (c < 0)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            if (!next)
                return NULL;
            v = next;
        } else if (v->type == J_ARR && index_part(p, n, &idx)
                   && idx < (long long)v->count && idx >= -(long long)v->count) {
            v = &v->arr[idx < 0 ? (long long)v->count + idx : idx];
        } else {
            return NULL;
        }
        if (!dot)
            break;
        p = dot + 1;
    }
    return v;
}

/* --- public API --------------------------------------------------------- */

const char *citron_version(void)
{
    return CITRON_VERSION;
}

static char *concat(const char *a, const char *b)
{
    size_t an = strlen(a), bn = strlen(b);
    char *p = malloc(an + bn + 1);
    if (p) {
        memcpy(p, a, an);
        memcpy(p + an, b, bn + 1);
    }
    return p;
}

int citron_open(const char *path, citron **out)
{
    citron *db;
    lockh l;
    store s = { 0 };
    int rc;

    if (!out)
        return CITRON_EINVALID;
    *out = NULL;
    if (!path)
        path = DEFAULT_FILE;
    if (!(db = calloc(1, sizeof *db)))
        return CITRON_ENOMEM;
    *out = db;

    db->path = concat(path, "");
    db->tmp_path = concat(path, ".tmp");
    db->lock_path = concat(path, ".lock");
    if (!db->path || !db->tmp_path || !db->lock_path)
        return fail_nomem(db);
    if (!*path)
        return fail(db, CITRON_EINVALID, "Empty database path");

    if ((rc = lock_acquire(db, 1, &l)))
        return rc;

    /* remove a temp file left by a crash */
    if (file_exists(db->tmp_path))
        remove(db->tmp_path);

    /* create if missing, otherwise make sure it's readable */
    rc = file_exists(db->path) ? load(db, &s) : save(db, &s);
    store_free(&s);
    lock_release(&l);
    return rc;
}

void citron_close(citron *db)
{
    if (!db)
        return;
    free(db->path);
    free(db->tmp_path);
    free(db->lock_path);
    free(db);
}

const char *citron_errmsg(const citron *db)
{
    if (!db)
        return "Out of memory";
    return db->err;
}

#define CHECK_ARGS(db, cond)                                                   \
    do {                                                                       \
        if (!(db))                                                             \
            return CITRON_EINVALID;                                            \
        if (!(cond))                                                           \
            return fail((db), CITRON_EINVALID, "Invalid argument");            \
    } while (0)

static int write_key(citron *db, const char *key, const char *value, int only_existing)
{
    buf enc = { 0 };
    lockh l;
    store s;
    size_t pos;
    int rc;

    CHECK_ARGS(db, key && value);
    if ((rc = encode_input(db, value, &enc))) {
        free(enc.p);
        return rc;
    }
    if ((rc = begin(db, 1, &l, &s))) {
        free(enc.p);
        return rc;
    }
    if (only_existing && !store_find(&s, key, strlen(key), &pos)) {
        free(enc.p);
        return finish(db, &l, &s, 0, 0);
    }
    if (store_put(&s, key, strlen(key), enc.p, enc.len)) {
        free(enc.p);
        finish(db, &l, &s, 0, 0);
        return fail_nomem(db);
    }
    free(enc.p);
    return finish(db, &l, &s, 1, 1);
}

int citron_set(citron *db, const char *key, const char *value)
{
    int rc = write_key(db, key, value, 0);
    return rc < 0 ? rc : CITRON_OK;
}

int citron_update(citron *db, const char *key, const char *value)
{
    return write_key(db, key, value, 1);
}

int citron_delete(citron *db, const char *key)
{
    lockh l;
    store s;
    int rc, existed;

    CHECK_ARGS(db, key);
    if ((rc = begin(db, 1, &l, &s)))
        return rc;
    existed = store_del(&s, key, strlen(key));
    return finish(db, &l, &s, existed, existed);
}

int citron_exists(citron *db, const char *key)
{
    lockh l;
    store s;
    size_t pos;
    int rc;

    CHECK_ARGS(db, key);
    if ((rc = begin(db, 0, &l, &s)))
        return rc;
    return finish(db, &l, &s, 0, store_find(&s, key, strlen(key), &pos));
}

/* Reads the stored JSON text for key into *text (NULL if missing). */
static int read_value(citron *db, const char *key, char **text, size_t *len)
{
    lockh l;
    store s;
    size_t pos;
    int rc;

    *text = NULL;
    if ((rc = begin(db, 0, &l, &s)))
        return rc;
    if (store_find(&s, key, strlen(key), &pos)) {
        /* take ownership instead of copying */
        *text = s.r[pos].v;
        *len = s.r[pos].vn;
        s.r[pos].v = NULL;
    }
    return finish(db, &l, &s, 0, CITRON_OK);
}

static int get_impl(citron *db, const char *key, const char *path, char **out,
                    size_t *out_len, int as_text)
{
    char *text;
    size_t len;
    jval v;
    const jval *found;
    buf b = { 0 };
    int rc;

    if (out)
        *out = NULL;
    if (out_len)
        *out_len = 0;
    CHECK_ARGS(db, key && out);
    if ((rc = read_value(db, key, &text, &len)))
        return rc;
    if (!text)
        return 0;

    rc = json_parse(text, len, &v);
    free(text);
    if (rc == -2)
        return fail_nomem(db);
    if (rc)
        return fail(db, CITRON_ECORRUPT, "Corrupt CitronDB file: value of '%s' is not JSON", key);

    if (path) {
        /* Same as lookup in citron.perl: the path is a byte string there,
         * so each byte is compared as a Latin-1 character against the
         * decoded keys. */
        buf p = { 0 };
        put_latin1(&p, path, strlen(path));
        if (p.oom) {
            free(p.p);
            jval_free(&v);
            return fail_nomem(db);
        }
        found = resolve_path(&v, p.p ? p.p : "");
        free(p.p);
    } else {
        found = resolve_path(&v, NULL);
    }
    if (found && as_text && found->type == J_STR)
        buf_put(&b, found->s, found->n);
    else if (found)
        enc_val(&b, found);
    jval_free(&v);

    if (!found)
        return 0;
    if (b.oom) {
        free(b.p);
        return fail_nomem(db);
    }
    if (!b.p && !(b.p = dup_bytes("", 0)))
        return fail_nomem(db);
    *out = b.p;
    if (out_len)
        *out_len = b.len;
    return 1;
}

int citron_get(citron *db, const char *key, const char *path, char **out, size_t *len)
{
    return get_impl(db, key, path, out, len, 0);
}

int citron_get_text(citron *db, const char *key, const char *path, char **out, size_t *len)
{
    return get_impl(db, key, path, out, len, 1);
}

int citron_keys(citron *db, char ***keys, size_t *count)
{
    lockh l;
    store s;
    char **list;
    size_t i;
    int rc;

    if (keys)
        *keys = NULL;
    if (count)
        *count = 0;
    CHECK_ARGS(db, keys);
    if ((rc = begin(db, 0, &l, &s)))
        return rc;
    if (!(list = calloc(s.n + 1, sizeof *list))) {
        finish(db, &l, &s, 0, 0);
        return fail_nomem(db);
    }
    for (i = 0; i < s.n; i++) {
        /* take ownership; keys are already NUL-terminated */
        list[i] = s.r[i].k;
        s.r[i].k = NULL;
    }
    if (count)
        *count = s.n;
    *keys = list;
    return finish(db, &l, &s, 0, CITRON_OK);
}

int citron_dump(citron *db, char **out)
{
    lockh l;
    store s;
    buf b = { 0 };
    size_t i;
    int rc;

    if (out)
        *out = NULL;
    CHECK_ARGS(db, out);
    if ((rc = begin(db, 0, &l, &s)))
        return rc;
    buf_putc(&b, '{');
    for (i = 0; i < s.n; i++) {
        if (i)
            buf_putc(&b, ',');
        enc_plain(&b, s.r[i].k, s.r[i].kn);
        buf_putc(&b, ':');
        buf_put(&b, s.r[i].v, s.r[i].vn);
    }
    buf_putc(&b, '}');
    finish(db, &l, &s, 0, 0);
    if (b.oom) {
        free(b.p);
        return fail_nomem(db);
    }
    *out = b.p;
    return CITRON_OK;
}

/* Merges a parsed object in one write; takes ownership of v. */
static int import_object(citron *db, jval *obj)
{
    jval v = *obj;
    lockh l;
    store s;
    size_t i;
    int rc;

    if ((rc = begin(db, 1, &l, &s))) {
        jval_free(&v);
        return rc;
    }
    for (i = 0; i < v.count; i++) {
        buf enc = { 0 };
        enc_val(&enc, &v.obj[i].v);
        if (enc.oom || store_put(&s, v.obj[i].k, v.obj[i].kn, enc.p, enc.len)) {
            free(enc.p);
            jval_free(&v);
            finish(db, &l, &s, 0, 0);
            return fail_nomem(db);
        }
        free(enc.p);
    }
    rc = (int)v.count;
    jval_free(&v);
    return finish(db, &l, &s, 1, rc);
}

int citron_import(citron *db, const char *json_object)
{
    jval v;
    int rc;

    CHECK_ARGS(db, json_object);
    rc = json_parse(json_object, strlen(json_object), &v);
    if (rc == -2)
        return fail_nomem(db);
    if (rc)
        return fail(db, CITRON_EINVALID, "Invalid JSON");
    if (v.type != J_OBJ) {
        jval_free(&v);
        return fail(db, CITRON_EINVALID, "Import must be a JSON object at the top level");
    }
    return import_object(db, &v);
}

/* JSON::PP->pretty: three-space indent, "key" : value, empty containers
 * inline. */
static void indent(buf *b, int level)
{
    int i;
    for (i = 0; i < level * 3; i++)
        buf_putc(b, ' ');
}

static void enc_pretty(buf *b, const jval *v, int level)
{
    size_t i;

    if ((v->type != J_ARR && v->type != J_OBJ) || v->count == 0) {
        enc_val(b, v);
        return;
    }
    buf_put(b, v->type == J_ARR ? "[\n" : "{\n", 2);
    for (i = 0; i < v->count; i++) {
        indent(b, level + 1);
        if (v->type == J_OBJ) {
            enc_str(b, v->obj[i].k, v->obj[i].kn);
            buf_put(b, " : ", 3);
            enc_pretty(b, &v->obj[i].v, level + 1);
        } else {
            enc_pretty(b, &v->arr[i], level + 1);
        }
        buf_put(b, i + 1 < v->count ? ",\n" : "\n", i + 1 < v->count ? 2 : 1);
    }
    indent(b, level);
    buf_putc(b, v->type == J_ARR ? ']' : '}');
}


int citron_export_json(citron *db, const char *file)
{
    lockh l;
    store s;
    buf b = { 0 };
    FILE *f;
    size_t i;
    int rc, ok;

    CHECK_ARGS(db, file);
    if ((rc = begin(db, 0, &l, &s)))
        return rc;

    if (s.n == 0)
        buf_put(&b, "{}", 2);
    else
        buf_put(&b, "{\n", 2);
    for (i = 0; i < s.n; i++) {
        jval v;
        buf key = { 0 };

        rc = json_parse(s.r[i].v, s.r[i].vn, &v);
        if (rc) {
            free(b.p);
            finish(db, &l, &s, 0, 0);
            return rc == -2 ? fail_nomem(db)
                            : fail(db, CITRON_ECORRUPT,
                                   "Corrupt CitronDB file: value of '%s' is not JSON", s.r[i].k);
        }
        /* Same as export_json in citron.perl: keys are byte strings there,
         * so JSON::PP reads their bytes as Latin-1. */
        put_latin1(&key, s.r[i].k, s.r[i].kn);
        indent(&b, 1);
        if (key.oom)
            b.oom = 1;
        else
            enc_str(&b, key.p ? key.p : "", key.len);
        free(key.p);
        buf_put(&b, " : ", 3);
        enc_pretty(&b, &v, 1);
        buf_put(&b, i + 1 < s.n ? ",\n" : "\n", i + 1 < s.n ? 2 : 1);
        jval_free(&v);
    }
    if (s.n)
        buf_putc(&b, '}');
    buf_putc(&b, '\n');
    rc = (int)s.n;
    finish(db, &l, &s, 0, 0);

    if (b.oom) {
        free(b.p);
        return fail_nomem(db);
    }
    if (!(f = fopen(file, "wb"))) {
        free(b.p);
        return fail(db, CITRON_EIO, "Could not write '%s': %s", file, strerror(errno));
    }
    ok = fwrite(b.p, 1, b.len, f) == b.len;
    free(b.p);
    if (fclose(f) != 0 || !ok)
        return fail(db, CITRON_EIO, "Could not write '%s'", file);
    return rc;
}

int citron_import_json(citron *db, const char *file)
{
    FILE *f;
    buf b = { 0 };
    char chunk[65536];
    size_t n;
    jval v;
    int rc;

    CHECK_ARGS(db, file);
    if (!(f = fopen(file, "rb")))
        return fail(db, CITRON_EIO, "Could not read '%s': %s", file, strerror(errno));
    while ((n = fread(chunk, 1, sizeof chunk, f)) > 0)
        buf_put(&b, chunk, n);
    rc = ferror(f);
    fclose(f);
    if (rc) {
        free(b.p);
        return fail(db, CITRON_EIO, "Could not read '%s'", file);
    }
    if (b.oom) {
        free(b.p);
        return fail_nomem(db);
    }

    rc = json_parse(b.p ? b.p : "", b.len, &v);
    free(b.p);
    if (rc == -2)
        return fail_nomem(db);
    if (rc)
        return fail(db, CITRON_EINVALID, "Invalid JSON in '%s'", file);
    if (v.type != J_OBJ) {
        jval_free(&v);
        return fail(db, CITRON_EINVALID, "'%s' must contain a JSON object at the top level", file);
    }
    return import_object(db, &v);
}

void citron_free(void *ptr)
{
    free(ptr);
}

void citron_free_keys(char **keys)
{
    size_t i;
    if (!keys)
        return;
    for (i = 0; keys[i]; i++)
        free(keys[i]);
    free(keys);
}
