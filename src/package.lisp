(defpackage #:cliam
  (:use #:cl)
  (:export
   ;; email
   #:email #:make-email #:email-p
   #:email-from #:email-to #:email-cc #:email-bcc #:email-reply-to
   #:email-subject #:email-text-body #:email-html-body
   #:email-headers #:email-attachments #:email-assigns
   ;; builders (return fresh email)
   #:from #:to #:cc #:bcc #:reply-to
   #:subject #:text-body #:html-body
   #:header #:attach
   #:assign #:get-assign
   ;; rendering
   #:render-rfc822
   ;; adapter protocol + delivery
   #:deliver #:deliver-with
   #:*default-adapter*
   #:deliver-error
   ;; test adapter
   #:test-adapter #:make-test-adapter
   #:test-inbox #:clear-inbox
   ;; test assertions (framework-agnostic)
   #:email-matches-p #:find-email
   #:assert-email-sent #:assert-no-emails-sent #:assert-email-count
   ;; local adapter
   #:local-adapter #:make-local-adapter
   #:local-adapter-directory
   ;; smtp adapter (opt-in via :cliam/smtp)
   #:smtp-adapter #:make-smtp-adapter
   #:smtp-adapter-host #:smtp-adapter-port #:smtp-adapter-ssl
   #:smtp-adapter-username #:smtp-adapter-password
   ;; SES preset (opt-in via :cliam/ses)
   #:make-ses-smtp-adapter #:*ses-regions*))
