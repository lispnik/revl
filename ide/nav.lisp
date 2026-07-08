;;;; nav.lisp --- source navigation: go-to-definition + xref (who-calls/...).
;;;;
;;;; Standard SB-INTROSPECT, like the other introspection tools: a symbol's
;;;; definition sources and its callers/references/binders/setters become rows
;;;; in a clickable table window that opens the source file at the right line.

(in-package #:revl)

(defun %offset-to-line (path char-offset)
  "1-based line of the definition SB-INTROSPECT records at CHAR-OFFSET in PATH.  The offset
sits where the reader *resumed* after the previous form -- typically a line or two before
the real definition, on a blank line or the previous form's newline -- so seek there, then
skip whitespace and Lisp comments (`;' and nested `#| |#') forward to the next actual form
and report that line.  This lands exactly on the DEFUN when the file matches its compiled
source (built-ins whose installed sources differ from the build can still drift)."
  (or (ignore-errors
        (with-open-file (s path :direction :input :external-format :utf-8)
          (let ((line 1))
            (labels ((adv () (let ((c (read-char s nil nil))) (when (eql c #\Newline) (incf line)) c)))
              (dotimes (i (or char-offset 0)) (unless (adv) (return)))
              (loop
                (let ((c (peek-char nil s nil nil)))
                  (cond
                    ((null c) (return))
                    ((member c '(#\Space #\Tab #\Return #\Newline #\Page)) (adv))
                    ((char= c #\;) (loop for d = (adv) until (or (null d) (eql d #\Newline))))
                    ((char= c #\#)                                  ; maybe a #| block comment
                     (adv)
                     (if (eql (peek-char nil s nil nil) #\|)
                         (let ((depth 1))
                           (adv)
                           (loop while (plusp depth) for d = (adv) while d do
                             (cond ((and (eql d #\|) (eql (peek-char nil s nil nil) #\#)) (adv) (decf depth))
                                   ((and (eql d #\#) (eql (peek-char nil s nil nil) #\|)) (adv) (incf depth)))))
                         (return)))                                 ; #x / #' / #( … : a real form
                    (t (return)))))
              line))))
      1))

(defvar *location-stack* '()
  "Stack of (PATH . LINE) editor locations, pushed on each go-to-definition / xref
jump so Pop back (M-,) can return to where you were.")

(defun %current-location ()
  "The focused editor's (PATH . LINE), or NIL when no file-backed editor is focused."
  (let ((te (ignore-errors (%focused-editor))))
    (when (and te (te-filename te))
      (cons (namestring (te-filename te)) (1+ (te-cy te))))))

(defun open-source-at (path line)
  "Open PATH in an editor at LINE, reusing an already-open editor for that file.
Records the current editor location first so Pop back can return to it."
  (let ((here (%current-location)))
    (when (and here (not (equal here (car *location-stack*))))
      (push here *location-stack*)))
  (%open-file-at path line))

(defun do-pop-back ()
  "Return to the location saved before the last go-to-definition / xref jump."
  (if (null *location-stack*)
      (revision::%tool-note "location stack is empty — nothing to pop back to")
      (let ((loc (pop *location-stack*)))
        (%open-file-at (car loc) (cdr loc)))))

(defun %show-locations (title rows)
  "ROWS = list of (LABEL PATH LINE); a table window whose Enter opens the source."
  (if (null rows)
      (%open-output title "No locations found.")
      (let ((cols (list (list "What" 36 #'first)
                        (list "File" 24 (lambda (r) (if (second r) (file-namestring (second r)) "?")))
                        (list "Line" 6 #'third))))
        (flet ((open-row (tv row) (declare (ignore tv)) (open-source-at (second row) (third row))))
          (if *desktop*
              (dt-open *desktop* (lambda () (make-table-window title cols rows :on-activate #'open-row)))
              (multiple-value-bind (w f) (make-table-window title cols rows :on-activate #'open-row)
                (run-view w :focus f)))))))

;;; --- go to definition -------------------------------------------------------

(defun %symbol-definitions (sym)
  "List of (LABEL PATH LINE) source locations for SYM (via SB-INTROSPECT)."
  (let ((out '()))
    (dolist (type '(:function :generic-function :macro :variable :class :structure
                    :condition :method :compiler-macro :setf-expander :type))
      (ignore-errors
        (dolist (src (sb-introspect:find-definition-sources-by-name sym type))
          (let ((path (sb-introspect:definition-source-pathname src)))
            (when path
              (push (list (format nil "~(~a~)  ~a" type sym) (namestring path)
                          (%offset-to-line (namestring path)
                                           (sb-introspect:definition-source-character-offset src)))
                    out))))))
    (remove-duplicates (nreverse out) :test #'equal)))

(defun %goto-symbol (sym &optional (label (princ-to-string sym)))
  "Jump to SYM's definition source: one location opens in an editor directly, several
show a picker.  Shared by Go-to-definition and the symbol browsers' Goto key."
  (let ((defs (and sym (%symbol-definitions sym))))
    (cond ((null defs) (%open-output " Go to definition "
                                     (format nil "No source location for ~a." label)))
          ((null (cdr defs)) (open-source-at (second (first defs)) (third (first defs))))
          (t (%show-locations (format nil " Definitions of ~a " label) defs)))))

(defun do-goto-definition ()
  (let ((name (prompt-string " Go to definition " "Symbol:")))
    (when (and name (plusp (length (string-trim " " name))))
      (%goto-symbol (%read-in-active name) name))))

;;; --- CL:ED -> open in a revl editor -----------------------------------------
;;; Installed into SB-EXT:*ED-FUNCTIONS* (see INSTALL-REVL-LOGIC) so evaluating
;;; (ed …) from a REPL opens in revl instead of erroring.  ED runs on the REPL's
;;; worker thread, so the actual window work is marshalled to the UI thread.

(defun revl-ed (&optional x)
  "revl's CL:ED handler: (ed) opens a scratch editor; (ed \"file\") / (ed #p\"…\") opens
that file (reusing an already-open buffer); (ed 'name) jumps to a definition.  Returns T
so CL:ED treats the request as handled."
  (flet ((scratch () (if *desktop* (dt-open *desktop* :editor) (run-view (make-editor)))))
    (run-on-ui
     (lambda ()
       (cond
         ((null x) (scratch))
         ((or (stringp x) (pathnamep x))
          (let ((p (pathname x)))
            (cond ((probe-file p) (%open-file-at p))
                  (*desktop* (dt-open *desktop* (lambda () (make-editor p))))
                  (t (run-view (make-editor p))))))
         ((or (symbolp x) (consp x)) (%goto-symbol x))   ; a function/definition name
         (t (scratch))))))
  t)

;;; --- xref: who-calls / -references / -binds / -sets / -macroexpands ---------

(defun %xref (kind sym)
  "List of (LABEL PATH LINE) for the WHO-KIND of SYM."
  (let ((fn (ecase kind
              (:calls #'sb-introspect:who-calls)   (:references #'sb-introspect:who-references)
              (:binds #'sb-introspect:who-binds)   (:sets #'sb-introspect:who-sets)
              (:macroexpands #'sb-introspect:who-macroexpands)))
        (out '()))
    (dolist (entry (ignore-errors (funcall fn sym)))
      (let* ((nm (car entry)) (src (cdr entry))
             (path (ignore-errors (sb-introspect:definition-source-pathname src)))
             (off  (ignore-errors (sb-introspect:definition-source-character-offset src))))
        (push (list (princ-to-string nm) (and path (namestring path))
                    (if path (%offset-to-line (namestring path) off) 0))
              out)))
    (nreverse out)))

(defun do-xref (kind label)
  (let ((name (prompt-string (format nil " Who ~a " label) "Symbol:")))
    (when (and name (plusp (length (string-trim " " name))))
      (let ((sym (%read-in-active name)))
        (%show-locations (format nil " Who ~a ~a " label name)
                         (and sym (symbolp sym) (%xref kind sym)))))))

;;; --- method browser ---------------------------------------------------------

(defun %method-label (m)
  "A printed signature for method M (qualifiers + specializers)."
  (let ((quals (sb-mop:method-qualifiers m))
        (specs (mapcar (lambda (s)
                         (if (typep s 'class) (class-name s)
                             (ignore-errors (list 'eql (sb-mop:eql-specializer-object s)))))
                       (sb-mop:method-specializers m))))
    (string-trim " " (format nil "~{~(~a~)~^ ~} (~{~a~^ ~})" quals specs))))

(defun %gf-methods (gf)
  "List of (LABEL PATH LINE) for the methods of generic function GF."
  (let ((out '()))
    (dolist (m (ignore-errors (sb-mop:generic-function-methods gf)))
      (let* ((src (ignore-errors (sb-introspect:find-definition-source (sb-mop:method-function m))))
             (path (and src (sb-introspect:definition-source-pathname src)))
             (off  (and src (sb-introspect:definition-source-character-offset src))))
        (push (list (%method-label m) (and path (namestring path))
                    (if path (%offset-to-line (namestring path) off) 0))
              out)))
    (nreverse out)))

(defun do-method-browser ()
  (let ((name (prompt-string " Method browser " "Generic function:")))
    (when (and name (plusp (length (string-trim " " name))))
      (let* ((sym (%read-in-active name)) (fn (and sym (symbolp sym) (fboundp sym) (fdefinition sym))))
        (if (typep fn 'generic-function)
            (%show-locations (format nil " Methods of ~a " name) (%gf-methods fn))
            (%open-output " Method browser " (format nil "~a is not a generic function." name)))))))

;; Go-to-definition and the xref commands are surfaced through the consolidated
;; "Lisp" menu's Navigate submenu (docs.lisp).
