;;;; git-status.lisp --- a Magit-style git status / staging window on revision.
;;;;
;;;; An OUTLINE whose roots are the Staged / Unstaged / Untracked sections; each
;;;; file row lazily expands to its diff.  Keys act on the focused file: s stage,
;;;; u unstage, k discard (confirm), c commit (prompt), g refresh, Enter diff.
;;;; The git porcelain lives in revl-logic (git-status.lisp); this file is view.

(in-package #:revl)

(defclass git-status-window (window)
  ((root :initarg :root :initform nil :accessor gsw-root))   ; the git work-tree root, or NIL
  (:metaclass reactive-class))

;;; --- node builders ----------------------------------------------------------

(defun %gs-badge (status)
  (case status (:added " [A]") (:modified " [M]") (:deleted " [D]")
               (:renamed " [R]") (:untracked " [?]") (:conflict " [U]") (t "")))

(defun %gs-diff-color (line)
  "A DOS foreground code for a diff LINE (green +, red -, cyan @@), or NIL."
  (when (plusp (length line))
    (case (char line 0) (#\+ 10) (#\- 12) (#\@ 11) (t nil))))

(defun %gs-diff-nodes (win relpath section data)
  "Lazy children of a file node: one outline node per diff line, coloured."
  (let ((lines (revl-logic::git-file-diff (gsw-root win) relpath
                                          :staged (eq section :staged)
                                          :untracked (eq section :untracked))))
    (if (null lines)
        (list (revision:make-outline-node "  (no diff)" nil data))
        (mapcar (lambda (l)
                  (let ((n (revision:make-outline-node (concatenate 'string "  " l) nil data)))
                    (let ((c (%gs-diff-color l))) (when c (setf (revision:outline-node-color n) c)))
                    n))
                lines))))

(defun %gs-file-node (win relpath section status)
  "A file row (DATA = (RELPATH SECTION STATUS)) that expands to its diff."
  (let* ((data (list relpath section status))
         (node (revision:make-outline-node
                (format nil "  ~a~a" relpath (%gs-badge status)) nil data)))
    (setf (revision:outline-node-loader node)
          (lambda () (%gs-diff-nodes win relpath section data)))
    node))

(defun %gs-section (win title entries section)
  "A section node listing ENTRIES (a list of (RELPATH . STATUS)), or NIL if empty."
  (when entries
    (let ((node (revision:make-outline-node
                 (format nil "~a (~d)" title (length entries))
                 (mapcar (lambda (e) (%gs-file-node win (car e) section (cdr e))) entries))))
      (setf (revision:outline-node-expanded node) t)
      node)))

(defun %gs-build-roots (win)
  (let ((root (gsw-root win)))
    (if (null root)
        (list (revision:make-outline-node "  (not a git repository) "))
        (multiple-value-bind (staged unstaged untracked) (revl-logic::git-status-sections root)
          (or (remove nil (list (%gs-section win "Staged"    staged    :staged)
                                (%gs-section win "Unstaged"  unstaged  :unstaged)
                                (%gs-section win "Untracked" untracked :untracked)))
              (list (revision:make-outline-node "  working tree clean ")))))))

;;; --- refresh + helpers ------------------------------------------------------

(defun %gs-echo (win msg)
  (let ((e (find-view win 'echo))) (when e (setf (static-text-text e) msg) (invalidate e))))

(defun %gs-apply (win branch roots)
  "Install freshly-computed sections + branch into WIN's outline and title (UI thread)."
  (let ((ol (find-view win 'tree)))
    (when ol
      (setf (outline-roots ol) roots (outline-focused ol) 0 (outline-top ol) 0)
      (invalidate ol)))
  (setf (window-title win)
        (if (gsw-root win) (format nil " Git status — ~a " (or branch "?")) " Git status ")))

(defun %gs-refresh (win)
  "Re-read git state and rebuild the outline.  The git subprocess (status + branch, and
building each file node) runs on a worker thread so a slow/large repo doesn't stall the
UI; the rebuilt sections are installed back on the UI thread via RUN-ASYNC's THEN."
  (let ((root (gsw-root win)))
    (%gs-echo win " loading… ")
    (revision:run-async
     (lambda () (cons (and root (revl-logic::git-current-branch root)) (%gs-build-roots win)))
     :then (lambda (result) (%gs-apply win (car result) (cdr result)) (%gs-echo win ""))
     :on-error (lambda (e) (%gs-echo win (format nil " git error: ~a " e)))
     :label "git-status")))

(defun %gs-current (win)
  "The (RELPATH SECTION STATUS) of the focused file/diff node, or NIL."
  (let* ((ol (find-view win 'tree)) (n (and ol (ov-current ol))))
    (and n (revision:outline-node-data n))))

(defun %gs-act (win action)
  "Run stage / unstage / discard on the focused file off the UI thread, then refresh.
The discard confirmation (a modal) is taken on the UI thread first; only the git
subprocess is backgrounded."
  (let ((root (gsw-root win)) (data (%gs-current win)))
    (if (and root data (consp data))
        (destructuring-bind (relpath section status) data
          (declare (ignore status))
          (when (or (not (eq action :discard))
                    (revision::%confirm (format nil " Discard changes to ~a? " relpath)))
            (%gs-echo win (format nil " ~(~a~)… " action))
            (revision:run-async
             (lambda () (ecase action
                          (:stage   (revl-logic::git-stage root relpath))
                          (:unstage (revl-logic::git-unstage root relpath))
                          (:discard (revl-logic::git-discard root relpath :untracked (eq section :untracked)))))
             :then (lambda (ok)
                     (%gs-refresh win)
                     (%gs-echo win (if ok (format nil " ~(~a~) ~a " action relpath) " (nothing to do) ")))
             :on-error (lambda (e) (%gs-echo win (format nil " git error: ~a " e)))
             :label "git-action")))
        (%gs-echo win " focus a file first "))))

;;; --- commands + keymap ------------------------------------------------------

(define-command gs-stage   (v e) "Stage the focused file."   (%gs-act (view-root v) :stage))
(define-command gs-unstage (v e) "Unstage the focused file." (%gs-act (view-root v) :unstage))
(define-command gs-discard (v e) "Discard the focused file's changes (with confirm)."
  (%gs-act (view-root v) :discard))
(define-command gs-refresh (v e) "Re-read git state." (%gs-refresh (view-root v)))

(define-command gs-commit (v e)
  "Commit the staged changes, prompting for a message."
  (let* ((win (view-root v)) (root (gsw-root win)))
    (when root
      (if (null (revl-logic::git-status-sections root))       ; first value = staged
          (%gs-echo win " nothing staged to commit ")
          (let ((msg (prompt-string " Commit " "Message:")))
            (when (and msg (plusp (length (string-trim " " msg))))
              (%gs-echo win " committing… ")
              (revision:run-async
               (lambda () (revl-logic::git-commit root msg))
               :then (lambda (ok) (%gs-refresh win) (%gs-echo win (if ok " committed " " commit failed ")))
               :on-error (lambda (e) (%gs-echo win (format nil " commit failed: ~a " e)))
               :label "git-commit")))))))

(define-command gs-toggle (v e)
  "Expand/collapse the focused file's diff (or a section)."
  (let* ((win (view-root v)) (ol (find-view win 'tree)) (n (and ol (ov-current ol))))
    (when (and n (revision:outline-node-expandable-p n))
      (setf (revision:outline-node-expanded n) (not (revision:outline-node-expanded n)))
      (when (revision:outline-node-expanded n) (revision:outline-ensure-children n))
      (invalidate ol))))

(defkeymap *git-status-keys* (*outline-keys*)          ; inherit up/down/left navigation
  (#\s gs-stage) (#\u gs-unstage) (#\k gs-discard) (#\c gs-commit) (#\g gs-refresh)
  (:enter gs-toggle) (:right gs-toggle))

(defmethod status-hints ((win git-status-window))      ; chips while the window is focused
  (list (cons "Stage"   (lambda () (%gs-act win :stage)))
        (cons "Unstage" (lambda () (%gs-act win :unstage)))
        (cons "Discard" (lambda () (%gs-act win :discard)))
        (cons "Commit"  (lambda () (perform 'gs-commit (find-view win 'tree) nil)))
        (cons "Refresh" (lambda () (%gs-refresh win)))))

;;; --- construction + registration --------------------------------------------

(defun make-git-status (&optional (dir *project-dir*))
  "Build a Magit-style git status window for the repository containing DIR (the
tracked project root by default).  Return (values WINDOW FOCUS)."
  (let* ((root (revl-logic::git-root dir))
         (win (make-instance 'git-status-window :root root
                             :title " Git status " :keymap *global-keys*))
         (body (ui (stack
                     (:fill (outline :name 'tree :keymap *git-status-keys*))
                     (1 (static-text :name 'echo :role :status :text ""))
                     (1 (static-text :role :status
                          :text " s stage · u unstage · k discard · c commit · g refresh · Enter diff · Esc close "))))))
    (add-subview win body)
    (%gs-refresh win)
    (setf (window-scroll-target win) (find-view win 'tree) (window-help win) :git-status)
    (values win (find-view win 'tree))))

(defun open-git-status (dt &optional dir)
  "Open the git status window on desktop DT, single-instance.  With DIR, point the
window at that directory's repository (re-targeting an existing window); without it,
open on the default (tracked project) root, or raise the existing window as-is."
  (let ((existing (find-if (lambda (w) (typep w 'git-status-window)) (dt-windows dt))))
    (cond
      (existing
       (when dir (setf (gsw-root existing) (revl-logic::git-root dir)))
       (dt-raise dt existing) (dt-refocus dt) (%gs-refresh existing) (invalidate dt))
      (dir (dt-open dt (lambda () (make-git-status dir))))   ; specific dir: builder fn (not persisted)
      (t   (dt-open dt :git-status)))))                       ; default root: keyword builder (persisted)

(pushnew (cons :git-status #'make-git-status) *window-builders* :key #'car)
