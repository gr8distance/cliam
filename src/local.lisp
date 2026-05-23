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
