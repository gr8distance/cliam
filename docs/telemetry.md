# telemetry

cliam emits three events around every delivery. You hook in by
setting `*telemetry*` to a function. No backend shipped — bring
your own logger / metrics / tracer.

---

## The hook

### `*telemetry*`

A function `(event payload)` called around every `deliver`
call. Defaults to `NIL` (disabled).

```lisp
(setf cliam:*telemetry*
      (lambda (event payload)
        (format t "[cliam] ~a~%" event)))
```

A bad handler is contained: errors raised by the callback are
**swallowed** via `ignore-errors` — observability code can't
take down delivery. (Unlike clauth's telemetry, cliam doesn't
log the first failure to `*error-output*`; this is simpler and
fits cliam's smaller surface.)

---

## Events

| Event | Payload | When |
| ----- | ------- | ---- |
| `:before-deliver` | `(:email E :adapter A)` | Just before `deliver-with` runs |
| `:after-deliver`  | `(:email E :adapter A :result R)` | After successful delivery |
| `:deliver-failed` | `(:email E :adapter A :condition C)` | When `deliver-with` signals; the condition is re-raised after the hook |

The `:email` payload key is the email **as passed to `deliver`**.
The `:result` key holds whatever `deliver-with` returned — the
email with any adapter-stashed assigns (`:delivered-via`,
`:delivered-path`, etc.).

`:condition` is the underlying condition (raw cl-smtp error, OS
error, whatever); cliam re-raises after the hook so a
`handler-case` at the call site still catches it.

---

## Wiring examples

### Log every delivery

```lisp
(setf cliam:*telemetry*
      (lambda (event payload)
        (case event
          (:before-deliver
           (log:info "sending to ~a"
                     (mapcar #'cliam:%addr-bare
                             (cliam:email-to (getf payload :email)))))
          (:after-deliver
           (log:info "sent to ~a"
                     (mapcar #'cliam:%addr-bare
                             (cliam:email-to (getf payload :email)))))
          (:deliver-failed
           (log:error "deliver failed via ~a: ~a"
                      (type-of (getf payload :adapter))
                      (getf payload :condition))))))
```

### Metrics

```lisp
(setf cliam:*telemetry*
      (lambda (event payload)
        (case event
          (:after-deliver  (statsd:incr "cliam.deliver.ok"))
          (:deliver-failed (statsd:incr "cliam.deliver.fail")))))
```

### Timing

`:before-deliver` and `:after-deliver` straddle the actual
send. Record a start time on `:before` and compute the delta
on `:after`:

```lisp
(let ((times (make-hash-table :test #'eq)))
  (setf cliam:*telemetry*
        (lambda (event payload)
          (let ((email (getf payload :email)))
            (case event
              (:before-deliver
               (setf (gethash email times) (get-internal-real-time)))
              (:after-deliver
               (let ((ms (* 1000
                            (/ (- (get-internal-real-time)
                                  (gethash email times 0))
                               internal-time-units-per-second))))
                 (log:info "deliver ~,1fms" ms)
                 (remhash email times)))
              (:deliver-failed
               (remhash email times)))))))
```

(Using the email value as a hash key works because emails are
unique objects per-deliver. Not bulletproof — a sufficiently
weird caller could share emails across threads — but fine for
typical use.)

### Conditional logging by content

```lisp
(setf cliam:*telemetry*
      (lambda (event payload)
        (when (and (eq event :deliver-failed)
                   ;; only log failures of important transactional mail
                   (search "password-reset"
                           (cliam:email-subject (getf payload :email))))
          (page-on-call "password reset email failed: ~a"
                        (getf payload :condition)))))
```

---

## What's in `:email`

The email value as it was right before delivery — including any
assigns set by the application. After `:after-deliver`, the
returned `:result` carries adapter-stashed assigns:

| Adapter | Assigns it sets |
| ------- | --------------- |
| `local-adapter` | `:delivered-path` (the written .eml file pathname) |
| `smtp-adapter`  | `:delivered-via :smtp` |
| `test-adapter`  | (none — captures the input as-is) |
| Your custom adapter | whatever you set |

For telemetry that wants the delivery details, read from
`:result` on `:after-deliver`, not from `:email`:

```lisp
(setf cliam:*telemetry*
      (lambda (event payload)
        (when (eq event :after-deliver)
          (log:info "delivered via ~a"
                    (cliam:get-assign (getf payload :result) :delivered-via)))))
```

---

## What's NOT in the payload

- **No timing data** — the hook is for instrumentation, not
  reporting. Compute timings yourself between `:before-deliver`
  and `:after-deliver`.
- **No rendered RFC 5322 body** — fetch via `render-rfc822` if
  you need it. Usually you don't; the email's slots are
  introspectable directly.
- **No "this is a retry"** — cliam doesn't retry. If your
  layer above does, thread that information through assigns
  (`:attempt-number`).

---

## Composing subscribers

`*telemetry*` is a single function. For multiple subscribers,
compose:

```lisp
(defparameter *cliam-subscribers* nil)

(setf cliam:*telemetry*
      (lambda (event payload)
        (dolist (sub *cliam-subscribers*)
          (ignore-errors (funcall sub event payload)))))

(push (lambda (e p) ...) *cliam-subscribers*)
(push (lambda (e p) ...) *cliam-subscribers*)
```

The outer wrapper still does `ignore-errors`, but the
per-subscriber form gives you debugging when a single
subscriber breaks (use `handler-case` for explicit logging).

---

## Hooking into auth-flow tests

When testing clauth's mail-driven flows, set `*telemetry*` to
capture deliveries even though the test adapter would also work:

```lisp
(let ((events nil)
      (cliam:*telemetry*
       (lambda (e p) (push (list e p) events))))
  (clauth:deliver-confirmation-instructions ...)
  ;; events now contains [:before-deliver ...] [:after-deliver ...]
  )
```

Useful when you want to assert "delivery was attempted" without
needing to inspect a test adapter's inbox.

---

## Performance overhead

Two `(when *telemetry* ...)` checks per delivery, each on a
fast path that short-circuits to no-op when unset. With
`*telemetry*` `NIL`, the cost is one dynamic variable lookup —
nanoseconds.

When set, the cost is whatever your callback does. Don't make
the callback synchronous-blocking on a network call; queue.

---

## Gotchas

- **Errors in the callback are silent.** `ignore-errors` wraps
  every call. If you suspect a busted subscriber, log inside
  the lambda explicitly:

  ```lisp
  (setf cliam:*telemetry*
        (lambda (event payload)
          (handler-case (my-real-handler event payload)
            (error (e)
              (format *error-output* "telemetry error: ~a~%" e)))))
  ```

- **The hook runs on the request thread.** Slow callback = slow
  `deliver`. Same as clauth.
- **`:deliver-failed` fires before the error is re-raised.**
  You can't suppress the error from the callback — it's an
  observation hook, not a recovery hook. Catch downstream of
  `deliver` if you want to swallow.
- **`:email` may not be the same object on `:after-deliver`.**
  Some adapters return a new email with assigns; the
  `:result` payload is canonical.
