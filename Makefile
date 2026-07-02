# Makefile --- build the tvlisp REPL / mini-IDE.
#
# tvlisp is dumped by ASDF's `program-op' (configured via :build-operation /
# :build-pathname / :entry-point in tvlisp.asd):
#
#   tvlisp      <- system tvlisp       (entry tvision-tvlisp:toplevel)
#   tvlisp-tv2  <- system tvlisp/tv2    (entry tvlisp-tv2:toplevel)
#
# It depends on the `tvision' framework, a sibling project at ../tvision.  The
# tvlisp-tv2 build instead runs on `tv2', the CLOS-native re-architecture of the
# framework (../tvision/tv2): every tvlisp window rebuilt on a new kernel.
#
# Usage:
#   make            # build ./tvlisp (classic)
#   make tvlisp-tv2 # build ./tvlisp-tv2 (on the tv2 CLOS kernel)
#   make run-tv2    # build & run the tv2 IDE
#   make test       # tvlisp pty smoke tests against the built binary
#   make clean      # remove the binaries and this project's fasl cache

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

# Rebuild whenever the app source or the framework changes.
FRAMEWORK := $(wildcard ../tvision/src/*.lisp) ../tvision/tvision.asd
# The tv2 kernel (../tvision/tv2) that the tvlisp-tv2 build runs on.
TV2 := $(wildcard ../tvision/tv2/*.lisp) ../tvision/tv2.asd

.DEFAULT_GOAL := all
.PHONY: all clean run run-tv2 test test-lisp test-pty test-pty-tv2 help

all: tvlisp

tvlisp: tvlisp.asd src/tvlisp.lisp $(FRAMEWORK)
	$(call asdf-make,tvlisp)

# tvlisp on the tv2 CLOS kernel (a separate binary; the classic build is above).
tvlisp-tv2: tvlisp.asd src/tv2-main.lisp $(FRAMEWORK) $(TV2)
	$(call asdf-make,tvlisp/tv2)

run: tvlisp
	./tvlisp

run-tv2: tvlisp-tv2
	./tvlisp-tv2

# Full test: the headless suite plus the classic + tv2 pty smoke tests.
test: test-lisp test-pty test-pty-tv2

# Headless unit suite (REPL backend, debugger, inspector, thread monitor).
# FiveAM is a test-only dependency, restored by `ocicl install`.
test-lisp: tvlisp.asd $(wildcard src/*.lisp) tests/tvlisp-tests.lisp
	$(SBCL) --non-interactive \
	--eval '(require :asdf)' \
		--eval '(asdf:initialize-source-registry (list :source-registry (list :tree (uiop:getcwd)) (list :tree (merge-pathnames "../" (uiop:getcwd))) :inherit-configuration))' \
		--eval '(handler-bind ((warning (function muffle-warning))) (asdf:load-system :tvlisp/tests))' \
		--eval '(sb-ext:exit :code (if (zerop (tvision-tvlisp-tests:run-tests)) 0 1))'

# Drive the built ./tvlisp through a pty and assert on the screen (end-to-end).
test-pty: tvlisp tests/pty_smoke.py
	$(PYTHON) tests/pty_smoke.py ./tvlisp

# End-to-end smoke test of the tv2 build, driven by the Lisp-native
# tvision-pty-driver (sibling project ../tvision-pty-driver).
test-pty-tv2: tvlisp-tv2 tests/pty_smoke_tv2.lisp
	$(SBCL) --script tests/pty_smoke_tv2.lisp

clean:
	rm -f tvlisp tvlisp-tv2
	rm -rf $(HOME)/.cache/common-lisp/*tvlisp* 2>/dev/null || true

help:
	@echo "Targets: all (default), tvlisp, tvlisp-tv2, run, run-tv2, test, clean"
