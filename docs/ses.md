# AWS SES preset

`make-ses-smtp-adapter` builds a pre-configured SMTP adapter
pointed at AWS SES's SMTP endpoint for a given region. It
doesn't introduce a new transport — it's just a constructor that
fills in the hostname and TLS settings.

Opt-in via `cliam/ses`:

```lisp
(ql:quickload :cliam/ses)
```

`cliam/ses` depends on `cliam/smtp` which depends on `cliam` —
loading it gives you the SMTP adapter and the SES preset.

For full SMTP details, see [smtp](./smtp.md). This page covers
just the SES-specific bits.

---

## Quick example

```lisp
(ql:quickload :cliam/ses)

(defparameter *mailer*
  (cliam:make-ses-smtp-adapter
   :region        "ap-northeast-1"
   :smtp-username (uiop:getenv "SES_SMTP_USER")
   :smtp-password (uiop:getenv "SES_SMTP_PASS")))

(setf cliam:*default-adapter* *mailer*)

(cliam:deliver
 (cliam:build-email
  :from "noreply@verified-domain.example"          ; must be SES-verified
  :to "alice@example.com"
  :subject "Welcome"
  :text-body "Thanks for signing up."))
```

---

## `(make-ses-smtp-adapter &key region smtp-username smtp-password port ssl) → ADAPTER`

| Key | Default | Notes |
| --- | ------- | ----- |
| `:region`        | `"us-east-1"` | AWS region string |
| `:smtp-username` | required | SES SMTP credential username |
| `:smtp-password` | required | SES SMTP credential password |
| `:port`          | `587`         | STARTTLS port |
| `:ssl`           | `:starttls`   | TLS mode |

Returns the same shape as `make-smtp-adapter` — an
`smtp-adapter` instance. Everything in [smtp](./smtp.md) applies.

The hostname is computed as
`email-smtp.<region>.amazonaws.com`. SES has SMTP endpoints in
these regions (as of 2024):

```
us-east-1 us-east-2 us-west-1 us-west-2
eu-west-1 eu-west-2 eu-central-1
ap-northeast-1 ap-northeast-2 ap-southeast-1 ap-southeast-2
ap-south-1 sa-east-1 ca-central-1
```

`*ses-regions*` is the list cliam knows about; it's **not
enforced** — pass any region string you've enabled SES in (AWS
adds new SES regions over time).

---

## SES SMTP credentials are NOT regular AWS keys

This is the most common gotcha.

In the AWS console:

1. Go to SES → SMTP Settings → **Create SMTP credentials**.
2. AWS creates a separate IAM user behind the scenes with a
   policy that allows `ses:SendRawEmail`.
3. You get an SMTP username + password.

The credentials **look** like AWS access keys (`AKIA...` /
40+ character secret), but:

- They're scoped to SES (the IAM user can't access S3 / EC2 /
  anything else).
- The password is HMAC-derived from the IAM user's secret key
  via SigV2 — not the secret itself.
- You can't compute them from your normal AWS access key
  programmatically; you generate them via the SES console (or
  the IAM API).

If you pass your regular AWS access keys, SES rejects auth with
535 5.7.8.

---

## Identity verification

SES requires sender identity verification before it will accept
mail from a From address.

1. **Verify a domain** (production): SES Console → Verified
   identities → Create identity → Domain. Get CNAME / TXT
   records, add to DNS. After validation, **any address on the
   domain** can send.

2. **Verify an email address** (sandbox / testing): SES Console
   → Verified identities → Create identity → Email address. You
   get a verification email. The verified address can send.

Sending from an unverified address fails with `554 Message
rejected: Email address is not verified.`

---

## Sandbox vs production

New SES accounts start in the **sandbox** — both sender and
recipient must be verified. Useful for testing without spamming
real users.

To send to arbitrary recipients, request **production access**
(SES Console → Get production access). AWS reviews the request;
typical turnaround is hours-to-days.

In production, the recipient doesn't need to be verified, but
the sender (domain or address) still does.

---

## Port choices

| `:port` | When |
| ------- | ---- |
| 587 (default) | Standard STARTTLS — works on most networks |
| 465           | Implicit TLS — pass `:ssl :tls` |
| 2587          | Alternative STARTTLS — when port 587 is blocked (some VPNs / containers) |
| 25            | Plain — **not supported by SES at all**; AWS rejects |

If your network blocks 587, try 2587 before reaching for a
non-SMTP solution.

---

## Snippets

**Production setup with env vars:**

```lisp
(defun init-ses ()
  (setf cliam:*default-adapter*
        (cliam:make-ses-smtp-adapter
         :region        (or (uiop:getenv "AWS_REGION") "us-east-1")
         :smtp-username (uiop:getenv "SES_SMTP_USER")
         :smtp-password (uiop:getenv "SES_SMTP_PASS"))))
```

**Switching to local in dev:**

```lisp
(defun init-mailer ()
  (setf cliam:*default-adapter*
        (cond
          ((production-p) (cliam:make-ses-smtp-adapter ...))
          ((staging-p)    (cliam:make-ses-smtp-adapter
                            :region "us-east-1"
                            ...))
          (t              (cliam:make-local-adapter #P"/tmp/dev-mail/")))))
```

**Cross-region failover** (very rare; SES regions are usually
fine on their own):

```lisp
(defun deliver-with-fallback (email primary secondary)
  (handler-case (cliam:deliver email :adapter primary)
    (cliam:deliver-error (e)
      (declare (ignore e))
      (cliam:deliver email :adapter secondary))))
```

Generally a queue with retries is the right tool — failover at
the cliam call level is a hack.

---

## Why no SES API adapter (yet)

The SES SMTP endpoint covers most use cases. AWS also has a
JSON HTTPS API (`SendRawEmail` / `SendEmail`) which would need
SigV4 signing via `ironclad` HMAC plus `dexador` for the HTTP
call. That's planned for environments where SMTP egress (port
587) isn't viable — typically locked-down container networks
that only allow HTTPS out.

If you need that today, write the adapter directly:

```lisp
(defclass ses-api-adapter ()
  ((region :initarg :region :reader ses-region)
   (key-id :initarg :key-id :reader ses-key-id)
   (secret :initarg :secret :reader ses-secret)))

(defmethod cliam:deliver-with ((a ses-api-adapter) email)
  (let ((sig-headers (build-sigv4-headers
                      (ses-region a) (ses-key-id a) (ses-secret a)
                      :service "ses" :request ...)))
    (dexador:post
     (format nil "https://email.~a.amazonaws.com/" (ses-region a))
     :headers sig-headers
     :content `(("Action" . "SendRawEmail")
                ("RawMessage.Data" . ,(base64-encode (cliam:render-rfc822 email)))))))
```

A 100-line adapter; mostly the SigV4 boilerplate, which lives
in any AWS-CL library you might already have.

---

## Gotchas

- **SES SMTP creds ≠ regular AWS keys.** See above.
- **Sender identity must be verified.** Domain verification
  unlocks "any address @ that domain"; address verification
  unlocks just that one.
- **Sandbox restricts recipients.** Production access is a
  one-time AWS approval.
- **From's `Return-Path` is rewritten by SES** to its own bounce
  address. You won't see bounces via the SMTP DSN path; consume
  them from SNS / SES bounce notifications.
- **DKIM signing is automatic** for verified domains (when you
  enable Easy DKIM in the SES console). You don't need to sign
  client-side.
- **Reputation matters.** SES will throttle / suspend you if
  your bounce or complaint rates rise. Monitor SES → Reputation
  metrics in production.
