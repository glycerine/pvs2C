;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;                PVS to C translator
;;
;;     Author: Gaspard ferey
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; This requires "Cprimop.lisp" and "Ctypes.lisp" files both available at
;;               https://github.com/Gaspi/pvs2c.git
;;
;; To use:
;;  - Copy this file, Cprimop.lisp and Ctypes.lisp (3 files) in the folder containing
;;    the .pvs file (e.g. "foo.pvs") you're interested in translating to C.
;;  - Start PVS, open this .pvs file and typecheck it.
;;  - In the *pvs* buffer:
;;      (load "pvs2c")
;;      (generate-C-for-pvs-file "foo")
;;  - "foo.c" and "foo.h" were created.
;;
;;
;;  Main functions :
;;
;;    pvs2C expr bindings livevars type
;;      -> string representing a C-variable or expression of the
;;         given type and with the translation of expr as a value.
;;
;;    pvs2C* expr bindings livevars
;;      -> cons of a type amd a string representing a C-variable
;;         or expression of the given type and with the translation
;;         of expr as a value.
;;
;;    pvs2C2-getdef expr bindings livevars type name [need-malloc]
;;      -> a list of instructions setting the C variable with the
;;         given name and type to the translation of expr.
;;         If need-malloc flag is t, also initialize the variable.
;;
;;    pvs2C2 expr bindings livevars type name [need-malloc]
;;      -> Add the result of pvs2C2-getdef to the current instructions.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(in-package :pvs)

;; Bad practice ???
(load "Ctypes")
(load "Cprimop")

(defvar *C-livevars-table* nil)
(defvar *C-record-defns* nil)


(defmacro C-reset (array)
  `(setq ,array nil))
(defmacro C-save (array)
  `(setq ,array (list ,array)))
(defmacro C-load (array)
  `(if (listp (car ,array))
       (let ((res (cdr ,array)))
	 (setq ,array (car ,array))
	 res)
     (break)))
(defmacro C-add (array args)
  `(setq ,array (append ,array
	    (if (listp ,args) ,args (list ,args)))))
(defmacro C-flush (array)
  `(let ((res ,array))
     (setq ,array nil)
     res))

;; Instructions to allocate memory for new variables
(defvar *C-instructions* nil)
(defun reset-instructions () (C-reset *C-instructions*))
(defun add-instructions (instructions)
  (C-add *C-instructions* instructions))
(defun add-instruction (instruction)
  (C-add *C-instructions* (list instruction)))
(defun add-instructions-first (instructions)
  (setq *C-instructions* (append instructions *C-instructions*)))

;; Instructions to destruct previously allocated memory
(defvar *C-destructions* nil)
(defun reset-destructions () (C-reset *C-destructions*))
(defun add-destructions (destructions)
  (C-add *C-destructions* destructions))
(defun add-destruction (destruction)
  (C-add *C-destructions* (list destruction)))

(defvar *C-definitions* nil)
(defun reset-definitions () (C-reset *C-definitions*))
(defun add-definition (definition)
  (setq *C-definitions* (append *C-definitions* (list definition))))


(defmacro pvs2C-error (msg &rest args)
  `(format t ,msg ,@args))


