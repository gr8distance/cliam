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

(defparameter *telemetry* nil
  "When bound to a function, it is called as (funcall *telemetry* event
payload) on delivery lifecycle events. EVENT is one of:
  :before-deliver   payload: (:email E :adapter A)
  :after-deliver    payload: (:email E :adapter A :result R)
  :deliver-failed   payload: (:email E :adapter A :condition C)
Use for logging, metrics, distributed tracing. Errors raised by the
telemetry callback are swallowed so observability code can't bring
down delivery.")

(defun %telemetry (event payload)
  (when *telemetry*
    (ignore-errors (funcall *telemetry* event payload))))

(defun validate-email (email)
  "Pre-deliver lint: ensure EMAIL has a FROM and at least one recipient.
Signals CL:ERROR otherwise. Returns EMAIL on success."
  (unless (email-from email)
    (error "cliam: email has no FROM address; set it with (cliam:from ...)"))
  (unless (or (email-to email) (email-cc email) (email-bcc email))
    (error "cliam: email has no recipient (To/Cc/Bcc all empty)"))
  email)

(defgeneric deliver-with (adapter email)
  (:documentation
   "Hand EMAIL off to ADAPTER. Methods should return the email (possibly
augmented with :delivered-at or other metadata in (email-assigns)) on
success, or signal DELIVER-ERROR on failure."))

(defun deliver (email &key (adapter *default-adapter*) (validate t))
  "Top-level send. Looks up *DEFAULT-ADAPTER* unless ADAPTER is given.
Calls VALIDATE-EMAIL up front when VALIDATE is true (default). Fires
*telemetry* hooks around the call."
  (unless adapter
    (error "No adapter: bind cliam:*default-adapter* or pass :adapter."))
  (when validate (validate-email email))
  (%telemetry :before-deliver (list :email email :adapter adapter))
  (handler-case
      (let ((result (deliver-with adapter email)))
        (%telemetry :after-deliver (list :email email :adapter adapter :result result))
        result)
    (error (e)
      (%telemetry :deliver-failed (list :email email :adapter adapter :condition e))
      (error e))))

(defun deliver-async (email &key (adapter *default-adapter*)
                                 on-success on-error
                                 (validate t))
  "Spawn a background thread that runs DELIVER. Returns the thread —
join it for sync semantics, or fire-and-forget. ON-SUCCESS/ON-ERROR
callbacks run in the spawned thread and receive (result) / (condition)
respectively. Errors without an ON-ERROR handler are printed to
*ERROR-OUTPUT*."
  (bordeaux-threads:make-thread
   (lambda ()
     (handler-case
         (let ((result (deliver email :adapter adapter :validate validate)))
           (when on-success (funcall on-success result)))
       (error (e)
         (if on-error
             (funcall on-error e)
             (format *error-output* "~&cliam:deliver-async failed: ~a~%" e)))))
   :name "cliam-deliver-async"))
