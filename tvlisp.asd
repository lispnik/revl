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
  :depends-on ("tvision" "tvlisp-logic")
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
                             (:file "lisp-text-view")   ; view-coupled half; pure core is in tvlisp-logic
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

;;; tvlisp on the experimental tv2 CLOS kernel (../tvision/tv2).  Every tvlisp
;;; window has been rebuilt on tv2; this system launches that IDE shell.  It is
;;; separate so the classic `tvlisp' build above is unaffected.
;;; `asdf:make :tvlisp/tv2` dumps a standalone `tvlisp-tv2' executable.
(asdf:defsystem "tvlisp/tv2"
  :description "tvlisp running on the experimental tv2 CLOS-native kernel."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  ;; depends on the tv2 toolkit + tvlisp's framework-agnostic logic ONLY -- NOT
  ;; the classic `tvlisp' app.  So the tv2 IDE reuses tvlisp's real logic
  ;; (indenter, eval backend, sexp/git/grep/profile/CLHS) without loading any of
  ;; the classic tvision view hierarchy.  (object->outline stays classic; the tv2
  ;; inspector uses its built-in fallback.)
  :depends-on ("tv2" "tvlisp-logic")
  :serial t
  :build-operation "program-op"
  :build-pathname "tvlisp-tv2"
  :entry-point "tvlisp-tv2:toplevel"
  :components ((:module "src"
                :components ((:file "tv2-main")))))
