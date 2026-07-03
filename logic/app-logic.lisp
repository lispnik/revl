;;;; app-logic.lisp --- revl's framework-agnostic application logic.
;;;;
;;;; The pure, view-free helpers the revision IDE reuses through hooks: sexp analysis
;;;; (paredit/reorder), git status + grep for the project manager, the sb-sprof
;;;; profiler, HTTP fetch (curl), the HyperSpec URL map, buffer package/form
;;;; extraction.  Extracted from src/revl.lisp (the classic app UI) so the revision
;;;; build need not load the classic view hierarchy.  Builds on revision + earlier
;;;; revl-logic files alone.

(in-package #:revl-logic)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-introspect)
  (require :sb-sprof))

(defun %http-get (url)
  "Fetch URL with curl; return the body string, or NIL on failure."
  (handler-case
      (let* ((out (make-string-output-stream))
             (p (sb-ext:run-program "curl" (list "-fsSL" "--max-time" "20" url)
                                    :search t :output out :error nil :wait t)))
        (if (and p (eql 0 (sb-ext:process-exit-code p)))
            (get-output-stream-string out)
            nil))
    (error () nil)))

(defparameter +hyperspec-base+ "https://www.lispworks.com/documentation/HyperSpec/")
(defvar *hyperspec-map* nil
  "Lazy-loaded hash table mapping an upcased symbol name to its HyperSpec URL.")

