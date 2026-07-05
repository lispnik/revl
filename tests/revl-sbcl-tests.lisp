;;;; revision-sbcl-tests.lisp --- tests for revl's SBCL-specific IDE features (on the revision toolkit).
;;;;
;;;; These exercise the *logic* behind the SBCL-only IDE features (compiler
;;;; notes, sb-di backtraces, sb-aprof, allocation-information, typexpand, GC
;;;; stats, evaluator mode, package locks, sb-cltl2) directly -- no UI needed.
;;;;
;;;; Run from the repo root:  sbcl --script tests/revision-sbcl-tests.lisp

(require :asdf)
;; register this dir tree so revision.asd, tvision.asd and the vendored systems/ deps
;; all resolve without a global ocicl/ASDF config (works on bare CI too).
(asdf:initialize-source-registry
 (list :source-registry (list :tree (uiop:getcwd))
       (list :tree (merge-pathnames "../" (uiop:getcwd))) :inherit-configuration))
(handler-bind ((warning #'muffle-warning)) (asdf:load-system :revl))
(in-package #:revl)

(defvar *pass* 0) (defvar *fail* 0)
(defmacro check (desc form)
  `(handler-case (if ,form (progn (incf *pass*) (format t "  ok   ~a~%" ,desc))
                     (progn (incf *fail*) (format t "  FAIL ~a~%" ,desc)))
     (error (e) (incf *fail*) (format t "  ERR  ~a -- ~a~%" ,desc e))))

;;; ===========================================================================
;;; 1. Compiler notes (sb-ext:compiler-note capture + offset refine)
;;; ===========================================================================
(format t "~&## compiler notes~%")
(multiple-value-bind (status notes)
    (%compile-text-notes
     (format nil "(defun add-floats (a b)~%  (declare (optimize speed))~%  (+ a b))~%")
     (find-package :cl-user))
  (check "compile status is :ok" (eq status :ok))
  (check "captured at least one note" (>= (length notes) 1))
  (check "at least one :note severity" (some (lambda (n) (eq (getf n :severity) :note)) notes))
  (check "a :note carries a non-empty message"      ; exact wording varies by SBCL version
         (some (lambda (n) (and (eq (getf n :severity) :note) (plusp (length (or (getf n :message) ""))))) notes))
  (check "every note carries a position" (every (lambda (n) (integerp (getf n :pos))) notes)))

;; clean code yields no notes
(multiple-value-bind (status notes)
    (%compile-text-notes "(defun plain-id (x) x)" (find-package :cl-user))
  (check "clean code compiles :ok" (eq status :ok))
  (check "clean code yields no notes" (null notes)))

;; offset refinement points at the named symbol
(let ((text "(foo)
(bar BAZ)
"))
  (check "refine-offset locates the offending token"
         (= (%note-refine-offset text 6 "undefined variable: BAZ") (search "BAZ" text))))

;;; ===========================================================================
;;; 2. Cross-thread backtrace (sb-thread:interrupt-thread + print-backtrace)
;;; ===========================================================================
(format t "~%## thread backtrace~%")
(check "self backtrace is a non-empty string"
       (let ((bt (%thread-backtrace sb-thread:*current-thread*)))
         (and (stringp bt) (plusp (length bt)))))
(let* ((gate (sb-thread:make-semaphore))
       (th (sb-thread:make-thread
            (lambda () (sb-thread:wait-on-semaphore gate)) :name "revision-test-victim")))
  (sleep 0.1)
  (let ((bt (%thread-backtrace th)))
    (check "another thread's backtrace is captured" (and (stringp bt) (plusp (length bt))))
    (check "backtrace mentions a stack frame"
           (or (search "SEMAPHORE" (string-upcase bt)) (search "WAIT" (string-upcase bt))
               (search "(" bt))))
  (sb-thread:signal-semaphore gate)
  (ignore-errors (sb-thread:join-thread th :timeout 2))
  (sleep 0.1)
  (check "dead thread reports as dead"
         (string= (%thread-backtrace th) "(thread is dead)")))

;;; ===========================================================================
;;; 3. sb-di frame-local debugger (%capture-backtrace reads frame locals)
;;; ===========================================================================
(format t "~%## sb-di frame locals~%")
(declaim (optimize (debug 3)))
(defun bt-probe (aardvark)
  (let ((zebra (* aardvark 2)))
    (declare (ignorable zebra))
    (%capture-backtrace :count 20)))          ; frames of the live stack, with locals
(multiple-value-bind (frames lives) (bt-probe 21)
  (check "backtrace captured frames" (and (consp frames) (plusp (length frames))))
  (check "frames align with live sb-di frames" (= (length frames) (length lives)))
  (check "the probe frame is present" (some (lambda (f) (search "BT-PROBE" (string-upcase (getf f :label)))) frames))
  (let ((probe (find-if (lambda (f) (search "BT-PROBE" (string-upcase (getf f :label)))) frames)))
    (check "its locals include aardvark = 21"
           (and probe (assoc "aardvark" (getf probe :locals) :test #'string=)
                (string= "21" (second (assoc "aardvark" (getf probe :locals) :test #'string=)))))
    (check "locals are (name value-string) pairs"
           (and probe (every (lambda (l) (and (stringp (first l)) (stringp (second l))))
                             (getf probe :locals))))))

;;; ===========================================================================
;;; 4. call-tree tracing (sb-int:encapsulate recording + system-symbol guard)
;;; ===========================================================================
(format t "~%## call tree~%")
(defun ct-probe (n) (if (<= n 0) 0 (ct-probe (1- n))))
(%ct-clear)
(check "refuses to watch a CL built-in" (eq (%ct-watch 'length) :system))
(check "length was NOT encapsulated" (not (member 'length *ct-watched*)))
(%ct-watch 'ct-probe)
(ct-probe 3)
(let ((rows (%ct-snapshot)))
  (check "recorded nested calls" (>= (length rows) 4))
  (check "top row is a :call to ct-probe" (and (eq (first (first rows)) :call) (eq (third (first rows)) 'ct-probe)))
  (check "records a :return" (some (lambda (r) (eq (first r) :return)) rows))
  (check "row labels render as strings" (every (lambda (r) (stringp (%ct-row-label r))) rows)))
(%ct-unwatch 'ct-probe)
(check "unwatch removes it" (not (member 'ct-probe *ct-watched*)))

;;; ===========================================================================
;;; 5. SBCL feature tools (typexpand, allocation, GC, evaluator mode, locks, cltl2)
;;; ===========================================================================
(format t "~%## SBCL feature tools~%")
(check "typexpand-1 expands a derived type"
       (equal (multiple-value-list (sb-ext:typexpand-1 '(mod 8))) '((integer 0 7) t)))
(check "typexpand fully expands to a primitive"
       (subtypep (sb-ext:typexpand 'sb-impl::index) 'integer))
(check "generation-of: a heap object has a generation" (integerp (sb-kernel:generation-of (make-array 3))))
(check "generation-of: a fixnum is immediate (nil)"    (null (sb-kernel:generation-of 5)))
(check "GC stats text mentions consed + space"
       (let ((txt (%gc-stats-text))) (and (search "consed" txt) (search "space" txt))))
(check "aprof availability is a boolean" (member (%aprof-available-p) '(t nil)))
(check "evaluator mode is :compile or :interpret" (member sb-ext:*evaluator-mode* '(:compile :interpret)))
(check "package-locked-p: CL is locked" (sb-ext:package-locked-p (find-package :cl)))
(check "cltl2 function-information: CAR is a function" (eq (sb-cltl2:function-information 'car nil) :function))
(check "cltl2 declaration-information: OPTIMIZE is an alist" (consp (sb-cltl2:declaration-information 'optimize nil)))

;;; ===========================================================================
;;; Keybinding reference: the committed KEYBINDINGS.md must match the generator,
;;; so a binding change without `make keybindings` fails here (no doc drift).
;;; ===========================================================================
(check "KEYBINDINGS.md matches the keymaps (run `make keybindings` after a rebind)"
       (string= (keybinding-markdown) (uiop:read-file-string "KEYBINDINGS.md")))
(check "no keymap binding names an unregistered command (PERFORM would error)"
       (null (unknown-command-bindings)))

;;; ===========================================================================
;;; git status porcelain (revl-logic git-status.lisp) — temp-repo round-trip
;;; ===========================================================================
(format t "~%## git status~%")
(let ((repo (uiop:ensure-directory-pathname
             (format nil "~arevl-gs-~36r/" (uiop:temporary-directory) (get-universal-time)))))
  (flet ((git (&rest args)
           (sb-ext:run-program "git" (list* "-C" (namestring repo) args)
                               :search t :output nil :error nil :wait t)))
    (unwind-protect
         (progn
           (ensure-directories-exist repo)
           (git "init" "-q") (git "config" "user.email" "t@e.x") (git "config" "user.name" "T")
           (with-open-file (s (merge-pathnames "a.txt" repo) :direction :output :if-exists :supersede)
             (write-line "one" s))
           (git "add" "a.txt") (git "commit" "-qm" "init")
           (with-open-file (s (merge-pathnames "a.txt" repo) :direction :output :if-exists :append)
             (write-line "two" s))                                   ; modify -> unstaged
           (with-open-file (s (merge-pathnames "b.txt" repo) :direction :output :if-exists :supersede)
             (write-line "new" s))                                   ; untracked
           (let ((root (revl-logic::git-root repo)))
             (check "git-root finds the repo" (and root (stringp root)))
             (check "git-current-branch is non-nil" (stringp (revl-logic::git-current-branch root)))
             (multiple-value-bind (staged unstaged untracked) (revl-logic::git-status-sections root)
               (check "nothing staged initially" (null staged))
               (check "a.txt is unstaged" (member "a.txt" unstaged :key #'car :test #'string=))
               (check "b.txt is untracked" (member "b.txt" untracked :key #'car :test #'string=)))
             (check "git-file-diff shows an added line"
                    (some (lambda (l) (and (plusp (length l)) (char= (char l 0) #\+)))
                          (revl-logic::git-file-diff root "a.txt")))
             (check "git-stage succeeds" (revl-logic::git-stage root "a.txt"))
             (check "a.txt moves to staged"
                    (member "a.txt" (revl-logic::git-status-sections root) :key #'car :test #'string=))
             (check "git-unstage succeeds" (revl-logic::git-unstage root "a.txt"))
             (check "a.txt no longer staged"
                    (not (member "a.txt" (revl-logic::git-status-sections root) :key #'car :test #'string=)))
             (revl-logic::git-stage root "a.txt")
             (check "git-commit succeeds" (revl-logic::git-commit root "second"))
             (check "nothing staged after commit" (null (revl-logic::git-status-sections root)))
             (check "empty commit message is rejected" (not (revl-logic::git-commit root "   ")))
             (check "git-discard deletes an untracked file"
                    (and (revl-logic::git-discard root "b.txt" :untracked t)
                         (not (probe-file (merge-pathnames "b.txt" repo)))))
             (check "git-root is NIL outside a repo"
                    (null (revl-logic::git-root (uiop:temporary-directory))))))
      (ignore-errors (uiop:delete-directory-tree repo :validate (constantly t))))))

;; Project manager -> git status: %PM-FOCUS-ROOT falls back to the primary root when
;; nothing is focused, so "Git status" (g) operates on the project root.
(let ((pw (make-instance 'project-window :dir (uiop:ensure-directory-pathname (uiop:getcwd)))))
  (check "%pm-focus-root falls back to the primary project root"
         (equal (namestring (%pm-focus-root pw)) (namestring (pw-dir pw)))))

;;; ===========================================================================
;;; desktop persistence: each window contributes restorable state (WINDOW-SAVE-STATE
;;; / WINDOW-RESTORE-STATE), so a saved layout reopens a full session, not just windows.
;;; ===========================================================================
(format t "~%## desktop persistence~%")
(let* ((w (make-editor)) (te (find-view w 'edit)))
  (te-set-text te "PERSISTED-SCRATCH") (setf (te-modified te) t)
  (let ((st (window-save-state w)) (w2 (make-editor)))
    (check "editor save-state captures unsaved scratch text" (equal (second st) "PERSISTED-SCRATCH"))
    (window-restore-state w2 st)
    (check "editor restore-state restores the text"
           (search "PERSISTED-SCRATCH" (te-text (find-view w2 'edit))))))
(let ((w (make-repl)))
  (setf (repl-package w) (find-package :keyword) (repl-history w) '("(+ 1 2)" "(list :a)"))
  (let ((st (window-save-state w)) (w2 (make-repl)))
    (check "REPL save-state captures package + input history"
           (and (equal (getf st :package) "KEYWORD") (equal (getf st :history) '("(+ 1 2)" "(list :a)"))))
    (window-restore-state w2 st)
    (check "REPL restore-state restores package + history"
           (and (eq (repl-package w2) (find-package :keyword))
                (equal (repl-history w2) '("(+ 1 2)" "(list :a)"))))))
(let* ((base (namestring (uiop:getcwd))) (w (make-project base)) (ol (find-view w 'tree))
       (dir (find-if #'outline-node-loader (outline-node-children (first (outline-roots ol))))))
  (when dir (setf (outline-node-expanded dir) t) (outline-ensure-children dir))
  (let ((st (window-save-state w)) (w2 (make-project base)))
    (check "project save-state records the expanded folder"
           (and dir (member (outline-node-data dir) (getf st :open) :test #'equal)))
    (window-restore-state w2 st)
    (let ((dir2 (and dir (find (outline-node-data dir)
                               (outline-node-children (first (outline-roots (find-view w2 'tree))))
                               :key #'outline-node-data :test #'equal))))
      (check "project restore-state re-expands the folder" (and dir2 (outline-node-expanded dir2))))))

;;; ===========================================================================
(format t "~%~d passed, ~d failed~%" *pass* *fail*)
(sb-ext:exit :code (if (zerop *fail*) 0 1))
