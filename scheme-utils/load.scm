;;; scheme-utils/load.scm -- load a user's config, and everything it pulls in
;;;
;;; TAKEN FROM Hyprscheme's `hl-load` / `hl-load-config` (hyprscheme/core.scm and
;;; hyprscheme/extras.scm).  Both contracts are theirs: an error in a loaded file
;;; does not stop the rest of the config, and the loader ANSWERS whether it
;;; loaded, so a caller can tell a file that died halfway from one that worked.
;;;
;;; WHY A LOADER AT ALL, rather than Guile's `load`:
;;;
;;;   - `load` evaluates into whatever module is current.  For a program started
;;;     with `-e main -s FILE` that is `(guile-user)`, where none of the
;;;     program's own names exist -- so a config could not call any of them.
;;;   - A config that pulls in a file by name wants the file looked up where a
;;;     config lives, and that is per program.
;;;   - Nothing in Guile reports WHICH files a config loaded, and the watcher
;;;     needs exactly that.  `primitive-load` goes through `%load-hook`, so
;;;     (scheme-utils watch) hears about every file this module reads without
;;;     being told.  (That is also why nothing here calls the watcher.)
;;;
;;; THE TARGET MODULE IS THE CALLER'S.  Upstream loads into "the current
;;; generation", which its host owns.  Here it is whatever `auto-load-module!`
;;; names, so the same loader serves a shell whose user module imports the
;;; shell's API and a test with a scratch module of its own.
;;;
;;; READY TO LOAD IS NOT THE SAME AS LOADED.  `auto-load` answers #t/#f, but the
;;; FILE is reported to the watcher as soon as it starts loading -- before it is
;;; evaluated, so before it can fail.  That is deliberate: a config with an error
;;; in it must still reload when the error is fixed, and a watcher told only
;;; about the loads that succeeded would sit there while the user saved the fix
;;; and saw nothing happen.

(define-module (scheme-utils load)
  #:use-module (ice-9 format)
  #:use-module (ice-9 optargs)
  #:export (auto-load-module! auto-load-module
            auto-config-dir! auto-config-dir
            auto-load auto-load-config))

;;; ---------------------------------------------------------------------------
;;; Where a loaded file's defines land, and where a bare name is looked up
;;; ---------------------------------------------------------------------------

(define %module #f)
(define %config-dir #f)

(define (auto-load-module! module)
  "Say which module `auto-load' evaluates into.

MODULE is a module or its name.  A program sets this once; until it does, a load
falls back to the current module, which is what upstream does at all times."
  (set! %module (if (symbol? module) (resolve-module module #:ensure #t) module))
  %module)

(define (auto-load-module)
  "The module `auto-load' evaluates into, or #f when none was set."
  %module)

(define (auto-config-dir! dir)
  "Say where `auto-load-config' looks for a bare name.

A directory rather than a list, because a config directory is one place.  Call it
with #f to clear, and `auto-load-config' then reports rather than guesses."
  (set! %config-dir dir)
  %config-dir)

(define (auto-config-dir)
  "The directory `auto-load-config' searches, or #f."
  %config-dir)

;;; ---------------------------------------------------------------------------
;;; Loading
;;; ---------------------------------------------------------------------------

(define (auto-load path)
  "Load the Scheme file PATH; #t when it loaded, #f when it raised.

PATH is used exactly as given: no search, and no \".scm\" appended.
`auto-load-config' is the one that resolves a name.

What the file defines lands in the module `auto-load-module!' named, and is
discarded by the next reload if the caller rebuilds that module.  An error in it
is REPORTED and does not stop the rest of the config -- but it IS a failure here,
and this answers #f for it, which is what lets `auto-load-config' tell a file
that died halfway through from one that loaded."

  (catch #t
    (lambda ()
      (save-module-excursion
       (lambda ()
         (let ((m (auto-load-module)))
           (when m (set-current-module m))
           (primitive-load path))))
      #t)
    (lambda (key . rest)
      ;; A half-applied config is the state that is hard to diagnose, so the
      ;; error says which file and at what -- not just that something failed.
      (format (current-error-port)
              "scheme-utils: ~a failed to load: ~a ~s~%" path key rest)
      #f)))

(define (auto-load-config name)
  "Load NAME.scm from the config directory, and return its path, or #f.

Resolves a name the way a user means it -- `(auto-load-config \"keybinds\")'
for the config directory's keybinds.scm.  \".scm\" is appended unless NAME
already ends in it.

The resolution is what earns this its place: a path written by hand in a config
has to repeat the config directory, and a directory that moves (XDG_CONFIG_HOME
set on one machine and not another) then breaks the file rather than the
lookup."
  (let* ((file (if (string-suffix? ".scm" name) name (string-append name ".scm")))
         (dir (auto-config-dir))
         (found (and dir (string-append dir "/" file))))
    (cond
     ((not dir)
      (format (current-error-port)
              "scheme-utils: no config directory set; cannot resolve ~a~%" name)
      #f)
     ((not (file-exists? found))
      (format (current-error-port)
              "scheme-utils: no config file called ~a (looked for ~a)~%" name found)
      #f)
     (else
      ;; the loaded file's own path is returned, not the one asked for, so a
      ;; caller can chain: `(auto-load-config (auto-load-config \"base\"))'
      (and (auto-load found) found)))))
