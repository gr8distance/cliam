(in-package #:cliam)

;;; The email value flows through builder functions like clug's conn.
;;; Every updater returns a fresh email — no mutation in user code.

(defstruct email
  (from        nil)              ; (name . addr) | addr-string | nil
  (to          nil :type list)   ; list of the above
  (cc          nil :type list)
  (bcc         nil :type list)
  (reply-to    nil)
  (subject     ""  :type string)
  (text-body   nil)              ; string | nil
  (html-body   nil)              ; string | nil
  (headers     nil :type list)   ; plist of extra headers
  (attachments nil :type list)   ; not yet wired through render; v0.1.x
  (assigns     nil :type list))  ; plist for user data passed between plugs

(defun %addr (addr name)
  (if name (cons name addr) addr))

(defun copy-with (email &rest overrides)
  "Return a copy of EMAIL with slot overrides applied (plist of :slot value)."
  (let ((e (copy-email email)))
    (loop for (slot val) on overrides by #'cddr do
      (ecase slot
        (:from        (setf (email-from e) val))
        (:to          (setf (email-to e) val))
        (:cc          (setf (email-cc e) val))
        (:bcc         (setf (email-bcc e) val))
        (:reply-to    (setf (email-reply-to e) val))
        (:subject     (setf (email-subject e) val))
        (:text-body   (setf (email-text-body e) val))
        (:html-body   (setf (email-html-body e) val))
        (:headers     (setf (email-headers e) val))
        (:attachments (setf (email-attachments e) val))
        (:assigns     (setf (email-assigns e) val))))
    e))

;;; --- builders -------------------------------------------------------------

(defun from (email addr &optional name)
  (copy-with email :from (%addr addr name)))

(defun reply-to (email addr &optional name)
  (copy-with email :reply-to (%addr addr name)))

(defun to (email addr &optional name)
  "Append a recipient to To."
  (copy-with email :to (append (email-to email) (list (%addr addr name)))))

(defun cc (email addr &optional name)
  (copy-with email :cc (append (email-cc email) (list (%addr addr name)))))

(defun bcc (email addr &optional name)
  (copy-with email :bcc (append (email-bcc email) (list (%addr addr name)))))

(defun subject (email s)
  (check-type s string)
  (copy-with email :subject s))

(defun text-body (email s)
  (check-type s (or string null))
  (copy-with email :text-body s))

(defun html-body (email s)
  (check-type s (or string null))
  (copy-with email :html-body s))

(defun header (email name value)
  "Set/replace an extra header. NAME is a string; comparison case-insensitive."
  (check-type name string)
  (check-type value string)
  (copy-with email
             :headers (list* name value
                             (loop for (k v) on (email-headers email) by #'cddr
                                   unless (string-equal k name)
                                     append (list k v)))))

(defun attach (email pathname &key filename content-type)
  "Add an attachment (pathname-based). FILENAME defaults to the file's name."
  (let ((att (list :pathname pathname
                   :filename (or filename
                                 (and pathname (file-namestring pathname)))
                   :content-type content-type)))
    (copy-with email :attachments (append (email-attachments email) (list att)))))

(defun assign (email key value)
  (copy-with email
             :assigns (list* key value
                             (alexandria:remove-from-plist (email-assigns email) key))))

(defun get-assign (email key &optional default)
  (getf (email-assigns email) key default))

;;; --- RFC 5322 rendering ---------------------------------------------------

(defun %ascii-only-p (s)
  (and (stringp s) (every (lambda (c) (< (char-code c) 128)) s)))

(defun %encode-rfc2047 (s)
  "If S contains any non-ASCII characters, wrap it in an RFC 2047
encoded-word (UTF-8 base64). Otherwise return S unchanged. Used for
Subject and display names — without this, Japanese (and any non-ASCII)
headers arrive as mojibake or get rejected outright."
  (if (or (null s) (%ascii-only-p s))
      s
      (let* ((bytes (babel:string-to-octets s :encoding :utf-8))
             (b64   (cl-base64:usb8-array-to-base64-string bytes)))
        (format nil "=?UTF-8?B?~a?=" b64))))

(defun %format-addr (addr)
  "Render an address: a (name . addr) cons or a bare addr string.
Display names are RFC 2047 encoded when non-ASCII."
  (etypecase addr
    (string addr)
    (cons   (format nil "~a <~a>" (%encode-rfc2047 (car addr)) (cdr addr)))))

(defun %format-addr-list (addrs)
  (format nil "~{~a~^, ~}" (mapcar #'%format-addr addrs)))

(defun %now-rfc822 ()
  "Current time as an RFC 822 / RFC 5322 Date header value."
  (multiple-value-bind (sec min hour day mon year dow dst tz)
      (decode-universal-time (get-universal-time))
    (declare (ignore dst))
    (let ((day-name (aref #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun") dow))
          (mon-name (aref #("Jan" "Feb" "Mar" "Apr" "May" "Jun"
                            "Jul" "Aug" "Sep" "Oct" "Nov" "Dec") (1- mon))))
      ;; tz is hours west of UTC (CL convention); convert to ±HHMM east.
      (multiple-value-bind (offset-hh offset-mm)
          (floor (* -60 tz) 60)
        (format nil "~a, ~2,'0d ~a ~4,'0d ~2,'0d:~2,'0d:~2,'0d ~a~2,'0d~2,'0d"
                day-name day mon-name year hour min sec
                (if (minusp offset-hh) "-" "+")
                (abs offset-hh) offset-mm)))))

(defun %random-boundary ()
  (format nil "----=_Boundary_~16,'0X" (random (ash 1 64))))

(defun %generate-message-id (from-addr)
  "Build a Message-ID that's likely unique. Uses the domain of FROM-ADDR
when present, falls back to a placeholder for headerless tests."
  (let* ((at (and from-addr (position #\@ from-addr)))
         (domain (if at (subseq from-addr (1+ at)) "cliam.local")))
    (format nil "<~16,'0X.~16,'0X@~a>"
            (get-universal-time) (random (ash 1 64)) domain)))

(defun %split-foldable (s)
  "Split S at single-space boundaries, keeping the trailing space on each
chunk. \"a, b\" -> (\"a, \" \"b\"). Lets the folder break recipient lists
right after \", \" while preserving normal whitespace folding too."
  (loop with len = (length s)
        with start = 0
        for i from 0 below len
        when (char= (char s i) #\Space)
          collect (subseq s start (1+ i)) into out
          and do (setf start (1+ i))
        finally (return (if (< start len)
                            (append out (list (subseq s start)))
                            out))))

(defun %fold-header-line (name value &optional (limit 78))
  "Format \"Name: value\\n\" with RFC 5322 §2.2.3 line folding. Folds at
whitespace (preferring the implicit \", \" boundaries of recipient lists)
when the line would exceed LIMIT chars. Continuation lines start with a
single space."
  (let* ((prefix (format nil "~a: " name))
         (full   (concatenate 'string prefix value)))
    (if (<= (length full) limit)
        (concatenate 'string full (string #\Newline))
        (with-output-to-string (out)
          (write-string prefix out)
          (let ((col (length prefix)))
            (dolist (tok (%split-foldable value))
              (cond
                ((<= (+ col (length tok)) limit)
                 (write-string tok out)
                 (incf col (length tok)))
                ((= col (length prefix))
                 ;; nothing yet on this fresh line, must write even if too long
                 (write-string tok out)
                 (incf col (length tok)))
                (t
                 (write-char #\Newline out)
                 (write-char #\Space   out)
                 (let ((trimmed (string-left-trim " " tok)))
                   (write-string trimmed out)
                   (setf col (1+ (length trimmed))))))))
          (write-char #\Newline out)))))

(defun %write-headers (email out)
  (let ((from-addr (and (email-from email) (%addr-bare-string (email-from email)))))
    (write-string (%fold-header-line "From"     (%format-addr (or (email-from email) ""))) out)
    (when (email-to email)
      (write-string (%fold-header-line "To"       (%format-addr-list (email-to email))) out))
    (when (email-cc email)
      (write-string (%fold-header-line "Cc"       (%format-addr-list (email-cc email))) out))
    (when (email-reply-to email)
      (write-string (%fold-header-line "Reply-To" (%format-addr (email-reply-to email))) out))
    (write-string (%fold-header-line "Subject"   (%encode-rfc2047 (email-subject email))) out)
    (format out "Date: ~a~%" (%now-rfc822))
    (format out "Message-ID: ~a~%" (%generate-message-id from-addr))
    (format out "MIME-Version: 1.0~%"))
  (loop for (k v) on (email-headers email) by #'cddr
        do (write-string (%fold-header-line k v) out)))

(defun %addr-bare-string (addr)
  (etypecase addr
    (string addr)
    (cons   (cdr addr))))

(defun %read-file-octets (path)
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence bytes s)
      bytes)))

(defun %base64-wrap (s &optional (width 76))
  "Insert a CRLF every WIDTH chars per RFC 5322 line-length recommendation."
  (with-output-to-string (out)
    (loop with len = (length s)
          for start from 0 below len by width
          do (write-string (subseq s start (min (+ start width) len)) out)
             (write-char #\Newline out))))

(defun %attachment-content-type (att)
  (or (getf att :content-type)
      (let ((fname (getf att :filename)))
        (and fname (trivial-mimes:mime-lookup fname)))
      "application/octet-stream"))

(defun %write-attachment (att out boundary)
  (let* ((path  (getf att :pathname))
         (fname (or (getf att :filename) "attachment"))
         (ct    (%attachment-content-type att))
         (bytes (%read-file-octets path))
         (b64   (cl-base64:usb8-array-to-base64-string bytes)))
    (format out "--~a~%" boundary)
    (format out "Content-Type: ~a; name=\"~a\"~%" ct fname)
    (format out "Content-Disposition: attachment; filename=\"~a\"~%" fname)
    (format out "Content-Transfer-Encoding: base64~%~%")
    (write-string (%base64-wrap b64) out)))

(defun %write-body-part (email out)
  "Write the body section without the outer headers. Used both as the
top-level body (no attachments) and as the first sub-part of multipart/
mixed (with attachments)."
  (let ((text (email-text-body email))
        (html (email-html-body email)))
    (cond
      ((and text html)
       (let ((b (%random-boundary)))
         (format out "Content-Type: multipart/alternative; boundary=\"~a\"~%~%" b)
         (format out "--~a~%Content-Type: text/plain; charset=utf-8~%Content-Transfer-Encoding: 8bit~%~%~a~%" b text)
         (format out "--~a~%Content-Type: text/html; charset=utf-8~%Content-Transfer-Encoding: 8bit~%~%~a~%"  b html)
         (format out "--~a--~%" b)))
      (text
       (format out "Content-Type: text/plain; charset=utf-8~%Content-Transfer-Encoding: 8bit~%~%~a~%" text))
      (html
       (format out "Content-Type: text/html; charset=utf-8~%Content-Transfer-Encoding: 8bit~%~%~a~%" html))
      (t
       (format out "Content-Type: text/plain; charset=utf-8~%~%~%")))))

(defun render-rfc822 (email)
  "Serialise EMAIL into an RFC 5322 string suitable for SMTP or .eml output.
Supports text-only, html-only, multipart/alternative (both bodies), and
multipart/mixed with attachments (base64-encoded, Content-Type guessed
from filename when not supplied)."
  (with-output-to-string (out)
    (%write-headers email out)
    (cond
      ((email-attachments email)
       (let ((b (%random-boundary)))
         (format out "Content-Type: multipart/mixed; boundary=\"~a\"~%~%" b)
         (format out "--~a~%" b)
         (%write-body-part email out)
         (dolist (att (email-attachments email))
           (%write-attachment att out b))
         (format out "--~a--~%" b)))
      (t
       (%write-body-part email out)))))
