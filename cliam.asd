(defsystem "cliam"
  :description "A tiny composable mailer for Common Lisp, in the spirit of Swoosh."
  :version "0.1.0"
  :author "ug <gr8.distance@gmail.com>"
  :license "MIT"
  :depends-on ("alexandria" "babel" "cl-base64" "trivial-mimes")
  :pathname "src/"
  :components ((:file "package")
               (:file "email"   :depends-on ("package"))
               (:file "adapter" :depends-on ("email"))
               (:file "test"       :depends-on ("adapter"))
               (:file "local"      :depends-on ("adapter"))
               (:file "assertions" :depends-on ("test")))
  :in-order-to ((test-op (test-op "cliam/tests"))))

(defsystem "cliam/smtp"
  :description "SMTP adapter for cliam (opt-in; pulls cl-smtp + transitive TLS deps)."
  :version "0.1.0"
  :depends-on ("cliam" "cl-smtp")
  :pathname "src/"
  :components ((:file "smtp")))

(defsystem "cliam/ses"
  :description "AWS SES SMTP preset for cliam (opt-in; wraps cliam/smtp)."
  :version "0.1.0"
  :depends-on ("cliam/smtp")
  :pathname "src/"
  :components ((:file "ses")))

(defsystem "cliam/tests"
  :depends-on ("cliam" "fiveam")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (op c) (symbol-call :fiveam :run! :cliam)))
