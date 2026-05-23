(in-package #:cliam)

;;; Test adapter: captures delivered emails in memory for assertions.
;;; Bind cliam:*default-adapter* to one of these in your test suite,
;;; clear-inbox between tests, walk test-inbox to verify what was sent.

(defclass test-adapter ()
  ((inbox :initform nil :accessor test-inbox
          :documentation "Emails delivered through this adapter, newest first.")))

(defun make-test-adapter () (make-instance 'test-adapter))

(defmethod deliver-with ((a test-adapter) email)
  (push email (test-inbox a))
  email)

(defun clear-inbox (adapter)
  "Reset the captured inbox. Call from your test setup."
  (setf (test-inbox adapter) nil))

(defmacro with-fresh-inbox ((adapter-var) &body body)
  "Bind ADAPTER-VAR to a fresh test-adapter, point *default-adapter* at
it, and run BODY. Guarantees test isolation — useful as a per-test
fixture without coupling to any particular test framework."
  `(let* ((,adapter-var (make-test-adapter))
          (*default-adapter* ,adapter-var))
     ,@body))
