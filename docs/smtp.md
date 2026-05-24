# SMTP adapter

Production-grade SMTP delivery. Thin wrapper around
[cl-smtp](https://github.com/3b/cl-smtp).

Opt-in via the `cliam/smtp` ASD system:

```lisp
(ql:quickload :cliam/smtp)
```

The subsystem pulls in `cl-smtp` and its transitive deps
(`usocket`, `cl+ssl`, `flexi-streams`, `cl-base64`) — that's why
it's opt-in rather than bundled.

For AWS SES specifically, see [ses](./ses.md) (a preset that
configures this adapter for SES's SMTP endpoint).

---

## Quick example

```lisp
(ql:quickload :cliam/smtp)

(defparameter *mailer*
  (cliam:make-smtp-adapter
   :host     "smtp.sendgrid.net"
   :port     587
   :ssl      :starttls
   :username "apikey"
   :password (uiop:getenv "SENDGRID_API_KEY")))

(setf cliam:*default-adapter* *mailer*)

(cliam:deliver
 (cliam:build-email
  :from "noreply@example.com"
  :to "alice@example.com"
  :subject "Welcome"
  :text-body "Thanks for signing up."))
```

---

## API

### `(make-smtp-adapter &key host port ssl username password) → ADAPTER`

| Key | Default | Notes |
| --- | ------- | ----- |
| `:host`      | required | SMTP server hostname (string) |
| `:port`      | `nil`    | Defaults to 465 for `:ssl :tls`, else 25. Always set explicitly in practice. |
| `:ssl`       | `nil`    | `nil` (plain), `:starttls`, or `:tls` |
| `:username`  | `nil`    | SMTP AUTH username |
| `:password`  | `nil`    | SMTP AUTH password |

When `:username` is `NIL`, no auth is performed (suitable for
in-LAN relays where the IP is the credential). When set, both
username and password go to cl-smtp's authentication
mechanism — typically PLAIN or LOGIN, negotiated by the server.

### `smtp-adapter-host` / `-port` / `-ssl` / `-username` / `-password`

Read accessors. Useful for tests that inspect the configuration
without coupling to the constructor.

---

## SSL / port pairings

The common configurations:

| Server expects | `:port` | `:ssl`        |
| -------------- | ------- | ------------- |
| Plain (no TLS) | 25      | `nil`         |
| STARTTLS       | 587     | `:starttls`   |
| Implicit TLS   | 465     | `:tls`        |
| Submission with STARTTLS, alt port | 2587 / 2525 | `:starttls` |

In 2024+ you should not be using plain SMTP except inside a
trusted local network. Production SMTP is one of `:starttls` /
`:tls`.

---

## What happens on delivery

`deliver-with` on an SMTP adapter:

1. Validates the email has a From address.
2. Builds the envelope: `From = (email-from email)` (stripped
   to bare address), `To = email-to + email-cc + email-bcc`
   (all bare addresses).
3. Renders the full RFC 5322 message via `render-rfc822`.
4. Hands it to `cl-smtp:with-smtp-mail` as a pre-formed message
   stream.

Why pre-rendering: cl-smtp's own header generation doesn't
support display names on `To`/`Cc` correctly, doesn't handle
RFC 2047 encoding for non-ASCII subjects, and produces a
different `multipart/*` structure than cliam's renderer. By
handing it a fully-rendered string, all of cliam's formatting
(display names, encoded subjects, attachments) survives the
wire.

5. On success, the returned email gets `:delivered-via :smtp`
   in its assigns. Read via:

   ```lisp
   (let ((e (cliam:deliver email)))
     (cliam:get-assign e :delivered-via))
   ;; → :smtp
   ```

6. On error, the cl-smtp condition is wrapped in
   `cliam:deliver-error`. The `(cause)` carries the original.

---

## Failure modes

The most common errors and what they mean:

| Error | Cause |
| ----- | ----- |
| Connection refused | wrong host / port |
| TLS handshake failure | wrong `:ssl` mode for the port (`:starttls` on 465, `:tls` on 587) |
| 535 5.7.8 Authentication failed | wrong `:username` / `:password` |
| 530 5.7.0 Must issue a STARTTLS command first | `:ssl nil` on a server that requires TLS |
| 550 No such recipient | the To address doesn't exist on this server |
| 421 Service shutting down | server-side issue; retry or use a different relay |

cl-smtp's condition includes the SMTP server's response code
and message; `(deliver-error-cause e)` exposes it for logging.

---

## Performance notes

- **One TCP connection per delivery.** cliam doesn't pool. For
  high-volume sending, queue deliveries and process from a
  worker that pools its own connection (or call into a service
  that does — Mailgun / SES / SendGrid each handle pooling).
- **Synchronous send blocks the calling thread.** Use
  `deliver-async` for fire-and-forget, or queue for durable
  retries.
- **TLS handshake is the dominant cost** (~50ms over a LAN to a
  cloud relay). The actual SMTP exchange is small. Connection
  reuse halves the latency for back-to-back sends.

---

## Snippets

**Gmail (via app password, not your real password):**

```lisp
(cliam:make-smtp-adapter
 :host     "smtp.gmail.com"
 :port     587
 :ssl      :starttls
 :username "you@gmail.com"
 :password (uiop:getenv "GMAIL_APP_PASSWORD"))
```

You need to enable 2FA + create an "app password" — Google
disables direct password auth for security reasons. App
passwords are 16-character codes you generate in the Google
account settings.

**SendGrid:**

```lisp
(cliam:make-smtp-adapter
 :host     "smtp.sendgrid.net"
 :port     587
 :ssl      :starttls
 :username "apikey"                              ; literal string "apikey"
 :password (uiop:getenv "SENDGRID_API_KEY"))
```

The username is the literal string `"apikey"`; SendGrid uses
that as a marker that the password slot carries an API key.

**Mailgun:**

```lisp
(cliam:make-smtp-adapter
 :host     "smtp.mailgun.org"
 :port     587
 :ssl      :starttls
 :username (uiop:getenv "MAILGUN_SMTP_USER")
 :password (uiop:getenv "MAILGUN_SMTP_PASS"))
```

Mailgun's SMTP creds are at Mailgun Domain → Domain Settings →
SMTP credentials.

**Postmark:**

```lisp
(cliam:make-smtp-adapter
 :host     "smtp.postmarkapp.com"
 :port     587
 :ssl      :starttls
 :username (uiop:getenv "POSTMARK_SERVER_TOKEN")
 :password (uiop:getenv "POSTMARK_SERVER_TOKEN"))   ; same value for both
```

Postmark uses the server token in both fields.

**AWS SES** — has its own preset; see [ses](./ses.md).

---

## Hidden behaviors

- **Bcc recipients receive the message** (they're in the SMTP
  envelope) but **don't appear in the rendered headers** —
  same as standard SMTP semantics.
- **The From address's domain ends up in the Message-ID** —
  generated by `render-rfc822`. Helps with downstream
  deliverability (mailing-list managers and spam filters
  prefer matching domains).
- **STARTTLS is opportunistic in cl-smtp's default mode.** A
  server that doesn't advertise STARTTLS will fall back to
  plain — meaning the credential goes over the wire in the
  clear. If your server *must* support TLS, verify the
  connection at the relay level rather than relying on
  cl-smtp's negotiation.
- **DKIM / SPF / DMARC** are the relay's job. Configure them
  in your DNS for the From domain; cliam doesn't sign or set
  Return-Path.

---

## When to NOT use this

- **AWS SES** — use the [ses](./ses.md) preset instead. Same
  underlying adapter, but the preset sets the region's
  endpoint hostname for you.
- **Heavily templated transactional mail** — providers like
  SendGrid and Mailgun have templates with variable substitution
  at the provider end. For those, write a custom adapter that
  hits their API (the JSON shape supports templates better
  than SMTP's MIME-and-pray).
- **Marketing-grade bulk send** — providers offer
  better-than-SMTP APIs for batching, suppression list
  handling, real-time bounces. Use those over plain SMTP.

For transactional auth-flavored email (welcome / confirm /
reset / magic-link), plain SMTP through a reputable relay is
fine.

---

## Gotchas

- **`:ssl :tls` with `:port 587`** doesn't work — port 587 is
  STARTTLS, port 465 is implicit TLS. Match them.
- **`:port nil` is dangerous.** It defaults to 465 only when
  `:ssl :tls` is set; otherwise it's 25 (plain). Always pass
  `:port` explicitly.
- **cl-smtp signals at the transport level.** A 5xx response
  from the server still raises — your `handler-case
  cliam:deliver-error` catches it, but the underlying
  condition is cl-smtp-specific.
- **Empty `:bcc` list still sends — `:bcc` doesn't add
  recipients on its own** in the empty case. To actually
  blind-copy, call `(bcc email "..")`.
