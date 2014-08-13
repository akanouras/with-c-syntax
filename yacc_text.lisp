(in-package :cl-user)

(asdf:load-system :yacc)
(use-package :yacc)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defconstant +operators+
    '(|,|
      = *= /= %= += -= <<= >>= &= ^= \|=
      ? |:|
      \|\|
      &&
      \|
      ^
      &
      == !=
      < > <= >=
      >> <<
      + -
      * / %
      \( \)
      ++ -- sizeof
      & * + - ~ !
      [ ] \. ->
      ))

  (defconstant +keywords+
    '(\;
      case default
      { }
      if else switch
      while do for
      goto continue break return
      ))
  )

(defvar *enum-symbols* nil)

(defun list-lexer (list)
  #'(lambda ()
      (let ((value (pop list)))
	(cond ((null value)
	       (values nil nil))
	      ((symbolp value)
	       (let ((op (or (member value +operators+
				     :test #'string=
				     :key #'symbol-name)
			     (member value +keywords+
				     :test #'string=
				     :key #'symbol-name)))
		     (en (member value *enum-symbols*)))
		 (cond (op
			;; returns the symbol of our package.
			(values (car op) value))
		       (en
			(values 'enumeration-const value))
		       (t
			(values 'id value)))))
	      ((integerp value)
	       (values 'int-const value))
	      ((characterp value)
	       (values 'char-const value))
	      ((floatp value)
	       (values 'float-const value))
	      ((stringp value)
	       (values 'string value))
	      ((listp value)
	       (values 'lisp-expression value))
	      (t
	       (error "Unexpected value ~S" value))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun lispify-unary (op)
    #'(lambda (_ exp)
	(declare (ignore _))
	`(,op ,exp)))
  
  (defun lispify-binary (op)
    #'(lambda (exp1 _ exp2)
	(declare (ignore _))
	`(,op ,exp1 ,exp2)))

  (defun lispify-augmented-assignment (op)
    #'(lambda (exp1 _ exp2)
	(declare (ignore _))
	(let ((tmp (gensym)))
	  `(let ((,tmp ,exp1))
	     (setf ,exp1
		   (,op ,tmp ,exp2))))))

  (defun pick-2nd (_1 x _3)
    (declare (ignore _1 _3))
    x)

  (defun ash-right (i c)
    (ash i (- c)))

  (defun lispify-loop (body
		       &key (init nil) (cond t) (step nil)
		       (post-test-p nil))
    `(tagbody
      loop-init
	(progn ,init)
	,(if post-test-p
	     '(go loop-body)		; do-while
	     '(go loop-cond))
      loop-body
	(progn ,body)
      loop-cond
	(when (progn ,cond)
	  (progn ,step)
	  (go loop-body))
      loop-end))
  )

(define-parser *expression-parser*
  (:start-symbol stat)

  ;; http://www.swansontec.com/sopc.html
  (:precedence (;; Primary expression
		(:left \( \) [ ] \. -> ++ --)
		;; Unary
		(:right * & + - ! ~ ++ -- #+ignore(typecast) sizeof)
		;; Binary
		(:left * / %)
		(:left + -)
		(:left >> <<)
		(:left < > <= >=)
		(:left == !=)
		(:left &)
		(:left ^)
		(:left \|)
		(:left &&)
		(:left \|\|)
		;; Ternary
		(:right ? \:)
		;; Assignment
		(:right = += -= *= /= %= >>= <<= &= ^= \|=)
		;; Comma
		(:left \,)
		))

  ;; http://www.cs.man.ac.uk/~pjj/bnf/c_syntax.bnf
  (:terminals
   #.(append +operators+
	     +keywords+
	     '(enumeration-const id
	       int-const char-const float-const
	       string)
	     '(lisp-expression)))

  (stat
   labeled-stat
   exp-stat
   compound-stat
   selection-stat
   iteration-stat
   jump-stat)

  (labeled-stat
   (id \: stat
       #'(lambda (id _c stat)
	   (declare (ignore _c))
	   ;; TODO: accumulate tags at upper list
	   `(,id			; tagbody's go tag
	     ,stat)))
   (case const-exp \: stat
       #'(lambda (_k  exp _c stat)
	   (declare (ignore _k _c))
	   ;; TODO: accumulate tags at switch
	   `(,exp			; tagbody's go tag
	     ,stat)))
   (default \: stat
       #'(lambda (_k _c stat)
	   (declare (ignore _k _c))
	   ;; TODO: accumulate tags at switch
	   `(default			; tagbody's go tag
	     ,stat))))

  (exp-stat
   (exp \;
	#'(lambda (exp term)
	    (declare (ignore term))
	    exp))
   (\;
    #'(lambda (term)
	(declare (ignore term))
	nil)))

  (compound-stat
   ;; ({ decl-list stat-list })
   ({ stat-list }
      #'(lambda (op1 sts op2)
	  (declare (ignore op1 op2))
	  `(tagbody ,@sts)))
   ;; ({ decl-list	})
   ({ }
      #'(lambda (op1 op2)
	  (declare (ignore op1 op2))
	  '(tagbody))))

  (stat-list
   (stat
    #'list)
   (stat-list stat
	      #'(lambda (sts st)
		  (append sts (list st)))))

  (selection-stat
   (if \( exp \) stat
       #'(lambda (op lp exp rp stat)
	   (declare (ignore op lp rp))
	   `(if ,exp ,stat)))
   (if \( exp \) stat else stat
       #'(lambda (op lp exp rp stat1 el stat2)
	   (declare (ignore op lp rp el))
	   `(if ,exp ,stat1 ,stat2)))
   (switch \( exp \) stat
	   #'(lambda (_k _lp exp _rp stat)
	       (declare (ignore _k _lp _rp))
	       ;; TODO:
	       ;; 1. collect tags of case clause
	       ;; 2. create jump table here
	       nil)))

  (iteration-stat
   (while \( exp \) stat
	  #'(lambda (_k _lp cond _rp body)
	      (declare (ignore _k _lp _rp))
	      (lispify-loop body :cond cond)))
   (do stat while \( exp \) \;
     #'(lambda (_k1 cond _k2 _lp body _rp _t)
	 (declare (ignore _k1 _k2 _lp _rp _t))
	 (lispify-loop body :cond cond :post-test-p t)))
   (for \( exp \; exp \; exp \) stat
	#'(lambda (_k _lp init _t1 cond _t2 step _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :init init :cond cond :step step)))
   (for \( exp \; exp \;     \) stat
	#'(lambda (_k _lp init _t1 cond _t2      _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :init init :cond cond)))
   (for \( exp \;     \; exp \) stat
	#'(lambda (_k _lp init _t1      _t2 step _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :init init :step step)))
   (for \( exp \;     \;     \) stat
	#'(lambda (_k _lp init _t1      _t2      _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :init init)))
   (for \(     \; exp \; exp \) stat
	#'(lambda (_k _lp      _t1 cond _t2 step _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :cond cond :step step)))
   (for \(     \; exp \;     \) stat
	#'(lambda (_k _lp      _t1 cond _t2      _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :cond cond)))
   (for \(     \;     \; exp \) stat
	#'(lambda (_k _lp      _t1      _t2 step _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body :step step)))
   (for \(     \;     \;     \) stat
	#'(lambda (_k _lp      _t1      _t2      _rp body)
	    (declare (ignore _k _lp _t1 _t2 _rp))
	    (lispify-loop body))))

  (jump-stat
   (goto id \;
	 #'(lambda (_k id _t)
	     (declare (ignore _k _t))
	     `(go ,id)))
   (continue \;
	     #'(lambda (_k _t)
		 (declare (ignore _k _t))
		 '(go loop-cond)))	; see lispify-loop
   (break \;
	  #'(lambda (_k _t)
	      (declare (ignore _k _t))
	      '(go loop-end)))		; see lispify-loop
   (return exp \;
	   #'(lambda (_k exp _t)
	       (declare (ignore _k _t))
	       `(return ,exp)))		; TODO: use our block
   (return \;
	   #'(lambda (_k _t)
	       (declare (ignore _k _t))
	       `(return (values)))))	; TODO: use our block


  (exp
   assignment-exp
   (exp |,| assignment-exp
	(lispify-binary 'progn)))

  ;; 'assignment-operator' is included here
  (assignment-exp
   conditional-exp
   (unary-exp = assignment-exp
	      #'(lambda (exp1 op exp2)
		  (declare (ignore op))
		  `(setf ,exp1 ,exp2)))
   (unary-exp *= assignment-exp
	      (lispify-augmented-assignment '*))
   (unary-exp /= assignment-exp
	      (lispify-augmented-assignment '/))
   (unary-exp %= assignment-exp
	      (lispify-augmented-assignment 'mod))
   (unary-exp += assignment-exp
	      (lispify-augmented-assignment '+))
   (unary-exp -= assignment-exp
	      (lispify-augmented-assignment '-))
   (unary-exp <<= assignment-exp
	      (lispify-augmented-assignment 'ash))
   (unary-exp >>= assignment-exp
	      (lispify-augmented-assignment 'ash-right))
   (unary-exp &= assignment-exp
	      (lispify-augmented-assignment 'logand))
   (unary-exp ^= assignment-exp
	      (lispify-augmented-assignment 'logxor))
   (unary-exp \|= assignment-exp
	      (lispify-augmented-assignment 'logior)))

  (conditional-exp
   logical-or-exp
   (logical-or-exp ? exp |:| conditional-exp
		   #'(lambda (cnd op1 then-exp op2 else-exp)
		       (declare (ignore op1 op2))
		       `(if ,cnd ,then-exp ,else-exp))))

  ;; TODO
  (const-exp
   conditional-exp)

  (logical-or-exp
   logical-and-exp
   (logical-or-exp \|\| logical-and-exp
		   (lispify-binary 'or)))

  (logical-and-exp
   inclusive-or-exp
   (logical-and-exp && inclusive-or-exp
		    (lispify-binary 'and)))

  (inclusive-or-exp
   exclusive-or-exp
   (inclusive-or-exp \| exclusive-or-exp
		     (lispify-binary 'logior)))

  (exclusive-or-exp
   and-exp
   (exclusive-or-exp ^ and-exp
		     (lispify-binary 'logxor)))

  (and-exp
   equality-exp
   (and-exp & equality-exp
	    (lispify-binary 'logand)))

  (equality-exp
   relational-exp
   (equality-exp == relational-exp
		 (lispify-binary '=))
   (equality-exp != relational-exp
		 (lispify-binary '/=)))

  (relational-exp
   shift-expression
   (relational-exp < shift-expression
		   (lispify-binary '<))
   (relational-exp > shift-expression
		   (lispify-binary '>))
   (relational-exp <= shift-expression
		   (lispify-binary '<=))
   (relational-exp >= shift-expression
		   (lispify-binary '>=)))

  (shift-expression
   additive-exp
   (shift-expression << additive-exp
		     (lispify-binary 'ash))
   (shift-expression >> additive-exp
		     (lispify-binary 'ash-right)))

  (additive-exp
   mult-exp
   (additive-exp + mult-exp
		 (lispify-binary '+))
   (additive-exp - mult-exp
		 (lispify-binary '-)))

  (mult-exp
   cast-exp
   (mult-exp * cast-exp
	     (lispify-binary '*))
   (mult-exp / cast-exp
	     (lispify-binary '/))
   (mult-exp % cast-exp
	     (lispify-binary 'mod)))

  (cast-exp
   unary-exp
   (\( type-name \) cast-exp		; TODO: type-name must be defined
       #'(lambda (op1 type op2 exp)
	   (declare (ignore op1 op2))
	   `(coerce ,exp ',type))))

  ;; 'unary-operator' is included here
  (unary-exp
   postfix-exp
   (++ unary-exp
       (lispify-unary 'incf))
   (-- unary-exp
       (lispify-unary 'decf))
   (& cast-exp)				; TODO
   (* cast-exp)				; TODO
   (+ cast-exp
      (lispify-unary '+))
   (- cast-exp
      (lispify-unary '-))
   (! cast-exp
      (lispify-unary 'not))
   (sizeof unary-exp)			; TODO
   (sizeof \( type-name \)))		; TODO

  (postfix-exp
   primary-exp
   (postfix-exp [ exp ]			; TODO: compound with multi-dimention
		#'(lambda (exp op1 idx op2)
		    (declare (ignore op1 op2))
		    `(aref ,exp ,idx)))
   (postfix-exp \( argument-exp-list \)
		#'(lambda (exp op1 args op2)
		    (declare (ignore op1 op2))
		    `(apply ,exp ,args)))
   (postfix-exp \( \)
		#'(lambda (exp op1 op2)
		    (declare (ignore op1 op2))
		    `(funcall ,exp)))
   (postfix-exp \. id)			 ; TODO
   (postfix-exp -> id)			 ; TODO
   (postfix-exp ++
		#'(lambda (exp op)
		    (declare (ignore op))
		    `(prog1 ,exp (incf ,exp))))
   (postfix-exp --
		#'(lambda (exp op)
		    (declare (ignore op))
		    `(prog1 ,exp (decf ,exp)))))

  (primary-exp
   id
   const
   string
   (\( exp \)
       #'pick-2nd)
   lisp-expression)			; added

  (argument-exp-list
   (assignment-exp
    #'list)
   (argument-exp-list \, assignment-exp
		      #'(lambda (exp1 op exp2)
			  (declare (ignore op))
			  (append exp1 (list exp2)))))

  (const
   int-const
   char-const
   float-const
   enumeration-const)			; TODO
  )

;; (parse-with-lexer (list-lexer '(x * - - 2 + 3 * y)) *expression-parser*)
;; => (+ (* X (- (- 2))) (* 3 Y))	       

(defun c-expression-tranform (form)
  (parse-with-lexer (list-lexer form)
		    *expression-parser*))


(defmacro with-c-syntax (() &body body)
  (c-expression-tranform body))

#|
(with-c-syntax ()
  1 + 2)
3

(defparameter x 0)
(with-c-syntax ()
  while \( x < 100 \)
  x ++ \;
  )

(defparameter i 0)
(with-c-syntax ()
  for \( i = 0 \; i < 100 \; ++ i \)
  (format t "~A~%" i) \;
  )

(defparameter i 0)
(with-c-syntax ()
  for \( i = 0 \; i < 100 \; ++ i \) {
    if \( (oddp i) \)
      continue \;
    if \( i == 50 \)
      break \;
    (format t "~A~%" i) \;
  }
)


(with-c-syntax ()
  {
  goto a \;
  a \:
    return 100 \;
    }
  )
|#
