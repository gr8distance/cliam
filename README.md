# cliam

A tiny composable mailer for Common Lisp.

> The library name reversed spells **`mailc`** — *mail in CL*.

cliam is built on a single idea:

> **An email is just a value.** Build it with pure functions.
> Hand it to an adapter when you're ready to send.

The struct is immutable in user code. Adapters are plug-in
generic-function methods. Tests run against an in-memory
adapter. Production uses SMTP / SES. Dev writes `.eml` files to
a directory. The build code doesn't change.

---

## Install

`cliam` isn't on Quicklisp yet. Symlink it into `local-projects`:

```sh
git clone https://github.com/gr8distance/cliam.git ~/src/cliam
ln -s ~/src/cliam ~/quicklisp/local-projects/cliam
```

```lisp
(ql:quickload :cliam)            ; core: email, test-adapter, local-adapter
(ql:quickload :cliam/smtp)       ; opt-in: SMTP adapter (pulls cl-smtp)
(ql:quickload :cliam/ses)        ; opt-in: AWS SES preset (wraps cliam/smtp)
```

---

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

(Substitute the thread-first macro with `let*` if you don't use
one.)

---

## Documentation

cliam is documented as topic pages under [`docs/`](./docs/).

**Core**

- [Overview](./docs/overview.md) — philosophy, layers, mental model
- [email](./docs/email.md) — struct, builders, attachments, `render-rfc822`
- [adapters](./docs/adapters.md) — protocol, `deliver`, custom adapters

**Built-in adapters**

- [test](./docs/test.md) — in-memory adapter + assertions
- [local](./docs/local.md) — file-based adapter for development
- [smtp](./docs/smtp.md) — SMTP adapter (opt-in `cliam/smtp`)
- [ses](./docs/ses.md) — AWS SES preset (opt-in `cliam/ses`)

**Observability**

- [telemetry](./docs/telemetry.md) — `*telemetry*` lifecycle hook

**Cross-cutting**

- [Cookbook](./docs/cookbook.md) — full patterns
- [Testing](./docs/testing.md) — testing emails fast

---

## What's intentionally out of scope

| not in cliam | reach for |
| ------------ | --------- |
| Templates / variables in body strings | Your own templating: `format`, mustache, djula, spinneret |
| Bounce / complaint handling           | SES / SendGrid webhooks → your app |
| Drip campaigns, segmentation          | Higher-level marketing tooling |
| Inline images (`cid:` refs)           | Build via `header` + `attach` + `multipart/related` manually |
| Calendar invites / vCard              | Use `attach` with the appropriate content-type |
| Mailgun / Postmark / SendGrid APIs    | 30-line custom adapter against their JSON HTTP API |

---

## Source layout

```
src/
  email.lisp       ; the email struct + builders + render-rfc822
  adapter.lisp     ; deliver-with protocol + deliver + telemetry
  test.lisp        ; in-memory test adapter
  local.lisp       ; file-based local adapter + mailbox API
  smtp.lisp        ; SMTP adapter (cliam/smtp system)
  ses.lisp         ; SES preset (cliam/ses system)
  assertions.lisp  ; framework-agnostic test helpers
```

Each file is small and orthogonal — read whichever covers what
you're touching.

---

## Run the tests

```sh
sbcl --non-interactive --load ~/quicklisp/setup.lisp \
     --eval '(ql:quickload :cliam/tests)' \
     --eval '(asdf:test-system :cliam)'
```

---

## License

MIT
