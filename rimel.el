;;; rimel.el --- Rime input method via librime and a native module  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Tau

;; Author: Tau
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: i18n, input method, chinese
;; URL: https://github.com/Tao-Boy/rimel
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Rimel is a Rime (中州韻輸入法引擎) input method for Emacs.  It talks to
;; librime through a small native dynamic module (rimel-module.c) and
;; plugs into Emacs as an ordinary input method: it is registered with
;; `register-input-method' and works through `input-method-function',
;; exactly like the built-in Quail input methods.  It does not use
;; `post-self-insert-hook' or any other insertion hook, and it never
;; modifies the buffer while composing: the preedit is an overlay.
;;
;; Highlights:
;;
;; - Probes (`rimel-probes'): functions that look at the context around
;;   point and decide whether the next key should be typed as plain
;;   ASCII or go to Rime, e.g. English inside code but Chinese inside
;;   comments and strings.
;;
;; - Candidates can be shown in a child frame (posframe), in the echo
;;   area/minibuffer, or by any function of your own
;;   (`rimel-candidate-style').
;;
;; - Asynchronous: deployment, dictionary compilation and user data sync
;;   run in librime's maintenance thread; the result is delivered
;;   through a pipe process, so Emacs never waits for it.  Each key
;;   costs a single module call, and candidate rendering is skipped
;;   while more input is already pending.
;;
;; Quick start:
;;
;;   (require 'rimel)
;;   (setq default-input-method "rimel")
;;
;; then toggle with C-\.  See README.org for more.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function posframe-show "ext:posframe")
(declare-function posframe-hide "ext:posframe")
(declare-function posframe-workable-p "ext:posframe")
(declare-function org-in-src-block-p "org")
(declare-function org-inside-LaTeX-fragment-p "org")
(declare-function texmathp "ext:texmathp")

;; Defined by the dynamic module.
(declare-function rimel-module-start "rimel-module")
(declare-function rimel-module-finalize "rimel-module")
(declare-function rimel-module-started-p "rimel-module")
(declare-function rimel-module-maintenance-p "rimel-module")
(declare-function rimel-module-deploy "rimel-module")
(declare-function rimel-module-sync-user-data "rimel-module")
(declare-function rimel-module-process-key "rimel-module")
(declare-function rimel-module-state "rimel-module")
(declare-function rimel-module-select-candidate "rimel-module")
(declare-function rimel-module-delete-candidate "rimel-module")
(declare-function rimel-module-change-page "rimel-module")
(declare-function rimel-module-clear-composition "rimel-module")
(declare-function rimel-module-commit-composition "rimel-module")
(declare-function rimel-module-input "rimel-module")
(declare-function rimel-module-get-option "rimel-module")
(declare-function rimel-module-set-option "rimel-module")
(declare-function rimel-module-schema-list "rimel-module")
(declare-function rimel-module-current-schema "rimel-module")
(declare-function rimel-module-select-schema "rimel-module")
(declare-function rimel-module-version "rimel-module")

(defgroup rimel nil
  "Rime input method based on librime."
  :group 'leim
  :prefix "rimel-")

(defconst rimel--root
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing rimel.el.")

;;;; Customization

(defcustom rimel-title "ㄓ"
  "Mode line title of the input method."
  :type 'string)

(defcustom rimel-module-file
  (expand-file-name (concat "rimel-module" module-file-suffix) rimel--root)
  "Path of the compiled dynamic module."
  :type 'file)

(defcustom rimel-emacs-module-header-root nil
  "Directory containing emacs-module.h, or nil to search for it."
  :type '(choice (const :tag "Search" nil) directory))

(defcustom rimel-librime-root nil
  "Prefix of a librime installation (with include/ and lib/), or nil.
When nil the system librime is used, located with pkg-config."
  :type '(choice (const :tag "System" nil) directory))

(defun rimel--default-shared-data-dir ()
  "Return the first existing Rime shared data directory."
  (cl-find-if
   #'file-directory-p
   (list "/usr/share/rime-data"
         "/usr/local/share/rime-data"
         "/run/current-system/sw/share/rime-data"
         "/opt/homebrew/share/rime-data"
         "/Library/Input Methods/Squirrel.app/Contents/SharedSupport"
         (expand-file-name "~/.nix-profile/share/rime-data")
         "/usr/share/rime/data")))

(defcustom rimel-shared-data-dir (rimel--default-shared-data-dir)
  "Rime shared data directory (where the stock schemas live)."
  :type '(choice (const :tag "Unset" nil) directory))

(defcustom rimel-user-data-dir (locate-user-emacs-file "rime/")
  "Rime user data directory (custom config, user dictionaries)."
  :type 'directory)

(defcustom rimel-log-dir nil
  "Directory for librime logs.
nil means the \"log\" subdirectory of `rimel-user-data-dir'."
  :type '(choice (const :tag "Default" nil) directory))

(defcustom rimel-probes nil
  "Probe functions deciding, from the context at point, how to type a key.

Probes are consulted when a key could start a new composition (they
are never consulted in the middle of one).  Each is called with no
argument, in the buffer, with `rimel-probe-key' bound to the key.
The first one to return non-nil decides:

  `rime'           -- send the key to Rime;
  any other value  -- insert the key as is (\"ASCII mode\").

When every probe returns nil the key goes to Rime.  Ordinary
predicates therefore work as probes: returning t means \"type
English here\".  Can be set buffer-locally.  See the built-in
`rimel-probe-*' functions."
  :type '(repeat function))

(defcustom rimel-candidate-style 'posframe
  "How to show the candidate menu.

`posframe'   -- a child frame next to point; needs the posframe
                package and a graphical frame, else falls back to
                `minibuffer';
`minibuffer' -- the echo area (or the end of an active minibuffer);
nil          -- do not show candidates;
a function   -- called with the state vector to show, or nil to hide."
  :type '(choice (const posframe) (const minibuffer) (const :tag "None" nil)
                 function))

(defcustom rimel-inline-preedit 'raw
  "What to show inline at point while composing.

`raw'     -- the preedit as Rime formats it, e.g. \"ni hao\";
`preview' -- the text that would be committed, e.g. \"你好\";
nil       -- nothing inline; the preedit is shown in the candidate menu."
  :type '(choice (const raw) (const preview) (const :tag "None" nil)))

(defcustom rimel-candidate-layout 'horizontal
  "Layout of candidates in the posframe: `horizontal' or `vertical'.
The echo area always uses a single line."
  :type '(choice (const horizontal) (const vertical)))

(defcustom rimel-candidate-labels '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0")
  "Labels used when the schema does not define select keys."
  :type '(repeat string))

(defcustom rimel-interrupt-action 'clear
  "What to do with a composition interrupted by a key Rime ignores.
For example `C-x' while composing.  The key is then executed as usual.

`clear'      -- discard the composition;
`commit'     -- insert the converted text (e.g. 你好);
`commit-raw' -- insert the raw input (e.g. nihao)."
  :type '(choice (const clear) (const commit) (const commit-raw)))

(defcustom rimel-posframe-properties
  '(:internal-border-width 1 :left-fringe 4 :right-fringe 4)
  "Extra properties passed to `posframe-show'."
  :type 'plist)

(defcustom rimel-indicator-refresh nil
  "Non-nil means keep `rimel-indicator' current while moving around.
Emacs re-evaluates the mode line only now and then, so a probe-based
indicator can lag behind point.  When non-nil, a buffer-local
`post-command-hook' refreshes the mode line whenever the indicator
changes.  The hook only reads state; it never inserts text."
  :type 'boolean)

(defcustom rimel-deployed-hook nil
  "Hook run after Rime finished a (background) deployment."
  :type 'hook)

(defcustom rimel-verbose t
  "Whether to report deployment progress in the echo area."
  :type 'boolean)

(defface rimel-preedit-face
  '((t (:inherit default :underline t)))
  "Face of the inline preedit.")

(defface rimel-code-face
  '((t (:inherit font-lock-string-face)))
  "Face of the preedit shown in the candidate menu.")

(defface rimel-candidate-face
  '((t (:inherit default)))
  "Face of candidates.")

(defface rimel-highlight-face
  '((t (:inherit highlight)))
  "Face of the highlighted candidate.")

(defface rimel-label-face
  '((t (:inherit shadow)))
  "Face of candidate labels.")

(defface rimel-comment-face
  '((t (:inherit font-lock-comment-face)))
  "Face of candidate comments.")

(defface rimel-posframe-face
  '((((background dark)) (:background "#333333" :foreground "#dcdccc"))
    (t (:background "#f6f6f6" :foreground "#333333")))
  "Face whose colors are used for the posframe.")

(defface rimel-posframe-border-face
  '((t (:inherit shadow)))
  "Face whose foreground is the posframe border color.")

(defface rimel-indicator-ascii-face
  '((t (:inherit shadow)))
  "Face of the indicator when keys are typed as ASCII.")

;;;; State vector (built by the module, see rimel-module.c)

(defsubst rimel--st-handled (st) (aref st 0))
(defsubst rimel--st-commit (st) (aref st 1))
(defsubst rimel--st-input (st) (aref st 2))
(defsubst rimel--st-preedit (st) (aref st 3))
(defsubst rimel--st-cursor (st) (aref st 4))
(defsubst rimel--st-sel-start (st) (aref st 5))
(defsubst rimel--st-sel-end (st) (aref st 6))
(defsubst rimel--st-candidates (st) (aref st 7))
(defsubst rimel--st-highlighted (st) (aref st 8))
(defsubst rimel--st-page-no (st) (aref st 9))
(defsubst rimel--st-last-page-p (st) (aref st 10))
(defsubst rimel--st-labels (st) (aref st 11))
(defsubst rimel--st-preview (st) (aref st 12))
(defsubst rimel--st-ascii-mode (st) (aref st 13))

(defsubst rimel--st-composing-p (st)
  "Return non-nil if ST has a composition in progress."
  (and st (rimel--st-preedit st)))

;;;; Module loading and building

(defvar rimel--compile-process nil)

(defun rimel--module-loaded-p ()
  (featurep 'rimel-module))

(defun rimel--load-module ()
  "Load the module if it is built.  Return non-nil on success."
  (or (rimel--module-loaded-p)
      (and (file-exists-p rimel-module-file)
           (progn (module-load rimel-module-file) t))))

(defvar rimel--emacs-bin-dir
  (file-name-directory
   (file-truename (expand-file-name invocation-name invocation-directory)))
  "Directory of the running Emacs binary, symlinks resolved.")

(defun rimel--emacs-include-dir ()
  (or rimel-emacs-module-header-root
      (cl-find-if
       (lambda (d) (file-exists-p (expand-file-name "emacs-module.h" d)))
       (list (expand-file-name "../include" rimel--emacs-bin-dir)
             (expand-file-name "../../include" rimel--emacs-bin-dir)
             (expand-file-name "../src" rimel--emacs-bin-dir)
             (expand-file-name "include" installation-directory)
             (expand-file-name "src" source-directory)
             "/usr/include" "/usr/local/include" "/opt/homebrew/include"))))

;;;###autoload
(defun rimel-compile-module (&optional callback)
  "Build the dynamic module in the background with make.
CALLBACK, if non-nil, is called with no argument once the module is
built and loaded."
  (interactive)
  (when (process-live-p rimel--compile-process)
    (user-error "Rimel: the module is already being built"))
  (let* ((default-directory rimel--root)
         (include (rimel--emacs-include-dir))
         (buffer (get-buffer-create "*rimel-compile*"))
         (command (append
                   (list "make" "module"
                         (concat "MODULE=" (file-name-nondirectory
                                            rimel-module-file)))
                   (when include (list (concat "EMACS_INCLUDE_DIR=" include)))
                   (when rimel-librime-root
                     (list (concat "LIBRIME_ROOT="
                                   (expand-file-name rimel-librime-root)))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer))
      (insert (string-join command " ") "\n"))
    (message "Rimel: building the module...")
    (setq rimel--compile-process
          (make-process
           :name "rimel-compile" :buffer buffer :command command
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (if (and (eq (process-status proc) 'exit)
                        (zerop (process-exit-status proc))
                        (rimel--load-module))
                   (progn (message "Rimel: module built")
                          (when callback (funcall callback)))
                 (display-buffer (process-buffer proc))
                 (message "Rimel: building the module failed, see %s"
                          (buffer-name (process-buffer proc))))))))))

;;;; Lifecycle

(defvar rimel--notify-process nil
  "Pipe process receiving librime notifications.")

(defvar rimel--schema-name nil
  "Name of the current schema, as reported by librime.")

(defvar rimel--deploy-callbacks nil
  "Functions to call once the running deployment has finished.")

(defun rimel--notify-filter (proc string)
  "Handle librime notifications STRING from PROC, one per line."
  (let ((pending (concat (or (process-get proc 'pending) "") string))
        (start 0))
    (while (string-match "\n" pending start)
      (let* ((line (substring pending start (match-beginning 0)))
             (tab (string-search "\t" line)))
        (setq start (match-end 0))
        (when tab
          (rimel--handle-notification (substring line 0 tab)
                                      (substring line (1+ tab))))))
    (process-put proc 'pending (substring pending start))))

(defun rimel--handle-notification (type value)
  "Act on the librime notification TYPE with VALUE."
  (pcase type
    ("deploy"
     (pcase value
       ("start" (when rimel-verbose (message "Rime: deploying...")))
       ("success"
        (when rimel-verbose (message "Rime: ready"))
        (rimel--deployed))
       ("failure"
        (display-warning
         'rimel (format "Rime deployment failed, see the logs in %s"
                        (rimel--log-dir)))
        (rimel--deployed))))
    ("schema"
     (setq rimel--schema-name
           (let ((slash (string-search "/" value)))
             (if slash (substring value (1+ slash)) value)))
     (force-mode-line-update t))
    ("option" (force-mode-line-update t))))

(defun rimel--deployed ()
  (let ((callbacks (nreverse rimel--deploy-callbacks)))
    (setq rimel--deploy-callbacks nil)
    (mapc #'funcall callbacks))
  (run-hooks 'rimel-deployed-hook)
  (force-mode-line-update t))

(defun rimel--log-dir ()
  (or rimel-log-dir (expand-file-name "log" rimel-user-data-dir)))

(defun rimel--start ()
  "Start librime unless already running.  Never blocks on deployment."
  (unless (and (rimel--module-loaded-p) (rimel-module-started-p))
    (unless rimel-shared-data-dir
      (user-error "Rimel: no Rime shared data found, set `rimel-shared-data-dir'"))
    (make-directory rimel-user-data-dir t)
    (make-directory (rimel--log-dir) t)
    (unless (process-live-p rimel--notify-process)
      (setq rimel--notify-process
            (make-pipe-process :name "rimel-notify" :buffer nil
                               :coding 'utf-8 :noquery t
                               :filter #'rimel--notify-filter)))
    (rimel-module-start (expand-file-name rimel-shared-data-dir)
                        (expand-file-name rimel-user-data-dir)
                        (expand-file-name (rimel--log-dir))
                        rimel--notify-process)
    (add-hook 'kill-emacs-hook #'rimel--shutdown)))

(defun rimel--shutdown ()
  (when (and (rimel--module-loaded-p) (rimel-module-started-p))
    (rimel-module-finalize))
  (when (process-live-p rimel--notify-process)
    (delete-process rimel--notify-process))
  (setq rimel--notify-process nil))

(defun rimel--ensure-started ()
  "Load the module (building it if needed) and start librime."
  (cond
   ((rimel--load-module) (rimel--start))
   ((process-live-p rimel--compile-process))
   ((or noninteractive
        (y-or-n-p "Rimel: the native module is not built.  Build it now? "))
    (rimel-compile-module #'rimel--start))))

(defun rimel-ready-p ()
  "Return non-nil if Rime can process keys right now."
  (and (rimel--module-loaded-p)
       (rimel-module-started-p)
       (not (rimel-module-maintenance-p))))

(defun rimel-wait-for-deployment (&optional timeout)
  "Wait until a background deployment finishes, at most TIMEOUT seconds.
Return non-nil if Rime is ready.  Meant for scripts and tests;
interactive use never needs to wait."
  (let ((deadline (+ (float-time) (or timeout 60))))
    (while (and (rimel--module-loaded-p) (rimel-module-maintenance-p)
                (< (float-time) deadline))
      (accept-process-output rimel--notify-process 0.05))
    ;; Drain the notifications produced at the end of the deployment.
    (when (process-live-p rimel--notify-process)
      (accept-process-output rimel--notify-process 0.05))
    (rimel-ready-p)))

;;;; Key translation

(defconst rimel--keysyms
  '((backspace . #xff08) (tab . #xff09) (return . #xff0d) (escape . #xff1b)
    (delete . #xffff) (deletechar . #xffff) (home . #xff50) (left . #xff51)
    (up . #xff52) (right . #xff53) (down . #xff54) (prior . #xff55)
    (next . #xff56) (end . #xff57) (begin . #xff58) (insert . #xff63)
    (kp-enter . #xff8d) (kp-home . #xff95) (kp-left . #xff96) (kp-up . #xff97)
    (kp-right . #xff98) (kp-down . #xff99) (kp-prior . #xff9a)
    (kp-next . #xff9b) (kp-end . #xff9c) (kp-delete . #xff9f)
    (iso-lefttab . #xfe20) (backtab . #xfe20)
    (f1 . #xffbe) (f2 . #xffbf) (f3 . #xffc0) (f4 . #xffc1) (f5 . #xffc2)
    (f6 . #xffc3) (f7 . #xffc4) (f8 . #xffc5) (f9 . #xffc6) (f10 . #xffc7)
    (f11 . #xffc8) (f12 . #xffc9))
  "Emacs function keys and their X11 keysyms.")

(defconst rimel--modifier-masks
  '((shift . #x1) (control . #x4) (meta . #x8) (alt . #x8)
    (super . #x4000000) (hyper . #x8000000))
  "Emacs modifiers and the corresponding Rime modifier masks.")

(defsubst rimel--char-keysym (char)
  (if (< char #x100) char (+ #x1000000 char)))

(defun rimel--mask (modifiers)
  (let ((mask 0))
    (dolist (m modifiers mask)
      (setq mask (logior mask (alist-get m rimel--modifier-masks 0))))))

(defun rimel--event-key (event)
  "Translate EVENT to (KEYSYM . MASK) for librime, or nil."
  (cond
   ((integerp event)
    (pcase event
      (127 '(#xff08 . 0))
      (9 '(#xff09 . 0))
      (13 '(#xff0d . 0))
      (27 '(#xff1b . 0))
      ((pred (lambda (c) (and (characterp c) (>= c 32))))
       (cons (rimel--char-keysym event) 0))
      (_
       (let* ((mods (event-modifiers event))
              (base (event-basic-type event)))
         (when (characterp base)
           (when (and (memq 'shift mods) (<= ?a base ?z))
             (setq base (upcase base)))
           (cons (rimel--char-keysym base) (rimel--mask mods)))))))
   ((symbolp event)
    ;; `event-basic-type' does not know every function key (it returns
    ;; nil for `C-return'), so strip the modifier prefixes ourselves.
    (let ((keysym (alist-get (intern (replace-regexp-in-string
                                      "\\`\\([ACHMSs]-\\)+" ""
                                      (symbol-name event)))
                             rimel--keysyms)))
      (when keysym
        (cons keysym (rimel--mask (event-modifiers event))))))))

;;;; Probes

(defvar rimel-probe-key nil
  "The key being probed, bound while `rimel-probes' run.
It is nil when probes are evaluated for the mode line indicator.")

(defvar rimel--force-rime nil
  "Non-nil means ignore probes for the next composition.")

(defun rimel--probe-ascii-p (key)
  "Return non-nil if the probes say KEY should be typed as is."
  (let ((rimel-probe-key key))
    (cl-loop for probe in rimel-probes
             for verdict = (funcall probe)
             when verdict return (not (eq verdict 'rime)))))

(defun rimel-probe-program ()
  "Probe: ASCII in code, Rime in comments and strings.
Applies to `prog-mode' and `conf-mode' derived buffers."
  (and (derived-mode-p 'prog-mode 'conf-mode)
       (not (nth 8 (syntax-ppss)))))

(defun rimel-probe-after-alphanumeric ()
  "Probe: ASCII right after an ASCII letter or digit."
  (let ((c (char-before)))
    (and c (or (<= ?a c ?z) (<= ?A c ?Z) (<= ?0 c ?9)))))

(defun rimel-probe-after-ascii ()
  "Probe: ASCII right after any non-blank ASCII character."
  (let ((c (char-before)))
    (and c (< 32 c 127))))

(defun rimel-probe-uppercase ()
  "Probe: ASCII when the key itself is an uppercase letter."
  (and rimel-probe-key (<= ?A rimel-probe-key ?Z)))

(defun rimel-probe-punctuation-after-ascii ()
  "Probe: ASCII for punctuation typed right after an ASCII character."
  (and rimel-probe-key
       (< 32 rimel-probe-key 127)
       (not (or (<= ?a rimel-probe-key ?z) (<= ?A rimel-probe-key ?Z)
                (<= ?0 rimel-probe-key ?9)))
       (let ((c (char-before))) (and c (< 32 c 127)))))

(defun rimel-probe-after-cjk ()
  "Probe: force Rime right after a CJK character.
Put it before more aggressive probes to keep typing Chinese in a run
of Chinese text."
  (let ((c (char-before)))
    (and c (memq (aref char-script-table c) '(han cjk-misc)) 'rime)))

(defun rimel-probe-org ()
  "Probe: ASCII in Org source blocks and LaTeX fragments."
  (and (derived-mode-p 'org-mode)
       (or (org-in-src-block-p)
           (org-inside-LaTeX-fragment-p))))

(defun rimel-probe-tex-math ()
  "Probe: ASCII in TeX math."
  (and (derived-mode-p 'tex-mode 'latex-mode 'LaTeX-mode)
       (require 'texmathp nil t)
       (texmathp)))

(defun rimel-probe-minibuffer ()
  "Probe: ASCII in the minibuffer."
  (minibufferp))

(defun rimel-probe-evil-non-insert ()
  "Probe: ASCII outside evil insert and emacs states."
  (and (bound-and-true-p evil-local-mode)
       (boundp 'evil-state)
       (not (memq (symbol-value 'evil-state) '(insert emacs)))))

(defun rimel-probe-meow-non-insert ()
  "Probe: ASCII outside meow insert state."
  (and (bound-and-true-p meow-mode)
       (not (bound-and-true-p meow-insert-mode))))

;;;###autoload
(defun rimel-force-rime ()
  "Send the next composition to Rime regardless of `rimel-probes'."
  (interactive)
  (setq rimel--force-rime t)
  (message "Rime: next input ignores probes"))

;;;; Inline preedit

(defvar-local rimel--preedit-overlay nil)

(defun rimel--preedit-string (state)
  "Return the inline preedit string for STATE, or nil."
  (pcase rimel-inline-preedit
    ('raw
     (let* ((preedit (rimel--st-preedit state))
            (str (propertize preedit 'face 'rimel-preedit-face))
            (cursor (rimel--st-cursor state)))
       (when (and cursor (< cursor (length str)))
         (put-text-property cursor (1+ cursor) 'cursor t str))
       str))
    ('preview
     (when-let* ((preview (or (rimel--st-preview state)
                              (rimel--st-preedit state))))
       (propertize preview 'face 'rimel-preedit-face)))))

(defun rimel--show-preedit (state &optional suffix)
  "Show the inline preedit of STATE at point, followed by SUFFIX.
Both live in one overlay string, so their order is fixed; when the
caret is at the end of the preedit, the cursor stays right after it."
  (let* ((preedit (rimel--preedit-string state))
         (str (if suffix (concat preedit suffix) preedit)))
    (when (and suffix
               (not (and preedit (text-property-any 0 (length preedit)
                                                    'cursor t preedit))))
      (put-text-property (length preedit) (1+ (length preedit))
                         'cursor t str))
    (if (not str)
        (rimel--hide-preedit)
      (if (overlayp rimel--preedit-overlay)
          (move-overlay rimel--preedit-overlay (point) (point) (current-buffer))
        (setq rimel--preedit-overlay (make-overlay (point) (point) nil t nil))
        (overlay-put rimel--preedit-overlay 'priority 1000)
        (overlay-put rimel--preedit-overlay 'window (selected-window)))
      (overlay-put rimel--preedit-overlay 'before-string str))))

(defun rimel--hide-preedit ()
  (when (overlayp rimel--preedit-overlay)
    (delete-overlay rimel--preedit-overlay)
    (setq rimel--preedit-overlay nil)))

;;;; Candidate menu

(defun rimel--menu-preedit (state)
  "The preedit as shown in the candidate menu, with a caret."
  (let* ((preedit (rimel--st-preedit state))
         (cursor (min (or (rimel--st-cursor state) (length preedit))
                      (length preedit))))
    (propertize (if (< cursor (length preedit))
                    (concat (substring preedit 0 cursor) "|"
                            (substring preedit cursor))
                  preedit)
                'face 'rimel-code-face)))

(defun rimel-format-candidates (state &optional layout show-preedit)
  "Format the candidate menu of STATE as a string.
LAYOUT is `horizontal' (the default) or `vertical'.  When
SHOW-PREEDIT is non-nil the preedit is included."
  (let* ((candidates (rimel--st-candidates state))
         (labels (or (rimel--st-labels state) rimel-candidate-labels))
         (highlighted (or (rimel--st-highlighted state) -1))
         (vertical (eq layout 'vertical))
         (items
          (cl-loop
           for (text . comment) in candidates
           for i from 0
           for label = (or (nth i labels) "")
           collect
           (let ((item (concat
                        (propertize (concat label ".") 'face 'rimel-label-face)
                        (propertize text 'face 'rimel-candidate-face)
                        (when comment
                          (propertize (concat " " comment)
                                      'face 'rimel-comment-face)))))
             (when (= i highlighted)
               (add-face-text-property 0 (length item) 'rimel-highlight-face
                                       nil item))
             item)))
         (page (concat
                (if (and (rimel--st-page-no state)
                         (> (rimel--st-page-no state) 0))
                    "<" "")
                (if (and candidates (not (rimel--st-last-page-p state)))
                    ">" "")))
         (menu (string-join items (if vertical "\n" " "))))
    (unless (string-empty-p page)
      (setq menu (concat menu (if vertical "\n" " ")
                         (propertize page 'face 'rimel-label-face))))
    (if show-preedit
        (concat (rimel--menu-preedit state) (if vertical "\n" " ") menu)
      menu)))

(defvar rimel--echo-message nil)

(defun rimel-show-minibuffer (state)
  "Show the candidate menu of STATE in the echo area; hide if STATE is nil.
In an active minibuffer the menu is appended to its contents instead."
  (if (null state)
      (progn
        (when (and rimel--echo-message
                   (equal (current-message) rimel--echo-message))
          (message nil))
        (setq rimel--echo-message nil))
    (let ((text (rimel-format-candidates
                 state 'horizontal
                 (or input-method-use-echo-area (not rimel-inline-preedit)))))
      (if (and (minibufferp) (not input-method-use-echo-area))
          ;; The echo area is hidden by an active minibuffer: show the
          ;; menu right after the inline preedit instead.
          (rimel--show-preedit state (concat "  " text))
        (let ((message-log-max nil)
              (inhibit-message nil))
          (setq rimel--echo-message (message "%s" text)))))))

(defconst rimel--posframe-buffer " *rimel-posframe*")

(defun rimel--posframe-usable-p ()
  (and (display-graphic-p)
       (require 'posframe nil t)
       (posframe-workable-p)))

(defun rimel-show-posframe (state)
  "Show the candidate menu of STATE in a posframe; hide if STATE is nil.
Falls back to `rimel-show-minibuffer' when posframe is unavailable."
  (cond
   ((null state)
    (when (get-buffer rimel--posframe-buffer)
      (posframe-hide rimel--posframe-buffer))
    (rimel-show-minibuffer nil))
   ((or input-method-use-echo-area (not (rimel--posframe-usable-p)))
    (rimel-show-minibuffer state))
   (t
    (let ((face-bg (face-background 'rimel-posframe-face nil t))
          (face-fg (face-foreground 'rimel-posframe-face nil t)))
      (apply #'posframe-show rimel--posframe-buffer
             :string (rimel-format-candidates state rimel-candidate-layout
                                              (not rimel-inline-preedit))
             :position (point)
             :background-color face-bg
             :foreground-color face-fg
             :internal-border-color
             (face-foreground 'rimel-posframe-border-face nil t)
             rimel-posframe-properties)))))

(defun rimel--candidate-function ()
  (pcase rimel-candidate-style
    ('posframe #'rimel-show-posframe)
    ('minibuffer #'rimel-show-minibuffer)
    ('nil nil)
    ((pred functionp) rimel-candidate-style)))

(defun rimel--render (state)
  "Display STATE.  Candidate rendering is skipped when input is pending."
  (if input-method-use-echo-area
      (rimel-show-minibuffer state)
    (rimel--show-preedit state)
    (unless (or executing-kbd-macro (input-pending-p))
      (when-let* ((fn (rimel--candidate-function)))
        (funcall fn state)))))

(defun rimel--clear-ui ()
  (rimel--hide-preedit)
  (when-let* ((fn (rimel--candidate-function)))
    (funcall fn nil))
  (rimel-show-minibuffer nil))

;;;; The input method

(defun rimel--passthrough-p (key)
  "Return non-nil if KEY must not start a composition."
  (or (and (or buffer-read-only
               (and (get-char-property (point) 'read-only)
                    (get-char-property (point) 'front-sticky)))
           (not (or inhibit-read-only
                    (get-char-property (point) 'inhibit-read-only))))
      (and overriding-terminal-local-map
           (lookup-key overriding-terminal-local-map (vector key)))
      overriding-local-map
      (not (rimel--module-loaded-p))
      (and (not rimel--force-rime)
           rimel-probes
           (rimel--probe-ascii-p key))))

(defun rimel-input-method (key)
  "Input method function of Rimel; see `input-method-function'."
  (if (rimel--passthrough-p key)
      (list key)
    (let* ((rkey (rimel--event-key key))
           (state (and rkey (rimel-module-process-key (car rkey) (cdr rkey)))))
      (cond
       ;; Not ready (e.g. deploying in the background): type as is.
       ((null state) (list key))
       ((and (not (rimel--st-handled state))
             (not (rimel--st-composing-p state))
             (not (rimel--st-commit state)))
        (list key))
       (t
        (setq rimel--force-rime nil)
        (rimel--compose state key))))))

(defun rimel--interrupt ()
  "Apply `rimel-interrupt-action' and return the text to insert."
  (pcase rimel-interrupt-action
    ('commit (rimel-module-commit-composition))
    ('commit-raw (prog1 (rimel-module-input)
                   (rimel-module-clear-composition)))
    (_ (rimel-module-clear-composition) nil)))

(defun rimel--compose (state key)
  "Run the composition loop starting from STATE, reached by KEY.
Return the list of events to insert, as `input-method-function' does."
  (let ((input-method-function nil)
        (echo-keystrokes 0)
        (inhibit-quit t)
        (committed "")
        (extra nil)
        (event key))
    (unwind-protect
        (catch 'done
          (while t
            (when (rimel--st-commit state)
              (setq committed (concat committed (rimel--st-commit state))))
            (cond
             ;; The key was not used and the composition is over: insert
             ;; the commit (if any) followed by the key itself.
             ((and (not (rimel--st-handled state))
                   (not (rimel--st-composing-p state)))
              (setq extra (list event))
              (throw 'done nil))
             ((not (rimel--st-composing-p state))
              (throw 'done nil))
             ;; Rime ignored a key mid-composition (e.g. C-x).
             ((not (rimel--st-handled state))
              (setq committed (concat committed (or (rimel--interrupt) ""))
                    extra (list event))
              (throw 'done nil))
             ;; A commit that leaves a composition behind (e.g. auto
             ;; commit when the code is full): insert the commit now and
             ;; re-feed the remaining input through the input method, so
             ;; the commit goes through the command loop first.
             ((and (rimel--st-commit state) (rimel--replayable-p state))
              (let ((input (string-to-list (rimel--st-input state))))
                (rimel-module-clear-composition)
                ;; The re-fed keys continue a composition: skip probes.
                (setq rimel--force-rime t)
                (setq unread-command-events
                      (append (mapcar (lambda (c) (cons 'no-record c)) input)
                              unread-command-events)))
              (throw 'done nil)))
            (rimel--render state)
            (setq event (read-key))
            (if (eq event ?\C-g)
                (progn (setq quit-flag nil)
                       (rimel-module-clear-composition)
                       (throw 'done nil))
              (let ((rkey (rimel--event-key event)))
                (setq state
                      (or (and rkey (rimel-module-process-key
                                     (car rkey) (cdr rkey)))
                          ;; Untranslatable event (mouse, ...): handled
                          ;; like a key Rime ignores.
                          (let ((st (rimel-module-state)))
                            (if st (progn (aset st 0 nil) st)
                              ;; Rime went away (a deployment started):
                              ;; keep the event.
                              (setq extra (list event))
                              (throw 'done nil)))))))))
      (rimel--clear-ui))
    (append (string-to-list committed) extra)))

(defun rimel--replayable-p (state)
  "Return non-nil if the raw input of STATE can be fed back as events."
  (let ((input (rimel--st-input state)))
    (and input
         (not (string-empty-p input))
         (cl-every (lambda (c) (and (<= 32 c 255) (/= c 127))) input))))

;;;###autoload
(defun rimel-activate (&optional _name)
  "Activate the Rimel input method in the current buffer."
  (rimel--ensure-started)
  (setq-local input-method-function #'rimel-input-method)
  (setq-local deactivate-current-input-method-function #'rimel-deactivate)
  (setq-local describe-current-input-method-function #'rimel-describe)
  (setq-local current-input-method-title rimel-title)
  (when rimel-indicator-refresh
    (add-hook 'post-command-hook #'rimel--refresh-indicator nil t))
  (when (rimel--module-loaded-p)
    (rimel-module-clear-composition)))

(defun rimel-deactivate ()
  "Deactivate the Rimel input method in the current buffer."
  (rimel--clear-ui)
  (remove-hook 'post-command-hook #'rimel--refresh-indicator t)
  (kill-local-variable 'input-method-function)
  (kill-local-variable 'describe-current-input-method-function))

(defun rimel-describe ()
  "Describe the Rimel input method."
  (with-output-to-temp-buffer "*Help*"
    (princ (format "Input method: rimel (mode line \"%s\")\n\n" rimel-title))
    (princ "Rime input method engine via librime.\n\n")
    (when (rimel-ready-p)
      (let ((v (rimel-module-version)))
        (princ (format "Module %s, librime %s\n" (car v) (or (cdr v) "?"))))
      (princ (format "Schema: %s\n" (or (rimel-module-current-schema) "?"))))
    (princ (format "Shared data: %s\nUser data: %s\n"
                   rimel-shared-data-dir rimel-user-data-dir))))

;;;###autoload
(register-input-method "rimel" "euc-cn" #'rimel-activate "ㄓ"
                       "Rime input method via librime")

;;;; Commands

(defun rimel--require-ready ()
  (unless (rimel-ready-p)
    (user-error (if (and (rimel--module-loaded-p) (rimel-module-started-p))
                    "Rime is deploying, try again shortly"
                  "Rime is not running; activate the input method first"))))

;;;###autoload
(defun rimel-select-schema (schema)
  "Select the Rime SCHEMA (a schema id)."
  (interactive
   (progn
     (rimel--ensure-started)
     (rimel--require-ready)
     (let* ((schemas (rimel-module-schema-list))
            (choices (mapcar (lambda (s) (cons (format "%s (%s)" (cdr s) (car s))
                                               (car s)))
                             schemas))
            (choice (completing-read "Rime schema: " choices nil t)))
       (list (cdr (assoc choice choices))))))
  (rimel--require-ready)
  ;; librime accepts unknown ids, so check against the schema list.
  (if (and (assoc schema (rimel-module-schema-list))
           (rimel-module-select-schema schema))
      (message "Rime: %s" schema)
    (user-error "Rime: cannot select schema %s" schema)))

;;;###autoload
(defun rimel-deploy ()
  "Redeploy Rime in the background, e.g. after editing its configuration."
  (interactive)
  (rimel--ensure-started)
  (rimel--require-ready)
  (if (rimel-module-deploy)
      (message "Rime: deploying in the background...")
    (message "Rime: nothing to deploy")))

;;;###autoload
(defun rimel-sync ()
  "Sync Rime user data in the background."
  (interactive)
  (rimel--ensure-started)
  (rimel--require-ready)
  (rimel-module-sync-user-data)
  (message "Rime: syncing user data in the background..."))

;;;###autoload
(defun rimel-toggle-ascii-mode ()
  "Toggle Rime's own ASCII mode."
  (interactive)
  (rimel--require-ready)
  (let ((on (not (rimel-module-get-option "ascii_mode"))))
    (rimel-module-set-option "ascii_mode" on)
    (force-mode-line-update)
    (message "Rime: %s" (if on "ASCII" "Chinese"))))

;;;###autoload
(defun rimel-open-user-dir ()
  "Open the Rime user data directory."
  (interactive)
  (make-directory rimel-user-data-dir t)
  (dired rimel-user-data-dir))

;;;###autoload
(defun rimel-restart ()
  "Restart librime, e.g. after changing `rimel-user-data-dir'."
  (interactive)
  (rimel--shutdown)
  (rimel--ensure-started))

(defvar-local rimel--indicator-last nil)

(defun rimel--refresh-indicator ()
  (let ((now (rimel-indicator)))
    (unless (equal-including-properties now rimel--indicator-last)
      (setq rimel--indicator-last now)
      (force-mode-line-update))))

(defun rimel-indicator ()
  "Return a mode line indicator for the input state at point.
Shows `rimel-title' when keys go to Rime, and a dimmed letter when
they are typed as ASCII, either by Rime's ASCII mode or a probe.
Use it as (:eval (rimel-indicator)) in `mode-line-format'."
  (when (equal current-input-method "rimel")
    (cond
     ((not (rimel-ready-p)) (propertize rimel-title 'face 'shadow))
     ((or (rimel-module-get-option "ascii_mode")
          (and rimel-probes (not rimel--force-rime)
               (ignore-errors (rimel--probe-ascii-p nil))))
      (propertize "A" 'face 'rimel-indicator-ascii-face))
     (t rimel-title))))

(provide 'rimel)
;;; rimel.el ends here
