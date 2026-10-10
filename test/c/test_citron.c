/*
 * Tests for the CitronDB C library. Behavior is checked against the Perl
 * implementation in test/python3/test_interop.py; these cover the C API
 * itself (return codes, ownership, errors).
 *
 *   make -C bindings/c test
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "citron.h"

static int failures, checks;

#define CHECK(cond)                                                            \
    do {                                                                       \
        checks++;                                                              \
        if (!(cond)) {                                                         \
            failures++;                                                        \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);    \
        }                                                                      \
    } while (0)

/* Checks that a lookup returns exactly `expected` (NULL = missing). */
static void check_get(citron *db, const char *key, const char *path, const char *expected,
                      int text, int line)
{
    char *out = NULL;
    size_t len = 0;
    int rc = text ? citron_get_text(db, key, path, &out, &len)
                  : citron_get(db, key, path, &out, &len);

    checks++;
    if (expected ? (rc != 1 || !out || len != strlen(expected) || strcmp(out, expected))
                 : (rc != 0 || out)) {
        failures++;
        fprintf(stderr, "FAIL line %d: get(%s, %s) = %d '%s', expected '%s'\n", line, key,
                path ? path : "NULL", rc, out ? out : "(null)", expected ? expected : "(missing)");
    }
    citron_free(out);
}

#define GET(db, key, path, expected) check_get(db, key, path, expected, 0, __LINE__)
#define GET_TEXT(db, key, path, expected) check_get(db, key, path, expected, 1, __LINE__)

static char *read_file(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    char *data = NULL;
    long n;

    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    data = malloc((size_t)n + 1);
    *len = fread(data, 1, (size_t)n, f);
    data[*len] = '\0';
    fclose(f);
    return data;
}

static void write_file(const char *path, const void *data, size_t len)
{
    FILE *f = fopen(path, "wb");
    fwrite(data, 1, len, f);
    fclose(f);
}

static void remove_db(const char *path)
{
    char extra[512];
    remove(path);
    snprintf(extra, sizeof extra, "%s.lock", path);
    remove(extra);
    snprintf(extra, sizeof extra, "%s.tmp", path);
    remove(extra);
}

static citron *fresh(const char *path)
{
    citron *db = NULL;
    remove_db(path);
    CHECK(citron_open(path, &db) == CITRON_OK);
    return db;
}

static void test_open(void)
{
    const char *path = "test_c_open.citron";
    citron *db = fresh(path);
    size_t len;
    char *data = read_file(path, &len);

    CHECK(data && len == 14 && !memcmp(data, "CITRON\0\0\0\2\0\0\0\0", 14));
    free(data);
    citron_close(db);

    /* a temp file left by a crash is removed on open */
    write_file("test_c_open.citron.tmp", "half", 4);
    CHECK(citron_open(path, &db) == CITRON_OK);
    CHECK(fopen("test_c_open.citron.tmp", "rb") == NULL);
    citron_close(db);
    remove_db(path);
}

static void test_set_get(void)
{
    citron *db = fresh("test_c_set.citron");

    CHECK(citron_set(db, "name", "Ada") == CITRON_OK);
    GET(db, "name", NULL, "\"Ada\"");
    GET_TEXT(db, "name", NULL, "Ada");
    GET(db, "missing", NULL, NULL);

    CHECK(citron_set(db, "n", "1.50") == CITRON_OK);
    GET(db, "n", NULL, "1.5");
    CHECK(citron_set(db, "e", "1e3") == CITRON_OK);
    GET(db, "e", NULL, "1000");
    CHECK(citron_set(db, "zip", "\"02139\"") == CITRON_OK);
    GET_TEXT(db, "zip", NULL, "02139");
    CHECK(citron_set(db, "broken", "{\"half\":") == CITRON_OK);
    GET(db, "broken", NULL, "\"{\\\"half\\\":\"");

    CHECK(citron_set(db, "nothing", "null") == CITRON_OK);
    GET(db, "nothing", NULL, "null");

    CHECK(citron_set(db, "name", "Grace") == CITRON_OK);
    GET_TEXT(db, "name", NULL, "Grace");

    citron_close(db);
    remove_db("test_c_set.citron");
}

static void test_paths(void)
{
    citron *db = fresh("test_c_paths.citron");

    citron_set(db, "u", "{\"name\":\"Ada\",\"tags\":[\"math\",\"code\"],"
                        "\"address\":{\"city\":\"London\"}}");
    GET(db, "u", NULL, "{\"address\":{\"city\":\"London\"},\"name\":\"Ada\",\"tags\":[\"math\",\"code\"]}");
    GET_TEXT(db, "u", "address.city", "London");
    GET_TEXT(db, "u", "tags.0", "math");
    GET_TEXT(db, "u", "tags.-1", "code");
    GET(db, "u", "tags", "[\"math\",\"code\"]");
    GET(db, "u", "tags.2", NULL);
    GET(db, "u", "tags.x", NULL);
    GET(db, "u", "nope", NULL);
    GET(db, "u", "", "{\"address\":{\"city\":\"London\"},\"name\":\"Ada\",\"tags\":[\"math\",\"code\"]}");

    citron_close(db);
    remove_db("test_c_paths.citron");
}

