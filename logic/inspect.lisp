;;;; inspect.lisp --- object -> TOutline tree (the inspector model).
;;;;
;;;; OBJECT->OUTLINE builds a depth-limited, cycle-safe, pageable outline-node
;;;; tree describing any Lisp object (slots via sb-mop, with per-cell setters).
;;;; Pure -- it produces a base OUTLINE-NODE tree with no view dependency -- so
;;;; both the classic TInspectorWindow and the revision inspector reuse it (the revision
;;;; IDE via *object->outline-fn*).  Extracted from src/repl.lisp.

(in-package #:tvision)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(object->outline) '#:tvision))

;;; --- object inspector (built on TOutline) ----------------------------------

(defun %short-repr (obj)
  (let ((*print-length* 6) (*print-level* 2) (*print-readably* nil))
    (let ((s (handler-case (prin1-to-string obj) (error () "#<unprintable>"))))
      (if (> (length s) 56) (concatenate 'string (subseq s 0 53) "...") s))))

(defun %inspect-trackable-p (obj)
  "True for aggregate objects that OBJECT->OUTLINE recurses into and that can
therefore form a reference cycle (strings are leaves and never tracked)."
  (typecase obj
    (string nil)
    ((or cons hash-table standard-object structure-object) t)
    (vector t)
    (t nil)))

(defconstant +inspect-page+ 200
  "How many elements OBJECT->OUTLINE shows per collection before a drillable
`... N more' node; drilling that node pages through the remainder.")

(defun object->outline (obj label &optional (depth 3) path)
  "Build a depth-limited TOutline node tree describing OBJ.  Robust against
objects whose slots/elements error when read (e.g. system structures): a
failing branch becomes an `<error>' leaf rather than crashing the inspector.
PATH is the chain of ancestor objects; an OBJ already on it is rendered as a
`[circular ref]' leaf instead of being expanded again."
  (when (and (%inspect-trackable-p obj) (member obj path :test #'eq))
    (return-from object->outline
      (make-outline-node (format nil "~a = ~a  [circular ref]" label (%short-repr obj))
                         nil obj)))
  (let ((children '())
        (path* (if (%inspect-trackable-p obj) (cons obj path) path)))
    (when (plusp depth)
      (flet ((kid (v lbl &optional setter)
               ;; never let a recursive step escape -- it would kill the UI loop
               (let ((node (handler-case (object->outline v lbl (1- depth) path*)
                             (serious-condition (e)
                               (make-outline-node (format nil "~a = <~a>" lbl (type-of e)))))))
                 (when setter (setf (outline-node-setter node) setter))
                 (push node children)))
             (overflow (n rest noun)
               ;; a drillable `... N more' node for the truncated tail of a big
               ;; collection (REST is re-inspected to page through the remainder)
               (push (make-outline-node
                      (if n (format nil "... ~d more ~a" n noun) (format nil "... more ~a" noun))
                      nil rest)
                     children)))
        (handler-case
            (typecase obj
              (string nil)
              ;; packages are structure-objects in SBCL, but their raw slots are
              ;; huge internal symbol tables -- show the useful summary instead.
              (package
               (kid (package-name obj) "name")
               (kid (package-nicknames obj) "nicknames")
               (kid (package-use-list obj) "use-list")
               (kid (package-used-by-list obj) "used-by-list"))
              ;; a symbol: show its full namespace -- value, function/macro,
              ;; class, plist and documentation -- not just its printed name
              (symbol
               (kid (symbol-name obj) "symbol-name")
               ;; package as a name (not the package object, whose internals
               ;; would swamp the more useful value/function cells)
               (when (symbol-package obj) (kid (package-name (symbol-package obj)) "package"))
               (when (and (boundp obj) (not (eq (symbol-value obj) obj)))
                 (kid (symbol-value obj) "value" (lambda (new) (setf (symbol-value obj) new))))
               (cond ((special-operator-p obj) (kid :special-operator "operator"))
                     ((macro-function obj)      (kid (macro-function obj) "macro-function"))
                     ((fboundp obj)             (kid (symbol-function obj) "function")))
               (let ((c (find-class obj nil)))   (when c  (kid c "class")))
               (let ((pl (symbol-plist obj)))    (when pl (kid pl "plist")))
               (let ((doc (or (ignore-errors (documentation obj 'function))
                              (ignore-errors (documentation obj 'variable))
                              (ignore-errors (documentation obj 'type)))))
                 (when doc (kid doc "documentation"))))
              (cons
               (let ((i 0) (tail obj))
                 (loop while (and (consp tail) (< i +inspect-page+))
                       do (let ((cell tail))
                            (kid (car tail) (format nil "[~d]" i)
                                 (lambda (new) (setf (car cell) new))))
                          (incf i) (setf tail (cdr tail)))
                 (when (consp tail)
                   (let ((m (list-length tail)))   ; NIL for a circular list
                     (overflow m tail (if m "elements" "elements (circular)"))))))
              (vector
               (let ((n (length obj)))
                 (dotimes (i (min n +inspect-page+))
                   (let ((idx i))
                     (kid (aref obj i) (format nil "[~d]" i)
                          (lambda (new) (setf (aref obj idx) new)))))
                 (when (> n +inspect-page+)
                   (overflow (- n +inspect-page+) (subseq obj +inspect-page+) "elements"))))
              (hash-table
               (let ((i 0) (total (hash-table-count obj)))
                 (maphash (lambda (k v)
                            (when (< i +inspect-page+)
                              (let ((key k))
                                (kid v (format nil "~a =>" (%short-repr k))
                                     (lambda (new) (setf (gethash key obj) new)))))
                            (incf i))
                          obj)
                 (when (> total +inspect-page+)
                   (overflow (- total +inspect-page+) nil "entries"))))
              ((or structure-object standard-object)
               (dolist (slot (handler-case (sb-mop:class-slots (class-of obj)) (error () nil)))
                 (let ((name (sb-mop:slot-definition-name slot)))
                   (when (handler-case (slot-boundp obj name) (error () nil))
                     (kid (handler-case (slot-value obj name) (serious-condition (e) e))
                          (format nil "~a" name)
                          (lambda (new) (setf (slot-value obj name) new))))))))
          (serious-condition () nil))))
    ;; store the value in the node so the inspector can drill into it
    (let ((node (make-outline-node (format nil "~a = ~a" label (%short-repr obj))
                                   (nreverse children) obj)))
      (setf (outline-node-expanded node) t)
      node)))
