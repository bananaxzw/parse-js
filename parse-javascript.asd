(asdf:defsystem #:parse-javascript
  :depends-on (#:cl-ppcre)
  :components
  ((:module :parser
            :components ((:file "package")
                         (:file "util" :depends-on ("package"))
                         (:file "tokenize" :depends-on ("util"))
                         (:file "parse" :depends-on ("tokenize"))))))

