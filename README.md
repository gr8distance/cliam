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

| adapter | use |
|---|---|
| `test-adapter`  | tests — captures deliveries in memory (`test-inbox`) |
| `local-adapter` | development — writes `.eml` files to a directory |

Top-level entry: `(deliver email :adapter ...)` or bind
`*default-adapter*` per environment.

### Rendering

`(render-rfc822 email)` returns the message as a string. Supports
text-only, html-only, and `multipart/alternative` (both bodies). The
SMTP adapter will use this when it lands.

## What cliam intentionally does NOT do (yet)

| not in cliam (yet) | use this instead |
|---|---|
| Actual SMTP delivery | `cl-smtp` directly (a `cliam/smtp` adapter is planned) |
| Attachments on the wire | `local` adapter accepts attachments in the struct but doesn't render them yet |
| HTTP API providers (SendGrid / Mailgun / etc.) | the adapter protocol is open — write your own and `defmethod deliver-with` |
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
