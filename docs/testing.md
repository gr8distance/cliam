# Testing

cliam is designed so that most testing happens **without
SMTP**. Build emails the way production does; deliver against
the in-memory test adapter; assert against the captured inbox.

For [test-adapter](./test.md)-specific helpers (assertions,
predicates), see that page. This one covers strategy: when to
use which adapter, how to structure fixtures, what NOT to test.

---

## The three adapters in testing

| Adapter | When to reach for it |
| ------- | -------------------- |
| `test-adapter`  | **Default for unit tests.** In-memory, fast, no I/O. |
| `local-adapter` | Integration tests that want to inspect rendered RFC 5322. |
| `smtp-adapter`  | End-to-end tests against a real SMTP server (rarely worth it). |

The split lets you choose granularity. A test asserting "the
welcome flow sends one email" uses `test-adapter`. A test
asserting "the rendered email has correct MIME structure" uses
`local-adapter` and reads the file.

---

## Unit test pattern

```lisp
(test welcome-sends-one-email
  (cliam:with-fresh-inbox (mailer)
    (welcome-user "alice@x")
    (cliam:assert-email-count mailer 1)
    (cliam:assert-email-sent mailer
                              :to "alice@x"
                              :subject "Welcome")))
```

`with-fresh-inbox` is the right primitive — it binds a fresh
test adapter to `*default-adapter*` for the duration of the
body. No suite-level state to clean.

For tests that need to inspect more than the convenience
predicates cover:

```lisp
(test welcome-includes-display-name
  (cliam:with-fresh-inbox (mailer)
    (welcome-user '(:email "alice@x" :name "Alice Smith"))
    (let ((e (first (cliam:test-inbox mailer))))
      (assert (search "Alice" (cliam:email-text-body e))))))
```

`test-inbox` exposes the captured emails; introspect freely
with the `email-*` accessors.

---

## Rendering tests

For "the rendered RFC 5322 is correct" tests, you can skip the
adapter entirely:

```lisp
(test ja-subject-encodes
  (let ((rendered (cliam:render-rfc822
                   (cliam:build-email
                    :from "x@y" :to "z@a"
                    :subject "ようこそ"
                    :text-body "..."))))
    (is (search "=?UTF-8?B?" rendered))
    (is (search "MIME-Version: 1.0" rendered))))
```

`render-rfc822` is a pure function over the email — no I/O,
no adapter needed. Run as fast as your test framework lets you.

For assertions on attachment encoding:

```lisp
(test attachment-base64-wrapped
  (uiop:with-temporary-file (:pathname p)
    (with-open-file (s p :direction :output)
      (write-sequence "hello, world" s))
    (let ((rendered (cliam:render-rfc822
                     (-> (cliam:build-email :from "x@y" :to "z@a"
                                            :subject "S" :text-body "...")
                         (cliam:attach p)))))
      (is (search "multipart/mixed" rendered))
      (is (search "Content-Transfer-Encoding: base64" rendered)))))
```

---

## Local-adapter integration tests

When you want the test to write a real file and assert against
the file:

```lisp
(test local-adapter-writes-eml
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/cliam-test-~a/" (random 1000))))
         (a (cliam:make-local-adapter dir)))
    (unwind-protect
         (progn
           (cliam:deliver (cliam:build-email :from "x@y" :to "z@a"
                                             :subject "S" :text-body "B")
                          :adapter a)
           (let ((files (cliam:list-mailbox a)))
             (is (= 1 (length files)))
             (let ((body (cliam:read-mailbox-entry (first files))))
               (is (search "Subject: S" body)))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
```

Use a unique temp directory per test so parallel runs don't
collide. Clean up in `unwind-protect`.

---

## SMTP integration tests

If you must test against a real SMTP server, use a local
one (Mailpit, MailHog) rather than a production relay. Both
present an HTTP API for inspecting captured emails:

```lisp
(test smtp-actually-delivers
  (let ((a (cliam:make-smtp-adapter
            :host "localhost" :port 1025 :ssl nil)))
    (cliam:deliver (cliam:build-email :from "x@y" :to "z@a"
                                       :subject "S" :text-body "B")
                   :adapter a)
    ;; assert via mailpit's HTTP API
    (let ((messages (mailpit-list-messages)))
      (is (= 1 (length messages)))
      (is (string= "S" (getf (first messages) :subject))))))
```

For CI, run Mailpit / MailHog in a sidecar container; the
test asserts against the captured inbox there. Don't hit
production SMTP from tests.

---

## Tests for adapters you wrote

Write your custom adapter's tests using the same shape:

