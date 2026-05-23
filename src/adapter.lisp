(in-package #:cliam)

;;; Adapter protocol. An adapter is any object for which DELIVER-WITH
;;; is defined. Plug in your own by writing a METHOD.

(define-condition deliver-error (error)
  ((email     :initarg :email     :reader deliver-error-email)
   (adapter   :initarg :adapter   :reader deliver-error-adapter)
   (cause     :initarg :cause     :reader deliver-error-cause :initform nil))
  (:report (lambda (c s)
             (format s "Failed to deliver email via ~a~@[: ~a~]"
                     (type-of (deliver-error-adapter c))
                     (deliver-error-cause c)))))

(defparameter *default-adapter* nil
  "Adapter used when DELIVER is called without an :ADAPTER keyword.
Set per-environment (e.g. test-adapter in tests, smtp-adapter in prod).")

(defgeneric deliver-with (adapter email)
  (:documentation
   "Hand EMAIL off to ADAPTER. Methods should return the email (possibly
augmented with :delivered-at or other metadata in (email-assigns)) on
success, or signal DELIVER-ERROR on failure."))

(defun deliver (email &key (adapter *default-adapter*))
  "Top-level send. Looks up *DEFAULT-ADAPTER* unless ADAPTER is given."
  (unless adapter
    (error "No adapter: bind cliam:*default-adapter* or pass :adapter."))
  (deliver-with adapter email))
