(in-package #:cliam)

;;; SMTP adapter. Thin wrapper over cl-smtp:send-email — translates
;;; cliam's email value into the keyword soup cl-smtp wants, and turns
;;; any error into CLIAM:DELIVER-ERROR for uniform handling.
;;;
;;; Lives in :cliam/smtp (sub-system) so core stays free of cl-smtp +
;;; its transitive deps (usocket, cl+ssl, flexi-streams, cl-base64).

(defclass smtp-adapter ()
  ((host     :initarg :host     :reader smtp-adapter-host
             :documentation "SMTP server hostname.")
   (port     :initarg :port     :initform nil :reader smtp-adapter-port
             :documentation "Port; defaults to 465 for :tls, 25 otherwise.")
   (ssl      :initarg :ssl      :initform nil :reader smtp-adapter-ssl
             :documentation "NIL, :starttls, or :tls.")
   (username :initarg :username :initform nil :reader smtp-adapter-username)
   (password :initarg :password :initform nil :reader smtp-adapter-password)))

(defun make-smtp-adapter (&key host port ssl username password)
  (check-type host string)
  (make-instance 'smtp-adapter
                 :host host :port port :ssl ssl
                 :username username :password password))

(defun %addr-bare (addr)
  "Strip any (name . addr) wrapping; cl-smtp wants bare envelope addresses."
  (etypecase addr
    (string addr)
    (cons   (cdr addr))))

(defun %addr-name (addr)
  (when (consp addr) (car addr)))

(defmethod deliver-with ((a smtp-adapter) email)
  (let* ((from        (or (email-from email)
                          (error 'deliver-error :email email :adapter a
                                                :cause "email has no FROM address")))
         (from-bare   (%addr-bare from))
         (auth        (when (smtp-adapter-username a)
                        (list (smtp-adapter-username a)
                              (smtp-adapter-password a)))))
    (handler-case
        (cl-smtp:send-email
         (smtp-adapter-host a)
         from-bare
         (mapcar #'%addr-bare (email-to email))
         (email-subject email)
         (or (email-text-body email) "")
         :port          (or (smtp-adapter-port a)
                            (if (eq (smtp-adapter-ssl a) :tls) 465 25))
         :ssl           (smtp-adapter-ssl a)
         :cc            (mapcar #'%addr-bare (email-cc email))
         :bcc           (mapcar #'%addr-bare (email-bcc email))
         :reply-to      (when (email-reply-to email) (%addr-bare (email-reply-to email)))
         :extra-headers (loop for (k v) on (email-headers email) by #'cddr
                              collect (list k v))
         :html-message  (email-html-body email)
         :display-name  (%addr-name from)
         :authentication auth)
      (error (e)
        (error 'deliver-error :email email :adapter a :cause e)))
    (assign email :delivered-via :smtp)))
