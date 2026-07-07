;;;; pty_smoke.lisp --- end-to-end pty smoke tests for the revl binary.
;;;;
;;;; Drives the *built* ./revl through a pseudo-terminal (via the
;;;; revision-pty-driver sibling project) and asserts on the reconstructed screen,
;;;; so the integrated IDE flows -- the consolidated framed menu, the SLIME-style
;;;; REPL with clickable presentations + completion, the editor's frame indicator,
;;;; the call tree, an SBCL tool and Unicode editing -- are guarded too.
;;;;
;;;; Exit 0 = all passed, 1 = a failure.  Windows are opened by KEYBOARD (Alt-w +
;;;; Enter/Down) because a *clicked* first menu item lets the release land on the
;;;; window beneath and steal focus.

(require :asdf)
(let ((asd (truename (format nil "~a../../revision-pty-driver/revision-pty-driver.asd"
                             (directory-namestring *load-pathname*)))))
  (asdf:load-asd asd))
(handler-bind ((warning #'muffle-warning)) (asdf:load-system :revision-pty-driver))

(defpackage #:revl-smoke (:use #:common-lisp #:revision-pty-driver))
(in-package #:revl-smoke)

(defun binary ()
  (or (sb-ext:posix-getenv "REVL_BIN")
      (namestring (truename (format nil "~a../revl" (directory-namestring *load-pathname*))))))

(let ((d (launch (binary) :cols 130 :rows 30)))
  (unwind-protect
       (progn
         ;; 1. consolidated, framed menu bar
         (check d "menu bar (File/Edit/Lisp/Window/Options)"
                (and (wait-for d "Lisp") (found? d "File") (found? d "Options") (not (found? d "Debug  "))))
         (open-menu d #\l)
         (check d "framed Lisp menu with submenus"
                (and (wait-for d "Eval / compile") (found? d "Navigate") (found? d "SBCL")))

         ;; 2. SBCL tool (done first: no REPL banner, so "SBCL" is unambiguous)
         (menu-item d "SBCL")
         (check d "SBCL submenu" (wait-for d "Type expand"))
         (menu-item d "Type expand")
         (check d "typexpand prompt" (wait-for d "Type specifier"))
         (type-text d "(mod 8)") (key d "enter")
         (check d "typexpand result (integer 0 7)" (wait-for d "0 7"))
         (key d "esc")

         ;; 2b. Settings dialog exposes the status-note timeout (checked early, before clutter)
         (open-menu d #\o) (menu-item d "Settings")
         (check d "Settings exposes the status-note timeout" (wait-for d "Status-note timeout"))
         (key d "esc")

         ;; 3. REPL: open, eval, floating prompt, presentation click, completion
         (open-menu d #\t) (key d "enter")                   ; Tools -> Lisp REPL
         (check d "REPL opens (numbered title)" (wait-for d "Lisp REPL 1"))
         (type-text d "(list 1 2 3)") (key d "enter")
         (check d "REPL evaluates" (wait-for d "=> (1 2 3)"))
         (check d "prompt floats after output (inline CL-USER>)" (found? d "CL-USER>"))
         (click-text d "=> (1 2 3)" :dx 3)                    ; SLY-style presentation (click into the text)
         (check d "clicking a result inspects the live object"
                (or (wait-for d "Inspector") (found? d "[0]")))
         (key d "esc")
         (type-text d "(list-all-pack") (key d "tab")         ; Tab completion
         (check d "Tab completion" (wait-for d "list-all-packages"))
         (type-text d ")") (key d "enter") (drain d 0.6)

         ;; 4. editor: open, classic bottom-frame line:col + INS indicator
         (open-menu d #\f) (key d "enter")     ; File -> New (editor)
         (check d "editor opens" (wait-for d "scratch"))
         (ctrl d #\a) (key d "del")                           ; clear the scratch buffer
         (type-text d "(defun demo (x) (* x x))") (key d "home")
         (check d "frame indicator shows 1:1" (wait-for d "1:1"))
         (check d "frame indicator shows INS" (found? d "INS"))
         (ctrl d #\Space)                                     ; terminal-portable selection: set mark
         (key d "right") (key d "right")                      ; plain arrows extend (only possible with a mark set)
         (check d "Ctrl-Space mark + plain arrows select" (wait-for d "sel"))
         (ctrl d #\Space) (key d "home")                      ; clear the mark, back to start
         (drag-text d "defun" :from 0 :to 5)                  ; mouse: click-drag selects text
         (check d "mouse drag selects text" (found? d "sel"))
         (key d "home")                                       ; collapse the selection

         ;; 5. call tree (Lisp -> Debug / trace -> Call tree)
         (open-menu d #\l) (menu-item d "Debug / trace") (menu-item d "Call tree")
         (check d "call tree window opens" (wait-for d "watched"))
         (key d "esc")

         ;; 6. Unicode editing (wide CJK + accents + emoji)
         (open-menu d #\f) (key d "enter")
         (wait-for d "scratch")
         (ctrl d #\a) (key d "del")
         (type-text d "日本語 café 🎉")
         (check d "wide/multi-script text renders" (and (found? d "日本語") (found? d "café")))

         ;; 7. newly-ported parity features (save-as, rename, pop-back, theme, window list, clear)
         ;; NB: %tool-note raises the REPL over the editor, so do Save-As (needs the
         ;; editor focused) before any note-producing action, and assert the others
         ;; via their transcript notes.
         (open-menu d #\f) (key d "enter") (wait-for d "scratch")
         (ctrl d #\a) (key d "del") (type-text d "(defun foo")   ; cursor rests on the symbol
         (open-menu d #\e)
         (check d "Edit menu exposes Undo/Cut/Copy/Paste/Select all"
                (and (found? d "Undo") (found? d "Cut") (found? d "Copy") (found? d "Paste") (found? d "Select all") (found? d "History search")))
         (key d "esc")
         (open-menu d #\f) (menu-item d "Save as")               ; editor still focused (no note yet)
         (check d "Save dialog opens (Save file / Name field)" (and (wait-for d "Save file") (found? d "Name")))
         (key d "esc")
         (open-menu d #\e) (menu-item d "Rename symbol")
         (check d "rename-symbol prompt" (wait-for d "Rename foo"))
         (type-text d "bar") (key d "enter")
         (check d "rename rewrites the symbol (1 occurrence)" (wait-for d "renamed 1 occurrence of foo"))
         (open-menu d #\l) (menu-item d "Navigate") (menu-item d "Pop back")
         (check d "pop-back reports the empty stack" (wait-for d "location stack is empty"))
         (open-menu d #\o) (menu-item d "Colour theme")
         (check d "colour theme cycles to Dark" (wait-for d "colour theme: Dark"))
         (check d "status note auto-clears after a few seconds" (wait-gone d "colour theme: Dark" :timeout 8))
         (open-menu d #\w) (menu-item d "List")
         (check d "window list dialog lists open windows" (and (wait-for d "Windows") (found? d "scratch")))
         (key d "esc")
         (open-menu d #\t) (key d "enter") (wait-for d "Lisp REPL")   ; raise/focus a REPL, give it output
         (type-text d "(* 7 9)") (key d "enter")
         (check d "REPL shows eval output" (wait-for d "=> 63"))
         (open-menu d #\f) (menu-item d "Clear REPL")
         (check d "Clear REPL empties the transcript" (wait-gone d "=> 63" :timeout 4))

         ;; 8. Settings controls are wired live, + Ctrl-U clears an input field.
         ;; Open Settings by KEYBOARD (Alt-o + Enter): clicking the first menu item
         ;; over a window lets the mouse-release steal focus and it won't open.
         (open-menu d #\f) (key d "enter") (wait-for d "scratch")
         (ctrl d #\a) (key d "del") (type-text d "(defun a ())")
         (open-menu d #\o) (key d "enter")
         (check d "Settings opens with a Colour-theme radio" (wait-for d "Colour theme"))
         (key d "down") (key d "down") (key d "down") (key d "space")   ; check "Line numbers"
         (check d "a Settings feature toggle applies to open editors" (wait-for d "editor features applied"))
         (key d "esc")
         (check d "the editor now shows a line-number gutter" (wait-for d "1 (defun a"))
         (open-menu d #\f) (menu-item d "Save as")
         (check d "Save dialog suggests a default file name" (wait-for d "untitled.lisp"))
         (check d "Save dialog shows the active mask hint (*.lisp)" (found? d "(*.lisp)"))
         (ctrl d #\u)
         (check d "Ctrl-U clears the Name field" (wait-gone d "untitled.lisp" :timeout 3))
         (key d "esc")

         ;; 9. TLabel: clicking a linked label focuses its control (Replace dialog).
         (open-menu d #\f) (key d "enter") (wait-for d "scratch")
         (ctrl d #\a) (key d "del") (type-text d "hello world")
         (click-text d "Replace")                            ; editor status chip -> Replace dialog
         (check d "Replace dialog opens" (wait-for d "Replace:"))
         (type-text d "FFF")                                 ; default focus is the Find field
         (click-text d "Replace:")                           ; click the ~R~eplace label
         (type-text d "RRR")
         (check d "clicking a label focuses its linked control (TLabel)"
                (and (found? d "RRR") (not (found? d "FFFRRR"))))
         (key d "esc")

         ;; 10. scrollback windows (REPL + all output windows) show a horizontal
         ;; scrollbar for content wider than the window (a 200-char line overflows
         ;; at any width).  Keyboard hscroll on output windows is covered elsewhere.
         (open-menu d #\t) (key d "enter") (wait-for d "Lisp REPL")
         (type-text d "(write-line (make-string 200 :initial-element #\\=))") (key d "enter")
         (wait-for d "====")
         (check d "wide output shows a horizontal scrollbar" (or (found? d "◄") (found? d "►")))

         ;; 11. Turbo Vision Window-menu keyboard shortcuts (modifier-aware accelerators)
         (ctrl d #\n) (wait-for d "scratch")             ; a fresh editor on top (doesn't bind Ctrl-F5)
         (key d "c-f5") (check d "Ctrl-F5 enters Size/move mode" (wait-for d "Size/move"))
         (key d "enter")
         (alt d #\0) (check d "Alt-0 opens the window list" (wait-for d "Windows"))
         (key d "esc")

         ;; 12. reworked Open dialog (mode :open): title + type-ahead Filter field
         (open-menu d #\f) (menu-item d "Open file")
         (check d "Open dialog has a type-ahead Filter field"
                (and (wait-for d "Open file") (found? d "Filter") (found? d "Hidden")))
         (key d "esc")

         ;; 13. emoji palette: filter by Unicode name, copy, paste elsewhere
         (open-menu d #\t) (menu-item d "Emoji palette")
         (check d "emoji palette opens with a Filter" (and (wait-for d "Emoji palette") (found? d "Filter")))
         (type-text d "thumbs") (drain d 0.4)
         (check d "shows skin-tone variants" (and (found? d "dark skin tone") (found? d "light skin tone")))
         (dotimes (i 6) (key d "bs"))                        ; clear the filter
         (type-text d "party") (drain d 0.4)
         (check d "filters by SBCL char-name (PARTY POPPER)" (found? d "PARTY POPPER"))
         (key d "enter")
         (check d "Enter copies the emoji" (wait-for d "copied"))
         (open-menu d #\f) (key d "enter") (wait-for d "scratch")   ; new editor
         (ctrl d #\a) (key d "del") (ctrl d #\v)
         (check d "the copied emoji pastes into an editor" (found? d "🎉"))

         ;; 14. git status window opens in the integrated IDE (read-only here; the git
         ;; porcelain + staging round-trip is covered by revl-sbcl-tests against a temp repo)
         (open-menu d #\t) (menu-item d "Git status")
         (check d "git status window opens (branch in title)" (wait-for d "Git status" :timeout 5))

         ;; 14b. the Man page viewer (revision-manpage: mandoc -> HTML) is wired into
         ;; Tools: the item prompts for a page and opens the viewer window.  (The
         ;; conversion + rendering itself is covered by revision-manpage's own suite;
         ;; the window title is set before the async load, so this holds regardless of
         ;; which man pages the runner happens to have.)
         (open-menu d #\t) (menu-item d "Man page")
         (check d "Man page prompt opens" (wait-for d "Name:" :timeout 4))
         (type-text d "mandoc") (key d "enter")
         (check d "Man page viewer window opens" (wait-for d "man mandoc" :timeout 6))

         ;; 14c. the Hex editor (revision-hexdump: editable offset·hex·ASCII) is wired
         ;; into Tools: the item opens a file picker that opens the chosen file in a hex
         ;; window.  (Editing + rendering are covered by revision-hexdump's own suite;
         ;; here we confirm the menu wiring reaches the picker and cancels cleanly.)
         (open-menu d #\t) (menu-item d "Hex editor")
         (check d "Hex editor file picker opens" (wait-for d "Open file (hex)" :timeout 4))
         (key d "esc")
         (check d "Hex editor picker cancels" (wait-gone d "Open file (hex)" :timeout 3))

         ;; 15. an unsaved editor is not silently discarded: Esc prompts Save/Discard/Cancel
         (open-menu d #\f) (key d "enter") (wait-for d "scratch")
         (type-text d "zz") (key d "esc")
         (check d "Esc on a modified editor prompts to save" (wait-for d "Unsaved changes"))
         (click-text d "Discard")
         (check d "Discard closes the modified editor" (wait-gone d "Unsaved changes" :timeout 3))

         ;; 16. Window ▸ Close all clears the desktop (unsaved editors prompt -> Discard)
         (open-menu d #\w) (menu-item d "Close all")
         (loop repeat 8 while (wait-for d "Unsaved changes" :timeout 2) do (click-text d "Discard"))
         (check d "Window > Close all removes every window"
                (and (wait-gone d "Emoji palette" :timeout 3) (not (found? d "Lisp REPL")))))
    (quit-driver d))
  (sb-ext:exit :code (report d :title "revl pty smoke")))
