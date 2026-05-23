(in-package #:cliam)

;;; Framework-agnostic test helpers that match against a test-adapter's
;;; inbox. They signal CL:ERROR on miss, so fiveam / rove / parachute
;;; all report failures naturally.

(defun %addr-match-p (email-addr expected)
  "Does EMAIL-ADDR (string or (name . addr) cons) match EXPECTED (string)?"
  (let ((bare (etypecase email-addr
                (string email-addr)
                (cons   (cdr email-addr)))))
    (string-equal bare expected)))

(defun %contains-recipient-p (recipients expected)
  (some (lambda (r) (%addr-match-p r expected)) recipients))

(defun email-matches-p (email &key from to cc subject subject-contains
                                   body-contains)
  "Return T when EMAIL satisfies every supplied predicate (omitted keys
are ignored)."
  (and (or (null from)            (%addr-match-p (email-from email) from))
       (or (null to)              (%contains-recipient-p (email-to email) to))
       (or (null cc)              (%contains-recipient-p (email-cc email) cc))
       (or (null subject)         (string= subject (email-subject email)))
       (or (null subject-contains)
           (search subject-contains (email-subject email)))
       (or (null body-contains)
           (or (and (email-text-body email)
                    (search body-contains (email-text-body email)))
               (and (email-html-body email)
                    (search body-contains (email-html-body email)))))
       t))

(defun find-email (adapter &rest matchers)
  "Return the first email in ADAPTER's inbox matching MATCHERS, or NIL."
  (find-if (lambda (e) (apply #'email-matches-p e matchers))
           (test-inbox adapter)))

(defun assert-email-sent (adapter &rest matchers)
  "Signal an error unless ADAPTER's inbox contains an email matching the
given keyword predicates (see EMAIL-MATCHES-P). Returns the matched
email on success."
  (or (apply #'find-email adapter matchers)
      (error "No email matching ~s; inbox has ~d message(s)."
             matchers (length (test-inbox adapter)))))

(defun assert-no-emails-sent (adapter)
  (when (test-inbox adapter)
    (error "Expected empty inbox, found ~d message(s): ~s"
           (length (test-inbox adapter))
           (mapcar #'email-subject (test-inbox adapter)))))

(defun assert-email-count (adapter expected)
  (let ((actual (length (test-inbox adapter))))
    (unless (= actual expected)
      (error "Expected ~d email(s) in inbox, found ~d." expected actual))))
