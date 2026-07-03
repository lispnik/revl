;;;; package.lisp --- the REVISION-REVL package (revl's app package).
;;;;
;;;; Defined here in revl-logic so the shared logic and the classic UI both
;;;; live in it, with the logic loadable on revision alone.

(defpackage #:revl-logic
  (:use #:common-lisp #:revision)
  (:export #:main #:toplevel))

