;;;; tv2-main.lisp --- tvlisp running on the experimental tv2 CLOS kernel.
;;;;
;;;; The classic tvlisp IDE is built on the original `tvision' framework.  Every
;;;; tvlisp window has also been rebuilt on `tv2', the CLOS-native re-architecture
;;;; of the framework (see ../tvision/tv2/README.md).  This is the entry point
;;;; for that build: it launches the tv2 IDE shell (a menu of the ported
;;;; windows).  It lives in its own system (`tvlisp/tv2') so the classic build
;;;; and binary are untouched.

(defpackage #:tvlisp-tv2
  (:use #:cl)
  (:documentation "tvlisp on the tv2 kernel.")
  (:export #:main #:toplevel))

(in-package #:tvlisp-tv2)

;;; --- migration: reuse the classic tvlisp app's real logic on tv2 windows ----
;;; Stage 1: the editor's Lisp indentation.  tv2's editor calls *LISP-INDENTER*
;;; for a fresh line; we point it at tvlisp's actual indent engine
;;; (TVISION::%LISP-INDENT-AT), so the tv2 editor indents exactly like tvlisp.

(defun %line-offset (te line)
  "Char offset where LINE begins in TE's buffer."
  (loop for i below line sum (1+ (length (tv2::te-line te i)))))

(defun tvlisp-indent (te)
  "Indent a fresh line using the classic tvlisp Lisp indenter."
  (or (ignore-errors
       (funcall (find-symbol "%LISP-INDENT-AT" :tvision)
                (tv2:te-text te) (%line-offset te (tv2::te-cy te))))
      0))

(defun install-tvlisp-logic ()
  "Inject tvlisp's real logic into the tv2 toolkit (extended each migration stage)."
  (setf tv2:*lisp-indenter* #'tvlisp-indent))

(defun main ()
  "Run the tv2-based tvlisp IDE until the user quits the launcher."
  (install-tvlisp-logic)
  (tv2:run-app))

(defun toplevel ()
  "Dumped-executable entry point: run the IDE, report a fatal error cleanly, exit."
  (handler-case (main)
    (error (e) (format *error-output* "~&tvlisp-tv2: fatal: ~a~%" e)))
  (uiop:quit 0))
