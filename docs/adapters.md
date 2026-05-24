# adapters

An adapter is anything for which `deliver-with` is defined. It's
a single generic-function protocol. cliam ships four out of the
box (test, local, SMTP, SES); writing your own is a one-method
job.

This page covers the protocol, `deliver` / `deliver-async`,
validation, and how to write your own adapter.

---

## The protocol

```lisp
(defgeneric deliver-with (adapter email)
  (:documentation
   "Hand EMAIL off to ADAPTER. Methods should return the email
   (possibly augmented with :delivered-at or other metadata in
   email-assigns) on success, or signal DELIVER-ERROR on failure."))
```

That's it. To plug in a new backend (Mailgun API, an in-process
queue, your custom SaaS, anything) — define a class and a method:

```lisp
(defclass my-adapter ()
  ((api-key :initarg :api-key :reader my-adapter-api-key)))

(defmethod cliam:deliver-with ((a my-adapter) email)
  ;; do whatever
  (post-to-api email (my-adapter-api-key a))
  email)
```

Use it like any built-in:

```lisp
(cliam:deliver email :adapter (make-instance 'my-adapter ...))
```

The protocol intentionally doesn't constrain how you process the
email — `render-rfc822` is available when you want the wire
format, or you can read the slots directly (`email-to`,
`email-subject`, etc.) when your transport doesn't speak SMTP.

---

## `deliver`

### `(deliver EMAIL &key adapter validate) → EMAIL`

The top-level send. Looks up `*default-adapter*` unless ADAPTER
is given. Runs `validate-email` up front when VALIDATE is true
(default).

```lisp
(cliam:deliver email :adapter *mailer*)
```

Lifecycle:

1. **Validate** — `validate-email` checks `email-from` is set
   and at least one recipient exists. Signals `cl:error`
   otherwise.
2. **Telemetry** — `:before-deliver` fires.
3. **Dispatch** — `deliver-with` runs.
4. **Telemetry** — `:after-deliver` on success,
   `:deliver-failed` on signalled error.
5. **Return** — the email returned by `deliver-with`. The
   original conditions are re-signalled on failure.

If `adapter` is `NIL` and `*default-adapter*` is unset:

```
error: No adapter: bind cliam:*default-adapter* or pass :adapter.
```

This is a loud-on-misconfiguration choice — the default is `NIL`
rather than a silently-accepting "no-op adapter."

### `*default-adapter*`

```lisp
(setf cliam:*default-adapter*
      (if (uiop:getenv "PRODUCTION")
          (cliam:make-smtp-adapter ...)
          (cliam:make-local-adapter #P"/tmp/dev-mail/")))
```

Used when `deliver` is called without `:adapter`. Set once at
app boot. Tests typically `(let ((*default-adapter* (make-test-adapter))) ...)`
inside a fixture — see [test](./test.md).

### Why `validate` defaults to T

The lint catches two common bugs:

- "I'm sending an email with no From — that's a delivery
  failure waiting at the SMTP server, but the failure mode is
  cryptic."
- "I forgot to call `to` — `validate-email` says so, the SMTP
  server would say 'no recipients,' but at least you know
  client-side."

Pass `:validate nil` to skip — useful when you're constructing
a partial email for serialisation / debugging.

---

## `(validate-email EMAIL) → EMAIL | error`

Pre-deliver lint:

- FROM must be set
- At least one of To / Cc / Bcc must be non-empty

Returns EMAIL on success (for chaining). Signals `cl:error`
otherwise — used internally by `deliver` and exported so you
can pre-check before persisting an email to a job queue.

```lisp
(defun enqueue (email)
  (cliam:validate-email email)        ; fail fast at enqueue time
  (queue:push *email-queue* email))
```

---

## `(deliver-async EMAIL &key adapter on-success on-error validate) → THREAD`

Fire-and-forget delivery. Spawns a `bordeaux-threads` thread
that runs `deliver`. Returns the thread:

```lisp
(cliam:deliver-async email
                     :on-success (lambda (result) (log-info "sent" result))
                     :on-error   (lambda (cond)   (log-error "failed" cond)))
```

What it does:

- Synchronously call `deliver` in a fresh thread.
- On success, call ON-SUCCESS with the returned email.
- On error, call ON-ERROR with the condition. If ON-ERROR is
  `NIL`, the condition is printed to `*error-output*`.

The callbacks run **in the spawned thread**. Be careful with
shared state — wrap in locks or queue back to a known consumer.

### When `deliver-async` is the right tool

- "I want the request to return immediately and the SMTP send
  to happen in the background." Good fit, low scale.
- "I want delivery to retry, persist across restarts, observe
  rate limits." **Wrong tool** — use a durable job queue
  (cl-rq, etc.). `deliver-async` is in-process only.

For production sending at any volume, queue the email via your
job library and consume from a worker that calls
`deliver` synchronously.

---

## `deliver-error`

```lisp
(define-condition cliam:deliver-error (error)
  ((email   :initarg :email   :reader deliver-error-email)
   (adapter :initarg :adapter :reader deliver-error-adapter)
   (cause   :initarg :cause   :reader deliver-error-cause)))
```