static void test_update_delete_exists(void)
{
    citron *db = fresh("test_c_ude.citron");

    CHECK(citron_update(db, "ghost", "1") == 0);
    CHECK(citron_exists(db, "ghost") == 0);
    citron_set(db, "k", "1");
    CHECK(citron_exists(db, "k") == 1);
    CHECK(citron_update(db, "k", "2") == 1);
    GET(db, "k", NULL, "2");
    CHECK(citron_delete(db, "k") == 1);
    CHECK(citron_delete(db, "k") == 0);
    CHECK(citron_exists(db, "k") == 0);

    citron_close(db);
    remove_db("test_c_ude.citron");
}

static void test_keys_dump_import(void)
{
    citron *db = fresh("test_c_keys.citron");
    char **keys = NULL, *dump = NULL;
    size_t count = 99;

    CHECK(citron_keys(db, &keys, &count) == CITRON_OK);
    CHECK(count == 0 && keys && keys[0] == NULL);
    citron_free_keys(keys);

    CHECK(citron_import(db, "{\"b\":1,\"a\":{\"x\":[]},\"b\":2}") == 2);
    CHECK(citron_import(db, "[1]") == CITRON_EINVALID);
    CHECK(citron_import(db, "{") == CITRON_EINVALID);
    citron_set(db, "c", "hi");

    CHECK(citron_keys(db, &keys, &count) == CITRON_OK);
    CHECK(count == 3 && !strcmp(keys[0], "a") && !strcmp(keys[1], "b") && !strcmp(keys[2], "c")
          && keys[3] == NULL);
    citron_free_keys(keys);

    CHECK(citron_dump(db, &dump) == CITRON_OK);
    CHECK(dump && !strcmp(dump, "{\"a\":{\"x\":[]},\"b\":2,\"c\":\"hi\"}"));
    citron_free(dump);

    citron_close(db);
    remove_db("test_c_keys.citron");
}

static void test_export_import_files(void)
{
    citron *db = fresh("test_c_export.citron");
    size_t len;
    char *data;

    citron_set(db, "a", "{\"x\":[1,2],\"y\":{}}");
    citron_set(db, "s", "hello");
    CHECK(citron_export_json(db, "test_c_export.json") == 2);
    data = read_file("test_c_export.json", &len);
    CHECK(data && !strcmp(data, "{\n   \"a\" : {\n      \"x\" : [\n         1,\n         2\n"
                                "      ],\n      \"y\" : {}\n   },\n   \"s\" : \"hello\"\n}\n"));
    free(data);
    citron_close(db);

    db = fresh("test_c_import.citron");
    CHECK(citron_import_json(db, "test_c_export.json") == 2);
    GET(db, "a", "x.1", "2");
    CHECK(citron_import_json(db, "does_not_exist.json") == CITRON_EIO);
    citron_close(db);

    remove("test_c_export.json");
    remove_db("test_c_export.citron");
    remove_db("test_c_import.citron");
}

static void test_errors(void)
{
    citron *db = NULL;
    const char *path = "test_c_errors.citron";

    remove_db(path);
    write_file(path, "garbage!!", 9);
    CHECK(citron_open(path, &db) == CITRON_ECORRUPT);
    CHECK(strstr(citron_errmsg(db), "bad header") != NULL);
    citron_close(db);

    write_file(path, "CITRON\0\0\0\x09\0\0\0\0", 14);
    CHECK(citron_open(path, &db) == CITRON_EVERSION);
    citron_close(db);

    /* one record "k" -> "\"v\"", then damaged */
    write_file(path, "CITRON\0\0\0\2\0\0\0\1\0\0\0\1k\0\0\0\3\"v\"", 26);
    CHECK(citron_open(path, &db) == CITRON_OK);
    GET_TEXT(db, "k", NULL, "v");
    write_file(path, "CITRON\0\0\0\2\0\0\0\1\0\0\0\1k\0\0\0\3\"v", 25);
    CHECK(citron_exists(db, "k") == CITRON_ECORRUPT);
    CHECK(strstr(citron_errmsg(db), "truncated") != NULL);
    write_file(path, "CITRON\0\0\0\2\0\0\0\1\0\0\0\1k\0\0\0\3\"v\"xx", 28);
    CHECK(citron_set(db, "k2", "1") == CITRON_ECORRUPT);
    CHECK(strstr(citron_errmsg(db), "trailing") != NULL);
    citron_close(db);

    CHECK(citron_open(path, NULL) == CITRON_EINVALID);
    CHECK(citron_set(NULL, "k", "v") == CITRON_EINVALID);
    remove_db(path);
}

static void test_nul_in_text(void)
{
    citron *db = fresh("test_c_nul.citron");
    char *out = NULL;
    size_t len = 0;

    citron_set(db, "k", "\"a\\u0000b\"");
    CHECK(citron_get_text(db, "k", NULL, &out, &len) == 1);
    CHECK(len == 3 && !memcmp(out, "a\0b", 3));
    citron_free(out);

    citron_close(db);
    remove_db("test_c_nul.citron");
}

int main(void)
{
    test_open();
    test_set_get();
    test_paths();
    test_update_delete_exists();
    test_keys_dump_import();
    test_export_import_files();
    test_errors();
    test_nul_in_text();

    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures ? 1 : 0;
}
