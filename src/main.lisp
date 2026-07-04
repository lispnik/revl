;;;; revision-main.lisp --- revl running on the experimental revision CLOS kernel.
;;;;
;;;; The classic revl IDE is built on the original `revision' framework.  Every
;;;; revl window has also been rebuilt on `revision', the CLOS-native re-architecture
;;;; of the framework (see ../revision/revision/README.md).  This is the entry point
;;;; for that build: it launches the revision IDE shell (a menu of the ported
;;;; windows).  It lives in its own system (`revl/revision') so the classic build
;;;; and binary are untouched.

(defpackage #:revl
  (:use #:cl)
  (:documentation "revl on the revision kernel.")
  (:export #:main #:toplevel))

(in-package #:revl)

;;; --- migration: reuse the classic revl app's real logic on revision windows ----
;;; Stage 1: the editor's Lisp indentation.  revision's editor calls *LISP-INDENTER*
;;; for a fresh line; we point it at revl's actual indent engine
;;; (REVISION::%LISP-INDENT-AT), so the revision editor indents exactly like revl.

(defun %line-offset (te line)
  "Char offset where LINE begins in TE's buffer."
  (loop for i below line sum (1+ (length (revision::te-line te i)))))

(defun revl-indent (te)
  "Indent a fresh line using revl's Lisp indenter."
  (or (ignore-errors
       (revl-logic::%lisp-indent-at (revision:te-text te) (%line-offset te (revision::te-cy te))))
      0))

;;; Stage 2: the REPL evaluator.  Replace revision's hand-rolled eval loop with
;;; revl's actual REVISION:REPL-BACKEND-EVAL — its read/eval/print, the per-
;;; listener CL history vars (-, +/++/+++, */**/***, ///), and sticky IN-PACKAGE
;;; — while keeping revision's SLDB debugger as the error handler.

(defun revl-repl-eval (win input)
  "Worker thread: evaluate INPUT for the revision REPL window WIN using revl's
backend, then post output + results + new package back through revision's UI bridge."
  (let* ((hist (revision:repl-hist-vars win)))
    (multiple-value-bind (output results new-pkg errored new-hist)
        (restart-case
            ;; route break (invoke-debugger) and single-step (step-condition --
            ;; the SBCL stepper bypasses *debugger-hook*) to revision's cross-thread
            ;; debugger too, so TRACE :break and (step ...) work in-UI
            (let ((*debugger-hook* (lambda (c hook) (declare (ignore hook)) (revision::%repl-debug win c))))
              (handler-bind ((sb-ext:step-condition (lambda (c) (revision::%repl-debug win c))))
                (revl-logic::repl-backend-eval input (revision:repl-package win)
                         (lambda (e) (revision::%repl-debug win e))    ; reuse revision's cross-thread SLDB debugger
                         hist)))
          (revision::repl-abort () (values "" nil (revision:repl-package win) t hist)))   ; debugger's abort lands here
      (setf (revision:repl-hist-vars win) new-hist)
      (let ((lastvals (car (last results))))                  ; remember the primary result (object clipboard)
        (when (and (not errored) lastvals)
          (setf (revision:repl-last-value win) (first lastvals) (revision:repl-last-value-p win) t)))
      ;; pair each result object with its printed form so the transcript can show
      ;; it as a clickable presentation (SLY-style: click to inspect the object)
      (let ((result-entries (let ((*package* new-pkg))
                              (unless errored
                                (loop for vals in results
                                      collect (if vals (mapcar (lambda (o) (cons o (prin1-to-string o))) vals) :none))))))
        (revision:run-on-ui
         (lambda ()
           (let ((sb (revision:find-view win 'revision::transcript)))
             (when sb
               (when (plusp (length output))
                 (revision:scrollback-append sb output)
                 (unless (char= (char output (1- (length output))) #\Newline)
                   (revision:scrollback-append sb (string #\Newline))))
               (dolist (entry result-entries)
                 (if (eq entry :none)
                     (revision:scrollback-append sb (format nil "; No values~%"))
                     (dolist (pair entry)
                       (revision:scrollback-present sb (format nil "=> ~a~%" (cdr pair)) (car pair)))))))
           (setf (revision:repl-package win) new-pkg (revision:repl-busy win) nil)
           (revision::%repl-update-prompt win)))))))

;;; Stage 3: eval-defun / eval-region.  The editor's Eval chip evaluates the
;;; selection (region) or, if none, the top-level form at the cursor — extracted
;;; with revl's real %TOPLEVEL-FORM-AT-OFFSET — in the desktop's REPL.

(defun %blankp (s) (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) (or s "")))))

(defun revl-editor-eval (te)
  "Evaluate the region (or the top-level form at point) in the REPL."
  (let* ((text (revision:te-text te))
         (sel  (revision::te-selected-string te))
         (off  (+ (%line-offset te (revision::te-cy te)) (revision::te-cx te)))
         (form (if (not (%blankp sel)) sel
                   (revl-logic::%toplevel-form-at-offset text off))))
    (unless (%blankp form)
      (let ((repl (revision:ensure-repl)))
        (when repl
          (revision::dt-raise revision:*desktop* repl) (revision:invalidate revision:*desktop*)   ; show the result
          (revision:repl-submit-string repl (string-trim '(#\Space #\Tab #\Newline #\Return) form)))))))

;;; Stage 4: editor structural ops.  Two more revision hooks reuse revl's real Lisp
;;; logic: package-aware symbol completion against the live image (revl's
;;; REPL-BACKEND-COMPLETIONS, with the buffer's IN-PACKAGE via %BUFFER-IN-PACKAGE)
;;; and bracket matching (%PAREN-MATCH-OFFSET, which skips strings/comments).

(defun revl-editor-completions (te token)
  "Completion candidates for the prefix TOKEN at the cursor, resolved in the
package the buffer's IN-PACKAGE form selects (falling back to *PACKAGE*)."
  (let ((upto (+ (%line-offset te (revision::te-cy te)) (revision::te-cx te))))
    (let ((pkg (or (ignore-errors (find-package (revl-logic::%buffer-in-package (revision:te-text te) upto)))
                   *package*)))
      (ignore-errors (revl-logic::repl-backend-completions token pkg)))))

(defun revl-repl-completions (token package)
  "REPL Tab-completion candidates for TOKEN in the listener's PACKAGE."
  (ignore-errors (revl-logic::repl-backend-completions token (or package *package*))))

;;; Stage 5: project manager.  Two more revision hooks reuse revl's real PM logic:
;;; git status badges (%GIT-STATUS-MAP -> relpath/:modified/:added) and
;;; find-in-files (%PM-GREP -> git grep / grep -rnI, returning match locations).

(defun revl-project-status (dir)
  "Hash of relative-path -> :modified / :added for files git reports changed."
  (revl-logic::%git-status-map dir))

(defun revl-project-grep (dir query)
  "List of (ABS-PATH LINE TEXT) matches of QUERY under DIR (capped by revl)."
  (revl-logic::%pm-grep dir query))

;;; Stage 9: paredit / structural editing.  revision's editor calls *PAREDIT-FN* with
;;; an op + the buffer text + cursor offset; we reuse revl's real sexp layer
;;; (%SEXP-BOUNDS / %SEXP-SPAN-AT / %SEXP-SPANS / %INNER-LIST / %PARENT-SIBLINGS)
;;; to compute the new text + cursor, exactly as revl's do-slurp/-barf/... do.

(defun %ws-trim-left (s) (string-left-trim '(#\Space #\Tab #\Newline #\Return) s))

(defun revl-paredit (op text off)
  "Structural edit OP at OFF in TEXT -> (values NEW-TEXT NEW-OFF), or NIL."
  (let ((%bounds #'revl-logic::%sexp-bounds) (%span #'revl-logic::%sexp-span-at)
        (%spans #'revl-logic::%sexp-spans) (%inner #'revl-logic::%inner-list)
        (%sibs  #'revl-logic::%parent-siblings))
      (macrolet ((sub (&rest a) `(subseq text ,@a)))
        (ecase op
          (:wrap
           (multiple-value-bind (s e) (funcall %bounds text off)
             (when s (values (concatenate 'string (sub 0 s) "(" (sub s e) ")" (sub e)) (1+ s)))))
          (:splice
           (multiple-value-bind (s e) (funcall %bounds text off)
             (when (and s (> e s))
               (values (concatenate 'string (sub 0 s) (sub (1+ s) (1- e)) (sub e)) (max s (1- off))))))
          (:raise
           (multiple-value-bind (is ie) (funcall %bounds text off)
             (when is
               (multiple-value-bind (ps pe) (funcall %bounds text (max 0 (1- is)))
                 (when (and ps (< ps is) (>= pe ie))
                   (values (concatenate 'string (sub 0 ps) (sub is ie) (sub pe)) ps))))))
          (:slurp
           (multiple-value-bind (s e) (funcall %bounds text off)
             (when (and s (> e s))
               (let ((cp (1- e)))
                 (multiple-value-bind (n0 n1) (funcall %span text e)
                   (declare (ignore n0))
                   (when n1
                     (values (concatenate 'string (sub 0 cp) (sub (1+ cp) n1) ")" (sub n1)) off)))))))
          (:barf
           (multiple-value-bind (s e) (funcall %bounds text off)
             (when (and s (> (- e s) 2))
               (let ((cp (1- e)) (last nil) (i (1+ s)))
                 (loop (multiple-value-bind (a b) (funcall %span text i)
                         (if (and a (< a cp)) (progn (setf last (cons a b) i b)) (return))))
                 (when last
                   (let* ((l0 (car last)) (l1 (min (cdr last) cp))
                          (trimmed (string-right-trim '(#\Space #\Tab #\Newline #\Return) (sub (1+ s) l0))))
                     (values (concatenate 'string (sub 0 (1+ s)) trimmed ") " (sub l0 l1) (sub (1+ cp))) off)))))))
          (:slurp-back
           (multiple-value-bind (s e) (funcall %bounds text off)
             (when (and s (> e s))
               (let* ((sibs (funcall %sibs text s e))
                      (me (position s sibs :key #'car))
                      (prev (and me (> me 0) (nth (1- me) sibs))))
                 (when prev
                   (values (concatenate 'string (sub 0 (car prev)) "(" (sub (car prev) (cdr prev)) " "
                                        (sub (1+ s) e) (sub e))
                           (1+ (car prev))))))))
          (:barf-back
           (multiple-value-bind (s e) (funcall %bounds text off)
             (when (and s (> (- e s) 2))
               (let ((fk (first (funcall %spans text (1+ s) (1- e)))))
                 (when fk
                   (values (concatenate 'string (sub 0 s) (sub (car fk) (cdr fk)) " ("
                                        (%ws-trim-left (sub (cdr fk) (1- e))) (sub (1- e)))
                           s))))))
          (:transpose
           (multiple-value-bind (s e) (funcall %inner text off)
             (when s
               (let* ((kids (funcall %spans text (1+ s) (1- e)))
                      (idx (or (position-if (lambda (k) (and (<= (car k) off) (< off (cdr k)))) kids)
                               (position-if (lambda (k) (<= (cdr k) off)) kids :from-end t))))
                 (when (and idx (< (1+ idx) (length kids)))
                   (let* ((a (nth idx kids)) (b (nth (1+ idx) kids)) (gap (sub (cdr a) (car b))))
                     (values (concatenate 'string (sub 0 (car a)) (sub (car b) (cdr b)) gap
                                          (sub (car a) (cdr a)) (sub (cdr b)))
                             (+ (car a) (- (cdr b) (car b)) (length gap)))))))))
          (:kill
           (multiple-value-bind (a b) (funcall %span text off)
             (when a (values (concatenate 'string (sub 0 a) (string-left-trim '(#\Space #\Tab) (sub b))) a))))))))

(defun revl-reorder (name text perm r)
  "Reorder the first R positional args of every direct call (NAME ...) in TEXT
per PERM, reusing revl's sexp rewriter.  Returns new TEXT, or NIL if unchanged."
  (let ((edits (revl-logic::%reorder-edits text name perm r)))
    (when edits (revl-logic::%apply-reorder text edits))))

(defun install-revl-logic ()
  "Inject revl's real logic into the revision toolkit (extended each migration stage)."
  (setf revision:*lisp-indenter*         #'revl-indent               ; stage 1: editor indentation
        revision:*repl-eval-fn*          #'revl-repl-eval            ; stage 2: REPL evaluator
        revision:*editor-eval-fn*        #'revl-editor-eval          ; stage 3: eval-defun / eval-region
        revision:*editor-completions-fn* #'revl-editor-completions   ; stage 4: symbol completion
        revision:*repl-completions-fn*   #'revl-repl-completions     ; REPL Tab completion
        revision:*paren-matcher*         #'revl-logic::%paren-match-offset   ; bracket match
        revision:*project-status-fn*     #'revl-project-status             ; git status badges
        revision:*project-grep-fn*       #'revl-project-grep               ; find-in-files
        revision:*object->outline-fn*    #'revl-logic::object->outline       ; object inspector
        revision:*profile-fn*            #'revl-logic::run-profile         ; sb-sprof profiler
        revision:*paredit-fn*            #'revl-paredit                    ; paredit
        revision:*reorder-fn*            #'revl-reorder                    ; reorder args at call sites
        revision:*url-fetch-fn*          #'revl-logic::%http-get           ; fetch (curl)
        revision:*hyperspec-url-fn*      #'revl-logic::hyperspec-url))     ; CLHS map

(defun main ()
  "Run the revision-based revl IDE until the user quits the launcher."
  (install-revl-logic)
  (revision:run-app))

(defun toplevel ()
  "Dumped-executable entry point: run the IDE, report a fatal error cleanly, exit."
  (handler-case (main)
    (error (e) (format *error-output* "~&revl: fatal: ~a~%" e)))
  (uiop:quit 0))