```lisp
(test my-adapter-sets-delivered-via
  (let* ((a (make-my-adapter ...))
         (e (cliam:deliver (cliam:build-email :from "x@y" :to "z@a"
                                              :subject "S" :text-body "B")
                           :adapter a)))
    (is (eq :my-backend (cliam:get-assign e :delivered-via)))))

(test my-adapter-wraps-errors
  (let ((a (make-my-adapter :force-fail t)))
    (signals cliam:deliver-error
      (cliam:deliver (cliam:build-email :from "x@y" :to "z@a"
                                        :subject "S" :text-body "B")
                     :adapter a))))
```

The contract for custom adapters (see [adapters](./adapters.md))
is "return the email on success, signal `deliver-error` on
failure" — those two assertions cover it.

---

## Telemetry tests

`*telemetry*` is dynamic — bind it inside the test to capture
events:

```lisp
(test telemetry-fires-around-deliver
  (let ((events nil))
    (let ((cliam:*telemetry*
           (lambda (e p) (push (cons e p) events))))
      (cliam:with-fresh-inbox (a)
        (cliam:deliver (cliam:build-email :from "x@y" :to "z@a"
                                          :subject "S" :text-body "B")
                       :adapter a)))
    (is (member :before-deliver (mapcar #'car events)))
    (is (member :after-deliver  (mapcar #'car events)))))
```

For "deliver-failed fires on error" tests, use an adapter that
always signals:

```lisp
(defclass always-fails ()  ())

(defmethod cliam:deliver-with ((a always-fails) email)
  (declare (ignore email))
  (error 'cliam:deliver-error :adapter a :email nil
                              :cause "intentional"))

(test failure-fires-deliver-failed
  (let ((events nil)
        (cliam:*telemetry* (lambda (e p) (push (cons e p) events))))
    (handler-case
        (cliam:deliver (cliam:build-email :from "x@y" :to "z@a"
                                          :subject "S" :text-body "B")
                       :adapter (make-instance 'always-fails))
      (cliam:deliver-error () nil))
    (is (assoc :deliver-failed events))))
```

---

## Argon / Crypto cost

Unlike clauth, cliam has no per-test cost knob — there's
nothing CPU-bound to dial down. Test suites against the test
adapter run essentially instantaneously.

The exception is if your *email content* includes generated PDF
attachments or other heavy work — that's your code, not cliam's.
Cache or mock the content generation.

---

## What NOT to test

- **The RFC 5322 format itself**. cliam's tests cover header
  folding, RFC 2047 encoding, multipart structure. Your tests
  should cover that **your app uses cliam correctly** — what
  recipients, what subjects, what trigger conditions.
- **`render-rfc822` byte-for-byte identical output**. The
  format is stable, but the `Date` and `Message-ID` headers
  include the current time / random — so exact-string tests
  break per-run. Assert on substrings or specific structural
  pieces.
- **SMTP transport** (in unit tests). Use the test adapter.
  Save SMTP for a small set of integration tests against
  Mailpit / MailHog.
- **Provider-specific behaviors** (DKIM signatures, bounce
  handling). Those happen on the provider side; your tests
  don't run the provider's code.

---

## A typical test layout

```lisp
(defpackage #:my-app/tests
  (:use #:cl #:fiveam #:my-app)
  (:import-from #:cliam
                #:with-fresh-inbox
                #:assert-email-sent #:assert-email-count
                #:assert-no-emails-sent))

(in-package #:my-app/tests)

(def-suite :my-app)
(in-suite :my-app)

(test welcome-flow
  (with-fresh-inbox (a)
    (welcome-user 'alice)
    (assert-email-sent a :to "alice@x" :subject-contains "Welcome")))

(test cancellation-no-email
  (with-fresh-inbox (a)
    (cancel-user 'alice)
    (assert-no-emails-sent a)))
```

Run from the REPL:

```lisp
(asdf:test-system :my-app)
```

---

## Quick reference

| What you want to test                 | How |
| ------------------------------------- | --- |
| "An email was sent to X"              | `with-fresh-inbox` + `assert-email-sent` |
| "Exactly N emails were sent"          | `assert-email-count` |
| "No email was sent"                   | `assert-no-emails-sent` |
| "The body contains a specific URL"    | `assert-email-sent ... :body-contains "..."` |
| "The wire format includes header X"   | `render-rfc822` + `search` for the string |
| "Attachment is encoded base64"        | render-rfc822 + search for `base64` content-transfer-encoding |
| "Custom adapter sets `:delivered-via`" | inspect `(get-assign email :delivered-via)` after `deliver` |
| "Telemetry fires"                     | bind `*telemetry*` to a closure that appends |
| "Adapter wraps errors as `deliver-error`" | `(signals cliam:deliver-error ...)` |
