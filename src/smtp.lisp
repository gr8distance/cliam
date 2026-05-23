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
  ;; Render the entire RFC 5322 message ourselves and hand it to cl-smtp
  ;; as a stream — that way display names on To/Cc, attachments, and
  ;; multipart layout produced by render-rfc822 all reach the wire as-is,
  ;; instead of getting clobbered by cl-smtp's own header generator.
  (let* ((from       (or (email-from email)
                         (error 'deliver-error :email email :adapter a
                                               :cause "email has no FROM address")))
         (envelope   (%addr-bare from))
         (recipients (mapcar #'%addr-bare
                             (append (email-to email)
                                     (email-cc email)
                                     (email-bcc email))))
         (auth       (when (smtp-adapter-username a)
                       (list (smtp-adapter-username a)
                             (smtp-adapter-password a)))))
    (handler-case
        (cl-smtp:with-smtp-mail (stream
                                 (smtp-adapter-host a)
                                 envelope
                                 recipients
                                 :port (or (smtp-adapter-port a)
                                           (if (eq (smtp-adapter-ssl a) :tls) 465 25))
                                 :ssl  (smtp-adapter-ssl a)
                                 :authentication auth)
          (write-sequence (render-rfc822 email) stream))
      (error (e)
        (error 'deliver-error :email email :adapter a :cause e)))
    (assign email :delivered-via :smtp)))
