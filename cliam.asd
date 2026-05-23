(defsystem "cliam"
  :description "A tiny composable mailer for Common Lisp, in the spirit of Swoosh."
  :version "0.1.0"
  :author "ug <gr8.distance@gmail.com>"
  :license "MIT"
  :depends-on ("alexandria")
  :pathname "src/"
  :components ((:file "package")
               (:file "email"   :depends-on ("package"))
               (:file "adapter" :depends-on ("email"))
               (:file "test"    :depends-on ("adapter"))
               (:file "local"   :depends-on ("adapter")))
  :in-order-to ((test-op (test-op "cliam/tests"))))

(defsystem "cliam/tests"
  :depends-on ("cliam" "fiveam")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (op c) (symbol-call :fiveam :run! :cliam)))
