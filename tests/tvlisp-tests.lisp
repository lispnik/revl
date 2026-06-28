;;;; tvlisp-tests.lisp --- unit tests for the parts of tvlisp that extend the
;;;; tvision library: the REPL backend, the threaded debugger, the object
;;;; inspector and the thread monitor (src/repl.lisp, src/threadmon.lisp).
;;;;
;;;; On FiveAM (a test-only dependency), mirroring the core tvision test harness:
;;;; DEFTEST / OK / IS= are thin wrappers over FiveAM's TEST / IS-TRUE / IS.
;;;;
;;;; Run with:  (tvision-tvlisp-tests:run-tests)   ; returns the failure count
;;;; or:        make test-lisp

(defpackage #:tvision-tvlisp-tests
  (:use #:common-lisp #:tvision)
  (:export #:run-tests #:toplevel #:tvlisp-suite))

(in-package #:tvision-tvlisp-tests)

;;; ---------------------------------------------------------------------------
;;; Harness: FiveAM with the same small compatibility vocabulary tvision uses
;;; ---------------------------------------------------------------------------

(5am:def-suite tvlisp-suite
  :description "tvlisp REPL / debugger / inspector / thread-monitor tests.")
(5am:in-suite tvlisp-suite)

(defmacro deftest (name &body body)
  "Define a FiveAM test NAME in the tvlisp suite."
  `(5am:test ,name ,@body))

(defmacro ok (desc form)
  "Assert FORM is true; DESC is the failure description."
  `(5am:is-true ,form "~a" ,desc))

(defmacro is= (desc actual expected &key (test '#'equal))
  "Assert (TEST ACTUAL EXPECTED); DESC labels the check."
  (let ((a (gensym)) (e (gensym)))
    `(let ((,a ,actual) (,e ,expected))
       (5am:is (funcall ,test ,a ,e) "~a -- got ~s, want ~s" ,desc ,a ,e))))

(defun make-test-screen ()
  (let ((s (tvision::make-screen)))
    (setf (tvision::screen-out s) (make-string-output-stream))
    (screen-resize s 80 25)
    s))

(defun run-tests ()
  "Run the suite under FiveAM; print the report; return the failure count.
The screen and REPL globals the tests rely on are bound for the whole run."
  (let ((*screen* (make-test-screen))
        (*repl-async* nil)            ; keep the REPL inline in tests
        (*repl-debugger* nil)
        (5am:*on-error* nil) (5am:*on-failure* nil))   ; record, never enter the debugger
    (let* ((results (5am:run 'tvlisp-suite))
           (failures (nth-value 1 (5am:results-status results)))
           (nfail (length failures)))
      (5am:explain! results)
      (format t "~&==== ~d checks, ~d failure~:p ====~%" (length results) nfail)
      nfail)))

(defun toplevel ()
  (sb-ext:exit :code (if (zerop (run-tests)) 0 1)))

;;; --- helpers (shared with the core tvision suite) --------------------------

(defun host (control &optional (bounds (make-trect 0 0 78 23)))
  "Insert CONTROL into a fresh full-size window so it has an owner (for focus,
broadcasts and drawing); return the control."
  (let ((w (make-instance 'twindow :title "host" :bounds bounds)))
    (insert w control)
    control))

(defun focused (v)
  (setf (view-state v) (logior (view-state v) +sf-focused+))
  v)

(defun ev-key (code &optional (char 0) (mods 0))
  (make-event :type +ev-key-down+ :key-code code :char-code char :modifiers mods))

(defun type-char (v ch)
  (handle-event v (ev-key (char-code ch) (char-code ch))))

(defun press-key (v code)
  (handle-event v (ev-key code 0)))

(defun cell-char-at (x y)
  (tvision::cell-char (aref (screen-back-buffer *screen*)
                           (tvision::screen-index *screen* x y))))

(defun text-at (x y len)
  (coerce (loop for i below len collect (cell-char-at (+ x i) y)) 'string))

;;; ===========================================================================
;;; Inspector (object->outline, tinspector-window)
;;; ===========================================================================

(deftest inspector-tree
  ;; object->outline stores each value in its node so the inspector can drill in
  (let* ((obj (list 10 20 (list 30 40)))
         (node (tvision::object->outline obj "*")))
    (is= "root holds the object" (outline-node-data node) obj)
    (is= "three children" (length (outline-node-children node)) 3)
    (let ((third (third (outline-node-children node))))
      (is= "child label" (subseq (outline-node-text third) 0 3) "[2]")
      (is= "child holds the sub-list" (outline-node-data third) (third obj))
      (is= "sub-list has two children" (length (outline-node-children third)) 2))
    ;; strings are leaves (not exploded char by char), but still carry their value
    (let ((sn (tvision::object->outline "hi" "s")))
      (is= "string node value" (outline-node-data sn) "hi")
      (ok "string node has no children" (null (outline-node-children sn))))))

(deftest inspector-cycles
  ;; a value that points back to an ancestor object is rendered as a leaf marked
  ;; [circular ref], not expanded again (so the inspector can't loop on cycles)
  (let ((v (vector 1 2 nil)))
    (setf (aref v 2) v)                       ; v[2] = v -> a reference cycle
    (let* ((node (tvision::object->outline v "v"))
           (kids (outline-node-children node)))
      (is= "vector shows its three slots" (length kids) 3)
      (let ((back (third kids)))
        (ok "the self-reference is marked circular"
            (search "[circular ref]" (outline-node-text back)))
        (ok "the circular node is a leaf (not re-expanded)"
            (null (outline-node-children back)))
        (is= "the circular node still carries the value" (outline-node-data back) v))))
  ;; a shared-but-acyclic value is NOT mistaken for a cycle (siblings re-expand)
  (let* ((shared (list 7))
         (node (tvision::object->outline (list shared shared) "pair"))
         (kids (outline-node-children node)))
    (is= "both siblings present" (length kids) 2)
    (ok "neither sibling is flagged circular"
        (notany (lambda (k) (search "[circular ref]" (outline-node-text k))) kids))))

(deftest inspector-symbol
  ;; inspecting a symbol shows its namespace: name, package, value, function, ...
  (defvar *inspector-symbol-test-var* 99)
  (let* ((node (tvision::object->outline '*inspector-symbol-test-var* "v"))
         (labels (mapcar #'outline-node-text (outline-node-children node))))
    (flet ((has (s) (some (lambda (l) (search s l)) labels)))
      (ok "shows symbol-name" (has "symbol-name"))
      (ok "shows package" (has "package"))
      (ok "shows the bound value" (has "value"))))
  ;; a function symbol shows its function cell
  (let* ((node (tvision::object->outline 'car "f"))
         (labels (mapcar #'outline-node-text (outline-node-children node))))
    (ok "function symbol shows its function" (some (lambda (l) (search "function" l)) labels))))

(deftest inspector-edit
  ;; nodes for settable places carry a setter that writes the value back
  (let* ((v (vector 1 2 3))
         (node (tvision::object->outline v "v"))
         (slot (second (outline-node-children node))))   ; the [1] element
    (ok "vector element has a setter" (outline-node-setter slot))
    (funcall (outline-node-setter slot) 99)
    (is= "setter writes through to the vector" (aref v 1) 99))
  ;; hash entries are settable
  (let ((h (make-hash-table)))
    (setf (gethash :k h) 1)
    (let* ((node (tvision::object->outline h "h"))
           (entry (first (outline-node-children node))))
      (ok "hash entry has a setter" (outline-node-setter entry))
      (funcall (outline-node-setter entry) 7)
      (is= "setter updates the hash value" (gethash :k h) 7))))

(deftest inspector-paging
  ;; big collections show one page plus a drillable "... N more" node, instead of
  ;; silently truncating; re-inspecting that node's value pages the remainder
  (let* ((cap tvision::+inspect-page+)
         (big (loop for i below (+ cap 50) collect i))
         (node (tvision::object->outline big "big"))
         (kids (outline-node-children node)))
    (is= "one page of elements plus an overflow node" (length kids) (1+ cap))
    (let ((more (car (last kids))))
      (ok "overflow node is labelled '... more'" (search "more" (outline-node-text more)))
      (is= "overflow carries the un-shown tail" (outline-node-data more) (nthcdr cap big))
      (ok "overflow node is itself a leaf" (null (outline-node-children more)))
      ;; drilling the overflow re-inspects the tail -> the remaining 50 elements
      (let ((page2 (tvision::object->outline (outline-node-data more) "rest")))
        (is= "drilling the overflow pages the rest"
             (length (outline-node-children page2)) 50))))
  ;; a hash-table over the cap reports the overflow count too
  (let ((h (make-hash-table)))
    (dotimes (i (+ tvision::+inspect-page+ 5)) (setf (gethash i h) i))
    (let ((kids (outline-node-children (tvision::object->outline h "h"))))
      (is= "hash-table page plus overflow" (length kids) (1+ tvision::+inspect-page+))
      (ok "overflow counts the rest" (search "5 more" (outline-node-text (car (last kids))))))))

(deftest inspector-back
  ;; drilling re-roots in place and records history; Backspace restores the
  ;; previous object (one window, not a pile of them)
  (let* ((host (make-instance 'twindow :bounds (make-trect 0 0 60 20)))
         (w  (make-instance 'tvision::tinspector-window :bounds (make-trect 0 0 50 16)))
         (ol (make-instance 'toutline
                            :roots (list (tvision::object->outline (list 10 20) "root"))
                            :bounds (make-trect 1 1 48 14))))
    (setf (tvision::inspector-outline w) ol
          (tvision::inspector-current w) (cons (list 10 20) "root"))
    (insert w ol) (insert host w)
    (let ((child (first (outline-node-children (first (outline-roots ol))))))  ; the [0] node
      (is= "drill target is the [0] node" (tvision::%node-label child) "[0]")
      (tvision::%inspector-drill w child)
      (is= "drilling records one history entry" (length (tvision::inspector-history w)) 1)
      (is= "current view is the drilled value" (cdr (tvision::inspector-current w)) "[0]")
      (tvision::%inspector-back w)
      (is= "back empties the history" (length (tvision::inspector-history w)) 0)
      (is= "back restores the previous view" (cdr (tvision::inspector-current w)) "root"))))

(deftest restart-labels
  ;; the debugger labels restarts with their NAME plus their report description
  (restart-case
      (let ((named (find-restart 'retry-now))
            (anon  (find-restart 'plain)))
        (let ((l (tvision::%restart-label named)))
          (ok "named restart shows its symbolic name" (search "RETRY-NOW" l))
          (ok "named restart shows its report text" (search "Retry the operation" l)))
        (ok "restart label is non-empty even without a useful report"
            (plusp (length (tvision::%restart-label anon)))))
    (retry-now () :report "Retry the operation" nil)
    (plain () nil)))

;;; ===========================================================================
;;; Thread monitor
;;; ===========================================================================

(deftest thread-monitor
  (let* ((w (make-thread-window (make-trect 0 0 40 14)))
         (tl (tw-list w)))
    (ok "list populated" (>= (list-count tl) 1))
    (ok "snapshot matches list"
        (= (list-count tl) (length (thread-list-threads tl))))
    (ok "main thread present"
        (member (sb-thread:main-thread) (thread-list-threads tl)))
    (ok "current thread marked *"
        (let ((i (position sb-thread:*current-thread* (thread-list-threads tl))))
          (and i (char= (char (list-item tl i) 0) #\*))))
    ;; backtrace capture of the current thread (the fast self path)
    (let ((bt (tvision::%thread-backtrace sb-thread:*current-thread* 10)))
      (ok "captures a backtrace string for the current thread"
          (and (stringp bt) (plusp (length bt)))))))

;;; ===========================================================================
;;; REPL backend (inline path)
;;; ===========================================================================

(deftest repl-meta-command
  (ok ":help is a meta-command" (tvision::repl-meta-command-p ":help"))
  (ok ":help SYM is a meta-command" (tvision::repl-meta-command-p ":help car"))
  (ok ":h SYM is a meta-command" (tvision::repl-meta-command-p ":h car"))
  (ok "other keywords are not meta-commands" (not (tvision::repl-meta-command-p ":foo")))
  (ok "ordinary forms are not meta-commands" (not (tvision::repl-meta-command-p "(+ 1 2)"))))

(deftest backtrace-export
  (let* ((frames (list (list :label "0  FOO" :locals '(("x" "10" 10) ("y" "20" 20)))
                       (list :label "1  BAR" :locals nil)))
         (txt (tvision::%backtrace-text frames)))
    (ok "includes both frame labels" (and (search "0  FOO" txt) (search "1  BAR" txt)))
    (ok "includes a local and its value" (search "x = 10" txt))))

;;; --- debugger frame ops ---------------------------------------------------

(declaim (notinline %ut-frame-inner))
(defun %ut-frame-inner ()
  "Capture the live stack, then make THIS frame return the value of \"41\" via
the return-from-frame op; if the op doesn't fire, fall through to 99."
  (declare (optimize (debug 3) (speed 0)))
  (multiple-value-bind (bt live) (tvision::repl-capture-stack)
    (let ((idx (position-if (lambda (f)
                              (let ((n (getf f :name)))
                                (and (symbolp n) (string= (symbol-name n) "%UT-FRAME-INNER"))))
                            bt)))
      (when idx (tvision::%frame-return live idx "41"))
      99)))

(defun %ut-frame-outer ()
  (declare (optimize (debug 3) (speed 0)))
  (restart-case (1+ (%ut-frame-inner))
    (tvision::repl-abort () :aborted)))

(deftest debugger-frame-ops
  ;; capture returns index-aligned snapshots + live frames
  (multiple-value-bind (bt live) (tvision::repl-capture-stack)
    (ok "capture returns frames" (consp bt))
    (is= "snapshots and live frames are index-aligned" (length bt) (length live))
    (ok "live entries are sb-di frames"
        (every (lambda (f) (typep f 'sb-di:frame)) live))
    (ok "snapshots carry the raw frame name" (getf (first bt) :name t)))
  ;; return-from-frame actually unwinds and supplies the value:
  ;; inner returns 41 (not 99), so outer's (1+ ...) is 42 (not :aborted)
  (is= "return-from-frame unwinds with the given value" (%ut-frame-outer) 42)
  ;; disassemble works from a name and degrades gracefully on a bad one
  (let ((txt (tvision::%frame-disassemble-text 'car)))
    (ok "disassembles a real function to text" (and (stringp txt) (plusp (length txt)))))
  (let ((txt (tvision::%frame-disassemble-text '#:no-such-fn)))
    (ok "bad disassembly target yields a note, not an error"
        (and (stringp txt) (search "cannot disassemble" txt))))
  ;; machinery classification: signalling/eval/worker-loop frames are internal,
  ;; ordinary user functions are not
  (ok "ERROR is machinery"   (tvision::%frame-internal-p 'error))
  (ok "EVAL is machinery"    (tvision::%frame-internal-p 'eval))
  (ok "(FLET BODY IN RUN) is machinery"
      (tvision::%frame-internal-p (list 'flet 'body 'in (find-symbol "RUN" :tvision))))
  (ok "a user function is not machinery" (not (tvision::%frame-internal-p '%ut-frame-inner)))
  ;; snapshots carry :internal-p, and the default filter hides machinery
  (multiple-value-bind (bt live) (tvision::repl-capture-stack)
    (declare (ignore live))
    (ok "every snapshot has an :internal-p flag"
        (every (lambda (f) (member :internal-p f)) bt))
    (let ((user (tvision::%frame-visible-indices bt nil))
          (all  (tvision::%frame-visible-indices bt t)))
      (ok "show-all reveals at least as many frames as the default view"
          (>= (length all) (length user)))
      (ok "the default view hides this capture's machinery (ERROR/EVAL/RUN)"
          (< (length user) (length all)))
      (ok "filtering never yields an empty frame list" (plusp (length user))))))

;;; --- backtrace browser: error frame, source, row model, restart-frame ------

(defvar *ut-restart-count* 0)
(declaim (notinline %ut-restart-fn))
(defun %ut-restart-fn ()
  "On its first call, restart its own live frame; the second call returns."
  (declare (optimize (debug 3) (speed 0)))
  (incf *ut-restart-count*)
  (if (< *ut-restart-count* 2)
      (multiple-value-bind (bt live) (tvision::repl-capture-stack)
        (let ((idx (position-if (lambda (f)
                                  (let ((n (getf f :name)))
                                    (and (symbolp n) (string= (symbol-name n) "%UT-RESTART-FN"))))
                                bt)))
          (when idx (tvision::%frame-restart live idx))
          :no-restart))                       ; reached only if restart-frame failed
      :second-call))

(deftest debugger-backtrace-browser
  ;; error frame = first non-machinery frame
  (let ((frames (list (list :label "0 A" :internal-p t   :locals nil)
                      (list :label "1 B" :internal-p nil :locals '(("x" "1" 1)))
                      (list :label "2 C" :internal-p nil :locals nil))))
    (is= "error frame is the first user frame" (tvision::%frame-error-index frames) 1)
    ;; row model: filtered frames, with inline locals when a frame is expanded
    (let ((d (make-instance 'tvision::tframe-dialog :frames frames :lb nil)))
      (tvision::%frame-rebuild d)
      (is= "default rows are the two user frames"
           (coerce (tvision::frame-dialog-index-map d) 'list) '((:frame 1) (:frame 2)))
      (setf (tvision::frame-dialog-expanded d) '(1))
      (tvision::%frame-rebuild d)
      (is= "expanding frame 1 inlines its local row"
           (coerce (tvision::frame-dialog-index-map d) 'list)
           '((:frame 1) (:local 1 0) (:frame 2)))
      (setf (tvision::frame-dialog-show-all d) t)
      (tvision::%frame-rebuild d)
      (ok "show-all reveals the machinery frame too"
          (member '(:frame 0) (coerce (tvision::frame-dialog-index-map d) 'list)
                  :test #'equal))))
  ;; source line lookup from a character offset
  (uiop:with-temporary-file (:stream s :pathname p :type "lisp")
    (write-string "(defun a () 1)" s)        ; line 1
    (terpri s) (terpri s)
    (write-string "(defun b () 2)" s)        ; line 3
    (finish-output s)
    (let ((cache (make-hash-table :test 'equal)))
      (is= "offset on line 1 -> line 1" (tvision::%offset->line p 3 cache) 1)
      (is= "offset after two newlines -> line 3" (tvision::%offset->line p 17 cache) 3)))
  ;; restart-frame actually re-runs the frame's function
  (let ((*ut-restart-count* 0))
    (is= "restart-frame re-runs the frame"
         (restart-case (%ut-restart-fn) (tvision::repl-abort () :aborted)) :second-call)
    (is= "the frame ran exactly twice" *ut-restart-count* 2))
  (is= "restart-frame with no live frame aborts gracefully"
       (restart-case (tvision::%frame-restart nil 0) (tvision::repl-abort () :ok)) :ok))

(deftest repl-backend
  (let ((cands (repl-backend-completions "list-len" (find-package :cl))))
    (ok "completion finds list-length" (member "list-length" cands :test #'string=)))
  (let ((r (make-instance 'trepl-view :bounds (make-trect 0 0 40 10))))
    (multiple-value-bind (out results errored) (repl-eval r "(+ 2 3)")
      (declare (ignore out))
      (ok "eval ok" (not errored))
      (is= "eval result" (caar results) 5))
    (repl-eval r "(* 6 7)")
    (is= "per-listener * history" (repl-hvar r '*) 42)))

(deftest repl-fuzzy-completion
  ;; prefix completion still works (and stays prefix-only when it matches)
  (let ((p (repl-backend-completions "list-len" (find-package :cl))))
    (ok "prefix: list-len -> list-length" (member "list-length" p :test #'string=))
    (ok "prefix result has no non-prefix noise"
        (every (lambda (s) (eql 0 (search "list-len" s))) p)))
  ;; flex fallback kicks in only when nothing prefix-matched
  (let ((f (repl-backend-completions "mvb" (find-package :cl))))
    (ok "flex: mvb -> multiple-value-bind" (member "multiple-value-bind" f :test #'string=)))
  ;; %flexp basics
  (ok "flexp subsequence" (tvision::%flexp "mvb" "multiple-value-bind"))
  (ok "flexp respects order" (not (tvision::%flexp "bvm" "multiple-value-bind")))
  (ok "flexp rejects missing char" (not (tvision::%flexp "mvbx" "multiple-value-bind"))))

(deftest repl-presentations
  (let ((r (make-instance 'trepl-view :bounds (make-trect 0 0 40 10)))
        (obj (list 1 2 3)))
    (tvision::repl-present r obj)
    (let ((ps (tvision::repl-presentations r)))
      (is= "one presentation recorded" (length ps) 1)
      (destructuring-bind (o start end) (first ps)
        (ok "object retained by identity" (eq o obj))
        (ok "presentation covers a non-empty range" (< start end))
        (ok "presentation-at finds the object inside its range"
            (eq obj (first (tvision::repl-presentation-at r start))))
        (ok "presentation-at returns nil past the range"
            (null (tvision::repl-presentation-at r end)))))
    ;; a second result presents a distinct, non-overlapping region
    (tvision::repl-present r :other)
    (is= "two presentations now" (length (tvision::repl-presentations r)) 2)))

;;; ===========================================================================
;;; Lisp file editor (the Lisp-aware editing extracted from the generic
;;; tfile-editor into this project's tlisp-file-editor subclass)
;;; ===========================================================================

(deftest lisp-file-editor-auto-indent
  ;; the Lisp editor turns colouring on and auto-indents the new line on Return;
  ;; the generic tfile-editor it subclasses does neither
  (let ((lisp  (focused (host (make-instance 'tlisp-file-editor
                                             :bounds (make-trect 0 0 40 12)))))
        (plain (focused (host (make-instance 'tfile-editor
                                             :bounds (make-trect 0 0 40 12))))))
    (ok "lisp editor highlights"           (text-highlight lisp))
    (ok "plain editor does not highlight"  (not (text-highlight plain)))
    (flet ((open-form-then-return (ed)
             (loop for ch across "(defun f ()" do (type-char ed ch))
             (press-key ed +kb-enter+)
             (text-cur-col ed)))           ; cursor column on the fresh line
      (ok  "lisp editor auto-indents the body" (plusp (open-form-then-return lisp)))
      (is= "plain editor's new line is flush left" (open-form-then-return plain) 0))))

(deftest lisp-file-editor-tab-reindent
  ;; Tab re-indents the current line for Lisp: strip the auto-indent back to
  ;; column 0, then Tab restores the proper indentation under the open form
  (flet ((lead (s) (- (length s) (length (string-left-trim '(#\Space) s)))))
    (let ((ed (focused (host (make-instance 'tlisp-file-editor
                                            :bounds (make-trect 0 0 40 12))))))
      (loop for ch across "(defun f ()" do (type-char ed ch))
      (press-key ed +kb-enter+)                              ; auto-indented line
      (dotimes (_ (text-cur-col ed)) (press-key ed +kb-back+)) ; strip to col 0
      (is= "indent stripped" (lead (nth-line ed (text-cur-line ed))) 0)
      (press-key ed +kb-tab+)                                ; Tab re-indents
      (ok "tab restored the Lisp indent"
          (plusp (lead (nth-line ed (text-cur-line ed))))))))

;;; ===========================================================================
;;; Lisp text intelligence (colouriser, bracket matching, auto-indent engine)
;;; ===========================================================================

(deftest syntax-highlight
  ;; matching-paren scan over a string (offsets); strings/comments are skipped
  (is= "match forward"  (tvision::%paren-match-offset "(a (b) c)" 0) 8)
  (is= "match backward" (tvision::%paren-match-offset "(a (b) c)" 8) 0)
  (is= "match inner"    (tvision::%paren-match-offset "(a (b) c)" 3) 5)
  (is= "paren inside a string is skipped" (tvision::%paren-match-offset "(foo \")\")" 0) 8)
  ;; colouriser: comment / string / keyword differ from the base attribute
  (let* ((base (tvision::make-attr 0 3))            ; black on cyan = the editor base
         (src "(a :kw \"s\") ; c"))
    (multiple-value-bind (attrs instr) (tvision::%lisp-colorize src base nil)
      (ok "line not left in a string" (not instr))
      (ok "plain symbol char stays base" (= (aref attrs 1) base))   ; the 'a'
      (ok "keyword coloured"  (/= (aref attrs (search ":kw" src)) base))
      (ok "string coloured"   (/= (aref attrs (search "\"s\"" src)) base))
      (ok "comment coloured"  (/= (aref attrs (search "; c" src)) base)))
    ;; an unterminated string carries the state to the next line
    (multiple-value-bind (attrs instr) (tvision::%lisp-colorize "\"open" base nil)
      (declare (ignore attrs))
      (ok "unterminated string carries over" instr)))
  ;; auto-indent (per-symbol specs after cl-indent)
  (flet ((ind (s) (tvision::%lisp-indent-at s (length s))))
    (is= "defun body indents +2"      (ind "(defun f (x)") 2)
    (is= "let body indents +2"        (ind "  (let ((x 1))") 4)
    (is= "args align under first arg" (ind "(foo bar") 5)
    (is= "bare open indents +1"       (ind "(") 1)
    (is= "operator alone -> +1"       (ind "(foo") 1)
    (is= "closed form -> 0"           (ind "(foo)") 0)
    (is= "paren in string ignored"    (ind "(foo \";)\" ") 5)
    (is= "if distinguished arg +4"    (ind "(if test") 4)
    (is= "with-open-file body +2"     (ind "(with-open-file (s p)") 2)
    (is= "cond clauses +2"            (ind "(cond") 2)
    (is= "loop clauses align under first clause" (ind "(loop for x in xs") 6)
    (is= "loop conditional body indents +2"
         (ind (format nil "(loop for x in xs~%      when (evenp x)")) 8)
    (is= "loop returns to clause col after an action"
         (ind (format nil "(loop for x in xs~%      when (evenp x) collect x")) 6)
    (is= "literal list aligns under first element" (ind "(1 2 3") 1)
    (is= "binding list aligns under first binding" (ind "(let ((a 1) (b 2)") 6)
    (is= "quoted list aligns under first element" (ind "'(aa bb") 2)
    (is= "backquoted list aligns under first element" (ind "`(aa bb") 2)
    (is= "nested quoted list is data" (ind "'(foo (bar baz") 7))
  ;; lisp-indent-sexp reflows a whole top-level form
  (let ((ed (host (make-instance 'tfile-editor :bounds (make-trect 0 0 40 12)
                                 :text (format nil "(defun f ()~%(when x~%(foo)))")))))
    (lisp-indent-sexp ed)
    (is= "defun line unchanged" (nth-line ed 0) "(defun f ()")
    (is= "when reindented to +2" (nth-line ed 1) "  (when x")
    (is= "body reindented to +4" (nth-line ed 2) "    (foo)))")))

(deftest match-paren
  (let ((tv (focused (host (make-instance 'tmemo :bounds (make-trect 0 0 30 5))))))
    (set-text tv "(foo (bar))")
    (setf (text-cur-line tv) 0 (text-cur-col tv) 0)        ; on the outer (
    (ok "jumps from an open paren" (match-paren-jump tv))
    (is= "lands on the matching close paren" (text-cur-col tv) 10)
    (ok "jumps back from the close paren" (match-paren-jump tv))
    (is= "returns to the open paren" (text-cur-col tv) 0)
    (setf (text-cur-col tv) 2)                             ; on 'o' of foo
    (ok "no jump when point isn't on a paren" (not (match-paren-jump tv)))))
