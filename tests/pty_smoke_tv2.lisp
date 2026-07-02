;;;; pty_smoke_tv2.lisp --- end-to-end pty smoke tests for the tvlisp-tv2 binary.
;;;;
;;;; tests/tvlisp-tests.lisp covers the framework-agnostic logic in isolation;
;;;; this drives the *built* ./tvlisp-tv2 through a pseudo-terminal (via the
;;;; tvision-pty-driver sibling project) and asserts on the reconstructed screen,
;;;; so the integrated IDE flows -- the consolidated framed menu, the SLIME-style
;;;; REPL with clickable presentations + completion, the editor's frame indicator,
;;;; the call tree, an SBCL tool and Unicode editing -- are guarded too.
;;;;
;;;; Exit 0 = all passed, 1 = a failure.  Windows are opened by KEYBOARD (Alt-w +
;;;; Enter/Down) because a *clicked* first menu item lets the release land on the
;;;; window beneath and steal focus.

(require :asdf)
(let ((asd (truename (format nil "~a../../tvision-pty-driver/tvision-pty-driver.asd"
                             (directory-namestring *load-pathname*)))))
  (asdf:load-asd asd))
(handler-bind ((warning #'muffle-warning)) (asdf:load-system :tvision-pty-driver))

(defpackage #:tvlisp-tv2-smoke (:use #:common-lisp #:tvision-pty-driver))
(in-package #:tvlisp-tv2-smoke)

(defun binary ()
  (or (sb-ext:posix-getenv "TVLISP_TV2_BIN")
      (namestring (truename (format nil "~a../tvlisp-tv2" (directory-namestring *load-pathname*))))))

(let ((d (launch (binary) :cols 100 :rows 30)))
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

         ;; 3. REPL: open, eval, floating prompt, presentation click, completion
         (open-menu d #\w) (key d "enter")                   ; Window -> Lisp REPL
         (check d "REPL opens" (wait-for d "Lisp REPL"))
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
         (open-menu d #\w) (key d "down") (key d "enter")     ; Window -> Text editor
         (check d "editor opens" (wait-for d "Text editor"))
         (ctrl d #\a) (key d "del")                           ; clear the scratch buffer
         (type-text d "(defun demo (x) (* x x))") (key d "home")
         (check d "frame indicator shows 1:1" (wait-for d "1:1"))
         (check d "frame indicator shows INS" (found? d "INS"))

         ;; 5. call tree (Lisp -> Debug / trace -> Call tree)
         (open-menu d #\l) (menu-item d "Debug / trace") (menu-item d "Call tree")
         (check d "call tree window opens" (wait-for d "watched"))
         (key d "esc")

         ;; 6. Unicode editing (wide CJK + accents + emoji)
         (open-menu d #\w) (key d "down") (key d "enter")
         (wait-for d "Text editor")
         (ctrl d #\a) (key d "del")
         (type-text d "日本語 café 🎉")
         (check d "wide/multi-script text renders" (and (found? d "日本語") (found? d "café"))))
    (quit-driver d))
  (sb-ext:exit :code (report d :title "tvlisp-tv2 pty smoke")))
