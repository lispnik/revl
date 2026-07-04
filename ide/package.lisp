;;;; package.lisp --- the REVL package: the Lisp IDE on the revision toolkit.
;;;;
;;;; revl USES revision, so the toolkit's public API is available unqualified here;
;;;; anything the IDE still reaches for as revision::internal is a signal that the
;;;; symbol should either be exported (public toolkit API) or the code restructured.

(defpackage #:revl
  (:use #:common-lisp #:revision)
  (:documentation "revl: a SLIME-class Common Lisp IDE on the revision framework.")
  (:export #:main #:toplevel))
