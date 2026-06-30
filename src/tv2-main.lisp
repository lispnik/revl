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

;;; Stage 2: the REPL evaluator.  Replace tv2's hand-rolled eval loop with
;;; tvlisp's actual TVISION:REPL-BACKEND-EVAL — its read/eval/print, the per-
;;; listener CL history vars (-, +/++/+++, */**/***, ///), and sticky IN-PACKAGE
;;; — while keeping tv2's SLDB debugger as the error handler.

(defun tvlisp-repl-eval (win input)
  "Worker thread: evaluate INPUT for the tv2 REPL window WIN using tvlisp's
backend, then post output + results + new package back through tv2's UI bridge."
  (let* ((backend (find-symbol "REPL-BACKEND-EVAL" :tvision))
         (hist (tv2:repl-hist-vars win)))
    (multiple-value-bind (output results new-pkg errored new-hist)
        (restart-case
            ;; route break (invoke-debugger) and single-step (step-condition --
            ;; the SBCL stepper bypasses *debugger-hook*) to tv2's cross-thread
            ;; debugger too, so TRACE :break and (step ...) work in-UI
            (let ((*debugger-hook* (lambda (c hook) (declare (ignore hook)) (tv2::%repl-debug win c))))
              (handler-bind ((sb-ext:step-condition (lambda (c) (tv2::%repl-debug win c))))
                (funcall backend input (tv2:repl-package win)
                         (lambda (e) (tv2::%repl-debug win e))    ; reuse tv2's cross-thread SLDB debugger
                         hist)))
          (tv2::repl-abort () (values "" nil (tv2:repl-package win) t hist)))   ; debugger's abort lands here
      (setf (tv2:repl-hist-vars win) new-hist)
      (let ((result-strs (let ((*package* new-pkg))            ; print results in the listener's package
                           (unless errored
                             (loop for vals in results
                                   collect (if vals (mapcar #'prin1-to-string vals) :none))))))
        (tv2:run-on-ui
         (lambda ()
           (let ((sb (tv2:find-view win 'tv2::transcript)))
             (when sb
               (when (plusp (length output))
                 (tv2:scrollback-append sb output)
                 (unless (char= (char output (1- (length output))) #\Newline)
                   (tv2:scrollback-append sb (string #\Newline))))
               (dolist (vals result-strs)
                 (if (eq vals :none)
                     (tv2:scrollback-append sb (format nil "; No values~%"))
                     (dolist (v vals) (tv2:scrollback-append sb (format nil "=> ~a~%" v)))))))
           (setf (tv2:repl-package win) new-pkg (tv2:repl-busy win) nil)
           (tv2::%repl-update-prompt win)))))))

;;; Stage 3: eval-defun / eval-region.  The editor's Eval chip evaluates the
;;; selection (region) or, if none, the top-level form at the cursor — extracted
;;; with tvlisp's real %TOPLEVEL-FORM-AT-OFFSET — in the desktop's REPL.

(defun %blankp (s) (zerop (length (string-trim '(#\Space #\Tab #\Newline #\Return) (or s "")))))

(defun tvlisp-editor-eval (te)
  "Evaluate the region (or the top-level form at point) in the REPL."
  (let* ((text (tv2:te-text te))
         (sel  (tv2::te-selected-string te))
         (off  (+ (%line-offset te (tv2::te-cy te)) (tv2::te-cx te)))
         (form (if (not (%blankp sel)) sel
                   (funcall (find-symbol "%TOPLEVEL-FORM-AT-OFFSET" :tvision-tvlisp) text off))))
    (unless (%blankp form)
      (let ((repl (tv2:ensure-repl)))
        (when repl
          (tv2::dt-raise tv2:*desktop* repl) (tv2:invalidate tv2:*desktop*)   ; show the result
          (tv2:repl-submit-string repl (string-trim '(#\Space #\Tab #\Newline #\Return) form)))))))

;;; Stage 4: editor structural ops.  Two more tv2 hooks reuse tvlisp's real Lisp
;;; logic: package-aware symbol completion against the live image (tvlisp's
;;; REPL-BACKEND-COMPLETIONS, with the buffer's IN-PACKAGE via %BUFFER-IN-PACKAGE)
;;; and bracket matching (%PAREN-MATCH-OFFSET, which skips strings/comments).

(defun tvlisp-editor-completions (te token)
  "Completion candidates for the prefix TOKEN at the cursor, resolved in the
package the buffer's IN-PACKAGE form selects (falling back to *PACKAGE*)."
  (let ((complete (find-symbol "REPL-BACKEND-COMPLETIONS" :tvision))
        (buf-pkg  (find-symbol "%BUFFER-IN-PACKAGE" :tvision-tvlisp))
        (upto     (+ (%line-offset te (tv2::te-cy te)) (tv2::te-cx te))))
    (let ((pkg (or (and buf-pkg (ignore-errors (find-package (funcall buf-pkg (tv2:te-text te) upto))))
                   *package*)))
      (and complete (ignore-errors (funcall complete token pkg))))))

;;; Stage 5: project manager.  Two more tv2 hooks reuse tvlisp's real PM logic:
;;; git status badges (%GIT-STATUS-MAP -> relpath/:modified/:added) and
;;; find-in-files (%PM-GREP -> git grep / grep -rnI, returning match locations).

(defun tvlisp-project-status (dir)
  "Hash of relative-path -> :modified / :added for files git reports changed."
  (let ((statusmap (find-symbol "%GIT-STATUS-MAP" :tvision-tvlisp)))
    (and statusmap (funcall statusmap dir))))

(defun tvlisp-project-grep (dir query)
  "List of (ABS-PATH LINE TEXT) matches of QUERY under DIR (capped by tvlisp)."
  (let ((grep (find-symbol "%PM-GREP" :tvision-tvlisp)))
    (and grep (funcall grep dir query))))

(defun install-tvlisp-logic ()
  "Inject tvlisp's real logic into the tv2 toolkit (extended each migration stage)."
  (setf tv2:*lisp-indenter*         #'tvlisp-indent               ; stage 1: editor indentation
        tv2:*repl-eval-fn*          #'tvlisp-repl-eval            ; stage 2: REPL evaluator
        tv2:*editor-eval-fn*        #'tvlisp-editor-eval          ; stage 3: eval-defun / eval-region
        tv2:*editor-completions-fn* #'tvlisp-editor-completions   ; stage 4: symbol completion
        tv2:*paren-matcher*         (find-symbol "%PAREN-MATCH-OFFSET" :tvision)   ; stage 4: bracket match
        tv2:*project-status-fn*     #'tvlisp-project-status       ; stage 5: git status badges
        tv2:*project-grep-fn*       #'tvlisp-project-grep         ; stage 5: find-in-files
        tv2:*object->outline-fn*    (or (find-symbol "OBJECT->OUTLINE" :tvision)   ; stage 7: object inspector
                                        tv2:*object->outline-fn*)
        tv2:*profile-fn*            (let ((p (find-symbol "RUN-PROFILE" :tvision-tvlisp)))   ; stage 8: sb-sprof profiler
                                      (and p (lambda (form package) (funcall p form package))))))

(defun main ()
  "Run the tv2-based tvlisp IDE until the user quits the launcher."
  (install-tvlisp-logic)
  (tv2:run-app))

(defun toplevel ()
  "Dumped-executable entry point: run the IDE, report a fatal error cleanly, exit."
  (handler-case (main)
    (error (e) (format *error-output* "~&tvlisp-tv2: fatal: ~a~%" e)))
  (uiop:quit 0))
