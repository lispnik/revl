;;;; revl.asd --- a SLIME-class Lisp IDE on the revision CLOS-native framework.
;;;;
;;;; revl is built on `revision' (../revision/revision), the CLOS-native framework, plus
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
  :depends-on ("revision" "revl-logic" "revision-term")   ; revision-term: the libvterm-backed Terminal window
  :serial t
  :build-operation "program-op"
  :build-pathname "revl"
  :entry-point "revl:toplevel"   ; REVL is the entry package (see src/main.lisp)
  :components ((:module "ide"                ; the Lisp-IDE windows (on revision's toolkit)
                :serial t
                :components ((:file "package")
                             (:file "threadmon")
                             (:file "browser")
                             (:file "project")
                             (:file "debugger")
                             (:file "repl")
                             (:file "inspect")
                             (:file "tools")
                             (:file "paredit")
                             (:file "nav")
                             (:file "compile")
                             (:file "editing")
                             (:file "sbcl")
                             (:file "docs")
                             (:file "desktop-ide")   ; REPL/table glue pulled out of the toolkit desktop
                             (:file "app")))
               (:module "src"
                :components ((:file "main")))))
