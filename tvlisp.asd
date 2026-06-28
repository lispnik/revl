;;;; tvlisp.asd --- A Lisp REPL / mini-IDE built on the tvision Turbo Vision port.
;;;;
;;;; Depends on `tvision', a sibling project at ../tvision.  ocicl resolves it
;;;; through the symlink in ./systems/tvision (and `make' adds the project tree
;;;; to the ASDF source registry explicitly), so no global config is required.

(asdf:defsystem "tvlisp"
  :description "A standalone Lisp REPL / mini-IDE on the Turbo Vision port."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("tvision")
  :serial t
  ;; `asdf:make :tvlisp` dumps a standalone `tvlisp' REPL executable.
  :build-operation "program-op"
  :build-pathname "tvlisp"
  :entry-point "tvision-tvlisp:toplevel"
  :components ((:module "src"
                :serial t
                ;; threadmon + repl extend the TVISION package but are
                ;; application-level (not part of the core tvision library)
                :components ((:file "threadmon")
                             (:file "repl")
                             (:file "lisp-text")
                             (:file "lisp-editor")
                             (:file "tvlisp")))))

(asdf:defsystem "tvlisp/tests"
  :description "Tests for tvlisp's REPL / debugger / inspector / thread monitor.
Only the tests depend on FiveAM; the tvlisp binary has no external dependencies."
  :depends-on ("tvlisp" "fiveam")
  :serial t
  :components ((:module "tests"
                :components ((:file "tvlisp-tests"))))
  :perform (asdf:test-op (o c)
             (uiop:symbol-call :tvision-tvlisp-tests :run-tests)))
