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
    (deliver (subject (from (to (make-email) "b@x.com") "a@x.com") "second"))
    (is (= 2 (length (test-inbox adapter))))
    ;; newest first
    (is (equal "second" (email-subject (first  (test-inbox adapter)))))
    (is (equal "first"  (email-subject (second (test-inbox adapter)))))
    (clear-inbox adapter)
    (is (null (test-inbox adapter)))))

(test deliver-without-adapter-signals
  (let ((*default-adapter* nil))
    (signals error (deliver (make-email)))))

(test validate-email-requires-from
  (signals error (validate-email (to (make-email) "x@y.com")))
  (signals error (validate-email (from (make-email) "a@x.com")))   ; no recipient
  (let ((e (to (from (make-email) "a@x.com") "b@x.com")))
    (is (eq e (validate-email e)))))

(test deliver-runs-validation-by-default
  (let* ((a (make-test-adapter))
         (*default-adapter* a))
    (signals error (deliver (make-email)))
    ;; opting out
    (deliver (make-email) :validate nil)
    (is (= 1 (length (test-inbox a))))))

(test telemetry-fires-around-deliver
  (let* ((a (make-test-adapter))
         (events nil)
         (*default-adapter* a)
         (*telemetry* (lambda (event payload)
                        (declare (ignore payload))
                        (push event events))))
    (deliver (to (from (make-email) "a@x.com") "b@x.com"))
    (is (equal '(:after-deliver :before-deliver) events))))

(test telemetry-fires-on-failure
  (let* ((events nil)
         (*telemetry* (lambda (event payload)
                        (declare (ignore payload))
                        (push event events)))
         (boom (make-instance 'test-adapter)))
    ;; override deliver-with to always fail
    (defmethod deliver-with ((a (eql boom)) email)
      (declare (ignore email))
      (error "boom"))
    (signals error (deliver (to (from (make-email) "a@x.com") "b@x.com")
                            :adapter boom))
    (is (member :deliver-failed events))
    (is (member :before-deliver events))
    (is (not (member :after-deliver events)))))

(test deliver-async-runs-in-thread-and-completes
  (let* ((a (make-test-adapter))
         (*default-adapter* a)
         (thread (deliver-async
                  (to (from (make-email) "a@x.com") "b@x.com"))))
    (bordeaux-threads:join-thread thread)
    (is (= 1 (length (test-inbox a))))))

(test deliver-async-invokes-on-error
  (let* ((captured nil)
         (boom (make-instance 'test-adapter)))
    (defmethod deliver-with ((a (eql boom)) email)
      (declare (ignore email))
      (error "boom"))
    (let ((thread (deliver-async
                   (to (from (make-email) "a@x.com") "b@x.com")
                   :adapter boom
                   :on-error (lambda (e) (setf captured e)))))
      (bordeaux-threads:join-thread thread)
      (is (not (null captured)))
      (is (search "boom" (format nil "~a" captured))))))

;;; --- local adapter --------------------------------------------------------

(defun temp-dir ()
  (let ((p (merge-pathnames
            (format nil "cliam-test-~a/" (random #x1000000))
            (uiop:temporary-directory))))
    (ensure-directories-exist p)
    p))

;;; --- assertions -----------------------------------------------------------

(defun seed-inbox ()
  (let* ((a (make-test-adapter))
         (*default-adapter* a))
    (deliver (subject (to (from (make-email) "noreply@x.com") "alice@x.com" "Alice")
                      "Welcome"))
    (deliver (subject (text-body (to (from (make-email) "noreply@x.com") "bob@x.com")
                                 "click here please")
                      "Reset your password"))
    a))

(test find-email-by-subject
  (let* ((a (seed-inbox))
         (e (find-email a :subject "Welcome")))
    (is (not (null e)))
    (is (equal "Welcome" (email-subject e)))))

(test find-email-by-recipient-and-substring
  (let ((a (seed-inbox)))
    (is (find-email a :to "bob@x.com" :subject-contains "Reset"))
    (is (find-email a :body-contains "click here"))))

(test assert-email-sent-returns-match
  (let ((a (seed-inbox)))
    (is (equal "Welcome"
               (email-subject (assert-email-sent a :to "alice@x.com"))))))

(test assert-email-sent-signals-on-miss
  (let ((a (make-test-adapter)))
    (signals error (assert-email-sent a :subject "anything"))))

(test assert-no-emails-sent
  (let ((a (make-test-adapter)))
    (assert-no-emails-sent a)
    (push (subject (make-email) "boom") (test-inbox a))
    (signals error (assert-no-emails-sent a))))

(test assert-email-count
  (let ((a (seed-inbox)))
    (assert-email-count a 2)
    (signals error (assert-email-count a 99))))

;;; --- attachments ----------------------------------------------------------

(defun temp-file-with-bytes (bytes)
  (let ((path (uiop:tmpize-pathname
               (merge-pathnames "cliam-att.bin" (uiop:temporary-directory)))))
    (with-open-file (s path :direction :output
                            :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
      (write-sequence bytes s))
    path))

(test render-attachment-multipart-mixed
  (let* ((bytes (map '(simple-array (unsigned-byte 8) (*)) #'char-code "hello bytes"))
         (path (temp-file-with-bytes bytes))
         (e (attach (text-body (make-email) "see attachment")
                    path :filename "note.txt" :content-type "text/plain"))
         (s (render-rfc822 e)))
    (is (search "multipart/mixed" s))
    (is (search "Content-Disposition: attachment; filename=\"note.txt\"" s))
    (is (search "Content-Transfer-Encoding: base64" s))
    ;; "hello bytes" -> base64 "aGVsbG8gYnl0ZXM="
    (is (search "aGVsbG8gYnl0ZXM=" s))
    (uiop:delete-file-if-exists path)))

(test attachment-content-type-defaulted-from-filename
  (let* ((path (temp-file-with-bytes #(0 1 2)))
         (e (attach (make-email) path :filename "logo.png")))
    (is (search "Content-Type: image/png; name=\"logo.png\"" (render-rfc822 e)))
    (uiop:delete-file-if-exists path)))

(test attachment-content-type-fallback-to-octet-stream
  (let* ((path (temp-file-with-bytes #(0 1 2)))
         (e (attach (make-email) path :filename "weirdfile.unknownext")))
    (is (search "application/octet-stream" (render-rfc822 e)))
    (uiop:delete-file-if-exists path)))

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
  ;; Pre-deliver validation catches missing FROM before the SMTP adapter
  ;; would; the test still verifies "no FROM is reported as an error".
  (let ((a (make-smtp-adapter :host "h")))
    (signals error
      (deliver (subject (make-email) "no from") :adapter a))))

(asdf:load-system :cliam/ses)

(test ses-preset-builds-correct-endpoint
  (let ((a (make-ses-smtp-adapter :region "ap-northeast-1"
                                  :smtp-username "AKIA-fake"
                                  :smtp-password "fake-secret")))
    (is (equal "email-smtp.ap-northeast-1.amazonaws.com" (smtp-adapter-host a)))
    (is (= 587 (smtp-adapter-port a)))
    (is (eq :starttls (smtp-adapter-ssl a)))
    (is (equal "AKIA-fake" (smtp-adapter-username a)))))

(test ses-preset-defaults-region-and-tls
  (let ((a (make-ses-smtp-adapter :smtp-username "u" :smtp-password "p")))
    (is (search "us-east-1" (smtp-adapter-host a)))
    (is (eq :starttls (smtp-adapter-ssl a)))))

(test ses-preset-allows-tls-on-465
  (let ((a (make-ses-smtp-adapter :smtp-username "u" :smtp-password "p"
                                  :port 465 :ssl :tls)))
    (is (= 465 (smtp-adapter-port a)))
    (is (eq :tls (smtp-adapter-ssl a)))))

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
