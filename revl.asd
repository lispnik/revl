;;;; revl.asd --- a SLIME-class Lisp IDE on the revision CLOS-native framework.
;;;;
;;;; revl is built on `revision' (../tvision/revision), the CLOS-native framework, plus
;;;; `revl-logic' (its framework-agnostic Lisp logic).  ocicl resolves the
;;;; siblings through ./systems and `make' adds the project tree to the ASDF
;;;; source registry, so no global config is required.
;;;;
;;;; `asdf:make :revl` dumps the standalone `revl' executable.

(asdf:defsystem "revl"
  :description "revl: a SLIME-class Common Lisp IDE on the revision framework."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("revision" "revl-logic")
  :serial t
  :build-operation "program-op"
  :build-pathname "revl"
  :entry-point "revl:toplevel"   ; REVL is the entry package (see src/main.lisp)
  :components ((:module "src"
                :components ((:file "main")))))
