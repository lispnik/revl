;;;; package.lisp --- the REVL-LOGIC package: revl's framework-agnostic Lisp logic.
;;;;
;;;; Indentation, sexp analysis, the REPL backend, object->outline, git/grep,
;;;; profiling and CLHS lookup -- no view dependencies (it builds on the revision
;;;; foundation for the OUTLINE-NODE type alone).  The revl IDE wires it into the
;;;; revision toolkit through hooks; see revl/src/main.lisp.

(defpackage #:revl-logic
  (:use #:common-lisp #:revision)
  (:documentation "revl's framework-agnostic Lisp logic: indentation, sexp analysis,
the REPL backend, object->outline, git/grep, profiling, and CLHS lookup.")
  (:export #:object->outline))

;; The inspector model builds revision's OUTLINE-NODE trees; import its struct API
;; (internal to revision) so INSPECT.LISP can use it unqualified.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(revision::make-outline-node revision::outline-node-setter revision::outline-node-expanded)
          '#:revl-logic))
