;;; Load with:
;;;   (ql:quickload :cliam)
;;;   (load "examples/quickstart.lisp")
;;;
;;; Sends one email via the local adapter — opens .eml files under /tmp/cliam-out/.

(defpackage #:cliam-quickstart (:use #:cl #:cliam))
(in-package #:cliam-quickstart)

(defparameter *adapter*
  (make-local-adapter #P"/tmp/cliam-out/"))

(defun send-welcome (to-addr name)
  (deliver
   (-> (make-email)
       (from "noreply@example.com" "Example")
       (to to-addr name)
       (subject (format nil "Welcome, ~a!" name))
       (text-body (format nil "Hi ~a,~%~%Thanks for signing up.~%-- The Team~%" name))
       (html-body (format nil "<p>Hi ~a,</p><p>Thanks for signing up.</p>" name)))
   :adapter *adapter*))

;;; Sketchy threading macro for the example; uses CL standard nesting if missing.
(defmacro -> (init &rest forms)
  (reduce (lambda (acc form)
            (if (listp form) `(,(car form) ,acc ,@(cdr form)) `(,form ,acc)))
          forms :initial-value init))

;; (send-welcome "alice@example.com" "Alice")
;; => writes /tmp/cliam-out/YYYYMMDD-HHMMSS-XXXXXX.eml
