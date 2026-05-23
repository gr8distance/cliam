;;; CI test runner. Loads cliam/tests and exits non-zero if any test failed.

(ql:quickload :cliam/tests :silent t)

(let ((results (fiveam:run :cliam)))
  (fiveam:explain! results)
  (unless (every (lambda (r) (typep r 'fiveam::test-passed)) results)
    (uiop:quit 1)))
