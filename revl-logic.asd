;;;; revl-logic.asd --- revl's framework-agnostic Lisp logic.
;;;;
;;;; revl's pure Lisp logic, in its own REVL-LOGIC package: no view dependencies,
;;;; so it builds on the revision foundation alone (for the OUTLINE-NODE type).  The
;;;; revl IDE wires it into the revision toolkit through hooks (see revl/src/main.lisp).

(asdf:defsystem "revl-logic"
  :description "Framework-agnostic Lisp logic for revl (indent, sexp analysis, REPL backend, object->outline, git/grep, profiling, CLHS)."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("revision")
  :serial t
  :components ((:module "logic"
                :serial t
                :components ((:file "package")        ; the REVL-LOGIC package
                             (:file "lisp-text")       ; indentation + bracket matching
                             (:file "repl-backend")    ; read/eval/print, completion, history vars
                             (:file "inspect")         ; object->outline (inspector model)
                             (:file "app-logic")        ; sexp/git/grep/profile/http/CLHS
                             (:file "git-status")))))   ; git porcelain for the status window
