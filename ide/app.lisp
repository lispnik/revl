;;;; app.lisp --- a launcher that composes the ported windows into one IDE.
;;;;
;;;; Each ported window (run-repl, run-editor, …) owns its own WITH-SCREEN
;;;; session.  Rather than nest screens (REVISION's screen isn't reentrant), the
;;;; launcher runs the menu and the chosen window as *sequential* sessions: pick
;;;; a window, it takes over the screen, and closing it returns to the menu.
;;;; This is the "revl on revision" entry point that the revl project drives.

(in-package #:revl)

(defparameter *app-windows*
  (list (cons "Lisp REPL"             #'run-repl)
        (cons "Text editor"           #'run-editor)
        (cons "Project manager"       #'run-project)
        (cons "Package browser"       #'run-packages)
        (cons "ASDF system browser"   #'run-systems)
        (cons "Thread monitor"        #'run-threadmon)
        (cons "HTML browser"          #'run-html)
        (cons "Kitchen-sink demo"     #'run))
  "Launcher entries: (LABEL . THUNK).")

(defun run-menu ()
  "Show the launcher menu in its own screen session; return the chosen THUNK, or
NIL when the user quits."
  (let ((choice nil))
    (revision:with-screen (s)
      (let ((win (ui (window (:title " revl on revision — launcher " :keymap *global-keys*)
                       (stack
                         (1 (static-text :role :label
                              :text " Choose a window — ↑/↓ then Enter; Esc or q to quit: "))
                         (:fill (list-box :name 'menu :items (mapcar #'car *app-windows*)
                                  :on-activate (lambda (lb item) (declare (ignore item))
                                                 (setf choice (nth (list-selected lb) *app-windows*)
                                                       *running* nil))))
                         (1 (static-text :role :status
                              :text " every window runs on the revision kernel; close it (q/Esc) to return here ")))))))
        (layout win (rect 0 0 (revision:screen-width s) (revision:screen-height s)))
        (setf (context-root *context*) win
              (container-focus win) (find-view win 'menu)
              *ui-thread* sb-thread:*current-thread* *running* t (context-dirty *context*) t)
        (loop while *running* do
          (when (context-dirty *context*)
            (revision:hide-cursor s)
            (draw win) (revision:flush-screen s) (setf (context-dirty *context*) nil))
          (revision::pump-input s 0.05)
          (let ((tev (revision::screen-next-event s)))
            (when tev (let ((ev (translate tev))) (when ev (handle-event win ev))))))))
    (cdr choice)))

;;; --- user config: ~/.config/revl/{early-init,init}.lisp --------------------
;;; Two optional startup files, loaded (in the REVL package) by the desktop's
;;; layout-restore hooks: early-init.lisp runs *before* the previous session's
;;; windows are restored, init.lisp *after* (so it may inspect / add to them).
;;; A missing file is skipped; an error in one is logged (REVISION-LOG), not fatal.

(defun %revl-config-file (name)
  "The path ~/.config/revl/NAME."
  (merge-pathnames (concatenate 'string ".config/revl/" name) (user-homedir-pathname)))

(defun %load-revl-config (name)
  "Load ~/.config/revl/NAME in the REVL package, if it exists; errors are logged, not fatal."
  (let ((file (%revl-config-file name)))
    (when (probe-file file)
      (ignoring-errors ("revl user config")
        (let ((*package* (find-package '#:revl)))
          (load file))))))

(defun run-app ()
  "Run the revision-based revl IDE (the full Turbo-Vision-style desktop shell: menu bar +
status bar + hosted windows; see RUN-DESKTOP).  Loads the user config from ~/.config/revl/ --
early-init.lisp before the saved layout is restored, init.lisp after."
  (setf *before-layout-restore* (lambda () (%load-revl-config "early-init.lisp"))
        *after-layout-restore*  (lambda () (%load-revl-config "init.lisp")))
  (run-desktop))

;;; --- the IDE's desktop menus -----------------------------------------------
;;; The generic revision shell provides only ≡ / Window / Options(toolkit) / Help(this
;;; window).  The IDE contributes File and Tools, and adds its own Options + Help items
;;; (which %ORDER-MENUS merges into the shell's), by pushing to *EXTRA-MENUS*.

(register-menu :file
      (lambda (dt)
        (flet ((any-win () (lambda () (dt-top dt))))
          (list "File"
                (list "New"            (lambda () (dt-open dt :editor)) (ctrl #\n))
                (list "Open file…"     (lambda () (let ((p (make-file-dialog :dir *project-dir* :title " Open file ")))
                                                    (when p (dt-open dt (lambda () (make-editor p)))))) :f3)
                (list "Change dir…"    (lambda () (let ((p (make-file-dialog :dir *project-dir* :dirs-only t :title " Change dir ")))
                                                    (when p (setf *project-dir* (uiop:ensure-directory-pathname p))))))
                :--
                (list "Save"           (lambda () (revision::%dt-save dt)) :f2 (any-win))
                (list "Save as…"       (lambda () (revision::%dt-save-as dt)) nil (any-win))
                (list "Save all"       (lambda () (revision::%dt-save-all dt)) nil (any-win))
                (list "Reload file"    (lambda () (revision::%dt-reload dt)) nil (any-win))
                :--
                (list "Save transcript…"  (lambda () (%dt-save-transcript dt)))
                (list "Save Lisp script…" (lambda () (%dt-save-script dt)))
                (list "Clear REPL"        (lambda () (%dt-clear-repl dt)))
                :--
                (list "Save layout"    (lambda () (dt-save-layout dt)))
                (list "Restore layout" (lambda () (mapc (lambda (w) (dt-close-window dt w)) (copy-list (dt-windows dt)))
                                         (dt-load-layout dt)) nil (lambda () t))
                :--
                (list "Exit"           (lambda () (setf *app-done* t)) (cons #\x revision::+md-alt+))))))

;; The Terminal window is the reusable revision-term widget (libvterm-backed): a
;; real shell/child process on a pty, emulated and rendered into a revision view.
(register-window :terminal (lambda () (revision-term:make-terminal)))

;; The Man page viewer is the reusable revision-manpage widget (mandoc -> HTML).  It
;; self-registers its :man-page builder; we place its menu item ourselves (below,
;; next to Terminal), so suppress its own auto-added Tools item to avoid a duplicate.
(setf revision-manpage:*auto-menu* nil)

;; The Hex editor is the reusable revision-hexdump widget (editable offset·hex·ASCII).
;; Same story: it self-registers its :hexdump builder; we place the menu item below,
;; so suppress its own auto-added Tools item.
(setf revision-hexdump:*auto-menu* nil)

(register-menu :tools
      (lambda (dt)
        (list "Tools"
              (list "Lisp REPL"       (lambda () (dt-open dt :repl))
                    (cons :f2 revision::+md-alt+))                            ; Alt-F2 = new REPL
              (list "Project manager" (lambda () (dt-open dt :project)))
              (list "Package browser" (lambda () (dt-open dt :packages)))
              (list "ASDF systems"    (lambda () (dt-open dt :systems)))
              (list "Thread monitor"  (lambda () (dt-open dt :threads)))
              (list "Git status"      (lambda () (open-git-status dt)))
              (list "Terminal"        (lambda () (dt-open dt :terminal)))
              (list "Man page…"       (lambda () (revision-manpage:prompt-man-page dt)))
              (list "Hex editor…"     (lambda () (revision-hexdump:prompt-hexdump dt)))
              (list "HTML browser"    (lambda () (dt-open dt :html)))
              (list "Package table"   (lambda () (dt-open dt :ptable)))
              (list "Emoji palette"   (lambda () (dt-open dt :emoji))))))

(register-menu :options-eval
      (lambda (dt)
        (declare (ignore dt))
        (list "Options"
              (list "Eval timing"     (lambda () (setf *repl-time* (not *repl-time*))
                                        (revision::%tool-note (if *repl-time* "eval timing ON" "eval timing OFF")))))))

(register-menu :help
      (lambda (dt)
        (list "Help"
              (list "Contents"        (lambda () (dt-open dt (lambda () (make-help :general)))))
              (list "Keybindings"     (lambda () (dt-open dt (lambda () (make-help :keys)))))
              (list "Topics" :submenu
                    (list "Lisp REPL"       (lambda () (dt-open dt (lambda () (make-help :repl)))))
                    (list "Text editor"     (lambda () (dt-open dt (lambda () (make-help :editor)))))
                    (list "Project manager" (lambda () (dt-open dt (lambda () (make-help :project)))))
                    (list "Browsers"        (lambda () (dt-open dt (lambda () (make-help :browser)))))
                    (list "HTML browser"    (lambda () (dt-open dt (lambda () (make-help :html)))))
                    (list "Thread monitor"  (lambda () (dt-open dt (lambda () (make-help :threads))))))
              :--
              (list "About…"          (lambda () (revision::%about-dialog))))))

;;; contribute the IDE's keymaps to the (toolkit-owned) keybinding reference, so the
;;; generated KEYBINDINGS.md documents the Inspector / Project / REPL / Call-tree keys.
(setf revision:*reference-keymaps*
      (append revision:*reference-keymaps*
              (list (cons "Inspector"    '*inspector-keys*)
                    (cons "Project tree" '*proj-keys*)
                    (cons "Git status"   '*git-status-keys*)
                    (cons "REPL input"   '*repl-input-keys*)
                    (cons "Call-tree"    '*call-tree-keys*))))
