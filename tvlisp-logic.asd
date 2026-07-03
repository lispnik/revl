;;;; tvlisp-logic.asd --- tvlisp's framework-agnostic Lisp logic.
;;;;
;;;; The pure logic layer tvlisp shares between its classic (tvision) UI and its
;;;; tv2 UI: no view dependencies, so it builds on the tv2 foundation alone (for
;;;; the TVISION package + outline-node).  The tv2 IDE reuses these through hooks
;;;; instead of pulling in the whole classic application.

(asdf:defsystem "tvlisp-logic"
  :description "Framework-agnostic Lisp logic for tvlisp (indent, sexp analysis, REPL backend, git/grep, profiling, CLHS) — shared by the classic and tv2 UIs."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("tv2")
  :serial t
  :components ((:module "logic"
                :serial t
                :components ((:file "package")        ; the TVISION-TVLISP app package
                             (:file "lisp-text")
                             (:file "repl-backend")
                             (:file "app-logic")))))   ; sexp/git/grep/profile/http/CLHS
