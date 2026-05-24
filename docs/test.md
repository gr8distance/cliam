# test adapter

In-memory adapter that captures delivered emails for assertions.
Plus framework-agnostic helpers that match an inbox against
keyword predicates.

The point is to write production-shaped delivery code, run it
under a test adapter, and assert against what was sent — no
SMTP, no filesystem, no race conditions.

In cliam core — no opt-in load.

---

## Quick example

```lisp
(let ((adapter (cliam:make-test-adapter)))
  (cliam:deliver
   (cliam:build-email :from "x@y" :to "z@a"
                      :subject "Hi" :text-body "...")
   :adapter adapter)

  (cliam:assert-email-sent adapter :to "z@a" :subject "Hi"))
```

The assertion signals `cl:error` on miss — fiveam / rove /
parachute / 1am all report failures naturally.

---

## API

### `(make-test-adapter) → TEST-ADAPTER`

Make a fresh adapter with an empty inbox.

### `(test-inbox ADAPTER) → LIST-OF-EMAILS`

Read accessor for the captured inbox. **Newest first** —
`(first (test-inbox a))` is the most recently delivered email.

```lisp
(test-inbox adapter)
;; → (#<EMAIL :subject "Latest"> #<EMAIL :subject "Earlier"> ...)
```

Use this when the convenience assertions don't fit (e.g.
testing the body's exact bytes, asserting on attachments,
filtering by `email-assigns` keys).

### `(clear-inbox ADAPTER)`

Reset the captured inbox. Call from your test setup if you reuse
adapters across tests (`with-fresh-inbox` below makes this rare).

### `(with-fresh-inbox (ADAPTER-VAR) &body BODY)`

Macro. Binds ADAPTER-VAR to a fresh test-adapter, points
`*default-adapter*` at it, and runs BODY:

```lisp
(test sends-welcome
  (cliam:with-fresh-inbox (a)
    (send-welcome-email 'alice)               ; uses *default-adapter*
    (cliam:assert-email-sent a :subject "Welcome")))
```

This is the cleanest per-test fixture. Doesn't couple to fiveam
or any specific framework — it's a plain macro you can use
anywhere.

---

## Assertions

The convenience helpers signal `cl:error` on miss, with a
message naming what was expected and what was found. fiveam's
`is`, rove's `ok`, parachute's `true` all accept the result
and report failures cleanly.

### `(email-matches-p EMAIL &key from to cc subject subject-contains body-contains) → BOOLEAN`

Predicate. Returns `T` when EMAIL satisfies every supplied
keyword (omitted keys are ignored).

```lisp
(cliam:email-matches-p e :to "alice@example.com"
                         :subject-contains "Welcome")
```

Matcher semantics:

- `:from` — address-only match (`%addr-bare` strips any display
  name). Case-insensitive string comparison.
- `:to` / `:cc` — `:to` matches when any recipient's address
  matches. (No "exact list" matcher; build it manually if you
  need.)
- `:subject` — exact equality.
- `:subject-contains` — substring search.
- `:body-contains` — substring search in `text-body` OR
  `html-body` (either match counts).

### `(find-email ADAPTER &rest MATCHERS) → EMAIL | NIL`

Return the **first** email in the adapter's inbox matching the
keyword predicates. The inbox is newest-first, so this returns
the most-recent match.

```lisp
(let ((e (cliam:find-email adapter :to "alice@x" :subject "Welcome")))
  (when e (princ (cliam:email-text-body e))))
```

Returns `NIL` if nothing matches — for the "must exist" form,
use `assert-email-sent` instead.

### `(assert-email-sent ADAPTER &rest MATCHERS) → EMAIL`

Signal an error unless the inbox contains a matching email.
Returns the matched email on success — chain with field
assertions:

```lisp
(let ((e (cliam:assert-email-sent adapter
                                  :to (getf user :email)
                                  :subject "Welcome")))
  (assert (search "your account" (cliam:email-text-body e))))
```

The error message names the failing matcher and the inbox size:

```
No email matching (:TO "missing@x"); inbox has 2 message(s).
```

### `(assert-no-emails-sent ADAPTER)`

Signal an error if the inbox is non-empty. Useful for negative
assertions ("the cancellation flow doesn't email").

The error lists the subjects of what was found:

```
Expected empty inbox, found 1 message(s): ("Welcome!")
```

### `(assert-email-count ADAPTER EXPECTED)`

Assert that exactly EXPECTED emails were sent:

```lisp
(cliam:assert-email-count adapter 2)
```

Useful for "broadcast to all users" tests that need to verify
the right number went out.

---

## Patterns

### Per-test isolation

`with-fresh-inbox` is the recommended fixture. Each test gets
a clean adapter:

