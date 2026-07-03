;;;; tvlisp.asd --- a SLIME-class Lisp IDE on the tv2 CLOS-native framework.
;;;;
;;;; tvlisp is built on `tv2' (../tvision/tv2), the CLOS-native framework, plus
;;;; `tvlisp-logic' (its framework-agnostic Lisp logic).  ocicl resolves the
;;;; siblings through ./systems and `make' adds the project tree to the ASDF
;;;; source registry, so no global config is required.
;;;;
;;;; `asdf:make :tvlisp` dumps the standalone `tvlisp' executable.

(asdf:defsystem "tvlisp"
  :description "tvlisp: a SLIME-class Common Lisp IDE on the tv2 framework."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("tv2" "tvlisp-logic")
  :serial t
  :build-operation "program-op"
  :build-pathname "tvlisp"
  :entry-point "tvlisp-tv2:toplevel"   ; TVLISP-TV2 is the entry package (see src/tv2-main.lisp)
  :components ((:module "src"
                :components ((:file "tv2-main")))))
