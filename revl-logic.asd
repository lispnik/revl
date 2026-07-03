;;;; revl-logic.asd --- revl's framework-agnostic Lisp logic.
;;;;
;;;; The pure logic layer revl shares between its classic (tvision) UI and its
;;;; revision UI: no view dependencies, so it builds on the revision foundation alone (for
;;;; the TVISION package + outline-node).  The revision IDE reuses these through hooks
;;;; instead of pulling in the whole classic application.

(asdf:defsystem "revl-logic"
  :description "Framework-agnostic Lisp logic for revl (indent, sexp analysis, REPL backend, git/grep, profiling, CLHS) — shared by the classic and revision UIs."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("revision")
  :serial t
  :components ((:module "logic"
                :serial t
                :components ((:file "package")        ; the TVISION-REVL app package
                             (:file "lisp-text")
                             (:file "repl-backend")
                             (:file "inspect")         ; object->outline (inspector model)
                             (:file "app-logic")))))   ; sexp/git/grep/profile/http/CLHS
