(in-package #:parse-js)

(defstruct token type value line char newline-before)
(defun tokenp (token type value)
  (and (eq (token-type token) type)
       (eql (token-value token) value)))
(defun token-type-p (token type)
  (eq (token-type token) type))
(defun token-id (token)
  (token-value token))

(defvar *line*)
(defvar *char*)

(define-condition js-parse-error (simple-error)
  ((line :initform *line* :reader error-line)
   (char :initform *char* :reader error-char)))
(defmethod print-object ((err js-parse-error) stream)
  (call-next-method)
  (format stream " (line ~a, character ~a)" (error-line err) (error-char err)))
(defun js-parse-error (control &rest args)
  (error 'js-parse-error :format-control control :format-arguments args))

(defparameter *hex-number* (cl-ppcre:create-scanner "^0x[0-9a-f]+$" :case-insensitive-mode t))
(defparameter *octal-number* (cl-ppcre:create-scanner "^0[0-7]+$"))
(defparameter *decimal-number* (cl-ppcre:create-scanner "^\\d*\\.?\\d*(?:e-?\\d*(?:\\d\\.?|\\.?\\d)\\d*)?$"
                                                        :case-insensitive-mode t))
(defparameter *operator-chars* "+-*&%=<>!?|~^")
(defparameter *operators*
  (let ((ops (make-hash-table :test 'equal)))
    (dolist (op '(:in :instanceof :typeof :new :void :delete :++ :-- :+ :- :! :~ :& :|\|| :^ :* :/ :%
                  :>> :<< :>>> :< :> :<= :>= :== :=== :!= :!== :? := :+= :-= :/= :*= :%= :>>= :<<=
                  :>>>= :~= :%= :|\|=| :^= :&& :|\|\||))
      (setf (gethash (string op) ops) op))
    ops))

(defparameter *whitespace-chars* (concatenate 'string '(#\space #\tab #\return #\newline)))

(defparameter *keywords*
  (let ((keywords (make-hash-table :test 'equal)))
    (dolist (word '(:break :case :catch :continue :debugger :default :delete :do :else :false
                    :finally :for :function :if :in :instanceof :new :null :return :switch
                    :throw :true :try :typeof :var :void :while :with))
      (setf (gethash (string-downcase (string word)) keywords) word))
    (setf (gethash "NaN" keywords) :nan)
    keywords))
(defparameter *keywords-before-expression* '(:return :new :delete :throw))
(defparameter *atom-keywords* '(:false :null :true :undefined :nan))

(defun/defs lex-js (stream)
  (def expression-allowed t)
  (def newline-before nil)
  (def line 1)
  (def char 0)

  (def start-token ()
    (setf *line* line
          *char* char))
  (def token (type value)
    (setf expression-allowed
          (or (eq type :operator)
              (and (eq type :keyword)
                   (member value *keywords-before-expression*))
              (and (eq type :punc)
                   (find value "[{}(,.;:"))))
    (prog1 (make-token :type type :value value :line *line* :char *char* :newline-before newline-before)
      (setf newline-before nil)))

  (def peek ()
    (peek-char nil stream nil))
  (def next (&optional eof-error)
    (let ((ch (read-char stream eof-error)))
      (when ch
        (if (eql ch #\newline)
            (setf line (1+ line) char 0 newline-before t)
            (incf char)))
      ch))

  (def skip-whitespace ()
    (loop :for ch := (peek)
          :while (and ch (find ch *whitespace-chars*))
          :do (next)))
  (def read-while (pred)
    (with-output-to-string (*standard-output*)
      (loop :for ch := (peek)
            :while (and ch (funcall pred ch))
            :do (princ (next)))))

  (def read-num (start)
    (let ((num (read-while (lambda (ch) (or (alphanumericp ch) (eql ch #\.) (eql ch #\-))))))
      (when start (setf num (concatenate 'string start num)))
      (cond ((cl-ppcre:scan *hex-number* num)
             (token :num (parse-integer num :start 2 :radix 16)))
            ((cl-ppcre:scan *octal-number* num)
             (token :num (parse-integer num :start 1 :radix 8)))
            ((cl-ppcre:scan *decimal-number* num)
             (token :num (read-from-string num)))
            (t (js-parse-error "Invalid syntax: '~a'." num)))))

  (def handle-dot ()
    (next)
    (if (digit-char-p (peek))
        (read-num ".")
        (token :punc #\.)))

  (def hex-bytes (n)
    (loop :with num := 0
          :for pos :from (1- n) :downto 0
          :do (let ((digit (digit-char-p (next t) 16)))
                (if digit
                    (incf num (* digit (expt 16 pos)))
                    (js-parse-error "Invalid hex-character pattern in string.")))
          :finally (return num)))
  (def read-escaped-char ()
    (let ((ch (next t)))
      (case ch
        (#\n #\newline) (#\r #\return) (#\t #\tab)
        (#\b #\backspace) (#\v #\vt) (#\f #\page) (#\0 #\null)
        (#\x (code-char (hex-bytes 2)))
        (#\u (code-char (hex-bytes 4)))
        (t ch))))
  (def read-string ()
    (let ((quote (next)))
      (handler-case
          (token :string
                 (with-output-to-string (*standard-output*)
                   (loop (let ((ch (next t)))
                           (cond ((eql ch #\\) (write-char (read-escaped-char)))
                                 ((eql ch quote) (return))
                                 (t (write-char ch)))))))
        (end-of-file () (js-parse-error "Unterminated string constant.")))))

  (def skip-line-comment ()
    (next)
    (loop :for ch := (next)
          :until (or (eql ch #\newline) (not ch))))
  (def skip-multiline-comment ()
    (next)
    (loop :with star := nil
          :for ch := (next)
          :until (or (not ch) (and star (eql ch #\/)))
          :do (setf star (eql ch #\*))))

  (def read-regexp ()
    (handler-case
        (token :regexp
               (cons
                (with-output-to-string (*standard-output*)
                  (loop :with backslash := nil
                        :for ch := (next t)
                        :until (and (not backslash) (eql ch #\/))
                        :do (setf backslash (eql ch #\\))
                        ;; Handle \u sequences, since CL-PPCRE does not understand them.
                        :do (write-char (if (and (eql ch #\\) (eql (peek) #\u))
                                            (progn
                                              (setf backslash nil)
                                              (next)
                                              (code-char (hex-bytes 4)))
                                            ch))))
                (read-while (lambda (ch) (find ch "gim")))))
      (end-of-file () (js-parse-error "Unterminated regular expression."))))

  (def read-operator (&optional start)
    (labels ((grow (str)
               (let ((bigger (concatenate 'string str (string (peek)))))
                 (if (gethash bigger *operators*)
                     (progn (next) (grow bigger))
                     (token :operator (gethash str *operators*))))))
      (grow (or start (string (next))))))

  (def handle-slash ()
    (next)
    (case (peek)
      (#\/ (skip-line-comment)
           (next-token))
      (#\* (skip-multiline-comment)
           (next-token))
      (t (if expression-allowed
             (read-regexp)
             (read-operator "/")))))

  (def identifier-char-p (ch) (or (alphanumericp ch) (eql ch #\$) (eql ch #\_)))
  (def read-word ()
    (let* ((word (read-while #'identifier-char-p))
           (keyword (gethash word *keywords*)))
      (cond ((not keyword) (token :name word))
            ((gethash word *operators*) (token :operator keyword))
            ((member keyword *atom-keywords*) (token :atom keyword))
            (t (token :keyword keyword)))))

  (def next-token ()
    (skip-whitespace)
    (start-token)
    (let ((next (peek)))
      (cond ((not next) (token :eof "EOF"))
            ((digit-char-p next) (read-num nil))
            ((find next "'\"") (read-string))
            ((find next "[]{}(),.;:") (token :punc (next)))
            ((eql next #\.) (handle-dot))
            ((eql next #\/) (handle-slash))
            ((find next *operator-chars*) (read-operator))
            ((identifier-char-p next) (read-word))
            (t (js-parse-error "Unexpected character '~a'." next)))))

  #'next-token)
