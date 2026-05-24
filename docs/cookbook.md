# Cookbook

End-to-end patterns combining the cliam pieces.

---

## Sending a confirmation email

```lisp
(defun send-confirmation (user url)
  (cliam:deliver
   (-> (cliam:make-email)
       (cliam:from "noreply@example.com" "App")
       (cliam:to (getf user :email) (getf user :name))
       (cliam:subject "Please confirm your account")
       (cliam:text-body (format nil "Hi ~a,~%~%Click here to confirm:~%~a~%"
                                (getf user :name) url))
       (cliam:html-body (format nil "<p>Hi ~a,</p><p>Click <a href=\"~a\">here</a> to confirm.</p>"
                                (getf user :name) url)))))
```

In practice you'd let clauth's
`deliver-confirmation-instructions` handle this (see
[clauth/docs/mail.md](https://github.com/gr8distance/clauth/blob/main/docs/mail.md))
— but the underlying email construction is what cliam exposes.

(Substitute the thread-first macro with `let*` if you don't use
one.)

---

## A receipt with an attachment

```lisp
(defun send-receipt (user invoice-pdf-path)
  (cliam:deliver
   (-> (cliam:make-email)
       (cliam:from "billing@example.com" "App Billing")
       (cliam:to (getf user :email))
       (cliam:subject (format nil "Receipt for invoice ~a"
                              (getf user :invoice-id)))
       (cliam:text-body "See attached.")
       (cliam:attach invoice-pdf-path
                     :content-type "application/pdf"))))
```

The PDF is read at render time, base64-encoded, wrapped in
`multipart/mixed`. The file on disk doesn't need to exist when
the email value is built — only when `deliver` actually runs.

For an in-memory generated PDF:

```lisp
(cliam:attach email (generate-pdf-bytes user)
              :filename     "invoice.pdf"
              :content-type "application/pdf")
```

---

## Bulk broadcast with a shared base

```lisp
(defun broadcast (users subject text html)
  (let ((base (-> (cliam:make-email)
                  (cliam:from "broadcast@example.com" "App")
                  (cliam:subject subject)
                  (cliam:text-body text)
                  (cliam:html-body html))))
    (dolist (u users)
      (cliam:deliver (cliam:to base (getf u :email) (getf u :name))))))
```

`base` is reused — each `(to base ...)` returns a fresh email
with a single recipient. Don't put N recipients on one email
unless you actually want them to see each other (that's "Cc",
not "broadcast").

For large broadcasts (10k+), the per-deliver TCP handshake
dominates. Queue and have the SMTP relay handle pooling.

---

## Env-driven adapter selection

```lisp
(defun init-mailer ()
  (setf cliam:*default-adapter*
        (cond
          ((uiop:getenv "TEST")
           (cliam:make-test-adapter))                  ; tests
          ((null (uiop:getenv "PRODUCTION"))
           (cliam:make-local-adapter #P"/tmp/dev-mail/"))  ; dev
          ((string= (uiop:getenv "MAIL_BACKEND") "ses")
           (cliam:make-ses-smtp-adapter
            :region        (uiop:getenv "AWS_REGION")
            :smtp-username (uiop:getenv "SES_SMTP_USER")
            :smtp-password (uiop:getenv "SES_SMTP_PASS")))
          (t                                            ; default: generic SMTP
           (cliam:make-smtp-adapter
            :host     (uiop:getenv "SMTP_HOST")
            :port     (parse-integer (uiop:getenv "SMTP_PORT"))
            :ssl      :starttls
            :username (uiop:getenv "SMTP_USER")
            :password (uiop:getenv "SMTP_PASS")))))
  (setf cliam:*default-adapter*
        (or cliam:*default-adapter*
            (error "No mail adapter configured"))))
```

Run at app boot. Code that calls `(cliam:deliver email)` doesn't
change between environments.

---

## Queueing for production

In-process `deliver-async` is fine for low-volume / fire-and-forget.
For anything serious, queue:

```lisp
;; In your request path:
(defun enqueue-welcome (user)
  (let ((email (build-welcome-email user)))
    (cliam:validate-email email)                   ; fail fast at enqueue
    (job-queue:push *email-jobs* (cliam:render-rfc822 email))))

;; In a worker:
(defun deliver-from-queue ()
  (loop for raw = (job-queue:pop *email-jobs* :timeout 30)
        while raw
        do (send-raw-via-smtp raw)))
```

Two layers: cliam owns "build the email value + validate";
your job library owns "persist + retry + backoff."

For the worker side, you'd typically deliver via cliam too — but
since the email has already been rendered to a string at
enqueue time, the worker speaks SMTP directly (or
re-instantiates the email via your own deserializer if you need
to mutate it).

---

## Test the auth flow end-to-end

```lisp
(test register-sends-confirmation
  (cliam:with-fresh-inbox (mailer)
    (let ((*test-repo* (setup-test-repo)))
      ;; register a user
      (clecto:repo-insert *test-repo*
                          (clauth:register-changeset
                           'user (list :email "alice@example.com"
                                       :password "secret-secret"
                                       :password-confirmation "secret-secret")))
      ;; trigger the confirmation email
      (let ((user (clecto:repo-get-by *test-repo* 'user
                                      (list :email "alice@example.com"))))
        (clauth:deliver-confirmation-instructions
         :repo *test-repo* :token-schema 'auth-token
         :user user
         :url-builder (lambda (raw)
                        (format nil "https://app/c/~a" raw))
         :mailer mailer))
      ;; assert
      (cliam:assert-email-sent mailer
                                :to "alice@example.com"
                                :subject-contains "Confirm"))))
```

The test never touches SMTP or the filesystem.

---

## Pretty-printing rendered emails for review

A REPL helper:

```lisp
(defun preview (email)
  (terpri)
  (princ (cliam:render-rfc822 email))
  (terpri))

(preview (welcome-email some-user))
;; → prints headers + body to stdout
```

Useful while iterating on copy.

---

## Inline HTML with `cl-who`

cliam doesn't have a templating system. Combine with `cl-who`
(or your preferred HTML library) for HTML bodies:

```lisp
(defun render-welcome-html (user)
  (cl-who:with-html-output-to-string (s nil :prologue nil :indent t)
    (:p "Hi " (cl-who:str (getf user :name)) ",")
    (:p "Thanks for signing up.")
    (:p (:a :href "https://app/login" "Sign in here."))))

(-> (cliam:make-email)
    (cliam:from "noreply@app")
    (cliam:to (getf user :email))
    (cliam:subject "Welcome")
    (cliam:html-body (render-welcome-html user))
    cliam:deliver)
```

Or with `spinneret`:

```lisp
(spinneret:with-html-string
  (:p "Hi " (getf user :name) ",")
  (:p "Thanks for signing up.")
  (:p (:a :href "https://app/login" "Sign in here.")))
```

Either way, the HTML string is just a value handed to
`html-body`.

---

## A custom adapter that logs + delegates

```lisp
(defclass logging-adapter ()
  ((inner :initarg :inner :reader logging-inner)))

(defmethod cliam:deliver-with ((a logging-adapter) email)
  (log:info "delivering ~a -> ~{~a~^,~}"
            (cliam:email-subject email)
            (mapcar #'cdr (cliam:email-to email)))
  (cliam:deliver-with (logging-inner a) email))

;; usage
(setf cliam:*default-adapter*
      (make-instance 'logging-adapter
                     :inner (cliam:make-smtp-adapter ...)))
```

A decorator pattern — but consider `*telemetry*` first; it
covers most "log every delivery" cases without a new class.
A custom adapter is the right move when you want to **change**
behavior (rate-limit, deduplicate, fanout) rather than observe.

---

## A staging "fan-out" adapter

Send to both production AND a test inbox during staging
deploys:

```lisp
(defclass fanout-adapter ()
  ((adapters :initarg :adapters :reader fanout-adapters)))

(defmethod cliam:deliver-with ((a fanout-adapter) email)
  (let ((result nil))
    (dolist (sub (fanout-adapters a))
      (handler-case
          (setf result (cliam:deliver email :adapter sub
                                            :validate nil))
        (cliam:deliver-error (e)
          (log:warn "fanout: ~a failed: ~a" (type-of sub) e))))
    (or result email)))

(setf cliam:*default-adapter*
      (make-instance 'fanout-adapter
                     :adapters (list (cliam:make-ses-smtp-adapter ...)
                                     (cliam:make-local-adapter #P"/tmp/staging-mirror/"))))
```

Useful for "verify production sends are going out correctly" in
a pre-production environment. Don't run in real production.

---

## Anti-patterns

- **Building emails with `make-email` and `setf`.** The struct
  is mutable but treating it that way leaks state. Use the
  builders.
- **Calling `deliver-async` for high-volume work.** It spawns
  a thread per call. Use a job queue.
- **Embedding tokens / API keys in subject or body.** They land
  in logs (Subject in particular often gets logged by mail
  servers). Use links with one-time-use tokens (clauth's mail
  flows do this).
- **Hard-coding the production adapter in app code.** Set
  `*default-adapter*` once at boot from env vars; the rest of
  the app calls `(deliver email)`.
- **Not validating at enqueue time.** If you queue emails for
  later delivery, call `validate-email` before enqueuing —
  catches misconstructed emails synchronously where the user
  is still around to see the error.
