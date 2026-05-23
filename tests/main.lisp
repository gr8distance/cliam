(defpackage #:cliam/tests
  (:use #:cl #:cliam #:fiveam))
(in-package #:cliam/tests)

(def-suite :cliam)
(in-suite :cliam)

;;; --- builders -------------------------------------------------------------

(test builders-are-functional
  (let* ((e0 (make-email))
         (e1 (from e0 "a@x.com"))
         (e2 (to (to e1 "b@x.com") "c@x.com" "Charlie")))
    (is (null (email-from e0)))                       ; e0 untouched
    (is (equal "a@x.com" (email-from e1)))
    (is (= 2 (length (email-to e2))))
    (is (equal "b@x.com" (first (email-to e2))))
    (is (equal '("Charlie" . "c@x.com") (second (email-to e2))))))

(test subject-and-bodies
  (let ((e (html-body (text-body (subject (make-email) "hi") "text") "<b>html</b>")))
    (is (equal "hi" (email-subject e)))
    (is (equal "text" (email-text-body e)))
    (is (equal "<b>html</b>" (email-html-body e)))))

(test header-replace-is-case-insensitive
  (let* ((e1 (header (make-email) "X-Foo" "1"))
         (e2 (header e1 "x-foo" "2")))
    (is (equal "2" (getf (email-headers e2) "x-foo")))
    ;; only one entry kept
    (is (= 2 (length (email-headers e2))))))

(test assign-and-get-assign
  (let ((e (assign (make-email) :note "draft")))
    (is (equal "draft" (get-assign e :note)))
    (is (equal "fallback" (get-assign e :missing "fallback")))))

;;; --- rendering ------------------------------------------------------------

(test render-text-only
  (let* ((e (text-body (subject (from (to (make-email) "b@x.com") "a@x.com" "Alice")
                                "hello") "world"))
         (s (render-rfc822 e)))
    (is (search "From: Alice <a@x.com>" s))
    (is (search "To: b@x.com" s))
    (is (search "Subject: hello" s))
    (is (search "Content-Type: text/plain; charset=utf-8" s))
    (is (search "world" s))))

(test render-html-only
  (let ((s (render-rfc822 (html-body (make-email) "<h1>hi</h1>"))))
    (is (search "Content-Type: text/html; charset=utf-8" s))
    (is (search "<h1>hi</h1>" s))))

(test render-utf8-subject-encoded-rfc2047
  (let* ((e (subject (make-email) "ようこそ"))
         (s (render-rfc822 e)))
    (is (search "Subject: =?UTF-8?B?" s))
    ;; raw Japanese must not appear in the headers
    (is (null (search "ようこそ" s)))))

(test render-utf8-display-name-encoded
  (let* ((e (from (make-email) "alice@x.com" "山田太郎"))
         (s (render-rfc822 e)))
    (is (search "=?UTF-8?B?" s))
    (is (search "<alice@x.com>" s))
    (is (null (search "山田太郎" s)))))

(test render-ascii-subject-passes-through
  (let ((s (render-rfc822 (subject (make-email) "Hello"))))
    (is (search "Subject: Hello" s))
    (is (null (search "=?UTF-8?B?" s)))))

(test render-body-declares-8bit-transfer-encoding
  (let ((s (render-rfc822 (text-body (make-email) "anything"))))
    (is (search "Content-Transfer-Encoding: 8bit" s))))

(test render-multipart-when-both-bodies
  (let* ((e (html-body (text-body (make-email) "plain") "<p>rich</p>"))
         (s (render-rfc822 e)))
    (is (search "multipart/alternative" s))
    (is (search "plain" s))
    (is (search "<p>rich</p>" s))))

;;; --- adapter protocol + test adapter --------------------------------------

(test test-adapter-captures-deliveries
  (let* ((adapter (make-test-adapter))
         (*default-adapter* adapter))
    (deliver (subject (from (to (make-email) "b@x.com") "a@x.com") "first"))
    (deliver (subject (make-email) "second"))
    (is (= 2 (length (test-inbox adapter))))
    ;; newest first
    (is (equal "second" (email-subject (first  (test-inbox adapter)))))
    (is (equal "first"  (email-subject (second (test-inbox adapter)))))
    (clear-inbox adapter)
    (is (null (test-inbox adapter)))))

(test deliver-without-adapter-signals
  (let ((*default-adapter* nil))
    (signals error (deliver (make-email)))))

;;; --- local adapter --------------------------------------------------------

(defun temp-dir ()
  (let ((p (merge-pathnames
            (format nil "cliam-test-~a/" (random #x1000000))
            (uiop:temporary-directory))))
    (ensure-directories-exist p)
    p))

;;; --- smtp adapter (constructor / arg shaping; no live send) --------------

(asdf:load-system :cliam/smtp)

(test smtp-adapter-fields-default
  (let ((a (make-smtp-adapter :host "smtp.example.com")))
    (is (equal "smtp.example.com" (smtp-adapter-host a)))
    (is (null (smtp-adapter-port a)))
    (is (null (smtp-adapter-ssl  a)))
    (is (null (smtp-adapter-username a)))))

(test smtp-adapter-stores-credentials
  (let ((a (make-smtp-adapter :host "h" :port 587 :ssl :starttls
                              :username "u" :password "p")))
    (is (eq :starttls (smtp-adapter-ssl a)))
    (is (equal "u" (smtp-adapter-username a)))
    (is (equal "p" (smtp-adapter-password a)))
    (is (= 587 (smtp-adapter-port a)))))

(test smtp-deliver-without-from-signals
  (let ((a (make-smtp-adapter :host "h")))
    (signals deliver-error
      (deliver (subject (make-email) "no from") :adapter a))))

(test addr-helpers
  (is (equal "x@y.com" (cliam::%addr-bare "x@y.com")))
  (is (equal "x@y.com" (cliam::%addr-bare '("Alice" . "x@y.com"))))
  (is (null (cliam::%addr-name "x@y.com")))
  (is (equal "Alice" (cliam::%addr-name '("Alice" . "x@y.com")))))

(test local-adapter-writes-eml-file
  (let* ((dir (temp-dir))
         (adapter (make-local-adapter dir))
         (e (subject (text-body (from (to (make-email) "b@x.com") "a@x.com")
                                "hello there") "smoke")))
    (let* ((delivered (deliver-with adapter e))
           (path (get-assign delivered :delivered-path)))
      (is (probe-file path))
      (let ((contents (with-open-file (s path :external-format :utf-8)
                        (with-output-to-string (out)
                          (loop for line = (read-line s nil nil)
                                while line do (format out "~a~%" line))))))
        (is (search "Subject: smoke" contents))
        (is (search "hello there" contents)))
      (uiop:delete-file-if-exists path)
      (uiop:delete-empty-directory dir))))
