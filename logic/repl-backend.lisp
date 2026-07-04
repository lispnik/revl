;;;; repl-backend.lisp --- the REPL "backend": completion + evaluation.
;;;;
;;;; The framework-agnostic in-process "backend" the REPL view is built on (the
;;;; operation set Lem gets from micros/swank, but called directly since the TUI
;;;; *is* the Lisp image).  Pure read/eval/print + symbol completion + the CL
;;;; history-variable machinery -- NO view dependency, so the revision REPL reuses it
;;;; through hooks (*REPL-EVAL-FN* / *REPL-COMPLETIONS-FN*).

(in-package #:revl-logic)

;;; --- per-listener CL history variables -------------------------------------

(defparameter +repl-hist-symbols+ '(* ** *** / // /// + ++ +++ -)
  "The CL REPL history variables, in shift order.  Each listener keeps its own
values (in the view) and binds these symbols with PROGV around evaluation, so
concurrent listeners never clobber one another's `*'/`+'/`/'.")

;;; ===========================================================================
;;; Backend: introspection + evaluation (the "micros-equivalent" operations)
;;; ===========================================================================

(defun %symbol-char-p (ch)
  (or (alphanumericp ch) (find ch "+-*/<>=!?._%&$~^@:[]{}")))

(defun %prefixp (prefix string)
  (and (<= (length prefix) (length string))
       (string= prefix string :end2 (length prefix))))

(defun %flexp (sub string)
  "True when SUB occurs in STRING as a subsequence (its characters appear in
order, not necessarily contiguous) — the basis of flex/fuzzy completion, so
\"mvb\" matches \"multiple-value-bind\".  SUB and STRING are compared as given."
  (let ((i 0) (n (length sub)))
    (and (plusp n)
         (progn (loop for ch across string
                      while (< i n)
                      when (char= ch (char sub i)) do (incf i))
                (= i n)))))

(defun %flex-score (sub str)
  "If SUB is a subsequence of STR *and its first matched character begins a word*
(string start or just after a separator), return a score where word-initial
matches count more (so \"mvb\" ranks Multiple-Value-Bind above mid-word hits);
otherwise NIL."
  (let ((i 0) (n (length sub)) (score 0) (sep t) (first t))
    (when (plusp n)
      (loop for ch across str do
        (cond ((and (< i n) (char= ch (char sub i)))
               (when (and first (not sep)) (return-from %flex-score nil))  ; must start a word
               (incf score (if sep 10 1))
               (incf i) (setf first nil sep nil))
              (t (setf sep (not (alphanumericp ch))))))
      (when (= i n) score))))

(defun %flex-completions (token package)
  "Ranked flex/fuzzy completions of TOKEN in PACKAGE: word-boundary matches
first, then shorter, then alphabetical; capped so a loose token can't flood the
popup."
  (let ((scored '()))
    (do-symbols (s package)
      (let* ((n (string-downcase (symbol-name s)))
             (sc (and (not (string= n token)) (%flex-score token n))))
        (when sc (push (cons n sc) scored))))
    (setf scored (delete-duplicates scored :key #'car :test #'string=))
    (setf scored (sort scored
                       (lambda (a b)
                         (cond ((/= (cdr a) (cdr b)) (> (cdr a) (cdr b)))
                               ((/= (length (car a)) (length (car b)))
                                (< (length (car a)) (length (car b))))
                               (t (string< (car a) (car b)))))))
    (mapcar #'car (subseq scored 0 (min 40 (length scored))))))

(defun longest-common-prefix (strings)
  (if (null strings) ""
      (let ((p (first strings)))
        (dolist (s (rest strings) p)
          (let ((m (mismatch p s))) (when m (setf p (subseq p 0 m))))))))

(defun repl-backend-completions (token package)
  "Return sorted completion strings for TOKEN in PACKAGE (micros: simple-
completions).  Handles `pkg:name' / `pkg::name' qualified tokens."
  (let ((out '()) (colon (position #\: token)))
    (flet ((collect (sym name &optional prefix)
             (declare (ignore sym))
             (pushnew (if prefix (concatenate 'string prefix name) name)
                      out :test #'string=)))
      (if colon
          (let* ((pkgname (subseq token 0 colon))
                 (double (and (< (1+ colon) (length token))
                              (char= (char token (1+ colon)) #\:)))
                 (rest (string-downcase (subseq token (if double (+ colon 2) (1+ colon)))))
                 (sep (if double "::" ":"))
                 (pkg (find-package (string-upcase pkgname))))
            (when pkg
              (if double
                  (do-symbols (s pkg)
                    (when (and (eq (symbol-package s) pkg)
                               (%prefixp rest (string-downcase (symbol-name s))))
                      (collect s (string-downcase (symbol-name s))
                               (concatenate 'string pkgname sep))))
                  (do-external-symbols (s pkg)
                    (when (%prefixp rest (string-downcase (symbol-name s)))
                      (collect s (string-downcase (symbol-name s))
                               (concatenate 'string pkgname sep)))))))
          (let ((lc (string-downcase token)))
            (do-symbols (s package)
              (let ((n (string-downcase (symbol-name s))))
                (when (%prefixp lc n) (collect s n))))
            ;; flex/fuzzy fallback when prefix completion can't extend the token
            ;; (NB: the token may already be interned -- e.g. by the live arglist
            ;; echo -- so it prefix-matches itself; treat "only the token" as no
            ;; useful prefix completion).  Return the ranked matches directly,
            ;; bypassing the alphabetical sort, so "mvb" -> multiple-value-bind.
            (when (and (>= (length lc) 2)
                       (notany (lambda (n) (> (length n) (length lc))) out))
              (let ((flex (%flex-completions lc package)))
                (when flex (return-from repl-backend-completions flex)))))))
    (sort (remove-duplicates out :test #'string=) #'string<)))

(defmacro with-repl-history ((hist new-hist) &body body)
  "Bind the CL history variables to the values in HIST (a list aligned with
+repl-hist-symbols+, or NIL for a fresh set) for the dynamic extent of BODY,
then capture their resulting values into NEW-HIST.  PROGV makes the binding
thread-local, so concurrent listeners never share `*'/`+'/`/'."
  `(progv +repl-hist-symbols+ (copy-list (or ,hist (make-list 10)))
     (multiple-value-prog1 (progn ,@body)
       (setf ,new-hist (mapcar #'symbol-value +repl-hist-symbols+)))))

(defun repl-backend-eval (input package error-handler &optional hist)
  "Read+eval all forms in INPUT under PACKAGE, capturing output.  Maintains the
standard history vars (-, +/++/+++, */**/***, ///) starting from HIST (the
listener's prior values).  ERROR-HANDLER is invoked with the condition inside
HANDLER-BIND (it must transfer control).  Return (values output-string results
package errored new-hist)."
  (let ((*package* package) (results '()) (errored nil) (last nil) (new-hist hist))
    (let ((output
            (with-output-to-string (out)
              (let ((*standard-output* out) (*error-output* out) (*trace-output* out))
                (with-repl-history (hist new-hist)
                  (restart-case
                      (handler-bind ((error (lambda (e) (setf last e)
                                              (funcall error-handler e))))
                        (with-input-from-string (in input)
                          (loop for form = (read in nil :repl-eof)
                                until (eq form :repl-eof)
                                do (setf - form)
                                   (let ((vals (multiple-value-list (eval form))))
                                     (push vals results)
                                     ;; shift the CL history variables
                                     (setf +++ ++  ++ +  + form
                                           /// //  // /  / vals
                                           *** **  ** *  * (first vals))))))
                    (repl-abort () (setf errored t))))
                (when (and errored last)
                  (format out "~&;; ~(~a~): ~a~%" (type-of last) last))))))
      (values output (nreverse results) *package* errored new-hist))))
