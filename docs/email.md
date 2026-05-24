# email

The `email` struct is the value that flows through every
builder. Each builder returns a new email — treat the struct as
immutable in user code.

This page covers the struct, every builder, the one-shot
constructor, and the RFC 5322 renderer.

---

## The struct

```lisp
(defstruct email
  from         ; (name . addr) | "addr" | nil
  to           ; list of addresses
  cc           ; list of addresses
  bcc          ; list of addresses (stripped on render where appropriate)
  reply-to     ; single address
  subject      ; string
  text-body    ; string | nil
  html-body    ; string | nil
  headers      ; plist of extra headers
  attachments  ; list of attachment plists
  assigns)     ; plist for adapter-side metadata
```

Accessors follow the standard `(email-slot e)` convention:
`email-from`, `email-to`, etc. Use them for ad-hoc reads; the
builders below cover the common patterns.

An **address** is one of:

- A bare string — `"alice@example.com"`. No display name.
- A `(name . addr)` cons — `'("Alice" . "alice@example.com")`.
  The display name is RFC 2047 encoded on render when it's
  non-ASCII.

`from` and `reply-to` are single addresses. `to`, `cc`, `bcc`
are lists.

---

## Builders

Each builder takes an email and returns a new email. They
compose with `let*`, with a thread-first macro, or as a chain
of `let` bindings — pick what your project prefers.

### `(make-email) → EMAIL`

Build a fresh email with all slots at their defaults. Usually
the seed of a chain.

### `(from EMAIL ADDR &optional NAME) → EMAIL`

Set the From address.

```lisp
(from email "noreply@example.com")
(from email "noreply@example.com" "Acme Support")
```

### `(reply-to EMAIL ADDR &optional NAME) → EMAIL`

Set the Reply-To address. Useful when From is a no-reply
address but you want replies to land somewhere readable:

```lisp
(-> email
    (from "noreply@example.com" "Acme")
    (reply-to "support@example.com" "Acme Support"))
```

### `(to EMAIL ADDR &optional NAME) → EMAIL`

**Append** a recipient to To. (Doesn't replace — chain calls
to add multiple.)

```lisp
(-> email
    (to "alice@example.com" "Alice")
    (to "bob@example.com"))
;; → email with To: Alice <alice@example.com>, bob@example.com
```

### `(cc EMAIL ADDR &optional NAME)` / `(bcc EMAIL ADDR &optional NAME)`

Same shape as `to`. Appends to Cc / Bcc.

Bcc is not rendered in the message headers — adapters strip it
before send. (The SMTP adapter still lists Bcc recipients in
the envelope so they receive the message.)

### `(subject EMAIL STRING) → EMAIL`

Set the Subject. Non-ASCII subjects are RFC 2047 encoded on
render — so a Japanese subject arrives as Japanese, not as
mojibake.

### `(text-body EMAIL STRING-OR-NIL) → EMAIL` / `(html-body EMAIL STRING-OR-NIL) → EMAIL`

Set the text or HTML body. Set both → renders as
`multipart/alternative`. Set one → renders as that single part.

```lisp
(-> email
    (text-body "Hi,\n\nThanks for signing up.\n")
    (html-body "<p>Hi,</p><p>Thanks for signing up.</p>"))
```

### `(header EMAIL NAME VALUE) → EMAIL`

Set / replace a custom header. NAME comparison is
case-insensitive — calling `(header e "X-Foo" "1")` then
`(header e "x-foo" "2")` results in one header `X-Foo: 2`.

```lisp
(header email "X-Campaign-Id" "welcome-2024")
(header email "List-Unsubscribe" "<mailto:u@example.com>")
```

clauth-generated emails don't add headers themselves; reach for
this when you need List-Unsubscribe, X-Mailgun-Variables, etc.

### `(attach EMAIL SOURCE &key filename content-type) → EMAIL`

Add an attachment. SOURCE is one of:

- A **pathname** (or pathname-string) — file is read at render
  time. FILENAME defaults to the file's basename;
  CONTENT-TYPE is auto-guessed via `trivial-mimes:mime-lookup`.

  ```lisp
  (attach email #P"/var/reports/2024-01.pdf")
  (attach email #P"/tmp/x.dat" :content-type "application/octet-stream")
  ```

- An **octet vector** — used as-is. FILENAME is required.

  ```lisp
  (attach email (generate-pdf-bytes)
          :filename "invoice.pdf"
          :content-type "application/pdf")
  ```

Calling `attach` multiple times appends. The renderer produces a
`multipart/mixed` body with the message text as the first part
and each attachment base64-encoded.

### `(assign EMAIL KEY VALUE) → EMAIL` / `(get-assign EMAIL KEY &optional DEFAULT)`

A plist owned by you. Adapters use it to add delivery metadata
(the local adapter stashes `:delivered-path`, the SMTP adapter
sets `:delivered-via :smtp`). Application code can stuff
anything there:

```lisp
(assign email :campaign-id "welcome-2024")
;; later, in a telemetry callback:
(get-assign email :campaign-id)
```

Assigns don't appear in the wire format — they're for
in-process bookkeeping only.

---

## One-shot constructor

### `(build-email &key from to cc bcc reply-to subject text-body html-body headers attachments assigns) → EMAIL`

For when you'd rather pass everything in one call:

