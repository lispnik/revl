;;;; lisp-editor.lisp --- TLispFileEditor: a file editor specialised for Lisp.
;;;;
;;;; The plain TFILE-EDITOR (in the tvision framework) is language-agnostic.
;;;; The Lisp-specific editing behaviour -- syntax colouring, auto-indent on
;;;; Return and re-indent on Tab -- lives here, in the tvlisp application, as a
;;;; subclass.  It is built on the Lisp text utilities the framework provides
;;;; (the indent engine %LISP-INDENT-AT / LISP-INDENT-LINE / LISP-INDENT-REGION
;;;; and the highlighter behind the TEXT-HIGHLIGHT slot), so it only wires those
;;;; into the editor's keystrokes.
;;;;
;;;; Like repl.lisp and threadmon.lisp, this file extends the TVISION package
;;;; (it leans on framework internals), so it (in-package #:tvision) and exports
;;;; its public symbol here.

(in-package #:tvision)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(tlisp-file-editor) '#:tvision))

(defclass tlisp-file-editor (tfile-editor)
  ()
  (:documentation "A TFILE-EDITOR specialised for editing Common Lisp source:
syntax colouring on, auto-indent on Return, and re-indent on Tab."))

(defmethod initialize-instance :after ((ed tlisp-file-editor) &key)
  (setf (text-highlight ed) t))   ; Lisp syntax colouring on

(defmethod text-return ((ed tlisp-file-editor))
  "Break the line and auto-indent the new one for Lisp."
  (let ((indent (%lisp-indent-at (text-string ed) (%cursor-offset ed))))
    (split-line-at-cursor ed)
    (dotimes (_ indent) (insert-char-at-cursor ed #\Space))))

(defmethod text-tab ((ed tlisp-file-editor))
  "Tab re-indents: the selected lines if there is a selection, else the current
line."
  (if (text-anchor ed)
      (multiple-value-bind (s e) (selection-range ed)
        (lisp-indent-region ed (car s) (car e)))
      (lisp-indent-line ed (text-cur-line ed))))

;; New edit windows in this application are Lisp editors by default.
(setf *file-editor-class* 'tlisp-file-editor)
