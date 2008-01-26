;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Indent-tabs-mode: NIL -*-
;;;
;;; address.lisp --- IP address classes.
;;;
;;; Copyright (C) 2006-2007, Stelian Ionescu  <sionescu@common-lisp.net>
;;;
;;; This code is free software; you can redistribute it and/or
;;; modify it under the terms of the version 2.1 of
;;; the GNU Lesser General Public License as published by
;;; the Free Software Foundation, as clarified by the
;;; preamble found here:
;;;     http://opensource.franz.com/preamble.html
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU Lesser General
;;; Public License along with this library; if not, write to the
;;; Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
;;; Boston, MA 02110-1301, USA

(in-package :net.sockets)

;;;; Class Definitions

(defclass address ()
  ((name :initarg :name :reader address-name :type vector))
  (:documentation "Base class for all socket address classes."))

(defclass inet-address (address) ()
  (:documentation "Base class for IPv4 and IPv6 addresses."))

(defclass ipv4-address (inet-address) ()
  (:documentation "IPv4 address.  Its low-level representation
can be accessed as vector of type IPV4-ARRAY through the
ADDRESS-NAME reader."))

(defclass ipv6-address (inet-address) ()
  (:documentation "IPv6 address.  Its low-level representation
can be accessed as vector of type IPV6-ARRAY through the
ADDRESS-NAME reader."))

(defclass local-address (address)
  ((abstract :initform nil :initarg :abstract
             :reader abstract-address-p :type boolean))
  (:documentation "UNIX socket address."))

(defmethod make-load-form ((address inet-address) &optional env)
  (declare (ignore env))
  `(make-instance ,(class-of address)
                  :name ,(address-name address)))

(defmethod make-load-form ((address local-address) &optional env)
  (declare (ignore env))
  `(make-instance ,(class-of address)
                  :name ,(address-name address)
                  :abstrace ,(abstract-address-p address)))

;;;; Conversion functions

(defun integer-to-dotted (integer)
  "Convert a 32-bit unsigned integer to a dotted string."
  (check-type integer ub32 "an '(unsigned-byte 32)")
  (format nil "~A.~A.~A.~A"
          (ldb (byte 8 24) integer)
          (ldb (byte 8 16) integer)
          (ldb (byte 8 8) integer)
          (ldb (byte 8 0) integer)))

(defun dotted-to-vector (address)
  "Convert a dotted IPv4 address to a (simple-array (unsigned-byte 8) 4)."
  (check-type address string "a string")
  (let ((addr (make-array 4 :element-type 'ub8 :initial-element 0))
        (split (split-sequence #\. address :count 5)))
    (flet ((set-array-value (index str)
             (setf (aref addr index)
                   (or (parse-number-or-nil str :ub8)
                       (error 'parse-error)))))
      (let ((len (length split)))
        (unless (<= 1 len 4)
          (error 'parse-error))
        (set-array-value 3 (nth (1- len) split))
        (loop :for n :in split
              :for index :below (1- len)
              :do (set-array-value index n))))
    (values addr)))

(defun dotted-to-integer (address)
  "Convert a dotted IPv4 address to a 32-bit unsigned integer."
  (vector-to-integer (dotted-to-vector address)))

(defun vector-to-dotted (vector)
  "Convert an 4-element vector to a dotted string."
  (coercef vector 'ipv4-array)
  (let ((*print-pretty* nil))
    (with-output-to-string (s)
      (princ (aref vector 0) s) (princ #\. s)
      (princ (aref vector 1) s) (princ #\. s)
      (princ (aref vector 2) s) (princ #\. s)
      (princ (aref vector 3) s))))

;;; TODO: add tests against inet_pton().  Optimize if necessary.
;;; <http://java.sun.com/javase/6/docs/api/java/net/Inet6Address.html#format>
(defun colon-separated-to-vector (string)
  "Convert a colon-separated IPv6 address to a (simple-array ub16 8)."
  (check-type string string "a string")
  (when (< (length string) 2)
    (error 'parse-error))
  (flet ((handle-trailing-and-leading-colons (string)
           (let ((start 0)
                 (end (length string))
                 (start-i 0)
                 (trailing-colon-p nil)
                 (tokens-from-leading-or-trailing-zeros 0))
             (when (char= #\: (char string 0))
               (incf start)
               (unless (char= #\: (char string 1))
                 (setq start-i 1)
                 (setq tokens-from-leading-or-trailing-zeros 1)))
             (when (char= #\: (char string (- end 1)))
               (setq trailing-colon-p t)
               (unless (char= #\: (char string (- end 2)))
                 (incf tokens-from-leading-or-trailing-zeros))
               (decf end))
             (values start end start-i trailing-colon-p
                     tokens-from-leading-or-trailing-zeros)))
         (emptyp (string)
           (= 0 (length string)))
         ;; we need to use this instead of dotted-to-vector because
         ;; abbreviated IPv4 addresses are invalid in this context.
         (ipv4-string-to-ub16-list (string)
           (let ((tokens (split-sequence #\. string)))
             (when (= (length tokens) 4)
               (let ((ipv4 (map 'vector
                                (lambda (string)
                                  (let ((x (ignore-errors
                                             (parse-integer string))))
                                    (if (or (null x) (not (<= 0 x #xff)))
                                        (error 'parse-error)
                                        x)))
                                tokens)))
                 (list (dpb (aref ipv4 0) (byte 8 8) (aref ipv4 1))
                       (dpb (aref ipv4 2) (byte 8 8) (aref ipv4 3)))))))
         (parse-hex-ub16 (string)
           (let ((x (ignore-errors (parse-integer string :radix 16))))
             (if (or (null x) (not (<= 0 x #xffff)))
                 (error 'parse-error)
                 x))))
    (multiple-value-bind (start end start-i trailing-colon-p extra-tokens)
        (handle-trailing-and-leading-colons string)
      (let* ((vector (make-array 8 :element-type 'ub16 :initial-element 0))
             (tokens (split-sequence #\: string :start start :end end))
             (empty-tokens (count-if #'emptyp tokens))
             (token-count (+ (length tokens) extra-tokens)))
        (unless trailing-colon-p
          (let ((ipv4 (ipv4-string-to-ub16-list (lastcar tokens))))
            (when ipv4
              (incf token-count)
              (setq tokens (nconc (butlast tokens) ipv4)))))
        (when (or (> token-count 8) (> empty-tokens 1)
                  (and (zerop empty-tokens) (/= token-count 8)))
          (error 'parse-error))
        (loop for i from start-i and token in tokens do
              (cond
                ((integerp token) (setf (aref vector i) token))
                ((emptyp token) (incf i (- 8 token-count)))
                (t (setf (aref vector i) (parse-hex-ub16 token)))))
        vector))))

(defun ipv4-on-ipv6-mapped-vector-p (vector)
  (and (dotimes (i 5 t)
         (when (plusp (aref vector i))
           (return nil)))
       (= (aref vector 5) #xffff)))

(defun princ-ipv4-on-ipv6-mapped-address (vector s)
  (princ "::ffff:" s)
  (let ((*print-base* 10) (*print-pretty* nil))
    (princ (ldb (byte 8 8) (aref vector 6)) s) (princ #\. s)
    (princ (ldb (byte 8 0) (aref vector 6)) s) (princ #\. s)
    (princ (ldb (byte 8 8) (aref vector 7)) s) (princ #\. s)
    (princ (ldb (byte 8 0) (aref vector 7)) s)))

(defun vector-to-colon-separated (vector &optional (case :downcase))
  "Convert an 8-element vector to a colon-separated IPv6
address. CASE may be :DOWNCASE or :UPCASE."
  (coercef vector 'ipv6-array)
  (check-type case (member :upcase :downcase) "either :UPCASE or :DOWNCASE")
  (let ((s (make-string-output-stream)))
    (flet ((find-zeros ()
             (let ((start (position 0 vector :start 1 :end 7)))
               (when start
                 (values start
                         (position-if #'plusp vector :start start :end 7)))))
           (princ-subvec (start end)
             (loop :for i :from start :below end
                   :do (princ (aref vector i) s) (princ #\: s))))
      (cond
        ((ipv4-on-ipv6-mapped-vector-p vector)
         (princ-ipv4-on-ipv6-mapped-address vector s))
        (t
         (let ((*print-base* 16) (*print-pretty* nil))
           (when (plusp (aref vector 0)) (princ (aref vector 0) s))
           (princ #\: s)
           (multiple-value-bind (start end) (find-zeros)
             (cond (start (princ-subvec 1 start)
                          (princ #\: s)
                          (when end (princ-subvec end 7)))
                   (t (princ-subvec 1 7))))
           (when (plusp (aref vector 7)) (princ (aref vector 7) s))))))
    (let ((str (get-output-stream-string s)))
      (ecase case
        (:downcase (nstring-downcase str))
        (:upcase (nstring-upcase str))))))

(defmacro ignore-parse-errors (&body body)
  ;; return first value only
  `(values (ignore-some-conditions (parse-error) ,@body)))

(defun string-address-to-vector (address)
  "Convert a string address (dotted or colon-separated) to a vector address.
If the string is not a valid address, return NIL."
  (or (ignore-parse-errors (dotted-to-vector address))
      (ignore-parse-errors (colon-separated-to-vector address))))

(defun address-to-vector (address)
  "Convert any representation of an internet address to a vector.
Allowed inputs are: unsigned 32-bit integers, strings, vectors
and INET-ADDRESS objects.  If the address is valid, two values
are returned: the vector and the address type (:IPV4 or IPV6),
otherwise NIL is returned."
  (let (vector addr-type)
    (typecase address
      (number (and (ignore-parse-errors
                     (setf vector (integer-to-vector address)))
                   (setf addr-type :ipv4)))
      (string (cond
                ((ignore-parse-errors (setf vector (dotted-to-vector address)))
                 (setf addr-type :ipv4))
                ((ignore-parse-errors
                   (setf vector (colon-separated-to-vector address)))
                 (setf addr-type :ipv6))))
      ((vector * 4) (and (ignore-parse-errors
                           (setf vector (coerce address 'ipv4-array)))
                         (setf addr-type :ipv4)))
      ((vector * 8) (and (ignore-parse-errors
                           (setf vector (coerce address 'ipv6-array)))
                         (setf addr-type :ipv6)))
      (ipv4-address (setf vector (address-name address)
                          addr-type :ipv4))
      (ipv6-address (setf vector (address-name address)
                          addr-type :ipv6)))
    (when vector
      (values vector addr-type))))

(defun ensure-address (address &optional (family :internet))
  "If FAMILY is :LOCAL, a LOCAL-ADDRESS is instantiated with
ADDRESS as its NAME slot. If FAMILY is :INTERNET, an appropriate
subtype of INET-ADDRESS is instantiated after guessing the
address type through ADDRESS-TO-VECTOR. If the address is not
valid, a CL:PARSE-ERROR is signalled.

When ADDRESS is already an instance of the ADDRESS class, a check
is made to see if it matches the FAMILY argument and it is
returned unmodified."
  (ecase family
    (:internet
     (typecase address
       (address (check-type address inet-address "an INET address")
                address)
       (t (make-address (or (address-to-vector address)
                            (error 'parse-error))))))
    (:local
     (etypecase address
       (string (make-instance 'local-address :name address))
       (address (check-type address local-address "a local address")
                address)))))

;;;; Print Methods

(defgeneric address-to-string (address)
  (:documentation "Returns a textual presentation of ADDRESS."))

(defmethod address-to-string ((address ipv4-address))
  (vector-to-dotted (address-name address)))

(defmethod address-to-string ((address ipv6-address))
  (vector-to-colon-separated (address-name address)))

(defmethod address-to-string ((address local-address))
  (if (abstract-address-p address)
      "<unknown socket>"
      (address-name address)))

(defmethod print-object ((address ipv4-address) stream)
  (print-unreadable-object (address stream :type nil :identity nil)
    (format stream "IPv4 address: ~A" (address-to-string address))))

(defmethod print-object ((address ipv6-address) stream)
  (print-unreadable-object (address stream :type nil :identity nil)
    (format stream "IPv6 address: ~A" (address-to-string address))))

(defmethod print-object ((address local-address) stream)
  (print-unreadable-object (address stream :type nil :identity nil)
    (format stream "Unix socket address: ~A. Abstract: ~:[no~;yes~]"
            (address-to-string address) (abstract-address-p address))))

;;;; Equality Methods

(defun vector-equal (v1 v2)
  (and (= (length v1) (length v2))
       (every #'eql v1 v2)))

(defgeneric address= (addr1 addr2)
  (:documentation "Returns T if both arguments are the same socket address."))

(defmethod address= ((addr1 inet-address) (addr2 inet-address))
  (vector-equal (address-name addr1) (address-name addr2)))

(defmethod address= ((addr1 local-address) (addr2 local-address))
  (equal (address-name addr1) (address-name addr2)))

(defun address-equal-p (addr1 addr2 &optional (family :internet))
  "Returns T if both arguments are designators for the same socket address."
  (address= (ensure-address addr1 family)
            (ensure-address addr2 family)))

;;;; Copy Methods

(defgeneric copy-address (address)
  (:documentation
   "Returns a copy of ADDRESS which is ADDRESS= to the original."))

(defmethod copy-address ((addr ipv4-address))
  (make-instance 'ipv4-address :name (copy-seq (address-name addr))))

(defmethod copy-address ((addr ipv6-address))
  (make-instance 'ipv6-address :name (copy-seq (address-name addr))))

(defmethod copy-address ((addr local-address))
  (make-instance 'local-address
                 :name (copy-seq (address-name addr))
                 :abstract (abstract-address-p addr)))

;;; Returns an IPv6 address by mapping ADDR onto it.
(defun map-ipv4-address-to-ipv6 (address)
  (make-instance 'ipv6-address
                 :name (map-ipv4-vector-to-ipv6 (address-name address))))

(defun map-ipv6-address-to-ipv4 (address)
  (assert (ipv6-ipv4-mapped-p address) (address)
          "Not an IPv6-mapped IPv4 address: ~A" address)
  (make-instance 'ipv4-address
                 :name (map-ipv6-vector-to-ipv4 (address-name address))))

;;;; Constructor

(defun make-address (name)
  "Constructs an ADDRESS object.  NAME should be of type
IPV4-ARRAY, IPV6-ARRAY or STRING in which case an instance of
IPV4-ADDRESS, IPV6-ADDRESS or LOCAL-ADDRESS, respectively, will
be created.  Otherwise, a TYPE-ERROR is signalled.  See also
ENSURE-ADDRESS."
  (cond
    ((ignore-errors (coercef name 'ipv4-array))
     (make-instance 'ipv4-address :name name))
    ((ignore-errors (coercef name 'ipv6-array))
     (make-instance 'ipv6-address :name name))
    ((stringp name) (make-instance 'local-address :name name))
    (t (error 'type-error :datum name
              :expected-type '(or string ipv4-array ipv6-array)))))