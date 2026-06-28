;;;; lisp-text.lisp --- Common Lisp text intelligence for the editor & REPL.
;;;;
;;;; The tvision framework is language-agnostic: its text view colours lines
;;;; through *TEXT-COLORIZER* and accents brackets through *PAREN-MATCHER* (both
;;;; NIL by default).  This file -- part of the tvlisp application -- supplies
;;;; the Common Lisp implementations and installs them:
;;;;
;;;;   * a syntax colouriser (comments, strings, char literals, keywords), with
;;;;     multi-line string state;
;;;;   * bracket matching (match-paren-jump, and the matching-paren accent);
;;;;   * an Emacs cl-indent-style auto-indent engine (per-operator specs, LOOP
;;;;     awareness) behind lisp-indent-line / -region / -sexp.
;;;;
;;;; Like repl.lisp / threadmon.lisp / lisp-editor.lisp it extends the TVISION
;;;; package (it builds on the framework's text internals) and exports the
;;;; symbols that were formerly part of the library's public surface.

(in-package #:tvision)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(lisp-indent-line lisp-indent-region lisp-indent-sexp
            *lisp-indent-hook* match-paren-jump)
          '#:tvision))

;;; --- syntax colouriser -------------------------------------------------------

(defun %lisp-symchar-p (c)
  (or (alphanumericp c) (find c "+-*/@$%^&_=<>.~!?:")))

(defun %lisp-colorize (line base in-string)
  "Return (values ATTRS END-IN-STRING): ATTRS is a per-character attribute-byte
vector colouring LINE as Lisp (comments, strings, char literals, keywords).
IN-STRING means the line begins inside a \"...\" string from the line above."
  (let* ((n (length line))
         (attrs (make-array n :initial-element base :element-type '(unsigned-byte 8)))
         (comment (%synfg base 8)) (string (%synfg base 4)) (kw (%synfg base 14))
         (i 0) (instr in-string))
    (flet ((paint (a b attr) (loop for k from (max 0 a) below (min b n) do (setf (aref attrs k) attr))))
      (when instr
        (let ((end 0) (closed nil))
          (loop while (< end n) do
            (cond ((char= (char line end) #\\) (incf end 2))
                  ((char= (char line end) #\") (incf end) (setf closed t) (return))
                  (t (incf end))))
          (paint 0 (min end n) string)
          (setf instr (not closed) i (if closed end n))))
      (loop while (< i n) do
        (let ((c (char line i)))
          (cond
            ((char= c #\;) (paint i n comment) (setf i n))
            ((char= c #\")
             (let ((end (1+ i)) (closed nil))
               (loop while (< end n) do
                 (cond ((char= (char line end) #\\) (incf end 2))
                       ((char= (char line end) #\") (incf end) (setf closed t) (return))
                       (t (incf end))))
               (paint i (min end n) string)
               (setf instr (not closed) i (if closed end n))))
            ((and (char= c #\#) (< (1+ i) n) (char= (char line (1+ i)) #\\))
             (let ((end (min n (+ i 3))))
               (when (and (> end (+ i 2)) (alpha-char-p (char line (1- end))))
                 (loop while (and (< end n) (alphanumericp (char line end))) do (incf end)))
               (paint i end string) (setf i end)))
            ((and (char= c #\:) (or (zerop i) (not (%lisp-symchar-p (char line (1- i))))))
             (let ((end (1+ i)))
               (loop while (and (< end n) (%lisp-symchar-p (char line end))) do (incf end))
               (paint i end kw) (setf i end)))
            (t (incf i))))))
    (values attrs instr)))

;;; --- bracket matching --------------------------------------------------------

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

(defun %matching-parens (tv)
  "Return a list of two (LINE . COL) cells -- the paren at/just-before the
cursor and its match -- or NIL."
  (let* ((cl (text-cur-line tv)) (cc (text-cur-col tv))
         (line (nth-line tv cl)) (llen (length line)))
    (labels ((off (l c)
               (let ((o 0)) (dotimes (i l) (incf o (1+ (length (nth-line tv i))))) (+ o c)))
             (lc (o)
               (let ((l 0))
                 (loop (let ((ll (1+ (length (nth-line tv l)))))
                         (if (< o ll) (return (cons l o)) (progn (decf o ll) (incf l))))))))
      (let ((target (cond
                      ((and (< cc llen) (find (char line cc) "()")) (off cl cc))
                      ((and (> cc 0) (<= cc llen) (find (char line (1- cc)) "()")) (off cl (1- cc))))))
        (when target
          (let ((m (%paren-match-offset (text-string tv) target)))
            (when m (list (lc target) (lc m)))))))))

(defun match-paren-jump (tv)
  "Move the cursor to the paren matching the one at/just-before it.  Returns T
when it moved, NIL when there is no balanced paren at point."
  (let ((pair (%matching-parens tv)))
    (when pair
      (let ((dest (second pair)))                  ; (line . col) of the match
        (setf (text-cur-line tv) (car dest)
              (text-cur-col tv) (cdr dest))
        (ensure-visible tv)
        t))))

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

(defun lisp-indent-line (tv li)
  "Re-indent line LI of TV for Lisp (in place), keeping the cursor sensible."
  (when (< li (line-count tv))
    (let* ((line (nth-line tv li))
           (lead (let ((k 0))
                   (loop while (and (< k (length line)) (member (char line k) '(#\Space #\Tab)))
                         do (incf k))
                   k))
           (start-off (let ((o 0)) (dotimes (i li) (incf o (1+ (length (nth-line tv i))))) o))
           (want (%lisp-indent-at (text-string tv) start-off))
           (new (concatenate 'string (make-string want :initial-element #\Space) (subseq line lead))))
      (unless (string= new line)
        (set-line tv li new)
        (when (= (text-cur-line tv) li)
          (let ((cc (text-cur-col tv)))
            (setf (text-cur-col tv) (if (<= cc lead) want (max 0 (+ cc (- want lead)))))))
        (text-update-limit tv)))))

(defun lisp-indent-region (tv l0 l1)
  "Re-indent lines L0..L1 top-to-bottom (each sees the lines above reindented)."
  (loop for li from (max 0 l0) to (min l1 (1- (line-count tv))) do (lisp-indent-line tv li)))

(defun %toplevel-span (str off)
  "Return (values START END) char-offsets of the top-level form containing OFF."
  (let ((n (length str)) (i 0) (depth 0) (start nil))
    (loop while (< i n) do
      (let ((c (char str i)))
        (cond
          ((char= c #\;) (loop while (and (< i n) (char/= (char str i) #\Newline)) do (incf i)))
          ((char= c #\")
           (incf i)
           (loop while (< i n) do
             (let ((d (char str i))) (incf i) (cond ((char= d #\\) (incf i)) ((char= d #\") (return))))))
          ((and (char= c #\#) (< (1+ i) n) (char= (char str (1+ i)) #\\)) (incf i 3))
          ((char= c #\() (when (zerop depth) (setf start i)) (incf depth) (incf i))
          ((char= c #\))
           (incf i) (when (plusp depth) (decf depth))
           (when (and (zerop depth) start (<= start off) (<= off i))
             (return-from %toplevel-span (values start i)))
           (when (zerop depth) (setf start nil)))
          (t (incf i)))))
    (values nil nil)))

(defun lisp-indent-sexp (tv)
  "Re-indent the whole top-level form containing the cursor."
  (multiple-value-bind (s e) (%toplevel-span (text-string tv) (%cursor-offset tv))
    (when s (lisp-indent-region tv (car (%offset->lc tv s)) (car (%offset->lc tv e))))))

;;; --- install these Common Lisp services into the framework's text views -----

(setf *text-colorizer* #'%lisp-colorize
      *paren-matcher*  #'%matching-parens)