```lisp
(cliam:build-email
 :from "noreply@example.com"
 :to (list "alice@example.com"
           '("Bob" . "bob@example.com"))
 :subject "Welcome"
 :text-body "Hi,\n\nThanks.\n"
 :html-body "<p>Hi,</p><p>Thanks.</p>"
 :headers (list "X-Campaign-Id" "welcome-2024")
 :assigns (list :campaign-id "welcome-2024"))
```

Address fields (`:to`, `:cc`, `:bcc`) accept:

- A single string (`"a@b"`)
- A single `(name . addr)` cons
- A list of either

The result is a regular email value — further mutation via
individual builders is fine.

---

## RFC 5322 rendering

### `(render-rfc822 EMAIL) → STRING`

Serialise EMAIL into an RFC 5322 wire-format string suitable
for SMTP, `.eml` file output, or `cat`-ing into `sendmail`.

You don't normally call this — adapters do it for you. Reach
for it when:

- Debugging "what does the actual wire format look like?"
- Writing a custom adapter
- Snapshot-testing message structure

```lisp
(princ (cliam:render-rfc822
        (-> (cliam:make-email)
            (cliam:from "x@y" "X")
            (cliam:to "z@a" "Z")
            (cliam:subject "Hello, 世界")
            (cliam:text-body "...\n"))))
```

What it produces:

```
From: X <x@y>
To: Z <z@a>
Subject: =?UTF-8?B?SGVsbG8sIOS4lueVjA==?=
Date: Mon, 24 Feb 2026 10:30:00 +0900
Message-ID: <00000000ABCD1234.0123456789ABCDEF@y>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: 8bit

...
```

### What the renderer handles

- **Non-ASCII subjects + display names** → RFC 2047
  encoded-word (`=?UTF-8?B?...?=`). Latin-only subjects pass
  through unchanged.
- **Long header lines** → folded at the 78-char limit, with
  continuation lines starting with a single space. Recipient
  lists fold cleanly at `, ` boundaries.
- **text only** → single-part `text/plain; charset=utf-8` with
  `Content-Transfer-Encoding: 8bit`.
- **html only** → single-part `text/html; charset=utf-8`.
- **Both** → `multipart/alternative` with both parts.
- **Attachments** → wraps the body in `multipart/mixed`. Each
  attachment is base64-encoded with `Content-Transfer-Encoding:
  base64` and a `Content-Disposition: attachment; filename=...`
  header.
- **`Message-ID`** → auto-generated from the From address's
  domain (or `cliam.local` fallback) + time + random.
- **`Date`** → current local time in RFC 822 format with
  timezone offset.

### What the renderer does NOT do

- **Bounce setup** — no Return-Path, no VERP. Set those via
  `header` if your MTA expects them.
- **DKIM / DMARC signing** — out of scope. Sign at the SMTP
  layer or downstream (most providers DKIM-sign for you).
- **Inline images (`cid:` references)** — currently no helper
  for `Content-ID` / `multipart/related`. Build manually via
  `header` + `attach` + raw HTML if you need.
- **Internationalised email addresses (SMTPUTF8)** — local-part
  is assumed ASCII. Display names handle non-ASCII fine.

---

## Address formats — gotchas

- **A single email can have a list of addresses**, but a single
  builder call adds **one**. To add three recipients, call `to`
  three times. (The `build-email` constructor accepts a list for
  convenience.)
- **`(name . addr)` is a cons, not a list.** Don't write
  `'("Alice" "alice@example.com")` — that's a 2-element list,
  and the renderer expects `(cons name addr)`. Use
  `'("Alice" . "alice@example.com")` or `(cons "Alice"
  "alice@example.com")`.
- **No address validation.** cliam doesn't check that a
  recipient string is a well-formed email. `validate-email`
  only checks that From + at least one recipient exists. SMTP
  servers will reject malformed addresses; the test and local
  adapters won't.

---

## Snippets

**A welcome email with both bodies:**

```lisp
(defun welcome-email (user)
  (-> (cliam:make-email)
      (cliam:from "noreply@app" "App")
      (cliam:reply-to "support@app")
      (cliam:to (getf user :email) (getf user :name))
      (cliam:subject "Welcome to App")
      (cliam:text-body (format nil "Hi ~a,~%~%Thanks for joining.~%"
                               (getf user :name)))
      (cliam:html-body (format nil "<p>Hi ~a,</p><p>Thanks for joining.</p>"
                               (getf user :name)))))
```

(Substitute the thread-first macro with your project's
preferred threading style.)

**A receipt with a PDF attachment:**

```lisp
(defun receipt-email (user pdf-path)
  (-> (cliam:make-email)
      (cliam:from "billing@app" "App Billing")
      (cliam:to (getf user :email))
      (cliam:subject "Your receipt")
      (cliam:text-body "See attached.")
      (cliam:attach pdf-path)))
```

**A bulk send loop** — note that each iteration builds a fresh
email; the base is reusable:

```lisp
(defun broadcast (users subject body)
  (let ((base (-> (cliam:make-email)
                  (cliam:from "broadcast@app" "App")
                  (cliam:subject subject)
                  (cliam:text-body body))))
    (dolist (u users)
      (cliam:deliver (cliam:to base (getf u :email))))))
```

`base` doesn't get mutated — each `(to base ...)` produces a
fresh email with the recipient set.

**Reading back an attachment from a built email:**

```lisp
(let ((e (cliam:attach (cliam:make-email)
                       #P"/tmp/x.txt")))
  (cliam:email-attachments e))
;; → ((:pathname #P"/tmp/x.txt" :filename "x.txt" :content-type NIL))
```

Useful in tests when asserting an attachment was added.
