;; scheme-utils/watch.scm — reload when a file the config loaded changes.
;;
;; TAKEN FROM Hyprscheme's hyprscheme/watch.scm. What changed is only what had
;; to: the module name, the prefix (`auto-`, since `hl-` is Hyprland's), and the
;; removal of everything that existed because their host supplied the waiter
;; before this file could be loaded. The comments below explaining WHEN to watch
;; and WHAT an event means are theirs and are the reason this module exists.
;;
;; TWO THINGS TO KNOW BEFORE READING:
;;
;; 1. WAITING IS A SEAM, NOT A DEPENDENCY WE BAKE IN.  Waiting on an fd means an
;;    event loop, and which loop differs: Hyprland has `hl--c-on-readable', a
;;    GLib program has the source API. So the host calls
;;    `auto-watch-waiter!' with its waiter, and `auto-watch-start!' when it is
;;    ready.  GLib's is supplied when the host says nothing, because that is
;;    what every program in this tree uses — but nothing runs at LOAD time, so
;;    loading this module neither starts a watch nor needs an event loop yet.
;;
;; 2. A BATCH OF EVENTS IS ONE QUESTION.  The fd is drained on each wakeup and
;;    every event in the batch is collected first; the reload decision is made
;;    ONCE for the batch. Ten events from one save are one reload, not ten.
;;
;; THE LOADER IS NOT HERE.  `auto-load' and `auto-load-config' live in
;; (scheme-utils load), which is the module that reads files; this one only
;; watches the ones that were read.  They were published from here too, and a
;; name exported by two modules is a name whose errors land in the wrong file.

(define-module (scheme-utils watch)
  ;; auto-loaded-files is the only part of this module that is API. Everything
  ;; else is auto--*-prefixed and exported because every top-level define in a
  ;; module here must be (tools/module-audit.py's rule, which is what keeps a
  ;; forgotten export from being invisible) — not because anything outside
  ;; uses them.
  #:export (;; what a host sets up
            auto-watch-waiter! auto-watch-configure! auto-watch-start!
            auto-watch-armed? auto-watch-stop!
            ;; the API a config uses
            auto-loaded-files
            ;; readiness, for a host that would rather poll
            auto-watch-on-readable
            ;; the reload itself
            auto-reload!
            ;; internals, exported because every top-level define here is --
            ;; upstream's convention, kept so a forgotten export is visible
            auto--watch-loaded auto--watch-dirs auto--watch-fd
            auto--watch-recording? auto--watch-waiter-armed?
            auto--watch-canonical auto--watch-join
            auto--watch-dir-watched? auto--watch-dir-of-wd
            auto--watch-dir! auto--watch-note-loaded!
            auto--watch-interesting? auto--watch-begin!
            auto--watch-arm! auto--watch-changed? auto--watch-mark!
            auto--watch-forget! auto--watch-text
            auto--watch-seen auto--watch-pending auto--watch-settle!
            auto--watch-debounce-ms auto--watch-default-waiter))

