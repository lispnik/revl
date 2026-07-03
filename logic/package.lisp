;;;; package.lisp --- the TVISION-TVLISP package (tvlisp's app package).
;;;;
;;;; Defined here in tvlisp-logic so the shared logic and the classic UI both
;;;; live in it, with the logic loadable on tv2 alone.

(defpackage #:tvision-tvlisp
  (:use #:common-lisp #:tvision)
  (:export #:main #:toplevel))

