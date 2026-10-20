# Build the rimel dynamic module and run the tests.
#
#   make                         build the module
#   make EMACS=/path/to/emacs    use a specific Emacs (for headers/tests)
#   make LIBRIME_ROOT=/opt/rime  use a librime installed under a prefix
#   make test                    byte-compile and run the ERT suite

EMACS ?= emacs
CC ?= cc
PKG_CONFIG ?= pkg-config

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  MODULE_SUFFIX ?= .dylib
  SHARED_FLAGS = -dynamiclib -undefined dynamic_lookup
else
  MODULE_SUFFIX ?= .so
  SHARED_FLAGS = -shared
endif
MODULE ?= rimel-module$(MODULE_SUFFIX)

# emacs-module.h: found from the (symlink-resolved) Emacs binary unless given.
EMACS_INCLUDE_DIR ?= $(shell $(EMACS) -Q --batch --eval \
  '(let* ((bin (file-name-directory (file-truename (expand-file-name invocation-name invocation-directory)))) \
          (dirs (list (expand-file-name "../include" bin) (expand-file-name "../../include" bin) \
                      (expand-file-name "../src" bin) "/usr/include" "/usr/local/include"))) \
     (princ (or (seq-find (lambda (d) (file-exists-p (expand-file-name "emacs-module.h" d))) dirs) "")))' 2>/dev/null)

ifdef LIBRIME_ROOT
  RIME_CFLAGS = -I$(LIBRIME_ROOT)/include
  RIME_LIBS = -L$(LIBRIME_ROOT)/lib -Wl,-rpath,$(LIBRIME_ROOT)/lib -lrime
else
  RIME_CFLAGS := $(shell $(PKG_CONFIG) --cflags rime 2>/dev/null)
  RIME_LIBS := $(shell $(PKG_CONFIG) --libs rime 2>/dev/null || echo -lrime)
endif

CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -fPIC -Wall -Wextra
CPPFLAGS += $(if $(EMACS_INCLUDE_DIR),-I$(EMACS_INCLUDE_DIR)) $(RIME_CFLAGS)

.PHONY: all module elc test clean

all: module

module: $(MODULE)

$(MODULE): rimel-module.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SHARED_FLAGS) -o $@ $< $(LDFLAGS) $(RIME_LIBS)

elc: rimel.elc

rimel.elc: rimel.el
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $<

test: module elc
	$(EMACS) -Q --batch -L . -l test/rimel-test.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f rimel-module.so rimel-module.dylib *.elc test/*.elc
