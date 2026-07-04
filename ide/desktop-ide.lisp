;;;; desktop-ide.lisp --- IDE glue for the desktop shell (extracted from revision).
;;;;
;;;; The generic revision desktop knows nothing about the REPL or a package table.
;;;; These helpers -- open-or-focus the REPL, save/clear its transcript, and the
;;;; package-table window -- are the application's, so they live in revl and drive the
;;;; moved repl-window / table window.  (Still in-package revision at this stage; they
;;;; join the revl package when the IDE is re-homed in Level 2.)

(in-package #:revl)

(defun ensure-repl ()
  "The desktop's REPL window, opening one if none is present.  Returns it."
  (when *desktop*
    (or (find :repl (dt-windows *desktop*) :key #'window-kind)
        (progn (dt-open *desktop* :repl) (dt-top *desktop*)))))

(defun %dt-save-transcript (dt)
  (let ((r (revision::%dt-repl dt)))
    (if (null r) (revision::%tool-note "no REPL open")
        (let ((p (make-file-dialog :dir *project-dir* :mode :save :default-name "transcript.txt")))
          (when p (%repl-save-transcript r p) (revision::%tool-note (format nil "transcript → ~a" (file-namestring p))))))))

(defun %dt-save-script (dt)
  (let ((r (revision::%dt-repl dt)))
    (if (null r) (revision::%tool-note "no REPL open")
        (let ((p (make-file-dialog :dir *project-dir* :mode :save :default-name "session.lisp" :mask "*.lisp")))
          (when p (%repl-save-script r p) (revision::%tool-note (format nil "script → ~a" (file-namestring p))))))))

(defun %dt-clear-repl (dt)
  (let ((r (revision::%dt-repl dt))) (if r (%repl-clear r) (revision::%tool-note "no REPL open"))))

(defun make-package-table ()
  "All packages as a column table: name · external-symbol count · packages used."
  (let* ((rows (sort (copy-list (list-all-packages)) #'string< :key #'package-name))
         (win (ui (window (:title " Packages (table viewer) " :keymap *global-keys*)
                    (stack
                      (:fill (table-view :name 'tbl :rows rows
                               :on-inspect (lambda (tv p) (declare (ignore tv))
                                             (when p (funcall 'open-inspector p (package-name p))))
                               :columns (list
                                         (list "Package"  30 (lambda (p) (package-name p)))
                                         (list "External" 10 (lambda (p) (let ((n 0))
                                                                           (do-external-symbols (s p) (declare (ignore s)) (incf n)) n)))
                                         (list "Uses"     40 (lambda (p) (format nil "~{~a~^ ~}"
                                                                                (mapcar #'package-name (package-use-list p))))))))
                      (1 (static-text :role :status :text " ↑/↓ select · Alt-I: inspect · click a row · wheel scrolls · Esc closes ")))))))
    (setf (window-scroll-target win) (find-view win 'tbl) (window-help win) :browser)
    (values win (find-view win 'tbl))))

;;; register the package-table window with the desktop (Tools menu / layout restore)
(pushnew (cons :ptable #'make-package-table) *window-builders* :key #'car)
