(in-package #:cliam)

;;; Local adapter: writes each delivery as an .eml file under a directory.
;;; Open the files in any mail client to inspect — useful for development
;;; without an SMTP server, and for verifying message-format changes.

(defclass local-adapter ()
  ((directory :initarg :directory :reader local-adapter-directory
              :documentation "Pathname of the destination directory."))
  (:documentation "Writes one .eml file per delivery."))

(defun make-local-adapter (directory)
  (make-instance 'local-adapter :directory (pathname directory)))

(defun %eml-filename ()
  (multiple-value-bind (sec min hour day mon year) (decode-universal-time (get-universal-time))
    (format nil "~4,'0d~2,'0d~2,'0d-~2,'0d~2,'0d~2,'0d-~6,'0x.eml"
            year mon day hour min sec (random #x1000000))))

(defmethod deliver-with ((a local-adapter) email)
  (let ((dir (local-adapter-directory a)))
    (ensure-directories-exist dir)
    (let ((path (merge-pathnames (%eml-filename) dir)))
      (with-open-file (s path :direction :output
                              :if-exists :supersede
                              :if-does-not-exist :create
                              :external-format :utf-8)
        (write-sequence (render-rfc822 email) s))
      (assign email :delivered-path path))))

;;; --- mailbox API ----------------------------------------------------------
;;;
;;; Read/inspect/delete .eml files written by a local-adapter. The
;;; mailbox is just the adapter's directory; entries are returned
;;; sorted by filename (which encodes the timestamp), oldest first.

(defun list-mailbox (adapter)
  "Return all .eml files currently in ADAPTER's directory, oldest first."
  (sort (directory (merge-pathnames "*.eml" (local-adapter-directory adapter)))
        #'string< :key #'namestring))

(defun read-mailbox-entry (path)
  "Return the contents of an .eml file as a string."
  (with-open-file (s path :external-format :utf-8)
    (with-output-to-string (out)
      (loop for line = (read-line s nil nil)
            while line do (format out "~a~%" line)))))

(defun delete-mailbox-entry (path)
  "Remove a single .eml file. Returns T if a file was deleted."
  (uiop:delete-file-if-exists path))

(defun clear-mailbox (adapter)
  "Delete every .eml file in ADAPTER's directory. Useful between dev
sessions or test runs."
  (let ((count 0))
    (dolist (p (list-mailbox adapter) count)
      (when (delete-mailbox-entry p) (incf count)))))

(defun pop-mailbox (adapter)
  "Remove and return the contents of the oldest .eml file, or NIL when
the mailbox is empty. Useful for processing queued dev mails."
  (let ((files (list-mailbox adapter)))
    (when files
      (let ((contents (read-mailbox-entry (first files))))
        (delete-mailbox-entry (first files))
        contents))))