(use-modules (scheme-utils inotify))
;; The event loop the default waiter needs.  (g-golf hl-api glib) is where
;; `g-timeout-add' lives -- the debounce below is built on it -- and it is the
;; one place that knows how to make a GClosure out of a Scheme procedure, which
;; the fd source needs for the same reason.
(use-modules (g-golf)
             (g-golf hl-api glib))
(use-modules (ice-9 format)
             (ice-9 optargs))
;; guard for the hook — the same import every other module here carries for it.
;; (No srfi-1: the two alist lookups below are written out rather than reaching
;; for rassoc, which is NOT in (guile) and not in srfi-1 either. The compiler
;; caught that, and a lookup this small is clearer spelled out.)
(use-modules (ice-9 exceptions)
             ;; get-string-all, for the content check below.
             (ice-9 textual-ports))

;; Every path the loader has reported, most recent first. Grows for the life of
;; the plugin and is never cleared: the question an event asks is "is this one of
;; them?", and a file a LATER config stopped loading is still a file some config
;; asked for — watching it one reload too long is harmless, missing one is the
;; bug this exists to fix.
(define auto--watch-loaded '())

;; (dir . wd) — the directory watches we hold, so a directory is watched once
;; however many of its files get loaded.
(define auto--watch-dirs '())

(define auto--watch-fd #f)
;; Whether a file being loaded is the CONFIG's or the host's.  Off until
;; `auto-watch-start!': this module is imported by a program's own module graph,
;; so the program's modules load after it, and recording those would fill the
;; watch list with the source tree instead of the config.  Measured in
;; scheme-desktop: 17 source files were recorded before the config was read.
(define auto--watch-recording? #f)

(define (auto-loaded-files)
  "The files the running config has loaded, most recent first. These are the
   paths whose changes reload the config: the list is what the watcher matches an
   inotify event against, so a file that is not here is not reloading anything.

   A file is added when the loader reads it — (auto-load \"…\"), (auto-load-config
   \"…\"), or a bare (load \"…\") — and stays for the life of the session, so an
   entry can outlive the config that asked for it."
  (reverse auto--watch-loaded))

;; ---- recording a load ---------------------------------------------------------
;; The path is CANONICALISED before it is stored, and that is not tidiness: the
;; loader reports the path as it was GIVEN ((auto-load "sub/x.scm") reports
;; "sub/x.scm"), while an inotify event carries a directory and a bare name. Both
;; sides have to be the same string for the match to work at all.
(define (auto--watch-canonical path)
  (or (false-if-exception (canonicalize-path path)) path))

;; An inotify event for a file inside DIR. Both halves are already canonical —
;; DIR came from a canonical path — so joining them gives the canonical path
;; back, with no symlink surprise.
(define (auto--watch-join dir name)
  (if (string=? dir "/")
      (string-append "/" name)
      (string-append dir "/" name)))

(define (auto--watch-dir-watched? dir)
  (let loop ((l auto--watch-dirs))
    (cond ((null? l) #f)
          ((string=? (caar l) dir) #t)
          (else (loop (cdr l))))))

;; the directory a watch descriptor belongs to — an event carries the wd, so
;; this is what turns it back into a path
(define (auto--watch-dir-of-wd wd)
  (let loop ((l auto--watch-dirs))
    (cond ((null? l) #f)
          ((= (cdar l) wd) (caar l))
          (else (loop (cdr l))))))

(define (auto--watch-dir! dir)
  (unless (auto--watch-dir-watched? dir)
    (let ((wd (inotify-add-watch auto--watch-fd dir
                                 (logior IN-CLOSE-WRITE IN-MOVED-TO IN-CREATE))))
      ;; a directory we cannot watch is not an error worth raising over: the
      ;; file simply does not get its reload
      (when (>= wd 0)
        (set! auto--watch-dirs (acons dir wd auto--watch-dirs))))))

(define (auto--watch-note-loaded! path)
  (let ((full (auto--watch-canonical path)))
    (unless (member full auto--watch-loaded)
      (set! auto--watch-loaded (cons full auto--watch-loaded))
      ;; Watching the DIRECTORY, not the file: a file watch follows the inode,
      ;; so an editor that saves by renaming a temp file over the target would
      ;; leave us watching something nobody will ever write to again.
      (auto--watch-dir! (dirname full)))))

;; ---- the event ---------------------------------------------------------------
(define (auto--watch-interesting? mask)
  (not (zero? (logand mask (logior IN-CLOSE-WRITE IN-MOVED-TO IN-CREATE)))))

(define (auto--watch-on-readable)
  "Drain the fd and act on the batch.

EVERY EVENT IN THE BATCH IS COLLECTED FIRST, and the reload is decided once for
the batch rather than once per event.  The fd is a byte stream, so one read
drains the kernel queue and bytes not looked at are bytes lost -- there is no
rewind -- so all of them are handled either way.  What the batching adds is that
ONE SAVE IS ONE RELOAD: writing a config atomically produces several events
against a watched directory, and asking the question once collapses them.

Returns the paths that changed, so a caller can log or assert on them."
  (let ((changed '()))
    (for-each
     (lambda (ev)
       (let ((mask (inotify-event-mask ev))
             (name (inotify-event-name ev))
             (wd   (inotify-event-wd ev)))
         ;; no name means a watch-level event (IN-IGNORED, IN-Q-OVERFLOW) rather
         ;; than a file being touched, so there is nothing to match
         (when (and name (auto--watch-interesting? mask))
           (let ((dir (auto--watch-dir-of-wd wd)))
             (when dir
               (let ((path (auto--watch-join dir name)))
                 (when (member path auto--watch-loaded)
                   (unless (member path changed)
                     (set! changed (cons path changed))))))))))
     ;; One bufferful per wakeup; the fd stays readable until drained, so the
     ;; event loop calls this again for anything left over.
     (inotify-read-events auto--watch-fd))
    ;; NOW, once, for the whole batch.  Guarded: this runs from an fd callback,
    ;; where an error that escapes does not fail a reload, it fails the PROCESS.
    (when (pair? changed)
      (catch #t
        (lambda () (auto--watch-arm! (car changed)))
        (lambda (key . rest)
          (format (current-error-port)
                  "scheme-utils: reload failed: ~a ~s~%" key rest))))
    (reverse changed)))

;; ---- the reload --------------------------------------------------------------

(define %reload #f)

(define (auto-reload!)
  "Call the reload the host configured, if any; #f when there is none.

The reload is a THUNK the host hands over through `auto-watch-configure!', and
this calls it.  Naming the call here rather than letting callers reach for the
stored procedure is what makes `reload' belong to the host: this module never
knows what rebuilding means."
  (if %reload (%reload) #f))

;; ---- wiring ------------------------------------------------------------------
;;
;; NOTHING HAPPENS AT LOAD TIME, and that is the difference from upstream.  Their
;; host supplies `hl--c-on-readable' and this file opened the fd and TRIED TO ARM
;; at load, guarded, because outside the compositor that symbol is unbound -- the
;; guard existed so that `make scm-compile' did not die with
;;
;;     guile: uncaught exception: Unbound variable: hl--c-on-readable
;;
;; and hyprpm reported the resulting abort as a successful build.
;;
;; Here the host says when.  `auto-watch-waiter!' takes the one primitive this
;; module cannot provide -- call this thunk when this fd is readable -- and
;; `auto-watch-start!' opens the fd and hands it over.  Until then there is no
;; fd, no watch, and nothing to guard.

;; `g_unix_fd_source_new' is NOT exported by (g-golf glib unix-utils) -- only a
;; wrapper that cannot be used is -- so it is reached by name.  Referenced
;; through `module-ref', which sees a module's own bindings whether or not they
;; are exported, rather than by importing something that deliberately is not
;; public.  Looked up once, at load: the module is there or it is not, and a
;; failure then is a failure anyone can see rather than one per wakeup.
(define %raw-unix-fd-source-new
  (let ((m (resolve-module '(g-golf glib unix-utils))))
    (module-ref m 'g_unix_fd_source_new)))

(define (auto--watch-default-waiter fd thunk)
  "Call THUNK whenever FD is readable, on the thread that runs the main loop.

Answers the source id, or #f when the source could not be attached.  The closure
is kept alive by G-Golf's own closure cache, which is what the reference to it
below is doing.

`g-unix-fd-add' would be the obvious call and cannot be used: it converts its
condition through G-Golf's GIOCondition table, that table is #f, and every call
dies with

  No applicable method for flags->integer (1)   (flags->integer #f in)

so the source is assembled from the raw bindings instead.  That is what
g-unix-fd-add does internally, and what the commented-out g-io-add-watch-fd in
G-Golf's own hl-api/glib.scm does."
  (catch #t
    (lambda ()
      (let* ((closure (make <closure>
                            #:function (lambda (f condition) (thunk) #t)
                            #:return-type 'boolean
                            #:param-types '(int uint32)))
             ;; 1 is G_IO_IN.  Written as a number because the named form is the
             ;; table that is broken; the constant is one and is not going to
             ;; move.
             (source (%raw-unix-fd-source-new fd 1))
             (g-closure (!g-closure closure))
             (id (g-source-attach
                  (begin (g-source-set-closure source g-closure) source)
                  #f)))
        (g-source-unref source)
        (g-closure-unref g-closure)
        id))
    (lambda (key . rest)
      (format (current-error-port)
              "scheme-utils: cannot wait on the inotify fd: ~a ~s~%" key rest)
      #f)))

(define %waiter auto--watch-default-waiter)

(define (auto-watch-waiter! proc)
  "Say how to wait on a file descriptor.

PROC is called as (proc fd thunk) and must arrange for THUNK to be called when
FD becomes readable.  The one thing this module cannot supply is the LOOP:
waiting means an event loop, and the loop belongs to whatever is hosting this.

  (auto-watch-waiter! hl--c-on-readable)      ; a Hyprland plugin
  ;; and GLib's is what you get without asking

Returns PROC, so a host can set it as it starts."
  (set! %waiter proc)
  proc)

(define* (auto-watch-configure! #:key reload)
  "Say what to call when a watched file changes.

RELOAD takes no arguments and does the rebuilding.  Where a bare config name
resolves is `auto-load-search-path!' in (scheme-utils load), which is the module
that does the resolving -- one fact, in the module that owns it."
  (when reload (set! %reload reload))
  #t)

(define auto--watch-waiter-armed? #f)

(define (auto-watch-armed?)
  "Whether the fd is open and being waited on."
  (and auto--watch-fd auto--watch-waiter-armed? #t))

(define (auto-watch-start!)
  "Open the inotify fd, hand it to the waiter, and start recording loads.

Called by the host once, after `auto-watch-waiter!' and `auto-watch-configure!'.
Anything the config loads AFTER this is a file the config asked for; see the
note on the hook below for why that matters."
  (unless %waiter
    (error "auto-watch-start!: call auto-watch-waiter! first"))
  (unless auto--watch-fd
    (set! auto--watch-fd (inotify-init1 (logior IN-NONBLOCK IN-CLOEXEC)))
    (set! auto--watch-waiter-armed?
          (%waiter auto--watch-fd (lambda () (auto--watch-on-readable)))))
  (set! auto--watch-recording? #t)
  #t)

;; %load-hook is Guile's own "a file is being loaded" notification. It fires for
;; load / load-from-path / primitive-load and does NOT fire for use-modules —
;; exactly the right set: the files a CONFIG chose to read, and none of the
;; machinery's own modules, which are loaded by name on the first generation.
;;
;; The hook that was there is CALLED THROUGH rather than replaced: Guile's
;; default is %load-announce, and dropping someone else's behaviour is not this
;; hook's business. Guarded, because it runs inside Guile's loader: a bad path
;; must never take a load down.
(set! %load-hook
  (let ((previous %load-hook))
    (lambda (file)
      (when (procedure? previous)
        (previous file))
      (guard (e (#t #f))
        (when (and auto--watch-fd auto--watch-recording?)
          (auto--watch-note-loaded! file))))))

;; ---- one reload per save, and only for a real change -------------------------
;;
;; NOT UPSTREAM'S, and it is here because of one thing this module now serves
;; that theirs did not: ATOMIC WRITES.  A config saved by writing a temporary
;; file and renaming it over the target produces MOVED-TO on the target and
;; CLOSE-WRITE and MOVED-FROM on the temporary -- several events for one save,
;; each against a watched directory.  Upstream never saw it because a Hyprland
;; plugin's config is written by an editor, once.
;;
;; THE GUARD IS THE FILE'S TEXT, not a timestamp: an editor that writes the same
;; bytes has changed nothing, and a clock with a coarse resolution can make two
;; real writes look simultaneous.  Reading a small file is cheap and exact.

(define auto--watch-seen (make-hash-table))   ; canonical path -> text when acted on
(define auto--watch-pending #f)
(define auto--watch-debounce-ms 250)

(define (auto--watch-text path)
  "PATH's contents, or #f when it cannot be read."
  (catch #t
    (lambda () (call-with-input-file path (lambda (p) (get-string-all p))))
    (lambda args #f)))

(define (auto--watch-changed? path)
  "Whether PATH's contents differ from what was last ACTED ON."
  (let ((now (auto--watch-text path))
        (was (hash-ref auto--watch-seen path)))
    (and now (not (equal? now was)))))

(define (auto--watch-mark! path)
  "Record PATH's current contents as what we have acted on."
  (let ((text (auto--watch-text path)))
    (when text (hash-set! auto--watch-seen path text))))

(define (auto--watch-forget!)
  "Forget what was seen, so the next event counts as a change.

For a caller that has just deliberately rewritten the files -- a save of its own
-- and knows the change is not one to act on."
  (hash-clear! auto--watch-seen))

(define (auto--watch-arm! path)
  "Arrange a reload if PATH's contents differ from what was last acted on.

Several events for one save collapse into one reload: the timer restarts on each
and only the last one runs.

MARKING HAPPENS ONLY AFTER A RELOAD, never on the way in.  Marking on entry looks
equivalent and is not: every event would record the new text, so by the time the
timer fired the file would match what was recorded and the change would look like
no change at all.  Measured -- it silenced the watcher completely, and it looks
correct while doing it."
  (when auto--watch-pending
    (catch #t (lambda () (g-source-remove auto--watch-pending)) (lambda args #f)))
  (set! auto--watch-pending
        (g-timeout-add auto--watch-debounce-ms
                 (lambda ()
                   (set! auto--watch-pending #f)
                   (when (auto--watch-changed? path)
                     (auto--watch-mark! path)
                     (auto-reload!))
                   ;; GLib deletes a source that returns #f.
                   #f))))

(define (auto--watch-begin! path)
  "Record PATH as it stands now, without watching anything.

For a file the host reads ITSELF rather than through `auto-load' -- a data config
it parses rather than evaluates.  Naming it is what makes it watched: without
this, editing it would do nothing, because nothing ever loaded it and the load
hook never saw it."
  (auto--watch-note-loaded! path)
  (auto--watch-mark! (auto--watch-canonical path))
  #t)

(define* (auto--watch-settle! ms)
  "Wait MS with the main loop running, so a debounce can fire. For probes."
  (let ((loop (g-main-loop-new #f #f)))
    (g-timeout-add ms (lambda () (g-main-loop-quit loop) #f))
    (g-main-loop-run loop)))

(define (auto-watch-stop!)
  "Stop watching: close the fd and forget everything.

The loaded-files list is cleared too, so a host that stops and restarts does not
carry the previous run's paths -- which would be watched again for nothing."
  (when (and auto--watch-fd (exact-integer? auto--watch-fd) (> auto--watch-fd 0))
    (catch #t (lambda () (inotify-close auto--watch-fd)) (lambda args #f)))
  (set! auto--watch-fd #f)
  (set! auto--watch-waiter-armed? #f)
  (set! auto--watch-recording? #f)
  (set! auto--watch-loaded '())
  (set! auto--watch-dirs '())
  (hash-clear! auto--watch-seen)
  #t)
