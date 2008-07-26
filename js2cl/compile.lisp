(cl:in-package :js2cl)

(defvar *js-package*)
(defvar *locals*)

(defgeneric compile* (type args))
(defmacro compiler (type (&rest args) &body body)
  (let ((a (gensym)))
    `(defmethod compile* ((type (eql ,type)) ,a)
       (destructuring-bind ,args ,a ,@body))))

(defun compile (as)
  (compile* (car as) (cdr as)))

(defun js-package (&optional name)
  (make-package (gensym (or name (string :javascript))) :use '(:js-runtime)))

(defun add-globals (names)
  (dolist (name names)
    (eval `(defvar ,name nil))))

(defun compile-js (input &optional package)
  (multiple-value-bind (compiled globals package) (compile-js-to-lisp input package)
    (add-globals globals)
    (values (cl:compile nil `(lambda () ,compiled)) package)))

(defun eval-js (input &optional package)
  (multiple-value-bind (compiled globals package) (compile-js-to-lisp input package)
    (add-globals globals)
    (values (eval compiled) package)))

(defun compile-js-to-lisp (input &optional package)
  (when (stringp input) (setf input (make-string-input-stream input)))
  (let* ((as (parse-javascript:parse-js input))
         (*js-package* (or package (js-package))))
    (multiple-value-bind (compiled globals) (compile as)
      (values compiled globals *js-package*))))
