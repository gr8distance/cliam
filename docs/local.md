# local adapter

Writes each delivery as an `.eml` file under a directory. Open
the files in any mail client (Apple Mail, Thunderbird) to
inspect — useful for development without an SMTP server, and
for verifying message-format changes.

In cliam core — no opt-in load needed.

---

## Quick example

```lisp
(defparameter *mailer* (cliam:make-local-adapter #P"/tmp/myapp-mail/"))
(setf cliam:*default-adapter* *mailer*)

(cliam:deliver
 (-> (cliam:make-email)
     (cliam:from "noreply@example.com")
     (cliam:to "alice@example.com")
     (cliam:subject "Welcome")
     (cliam:text-body "Hi.")))

;; check the file
(directory #P"/tmp/myapp-mail/*.eml")
;; → (#P"/tmp/myapp-mail/20260224-103045-12ab34.eml")
```

Open the file:

```sh
open /tmp/myapp-mail/20260224-103045-12ab34.eml
# or
cat /tmp/myapp-mail/*.eml
```

---

## API

### `(make-local-adapter DIRECTORY) → ADAPTER`

DIRECTORY is a pathname or pathname-string. The directory is
created lazily on the first delivery (`ensure-directories-exist`).

```lisp
(cliam:make-local-adapter #P"/tmp/cliam-out/")
(cliam:make-local-adapter "/tmp/cliam-out/")
```

### `(local-adapter-directory ADAPTER) → PATHNAME`

Read accessor. Useful for tests that inspect the output dir
without hard-coding the path.

---

## File naming

Filenames look like `YYYYMMDD-HHMMSS-<hex>.eml`. The timestamp
is local time at delivery; the hex suffix is a 6-character
random tag.

```
/tmp/cliam-out/
├── 20260224-103045-12ab34.eml
├── 20260224-103046-7def09.eml
└── 20260224-103048-456789.eml
```

Sorting by filename gives chronological order, which is what
`list-mailbox` (below) relies on.

The random suffix prevents collisions when two deliveries land
in the same second. Two deliveries in the same millisecond on
the same random seed are unlikely but possible — for high-
throughput cases, use a different adapter.

---

## Mailbox API

Helpers for working with the directory **after** writes have
landed.

### `(list-mailbox ADAPTER) → LIST-OF-PATHNAMES`

Every `.eml` file in the adapter's directory, sorted oldest
first. Useful in tests:

```lisp
(let ((files (cliam:list-mailbox *mailer*)))
  (assert (= 1 (length files))))
```

### `(read-mailbox-entry PATH) → STRING`

Contents of an `.eml` file. UTF-8 decode.

```lisp
(let ((body (cliam:read-mailbox-entry (first (cliam:list-mailbox *mailer*)))))
  (assert (search "Subject: Welcome" body)))
```

### `(delete-mailbox-entry PATH) → BOOLEAN`

Remove a single file. Returns T when a file was deleted.
Idempotent on missing.

### `(clear-mailbox ADAPTER) → INTEGER`

Delete every `.eml` file in the adapter's directory. Returns
the number of files deleted. Useful between dev sessions or
test runs:

```lisp
(cliam:clear-mailbox *mailer*)   ; tidy up
```

### `(pop-mailbox ADAPTER) → STRING | NIL`

Remove and return the contents of the **oldest** `.eml` file,
or `NIL` when empty. Useful for "process the queue" patterns
where a dev worker drains the mailbox:

```lisp
(loop for body = (cliam:pop-mailbox *mailer*)
      while body
      do (send-to-real-smtp body))
```

This is dev-tool territory — for real queueing you'd want a
job library with retries, backoff, etc.

---

## What the .eml contains

The full output of `render-rfc822` — see [email](./email.md).
Roughly:

```
From: noreply@example.com
To: alice@example.com
Subject: Welcome
Date: Mon, 24 Feb 2026 10:30:45 +0900
Message-ID: <01EBF...@example.com>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

Hi.
```

Multipart bodies (`multipart/alternative` for text+html,
`multipart/mixed` for attachments) render with the appropriate
MIME structure. Standard mail clients display them correctly.

---

## Snippets

**A dev startup that sends to a local dir:**

```lisp
(defun init-mailer ()
  (let ((dir #P"/tmp/myapp-mail/"))
    (ensure-directories-exist dir)
    (setf cliam:*default-adapter* (cliam:make-local-adapter dir))
    (format t "~&Mail .eml files go to ~a~%" dir)))
```

[onogoro](https://github.com/gr8distance/onogoro) does this in
its demo setup, plus it also prints token URLs to stdout so a
REPL user doesn't have to open `.eml` files for every flow.

**Pretty-print every delivered email:**

```lisp
(defun tail-mail (n)
  (let* ((files (last (cliam:list-mailbox *mailer*) n)))
    (dolist (p files)
      (format t "~&==== ~a ====~%~a~%~%"
              (file-namestring p)
              (cliam:read-mailbox-entry p)))))
```

Useful at a REPL after exercising auth flows: `(tail-mail 5)`
prints the last 5 emails.

**Clear between integration tests:**

```lisp
(def-fixture mailbox ()
  (cliam:clear-mailbox *mailer*)
  (unwind-protect (&body) ()))
```

For unit tests, prefer the [test adapter](./test.md) — it's
in-memory and faster.

---

## Why .eml files

- **Portable.** Every mail client opens them.
- **Greppable.** `grep "Welcome to App" /tmp/myapp-mail/*.eml`
  is faster than scrolling through a test inbox.
- **Self-contained.** Even if your app crashes, the files
  persist.
- **No setup.** No SMTP server in dev.

The tradeoff is filesystem I/O on every send. Don't use this
in production — for that you want SMTP / SES / SendGrid /
Mailgun adapters that actually deliver mail.

---

## Gotchas

- **The directory grows.** Add `(clear-mailbox *mailer*)` to
  your dev shutdown / cron / fixture if you don't want stale
  files accumulating.
- **Timestamp-based filenames are local time.** Switching
  timezones during a session produces non-sorted names. Fine
  for dev; if you care, use a different adapter.
- **`pop-mailbox` is destructive.** It deletes the file as it
  returns the body. Use `list-mailbox` + `read-mailbox-entry`
  for non-destructive inspection.
- **`assign :delivered-path`**. The local adapter stashes the
  written path on the returned email. Use it to verify:

  ```lisp
  (let ((e (cliam:deliver email :adapter *mailer*)))
    (cliam:get-assign e :delivered-path))
  ;; → #P"/tmp/cliam-out/..."
  ```