What adapters signal when delivery fails. The SMTP adapter
wraps cl-smtp's conditions; a custom adapter should do the
same (wrap the underlying driver's error) so callers see a
consistent type.

```lisp
(handler-case (cliam:deliver email)
  (cliam:deliver-error (e)
    (log-error "delivery failed via ~a: ~a"
               (type-of (cliam:deliver-error-adapter e))
               (cliam:deliver-error-cause e))))
```

The default reporter doesn't include the email contents (which
might contain PII / secrets) — just the adapter type and the
cause. Reach for `deliver-error-email` if you specifically want
to log the email that failed.

---

## Writing a custom adapter

Step 1: define the class.

```lisp
(defclass mailgun-adapter ()
  ((domain  :initarg :domain  :reader mailgun-domain)
   (api-key :initarg :api-key :reader mailgun-api-key)))

(defun make-mailgun-adapter (&key domain api-key)
  (make-instance 'mailgun-adapter :domain domain :api-key api-key))
```

Step 2: implement `deliver-with`.

```lisp
(defmethod cliam:deliver-with ((a mailgun-adapter) email)
  (handler-case
      (multiple-value-bind (body status)
          (dexador:post
           (format nil "https://api.mailgun.net/v3/~a/messages.mime"
                   (mailgun-domain a))
           :basic-auth (cons "api" (mailgun-api-key a))
           :content `(("to" . ,(format nil "~{~a~^, ~}"
                                       (mapcar #'cliam:%addr-bare
                                               (cliam:email-to email))))
                      ("message" . ,(cliam:render-rfc822 email))))
        (declare (ignore body))
        (unless (= status 200)
          (error 'cliam:deliver-error :email email :adapter a
                                       :cause (format nil "HTTP ~a" status))))
    (error (e)
      (error 'cliam:deliver-error :email email :adapter a :cause e)))
  (cliam:assign email :delivered-via :mailgun))
```

Step 3: use it.

```lisp
(cliam:deliver email
               :adapter (make-mailgun-adapter
                         :domain "mg.example.com"
                         :api-key (uiop:getenv "MAILGUN_KEY")))
```

Conventions to follow:

- **Wrap underlying errors** in `cliam:deliver-error` so
  callers can `handler-case` once and catch failures from any
  adapter.
- **Stash delivery metadata** on the returned email via
  `assign` — `:delivered-via`, `:provider-id`, `:cost`,
  whatever. Doesn't appear in the wire format; useful for
  telemetry and tests.
- **Don't mutate the input email.** Return a fresh one (via
  `assign` etc.).
- **Render with `render-rfc822` when the transport speaks
  SMTP/MIME**. Read slots directly when the transport speaks
  its own JSON / protobuf protocol (Mailgun JSON, SendGrid v3).

---

## Snippets

**Switch adapters per environment:**

```lisp
(defun pick-adapter ()
  (case (uiop:getenv "MAIL_BACKEND")
    ("smtp"   (cliam:make-smtp-adapter :host "smtp" ...))
    ("ses"    (cliam:make-ses-smtp-adapter ...))
    ("local"  (cliam:make-local-adapter #P"/tmp/dev-mail/"))
    (t        (cliam:make-test-adapter))))

(setf cliam:*default-adapter* (pick-adapter))
```

**Retry on a specific error class** (use sparingly — usually a
job queue is the right abstraction):

```lisp
(defun deliver-with-retry (email &key (attempts 3))
  (loop for attempt from 1 to attempts
        do (handler-case (return (cliam:deliver email))
             (cliam:deliver-error (e)
               (if (= attempt attempts)
                   (error e)
                   (sleep (expt 2 attempt)))))))
```

**Sending without an adapter for inspection:**

```lisp
(princ (cliam:render-rfc822 email))
;; → prints the full wire format to stdout
```

Useful in a REPL to verify "what would actually go out?"
without involving an adapter.

**Multi-adapter "fan out" for staging tests** (send to both a
test inbox and the real adapter):

```lisp
(defclass fanout-adapter ()
  ((adapters :initarg :adapters :reader fanout-adapters)))

(defmethod cliam:deliver-with ((a fanout-adapter) email)
  (dolist (sub (fanout-adapters a))
    (cliam:deliver email :adapter sub :validate nil))
  email)
```

Useful in pre-production where you want to verify deliveries
without losing visibility.

---

## Gotchas

- **`deliver` re-raises errors after the telemetry hook**.
  Don't catch in the telemetry callback expecting to suppress —
  the callback only runs for observation.
- **`deliver-async` errors are silent without `:on-error`**.
  Pass one in production. Without it, failures hit
  `*error-output*` and that's it.
- **Adapter methods get the same email**. If you have multiple
  adapters (logging + production), they share the input; don't
  let one mutate via `setf` on the struct directly.
- **The default `*default-adapter*` is `NIL`**. Forgetting to
  set it is a loud error, not a silent drop. This is on purpose.
