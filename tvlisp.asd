;;;; tvlisp.asd --- a SLIME-class Lisp IDE on the tv2 CLOS-native framework.
;;;;
;;;; tvlisp is built on `tv2' (../tvision/tv2), the CLOS-native framework, plus
;;;; `tvlisp-logic' (its framework-agnostic Lisp logic).  ocicl resolves the
;;;; siblings through ./systems and `make' adds the project tree to the ASDF
;;;; source registry, so no global config is required.
;;;;
;;;; `asdf:make :tvlisp/tv2` dumps the standalone `tvlisp-tv2' executable.

(asdf:defsystem "tvlisp"
  :description "tvlisp: a SLIME-class Common Lisp IDE on the tv2 framework."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("tv2" "tvlisp-logic")
  :serial t
  :build-operation "program-op"
  :build-pathname "tvlisp-tv2"
  :entry-point "tvlisp-tv2:toplevel"
  :components ((:module "src"
                :components ((:file "tv2-main")))))