(defvar *C-nondestructive-hash* (make-hash-table :test #'eq))
(defvar *C-destructive-hash* (make-hash-table :test #'eq))


(defun getConstantName (expr bindings)
  (when (name-expr? expr)
    (let ((e (assoc (declaration expr) bindings :key #'declaration)))
      (when e
	(cons (type (car e)) (cdr e))))))





; --- set and conversion functions need to be implemented correctly here ---

(defun convert (typeA typeB e)
  (cond ((type= typeA typeB) e)
	((not (C-pointer? typeA)) (format nil (convertor typeA typeB) e))
	(t
	 (let ((n (gen-C-var typeA "conv")))
	   (add-instructions (C-alloc n))
	   (add-instructions (get-typed-copy typeA n typeB e))
	   (add-destructions (C-free n))
	   n))))


(defmethod pvs2C ((expr list) bindings livevars &optional (exp-type (cons nil nil)))
  (when (consp expr)
    (cons (pvs2C (car expr) bindings
		 (append (updateable-vars (cdr expr)) livevars)
		 (car exp-type))
	  (pvs2C (cdr expr) bindings
		 (append (updateable-vars (car expr)) livevars)
		 (cdr exp-type)))))


;;(def method pvs2C ((expr list) bindings livevars exp-type)
;;   (let ((accum *C-destructions*))
;;     (reset-destructions)
;;     (pvs2C-list expr bindings livevars exp-type accum)))

;; (defun pvs2C-list (l bindings livevars exp-type accum)
;;   (if (consp l)
;;       (let ((carExpr (pvs2C (car l) bindings
;; 			(append (updateable-vars (cdr l)) livevars)
;; 			(car exp-type)))
;; 	    (newAccu (append *C-destructions* accum)))
;; 	(reset-destructions)
;; 	(cons carExpr
;; 	      (pvs2C-list (cdr l) bindings                        ;;need car's freevars
;; 		     (append (updateable-vars (car l)) livevars)
;; 		     (cdr exp-type) newAccu)))
;;     (progn
;;       (add-destructions accum)
;;    nil)))



(defmethod pvs2C-if ((expr if-expr) bindings livevars exp-type)  ;result
  (let* ((condition (condition expr))
	 (then-part (then-part expr))
	 (else-part (else-part expr))
	 (newlivevars (append (updateable-vars then-part)
			      (append (updateable-vars else-part)
				      livevars)))
	 (previous-instr *C-instructions*)
	 (previous-destr *C-destructions*))
    (reset-instructions)
    (reset-destructions)
    (let ((C-cond-part (pvs2C condition bindings newlivevars *C-int*))
	  (C-cond-instr *C-instructions*)
	  (C-cond-destr *C-destructions*))
      (reset-instructions)
      (reset-destructions)
      (pvs2C2 then-part bindings livevars exp-type "~a")
      (let ((C-then-instructions *C-instructions*)
	    (C-then-destructions *C-destructions*))
	(reset-instructions)
	(reset-destructions)
	(pvs2C2 else-part bindings livevars exp-type "~a")
	(let ((C-else-instructions *C-instructions*)
	      (C-else-destructions *C-destructions*))
	  (reset-instructions)
	  (reset-destructions)
	  (add-instructions previous-instr)
	  (add-instructions C-cond-instr)
	  (add-destructions previous-destr)
	  (add-instructions C-cond-destr)
	  (append (list (format nil "if(~a) {" C-cond-part))
		  (mapcar #'(lambda (x) (format nil "  ~a" x))
			  C-then-instructions)
		  (mapcar #'(lambda (x) (format nil "  ~a" x))
			  C-then-destructions)
		  (list "} else {")
		  (mapcar #'(lambda (x) (format nil "  ~a" x))
			  C-else-instructions)
		  (mapcar #'(lambda (x) (format nil "  ~a" x))
			  C-else-destructions)
		  (list "}")))))))





(defmethod pvs2C* ((expr if-expr) bindings livevars)
  (let* ((type (pvs2C-type expr))    ;; could be improved to find a smaller type
	 (if-bloc (pvs2C-if expr bindings livevars type)))
    (cons type if-bloc)))


;; Returns nothing
;; Should not empty *C-destructions*
(defun pvs2C2 (expr bindings livevars type name &optional need-malloc)
  (C-save *C-destructions*)
  (when need-malloc (add-instructions (C-alloc (C-var type name))))
  (if (not (C-pointer? type))
      (let ((e (pvs2C expr bindings livevars type)))
	(add-instruction (format nil "~a = ~a;" name e))
	(add-instructions (C-load *C-destructions*))
	(when need-malloc (add-destructions (C-free (C-var type name)))))
    (let* ((e (pvs2C* expr bindings livevars))
	   (type-e (car e)))
      (if (consp (cdr e))  ;; C-pointer? type-e
	  (if (type= type-e type)
	      (progn
		(add-instructions
		 (append (apply-argument (cdr e) name)
			 (C-load *C-destructions*)))
		(when need-malloc (add-destructions (C-free (C-var type name)))))
	    (let ((n (gen-C-var type-e "set")))
	      (add-instructions
	       (append (C-alloc n)
		       (apply-argument (cdr e) n)
		       (C-load *C-destructions*)
		       (get-typed-copy type name type-e n)
		       (C-free n)))
	      (when need-malloc (add-destructions (C-free (C-var type name))))))
	(progn
	  (add-instructions
	   (append (get-typed-copy type name type-e (cdr e))
		   (C-load *C-destructions*)))
	  (when need-malloc (add-destructions (C-free (C-var type name)))))))))

;(defun pvs2C2 (expr bindings livevars type name &optional need-malloc)
;  (add-instructions (pvs2C2 expr bindings livevars type name need-malloc)))


(defun pvs2C2-getdef (expr bindings livevars exp-type name &optional (need-malloc t))
  (let ((previous-instr *C-instructions*))
    (reset-instructions)
    (pvs2C2 expr bindings livevars exp-type name need-malloc)
    (let ((res *C-instructions*))
      (reset-instructions)
      (add-instructions previous-instr)
      res)))

(defmethod pvs2C (expr bindings livevars &optional (exp-type (pvs2C-type expr)))
  (let ((name (getConstantName expr bindings)))
    (if name (convert exp-type (pvs2C-type (car name)) (cdr name))
      (progn
	(C-save *C-destructions*)
	(let* ((e (pvs2C* expr bindings livevars)) ;; Returns an instructions (ends with *)
	       (type (car e)))
	  (if (listp (cdr e))
	      (let ((n (gen-C-var type "aux")))
		(add-instructions (C-alloc n))
		(add-instructions (apply-argument (cdr e) n))
		(add-instructions (C-load *C-destructions*))
		;; (C-reset *C-destructions*)
		(add-destructions (C-free n))
		(convert exp-type type n))
	    (if (not (cdr *C-destructions*))  ; If it was a simple expression (no destructions)
		(progn (C-load *C-destructions*)
		       (convert exp-type type (cdr e)))
	      (let ((n (gen-C-var type "aux")))
		(add-instructions (C-alloc n)) ; probably empty
		(add-instruction (format nil "~a = ~a;" n (cdr e)))
		(add-instructions (C-load *C-destructions*))
		(add-destructions (C-free n)) ; probably empty
		(convert exp-type type n)))))))))
  
(defmethod pvs2C ((expr if-expr) bindings livevars &optional (exp-type (pvs2C-type expr)))
  (C-save *C-destructions*)
  (let* ((type (smaller-type (pvs2C-type expr) exp-type))
	 (if-bloc (pvs2C-if expr bindings livevars type))
	 (if-name (gen-C-var type "if")))
    (add-instructions (C-alloc if-name))
    (add-instructions (apply-argument if-bloc if-name))
    (add-instructions (C-load *C-destructions*))
    (add-destructions (C-free if-name))
    (convert exp-type type if-name)))

;; Deprecated
;(defmethod pvs2C ((expr if-expr) bindings livevars exp-type)
;  (let* ((type (pvs2C-type expr))
;	 (if-bloc (pvs2C-if expr bindings livevars type t))
;	 (if-name (gentemp "if")))
;    (add-instructions (apply-argument if-bloc if-name))
;    (convert exp-type type if-name)))




(defstruct C-info
  id type-out type-arg definition analysis)

(defmacro C-hashtable ()
  `(if *destructive?* *C-destructive-hash* *C-nondestructive-hash*))

(defun C_id (op)
  (let ((hashentry (gethash (declaration op) (C-hashtable))))
    (when hashentry (C-info-id hashentry))))

(defun C_nondestructive_id (op)
  (let ((hashentry (gethash (declaration op) *C-nondestructive-hash*)))
    (when hashentry (C-info-id hashentry))))

(defun C_type (op)
  (let ((hashentry (gethash (declaration op) (C-hashtable))))
    (when hashentry (format nil "~a -> ~a"
	 (C-info-type-arg hashentry)
	 (C-info-type-out hashentry)))))

(defun C_definition (op)
  (let ((hashentry (gethash (declaration op) (C-hashtable))))
    (when hashentry (C-info-definition hashentry))))

(defun C_analysis (op)
  (let ((hashentry (gethash (declaration op) (C-hashtable))))
    (when hashentry (C-info-analysis hashentry))))


(defmethod pvs2C* ((expr number-expr) bindings livevars)
  (declare (ignore bindings livevars))
  (let ((type (pvs2C-type expr)))
    (cons type
       (if (C-pointer? type)
	   (let ((op (cond ((type= type *C-mpz*) "mpz_set_str")
			   ((type= type *C-mpq*) "mpq_set_str")
			   (t "setUnknown"))))
	     (set-C-pointer op (format nil  "\"~a\"" (number expr))))
	 (format nil "~a" (number expr))))))

(defmacro pvs2C_tuple (args)
  `(format nil "(~{~a~^, ~})" ,args))

;; Should be modified to create a different tuple according to the type of the args
(defmethod pvs2C* ((expr tuple-expr) bindings livevars)
  (let* ((elts (exprs expr))
	 (args (pvs2C elts bindings livevars
		      (mapcar #'pvs2C-type elts))))
    (mk-C-funcall "createTuple" (cons "~a" args))))

(defmethod pvs2C* ((expr record-expr) bindings livevars)
  (let* ((sorted-assignments (sort-assignments (assignments expr)))
	 (formatted-fields
	  (loop for entry in sorted-assignments
		collect (format nil "~~a.~a = ~a;"
			  (caar (arguments entry))
			  (pvs2C (expression entry)
				 bindings livevars)))))
    (cons (pvs2C-type expr)
	  (cons "struct record ~~a;"
		formatted-fields))))


(defmethod pvs2C* ((expr projection-application) bindings livevars)
  (let* ((ll (length (exprs expr)))
	 (dummy (gentemp "DDD"))
	 (match-list (pvs2C_tuple (matchlist (index expr) ll dummy)))
	 (expr-list (pvs2C expr bindings livevars)))
    `(let ,match-list = ,expr-list in ,dummy)))
	


(defmethod pvs2C*  ((expr field-application) bindings livevars)
  (let* ((clarg (pvs2C (argument expr) bindings livevars))
	 (id (id expr))
	 (e (format nil "~a.~a" clarg id))
	 (type (pvs2C-type expr)))
    (cons type
	  (if (C-pointer? type)
	      (get-typed-copy type "~a" type e)
	    e))))

;; When is this function called ??  (not working)
(defmethod pvs2C* ((expr list) bindings livevars)
  (if (consp expr)
      (cons (pvs2C (car expr) bindings
		   (append (updateable-vars (cdr expr)) livevars) )
	    (pvs2C (cdr expr) bindings  ;;need car's freevars
		   (append (updateable-vars (car expr)) ;;f(A, A WITH ..)
			   livevars)))
    nil))

(defun pair3lis (l1 l2 l3)
  (when (consp l1)
    (cons (list (car l1) (car l2) (car l3))
	  (pair3lis (cdr l1) (cdr l2) (cdr l3)))))

(defmethod pvs2C* ((expr application) bindings livevars)
  (with-slots (operator argument) expr
    (if (constant? operator)
      (if (pvs2cl-primitive? operator)
	    (pvs2C*-primitive-app expr bindings livevars)
	  (if (datatype-constant? operator)
	      (cons (pvs2C-type (range (type operator)))
		    (mk-C-funcall (pvs2C-resolution operator)
				  (pvs2C (arguments expr)
					 bindings
					 livevars)))
	    (pvs2C-defn-application expr bindings livevars)))
      (if (lambda? operator)
	  (let* ((bind-decls (bindings operator))
		 (bind-ids (pvs2cl-make-bindings bind-decls bindings))
		 (newbind (append (pairlis bind-decls bind-ids) bindings))
		 (type-args (C-type-args operator))
		 (C-arg (pvs2C (if (tuple-expr? argument)
				   (exprs argument)
				   (list argument))
			       bindings
			       (append (updateable-free-formal-vars operator) livevars)
			       type-args)))
	    (add-instructions (mapcar
			       #'(lambda (x) (format nil "~a ~a = ~a;"
						     (car x)
						     (cadr x)
						     (caddr x)))
			       (pair3lis type-args (bindings operator) C-arg))) ; process name
	    (pvs2C* (expression operator) newbind nil))
	(let* ((type-op (pvs2C-type (type operator)))
	       (type (pvs2C-type (range (type operator))))
	       (C-arg (pvs2C argument bindings
			     (append (updateable-free-formal-vars operator) livevars)))
	       (C-op (pvs2C operator bindings
			    (append (updateable-vars argument) livevars)
			    type-op)))
	  (if (C-pointer-type? type-op) ;; if the operator is an array
	      (cons (target type-op)
		    (if (C-pointer? (target type-op))
			(format nil "~a[~a]" C-op C-arg)
		      (format nil "~a[~a]" C-op C-arg)))
;;	     (pvs2C*-updateable-get type-op C-op C-arg)
	    (cons type
		  (if (C-pointer? type)
		      (set-C-pointer C-op C-arg)
		    (mk-C-funcall C-op C-arg)))))))))


(defun pvs2C-defn-application (expr bindings livevars)
  (with-slots (operator argument) expr
    (pvs2C-resolution operator)
    (let* ((actuals (expr-actuals (module-instance operator)))
	   (op-decl (declaration operator))
	   (args (arguments expr))
	   (type-args (C-type-args op-decl))
	   (ret-type (pvs2C-type (range (type op-decl))))
	   (C-args (pvs2C (append actuals args) bindings livevars type-args)))
      (if *destructive?*
	  (let* ((ret-type (pvs2C-type (range (type operator))))
		 (defns (def-axiom op-decl))
		 (defn (when defns (args2 (car (last (def-axiom op-decl))))))
		 (def-formals (when (lambda-expr? defn)
				(bindings defn)))
		 (module-formals (unless (eq (module op-decl) (current-theory))
				   (constant-formals (module op-decl))))
		 (alist (append (pairlis module-formals actuals)
				(when def-formals
				  (pairlis def-formals args))))
		 (analysis (C_analysis operator))
		 (check (check-output-vars analysis alist livevars))
		 (id-op (if check (C_id operator)
			          (C_nondestructive_id operator))))
	    (cons ret-type (if (C-pointer? ret-type)
			       (set-C-pointer id-op C-args)
			     (mk-C-funcall id-op C-args))))
	(cons ret-type (if (C-pointer? ret-type)
			   (set-C-pointer (C_id operator) C-args)
			 (mk-C-funcall (C_id operator) C-args)))))))

(defun pvs2C-resolution (op)
  (let* ((op-decl (declaration op)))
    (pvs2C-declaration op-decl)))

(defun pvs2C-declaration (op-decl)
  (let ((nd-hashentry (gethash op-decl *C-nondestructive-hash*))
	;(d-hashentry (gethash op-decl *C-destructive-hash*))
	;enough to check one hash-table. 
	)
    (when (null nd-hashentry)
      (let ((op-id (gentemp (format nil "pvs_~a" (id op-decl))))
	    (op-d-id (gentemp (format nil "pvs_d_~a" (id op-decl)))))
      (setf (gethash op-decl *C-nondestructive-hash*)
	    (make-C-info :id op-id))
      (setf (gethash op-decl *C-destructive-hash*)
	    (make-C-info :id op-d-id))
      (let* ((defns (def-axiom op-decl))
	     (defn (when defns (args2 (car (last (def-axiom op-decl))))))
	     (def-formals (when (lambda-expr? defn)
			    (bindings defn)))
	     (def-body (if (lambda-expr? defn) (expression defn) defn))
	     (module-formals (constant-formals (module op-decl)))
	     (range-type (if def-formals (range (type op-decl))
			     (type op-decl))))
	(pvs2C-resolution-nondestructive op-decl (append module-formals def-formals)
					     def-body range-type)
	(pvs2C-resolution-destructive op-decl (append module-formals def-formals)
					  def-body range-type))))))

(defun pvs2C-resolution-nondestructive (op-decl formals body range-type)
  (let* ((*destructive?* nil)
	 (bind-ids (pvs2cl-make-bindings formals nil))
	 (id-map (pairlis formals bind-ids))
	 (cl-type-out (pvs2C-type range-type))
	 (pointer-out (C-pointer? cl-type-out))
	 (result-var (C-var cl-type-out "result"))
	 (cl-type-arg (format nil "~{~a~^, ~}"
	      (append (when pointer-out (list (format nil "~a result" cl-type-out)))
		      (loop for var in formals
			    collect (format nil "~a ~a"
					    (pvs2C-type (type var))
					    (cdr (assoc var id-map)) )))))
	 (hash-entry (gethash op-decl *C-nondestructive-hash*)))
    (pvs2C2 body id-map nil cl-type-out "result")
    (format t "~%Defining (nondestructively) ~a with type~%   ~a -> ~a"
	    (id op-decl) cl-type-arg cl-type-out)
    (when *eval-verbose* (format t "~%as :~%~{~a~%~}" *C-instructions*))
    (setf (C-info-type-out hash-entry) (if pointer-out "void" cl-type-out)
	  (C-info-type-arg hash-entry) cl-type-arg
	  (C-info-definition hash-entry)
	       (format nil "~{  ~a~%~}~{  ~a~%~}~:[  return result;~%~;~]"
		       (C-flush *C-instructions*)
		       (C-flush *C-destructions*) pointer-out))
      ))

(defun pvs2C-resolution-destructive (op-decl formals body range-type)
  (let* ((*destructive?* t)
	 (*output-vars* nil)
	 (bind-ids (pvs2cl-make-bindings formals nil))
	 (id-map (pairlis formals bind-ids))
	 (cl-type-out (pvs2C-type range-type))
	 (pointer-out (C-pointer? cl-type-out))
	 (result-var (C-var cl-type-out "result"))
	 (cl-type-arg (format nil "~{~a~^, ~}"
	      (append (when pointer-out (list (format nil "~a result" cl-type-out)))
		      (loop for var in formals
		       collect (format nil "~a ~a"
				       (pvs2C-type (type var))
				       (cdr (assoc var id-map)))))))
	 (hash-entry (gethash op-decl *C-destructive-hash*))
	 (old-output-vars (C-info-analysis hash-entry)))
    (pvs2C2 body id-map nil cl-type-out "result")
    (format t "~%Defining (destructively) ~a with type~%   ~a -> ~a"
	    (id op-decl) cl-type-arg cl-type-out)
    (when *eval-verbose* (format t "~%as :~%~{~a~%~}" *C-instructions*))
    (unless pointer-out (add-instructions-first (C-alloc result-var)))
    (setf (C-info-type-out hash-entry) (if pointer-out "void" cl-type-out)
	  (C-info-type-arg hash-entry) cl-type-arg
	  (C-info-definition hash-entry)
	      (format nil "~{  ~a~%~}~{  ~a~%~}~:[  return result;~%~;~]"
		      (C-flush *C-instructions*)
		      (C-flush *C-destructions*) pointer-out)
	  (C-info-analysis hash-entry) *output-vars*)
    (unless (equalp old-output-vars *output-vars*)
      (pvs2C-resolution-destructive op-decl formals body range-type))))


(defmethod pvs2C* ((expr name-expr) bindings livevars)
  (let* ((type-e (pvs2C-type expr))
	 (decl (declaration expr))
	 (bnd (assoc decl bindings :key #'declaration))
	 (prim (pvs2cl-primitive? expr)))
    (assert (not (and bnd (const-decl? decl))))
    (cond (bnd  (cons type-e (cdr bnd)))
	  (prim (pvs2C*-primitive-cste expr bindings livevars))
	  ((const-decl? decl)
	        (pvs2C*-constant expr decl bindings livevars))
	  (t
	        (let ((undef (undefined expr "Hit untranslateable expression ~a")))
		  `(funcall ',undef))))))

(defun pvs2C*-constant (expr op-decl bindings livevars)
  (let* ((defns (def-axiom op-decl))
	 (defn (when defns (args2 (car (last (def-axiom op-decl))))))
	 (def-formals (when (lambda-expr? defn)
			(bindings defn))))
    (pvs2C-resolution expr)
    (if def-formals 
	(let ((eta-expansion
	       (make!-lambda-expr def-formals
		    (make!-application* expr
		       (loop for bd in def-formals
			     collect (mk-name-expr bd))))))
	  (pvs2C* eta-expansion bindings livevars))
	(let* ((actuals (expr-actuals (module-instance expr)))
	       (C-actuals (pvs2C actuals bindings livevars))  ;; The actuals are parameters
	       (type-e (pvs2C-type (type expr))))
	  (cons type-e
		(if (C-pointer? type-e)
		    (set-C-pointer (C_nondestructive_id expr) C-actuals)
		  (mk-C-funcall (C_nondestructive_id expr) C-actuals)))))))


(defun range-arr (max &key (min 0) (step 1))
   (loop for n from min below max by step
      collect n))

(defun append-lists (l)
  (when (consp l) (append (car l) (append-lists (cdr l)))))

;; Creates a closure (not working now...)
(defun pvs2C-lambda (bind-decls expr bindings) ;;removed livevars
  (let ((previous-instr *C-instructions*)
	(previous-destr *C-destructions*))
    (reset-instructions) 
    (reset-destructions)
    (let* ((*destructive?* nil)
	   (range-type (pvs2C-type (type expr)))
	   (bind-ids (pvs2cl-make-bindings bind-decls bindings))
	   (new-bind (append (pairlis bind-decls bind-ids) bindings))
	   (cl-body (pvs2C expr
			    new-bind
			    nil range-type))
	   (name (gentemp "fun"))
	   (fv (freevars expr))
	   (nb-args (length fv))
	   (var-ind (pairlis fv (range-arr nb-args)))
	   (param-def (append-lists (mapcar #'(lambda (x) (load-void x "env"))
					    var-ind)))
	   (def-instructions *C-instructions*)
	   (def-destructions *C-destructions*)
	   (assign (loop for x in bindings
			 when (assoc (cdr x) var-ind :test #'(lambda (x y) (eq x (id y)) ))
			 collect it))
	   ;; Carefull !! eq x (id y) is not enough, (duplication variable id)
	   (env-name (gentemp "env")))
      (reset-instructions)
      (reset-destructions)
      (add-instructions previous-instr)
      (add-destructions previous-destr)
      (add-definition (format nil "~a ~a(void *env) {~%~{  ~a~%~}  return ~a;~%}"
			      range-type name
			      (append param-def def-instructions def-destructions)
			      cl-body))
      (add-instruction (format nil "void ~a[~d];" env-name nb-args))
      (add-instructions (append-lists (mapcar
				       #'(lambda (x) (save-void x env-name))
				       assign)))
      (cons (make-instance 'C-closure)
	    (list (format nil "makeClosure(~~a, ~a, ~a);" name env-name))))))


(defmethod pvs2C* ((expr lambda-expr) bindings livevars)
  (declare (ignore livevars))
  (with-slots (type expression) expr
    (let* ((range-type (pvs2C-type expression))
	   (bind-decls (bindings expr)))
      (if (and (C-updateable? type) (funtype? type))  ;; If it could be represented as an array
	  (let* ((i (gentemp "i"))
		 (new-bind (append (pairlis (list (car bind-decls)) ;; Hopefully bind-decls has length 1
					    (list i))
				   bindings)))
	    (cons (pvs2C-type expr)
		  (append
		   (list (format nil "if ( GC_count( ~~a ) == 1) {")
			 (format nil "  ~~a = GC( ~a );" )
			 (format nil "for(int ~a = 0; ~a < ~a;;; ~a++) {" i i (array-bound type) i))
		   (mapcar #'(lambda (x) (format nil "  ~a" x))
			   (pvs2C2-getdef expression
					  new-bind
					  nil  ;;removed livevars (why ?)
					  range-type
					  (format nil "~~a[~a]" i)
					  nil))
		   (list "}"))))
	(pvs2C-lambda bind-decls expression bindings)))))


;; Doesn't work  / Should look like if-expr
(defmethod pvs2C* ((expr cases-expr) bindings livevars)
  (let ((type (pvs2C-type expr)))
    (cons type
	  (append (list (format nil "switch( ~a ) {"
				(pvs2C (expression expr) bindings livevars type)))
		  (pvs2C-cases (selections expr) (else-part expr) bindings livevars)
		  (list "}")))))

;; Doesn't work / Should look like if-expr
(defun pvs2C-cases (selections else-part bindings livevars)
  (let ((selections-C
	 (loop for entry in selections
	       collect
	       (let* ((bind-decls (args entry))
		      (bind-ids (pvs2cl-make-bindings bind-decls bindings)))
		 (format nil "  case ~a ~{~a ~} : ~a; break;"
			 (pvs2C (constructor entry) bindings livevars)
			 bind-ids
			 (pvs2C (expression entry)
				(append (pairlis bind-decls bind-ids) bindings)
				livevars)))))))
  (append selections-C
	  (when else-part
	    (list (format nil "  default: ~a"
			  (pvs2C (expression else-part) bindings livevars))))
	  (list "}")))

(defmethod pvs2C* ((expr update-expr) bindings livevars)
  (with-slots (expression assignments) expr
  (if (C-updateable? (type expression))
      (if (and *destructive?* (not (some #'maplet? assignments)))
	  (let* ((*C-livevars-table* 
		  (no-livevars? expression livevars assignments)))
	    ;;very unrefined: uses all freevars of eventually updated expression.
	    (cond (*C-livevars-table* ;; check-assign-types
		   (push-output-vars (car *C-livevars-table*)
				     (cdr *C-livevars-table*))
		   (pvs2C-update expr bindings livevars))
		  (t
		   (when (and *eval-verbose* (not *C-livevars-table*))
		     (format t "~%Update ~s translated nondestructively. Live variables ~s present"
			       expr livevars))
		   (pvs2C-update expr bindings livevars))))
	(pvs2C-update expr bindings livevars))
    (cons (pvs2C-type expr)
	  (pvs2C (translate-update-to-if! expr) bindings livevars)))))

(defun pvs2C-update (expr bindings livevars)
  (with-slots (type expression assignments) expr
    (let* ((C-type (pvs2C-type type))
	   (assign-exprs (mapcar #'expression assignments)))
      (cons C-type
	    (append (pvs2C2-getdef expression bindings
				   (append (updateable-free-formal-vars
					      assign-exprs) ;;assign-args can be ignored
					   livevars)
				   C-type "~a" nil)
		    ;; First we create a copy of the array named "~a" without malloc
		    (pvs2C-update* (type expression)
				   (mapcar #'arguments assignments)
				   assign-exprs
				   bindings
				   (append (updateable-vars expression)
					   livevars)
				   )))))) ;; Then we update it

;;recursion over updates in an update expression
(defun pvs2C-update* (type assign-args assign-exprs bindings livevars)
  (when (consp assign-args)
    (append (pvs2C-update-nd-type
	        type "~a"
		(car assign-args )
		(car assign-exprs)
		bindings
		(append (append (updateable-vars (cdr assign-exprs))
				(updateable-vars (cdr assign-args ))
				livevars)))
	    (pvs2C-update* type
			   (cdr assign-args)
			   (cdr assign-exprs)
			   bindings
			   (append (updateable-free-formal-vars (car assign-exprs))
				   livevars)))))

;; ---- Recursion over nested update arguments in a single update ----
(defun pvs2C-update-nd-type (type exprvar args assign-expr bindings livevars)
  (if (consp args)
      (pvs2C-update-nd-type* type exprvar (car args) (cdr args) assign-expr
			      bindings livevars)
    (let ((C-type (pvs2C-type type))) ;; Should not happen... (a priori)
      (break)
      (get-typed-copy C-type exprvar
		      C-type (pvs2C assign-expr bindings livevars C-type)))))

(defmethod pvs2C-update-nd-type* ((type funtype) expr arg1 restargs
				   assign-expr bindings livevars)
  (let ((arg1var (gentemp "L"))
	(Ctype (pvs2C-type type)))
    (pvs2C2 (car arg1) bindings
	    (append (updateable-vars restargs)
		    (updateable-free-formal-vars assign-expr)
		    livevars)
	    (pvs2C-type (domain type)) arg1var t)
    (if (consp restargs)
	(let ((exprvar (gentemp "E")))
	  (append (updateable-get Ctype exprvar expr arg1var)
		  (pvs2C-update-nd-type (range type) exprvar
					restargs assign-expr
					bindings livevars)))
      (pvs2C2-getdef assign-expr bindings livevars
		     (target Ctype)
		     (format nil "~a[~a]" expr arg1var)
		     nil))))


(defmethod pvs2C-update-nd-type* ((type recordtype) expr arg1 restargs
				   assign-expr bindings livevars)
  (let* ((id (id (car arg1)))
	 (field-type (type (find id (fields type) :key #'id) )))
    (if (consp restargs)
	(let ((exprvar (gentemp "E")))
	  (cons (format nil "~a ~a = ~a.~a;" (pvs2C-type field-type) exprvar expr id)
		(pvs2C-update-nd-type field-type exprvar restargs assign-expr
				      bindings livevars)))
      (list (format nil "~a.~a = ~a;" expr id
		    (pvs2C assign-expr bindings livevars (pvs2C-type field-type)))))))


(defmethod pvs2C-update-nd-type* ((type subtype) expr arg1 restargs
				   assign-expr bindings livevars)
  (pvs2C-update-nd-type* (find-supertype type) expr arg1 restargs
			  assign-expr bindings livevars))


;; Function to get and set arrays
(defun updateable-set (type array index value)
  (if (and *destructive?* *C-livevars-table*) ;; Destructive update
      (list (format nil "~a[~a] = ~a; +++" array index value))
;;      (get-typed-copy (target type)
;;		      (format nil "~a[~a]" array index)
;;		      (target type) value)
    (get-typed-copy (target type)
		    (format nil "~a[~a]" array index)
		    (target type)
		    value)))
;;    (list (format nil "pvsNonDestructiveUpdate2(~a, ~a, ~a);" array index value))))
;; Should depend on the type ...


;; Get array[index] to modify it's fields later
(defmethod updateable-get ((type C-pointer-type) result array index)
  (list (format nil "~a ~a = ~a[~a];" (target type) result array index)))

(defmethod pvs2C*-updateable-get ((type C-pointer-type) array index)
  (cons (target type)
	(if (C-pointer? (target type))
	    (list (format nil "~~a = ~a[~a];" array index))
	  (format nil "~a[~a]" array index))))


;;C-updateable? is used to check if the type of an updated expression
;;is possibly destructively. 

(defmethod C-updateable? ((texpr tupletype))
  (C-updateable? (types texpr)))

;;this is the only case where C-updateable? can be false, because
;;the given function type is not an array.  
(defmethod C-updateable? ((texpr funtype)) ;;add enum types, subrange.
  (and (or (simple-below? (domain texpr))
	   (simple-upto? (domain texpr)))
       (C-updateable? (range texpr))))

(defmethod C-updateable? ((texpr recordtype))
  (C-updateable? (mapcar #'type (fields texpr))))

(defmethod C-updateable? ((texpr subtype))
  (C-updateable? (find-supertype texpr)))

(defmethod C-updateable? ((texpr list))
  (or (null texpr)
      (and (C-updateable? (car texpr))
	   (C-updateable? (cdr texpr)))))

;;This is subsumed by fall-through case.
;(defmethod C-updateable? ((texpr type-name))
;  (not (or (eq texpr *boolean*)
;	   (eq texpr *number*))))

;(defmethod C-updateable? ((texpr actual))
;  (C-updateable? (type-value texpr)))

(defmethod C-updateable? ((texpr t)) t)
;; It is okay to say  C-updateable? for uninterpreted
;; or actuals since these will not be updated destructively or otherwise.



(defun pvs2C-theory (theory)
  (reset-instructions)
  (reset-destructions)
  (let* ((theory (get-theory theory))
	 (*current-theory* theory)
	 (*current-context* (context theory)))
    (cond ((datatype? theory)
	   (pvs2C-datatype theory)
	   ;;(pvs2C-theory (adt-theory theory))
	   ;;(let ((map-theory (adt-map-theory theory))
	   ;;   (reduce-theory (adt-reduce-theory theory)))
	   ;;   (when map-theory (pvs2C-theory (adt-map-theory theory)))
	   ;;   (when reduce-theory (pvs2C-theory (adt-reduce-theory theory))))
	   )
	  (t (loop for decl in (theory theory)
		   do (cond ((type-eq-decl? decl)
			     (let ((dt (find-supertype (type-value decl))))
			       (when (adt-type-name? dt)
				 (pvs2C-constructors (constructors dt) dt))))
			    ((datatype? decl)
			     (let ((adt (adt-type-name decl)))
			       (pvs2C-constructors (constructors adt) adt)))
			    ((const-decl? decl)
			     (unless (eval-info decl)
			       (progn
				 (pvs2C-declaration decl))))
			    (t nil)))))))

;;; maps to AlgebraicTypeDef
(defun pvs2C-datatype (dt)
  (let* ((typevars (mapcar #'(lambda (fm)
			       (pvs2C-datatype-formal fm dt))
		     (formals dt)))
	 (constructors (pvs2C-constructors
			(constructors dt) dt
			(mapcar #'cons (formals dt) typevars))))
    (format nil "::~a~{ ~a~} = ~{~a~^ | ~}"
      (id dt) typevars constructors)))

(defun pvs2C-datatype-formal (formal dt)
  (if (formal-type-decl? formal)
      (let ((id-str (string (id formal))))
	(if (lower-case-p (char id-str 0))
	    (id formal)
	    (make-new-variable (string-downcase id-str :end 1) dt)))
      (break "What to do with constant formals?")))

(defun pvs2C-constructors (constrs datatype tvars)
  (pvs2C-constructors* constrs datatype tvars))

(defun pvs2C-constructors* (constrs datatype tvars)
  (when constrs
    (cons (pvs2C-constructor (car constrs) datatype tvars)
	  (pvs2C-constructors* (cdr constrs) datatype tvars))))

;;; Maps to ConstructorDef
(defun pvs2C-constructor (constr datatype tvars)
  (format nil "~a~{ ~a~}" (id constr)
	  (mapcar #'(lambda (arg) (pvs2C-type (type arg) tvars))
	    (arguments constr))))

(defun clear-C-hash ()
  (clrhash *C-nondestructive-hash*)
  (clrhash *C-destructive-hash*))

(defun generate-C-for-pvs-file (filename &optional force?)
  (setq *C-record-defns* nil)
  (clrhash *C-nondestructive-hash*)
  (clrhash *C-destructive-hash*)
  (reset-destructions)
  (reset-definitions)
  (let ((theories (cdr (gethash filename *pvs-files*))))
    ;; Sets the hash-tables
    (dolist (theory theories)
      (pvs2C-theory theory))
    (with-open-file (outputH (format nil "~a.h" filename)
			    :direction :output
			    :if-exists :supersede
			    :if-does-not-exist :create)
    (with-open-file (output (format nil "~a.c" filename)
			    :direction :output
			    :if-exists :supersede
			    :if-does-not-exist :create)
      (format output "~{~a~%~}" (apply-argument (list
	    "// ---------------------------------------------"
	    "//        C file generated from ~a.pvs"
	    "// ---------------------------------------------"
	    "//   Make sure to link GMP in compilation:"
	    "//      gcc -o ~a ~:*~a.c -lgmp"
	    "//      ./~a"
	    "// ---------------------------------------------"
	    "~%#include<stdio.h>"
	    "#include<gmp.h>"
	    "#include \"~a.h\""
	    "~%#define TRUE 1"
	    "#define FALSE 0"
	    "~%int main(void) {"
	    "  printf(\"Executing ~a ...\\n\");"
	    "  return 0;~%}") filename))
      (format output "~{~2%~a~}" *C-definitions*)
      (format outputH "// C file generated from ~a.pvs" filename)

      (dolist (rec-def *C-record-defns*)
	(format output "~a~%" (caddr rec-def)))
      (dolist (theory theories)
	(dolist (decl (theory theory))
	  (let ((ndes-info (gethash decl *C-nondestructive-hash*))
		(des-info (gethash decl *C-destructive-hash*)))
	    (when ndes-info
	      (let ((id (C-info-id ndes-info)))
		;; First the signature
		(format outputH "~2%~a ~a(~a);"
			(C-info-type-out ndes-info)
			id
			(C-info-type-arg ndes-info))
		;; Then the defn
		(format output  "~2%~a ~a(~a) {"
			(C-info-type-out ndes-info)
			id
			(C-info-type-arg ndes-info))
		(format output "~%~a}"  (C-info-definition des-info))))
	    (when des-info
	      (let ((id (C-info-id des-info)))
		;; First the signature
		(format output  "~2%~a ~a(~a) {"
			(C-info-type-out des-info)
			id
			(C-info-type-arg des-info))
		(format outputH "~2%~a ~a(~a);"
			(C-info-type-out des-info)
			id
			(C-info-type-arg des-info))
		;; Then the defn
		(format output "~%~a}"  (C-info-definition des-info)))))))))))






;; Useless functions ?/




(defun pvs2C-assign-rhs (assignments bindings livevars)
  (when (consp assignments)
    (let* ((e (expression (car assignments)))
	   (C-assign-expr (pvs2C e
				 bindings
				 (append (updateable-vars
					  (arguments (car assignments)))
					 (append (updateable-vars (cdr assignments))
						 livevars))))
	   (*lhs-args* nil))
      (cons C-assign-expr
	    (pvs2C-assign-rhs (cdr assignments) bindings
			      (append (updateable-free-formal-vars e)
				      livevars))))))




(defmacro debug (array str)
  `(when (eq ',array '*C-destructions*)
       (break (format nil "~a ~a : ~a~%" ',str ',array ,array))))


;; Deprecated
(defmacro pvsC_update (array index value)
  `(let ((update-op (if (and *destructive?* *C-livevars-table*)
			(format nil "pvsDestructiveUpdate")
			(format nil "pvsNonDestructiveUpdate"))))
       (format nil  "~a(~a, ~a, ~a);" update-op ,array ,index ,value)))




;; To add in the .el files

;; (defpvs pvs-C-file find-file (filename)
;;   "Generates the C code for a given file and displays it in a buffer"
;;   (interactive (pvs-complete-file-name "Generate C for file: "))
;;   (unless (interactive-p) (pvs-collect-theories))
;;   (pvs-bury-output)
;;   (message "Generating C for file...")
;;   (pvs-send-and-wait (format "(generate-C-for-pvs-file \"%s\")"
;; 			 filename) nil nil 'dont-care)
;;   (let ((buf (pvs-find-C-file filename)))
;;     (when buf
;;       (message "")
;;       (save-excursion
;; 	(set-buffer buf)
;; 	(setq pvs-context-sensitive t)
;; 	(lisp-mode)))))

;; (defun pvs-find-C-file (filename)
;;   (let ((buf (get-buffer (format "%s.c" filename))))
;;     (when buf
;;       (kill-buffer buf)))
;;   (let ((C-file (format "%s%s.c" pvs-current-directory filename)))
;;     (when (file-exists-p C-file)
;;       (find-file-read-only-other-window C-file))))
