;;;; miscellaneous tests of package-related stuff

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; While most of SBCL is derived from the CMU CL system, the test
;;;; files (like this one) were written from scratch after the fork
;;;; from CMU CL.
;;;;
;;;; This software is in the public domain and is provided with
;;;; absolutely no warranty. See the COPYING and CREDITS files for
;;;; more information.

(make-package "FOO")
(defvar *foo* (find-package (coerce "FOO" 'base-string)))
(rename-package "FOO" (make-array 0 :element-type nil))
(assert (eq *foo* (find-package "")))
(assert (delete-package ""))

(make-package "BAR")
(defvar *baz* (rename-package "BAR" "BAZ"))
(assert (eq *baz* (find-package "BAZ")))
(assert (delete-package *baz*))

(handler-case
    (export :foo)
  (package-error (c) (princ c))
  (:no-error (&rest args) (error "(EXPORT :FOO) returned ~S" args)))

(make-package "FOO")
(assert (shadow #\a :foo))

(defpackage :PACKAGE-DESIGNATOR-1 (:use #.(find-package :cl)))

(defpackage :PACKAGE-DESIGNATOR-2
  (:import-from #.(find-package :cl) "+"))

(defpackage "EXAMPLE-INDIRECT"
  (:import-from "CL" "+"))

(defpackage "EXAMPLE-PACKAGE"
  (:shadow "CAR")
  (:shadowing-import-from "CL" "CAAR")
  (:use)
  (:import-from "CL" "CDR")
  (:import-from "EXAMPLE-INDIRECT" "+")
  (:export "CAR" "CDR" "EXAMPLE"))

(flet ((check-symbol (name expected-status expected-home-name)
         (multiple-value-bind (symbol status)
             (find-symbol name "EXAMPLE-PACKAGE")
           (let ((home (symbol-package symbol))
                 (expected-home (find-package expected-home-name)))
             (assert (eql home expected-home))
             (assert (eql status expected-status))))))
  (check-symbol "CAR" :external "EXAMPLE-PACKAGE")
  (check-symbol "CDR" :external "CL")
  (check-symbol "EXAMPLE" :external "EXAMPLE-PACKAGE")
  (check-symbol "CAAR" :internal "CL")
  (check-symbol "+" :internal "CL")
  (check-symbol "CDDR" nil "CL"))

(defpackage "TEST-ORIGINAL" (:nicknames "A-NICKNAME"))

(assert (raises-error? (defpackage "A-NICKNAME")))

(assert (eql (find-package "A-NICKNAME")
             (find-package "TEST-ORIGINAL")))

;;;; Utilities
(defun sym (package name)
 (let ((package (or (find-package package) package)))
   (multiple-value-bind (symbol status)
       (find-symbol name package)
     (assert status
             (package name symbol status)
             "No symbol with name ~A in ~S." name package symbol status)
   (values symbol status))))

(defmacro with-name-conflict-resolution ((symbol &key restarted)
                                         form &body body)
  "Resolves potential name conflict condition arising from FORM.

The conflict is resolved in favour of SYMBOL, a form which must
evaluate to a symbol.

If RESTARTED is a symbol, it is bound for the BODY forms and set to T
if a restart was invoked."
  (check-type restarted symbol "a binding name")
  (let ((%symbol (copy-symbol 'symbol)))
    `(let (,@(when restarted `((,restarted)))
           (,%symbol ,symbol))
       (handler-bind
           ((sb-ext:name-conflict
             (lambda (condition)
               ,@(when restarted `((setf ,restarted t)))
               (assert (member ,%symbol (sb-ext:name-conflict-symbols condition)))
               (invoke-restart 'sb-ext:resolve-conflict ,%symbol))))
         ,form)
       ,@body)))

(defmacro with-packages (specs &body forms)
  (let ((names (mapcar #'car specs)))
    `(unwind-protect
          (progn
            (delete-packages ',names)
            ,@(mapcar (lambda (spec)
                        `(defpackage ,@spec))
                      specs)
            ,@forms)
       (delete-packages ',names))))

(defun delete-packages (names)
  (dolist (p names)
    (ignore-errors (delete-package p))))


;;;; Tests
;;; USE-PACKAGE
(with-test (:name :use-package.1)
  (with-packages (("FOO" (:export "SYM"))
                  ("BAR" (:export "SYM"))
                  ("BAZ" (:use)))
    (with-name-conflict-resolution ((sym "BAR" "SYM") :restarted restartedp)
        (use-package '("FOO" "BAR") "BAZ")
      (is restartedp)
      (is (eq (sym "BAR" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :use-package.2)
  (with-packages (("FOO" (:export "SYM"))
                  ("BAZ" (:use) (:intern "SYM")))
    (with-name-conflict-resolution ((sym "FOO" "SYM") :restarted restartedp)
        (use-package "FOO" "BAZ")
      (is restartedp)
      (is (eq (sym "FOO" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :use-package.2a)
  (with-packages (("FOO" (:export "SYM"))
                  ("BAZ" (:use) (:intern "SYM")))
    (with-name-conflict-resolution ((sym "BAZ" "SYM") :restarted restartedp)
        (use-package "FOO" "BAZ")
      (is restartedp)
      (is (equal (list (sym "BAZ" "SYM") :internal)
                 (multiple-value-list (sym "BAZ" "SYM")))))))

(with-test (:name :use-package-conflict-set :fails-on :sbcl)
  (with-packages (("FOO" (:export "SYM"))
                  ("QUX" (:export "SYM"))
                  ("BAR" (:intern "SYM"))
                  ("BAZ" (:use) (:import-from "BAR" "SYM")))
    (let ((conflict-set))
      (block nil
        (handler-bind
            ((sb-ext:name-conflict
              (lambda (condition)
                (setf conflict-set (copy-list
                                    (sb-ext:name-conflict-symbols condition)))
                (return))))
          (use-package '("FOO" "QUX") "BAZ")))
      (setf conflict-set
            (sort conflict-set #'string<
                  :key (lambda (symbol)
                         (package-name (symbol-package symbol)))))
      (is (equal (list (sym "BAR" "SYM") (sym "FOO" "SYM") (sym "QUX" "SYM"))
                 conflict-set)))))

;;; EXPORT
(with-test (:name :export.1)
  (with-packages (("FOO" (:intern "SYM"))
                  ("BAR" (:export "SYM"))
                  ("BAZ" (:use "FOO" "BAR")))
    (with-name-conflict-resolution ((sym "FOO" "SYM") :restarted restartedp)
        (export (sym "FOO" "SYM") "FOO")
      (is restartedp)
      (is (eq (sym "FOO" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :export.1a)
  (with-packages (("FOO" (:intern "SYM"))
                  ("BAR" (:export "SYM"))
                  ("BAZ" (:use "FOO" "BAR")))
    (with-name-conflict-resolution ((sym "BAR" "SYM") :restarted restartedp)
        (export (sym "FOO" "SYM") "FOO")
      (is restartedp)
      (is (eq (sym "BAR" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :export.ensure-exported)
  (with-packages (("FOO" (:intern "SYM"))
                  ("BAR" (:export "SYM"))
                  ("BAZ" (:use "FOO" "BAR") (:IMPORT-FROM "BAR" "SYM")))
    (with-name-conflict-resolution ((sym "FOO" "SYM") :restarted restartedp)
        (export (sym "FOO" "SYM") "FOO")
      (is restartedp)
      (is (equal (list (sym "FOO" "SYM") :external)
                 (multiple-value-list (sym "FOO" "SYM"))))
      (is (eq (sym "FOO" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :export.3.intern)
  (with-packages (("FOO" (:intern "SYM"))
                  ("BAZ" (:use "FOO") (:intern "SYM")))
    (with-name-conflict-resolution ((sym "FOO" "SYM") :restarted restartedp)
        (export (sym "FOO" "SYM") "FOO")
      (is restartedp)
      (is (eq (sym "FOO" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :export.3a.intern)
  (with-packages (("FOO" (:intern "SYM"))
                  ("BAZ" (:use "FOO") (:intern "SYM")))
    (with-name-conflict-resolution ((sym "BAZ" "SYM") :restarted restartedp)
        (export (sym "FOO" "SYM") "FOO")
      (is restartedp)
      (is (equal (list (sym "BAZ" "SYM") :internal)
                 (multiple-value-list (sym "BAZ" "SYM")))))))

;;; IMPORT
(with-test (:name :import-nil.1)
  (with-packages (("FOO" (:use) (:intern "NIL"))
                  ("BAZ" (:use) (:intern "NIL")))
    (with-name-conflict-resolution ((sym "FOO" "NIL") :restarted restartedp)
        (import (list (sym "FOO" "NIL")) "BAZ")
      (is restartedp)
      (is (eq (sym "FOO" "NIL")
              (sym "BAZ" "NIL"))))))

(with-test (:name :import-nil.2)
  (with-packages (("BAZ" (:use) (:intern "NIL")))
    (with-name-conflict-resolution ('CL:NIL :restarted restartedp)
        (import '(CL:NIL) "BAZ")
      (is restartedp)
      (is (eq 'CL:NIL
              (sym "BAZ" "NIL"))))))

(with-test (:name :import-single-conflict :fails-on :sbcl)
  (with-packages (("FOO" (:export "NIL"))
                  ("BAR" (:export "NIL"))
                  ("BAZ" (:use)))
    (let ((conflict-sets '()))
      (handler-bind
          ((sb-ext:name-conflict
            (lambda (condition)
              (push (copy-list (sb-ext:name-conflict-symbols condition))
                    conflict-sets)
              (invoke-restart 'sb-ext:resolve-conflict 'CL:NIL))))
        (import (list 'CL:NIL (sym "FOO" "NIL") (sym "BAR" "NIL")) "BAZ"))
      (is (eql 1 (length conflict-sets)))
      (is (eql 3 (length (first conflict-sets)))))))

;;; Make sure that resolving a name-conflict in IMPORT doesn't leave
;;; multiple symbols of the same name in the package (this particular
;;; scenario found in 1.0.38.9, but clearly a longstanding issue).
(with-test (:name :import-conflict-resolution)
  (with-packages (("FOO" (:export "NIL"))
                  ("BAR" (:use)))
    (with-name-conflict-resolution ((sym "FOO" "NIL"))
      (import (list 'CL:NIL (sym "FOO" "NIL")) "BAR"))
    (do-symbols (sym "BAR")
      (assert (eq sym (sym "FOO" "NIL"))))))

;;; UNINTERN
(with-test (:name :unintern.1)
  (with-packages (("FOO" (:export "SYM"))
                  ("BAR" (:export "SYM"))
                  ("BAZ" (:use "FOO" "BAR") (:shadow "SYM")))
    (with-name-conflict-resolution ((sym "FOO" "SYM") :restarted restartedp)
        (unintern (sym "BAZ" "SYM") "BAZ")
      (is restartedp)
      (is (eq (sym "FOO" "SYM")
              (sym "BAZ" "SYM"))))))

(with-test (:name :unintern.2)
  (with-packages (("FOO" (:intern "SYM")))
    (unintern :sym "FOO")
    (assert (find-symbol "SYM" "FOO"))))

;;; WITH-PACKAGE-ITERATOR error signalling had problems
(with-test (:name :with-package-iterator.error)
  (assert (eq :good
              (handler-case
                  (progn
                    (eval '(with-package-iterator (sym :cl-user :foo)
                            (sym)))
                    :bad)
                ((and simple-condition program-error) (c)
                  (assert (equal (list :foo) (simple-condition-format-arguments c)))
                  :good)))))

;;; MAKE-PACKAGE error in another thread blocking FIND-PACKAGE & FIND-SYMBOL
(with-test (:name :bug-511072 :skipped-on '(not :sb-thread))
  (let* ((p (make-package :bug-511072))
         (sem1 (sb-thread:make-semaphore))
         (sem2 (sb-thread:make-semaphore))
         (t2 (make-join-thread (lambda ()
                                 (handler-bind ((error (lambda (c)
                                                         (sb-thread:signal-semaphore sem1)
                                                         (sb-thread:wait-on-semaphore sem2)
                                                         (abort c))))
                                   (make-package :bug-511072))))))
    (sb-thread:wait-on-semaphore sem1)
    (with-timeout 10
      (assert (eq 'cons (read-from-string "CL:CONS"))))
    (sb-thread:signal-semaphore sem2)))

(with-test (:name :quick-name-conflict-resolution-import)
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-IMPORT.1")
                 p2 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-IMPORT.2"))
           (intern "FOO" p1)
           (handler-bind ((name-conflict (lambda (c)
                                           (invoke-restart 'sb-impl::dont-import-it))))
             (import (intern "FOO" p2) p1))
           (assert (not (eq (intern "FOO" p1) (intern "FOO" p2))))
           (handler-bind ((name-conflict (lambda (c)
                                           (invoke-restart 'sb-impl::shadowing-import-it))))
             (import (intern "FOO" p2) p1))
           (assert (eq (intern "FOO" p1) (intern "FOO" p2))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name :quick-name-conflict-resolution-export.1)
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-EXPORT.1a")
                 p2 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-EXPORT.2a"))
           (intern "FOO" p1)
           (use-package p2 p1)
           (handler-bind ((name-conflict (lambda (c)
                                           (invoke-restart 'sb-impl::keep-old))))
             (export (intern "FOO" p2) p2))
           (assert (not (eq (intern "FOO" p1) (intern "FOO" p2)))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name :quick-name-conflict-resolution-export.2)
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-EXPORT.1b")
                 p2 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-EXPORT.2b"))
           (intern "FOO" p1)
           (use-package p2 p1)
           (handler-bind ((name-conflict (lambda (c)
                                           (invoke-restart 'sb-impl::take-new))))
             (export (intern "FOO" p2) p2))
           (assert (eq (intern "FOO" p1) (intern "FOO" p2))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name :quick-name-conflict-resolution-use-package.1)
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-USE-PACKAGE.1a")
                 p2 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-USE-PACKAGE.2a"))
           (intern "FOO" p1)
           (intern "BAR" p1)
           (export (intern "FOO" p2) p2)
           (export (intern "BAR" p2) p2)
           (handler-bind ((name-conflict (lambda (c)
                                           (invoke-restart 'sb-impl::keep-old))))
             (use-package p2 p1))
           (assert (not (eq (intern "FOO" p1) (intern "FOO" p2))))
           (assert (not (eq (intern "BAR" p1) (intern "BAR" p2)))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name :quick-name-conflict-resolution-use-package.2)
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-USE-PACKAGE.1b")
                 p2 (make-package "QUICK-NAME-CONFLICT-RESOLUTION-USE-PACKAGE.2b"))
           (intern "FOO" p1)
           (intern "BAR" p1)
           (export (intern "FOO" p2) p2)
           (export (intern "BAR" p2) p2)
           (handler-bind ((name-conflict (lambda (c)
                                           (invoke-restart 'sb-impl::take-new))))
             (use-package p2 p1))
           (assert (eq (intern "FOO" p1) (intern "FOO" p2)))
           (assert (eq (intern "BAR" p1) (intern "BAR" p2))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name (:package-at-variance-restarts :shadow))
  (let ((p nil)
        (*on-package-variance* '(:error t)))
    (unwind-protect
         (progn
           (setf p (eval `(defpackage :package-at-variance-restarts.1
                            (:use :cl)
                            (:shadow "CONS"))))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::keep-them))))
             (eval `(defpackage :package-at-variance-restarts.1
                      (:use :cl))))
           (assert (not (eq 'cl:cons (intern "CONS" p))))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::drop-them))))
             (eval `(defpackage :package-at-variance-restarts.1
                      (:use :cl))))
           (assert (eq 'cl:cons (intern "CONS" p))))
      (when p (delete-package p)))))

(with-test (:name (:package-at-variance-restarts :use))
  (let ((p nil)
        (*on-package-variance* '(:error t)))
    (unwind-protect
         (progn
           (setf p (eval `(defpackage :package-at-variance-restarts.2
                            (:use :cl))))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::keep-them))))
             (eval `(defpackage :package-at-variance-restarts.2
                      (:use))))
           (assert (eq 'cl:cons (intern "CONS" p)))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::drop-them))))
             (eval `(defpackage :package-at-variance-restarts.2
                      (:use))))
           (assert (not (eq 'cl:cons (intern "CONS" p)))))
      (when p (delete-package p)))))

(with-test (:name (:package-at-variance-restarts :export))
  (let ((p nil)
        (*on-package-variance* '(:error t)))
    (unwind-protect
         (progn
           (setf p (eval `(defpackage :package-at-variance-restarts.4
                            (:export "FOO"))))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::keep-them))))
             (eval `(defpackage :package-at-variance-restarts.4)))
           (assert (eq :external (nth-value 1 (find-symbol "FOO" p))))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::drop-them))))
             (eval `(defpackage :package-at-variance-restarts.4)))
           (assert (eq :internal (nth-value 1 (find-symbol "FOO" p)))))
      (when p (delete-package p)))))

(with-test (:name (:package-at-variance-restarts :implement))
  (let ((p nil)
        (*on-package-variance* '(:error t)))
    (unwind-protect
         (progn
           (setf p (eval `(defpackage :package-at-variance-restarts.5
                            (:implement :sb-int))))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::keep-them))))
             (eval `(defpackage :package-at-variance-restarts.5)))
           (assert (member p (package-implemented-by-list :sb-int)))
           (handler-bind ((sb-kernel::package-at-variance-error
                            (lambda (c)
                              (invoke-restart 'sb-impl::drop-them))))
             (eval `(defpackage :package-at-variance-restarts.5)))
           (assert (not (member p (package-implemented-by-list :sb-int)))))
      (when p (delete-package p)))))

(with-test (:name (:delete-package :implementation-package))
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "DELETE-PACKAGE/IMPLEMENTATION-PACKAGE.1")
                 p2 (make-package "DELETE-PACKAGE/IMPLEMENTATION-PACKAGE.2"))
           (add-implementation-package p2 p1)
           (assert (= 1 (length (package-implemented-by-list p1))))
           (delete-package p2)
           (assert (= 0 (length (package-implemented-by-list p1)))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name (:delete-package :implementated-package))
  (let (p1 p2)
    (unwind-protect
         (progn
           (setf p1 (make-package "DELETE-PACKAGE/IMPLEMENTED-PACKAGE.1")
                 p2 (make-package "DELETE-PACKAGE/IMPLEMENTED-PACKAGE.2"))
           (add-implementation-package p2 p1)
           (assert (= 1 (length (package-implements-list p2))))
           (delete-package p1)
           (assert (= 0 (length (package-implements-list p2)))))
      (when p1 (delete-package p1))
      (when p2 (delete-package p2)))))

(with-test (:name :package-local-nicknames)
  ;; Clear slate
  (without-package-locks
    (when (find-package :package-local-nicknames-test-1)
      (delete-package :package-local-nicknames-test-1))
    (when (find-package :package-local-nicknames-test-2)
      (delete-package :package-local-nicknames-test-2)))
  (eval `(defpackage :package-local-nicknames-test-1
           (:local-nicknames (:l :cl) (:sb :sb-ext))))
  (eval `(defpackage :package-local-nicknames-test-2
           (:export "CONS")))
  ;; Introspection
  (let ((alist (package-local-nicknames :package-local-nicknames-test-1)))
    (assert (equal (cons "L" (find-package "CL")) (assoc "L" alist :test 'string=)))
    (assert (equal (cons "SB" (find-package "SB-EXT")) (assoc "SB" alist :test 'string=)))
    (assert (eql 2 (length alist))))
  ;; Usage
  (let ((*package* (find-package :package-local-nicknames-test-1)))
    (let ((cons0 (read-from-string "L:CONS"))
          (exit0 (read-from-string "SB:EXIT"))
          (cons1 (find-symbol "CONS" :l))
          (exit1 (find-symbol "EXIT" :sb))
          (cl (find-package :l))
          (sb (find-package :sb)))
      (assert (eq 'cons cons0))
      (assert (eq 'cons cons1))
      (assert (equal "L:CONS" (prin1-to-string cons0)))
      (assert (eq 'sb-ext:exit exit0))
      (assert (eq 'sb-ext:exit exit1))
      (assert (equal "SB:EXIT" (prin1-to-string exit0)))
      (assert (eq cl (find-package :common-lisp)))
      (assert (eq sb (find-package :sb-ext)))))
  ;; Can't add same name twice for different global names.
  (assert (eq :oopsie
              (handler-case
                  (add-package-local-nickname :l :package-local-nicknames-test-2
                                              :package-local-nicknames-test-1)
                (error ()
                  :oopsie))))
  ;; But same name twice is OK.
  (add-package-local-nickname :l :cl :package-local-nicknames-test-1)
  ;; Removal.
  (assert (remove-package-local-nickname :l :package-local-nicknames-test-1))
  (let ((*package* (find-package :package-local-nicknames-test-1)))
    (let ((exit0 (read-from-string "SB:EXIT"))
          (exit1 (find-symbol "EXIT" :sb))
          (sb (find-package :sb)))
      (assert (eq 'sb-ext:exit exit0))
      (assert (eq 'sb-ext:exit exit1))
      (assert (equal "SB:EXIT" (prin1-to-string exit0)))
      (assert (eq sb (find-package :sb-ext)))
      (assert (not (find-package :l)))))
  ;; Adding back as another package.
  (assert (eq (find-package :package-local-nicknames-test-1)
              (add-package-local-nickname :l :package-local-nicknames-test-2
                                          :package-local-nicknames-test-1)))
  (let ((*package* (find-package :package-local-nicknames-test-1)))
    (let ((cons0 (read-from-string "L:CONS"))
          (exit0 (read-from-string "SB:EXIT"))
          (cons1 (find-symbol "CONS" :l))
          (exit1 (find-symbol "EXIT" :sb))
          (cl (find-package :l))
          (sb (find-package :sb)))
      (assert (eq cons0 cons1))
      (assert (not (eq 'cons cons0)))
      (assert (eq (find-symbol "CONS" :package-local-nicknames-test-2)
                  cons0))
      (assert (equal "L:CONS" (prin1-to-string cons0)))
      (assert (eq 'sb-ext:exit exit0))
      (assert (eq 'sb-ext:exit exit1))
      (assert (equal "SB:EXIT" (prin1-to-string exit0)))
      (assert (eq cl (find-package :package-local-nicknames-test-2)))
      (assert (eq sb (find-package :sb-ext)))))
  ;; Interaction with package locks.
  (lock-package :package-local-nicknames-test-1)
  (assert (eq :package-oopsie
              (handler-case
                  (add-package-local-nickname :c :sb-c :package-local-nicknames-test-1)
                (package-lock-violation ()
                  :package-oopsie))))
  (assert (eq :package-oopsie
              (handler-case
                  (remove-package-local-nickname :l :package-local-nicknames-test-1)
                (package-lock-violation ()
                  :package-oopsie))))
  (unlock-package :package-local-nicknames-test-1)
  (add-package-local-nickname :c :sb-c :package-local-nicknames-test-1)
  (remove-package-local-nickname :l :package-local-nicknames-test-1))

(defmacro with-tmp-packages (bindings &body body)
  `(let ,(mapcar #'car bindings)
     (unwind-protect
          (progn
            (setf ,@(apply #'append bindings))
            ,@body)
       ,@(mapcar (lambda (p)
                   `(when ,p (delete-package ,p)))
                 (mapcar #'car bindings)))))

(with-test (:name (:delete-package :locally-nicknames-others))
  (with-tmp-packages ((p1 (make-package "LOCALLY-NICKNAMES-OTHERS"))
                      (p2 (make-package "LOCALLY-NICKNAMED-BY-OTHERS")))
    (add-package-local-nickname :foo p2 p1)
    (assert (equal (list p1) (package-locally-nicknamed-by-list p2)))
    (delete-package p1)
    (assert (not (package-locally-nicknamed-by-list p2)))))

(with-test (:name (:delete-package :locally-nicknamed-by-others))
  (with-tmp-packages ((p1 (make-package "LOCALLY-NICKNAMES-OTHERS"))
                      (p2 (make-package "LOCALLY-NICKNAMED-BY-OTHERS")))
    (add-package-local-nickname :foo p2 p1)
    (assert (package-local-nicknames p1))
    (delete-package p2)
    (assert (not (package-local-nicknames p1)))))

(with-test (:name :own-name-as-local-nickname)
  (with-tmp-packages ((p1 (make-package "OWN-NAME-AS-NICKNAME1"))
                      (p2 (make-package "OWN-NAME-AS-NICKNAME2")))
    (assert (eq :oops
                (handler-case
                    (add-package-local-nickname :own-name-as-nickname1 p2 p1)
                  (error ()
                    :oops))))
    (handler-bind ((error #'continue))
      (add-package-local-nickname :own-name-as-nickname1 p2 p1))
    (assert (eq (intern "FOO" p2)
                (let ((*package* p1))
                  (intern "FOO" :own-name-as-nickname1))))))

(with-test (:name :own-nickname-as-local-nickname)
  (with-tmp-packages ((p1 (make-package "OWN-NICKNAME-AS-NICKNAME1"
                                        :nicknames '("OWN-NICKNAME")))
                      (p2 (make-package "OWN-NICKNAME-AS-NICKNAME2")))
    (assert (eq :oops
                (handler-case
                    (add-package-local-nickname :own-nickname p2 p1)
                  (error ()
                    :oops))))
    (handler-bind ((error #'continue))
      (add-package-local-nickname :own-nickname p2 p1))
    (assert (eq (intern "FOO" p2)
                (let ((*package* p1))
                  (intern "FOO" :own-nickname))))))

(with-test (:name :delete-package-restart)
  (let* (ok
         (result
           (handler-bind
               ((sb-kernel:simple-package-error
                  (lambda (c)
                    (setf ok t)
                    (continue c))))
             (delete-package (gensym)))))
    (assert ok)
    (assert (not result))))
