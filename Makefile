# Build the rimel dynamic module and run the tests.
#
#   make                         build the module
#   make EMACS=/path/to/emacs    use a specific Emacs (for headers/tests)
#   make LIBRIME_ROOT=/opt/rime  use a librime installed under a prefix
#   make nix-rime-data           fetch Rime schema data with Nix
#   make test                    byte-compile and run the ERT suite
#
# librime is located with pkg-config, then the compiler's default paths.
# An Emacs from the Nix store cannot load a distribution's librime (nor
# its libstdc++, boost, glog...), so for it, and on NixOS where neither
# finds anything, a Nix librime is used instead:
#  1. one installed in a Nix profile (nix profile / nix-env / home-manager
#     / NixOS), linked with an rpath through the profile, which keeps it
#     alive and follows upgrades;
#  2. else one built into the out-link .nix-librime (a GC root).

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

comma := ,
NIX_LIBRIME := $(CURDIR)/.nix-librime
NIX_RIME_DATA := $(CURDIR)/.nix-rime-data
# `<nixpkgs>' from NIX_PATH, else the `nixpkgs' flake from the registry.
nix_build = nix-build '<nixpkgs>' -A $(1) -o $(2) \
  || nix --extra-experimental-features 'nix-command flakes' \
       build 'nixpkgs\#$(1)' -o $(2)

HAVE_NIX := $(shell command -v nix-build || command -v nix)
NIX_EMACS := $(filter /nix/store/%,$(EMACS_INCLUDE_DIR))
NIX_PROFILES := $(HOME)/.nix-profile $(HOME)/.local/state/nix/profile \
  /etc/profiles/per-user/$(shell id -un) /run/current-system/sw
NIX_PROFILE_LIBRIME := $(firstword $(foreach p,$(NIX_PROFILES),\
  $(if $(wildcard $(p)/include/rime_api.h),$(p))))
NIX_LIBRIME_FOUND := $(or $(NIX_PROFILE_LIBRIME),\
  $(if $(wildcard $(NIX_LIBRIME)/include/rime_api.h),$(NIX_LIBRIME)))

ifndef LIBRIME_ROOT
  ifneq ($(and $(NIX_EMACS),$(NIX_LIBRIME_FOUND)),)
    LIBRIME_ROOT := $(NIX_LIBRIME_FOUND)
  else ifneq ($(and $(NIX_EMACS),$(HAVE_NIX)),)
    LIBRIME_ROOT := $(NIX_LIBRIME)
    RIME_DEPS := $(NIX_LIBRIME)
  else ifeq ($(shell $(PKG_CONFIG) --exists rime 2>/dev/null && echo yes),yes)
    RIME_LIBDIR := $(shell $(PKG_CONFIG) --variable=libdir rime)
    RIME_CFLAGS := $(shell $(PKG_CONFIG) --cflags rime)
    RIME_LIBS := $(shell $(PKG_CONFIG) --libs rime) \
      $(if $(RIME_LIBDIR),-Wl$(comma)-rpath$(comma)$(RIME_LIBDIR))
  else ifeq ($(shell printf '\043include <rime_api.h>\n' \
                | $(CC) -E -x c - >/dev/null 2>&1 && echo yes),yes)
    RIME_LIBS := -lrime
  else ifneq ($(NIX_LIBRIME_FOUND),)
    LIBRIME_ROOT := $(NIX_LIBRIME_FOUND)
  else ifneq ($(HAVE_NIX),)
    LIBRIME_ROOT := $(NIX_LIBRIME)
    RIME_DEPS := $(NIX_LIBRIME)
  else
    RIME_MISSING := yes
  endif
endif

ifdef LIBRIME_ROOT
  RIME_CFLAGS = -I$(LIBRIME_ROOT)/include
  RIME_LIBS = -L$(LIBRIME_ROOT)/lib -Wl,-rpath,$(LIBRIME_ROOT)/lib -lrime
endif

CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -fPIC -Wall -Wextra
CPPFLAGS += $(if $(EMACS_INCLUDE_DIR),-I$(EMACS_INCLUDE_DIR)) $(RIME_CFLAGS)

.PHONY: all module elc test clean distclean nix-rime-data

all: module

module: $(MODULE)

$(MODULE): rimel-module.c $(RIME_DEPS)
	$(if $(RIME_MISSING),$(error librime not found (rime_api.h). Install \
	  librime's development files, or run make LIBRIME_ROOT=<librime prefix>))
	$(if $(and $(NIX_EMACS),$(if $(LIBRIME_ROOT),,x)),$(warning Emacs is \
	  from the Nix store but no Nix librime was found: the system librime \
	  will likely fail to load; install librime with Nix or pass \
	  LIBRIME_ROOT=<Nix librime>))
	$(CC) $(CPPFLAGS) $(CFLAGS) $(SHARED_FLAGS) -o $@ $< $(LDFLAGS) $(RIME_LIBS)

$(NIX_LIBRIME):
	$(call nix_build,librime,$@)

nix-rime-data:
	$(call nix_build,rime-data,$(NIX_RIME_DATA))

elc: rimel.elc

rimel.elc: rimel.el
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $<

test: module elc
	$(EMACS) -Q --batch -L . -l test/rimel-test.el \
	  -f ert-run-tests-batch-and-exit

clean:
	rm -f rimel-module.so rimel-module.dylib *.elc test/*.elc

# Also drop the Nix out-links (GC roots); the module needs them at runtime.
distclean: clean
	rm -f $(NIX_LIBRIME) $(NIX_RIME_DATA)