```lisp
(test welcome-flow
  (cliam:with-fresh-inbox (a)
    (register-user "alice@x")
    (cliam:assert-email-sent a :to "alice@x" :subject-contains "Welcome")))

(test cancellation-no-email
  (cliam:with-fresh-inbox (a)
    (cancel-user 'alice)
    (cliam:assert-no-emails-sent a)))
```

The two tests don't interfere — each binds its own
`*default-adapter*` for the duration of the macro body.

### Suite-wide adapter

If a suite has many tests touching mail and you want each test
to get a fresh inbox without the macro:

```lisp
(defparameter *test-adapter* (cliam:make-test-adapter))

(def-fixture mailer ()
  (setf cliam:*default-adapter* *test-adapter*)
  (cliam:clear-inbox *test-adapter*)
  (unwind-protect (&body) ()))

(test ...
  (with-fixture mailer ()
    (send-something)
    (cliam:assert-email-sent *test-adapter* :subject "X")))
```

`with-fresh-inbox` does this cleanly; reach for the
suite-shared variant only when you have a reason.

### Asserting on body details

When the convenience matchers (`:body-contains`) aren't enough,
read the email directly:

```lisp
(cliam:with-fresh-inbox (a)
  (send-password-reset 'alice)
  (let ((e (first (cliam:test-inbox a))))
    (assert (alexandria:starts-with-subseq
             "https://app/reset/" (extract-link (cliam:email-text-body e))))))
```

### Snapshot-testing the wire format

For format-stability tests (e.g. "Japanese subjects render
correctly"), render the email and assert on the string:

```lisp
(test japanese-subject-renders-rfc-2047
  (let ((rendered (cliam:render-rfc822
                   (cliam:build-email
                    :from "x@y" :to "z@a"
                    :subject "ようこそ"
                    :text-body "..."))))
    (is (search "=?UTF-8?B?" rendered))))
```

You don't even need an adapter for this — the email value
plus `render-rfc822` is enough.

### Capturing assigns set by the adapter

The test adapter just captures the email as-is. To assert on
the `:delivered-via :test` kind of metadata, set it in your
own delivery path:

```lisp
(let* ((e (cliam:deliver email :adapter adapter))
       (via (cliam:get-assign e :delivered-via)))
  (is (eq :test via)))
```

The test adapter doesn't set this — write a thin wrapper if you
want it for symmetry with other adapters.

---

## Snippets

**Counting attempts by subject:**

```lisp
(cliam:with-fresh-inbox (a)
  (loop repeat 3 do (send-welcome 'alice))
  (cliam:assert-email-count a 3)
  (let ((subjects (mapcar #'cliam:email-subject (cliam:test-inbox a))))
    (assert (every (lambda (s) (string= s "Welcome")) subjects))))
```

**Asserting the right recipient given a multi-tenant flow:**

```lisp
(cliam:with-fresh-inbox (a)
  (notify-admins-of-org org)
  (let ((sent (cliam:test-inbox a)))
    (is (= 1 (length sent)))
    (let ((tos (cliam:email-to (first sent))))
      (is (member "admin@org-x.com" (mapcar #'cdr tos)
                  :test #'string-equal)))))
```

**Asserting the email contains a token URL:**

```lisp
(cliam:with-fresh-inbox (a)
  (let ((raw (clauth:deliver-confirmation-instructions
              :repo *test-repo* :token-schema 'auth-token
              :user user
              :url-builder (lambda (raw) (format nil "https://app/c/~a" raw)))))
    (cliam:assert-email-sent
     a :to (getf user :email)
       :body-contains (format nil "https://app/c/~a" raw))))
```

---

## What this is NOT for

- **Testing the adapter implementations themselves.** Use a
  real local file for the local adapter; a live SMTP fixture
  for the SMTP adapter. The test adapter is for *your app's*
  use of mail.
- **Asserting on SMTP-level details** (envelope vs message
  headers). The test adapter captures the cliam email, not
  SMTP wire details. If you need to test envelope vs headers,
  inspect `render-rfc822` output directly.
- **Load testing.** It's a list-prepend on every delivery —
  fine for hundreds of test emails, slow for millions.

---

## Gotchas

- **Inbox is newest-first.** `(first inbox)` is the latest;
  `(last inbox)` is the earliest. Surprising if you expect
  chronological order — assert against `(find-email ...)` or
  reverse the list explicitly.
- **No validation default.** Test adapter sends through
  `deliver`, which validates by default — so an email with no
  From or no recipients raises before reaching the inbox.
  Skip with `(deliver e :adapter a :validate nil)` if you
  really want to capture invalid emails (rare; usually a bug).
- **`with-fresh-inbox` rebinds `*default-adapter*`.** Code
  inside the body that explicitly passes `:adapter` to
  `deliver` bypasses the test adapter. Avoid `:adapter` in code
  under test; let it pick up the dynamic binding.
