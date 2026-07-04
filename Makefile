# Makefile --- build the revl IDE (on the revision CLOS-native framework).
#
# revl is dumped by ASDF's `program-op' (configured via :build-operation /
# :build-pathname / :entry-point in revl.asd):
#
#   revl  <- system revl   (entry revl:toplevel)

SBCL ?= sbcl
PYTHON ?= python3

# Build SYSTEM with asdf:make.  We add this project AND the sibling framework
# (../revision, reachable via the parent tree) to the source registry so the
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
REVISION   := $(wildcard ../revision/revision/*.lisp) $(wildcard ../revision/base/*.lisp) ../revision/revision.asd
LOGIC := $(wildcard logic/*.lisp) revl-logic.asd
IDE   := $(wildcard ide/*.lisp) revl.asd

.DEFAULT_GOAL := all
.PHONY: all clean run test test-pty test-sbcl keybindings help

all: revl

# revl on the revision CLOS-native framework.
revl: revl.asd src/main.lisp $(IDE) $(REVISION) $(LOGIC)
	$(call asdf-make,revl)

run: revl
	./revl

# Full test: revl's SBCL/IDE-feature logic (headless) + the pty smoke suite
# (end-to-end through a pseudo-terminal, via the revision-pty-driver sibling).
test: test-sbcl test-pty

# The SBCL-specific IDE features (compiler notes, backtraces, call-tree, …) and the
# keybinding-reference drift check — the full IDE bindings live here now.
test-sbcl: $(IDE) tests/revl-sbcl-tests.lisp
	$(SBCL) --script tests/revl-sbcl-tests.lisp

test-pty: revl tests/pty_smoke.lisp
	$(SBCL) --script tests/pty_smoke.lisp

# Regenerate the committed keybinding reference (the full IDE bindings) from the keymaps.
keybindings: $(IDE)
	$(SBCL) --non-interactive \
		--eval '(require :asdf)' \
		--eval '(asdf:initialize-source-registry (list :source-registry (list :tree (uiop:getcwd)) (list :tree (merge-pathnames "../" (uiop:getcwd))) :inherit-configuration))' \
		--eval '(handler-bind ((warning (function muffle-warning))) (asdf:load-system :revl))' \
		--eval '(with-open-file (o "KEYBINDINGS.md" :direction :output :if-exists :supersede) (write-string (uiop:symbol-call :revision :keybinding-markdown) o))' \
		--eval '(uiop:quit 0)'
	@echo "regenerated KEYBINDINGS.md"

clean:
	rm -f revl
	rm -rf $(HOME)/.cache/common-lisp/*revl* 2>/dev/null || true

help:
	@echo "make            build the revl binary"
	@echo "make run        build + run"
	@echo "make test       pty smoke suite"
	@echo "make clean      remove binary + fasl cache"
