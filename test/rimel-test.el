;;; rimel-test.el --- Tests for rimel  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with "make test".  Integration tests drive the real command loop
;; through keyboard macros, so keys travel the same path as typed keys:
;; read_char -> `input-method-function' -> `read-key'.

;;; Code:

(require 'ert)
(require 'rimel)

(defconst rimel-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst rimel-test--user-dir
  (expand-file-name "tmp/rime-user/" rimel-test--dir))

(defvar rimel-test--deployed-count 0)

(defun rimel-test--setup ()
  "Start Rime once for the whole run, with a fresh user directory."
  (unless (and (rimel--module-loaded-p) (rimel-module-started-p))
    (delete-directory rimel-test--user-dir t)
    (make-directory rimel-test--user-dir t)
    (dolist (f (directory-files (expand-file-name "data" rimel-test--dir) t
                                "\\.yaml\\'"))
      (copy-file f rimel-test--user-dir t))
    (setq rimel-user-data-dir rimel-test--user-dir
          rimel-verbose nil)
    (add-hook 'rimel-deployed-hook
              (lambda () (cl-incf rimel-test--deployed-count)))
    (should (rimel--load-module))
    (let ((t0 (float-time)))
      (rimel--start)
      ;; Starting must not wait for the deployment.
      (should (< (- (float-time) t0) 0.5)))
    (should (rimel-wait-for-deployment 120))))

(defmacro rimel-test--with-buffer (&rest body)
  "Run BODY in a fresh buffer with the input method active."
  (declare (indent 0))
  `(progn
     (rimel-test--setup)
     (rimel-module-select-schema "luna_pinyin")
     (with-temp-buffer
       (let ((rimel-candidate-style nil)
             (rimel-interrupt-action 'clear))
         (setq-local rimel-probes nil)
         (switch-to-buffer (current-buffer))
         (activate-input-method "rimel")
         (unwind-protect (progn ,@body)
           (deactivate-input-method))))))

(global-set-key [rimel-test-end] #'ignore)

(defun rimel-test--set-mode (mode)
  "Switch to major MODE with the input method kept working in batch.
After `kill-all-local-variables', Emacs (31.1) keeps a stale C-level
value of the permanent-local `input-method-function' until the
current buffer is swapped out and back in.  Redisplay does that all
the time interactively; batch mode has no redisplay, so do it here.
Quail input methods are affected the same way."
  (funcall mode)
  (let ((buf (current-buffer)))
    (with-temp-buffer (set-buffer buf))))

(defun rimel-test--type (keys)
  "Type KEYS (a `kbd' string) through the command loop.
A sentinel event ends the macro: when the input method consumes the
last key and returns no event (e.g. after DEL empties the
composition), `read_char' would otherwise go on reading from the
terminal, as it does for any input method."
  (execute-kbd-macro (vconcat (kbd keys) [rimel-test-end])))

;;;; Pure unit tests

(ert-deftest rimel-test-event-key ()
  (should (equal (rimel--event-key ?a) '(?a . 0)))
  (should (equal (rimel--event-key ?A) '(?A . 0)))
  (should (equal (rimel--event-key ?\s) '(?\s . 0)))
  (should (equal (rimel--event-key 127) '(#xff08 . 0)))
  (should (equal (rimel--event-key ?\r) '(#xff0d . 0)))
  (should (equal (rimel--event-key ?\t) '(#xff09 . 0)))
  (should (equal (rimel--event-key ?\e) '(#xff1b . 0)))
  (should (equal (rimel--event-key ?\C-n) '(?n . 4)))
  (should (equal (rimel--event-key ?\M-v) '(?v . 8)))
  (should (equal (rimel--event-key ?\C-\M-a) '(?a . 12)))
  (should (equal (rimel--event-key ?中) (cons (+ #x1000000 ?中) 0)))
  (should (equal (rimel--event-key 'left) '(#xff51 . 0)))
  (should (equal (rimel--event-key 'S-left) '(#xff51 . 1)))
  (should (equal (rimel--event-key 'C-return) '(#xff0d . 4)))
  (should (equal (rimel--event-key 'next) '(#xff56 . 0)))
  (should-not (rimel--event-key 'mouse-1))
  (should-not (rimel--event-key '(mouse-1 nil))))

(defun rimel-test--state (&rest plist)
  (let ((v (make-vector 14 nil)))
    (aset v 0 t)
    (aset v 3 (plist-get plist :preedit))
    (aset v 4 (plist-get plist :cursor))
    (aset v 7 (plist-get plist :candidates))
    (aset v 8 (plist-get plist :highlighted))
    (aset v 9 (plist-get plist :page))
    (aset v 10 (plist-get plist :last))
    (aset v 11 (plist-get plist :labels))
    (aset v 12 (plist-get plist :preview))
    v))

(ert-deftest rimel-test-format-candidates ()
  (let ((st (rimel-test--state :preedit "ni hao" :cursor 6
                               :candidates '(("你好") ("妳好" . "nǐ"))
                               :highlighted 0 :page 0 :last nil)))
    (should (equal (substring-no-properties (rimel-format-candidates st))
                   "1.你好 2.妳好 nǐ >"))
    (should (equal (substring-no-properties
                    (rimel-format-candidates st 'vertical t))
                   "ni hao\n1.你好\n2.妳好 nǐ\n>"))
    (let ((s (rimel-format-candidates st)))
      (should (memq 'rimel-highlight-face
                    (ensure-list (get-text-property 2 'face s))))
      (should-not (memq 'rimel-highlight-face
                        (ensure-list (get-text-property 6 'face s))))))
  ;; Caret in the middle, schema labels, later page.
  (let ((st (rimel-test--state :preedit "ni hao" :cursor 2
                               :candidates '(("你")) :labels '("a")
                               :highlighted 0 :page 1 :last t)))
    (should (equal (substring-no-properties (rimel-format-candidates st nil t))
                   "ni| hao a.你 <"))))

(ert-deftest rimel-test-inline-preedit ()
  (let ((st (rimel-test--state :preedit "ni hao" :cursor 2 :preview "你好")))
    (let ((rimel-inline-preedit 'raw))
      (let ((s (rimel--preedit-string st)))
        (should (equal (substring-no-properties s) "ni hao"))
        (should (get-text-property 2 'cursor s))
        (should-not (get-text-property 1 'cursor s))))
    (let ((rimel-inline-preedit 'preview))
      (should (equal (substring-no-properties (rimel--preedit-string st))
                     "你好")))
    (let ((rimel-inline-preedit nil))
      (should-not (rimel--preedit-string st)))))

(ert-deftest rimel-test-probes ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(foo ")
    (should (rimel-probe-program))
    (insert "\"str ")
    (should-not (rimel-probe-program))
    (erase-buffer)
    (insert ";; comment ")
    (should-not (rimel-probe-program)))
  (with-temp-buffer
    (text-mode)
    (should-not (rimel-probe-program))
    (insert "abc")
    (should (rimel-probe-after-alphanumeric))
    (should (rimel-probe-after-ascii))
    (insert "中")
    (should-not (rimel-probe-after-alphanumeric))
    (should (eq (rimel-probe-after-cjk) 'rime))
    (let ((rimel-probe-key ?A)) (should (rimel-probe-uppercase)))
    (let ((rimel-probe-key ?a)) (should-not (rimel-probe-uppercase)))
    (insert "x")
    (let ((rimel-probe-key ?,)) (should (rimel-probe-punctuation-after-ascii)))
    (let ((rimel-probe-key ?b))
      (should-not (rimel-probe-punctuation-after-ascii)))))

(ert-deftest rimel-test-probe-protocol ()
  (with-temp-buffer
    ;; First non-nil verdict wins; `rime' means "send to Rime".
    (let ((rimel-probes (list (lambda () nil) (lambda () 'rime)
                              (lambda () t))))
      (should-not (rimel--probe-ascii-p ?a)))
    (let ((rimel-probes (list (lambda () nil) (lambda () t))))
      (should (rimel--probe-ascii-p ?a)))
    (let ((rimel-probes (list (lambda () (eq rimel-probe-key ?x)))))
      (should (rimel--probe-ascii-p ?x))
      (should-not (rimel--probe-ascii-p ?y)))))

(ert-deftest rimel-test-notification-filter ()
  (let ((seen nil))
    (cl-letf (((symbol-function 'rimel--handle-notification)
               (lambda (type value) (push (cons type value) seen))))
      (let ((proc (make-pipe-process :name "rimel-test-pipe" :noquery t)))
        (unwind-protect
            (progn
              (rimel--notify-filter proc "deploy\tsta")
              (should-not seen)
              (rimel--notify-filter proc "rt\nschema\tluna_pinyin/朙月\nopt")
              (should (equal (nreverse seen)
                             '(("deploy" . "start")
                               ("schema" . "luna_pinyin/朙月"))))
              (should (equal (process-get proc 'pending) "opt")))
          (delete-process proc))))))

;;;; Integration tests (real librime, real command loop)

(ert-deftest rimel-test-async-deploy-notification ()
  (rimel-test--setup)
  ;; The notification pipe delivered at least the initial deployment.
  (should (>= rimel-test--deployed-count 1))
  (should (assoc "luna_pinyin" (rimel-module-schema-list))))

(ert-deftest rimel-test-input-method-registered ()
  (should (assoc "rimel" input-method-alist))
  (rimel-test--with-buffer
    (should (equal current-input-method "rimel"))
    (should (eq input-method-function #'rimel-input-method))))

(ert-deftest rimel-test-basic-commit ()
  (rimel-test--with-buffer
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "你好"))
    (rimel-test--type "z h o n g g u o SPC")
    (should (equal (buffer-string) "你好中國"))))

(ert-deftest rimel-test-select-by-number ()
  (rimel-test--with-buffer
    (rimel-test--type "n i h a o 2")
    (should (equal (buffer-string) "妳好"))))

(ert-deftest rimel-test-backspace-and-escape ()
  (rimel-test--with-buffer
    (rimel-test--type "n i h a o o DEL SPC")
    (should (equal (buffer-string) "你好"))
    (rimel-test--type "n i h a o <escape>")
    (should (equal (buffer-string) "你好"))
    (rimel-test--type "n DEL")
    (should (equal (buffer-string) "你好"))))

(ert-deftest rimel-test-return-commits-raw ()
  (rimel-test--with-buffer
    (rimel-test--type "n i h a o RET")
    (should (equal (buffer-string) "nihao"))))

(ert-deftest rimel-test-punctuation-and-passthrough ()
  (rimel-test--with-buffer
    (rimel-test--type ",")
    (should (equal (buffer-string) "，"))
    ;; Keys Rime ignores outside a composition are inserted as is.
    (rimel-test--type "1 SPC")
    (should (equal (buffer-string) "，1 "))))

(ert-deftest rimel-test-navigation-keys ()
  (rimel-test--with-buffer
    ;; Down highlights the next candidate, SPC commits it.
    (rimel-test--type "n i h a o <down> SPC")
    (should (equal (buffer-string) "妳好"))
    ;; Emacs-style C-n is bound by Rime's default key binder.
    (erase-buffer)
    (rimel-test--type "n i h a o C-n SPC")
    (should (equal (buffer-string) "妳好"))))

(ert-deftest rimel-test-ctrl-g-cancels ()
  (rimel-test--with-buffer
    (rimel-test--type "n i h a o C-g")
    (should (equal (buffer-string) ""))
    (should-not quit-flag)
    (should-not (rimel-module-input))))

(ert-deftest rimel-test-interrupt-actions ()
  ;; M-< is ignored by Rime (unlike C-a, which its default key binder
  ;; maps to Home inside the composition), so it interrupts.
  (rimel-test--with-buffer
    (insert "x")
    (rimel-test--type "n i h a o M-<")
    ;; Composition discarded and M-< executed.
    (should (equal (buffer-string) "x"))
    (should (= (point) 1))
    (should-not (rimel-module-input)))
  (rimel-test--with-buffer
    (let ((rimel-interrupt-action 'commit-raw))
      (rimel-test--type "n i h a o M-<")
      (should (equal (buffer-string) "nihao"))
      (should (= (point) 1))))
  (rimel-test--with-buffer
    (let ((rimel-interrupt-action 'commit))
      (rimel-test--type "n i h a o M-<")
      (should (equal (buffer-string) "你好"))
      (should (= (point) 1)))))

(ert-deftest rimel-test-no-buffer-modification-while-composing ()
  (rimel-test--with-buffer
    (let ((changes 0)
          (seen-preedit nil))
      (add-hook 'after-change-functions (lambda (&rest _) (cl-incf changes))
                nil t)
      (cl-letf* ((orig (symbol-function 'rimel--render))
                 ((symbol-function 'rimel--render)
                  (lambda (st)
                    (funcall orig st)
                    (when (overlayp rimel--preedit-overlay)
                      (setq seen-preedit
                            (overlay-get rimel--preedit-overlay
                                         'before-string))))))
        (rimel-test--type "n i h a o"))
      (should (equal (substring-no-properties seen-preedit) "ni hao"))
      ;; Nothing was inserted while composing (the preedit is an
      ;; overlay); the composition is discarded at the end of the macro.
      (should (= changes 0))
      (should (equal (buffer-string) ""))
      (should-not rimel--preedit-overlay))))

(ert-deftest rimel-test-probes-switch-input ()
  (rimel-test--with-buffer
    (rimel-test--set-mode #'emacs-lisp-mode)
    (setq-local rimel-probes '(rimel-probe-program))
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "nihao "))
    (insert ";; ")
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "nihao ;; 你好"))))

(ert-deftest rimel-test-probe-only-at-composition-start ()
  (rimel-test--with-buffer
    ;; ASCII after a letter -- but keys inside a composition are never
    ;; probed, so "nihao" is composed as a whole.
    (setq-local rimel-probes '(rimel-probe-after-alphanumeric))
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "你好"))
    (insert "a")
    (rimel-test--type "b c")
    (should (equal (buffer-string) "你好abc"))))

(ert-deftest rimel-test-force-rime ()
  (rimel-test--with-buffer
    (setq-local rimel-probes (list (lambda () t)))
    (rimel-test--type "n")
    (should (equal (buffer-string) "n"))
    (rimel-force-rime)
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "n你好"))
    (should-not rimel--force-rime)))

(ert-deftest rimel-test-ascii-mode ()
  (rimel-test--with-buffer
    (rimel-toggle-ascii-mode)
    (unwind-protect
        (progn
          (rimel-test--type "n i h a o")
          (should (equal (buffer-string) "nihao")))
      (rimel-module-set-option "ascii_mode" nil))))

(ert-deftest rimel-test-commit-while-composing-replay ()
  ;; In the test schema, "aa" has two candidates and codes are at most
  ;; 2 keys long, so a third key commits 工 and starts a new
  ;; composition ("顶字上屏").  The rest of the input must be re-fed.
  (rimel-test--setup)
  (rimel-module-select-schema "rimel_test")
  (unwind-protect
      (with-temp-buffer
        (let ((rimel-probes (list (lambda () t))) ; replay must skip probes
              (rimel-candidate-style nil))
          (switch-to-buffer (current-buffer))
          (activate-input-method "rimel")
          (rimel-force-rime)
          (rimel-test--type "a a b b")
          (should (equal (buffer-string) "工以"))
          (deactivate-input-method)))
    (rimel-module-select-schema "luna_pinyin")))

(ert-deftest rimel-test-keyboard-macro-roundtrip ()
  ;; Keys read inside the composition loop are recorded once, so a
  ;; recorded macro replays to the same text.
  (rimel-test--with-buffer
    (rimel-test--type "n i h a o SPC")
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "你好你好"))))

(ert-deftest rimel-test-candidate-function-called ()
  (rimel-test--with-buffer
    (let* ((calls nil)
           (rimel-candidate-style (lambda (st) (push (and st t) calls))))
      ;; Rendering is skipped while a macro runs; call it directly.
      (rimel-module-process-key ?n 0)
      (let ((executing-kbd-macro nil))
        (cl-letf (((symbol-function 'input-pending-p) #'ignore))
          (rimel--render (rimel-module-state))))
      (rimel--clear-ui)
      (rimel-module-clear-composition)
      (should (equal calls '(nil t))))))

(ert-deftest rimel-test-render-skipped-when-input-pending ()
  (rimel-test--with-buffer
    (let* ((calls 0)
           (rimel-candidate-style (lambda (st) (when st (cl-incf calls)))))
      (rimel-module-process-key ?n 0)
      (let ((executing-kbd-macro nil))
        (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
          (rimel--render (rimel-module-state))))
      (rimel-module-clear-composition)
      (should (= calls 0)))))

(ert-deftest rimel-test-minibuffer-display ()
  (rimel-test--with-buffer
    (should-not (minibufferp))
    (rimel-module-process-key ?n 0)
    (rimel-module-process-key ?i 0)
    (let ((st (rimel-module-state)))
      (rimel-show-minibuffer st)
      ;; `current-message' is always nil in batch mode.
      (should (string-match-p "1\\.你" rimel--echo-message))
      (rimel-show-minibuffer nil)
      (should-not rimel--echo-message))
    (rimel-module-clear-composition)))

(ert-deftest rimel-test-posframe-falls-back-to-minibuffer ()
  ;; No graphical display in batch mode: posframe style must still work.
  (rimel-test--with-buffer
    (rimel-module-process-key ?n 0)
    (rimel-show-posframe (rimel-module-state))
    (should (string-match-p "1\\." rimel--echo-message))
    (rimel-show-posframe nil)
    (rimel-module-clear-composition)))

(ert-deftest rimel-test-posframe-show-and-hide ()
  ;; Batch mode has no graphical frames: stub posframe and check the
  ;; arguments rimel passes to it.
  (rimel-test--with-buffer
    (insert "abc")
    (let ((shown nil) (hidden nil)
          (rimel-candidate-layout 'vertical)
          (rimel-posframe-properties '(:internal-border-width 3)))
      (cl-letf (((symbol-function 'rimel--posframe-usable-p) (lambda () t))
                ((symbol-function 'posframe-show)
                 (lambda (buf &rest args)
                   (get-buffer-create buf)
                   (setq shown (cons buf args))))
                ((symbol-function 'posframe-hide)
                 (lambda (buf) (setq hidden buf))))
        (rimel-module-process-key ?n 0)
        (rimel-show-posframe (rimel-module-state))
        (should (equal (car shown) rimel--posframe-buffer))
        (should (= (plist-get (cdr shown) :position) (point)))
        (should (= (plist-get (cdr shown) :internal-border-width) 3))
        (should (string-match-p "\\`1\\.你\n2\\."
                                (plist-get (cdr shown) :string)))
        (rimel-show-posframe nil)
        (should (equal hidden rimel--posframe-buffer))
        (rimel-module-clear-composition)))))

(ert-deftest rimel-test-echo-area-mode ()
  ;; With `input-method-use-echo-area' (e.g. isearch), the preedit is
  ;; shown in the echo area rather than as an overlay.
  (rimel-test--with-buffer
    (rimel-module-process-key ?n 0)
    (let ((input-method-use-echo-area t))
      (rimel--render (rimel-module-state))
      (should-not rimel--preedit-overlay)
      (should (string-prefix-p "n " rimel--echo-message)))
    (rimel--clear-ui)
    (rimel-module-clear-composition)))

(ert-deftest rimel-test-read-only-passthrough ()
  (rimel-test--with-buffer
    (insert "abc")
    (setq buffer-read-only t)
    (should (equal (rimel-input-method ?n) '(?n)))
    (should-not (rimel-module-input))))

(ert-deftest rimel-test-background-deploy-does-not-block ()
  (rimel-test--with-buffer
    (let ((t0 (float-time)))
      (rimel-module-deploy)
      ;; Typing during a deployment never waits for it: keys are
      ;; inserted as is until Rime is back.
      (rimel-test--type "n")
      (should (< (- (float-time) t0) 0.5)))
    (should (rimel-wait-for-deployment 120))
    (erase-buffer)
    (rimel-test--type "n i h a o SPC")
    (should (equal (buffer-string) "你好"))))

(ert-deftest rimel-test-schema-commands ()
  (rimel-test--setup)
  (rimel-select-schema "luna_pinyin")
  (should (equal (rimel-module-current-schema) "luna_pinyin"))
  (should-error (rimel-select-schema "no_such_schema") :type 'user-error))

(ert-deftest rimel-test-performance ()
  (rimel-test--with-buffer
    (let* ((n 200)
           (keys (string-join (make-list n "n i h a o SPC") " "))
           (t0 (float-time)))
      (rimel-test--type keys)
      (let ((per-key (/ (- (float-time) t0) (* n 6))))
        (message "rimel: %.1f us per key through the command loop"
                 (* per-key 1e6))
        (should (= (length (buffer-string)) (* n 2)))
        ;; Generous bound: a key must cost far less than a frame.
        (should (< per-key 0.002))))))

(provide 'rimel-test)
;;; rimel-test.el ends here
