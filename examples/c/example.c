/*
 * CitronDB 🍋 from C.
 *
 *   make -C bindings/c example
 *
 * or build it yourself against the static or shared library:
 *
 *   cc -Ibindings/c/include examples/c/example.c bindings/c/build/libcitron.a
 */
#include <stdio.h>
#include <stdlib.h>

#include "citron.h"

/* Every call returns a negative code on failure; citron_errmsg says why. */
static int check(citron *db, int rc)
{
    if (rc < 0) {
        fprintf(stderr, "citron: %s\n", citron_errmsg(db));
        citron_close(db);
        exit(1);
    }
    return rc;
}

static void print_value(citron *db, const char *key, const char *path)
{
    char *text;

    if (check(db, citron_get_text(db, key, path, &text, NULL))) {
        printf("%s%s%s: %s\n", key, path ? " " : "", path ? path : "", text);
        citron_free(text);
    } else {
        printf("%s: (nil)\n", key);
    }
}

int main(void)
{
    citron *db = NULL;
    char **keys;
    size_t count, i;

    check(db, citron_open("example.citron", &db));

    /* values are JSON; anything that isn't JSON is stored as a plain string */
    check(db, citron_set(db, "user:1", "{\"name\":\"Ada\",\"age\":36,\"tags\":[\"math\",\"code\"]}"));
    check(db, citron_set(db, "user:2", "{\"name\":\"Grace\",\"age\":85,\"tags\":[\"navy\",\"cobol\"]}"));
    check(db, citron_set(db, "greeting", "hello world"));
    check(db, citron_set(db, "visits", "0"));

    /* read whole values, or drill in with a path */
    print_value(db, "user:1", NULL);
    print_value(db, "user:1", "name");
    print_value(db, "user:2", "tags.0");
    print_value(db, "user:2", "tags.-1");
    print_value(db, "greeting", NULL);

    /* update only touches existing keys */
    check(db, citron_update(db, "visits", "1"));
    print_value(db, "visits", NULL);
    printf("update on a missing key: %d\n", check(db, citron_update(db, "ghost", "1")));

    /* a missing key and a stored null are different */
    check(db, citron_set(db, "nothing", "null"));
    printf("nothing exists: %d\n", check(db, citron_exists(db, "nothing")));
    print_value(db, "nothing", NULL);
    check(db, citron_delete(db, "nothing"));
    print_value(db, "nothing", NULL);

    /* snapshots: save the data, change it, roll back to exactly that
     * version. Without a name a snapshot is numbered 1, 2, 3, ... */
    char *number;
    check(db, citron_drop_snapshot(db, "beforeCleanup")); /* so the example can run again */
    check(db, citron_snapshot(db, "beforeCleanup", NULL));
    check(db, citron_snapshot(db, NULL, &number));
    printf("\nsnapshots:");
    check(db, citron_snapshots(db, &keys, &count));
    for (i = 0; i < count; i++)
        printf(" %s", keys[i]);
    citron_free_keys(keys);
    printf(" (just made %s)\n", number);
    citron_free(number);

    check(db, citron_delete(db, "user:2"));
    printf("after delete, user:2 exists: %d\n", check(db, citron_exists(db, "user:2")));
    check(db, citron_rollback(db, "beforeCleanup"));
    printf("after rollback, user:2 exists: %d\n", check(db, citron_exists(db, "user:2")));

    printf("\nall keys:\n");
    check(db, citron_keys(db, &keys, &count));
    for (i = 0; i < count; i++)
        printf("  %s\n", keys[i]);
    citron_free_keys(keys);

    printf("\nexported %d records to example.json\n",
           check(db, citron_export_json(db, "example.json")));

    citron_close(db);
    return 0;
}
