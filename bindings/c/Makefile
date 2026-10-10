# Builds the CitronDB C library into build/:
#   static library   build/libcitron.a
#   shared library   build/citron.dll (Windows), build/libcitron.dylib (macOS),
#                    build/libcitron.so (elsewhere)
#
#   make          build both libraries
#   make test     build and run the C tests
#   make example  build and run the example

ifeq ($(origin CC),default)
CC = gcc
endif
CFLAGS ?= -O2 -Wall -Wextra -std=c17
AR ?= ar

BUILD = build

ifeq ($(OS),Windows_NT)
SHARED = $(BUILD)/citron.dll
SHARED_FLAGS = -shared -Wl,--out-implib,$(BUILD)/libcitron.dll.a
EXE = .exe
else ifeq ($(shell uname -s),Darwin)
SHARED = $(BUILD)/libcitron.dylib
SHARED_FLAGS = -dynamiclib -fPIC
else
SHARED = $(BUILD)/libcitron.so
SHARED_FLAGS = -shared -fPIC
endif

STATIC = $(BUILD)/libcitron.a

all: $(STATIC) $(SHARED)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/citron.o: src/citron.c include/citron.h | $(BUILD)
	$(CC) $(CFLAGS) -fPIC -Iinclude -c src/citron.c -o $@

$(STATIC): $(BUILD)/citron.o
	$(AR) rcs $@ $^

$(SHARED): src/citron.c include/citron.h | $(BUILD)
	$(CC) $(CFLAGS) -DCITRON_SHARED -Iinclude $(SHARED_FLAGS) src/citron.c -o $@

# The tests and examples live at the project root, next to the Perl ones.
$(BUILD)/test_citron$(EXE): ../../test/c/test_citron.c $(STATIC)
	$(CC) $(CFLAGS) -Iinclude ../../test/c/test_citron.c $(STATIC) -o $@

$(BUILD)/example$(EXE): ../../examples/c/example.c $(STATIC)
	$(CC) $(CFLAGS) -Iinclude ../../examples/c/example.c $(STATIC) -o $@

# both run inside build/, so the files they create stay there
test: $(BUILD)/test_citron$(EXE)
	cd $(BUILD) && ./test_citron$(EXE)

example: $(BUILD)/example$(EXE)
	cd $(BUILD) && ./example$(EXE)

clean:
	rm -rf $(BUILD)

.PHONY: all test example clean
