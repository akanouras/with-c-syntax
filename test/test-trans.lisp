(in-package :with-c-syntax)

;;; translation-unit

(defun test-trans-decl-simple ()
  (eval-equal nil ()
    int a \; )
  (eval-equal nil ()
    int a \; int b \; )
  t)

;; TODO: support 'any' entry point
(defun test-trans-fdefinition-simple ()
  (with-c-syntax ()
    int hoge1 \( x \, y \)
      int x \, y \;
    { return x + y \; }
   )
  (assert (= 3 (hoge1 1 2)))

  (with-c-syntax ()
    hoge2 \( x \, y \)
      int x \, y \;
    { return x + y \; }
    )
  (assert (= 3 (hoge2 1 2)))

  (with-c-syntax ()
    int hoge3 \( \)
    { return 3 \; }
    )
  (assert (= 3 (hoge3)))

  (with-c-syntax ()
    int hoge4 \( x \)
    { return x + 4 \; }
    )
  (assert (= 9 (hoge4 5)))

  (with-c-syntax ()
    hoge5 \( \)
    { return 5 \; } 
    )
  (assert (= 5 (hoge5)))

  (with-c-syntax ()
    hoge6 \( x \)
    { return x + 6 \; }
    )
  (assert (= 12 (hoge6 6)))

  (with-c-syntax ()
    hoge7 \( int x \, float y \)
    { return x + y \; }
    )
  (assert (<= 5 (hoge7 5 0.4) 6))

  t)

(defun test-trans ()
  (test-trans-decl-simple)
  (test-trans-fdefinition-simple)
  t)
