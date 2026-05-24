# Overview

cliam is built on a single idea:

> **An email is just a value.** Build it with pure functions.
> Hand it to an adapter when you're ready to send.

That's the whole library. Everything else is the consequence of
taking it seriously.

---

## The shape

```
   user-supplied parts                 wire-format string
        │                                     ▲
        ▼                                     │
   build-email / from / to / ...        render-rfc822
        │                                     ▲
        ▼                                     │
   email value (immutable)            ┌───────┴───────┐
        │                             │   adapter:    │
        ▼                             │   smtp / ses  │
   deliver(email, :adapter ...) ────► │   local / test│
                                      └───────────────┘
```

| Layer | What it owns | Doc |
| ----- | ------------ | --- |
| **email value**     | `from`, `to`, `subject`, `text-body`, `html-body`, attachments, headers, assigns | [email](./email.md) |
| **renderer**        | `render-rfc822` — turns an email into an RFC 5322 string | [email](./email.md) |
| **adapter protocol** | A single generic function `deliver-with` | [adapters](./adapters.md) |
| **adapters**        | `test-adapter`, `local-adapter`, `smtp-adapter`, SES preset | per-adapter doc |
| **telemetry**       | `*telemetry*` hook around every delivery | [telemetry](./telemetry.md) |

The email is a plain `defstruct`. Builders (`from`, `to`,
`subject`, `text-body`, etc.) each return a new email — nothing
mutates in user code. Composition is just function calls.

---

## A minimum send

```lisp
(ql:quickload :cliam)

(defparameter *mailer* (cliam:make-local-adapter #P"/tmp/out/"))

(cliam:deliver
 (-> (cliam:make-email)
     (cliam:from "noreply@example.com" "Acme")
     (cliam:to "alice@example.com" "Alice")
     (cliam:subject "Welcome")
     (cliam:text-body "Hi Alice,\n\nThanks for signing up.\n"))
 :adapter *mailer*)
```

(Substitute the thread-first macro with `let*` if you don't use
one — see [email](./email.md) for both styles.)

What just happened:

1. Each builder returned a new `email` struct with one slot
   updated. The originals are still around (and reusable).
2. `deliver` ran the email through `validate-email` (FROM
   present, at least one recipient), then dispatched to the
   adapter's `deliver-with` method.
3. The local adapter rendered the email to RFC 5322 and wrote
   `/tmp/out/<timestamp>-<random>.eml`.

---

## Why split builders + adapters

Two reasons:

**1. Testability.** A `test-adapter` captures emails in memory.
Your tests build emails the way production does, run delivery
against the test adapter, and assert against the captured
inbox — no SMTP server, no filesystem, no mailbox cleanup.

**2. Substitutability.** Production swaps the adapter (SMTP /
SES). Dev swaps the adapter (local file). Tests swap the
adapter (in-memory). Code that builds emails doesn't change.

```lisp
(setf cliam:*default-adapter*
      (if (production-p)
          (cliam:make-ses-smtp-adapter ...)
          (cliam:make-local-adapter #P"/tmp/dev-mail/")))

;; everywhere else just:
(cliam:deliver email)
```

---

## What earns its keep

cliam is small on purpose:

- **One email value.** No subclassing.
- **One protocol method.** `deliver-with`. Anything else is
  built on top.
- **Three adapters in core.** test (in-memory), local (file),
  SMTP (opt-in via `cliam/smtp`).
- **One SES preset.** Builds an SMTP adapter pointed at
  `email-smtp.<region>.amazonaws.com`. No SigV4 machinery.
- **No queueing.** `deliver-async` is a thread; queue durably
  via your job library if you need persistence.

Things that aren't here, on purpose:

| not in cliam | reach for |
| ------------ | --------- |
| Templates / variables in body strings | Your own templating (mustache / djula / `format`) |
| Bounce / complaint handling | SES / SendGrid webhooks → your app |
| Drip campaigns, segmentation | Higher-level marketing tooling |
| Inline images / cid: references | Currently out of scope; PRs welcome |
| Calendar invites, vCard | Build via `header` + `attach` if you really need |
| Mailgun / Postmark / SendGrid API adapters | Write `deliver-with` against `dexador` — 30 lines |

---

## Reading order

If you're new:

1. **[email](./email.md)** — building emails, the value model
2. **[adapters](./adapters.md)** — `deliver`, `*default-adapter*`, writing your own
3. **[local](./local.md)** — file-based adapter for development
4. **[test](./test.md)** — in-memory adapter + assertions

Then:

5. **[smtp](./smtp.md)** — opt-in SMTP adapter
6. **[ses](./ses.md)** — AWS SES preset
7. **[telemetry](./telemetry.md)** — observability hook

Cross-cutting:

8. **[cookbook](./cookbook.md)** — patterns
9. **[testing](./testing.md)** — testing emails fast
