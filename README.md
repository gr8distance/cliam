# cliam

A tiny composable mailer for Common Lisp, in the spirit of Phoenix's
[Swoosh](https://hexdocs.pm/swoosh).

> The library name reversed spells **`mailc`** — *mail in CL*.

One idea, recycled from [clug](https://github.com/gr8distance/clug):

> **An email is just a value.** Build it with pure functions. Hand it
> to an adapter when you're ready to send.

---

## Install

`cliam` isn't on Quicklisp yet. Symlink it into `local-projects`:

```sh
git clone https://github.com/gr8distance/cliam.git ~/src/cliam
ln -s ~/src/cliam ~/quicklisp/local-projects/cliam
```

```lisp
(ql:quickload :cliam)
```

## Quickstart

```lisp
(in-package #:cliam)

(defparameter *mailer*
  (make-local-adapter #P"/tmp/cliam-out/"))

(deliver
  (-> (make-email)
      (from "noreply@example.com" "Example")
      (to "alice@example.com" "Alice")
      (subject "Welcome")
      (text-body "Hi Alice,\n\nThanks for joining.\n")
      (html-body "<p>Hi Alice,</p><p>Thanks for joining.</p>"))
  :adapter *mailer*)
```

The local adapter drops one `.eml` per delivery under the given
directory — open them in any mail client to inspect.

## Core concepts

### email — the value that flows

| accessor | meaning |
|---|---|
| `email-from`       | sender; address string or `(name . address)` |
| `email-to`         | list of recipients (To header) |
| `email-cc`         | list (Cc header) |
| `email-bcc`        | list (Bcc — stripped before send if the adapter respects it) |
| `email-reply-to`   | single address |
| `email-subject`    | string |
| `email-text-body`  | string \| nil |
| `email-html-body`  | string \| nil |
| `email-headers`    | plist of extra headers (case-insensitive replace) |
| `email-attachments`| list (wire-format support arrives in 0.2) |
| `email-assigns`    | plist for user data (e.g. tagging emails by template) |

Builders return a fresh email — no mutation:

```lisp
(from      email "addr@x.com" &optional name)
(to        email "addr@x.com" &optional name)   ; appends
(cc        email "addr@x.com" &optional name)
(bcc       email "addr@x.com" &optional name)
(reply-to  email "addr@x.com" &optional name)
(subject   email "...")
(text-body email "...")
(html-body email "...")
(header    email "X-Foo" "bar")
(attach    email path :filename "..." :content-type "...")
(assign    email :key value)
```

### Adapters

An adapter is anything with a `deliver-with` method:

```lisp
(defmethod deliver-with ((a my-adapter) email)
  ;; send the email; return it (optionally augmented via assign) on success,
  ;; or signal CLIAM:DELIVER-ERROR on failure.
  ...)
```

Built-in:

| adapter | use | system |
|---|---|---|
| `test-adapter`  | tests — captures deliveries in memory (`test-inbox`) | `cliam` (core) |
| `local-adapter` | development — writes `.eml` files to a directory | `cliam` (core) |
| `smtp-adapter`  | production — sends via SMTP using `cl-smtp` | `cliam/smtp` (opt-in) |
| `make-ses-smtp-adapter` | production — AWS SES SMTP preset | `cliam/ses` (opt-in) |

```lisp
(ql:quickload :cliam/smtp)

(defparameter *mailer*
  (make-smtp-adapter :host "smtp.example.com"
                     :port 587
                     :ssl :starttls
                     :username "noreply@example.com"
                     :password (uiop:getenv "SMTP_PASSWORD")))

(deliver email :adapter *mailer*)
```

AWS SES is a one-liner via the preset:

```lisp
(ql:quickload :cliam/ses)

(defparameter *mailer*
  (make-ses-smtp-adapter :region "ap-northeast-1"
                         :smtp-username (uiop:getenv "SES_SMTP_USER")
                         :smtp-password (uiop:getenv "SES_SMTP_PASS")))
```

(`smtp-username` / `smtp-password` are **SES SMTP credentials** —
generated under SES Console > SMTP Settings, distinct from your raw
AWS access keys.)

Display names on the From address are passed to `cl-smtp` as
`:display-name`; recipient names on To/Cc/Bcc are currently stripped
(envelope addresses only).

Top-level entry: `(deliver email :adapter ...)` or bind
`*default-adapter*` per environment.

### Rendering

`(render-rfc822 email)` returns the message as a string. Supports:

- text-only, html-only, and `multipart/alternative` (both bodies)
- attachments via `multipart/mixed` (base64-encoded, Content-Type
  guessed from filename via `trivial-mimes`, falls back to
  `application/octet-stream`)
- attachments from either a pathname or an in-memory octet vector
- RFC 2047 encoded-word for non-ASCII subjects and display names
  (Japanese et al.) — base64 + UTF-8
- `Content-Transfer-Encoding: 8bit` on body parts so strict MTAs
  accept the UTF-8 payload as-is
- RFC 5322 §2.2.3 header folding at 78 chars (long subjects,
  recipient lists)
- auto-generated `Message-ID` so MTAs don't downrank or refuse the
  message
- display names on To/Cc/Bcc preserved on the wire (SMTP adapter
  hands cliam-rendered headers to the MTA rather than letting
  `cl-smtp` rewrite them)

### Building emails

Chain builders, or use the one-call constructor:

```lisp
;; chained
(-> (make-email)
    (from "noreply@example.com")
    (to   "alice@example.com" "Alice")
    (subject "Hi"))

;; one-call
(build-email :from "noreply@example.com"
             :to (list "alice@example.com" '("Bob" . "bob@example.com"))
             :subject "Hi"
             :text-body "...")
```

### Delivery

```lisp
(deliver email :adapter *mailer*)                     ; sync, default
(deliver email :adapter *mailer* :validate nil)        ; skip pre-flight check
(deliver-async email :on-success (lambda (r) ...)      ; background thread
                     :on-error   (lambda (e) ...))
```

Every `deliver` runs `validate-email` first (FROM required, at least
one recipient required) — set `:validate nil` to skip in rare cases.
Bind `*telemetry*` to a `(lambda (event payload) ...)` to observe
`:before-deliver`, `:after-deliver`, and `:deliver-failed` events.

### Test assertions

Framework-agnostic helpers that signal on miss (fiveam / rove /
parachute all report failures naturally). `with-fresh-inbox` gives
per-test isolation without coupling to any framework's fixture
machinery:

```lisp
(with-fresh-inbox (adapter)
  (send-welcome-mail "alice@example.com")
  (assert-email-sent adapter
                     :to "alice@example.com"
                     :subject-contains "Welcome")
  (assert-email-count adapter 1))
```

Also: `find-email`, `email-matches-p`, `assert-no-emails-sent`,
`clear-inbox`.

### Local mailbox inspection

The local adapter writes one `.eml` per delivery; helpers let you
inspect or drain that directory programmatically:

```lisp
(list-mailbox adapter)            ; -> list of pathnames, oldest first
(read-mailbox-entry path)         ; -> string contents
(pop-mailbox adapter)             ; -> oldest entry as string, deletes it
(delete-mailbox-entry path)
(clear-mailbox adapter)           ; -> count of deleted entries
```

## What cliam intentionally does NOT do (yet)

| not in cliam (yet) | use this instead |
|---|---|
| HTTP API providers (SendGrid / Mailgun / Postmark / Resend / Brevo / ...) | the adapter protocol is open — write your own and `defmethod deliver-with`; one per ~50 LOC |
| AWS SES via the SES HTTP API (SigV4) | use `cliam/ses` (SMTP) for now; HTTP API adapter is planned |
| Inline images (`multipart/related` + `Content-ID`) | not yet — multipart/mixed attachments work |
| `quoted-printable` body encoding | not needed for modern MTAs; bodies use `8bit` |
| DKIM signing | offload to your sending service (SES / SendGrid / etc.) — they sign for you |
| Bulk delivery + retry | not yet — call `deliver` in a loop, plug into your job queue |
| Template rendering | bring your own (`spinneret`, `djula`, `cl-who`, etc.) — pass the result to `text-body` / `html-body` |
| Bcc enforcement | adapters strip Bcc before send themselves (the struct just stores it) |

## Tests

```sh
sbcl --non-interactive \
     --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :cliam/tests)' \
     --eval '(asdf:test-system :cliam)'
```

## License

MIT
