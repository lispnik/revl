;;;; lisp-text.lisp --- pure Common Lisp text intelligence (indent + paren match).
;;;;
;;;; The framework-agnostic core of tvlisp's Lisp editing smarts: functions that
;;;; take a STRING (+ char offset) and return a result, with NO dependency on any
;;;; view.  This is what the revision editor reuses through hooks (*LISP-INDENTER* ->
;;;; %LISP-INDENT-AT, *PAREN-MATCHER* -> %PAREN-MATCH-OFFSET), so it lives in the
;;;; shared `tvlisp-logic' system rather than the classic UI.  The classic,
;;;; view-coupled services (colouriser install, indent-line/-region/-sexp on a
;;;; live TTEXT-VIEW, match-paren-jump) live in src/lisp-text-view.lisp.
;;;;
;;;; It extends the TVISION package (the package now belongs to the revision base), so
;;;; the revision hooks can FIND-SYMBOL these by name in :TVISION.

(in-package #:tvision)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(*lisp-indent-hook*) '#:tvision))

;;; --- bracket matching (offset-based) ---------------------------------------

(defun %paren-match-offset (str target)
  "STR[TARGET] is ( or ).  Return the matching paren's offset, or NIL.  Skips
strings, ; comments and #\\ char literals."
  (let ((n (length str)) (stack '()) (i 0))
    (loop while (< i n) do
      (let ((c (char str i)))
        (cond
          ((char= c #\;) (loop while (and (< i n) (char/= (char str i) #\Newline)) do (incf i)))
          ((char= c #\")
           (incf i)
           (loop while (< i n) do
             (let ((d (char str i))) (incf i)
               (cond ((char= d #\\) (incf i)) ((char= d #\") (return))))))
          ((and (char= c #\#) (< (1+ i) n) (char= (char str (1+ i)) #\\)) (incf i 3))
          ((char= c #\() (push i stack) (incf i))
          ((char= c #\))
           (let ((open (and stack (pop stack))))
             (when (and open (or (= open target) (= i target)))
               (return-from %paren-match-offset (if (= i target) open i))))
           (incf i))
          (t (incf i)))))
    nil))

;;; --- Lisp auto-indent ------------------------------------------------------

;;; Indentation specs, after Emacs cl-indent: N = number of "distinguished"
;;; arguments (which indent +4); the rest of the body indents +2.  Operators
;;; with no spec are ordinary calls -- their args align under the first one.
(defparameter *lisp-indent-specs* (make-hash-table :test 'equal))

(dolist (spec '(("defun" . 2) ("defmacro" . 2) ("defmethod" . 2) ("defgeneric" . 2)
                ("defvar" . 1) ("defparameter" . 1) ("defconstant" . 1)
                ("define-condition" . 2) ("defclass" . 2) ("defstruct" . 1)
                ("defpackage" . 1) ("define-symbol-macro" . 1) ("define-modify-macro" . 2)
                ("lambda" . 1) ("let" . 1) ("let*" . 1) ("flet" . 1) ("labels" . 1)
                ("macrolet" . 1) ("symbol-macrolet" . 1)
                ("when" . 1) ("unless" . 1) ("case" . 1) ("ccase" . 1) ("ecase" . 1)
                ("typecase" . 1) ("etypecase" . 1) ("ctypecase" . 1) ("if" . 2)
                ("dolist" . 1) ("dotimes" . 1) ("do" . 2) ("do*" . 2)
                ("multiple-value-bind" . 2) ("destructuring-bind" . 2)
                ("with-open-file" . 1) ("with-output-to-string" . 1)
                ("with-input-from-string" . 1) ("with-slots" . 2) ("with-accessors" . 2)
                ("handler-case" . 1) ("handler-bind" . 1) ("restart-case" . 1)
                ("unwind-protect" . 1) ("block" . 1) ("catch" . 1) ("return-from" . 1)
                ("eval-when" . 1) ("prog1" . 1) ("prog2" . 2)
                ("progn" . 0) ("cond" . 0) ("tagbody" . 0) ("locally" . 0)
                ("ignore-errors" . 0)))
  (setf (gethash (car spec) *lisp-indent-specs*) (cdr spec)))

(defvar *lisp-indent-hook* nil
  "Optional (OPERATOR-NAME-STRING) -> N | NIL, consulted for operators not in
*LISP-INDENT-SPECS* -- e.g. to indent a user macro with a &body argument like a
special form.")

(defun %lisp-operator-spec (name)
  "The distinguished-argument count for operator NAME, or NIL for an ordinary
call (whose args align under the first argument)."
  (multiple-value-bind (n found) (gethash name *lisp-indent-specs*)
    (cond (found n)
          (*lisp-indent-hook* (funcall *lisp-indent-hook* name))
          (t nil))))

(defun %lisp-token (str i)
  "Read the symbol token starting at index I in STR, lowercased."
  (let ((n (length str)) (j i))
    (loop while (and (< j n)
                     (not (member (char str j)
                                  '(#\Space #\Tab #\Newline #\Return #\( #\) #\" #\;))))
          do (incf j))
    (string-downcase (subseq str i j))))

(defparameter *lisp-loop-keywords*
  ;; enough clause-introducing keywords that "the last keyword" tracks correctly
  (let ((h (make-hash-table :test 'equal)))
    (dolist (k '("for" "as" "with" "and" "do" "doing" "collect" "collecting"
                 "append" "appending" "nconc" "nconcing" "sum" "summing" "count"
                 "counting" "maximize" "maximizing" "minimize" "minimizing"
                 "when" "unless" "if" "else" "end" "while" "until" "repeat"
                 "always" "never" "thereis" "return" "initially" "finally"
                 "named" "into" "being" "then" "across" "in" "on" "=" "by"))
      (setf (gethash k h) t))
    h))

(defparameter *lisp-loop-conditionals* '("when" "unless" "if" "else"))

(defun %loop-last-keyword (str start off)
  "The last top-level loop keyword (lowercased) before OFF in the loop starting
at index START, or \"\".  Used to detect when a clause body follows a when/if."
  (let ((n (min off (length str))) (i (1+ start)) (depth 0) (last ""))
    (loop while (< i n) do
      (let ((c (char str i)))
        (cond
          ((char= c #\;) (loop while (and (< i n) (char/= (char str i) #\Newline)) do (incf i)))
          ((char= c #\")
           (incf i)
           (loop while (< i n) do
             (let ((d (char str i))) (incf i) (cond ((char= d #\\) (incf i)) ((char= d #\") (return))))))
          ((and (char= c #\#) (< (1+ i) n) (char= (char str (1+ i)) #\\)) (incf i 3))
          ((char= c #\() (incf depth) (incf i))
          ((char= c #\)) (when (plusp depth) (decf depth)) (incf i))
          ((member c '(#\Space #\Tab #\Newline #\Return)) (incf i))
          (t (let ((tok (%lisp-token str i)))
               (when (and (zerop depth) (gethash tok *lisp-loop-keywords*)) (setf last tok))
               (incf i (max 1 (length tok))))))))
    last))

(defun %lisp-indent-at (str off)
  "The indentation column for a fresh line broken at OFF in STR.  Each open form
on the stack tracks (OPEN-COL ELEMENT-COUNT HEAD FIRST-ARG-COL DATAP OPEN-INDEX);
DATAP marks a quoted/binding/literal list (its elements align, no body rule)."
  (let ((n (min off (length str))) (i 0) (col 0) (stack '()) (fresh t)
        (q nil) (comma nil))   ; q: after ' or `  ;  comma: after ,
    (flet ((start-elem (istart is-token)
             (when stack
               (let ((e (car stack)))
                 (incf (second e))
                 (cond ((= (second e) 1) (setf (third e) (if is-token (%lisp-token str istart) "")))
                       ((= (second e) 2) (setf (fourth e) col)))))))
      (loop while (< i n) do
        (let ((c (char str i)))
          (cond
            ((char= c #\Newline) (setf col 0 fresh t) (incf i))
            ((char= c #\;) (loop while (and (< i n) (char/= (char str i) #\Newline)) do (incf i)))
            ((member c '(#\Space #\Tab #\Return)) (incf i) (incf col) (setf fresh t))
            ((or (char= c #\') (char= c #\`)) (setf q t comma nil) (incf i) (incf col))
            ((char= c #\,) (setf comma t q nil) (incf i) (incf col))
            ((char= c #\")
             (start-elem i nil)
             (incf i) (incf col)
             (loop while (< i n) do
               (let ((d (char str i)))
                 (cond ((char= d #\Newline) (setf col 0 i (1+ i)))
                       ((char= d #\\) (incf i 2) (incf col 2))
                       ((char= d #\") (incf i) (incf col) (return))
                       (t (incf i) (incf col)))))
             (setf fresh nil q nil comma nil))
            ((and (char= c #\#) (< (1+ i) n) (char= (char str (1+ i)) #\\))
             (start-elem i nil) (incf i 3) (incf col 3) (setf fresh nil q nil comma nil))
            ((char= c #\()
             (start-elem i nil)
             (push (list col 0 nil nil
                         (or q (and stack (fifth (car stack)) (not comma)))  ; quoted/data?
                         i)
                   stack)
             (setf q nil comma nil fresh t) (incf i) (incf col))
            ((char= c #\)) (when stack (pop stack)) (incf i) (incf col) (setf fresh nil q nil comma nil))
            (t (when fresh (start-elem i t)) (incf i) (incf col) (setf fresh nil q nil comma nil)))))
      (if (null stack)
          0
          (destructuring-bind (open-col nelems head first-arg-col datap open-idx) (car stack)
            (let ((spec (and head (%lisp-operator-spec head))))
              (cond
                ((zerop nelems) (1+ open-col))               ; immediately after "("
                (datap (1+ open-col))                        ; quoted/binding/literal list
                ((and (equal head "loop") first-arg-col)     ; loop: clause / conditional body
                 (if (member (%loop-last-keyword str open-idx off) *lisp-loop-conditionals*
                             :test #'string=)
                     (+ first-arg-col 2)
                     first-arg-col))
                (spec (if (<= nelems spec) (+ open-col 4) (+ open-col 2)))
                ((or (string= head "")                       ; data list by head shape
                     (let ((c0 (char head 0))) (or (digit-char-p c0) (char= c0 #\#))))
                 (1+ open-col))
                (first-arg-col first-arg-col)                ; ordinary call: align under arg 1
                (t (1+ open-col)))))))))                     ; head only, no spec
