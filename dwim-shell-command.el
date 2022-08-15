;;; dwim-shell-command.el --- Shell commands with DWIM behaviour -*- lexical-binding: t; -*-

;; Copyright (C) 2022 Alvaro Ramirez

;; Author: Alvaro Ramirez
;; Package-Requires: ((emacs "27.1"))
;; URL: https://github.com/xenodium/dwim-shell-command
;; Version: 0.15

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Provides `dwim-shell-command' as an opinionated DWIM alternative to
;; `shell-command'.
;;
;; Use `dwim-shell-command-on-marked-files' to create your own command
;; line utilities, invoked via M-x.
;;
;; See examples at https://github.com/xenodium/dwim-shell-command/blob/main/dwim-shell-commands.el

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'dired)
(require 'dired-aux)
(require 'map)
(require 'seq)
(require 'shell)
(require 'simple)
(require 'subr-x)
(require 'view)

(defcustom dwim-shell-command-prompt
  "DWIM shell command (<<f>> <<fne>> <<e>> <<td>> <<*>> <<cb>> <<n>>): "
  "`dwim-shell-command' prompt.  Modify if shorter is preferred."
  :type 'string
  :group 'dwim-shell-command)

(defcustom dwim-shell-command-buffer-name
  "DWIM shell command"
  "`dwim-shell-command' buffer name.  Modify if shorter is preferred."
  :type 'string
  :group 'dwim-shell-command)

(defcustom dwim-shell-command-prompt-on-error t
  "If t, prompt user to focus buffer on process error.
Otherwise, automatically focus buffer on process error."
  :type 'boolean
  :group 'dwim-shell-command)

(defcustom dwim-shell-command-shell-util nil
  "Shell util, for example: \"zsh\" or \"bash\".
Set to nil to use `shell-file-name'."
  :type 'string
  :group 'dwim-shell-command)

(defcustom dwim-shell-command-shell-args nil
  "Shell util, for example: '(\"-x\" \"-c\").
Set to nil to use `shell-command-switch'."
  :type '(repeat string)
  :group 'dwim-shell-command)

(defcustom dwim-shell-command-done-buffer-name
  (lambda (name)
    (format "✅ %s %s" name (propertize "done" 'face 'success)))
  "Function to format buffer name on success.
Use `identify' to remove formatting."
  :type 'function
  :group 'dwim-shell-command)

(defcustom dwim-shell-command-error-buffer-name
  (lambda (name)
    (format "⛔️ %s %s" name (propertize "error" 'face 'error)))
  "Function to format buffer name on error.
Use `identify' to remove formatting."
  :type 'function
  :group 'dwim-shell-command)

(defvar dwim-shell-command--commands nil "All commands in progress.")

(cl-defstruct
    dwim-shell-command--command
  "Describes a command in progress."
  script
  process
  name
  calling-buffer
  reporter
  on-completion
  files-before
  silent-success
  error-autofocus
  monitor-directory)

(defun dwim-shell-command (prefix)
  "Execute DWIM shell command asynchronously using noweb templates.

Which files

  `dwim-shell-command' attempts to guess which file(s) you may want
  the command to operate on.

  1. If visiting a `dired' buffer, draw the marked file(s).
  2. If visiting any other buffer with an associated file, use that.

Templates

  Operate on drawn files using either the following:

    <<f>> (file path)
    <<fne>> (file path without extension)
    <<e>> (extension)
    <<td>> (generate a temporary directory)
    <<*>> (all files joined)
    <<cb>> (clipboard)
    <<n>>, <<1n>>, or <<An>> (for current iteration)

  For example:

    With drawn files '(\"path/to/image1.png\" \"path/to/image2.png\")

   \"convert '<<f>>' '<<fne>>.jpg'\" expands to

     \"convert 'path/to/image1.png' 'path/to/image1.jpg'\"
     \"convert 'path/to/image2.png' 'path/to/image2.jpg'\"

   while \"ls -lh <<*>>\" expands to

     \"ls -lh path/to/image1.png path/to/image2.png\"

Focus

  `dwim-shell-command' creates a process buffer to capture command
  output, but doesn't display or focus on it by default.  Instead,
  it tries to guess what's more convenient to focus on.

  While the process is busy, show a spinner in the minibuffer.  No
  focus changes.

  After process is finished:

  1. If there were any files created in the `default-directory',
  jump to a `dired' buffer and move point to the new file (via
  `dired-jump').

  2. If no new files were created, automatically switch focus to the
  process buffer and display its output.

    Note: You can prevent this automatic focus by prepending your
    command with whitespace.

      |
      V
    \" convert '<<f>>' '<<fne>>.jpg'\"

  3. If the shell command caused any errors, offer to focus the
  process buffer and display its output.

Quick exit

  Process buffers are read-only and can be quickly closed by
  pressing `q'.

Prefix

  With PREFIX, execute command that number of times."
  (interactive "p")
  (let ((script (read-shell-command dwim-shell-command-prompt)))
    (dwim-shell-command-on-marked-files
     dwim-shell-command-buffer-name script
     :repeat prefix
     :shell-util dwim-shell-command-shell-util
     :shell-args dwim-shell-command-shell-args
     :silent-success (string-prefix-p " " script)
     :error-autofocus (not dwim-shell-command-prompt-on-error))))

(cl-defun dwim-shell-command-on-marked-files (buffer-name script &key utils extensions shell-util shell-args shell-pipe post-process-template on-completion repeat silent-success no-progress error-autofocus monitor-directory focus-now)
  "Create DWIM utilities executing templated SCRIPT on given files.

Here's a simple utility invoking SCRIPT to convert image files to jpg.

  (defun dwim-shell-command-convert-image-to-jpg ()
    \"Convert all marked images to jpg(s).\"
    (interactive)
    (dwim-shell-command-on-marked-files
     \"Convert to jpg\"
     \"convert -verbose '<<f>>' '<<fne>>.jpg'\"
     :utils \"convert\"))

Check `dwim-shell-command-commands.el' for more examples.

All command process output is written to a buffer with BUFFER-NAME.

All params explained in `dwim-shell-command-execute-script'.

Which files

  `dwim-shell-command-on-marked-files' attempts to guess which file(s)
  you may want the command to operate on.

  1. If visiting a `dired' buffer, draw the marked file(s).
  2. If visiting any other buffer with an associated file, use that.

Templates

  Operate on drawn files using either the following:

    <<f>> (file path)
    <<fne>> (file path without extension)
    <<e>> (extension)
    <<td>> (generate a temporary directory)
    <<*>> (all files joined)
    <<cb>> (clipboard)
    <<n>>, <<1n>>, or <<An>> (for current iteration)

  For example:

    With drawn files '(\"path/to/image1.png\" \"path/to/image2.png\")

   \"convert '<<f>>' '<<fne>>.jpg'\" expands to

     \"convert 'path/to/image1.png' 'path/to/image1.jpg'\"
     \"convert 'path/to/image2.png' 'path/to/image2.jpg'\"

   while \"ls -lh <<*>>\" expands to

     \"ls -lh path/to/image1.png path/to/image2.png\"

Focus

  `dwim-shell-command-on-marked-files' creates a process buffer to
  capture command output, but doesn't display or focus on it by
  default.  Instead, it tries to guess what's more convenient to focus
  on.

  While the process is busy, show a spinner in the minibuffer.  No
  focus changes.

  After process is finished:

  1. If there were any files created in the `default-directory',
  jump to a `dired' buffer and move point to the new file (via
  `dired-jump').

  2. If no new files were created, automatically switch focus to the
  process buffer and display its output.

    Note: You can prevent this automatic focus by prepending your
    command with whitespace.

      |
      V
    \" convert '<<f>>' '<<fne>>.jpg'\"

  3. If the shell command caused any errors, offer to focus the
  process buffer and display its output.

Quick exit

  Process buffers are read-only and can be quickly closed by
  pressing `q'."
  (dwim-shell-command-execute-script buffer-name script
                                     :files (dwim-shell-command--files)
                                     :utils utils
                                     :extensions extensions
                                     :shell-util shell-util
                                     :shell-args shell-args
                                     :shell-pipe shell-pipe
                                     :post-process-template post-process-template
                                     :on-completion on-completion
                                     :silent-success silent-success
                                     :no-progress no-progress
                                     :repeat repeat
                                     :error-autofocus error-autofocus
                                     :monitor-directory monitor-directory
                                     :focus-now focus-now))

(cl-defun dwim-shell-command-execute-script (buffer-name script &key files extensions shell-util shell-args shell-pipe utils post-process-template on-completion silent-success gen-temp-dir repeat no-progress error-autofocus monitor-directory focus-now)
  "Execute a script asynchronously, DWIM style with SCRIPT and BUFFER-NAME.

:FILES are used to instantiate SCRIPT as a noweb template.

  The following are supported:

    <<f>> (file path)
    <<fne>> (file path without extension)
    <<e>> (extension)
    <<td>> (generate a temporary directory)
    <<*>> (all files joined)
    <<cb>> (clipboard)
    <<n>>, <<1n>>, or <<An>> (for current iteration)

  For example:

    Given :FILES '(\"path/to/image1.png\" \"path/to/image2.png\")

    \"convert '<<f>>' '<<fne>>.jpg'\" expands to

      \"convert 'path/to/image1.png' 'path/to/image1.jpg'\"
      \"convert 'path/to/image2.png' 'path/to/image2.jpg'\"

    and \"ls -lh <<*>>\" expands to

      \"ls -lh path/to/image1.png path/to/image2.png\"

:EXTENSIONS ensures that all files in :FILES have the given
extensions.  Can be either single string \"png\" or a list '(\"png\" \"jpg\").

:SHELL-UTIL and :SHELL-ARGS can be used to specify SCRIPT interpreter.

  For python, use:

    (dwim-shell-command-execute-script
       \"Print Pi\"
       \"import math
         print math.pi\"
       :shell-util \"python\"
       :shell-args \"-c\")

:SHELL-PIPE can be used to pipe SCRIPT to it

  For swift, use:

    (dwim-shell-command-on-marked-files
       \"Print Pi\"
       \"print(Double.pi)\"
       :shell-pipe \"swift -\")

:UTILS ensures that all needed command line utilities are installed.
Can be either a single string \"ffmpeg\" or a list '(\"ffmpet\" \"convert\").

:POST-PROCESS-TEMPLATE enables processing template further after noweb
instantiation.

:ON-COMPLETION is invoked after SCRIPT executes (disabling DWIM
internal behavior).

:SILENT-SUCCESS to avoid jumping to process buffer if neither error
 nor file generated.

:GEN-TEMP-DIR to generate a temporary directory for this command.
This is implied when <<td>> appears in the script.

:REPEAT Use to repeat script N number of times.

:NO-PROGRESS Suppress progress reporting.

:ERROR-AUTOFOCUS Automatically focus process buffer on error.

:MONITOR-DIRECTORY Monitor this directory for new files.

:FOCUS-NOW Immediately focus process buffer once started.
"
  (cl-assert buffer-name nil "Script must have a buffer name")
  (cl-assert (not (string-empty-p script)) nil "Script must not be empty")
  (when (stringp extensions)
    (setq extensions (list extensions)))
  (when (and shell-util (stringp shell-util))
    (setq shell-util (list shell-util)))
  (setq shell-util (or shell-util
                       (when shell-file-name
                         (list shell-file-name))
                       '("zsh")))
  (setq shell-args (or shell-args
                       (when shell-command-switch
                         (list shell-command-switch))
                       '("-x" "-c")))
  ;; See if -x can be prepended.
  (when (and (not (seq-contains shell-args "-x"))
             (apply #'dwim-shell-command--program-test
                    (seq-concatenate
                     'list shell-util '("-x") shell-args (list "echo"))))
    (setq shell-args (seq-concatenate 'list '("-x") shell-args)))
  (when (and shell-args (stringp shell-args))
    (setq shell-args (list shell-args)))
  (when (stringp utils)
    (setq utils (list utils)))
  (when (or gen-temp-dir (string-match-p "\<\<td\>\>" script 0))
    (setq gen-temp-dir (make-temp-file "dwim-shell-command-" t)))
  (when (and repeat (> repeat 1))
    (cl-assert (<= (length files) 1) nil
               "Must not repeat when multiple files are selected.")
    (setq files (make-list repeat (or (seq-first files) "_no_file_selected_"))))
  (when (seq-empty-p files)
    (cl-assert (not (or (dwim-shell-command--contains-multi-file-ref script)
                        (dwim-shell-command--contains-single-file-ref script)))
               nil "No files found to expand %s"
               (or (dwim-shell-command--contains-multi-file-ref script)
                   (dwim-shell-command--contains-single-file-ref script))))
  (when extensions
    (seq-do (lambda (file)
              (cl-assert (seq-contains-p extensions (downcase (file-name-extension file)))
                         nil "Not a .%s file" (string-join extensions " .")))
            files))
  (seq-do (lambda (util)
            (cl-assert (executable-find util) nil (format "%s not installed" util)))
          utils)
  (let* ((proc-buffer (generate-new-buffer (format "*%s*" buffer-name)))
         (template script)
         (script "")
         (files-before)
         (proc)
         (progress-reporter)
         (n (or (dwim-shell-command--n-start-value template) "1")))
    (if (seq-empty-p files)
        (setq script (dwim-shell-command--expand-file-template template nil post-process-template gen-temp-dir n))
      (if (dwim-shell-command--contains-multi-file-ref template)
          (setq script (dwim-shell-command--expand-files-template template files post-process-template gen-temp-dir))
        (seq-do (lambda (file)
                  (setq script
                        (concat script "\n"
                                (dwim-shell-command--expand-file-template template file post-process-template gen-temp-dir n)))
                  (setq n (dwim-shell-command--increment-string n)))
                files)))
    (setq script (string-trim script))
    (with-current-buffer proc-buffer
      (require 'shell)
      (shell-mode))
    (with-current-buffer proc-buffer
      (setq default-directory default-directory)
      (shell-command-save-pos-or-erase)
      (view-mode +1)
      (setq view-exit-action 'kill-buffer))
    (setq files-before (dwim-shell-command--default-directory-files monitor-directory))
    (setq proc (apply #'start-process (seq-concatenate 'list
                                                       (list (buffer-name proc-buffer) proc-buffer)
                                                       shell-util
                                                       shell-args
                                                       (if shell-pipe
                                                           (list (format "echo '%s' | %s" script shell-pipe))
                                                         (list script)))))
    (if no-progress
        (dwim-shell-command--message "%s started" (process-name proc))
      (setq progress-reporter (make-progress-reporter
                               ;; Append space so "done" is spaced when
                               ;; progress reporter is finished:
                               ;;
                               ;; *DWIM shell command* done
                               (concat (process-name proc) " ")))
      (progress-reporter-update progress-reporter))
    ;; Momentarily set buffer to same window, so it's next in recent stack.
    ;; Makes finding the shell command buffer a lot easier.
    (let ((current (current-buffer)))
      (pop-to-buffer-same-window proc-buffer)
      (pop-to-buffer-same-window current))
    (when focus-now
      (switch-to-buffer proc-buffer))
    (if (equal (process-status proc) 'exit)
        (dwim-shell-command--finalize (current-buffer)
                                      files-before
                                      proc
                                      progress-reporter
                                      on-completion
                                      silent-success
                                      error-autofocus
                                      monitor-directory)
      (setq dwim-shell-command--commands
            (push (cons (process-name proc)
                        (make-dwim-shell-command--command :script script
                                                          :process proc
                                                          :name (process-name proc)
                                                          :calling-buffer (current-buffer)
                                                          :files-before files-before
                                                          :reporter progress-reporter
                                                          :on-completion on-completion
                                                          :silent-success silent-success
                                                          :error-autofocus error-autofocus
                                                          :monitor-directory monitor-directory))
                  dwim-shell-command--commands))
      (set-process-sentinel proc #'dwim-shell-command--sentinel)
      (set-process-filter proc #'dwim-shell-command--filter))))

(defun dwim-shell-command-read-file-name (prompt extension)
  "Invoke `read-string' with PROMPT and validate EXTENSION.
Return nil if empty input."
  (let ((file-name (read-string prompt)))
    (cond ((string-empty-p (string-trim file-name))
           nil)
          ((and extension
                (string-equal (file-name-extension file-name) extension))
           file-name)
          ((and extension
                (not (string-equal (file-name-extension file-name) extension)))
           (user-error "Name must end in .%s" extension))
          (t
           file-name))))

(defun dwim-shell-command--message (message &rest args)
  "Like `dwim-shell-command--message' but non-blocking.
MESSAGE and ARGS same as `dwim-shell-command--message'."
  (let ((message-id (random)))
    (message (propertize (apply #'format message args) 'message-id message-id))
    (run-with-timer 3 nil
                    (lambda ()
                      (when (and (current-message)
                                 (eq (get-text-property 0 'message-id (current-message))
                                     message-id))
                        (message nil))))))

(defun dwim-shell-command--expand-files-template (template files &optional post-process-template temp-dir)
  "Expand TEMPLATE using FILES.

Expand using <<*>> for FILES.

Note: This expander cannot be used to expand <<f>>, <<fne>>, or <<e>>.

  For example:

    Given FILES '(\"path/to/image1.png\" \"path/to/image2.png\")

    \"du -csh <<*>>\" expands to

      \"du -csh 'path/to/image1.png' 'path/to/image2.png'\"

Use POST-PROCESS-TEMPLATE to further expand template given own logic.

Set TEMP-DIR to a unique temp directory to this template."
  (cl-assert (not (and (dwim-shell-command--contains-multi-file-ref template)
                       (dwim-shell-command--contains-single-file-ref template)))
             nil "Must not have %s and %s in the same template"
             (dwim-shell-command--contains-multi-file-ref template)
             (dwim-shell-command--contains-single-file-ref template))
  (setq files (seq-map (lambda (file)
                         (expand-file-name file))
                       files))
  ;; Try to use quotes surrounding <<*>> in each path.
  ;; "'<<*>>'" with '("path/to/image1.png" "path/to/image2.png") -> "'path/to/image1.png' 'path/to/image2.png'"
  (when-let ((found (string-match "\\([^ ]\\)\\(\<\<\\*\>\>\\)\\([^ ]\\)" template))
             (before (match-string 1 template))
             (after (match-string 3 template)))
    (setq template (replace-regexp-in-string "\\([^ ]\\)\\(\<\<\\*\>\>\\)\\([^ ]\\)"
                                             (string-join (seq-map (lambda (file)
                                                                     (concat before file after)) files) " ")
                                             template nil nil 0)))

  ;; "<<some.txt(u)>>" -> some.txt (if unique)
  ;;                   -> some(1).txt (if it exist)
  (when-let* ((found (string-match "\<\<\\([^ ]?+\\)(u)\>\>" template))
              (name (match-string 1 template)))
    (setq template (replace-regexp-in-string "\<\<\\([^ ]?+\\)(u)\>\>"
                                             (dwim-shell-command--unique-new-file-path name)
                                             template nil nil 0)))

  ;; "<<*>>" with '("path/to/image1.png" "path/to/image2.png") -> "path/to/image1.png path/to/image2.png"
  (setq template (replace-regexp-in-string "\\(\<\<\\*\>\>\\)" (string-join files " ") template nil nil 1))

  ;; "<<td>>" with TEMP-DIR -> "/var/folders/m7/ky091cp56d5g68nyhl4y7frc0000gn/T/dwim-shell-command-JNK4V5"
  (setq template (replace-regexp-in-string "\\(\<\<td\>\>\\)" temp-dir template nil nil 1))

  ;; "<<cb>>" with (current-kill 0) -> "whatever was in kill ring"
  (setq template (replace-regexp-in-string "\\(\<\<cb\>\>\\)" (or (current-kill 0)
                                                              (user-error "Nothing in clipboard"))
                                           template nil nil 1))

  (when post-process-template
    (setq template (funcall post-process-template template files)))
  template)

(defun dwim-shell-command--expand-file-template (template file &optional post-process-template temp-dir current)
  "Expand TEMPLATE using FILE.

Expand using <<f>> for FILE, <<fne>> for FILE without extension, and
<<e>> for FILE extension.  <<n>>, <<1n>>, or <<an>> is replaced with
CURRENT. <<some.txt(u)>> expands to unique \"some(1).txt\".

Note: This expander cannot be used to expand <<*>>.

  For example:

    Given FILE \"path/to/image.png\"

    \"convert '<<f>>' '<<fne>>.jpg'\" expands to

      \"convert 'path/to/image.png' 'path/to/image.jpg'\"

Use POST-PROCESS-TEMPLATE to further expand template given own logic.

Set TEMP-DIR to a unique temp directory to this template."
  (cl-assert (not (and (dwim-shell-command--contains-multi-file-ref template)
                       (dwim-shell-command--contains-single-file-ref template)))
             nil "Must not have %s and %s in the same template"
             (dwim-shell-command--contains-multi-file-ref template)
             (dwim-shell-command--contains-single-file-ref template))
  (when file
    (setq file (expand-file-name file))
    ;; "<<fne>>" with "/path/tmp.txt" -> "/path/tmp"
    (setq template (replace-regexp-in-string "\\(\<\<fne\>\>\\)" (file-name-sans-extension file) template nil nil 1))

    ;; "<<e>>" with "/path/tmp.txt" -> "txt"
    (if (file-name-extension file)
        (setq template (replace-regexp-in-string "\\(\<\<e\>\>\\)" (file-name-extension file) template nil nil 1))
      ;; File had no extension. Attempt to remove .<<e>>.
      (setq template (replace-regexp-in-string "\\(\.\<\<e\>\>\\)" "" template nil nil 1)))

    ;; "<<f>>" with "/path/file.jpg" -> "/path/file.jpg"
    (setq template (replace-regexp-in-string "\\(\<\<f\>\>\\)" file template nil nil 1)))

  ;; "<<some.txt(u)>>" -> some.txt (if unique)
  ;;                   -> some(1).txt (if it exist)
  (when-let* ((found (string-match "\<\<\\([^ ]?+\\)(u)\>\>" template))
              (name (match-string 1 template)))
    (setq template (replace-regexp-in-string "\<\<\\([^ ]?+\\)(u)\>\>"
                                             (dwim-shell-command--unique-new-file-path name)
                                             template nil nil 0)))

  ;; "<<td>>" with TEMP-DIR -> "/var/folders/m7/ky091cp56d5g68nyhl4y7frc0000gn/T/dwim-shell-command-JNK4V5"
  (setq template (replace-regexp-in-string "\\(\<\<td\>\>\\)" temp-dir template nil nil 1))

  ;; "<<cb>>" with (current-kill 0) -> "whatever was in kill ring"
  (setq template (replace-regexp-in-string "\\(\<\<cb\>\>\\)" (or (current-kill 0)
                                                              (user-error "Nothing in clipboard"))
                                           template nil nil 1))

  ;; "<<n>>" or "<<an>" or "<<1n>" with current.
  (setq template (replace-regexp-in-string "\\(\<\<[[:alnum:]]?+n\>\>\\)" current
                                           template nil nil 1))

  (when post-process-template
    (setq template (funcall post-process-template template file)))
  template)

(defun dwim-shell-command--contains-single-file-ref (template)
  "Check for <<f>>, <<fne>>, or <<e>> in TEMPLATE."
  (cond ((string-match "\<\<f\>\>" template)
         "<<f>>")
        ((string-match "\<\<fne\>\>" template)
         "<<fne>>")
        ((string-match "\<\<e\>\>" template)
         "<<e>>")))

(defun dwim-shell-command--contains-multi-file-ref (template)
  "Check for <<*>> in TEMPLATE."
  (when (string-match "\<\<\\*\>\>" template)
    "<<*>>"))

(defun dwim-shell-command--default-directory-files (override)
  "List of files in current buffer's `default-directory'.
Use OVERRIDE to override `default-directory'."
  (when-let ((default-directory (or override default-directory)))
    (seq-map (lambda (filename)
               (file-name-concat default-directory filename))
             (process-lines "ls" "-1"))))

(defun dwim-shell-command--last-modified-between (before after)
  "Compare files in BEFORE and AFTER and return oldest file in diff."
  (car (last (seq-sort #'file-newer-than-file-p
                       (seq-difference after before)))))

(defun dwim-shell-command--finalize (calling-buffer files-before process progress-reporter on-completion silent-success error-autofocus monitor-directory)
  "Finalize script execution.

CALLING-BUFFER, FILES-BEFORE, PROCESS, PROGRESS-REPORTER,
ERROR-AUTOFOCUS, ON-COMPLETION, SILENT-SUCCESS, and MONITOR-DIRECTORY are
all needed to finalize processing."
  (let ((oldest-new-file))
    (when progress-reporter
      (progress-reporter-done progress-reporter))
    (if (= (process-exit-status process) 0)
        (progn
          (dwim-shell-command--message (funcall dwim-shell-command-done-buffer-name (process-name process)))
          (with-current-buffer (process-buffer process)
            (rename-buffer (generate-new-buffer-name (funcall dwim-shell-command-done-buffer-name (process-name process)))))
          (if on-completion
              (funcall on-completion (process-buffer process))
            (with-current-buffer calling-buffer
              (when (equal major-mode 'dired-mode)
                (when revert-buffer-function
                  (funcall revert-buffer-function nil t))
                ;; Region is not accurate if new files added. Wipe it.
                (when mark-active
                  (deactivate-mark)))
              (setq oldest-new-file
                    (dwim-shell-command--last-modified-between
                     files-before
                     (dwim-shell-command--default-directory-files monitor-directory)))
              (when oldest-new-file
                (dired-jump nil oldest-new-file)))
            (unless (equal (process-buffer process)
                           (window-buffer (selected-window)))
              (if (or oldest-new-file silent-success)
                  (kill-buffer (process-buffer process))
                (unless silent-success
                  (switch-to-buffer (process-buffer process)))))))
      (if (and (buffer-name (process-buffer process))
               (or error-autofocus
                   ;; Buffer already selected. Don't ask.
                   (equal (process-buffer process)
                          (window-buffer (selected-window)))
                   (ignore-error quit
                     (y-or-n-p (format "%s error, see output? "
                                       (buffer-name (process-buffer process)))))))
          (progn
            (with-current-buffer (process-buffer process)
              (rename-buffer (generate-new-buffer-name (funcall dwim-shell-command-error-buffer-name (process-name process)))))
            (when (or error-autofocus
                      (equal (process-buffer process)
                             (window-buffer (selected-window))))
              (dwim-shell-command--message (funcall dwim-shell-command-error-buffer-name (process-name process))))
            (switch-to-buffer (process-buffer process)))
        (kill-buffer (process-buffer process))))
    (setq dwim-shell-command--commands
          (map-delete dwim-shell-command--commands (process-name process)))))

(defun dwim-shell-command--unique-new-file-path (file-path)
  "Return a unique FILE-PATH.
\"/tmp/blah.txt\" -> \"/tmp/blah(1).txt\"
\"/tmp/blah\" -> \"/tmp/blah(1)\"
"
  (let ((counter 1)
        (name (file-name-sans-extension file-path))
        (extension (file-name-extension file-path)))
    (while (file-exists-p file-path)
      (if extension
          (setq file-path (format "%s(%d).%s" name counter extension))
        (setq file-path (format "%s(%d)" name counter)))
      (setq counter (1+ counter)))
    file-path))

(defun dwim-shell-command--sentinel (process _)
  "Handles PROCESS sentinel and STATE."
  (let ((exec (map-elt dwim-shell-command--commands (process-name process))))
    (dwim-shell-command--finalize (dwim-shell-command--command-calling-buffer exec)
                                  (dwim-shell-command--command-files-before exec)
                                  process
                                  (dwim-shell-command--command-reporter exec)
                                  (dwim-shell-command--command-on-completion exec)
                                  (dwim-shell-command--command-silent-success exec)
                                  (dwim-shell-command--command-error-autofocus exec)
                                  (dwim-shell-command--command-monitor-directory exec))))

(defun dwim-shell-command--filter (process output)
  "Handles PROCESS filtering and STATE and OUTPUT."
  (when-let* ((exec (map-elt dwim-shell-command--commands (process-name process)))
              (reporter (dwim-shell-command--command-reporter exec)))
    (progress-reporter-update reporter))
  (comint-output-filter process output))

(defun dwim-shell-command--files ()
  "Return buffer file (if available) or marked/region files for a `dired' buffer."
  (cl-assert (not (and mark-active (let ((files (dired-get-marked-files nil nil nil t)))
                                     ;; Based on `dired-number-of-marked-files'.
                                     (cond ((null (cdr files))
                                            nil)
                                           ((and (= (length files) 2)
                                                 (eq (car files) t))
                                            t)
                                           (t
                                            (not (seq-empty-p (length files))))))))
             nil "Region and marked files both active. Choose one only.")
  (if (buffer-file-name)
      (list (buffer-file-name))
    (or
     (dwim-shell-command--dired-paths-in-region)
     (dired-get-marked-files))))

(defun dwim-shell-command--dired-paths-in-region ()
  "If `dired' buffer, return region files.  nil otherwise."
  (when (and (equal major-mode 'dired-mode)
             mark-active)
    (let ((start (region-beginning))
          (end (region-end))
          (paths))
      (save-excursion
        (save-restriction
          (goto-char start)
          (while (< (point) end)
            ;; Skip non-file lines.
            (while (and (< (point) end) (dired-between-files))
              (forward-line 1))
            (when (dired-get-filename nil t)
              (setq paths (append paths (list (dired-get-filename nil t)))))
            (forward-line 1))))
      paths)))

(defun dwim-shell-command--n-start-value (template)
  "Extract n start value from TEMPLATE.
Falls back to \"1\"."
  (when (string-match "\<\<\\([[:alnum:]]?+\\)n\>\>" template)
    (if (string-empty-p (match-string 1 template))
        "1"
      (match-string 1 template))))

(defun dwim-shell-command--increment-string (text)
  "Increment TEXT.
\"a\" -> \"b\"
\"1\" -> \"2\""
  (cond ((string-match "^[[:alpha:]]$" text) ;; char
         (char-to-string (1+ (string-to-char (match-string 0 text)))))
        ((string-match "^[[:digit:]]+$" text) ;; char
         (number-to-string (1+ (string-to-number (match-string 0 text)))))))

(defun dwim-shell-command--program-test (program &rest args)
  "Test that running PROGRAM with ARGS is successful."
  (eq 0 (apply #'call-process program nil nil nil args)))

(provide 'dwim-shell-command)

;;; dwim-shell-command.el ends here