(defun %load-hyperspec-map ()
  "Fetch and parse the HyperSpec Data/Map_Sym.txt -- alternating NAME / path
lines -- into a name -> URL hash table, or NIL on failure."
  (let ((txt (%http-get (concatenate 'string +hyperspec-base+ "Data/Map_Sym.txt"))))
    (when txt
      (let ((map (make-hash-table :test 'equal))
            (lines (with-input-from-string (s txt)
                     (loop for l = (read-line s nil nil) while l
                           collect (string-trim '(#\Return #\Space #\Tab) l)))))
        ;; paths are relative to the Data/ directory, e.g. "../Body/f_car_c.htm"
        (loop for (name path) on lines by #'cddr
              when (and name path (plusp (length name)) (plusp (length path))) do
                (let ((rel (if (eql 0 (search "../" path))
                               (subseq path 3)                       ; -> Body/...
                               (concatenate 'string "Data/" path))))
                  (setf (gethash (string-upcase name) map)
                        (concatenate 'string +hyperspec-base+ rel))))
        map))))

(defun hyperspec-url (name)
  "The HyperSpec page URL for symbol NAME, or NIL.  Loads the map on first use;
a failed load is retried next time."
  (when (null *hyperspec-map*)
    (setf *hyperspec-map* (%load-hyperspec-map)))
  (and *hyperspec-map* (gethash (string-upcase name) *hyperspec-map*)))

(defun %hs-symchar-p (ch) (or (alphanumericp ch) (find ch "+-*/@$%^&_=<>.~!?:")))

(defun %toplevel-form-at-offset (str off)
  "The outermost ( ) form whose span contains OFF, or NIL.  Skips strings,
#\\char literals and ; comments."
  (let ((len (length str)) (i 0) (depth 0) (start nil))
    (loop while (< i len) do
      (let ((c (char str i)))
        (cond
          ((char= c #\;)
           (loop while (and (< i len) (char/= (char str i) #\Newline)) do (incf i)))
          ((char= c #\")
           (incf i)
           (loop while (< i len) do
             (let ((d (char str i))) (incf i)
               (cond ((char= d #\\) (incf i)) ((char= d #\") (return))))))
          ((and (char= c #\#) (< (1+ i) len) (char= (char str (1+ i)) #\\)) (incf i 3))
          ((char= c #\()
           (when (zerop depth) (setf start i))
           (incf depth) (incf i))
          ((char= c #\))
           (incf i)
           (when (plusp depth) (decf depth))
           (when (zerop depth)
             (when (and start (<= start off) (<= off i))
               (return-from %toplevel-form-at-offset (subseq str start i)))
             (setf start nil)))
          (t (incf i)))))
    nil))

(defun %buffer-in-package (text upto)
  "Package-name STRING of the last (in-package ...) form starting before offset
UPTO in TEXT, or NIL -- so eval-defun / eval-region run in the buffer's declared
package rather than the listener's current one."
  (let ((pos 0) (found nil))
    (loop for i = (search "(in-package" text :start2 pos :test #'char-equal)
          while (and i (< i upto))
          do (let ((form (ignore-errors
                          (with-input-from-string (s text :start i) (read s nil nil)))))
               (when (and (consp form) (symbolp (first form))
                          (string-equal (symbol-name (first form)) "IN-PACKAGE")
                          (cdr form))
                 (setf found (string (second form))))
               (setf pos (+ i 11))))
    found))

(defun %fn-name (node-name)
  "A short printed name for an sb-sprof node name."
  (let ((s (princ-to-string node-name)))
    (if (> (length s) 48) (concatenate 'string (subseq s 0 45) "...") s)))

(defun run-profile (form package &key (interval 0.001) (mode :time) all-threads)
  "Evaluate FORM under sb-sprof and return a plist (:total :secs :mode :rows ...).
MODE is :time (CPU) or :alloc (allocations); INTERVAL is the sample interval in
seconds; ALL-THREADS samples every thread, not just this one."
  (let ((*package* package) (t0 (get-internal-real-time)))
    (sb-sprof:reset)
    (sb-sprof:start-profiling :max-samples 200000 :sample-interval interval :mode mode
                              :threads (if all-threads :all (list sb-thread:*current-thread*)))
    (unwind-protect (eval form) (sb-sprof:stop-profiling))
    (let* ((secs (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
           (cg (sb-sprof::make-call-graph sb-sprof::*samples* most-positive-fixnum))
           (total (max 1 (sb-sprof::call-graph-nsamples cg)))
           (flat (sb-sprof::call-graph-flat-nodes cg)))
      (list :total total :secs secs :mode mode
            :rows (loop for n in flat
                        for self = (sb-sprof::node-count n)
                        for cumul = (sb-sprof::node-accrued-count n)
                        collect (list :name (sb-sprof::node-name n)
                                      :self self :cumul cumul
                                      :self% (* 100.0 (/ self total))
                                      :cumul% (* 100.0 (/ cumul total))
                                      :callees (loop for e in (sb-sprof::node-edges n)
                                                     collect (%fn-name (sb-sprof::node-name
                                                                        (sb-sprof::edge-vertex e))))))))))

;;; A table window that can export its rows to CSV with the `e' key; the profile
;;; windows build on it.
(defun %search-token (token text start)
  "Offset of TOKEN in TEXT at/after START as a *whole* symbol token (not a
substring of a larger symbol, so `nam' won't match inside `name'),
case-insensitively, or NIL."
  (let* ((tk (string-downcase token)) (low (string-downcase text))
         (n (length text)) (tl (length token)) (i start))
    (loop for p = (search tk low :start2 i)
          while p do
            (let ((before (and (> p 0) (char low (1- p))))
                  (after (and (< (+ p tl) n) (char low (+ p tl)))))
              (if (and (or (null before) (not (%hs-symchar-p before)))
                       (or (null after) (not (%hs-symchar-p after))))
                  (return p)
                  (setf i (1+ p)))))))

(defun %sexp-bounds (str off)
  "(values START END) of the innermost () form containing OFF in STR, or NIL."
  (let ((len (length str)) (stack '()) (best nil) (i 0))
    (loop while (< i len) do
      (let ((c (char str i)))
        (cond
          ((char= c #\;) (loop while (and (< i len) (char/= (char str i) #\Newline)) do (incf i)))
          ((char= c #\")
           (incf i) (loop while (< i len) do
             (let ((d (char str i))) (incf i)
               (cond ((char= d #\\) (incf i)) ((char= d #\") (return))))))
          ((and (char= c #\#) (< (1+ i) len) (char= (char str (1+ i)) #\\)) (incf i 3))
          ((char= c #\() (push i stack) (incf i))
          ((char= c #\))
           (when stack
             (let ((start (pop stack)))
               (when (and (<= start off) (<= off (1+ i))
                          (or (null best) (> start (car best))))
                 (setf best (cons start (1+ i))))))
           (incf i))
          (t (incf i)))))
    (when best (values (car best) (cdr best)))))

(defun %inner-list (str off)
  "Like %SEXP-BOUNDS but with an exclusive end: a position sitting just past a
form's closing `)' belongs to the *enclosing* list, not that form.  So a cursor
in the whitespace between two sibling sub-forms resolves to their parent (which
is what transpose wants when swapping e.g. two LET bindings)."
  (let ((len (length str)) (stack '()) (best nil) (i 0))
    (loop while (< i len) do
      (let ((c (char str i)))
        (cond
          ((char= c #\;) (loop while (and (< i len) (char/= (char str i) #\Newline)) do (incf i)))
          ((char= c #\")
           (incf i) (loop while (< i len) do
             (let ((d (char str i))) (incf i)
               (cond ((char= d #\\) (incf i)) ((char= d #\") (return))))))
          ((and (char= c #\#) (< (1+ i) len) (char= (char str (1+ i)) #\\)) (incf i 3))
          ((char= c #\() (push i stack) (incf i))
          ((char= c #\))
           (when stack
             (let ((start (pop stack)))
               (when (and (<= start off) (< off (1+ i))
                          (or (null best) (> start (car best))))
                 (setf best (cons start (1+ i))))))
           (incf i))
          (t (incf i)))))
    (when best (values (car best) (cdr best)))))

(defun %sexp-span-at (str from)
  "From FROM, skip whitespace and line comments, then return (values START END)
of the one sexp beginning there — an atom, string, or balanced () list, with
leading reader prefixes (' ` , ,@) — or NIL when none remains."
  (let ((len (length str)) (i from))
    (loop while (< i len) do
      (let ((c (char str i)))
        (cond ((member c '(#\Space #\Tab #\Newline #\Return #\Page)) (incf i))
              ((char= c #\;) (loop while (and (< i len) (char/= (char str i) #\Newline)) do (incf i)))
              (t (return)))))
    (when (< i len)
      (let ((start i))
        (loop while (and (< i len) (member (char str i) '(#\' #\` #\,))) do
          (incf i) (when (and (< i len) (char= (char str i) #\@)) (incf i)))
        (when (< i len)
          (let ((c (char str i)))
            (cond
              ((char= c #\()
               (let ((depth 0))
                 (loop while (< i len) do
                   (let ((d (char str i)))
                     (cond ((char= d #\;) (loop while (and (< i len) (char/= (char str i) #\Newline)) do (incf i)))
                           ((char= d #\")
                            (incf i) (loop while (< i len) do
                              (let ((e (char str i))) (incf i)
                                (cond ((char= e #\\) (incf i)) ((char= e #\") (return))))))
                           ((and (char= d #\#) (< (1+ i) len) (char= (char str (1+ i)) #\\)) (incf i 3))
                           ((char= d #\() (incf depth) (incf i))
                           ((char= d #\)) (incf i) (decf depth) (when (zerop depth) (return)))
                           (t (incf i)))))))
              ((char= c #\")
               (incf i) (loop while (< i len) do
                 (let ((e (char str i))) (incf i)
                   (cond ((char= e #\\) (incf i)) ((char= e #\") (return))))))
              (t (loop while (and (< i len)
                                  (not (member (char str i)
                                               '(#\Space #\Tab #\Newline #\Return #\Page #\( #\) #\" #\;))))
                       do (incf i))))))
        (values start i)))))

(defun %sexp-spans (text start &optional (limit (length text)))
  "List of (START . END) spans of the successive sexps found scanning TEXT from
START up to LIMIT (using %SEXP-SPAN-AT) -- i.e. the direct children of a list, or
the top-level forms when scanning the whole buffer."
  (let ((spans '()) (i start))
    (loop (multiple-value-bind (a b) (%sexp-span-at text i)
            (if (and a (< a limit)) (progn (push (cons a b) spans) (setf i b))
                (return))))
    (nreverse spans)))

(defun %parent-siblings (text s e)
  "The (START . END) spans of the form at S..E and all its siblings -- the
children of the list that directly contains it, or the top-level forms when it
has no enclosing list."
  (or (when (> s 0)
        (multiple-value-bind (ps pe) (%sexp-bounds text (1- s))
          (when (and ps (< ps s) (> pe e))           ; a real enclosing list
            (%sexp-spans text (1+ ps) (1- pe)))))
      (%sexp-spans text 0)))

(defun %code-position-p (text pos)
  "True when POS in TEXT is ordinary code -- not inside a string, a ; comment or
a #\\ char literal.  Used so refactors can skip occurrences that only look like
the symbol."
  (let ((len (length text)) (i 0))
    (loop while (< i len) do
      (when (> i pos) (return))                       ; reached POS in plain code
      (let ((c (char text i)))
        (cond
          ((char= c #\;)
           (let ((j i))
             (loop while (and (< i len) (char/= (char text i) #\Newline)) do (incf i))
             (when (and (<= j pos) (< pos i)) (return-from %code-position-p nil))))
          ((char= c #\")
           (let ((j i)) (incf i)
             (loop while (< i len) do
               (let ((d (char text i))) (incf i)
                 (cond ((char= d #\\) (incf i)) ((char= d #\") (return)))))
             (when (and (<= j pos) (< pos i)) (return-from %code-position-p nil))))
          ((and (char= c #\#) (< (1+ i) len) (char= (char text (1+ i)) #\\))
           (let ((j i)) (incf i 3)
             (when (and (<= j pos) (< pos i)) (return-from %code-position-p nil))))
          (t (incf i)))))
    t))

(defun %reorder-edits (text name perm r)
  "Edits (REGION-START REGION-END REPLACEMENT CALL-OFFSET) that reorder the first
R positional arguments of each direct call (NAME ...) in TEXT according to PERM.
Only operator-position, in-code occurrences with at least R arguments qualify, so
apply/funcall/#' uses and the definition site are left alone."
  (let ((edits '()) (i 0) (nlen (length name)))
    (loop for p = (%search-token name text i)
          while p do
            (setf i (+ p nlen))
            (when (%code-position-p text p)
              (let ((j (1- p)))                       ; preceding non-whitespace char
                (loop while (and (>= j 0)
                                 (member (char text j) '(#\Space #\Tab #\Newline #\Return)))
                      do (decf j))
                (when (and (>= j 0) (char= (char text j) #\())
                  (multiple-value-bind (s e) (%sexp-bounds text p)
                    (when (and s (= j s))             ; that '(' opens this very call
                      (let* ((kids (%sexp-spans text (1+ s) (1- e)))
                             (op (first kids)) (args (rest kids)))
                        (when (and op (= (car op) p) (>= (length args) r))
                          (let* ((sel (subseq args 0 r)) (parts '())
                                 (region-end (cdr (nth (1- r) sel)))
                                 (prev (cdr op)))
                            (loop for k below r
                                  for slot = (nth k sel)
                                  for src = (nth (nth k perm) sel) do
                                    (push (subseq text prev (car slot)) parts)     ; gap before slot
                                    (push (subseq text (car src) (cdr src)) parts) ; reordered content
                                    (setf prev (cdr slot)))
                            (push (list (cdr op) region-end
                                        (apply #'concatenate 'string (nreverse parts)) p)
                                  edits))))))))))
    (nreverse edits)))

(defun %apply-reorder (text edits)
  "Apply EDITS (from %REORDER-EDITS) to TEXT, last-to-first so offsets stay valid."
  (let ((out text))
    (dolist (ed (sort (copy-list edits) #'> :key #'first) out)
      (setf out (concatenate 'string (subseq out 0 (first ed)) (third ed)
                             (subseq out (second ed)))))))

(defun %git-lines (dir &rest args)
  "Run `git -C DIR ARGS', returning its non-empty output lines, or NIL on
failure (e.g. DIR is not a git repository)."
  (handler-case
      (let* ((out (make-string-output-stream))
             (p (sb-ext:run-program "git" (list* "-C" (namestring dir) args)
                                    :search t :output out :error nil :wait t)))
        (when (and p (eql 0 (sb-ext:process-exit-code p)))
          (with-input-from-string (s (get-output-stream-string out))
            (loop for l = (read-line s nil nil) while l
                  when (plusp (length l)) collect l))))
    (error () nil)))

(defun %run-lines (program args)
  "Run PROGRAM with ARGS, returning its non-empty stdout lines (any exit code --
grep/git grep exit 1 when there are no matches), or NIL on failure."
  (handler-case
      (let* ((out (make-string-output-stream))
             (p (sb-ext:run-program program args :search t :output out :error nil :wait t)))
        (when p
          (with-input-from-string (s (get-output-stream-string out))
            (loop for l = (read-line s nil nil) while l
                  when (plusp (length l)) collect l))))
    (error () nil)))

(defun %git-files (dir)
  "Sorted relative paths git tracks under DIR, or NIL when DIR is not a git repo."
  (let ((ls (%git-lines dir "ls-files")))
    (and ls (sort (copy-list ls) #'string<))))

(defun %git-status-map (dir)
  "Hash table of relative-path -> status keyword (:added :modified) for tracked
files git reports as changed under DIR.  (Untracked files are listed separately
via `ls-files --others' so whole-directory entries don't appear nameless.)"
  (let ((map (make-hash-table :test 'equal)))
    (dolist (l (%git-lines dir "status" "--porcelain") map)
      (when (and (> (length l) 3) (not (string= (subseq l 0 2) "??")))
        (let* ((xy (subseq l 0 2))
               (rest (subseq l 3))
               (arrow (search " -> " rest))   ; "old -> new" rename: key on the new name
               (path (string-trim '(#\") (if arrow (subseq rest (+ arrow 4)) rest))))
          (setf (gethash path map)
                (if (char= (char xy 0) #\A) :added :modified)))))))

(defparameter +pm-grep-limit+ 1000)

(defun %pm-grep (dir query)
  "Search the fixed string QUERY under DIR: `git grep' in a repo (tracked files),
else `grep -rnI'.  Returns up to +PM-GREP-LIMIT+ (ABS-PATH LINE TEXT) matches."
  (let* ((dir (uiop:ensure-directory-pathname dir))
         (gitp (%git-files dir))
         (lines (if gitp
                    (%run-lines "git" (list "-C" (namestring dir) "grep" "-n" "-I" "-F" "-e" query))
                    (%run-lines "grep" (list "-rnI" "--exclude-dir=.git" "-F" "-e" query (namestring dir)))))
         (out '()) (n 0))
    (dolist (l lines (nreverse out))
      (when (>= n +pm-grep-limit+) (return (nreverse out)))
      (let* ((c1 (position #\: l))
             (c2 (and c1 (position #\: l :start (1+ c1)))))
        (when c2
          (let ((ln (parse-integer l :start (1+ c1) :end c2 :junk-allowed t)))
            (when ln
              (push (list (if gitp (merge-pathnames (subseq l 0 c1) dir) (pathname (subseq l 0 c1)))
                          ln (string-left-trim '(#\Space #\Tab) (subseq l (1+ c2))))
                    out)
              (incf n))))))))

