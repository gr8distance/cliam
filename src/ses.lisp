(in-package #:cliam)

;;; SES (SMTP) preset. Production-grade AWS SES delivery without
;;; pulling SigV4 / HMAC machinery; SES exposes a perfectly normal SMTP
;;; endpoint that any cl-smtp client can talk to.
;;;
;;; A full SES API adapter (cliam/ses-api with SigV4 signing via
;;; ironclad + dexador) is planned for when SMTP-via-egress-port-587
;;; isn't viable (containerised environments that block egress SMTP).

(defparameter *ses-regions*
  '("us-east-1" "us-east-2" "us-west-1" "us-west-2"
    "eu-west-1" "eu-west-2" "eu-central-1"
    "ap-northeast-1" "ap-northeast-2" "ap-southeast-1" "ap-southeast-2"
    "ap-south-1" "sa-east-1" "ca-central-1")
  "SES SMTP endpoints exist in these regions. Not enforced — pass any
region string you've enabled SES in.")

(defun make-ses-smtp-adapter (&key (region "us-east-1")
                                   smtp-username
                                   smtp-password
                                   (port 587)
                                   (ssl :starttls))
  "Build an SMTP adapter pointed at AWS SES's STARTTLS endpoint.

SMTP-USERNAME and SMTP-PASSWORD are *SES SMTP credentials*, not your
ordinary AWS access key pair — create them under
SES Console > SMTP Settings > Create SMTP credentials. They look like
AWS keys (AKIA... / 40+ char secret) but are scoped to SES and are
HMAC-derived from a separate IAM user.

Port defaults to 587 (STARTTLS). Use :port 465 :ssl :tls for direct
TLS, or :port 2587 if your network blocks 587."
  (check-type region string)
  (check-type smtp-username string)
  (check-type smtp-password string)
  (make-smtp-adapter
   :host     (format nil "email-smtp.~a.amazonaws.com" region)
   :port     port
   :ssl      ssl
   :username smtp-username
   :password smtp-password))
