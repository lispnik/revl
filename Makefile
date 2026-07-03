# Makefile --- build the revl IDE (on the revision CLOS-native framework).
#
# revl is dumped by ASDF's `program-op' (configured via :build-operation /
# :build-pathname / :entry-point in revl.asd):
#
#   revl  <- system revl   (entry revl:toplevel)

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

# Rebuild whenever the app entry, the revision framework (base + kernel), or the
# shared revl-logic changes.
REVISION   := $(wildcard ../tvision/revision/*.lisp) $(wildcard ../tvision/base/*.lisp) ../tvision/revision.asd
LOGIC := $(wildcard logic/*.lisp) revl-logic.asd

.DEFAULT_GOAL := all
.PHONY: all clean run test test-pty help

all: revl

# revl on the revision CLOS-native framework.
revl: revl.asd src/main.lisp $(REVISION) $(LOGIC)
	$(call asdf-make,revl)

run: revl
	./revl

# Full test: the pty smoke suite (end-to-end through a pseudo-terminal, driven
# by the Lisp-native tvision-pty-driver sibling project).
test: test-pty

test-pty: revl tests/pty_smoke.lisp
	$(SBCL) --script tests/pty_smoke.lisp

clean:
	rm -f revl
	rm -rf $(HOME)/.cache/common-lisp/*revl* 2>/dev/null || true

help:
	@echo "make            build the revl binary"
	@echo "make run        build + run"
	@echo "make test       pty smoke suite"
	@echo "make clean      remove binary + fasl cache"
