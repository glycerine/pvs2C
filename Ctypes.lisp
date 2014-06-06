
(in-package :pvs)


;; structure to represent the C variables
(defclass C-type () ())
(defclass C-int (C-type) ())
(defclass C-uli (C-type) ())
(defclass C-mpz (C-type) ())
(defclass C-mpq (C-type) ())
(defclass C-pointer (C-type) ((target :type C-type  :initarg :target)))
(defclass C-struct (C-type) ((name :initarg :name)))
(defclass C-named-type (C-type) ((name :initarg :name)))
(defclass C-closure  (C-type) ())


(defvar *C-type* (make-instance 'C-type))
(defvar *C-int* (make-instance 'C-int))
(defvar *C-uli* (make-instance 'C-int))
(defvar *C-mpz* (make-instance 'C-mpz))
(defvar *C-mpq* (make-instance 'C-mpq))

(defvar *min-C-int* (- (expt 2 15)))
(defvar *max-C-int* (- (expt 2 15) 1))
(defvar *min-C-uli* 0)
(defvar *max-C-uli* (- (expt 2 32) 1))


(defgeneric same-type (typeA typeB))
(defmethod same-type ((typeA C-int) (typeB C-int)) t)
(defmethod same-type ((typeA C-uli) (typeB C-uli)) t)
(defmethod same-type ((typeA C-mpz) (typeB C-mpz)) t)
(defmethod same-type ((typeA C-mpq) (typeB C-mpq)) t)
(defmethod same-type ((typeA C-pointer) (typeB C-pointer))
  (same-type (slot-value typeA 'target) (slot-value typeB 'target)))
(defmethod same-type ((typeA C-struct) (typeB C-struct))
  (string= (slot-value typeA 'name) (slot-value typeB 'name)))
(defmethod same-type ((typeA C-named-type) (typeB C-named-type))
  (string= (slot-value typeA 'name) (slot-value typeB 'name)))
(defmethod same-type ((typeA C-closure) (typeB C-closure)) t)
(defmethod same-type (typeA typeB) nil)



(defmethod print-object ((obj C-int) out) (format out "int"))
(defmethod print-object ((obj C-uli) out) (format out "unsigned long int"))
(defmethod print-object ((obj C-mpz) out) (format out "mpz_t"))
(defmethod print-object ((obj C-mpq) out) (format out "mpq_t"))
(defmethod print-object ((obj C-pointer) out) (format out "~a*" (slot-value obj 'target)))
(defmethod print-object ((obj C-struct) out) (format out "struct ~a" (slot-value obj 'name)))
(defmethod print-object ((obj C-named-type) out) (format out "~a" (slot-value obj 'name)))
(defmethod print-object ((obj C-closure) out) (format out "pvsClosure"))
(defmethod print-object ((obj C-type) out) (format out "[Abstract C type]"))

(defgeneric pointer? (type))
(defmethod pointer? ((type C-int)) nil)
(defmethod pointer? ((type C-uli)) nil)
(defmethod pointer? ((type C-type)) t)


(defmethod pvs-type-2-C-type ((type recordtype) &optional tbindings)
  (with-slots (print-type) type
    (if (type-name? print-type)
	(let ((entry (assoc (declaration print-type) *C-record-defns*)))
	  (if entry (cadr entry) ;return the C-rectype-name
	      (let* ((formatted-fields (loop for fld in (fields type)
				  collect
				  (format nil "~a ~a;" 
					  (pvs-type-2-C-type (type fld)) (id fld))))
		     (C-rectype-name (gentemp (format nil "pvs~a" (id print-type))))
		     (C-rectype (format nil "struct ~a {~%~{  ~a~%~}};"
					C-rectype-name formatted-fields)))
		(push (list (declaration print-type) C-rectype-name C-rectype)
		      *C-record-defns*)
		(make-instance 'C-struct :name C-rectype-name))))
	(pvs2C-error "~%Record type ~a must be declared." type))))

(defmethod pvs-type-2-C-type ((type tupletype) &optional tbindings)
  (make-instance 'C-named-type
		 :name (format nil "~{!~a~^_~}" (loop for elemtype in (types type)
				   collect (pvs-type-2-C-type elemtype)))))

(defmethod pvs-type-2-C-type ((type funtype) &optional tbindings)
  (if (C-updateable? type)
      (make-instance 'C-pointer :target (pvs-type-2-C-type (range type)))
    (make-instance 'C-closure)))

(defmethod pvs-type-2-C-type ((type subtype) &optional tbindings)
  (let ((range (subrange-index type)))
    (cond ((subtype-of? type *boolean*) *C-int*)
	  ((subtype-of? type *integer*)
	     (cond ((is-in-range? range *min-C-int* *max-C-int*) *C-int*)
		   ((is-in-range? range *min-C-uli* *max-C-uli*) *C-uli*)
		   (t *C-mpz*)))
	  ((subtype-of? type *number* ) *C-mpq*)
	  (t (pvs-type-2-C-type (find-supertype type))))))

(defmethod pvs-type-2-C-type ((type type-name) &optional tbindings)
  (with-slots (id) type
     (if (eq id 'boolean) *C-int*
       (make-instance 'C-named-type
		 :name (or (cdr (assoc type tbindings :test #'tc-eq))
			   (id type))))))


(defun C-type-args (operator)
  (let ((dom-type (domain (type operator))))
    (if (tupletype? dom-type)
	(pvs-type-2-C-type (types dom-type))
      (list (pvs-type-2-C-type dom-type)))))



(defun is-expr-subtype? (expr type)
  (let ((*generate-tccs* t))
    (some #'(lambda (jty) (subtype-of? jty type))
	  (judgement-types+ expr))))

(defun get-bounds (expr)
  (let ((*generate-tccs* t))
    (get-inner-bounds-list (judgement-types+ expr) nil nil)))
(defun get-inner-bounds-list (l inf sup)
  (if (consp l)
      (let ((range (subrange-index (car l))))
	(if range
	    (let ((ninf (car range))
		  (nsup (cadr range)))
	      (get-bounds (cdr l)
			  (when inf (max inf ninf) ninf)
			  (when sup (min sup nsup) nsup)))
	  (get-bounds (cdr l) inf sup)))
    (list inf sup)))

(defgeneric is-in-range? (e inf sup))
(defmethod is-in-range? ((interval list) inf sup)
  (and interval
       (<= inf (car interval))
       (<=     (cadr interval) sup)))
(defmethod is-in-range? ((t type-expr) inf sup)
  (is-in-range? (subrange-index t) inf sup))
(defmethod is-in-range? ((e expr) inf sup)
  (is-in-range? (get-bounds e) inf sup))


(defun C-integer-type? (expr)
  (is-expr-subtype? expr *integer*))
(defun C-unsignedlong-type? (expr)
  (and (C-integer-type? expr)
       (is-in-range? expr *min-C-uli* *max-C-uli*)))
(defun C-int-type? (expr)
  (and (C-integer-type? expr)
       (is-in-range? expr *min-C-int* *max-C-int*)))

(defmethod pvs-type-2-C-type ((e number-expr) &optional tbindings)
  (let ((n (number e)))
    (cond ((<= *min-C-int* n *max-C-int*) *C-int*)
	  ((<= 0 n *max-C-uli*) *C-uli*)
	  (t (pvs-type-2-C-type (type e))))))

(defmethod pvs-type-2-C-type ((e expr) &optional tbindings)
  (if (C-integer-type? e)
      *C-int*
    (pvs-type-2-C-type (type e))))

(defmethod pvs-type-2-C-type ((l list) &optional tbindings)
  (if (consp l)
      (cons (pvs-type-2-C-type (car l))
	    (pvs-type-2-C-type (cdr l)))
    nil))




(defstruct C-var name type)
(defun get-C-var (type name)
  (make-C-var :name name :type type))
(defun C-var (type name) (make-C-var :name name :type type))
(defmethod print-object ((obj C-var) out)
  (format out "~a" (slot-value obj 'name)))

(defmethod pointer? ((obj C-var)) (pointer? (C-type obj)))
(defmethod pointer? ((e expr)) (pointer? (pvs-type-2-C-type (type e))))
(defmethod pointer? (arg) nil)

(defmethod C-type ((arg C-var)) (slot-value arg 'type))

(defgeneric gen-C-var (expr prefix))
(defmethod gen-C-var ((type C-type) prefix)
  (C-var type (gentemp prefix)))
(defmethod gen-C-var ((expr expr) prefix)
  (let* ((type (type expr))
	 (name (gentemp prefix))
	 (C-type
	  (if (subtype-of? type *number*)
	      (if (C-integer-type? expr)
		  *C-mpz*
		*C-mpq*)
	    (pvs-type-2-C-type type))))
    (C-var C-type name)))

(defgeneric C-alloc (arg))
(defmethod C-alloc ((type C-mpz))
  (list "mpz_init(~a);"))
(defmethod C-alloc ((type C-mpq))
  (list "mpq_init(~a);"))
(defmethod C-alloc ((type C-pointer))
  (list (format "~~a = malloc( sizeof(~a) );" type)))
(defmethod C-alloc ((type C-type)) nil)
(defmethod C-alloc ((v C-var))
  (let ((type (C-type v))
	(name (slot-value v 'name)))
    (cons
     (format nil "~a ~a;" type name)
     (apply-argument (C-alloc type) name))))



(defgeneric C-free (arg))
(defmethod C-free ((type C-int)) nil)
(defmethod C-free ((type C-uli)) nil)
(defmethod C-free ((type C-mpz))
  (list "mpz_clear(~a);"))
(defmethod C-free ((type C-mpq))
  (list "mpq_clear(~a);"))
(defmethod C-free ((type C-type))
  (when (pointer? C-type) (list "free(~a);")))
(defmethod C-free ((v C-var))
  (apply-argument (C-free (C-type v))
		  (slot-value v 'name)))



(defun get-typed-copy (typeA nameA typeB nameB)
  (if (pointer? typeA)
      (format nil "~a(~a, ~a);" (convertor typeA typeB) nameA nameB)
    (if (same-type typeA typeB)
	(format nil "~a = ~a;" nameA nameB)
      (format nil "~a = ~a(~a);" nameA (convertor typeA typeB) nameB))))

(defun convertor (typeA typeB)
  (if (same-type typeA typeB)
      (format nil "copy_~a" typeA)
    (format nil "~a_from_~a" typeA typeB)))





;; Old functions


;(defun malloc (type name) ;; other versions should be defined (for BigInt, Rationnal, etc)
;  (cond ((subtype-of? type *integer*) (list
;				       (format nil "mpz_t ~a;" name)
;				       (format nil "mpz_init(~a);" name)))
;	((subtype-of? type *number*) (list
;				      (format nil "mpq_t ~a;" name)
;				      (format nil "mpq_init(~a);" name)))
;	 (t (list (format nil "~a ~a = malloc( sizeof(~a) );"
;			  (pvs2C-type type) name (pvs2C-type type))))))
;
;(defun free (type name) ;; other versions should be defined (for BigInt, Rationnal, etc)
;  (cond ((subtype-of? type *integer*) (list
;				       (format nil "mpz_clear(~a);" name)))
;	((subtype-of? type *number*) (list
;				      (format nil "mpq_clear(~a);" name)))
;	 (t (list (format nil "free(~a);" name)))))






;(defmethod pvs2C-type ((type recordtype) &optional tbindings)
;  (with-slots (print-type) type
;    (if (type-name? print-type)
;	(let ((entry (assoc (declaration print-type) *C-record-defns*)))
;	  (if entry (cadr entry) ;return the C-rectype-name
;	      (let* ((formatted-fields (loop for fld in (fields type)
;				  collect
;				  (format nil "~a :: !~a" (id fld)
;						(pvs2C-type (type fld)))))
;		    (C-rectype (format nil "{ ~{~a~^, ~} }" formatted-fields))
;		    (C-rectype-name (gentemp (format nil "pvs~a" (id print-type)))))
;		(push (list (declaration print-type) C-rectype-name C-rectype)
;		      *C-record-defns*)
;		C-rectype-name)))
;	(pvs2C-error "~%Record type ~a must be declared." type))))
;
;(defmethod pvs2C-type ((type tupletype) &optional tbindings)
;  (format nil "(~{!~a~^, ~})" (loop for elemtype in (types type)
;				   collect (pvs2C-type elemtype))))
;
;(defmethod pvs2C-type ((type funtype) &optional tbindings)
;  (if (C-updateable? type)
;      (format nil "~a*" (pvs2C-type (range type)))
;      (format nil "~aClosure" (pvs2C-type (range type)))))
;
;(defmethod pvs2C-type ((type subtype) &optional tbindings)
;  (cond ((subtype-of? type *integer*) "BigInt"  )
;	((subtype-of? type *real*   ) "Rational")
;	(t (pvs2C-type (find-supertype type)))))
;
;(defmethod pvs2C-type ((type type-name) &optional tbindings)
;  (or (cdr (assoc type tbindings :test #'tc-eq))
;      (id type)))
