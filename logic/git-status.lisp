;;;; git-status.lisp --- framework-agnostic git porcelain for the status window.
;;;;
;;;; Pure functions over `git -C ROOT ...' (via SB-EXT:RUN-PROGRAM); no revision /
;;;; UI dependency, so they are headless-testable.  Reads reuse %GIT-LINES
;;;; (app-logic.lisp); mutating commands need the exit code, so they go through
;;;; %GIT-OK.  The status/staging window (revl ide/git-status.lisp) renders these.

(in-package #:revl-logic)

(defun %git-ok (root &rest args)
  "Run `git -C ROOT ARGS' for its side effect; return T on exit 0, NIL otherwise.
Used for mutating commands (add / reset / checkout / commit)."
  (handler-case
      (let ((p (sb-ext:run-program "git" (list* "-C" (namestring root) args)
                                   :search t :output nil :error nil :wait t)))
        (and p (eql 0 (sb-ext:process-exit-code p))))
    (error () nil)))

(defun git-root (dir)
  "The top-level directory of the git work-tree containing DIR (a namestring), or
NIL when DIR is not inside a git repository."
  (first (%git-lines dir "rev-parse" "--show-toplevel")))

(defun git-current-branch (root)
  "A short label for ROOT's current position: the branch name, or `detached @ SHA'
when HEAD is detached, or NIL when it cannot be determined."
  (let ((b (first (%git-lines root "rev-parse" "--abbrev-ref" "HEAD"))))
    (cond ((null b) nil)
          ((string= b "HEAD")
           (format nil "detached @ ~a" (or (first (%git-lines root "rev-parse" "--short" "HEAD")) "?")))
          (t b))))

(defun %status-key (ch)
  "Map a porcelain status char to a keyword."
  (case ch (#\A :added) (#\M :modified) (#\D :deleted)
           (#\R :renamed) (#\C :copied) (#\U :conflict) (t :modified)))

(defun git-status-sections (root)
  "Parse `git status --porcelain' for ROOT into three lists of (RELPATH . KEYWORD):
 (values STAGED UNSTAGED UNTRACKED).  A file with both index and work-tree changes
appears in both STAGED and UNSTAGED (Magit-style).  Renames key on the new name."
  (let ((staged '()) (unstaged '()) (untracked '()))
    (dolist (l (%git-lines root "status" "--porcelain"))
      (when (>= (length l) 3)
        (let* ((x (char l 0)) (y (char l 1)) (rest (subseq l 3))
               (arrow (search " -> " rest))
               (path (string-trim '(#\") (if arrow (subseq rest (+ arrow 4)) rest))))
          (cond
            ((and (char= x #\?) (char= y #\?)) (push (cons path :untracked) untracked))
            (t (unless (char= x #\Space) (push (cons path (%status-key x)) staged))
               (unless (or (char= y #\Space) (char= y #\?)) (push (cons path (%status-key y)) unstaged)))))))
    (values (nreverse staged) (nreverse unstaged) (nreverse untracked))))

(defun git-file-diff (root relpath &key staged untracked)
  "Lines describing RELPATH's changes under ROOT: the staged diff (STAGED),
the work-tree diff (default), or the whole file for an UNTRACKED new file."
  (cond
    (untracked
     (handler-case
         (with-open-file (s (merge-pathnames relpath (uiop:ensure-directory-pathname root))
                            :if-does-not-exist nil)
           (and s (loop for l = (read-line s nil nil) while l
                        for n from 1 to 500 collect (concatenate 'string "+" l))))
       (error () nil)))
    (staged (%git-lines root "diff" "--cached" "--" relpath))
    (t      (%git-lines root "diff" "--" relpath))))

;;; --- mutating operations (each returns T on success) ------------------------

(defun git-stage (root relpath)
  "Stage RELPATH under ROOT (`git add')."
  (%git-ok root "add" "--" relpath))

(defun git-unstage (root relpath)
  "Unstage RELPATH under ROOT (`git reset HEAD'); works for adds and modifications."
  (%git-ok root "reset" "-q" "HEAD" "--" relpath))

(defun git-discard (root relpath &key untracked)
  "Discard RELPATH's work-tree changes under ROOT: restore a tracked file from HEAD
(`git checkout'), or delete an UNTRACKED file.  Returns T on success."
  (if untracked
      (handler-case
          (progn (uiop:delete-file-if-exists (merge-pathnames relpath (uiop:ensure-directory-pathname root))) t)
        (error () nil))
      (%git-ok root "checkout" "--" relpath)))

(defun git-commit (root message)
  "Commit ROOT's staged changes with MESSAGE (`git commit -m').  Returns T on
success (NIL when there is nothing staged or git refuses)."
  (and (stringp message) (plusp (length (string-trim " " message)))
       (%git-ok root "commit" "-m" message)))
