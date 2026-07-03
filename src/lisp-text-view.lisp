;;;; lisp-text-view.lisp --- classic-TTEXT-VIEW Lisp services (colourise, indent).
;;;;
;;;; The view-coupled half of tvlisp's Lisp text intelligence: the pieces that
;;;; operate on a live classic text view (text-cur-line / text-string / set-line
;;;; / ensure-visible) or install into the framework's *TEXT-COLORIZER* /
;;;; *PAREN-MATCHER* hooks.  The pure, offset-based core (%LISP-INDENT-AT,
;;;; %PAREN-MATCH-OFFSET + the indent tables) lives in logic/lisp-text.lisp
;;;; (system `tvlisp-logic'), which this file builds on.
;;;;
;;;; Extends the TVISION package like the rest of the classic tvlisp UI.

(in-package #:tvision)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(lisp-indent-line lisp-indent-region lisp-indent-sexp match-paren-jump)
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

;;; --- bracket matching (on a live view) -------------------------------------

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

;;; --- Lisp auto-indent (on a live view) -------------------------------------

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
