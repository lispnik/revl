# Makefile --- build the tvlisp IDE (on the tv2 CLOS-native framework).
#
# tvlisp is dumped by ASDF's `program-op' (configured via :build-operation /
# :build-pathname / :entry-point in tvlisp.asd):
#
#   tvlisp  <- system tvlisp   (entry tvlisp-tv2:toplevel)

SBCL ?= sbcl
PYTHON ?= python3

# Build SYSTEM with asdf:make.  We add this project AND the sibling framework
# (../tvision, reachable via the parent tree) to the source registry so the
# build works without any global ocicl/ASDF config.
define asdf-make
$(SBCL) --non-interactive \
	--eval '(require :asdf)' \
	--eval '(asdf:initialize-source-registry (list :source-registry (list :tree (uiop:getcwd)) (list :tree (merge-pathnames "../" (uiop:getcwd))) :inherit-configuration))' \
	--eval '(asdf:make :$(1))' \
	--eval '(uiop:quit 0)'
endef

# Rebuild whenever the app entry, the tv2 framework (base + kernel), or the
# shared tvlisp-logic changes.
TV2   := $(wildcard ../tvision/tv2/*.lisp) $(wildcard ../tvision/base/*.lisp) ../tvision/tv2.asd
LOGIC := $(wildcard logic/*.lisp) tvlisp-logic.asd

.DEFAULT_GOAL := all
.PHONY: all clean run test test-pty help

all: tvlisp

# tvlisp on the tv2 CLOS-native framework.
tvlisp: tvlisp.asd src/tv2-main.lisp $(TV2) $(LOGIC)
	$(call asdf-make,tvlisp)

run: tvlisp
	./tvlisp

# Full test: the pty smoke suite (end-to-end through a pseudo-terminal, driven
# by the Lisp-native tvision-pty-driver sibling project).
test: test-pty

test-pty: tvlisp tests/pty_smoke_tv2.lisp
	$(SBCL) --script tests/pty_smoke_tv2.lisp

clean:
	rm -f tvlisp
	rm -rf $(HOME)/.cache/common-lisp/*tvlisp* 2>/dev/null || true

help:
	@echo "make            build the tvlisp binary"
	@echo "make run        build + run"
	@echo "make test       pty smoke suite"
	@echo "make clean      remove binary + fasl cache"
