;; scheme-utils/inotify.scm — Linux inotify, reached through (system foreign).
;;
;; TAKEN FROM Hyprscheme's hyprscheme/inotify.scm, and kept as close to it as the
;; rename allows: the body below is theirs apart from the module name. It was
;; written for a Hyprland plugin and had to solve the same problem there.
;;
;; NO C. (system foreign) calls libc directly, so the kernel interface is
;; available from Scheme. What this module cannot do is WAIT — waiting on an fd
;; means an event loop, and which loop differs per host; that one primitive is
;; supplied by the caller (see `auto-watch-waiter!' in (scheme-utils watch)) and
;; everything else is here.
;;
;; WHY IT IS BOUND BY HAND: Guile has no inotify binding — there is no
;; (ice-9 inotify), and no inotify symbol anywhere in libguile — and the
;; third-party `guile-inotify' is GPL-3.0, which is a blocker for a tree that is
;; not.
;;
;; A LEAF: it imports nothing of ours and holds no knowledge of what is being
;; watched. The names here are the inotify(7) ones on purpose — the whole value
;; of this module is that it reads like the man page.

(define-module (scheme-utils inotify)
  ;; The raw C bindings and the parser are exported ALONGSIDE the wrappers, and
  ;; that is this tree's convention rather than an oversight: every machinery
  ;; module publishes its internals (the families export their hl--* helpers),
  ;; and tools/module-audit.py's rule — every top-level define is in #:export —
  ;; is what keeps a forgotten export from being invisible. Nothing outside
  ;; (scheme-utils watch) imports this module.
  #:export (inotify-init inotify-init1 inotify-add-watch inotify-remove-watch
            inotify-close inotify-read-events
            inotify-event-mask inotify-event-name inotify-event-wd
            IN-NONBLOCK IN-CLOEXEC
            IN-ACCESS IN-MODIFY IN-ATTRIB IN-CLOSE-WRITE
            IN-CLOSE-NOWRITE IN-OPEN IN-MOVED-FROM IN-MOVED-TO
            IN-CREATE IN-DELETE IN-DELETE-SELF IN-MOVE-SELF
            IN-UNMOUNT IN-Q-OVERFLOW IN-IGNORED
            IN-CLOSE IN-MOVE IN-ALL-EVENTS
            IN-ONLYDIR IN-DONT-FOLLOW IN-EXCL-UNLINK
            IN-MASK-CREATE IN-MASK-ADD IN-ISDIR IN-ONESHOT
            libc libc-procedure
            c-inotify-init c-inotify-init1 c-inotify-add-watch
            c-inotify-rm-watch c-read c-close
            EVENT-HEADER parse-events))

(use-modules (system foreign))
(use-modules (rnrs bytevectors))

;; ---- the C calls --------------------------------------------------------------
;; (dynamic-link) with NO argument links against the global namespace, which is
;; how libc is reached: these symbols are not in a library we name, they are in
;; libc, already loaded into the process. Naming a path here would be wrong (the
;; loader's search, ld.so's cache and a musl/glibc split are all its business,
;; not ours).
(define libc (dynamic-link))

;; NOT called `pointer->procedure`: that is the name (system foreign) exports,
;; and shadowing an import inside a module means anything else here that wants
;; the real one silently gets this. Guile's takes a POINTER; this takes a NAME
;; and looks it up — a different job, so it gets a different name.
(define (libc-procedure return-type internal-name argument-types)
  (pointer->procedure return-type (dynamic-func internal-name libc) argument-types))

(define c-inotify-init  (libc-procedure int "inotify_init" '()))
(define c-inotify-init1 (libc-procedure int "inotify_init1" (list int)))
(define c-inotify-add-watch
  (libc-procedure int "inotify_add_watch" (list int '* uint32)))
(define c-inotify-rm-watch
  (libc-procedure int "inotify_rm_watch" (list int int)))
(define c-read  (libc-procedure ssize_t "read" (list int '* size_t)))
(define c-close (libc-procedure int "close" (list int)))

(define IN-ACCESS        #x00000001)    ;; File was accessed
(define IN-MODIFY        #x00000002)    ;; File was modified
(define IN-ATTRIB        #x00000004)    ;; Metadata changed
(define IN-CLOSE-WRITE   #x00000008)    ;; Writable file was closed
(define IN-CLOSE-NOWRITE #x00000010)    ;; Unwritable file closed
(define IN-OPEN          #x00000020)    ;; File was opened
(define IN-MOVED-FROM    #x00000040)    ;; File was moved from X
(define IN-MOVED-TO      #x00000080)    ;; File was moved to Y
(define IN-CREATE        #x00000100)    ;; Subfile was created
(define IN-DELETE        #x00000200)    ;; Subfile was deleted
(define IN-DELETE-SELF   #x00000400)    ;; Self was deleted
(define IN-MOVE-SELF     #x00000800)    ;; Self was moved

;; the following are legal events.  they are sent as needed to any watch
(define IN-UNMOUNT       #x00002000)    ;; Backing fs was unmounted
(define IN-Q-OVERFLOW    #x00004000)    ;; Event queued overflowed
(define IN-IGNORED       #x00008000)    ;; File was ignored

;; helper events
(define IN-CLOSE         (logior IN-CLOSE-WRITE IN-CLOSE-NOWRITE)) ;; close
(define IN-MOVE          (logior IN-MOVED-FROM IN-MOVED-TO))       ;; moves

;; special flags
(define IN-ONLYDIR       #x01000000)    ;; only watch the path if it is a directory
(define IN-DONT-FOLLOW   #x02000000)    ;; don't follow a sym link
(define IN-EXCL-UNLINK   #x04000000)    ;; exclude events on unlinked objects
(define IN-MASK-CREATE   #x10000000)    ;; only create watches
(define IN-MASK-ADD      #x20000000)    ;; add to the mask of an already existing watch
(define IN-ISDIR         #x40000000)    ;; event occurred against dir
(define IN-ONESHOT       #x80000000)    ;; only send event once

(define IN-ALL-EVENTS (logior IN-ACCESS IN-MODIFY IN-ATTRIB IN-CLOSE-WRITE
                              IN-CLOSE-NOWRITE IN-OPEN IN-MOVED-FROM
                              IN-MOVED-TO IN-DELETE IN-CREATE IN-DELETE-SELF
                              IN-MOVE-SELF))

;; ---- flags, straight from inotify(7) ------------------------------------------
;; inotify_init1
(define IN-NONBLOCK #o00004000)
(define IN-CLOEXEC  #o02000000)


;; ---- the wrappers -------------------------------------------------------------
(define (inotify-init)
  "Open an inotify instance the old way: BLOCKING, and without close-on-exec.
   Prefer inotify-init1 — a blocking fd read on the compositor's thread is the
   one thing this interface must never be used for."
  (c-inotify-init))

(define (inotify-init1 flags)
  "Open an inotify instance with FLAGS (IN-NONBLOCK, IN-CLOEXEC, or their
   logior). Answers a file descriptor, or a negative number on failure."
  (c-inotify-init1 flags))

(define (inotify-add-watch fd path mask)
  "Watch PATH (a string) for the events in MASK, on the inotify instance FD.
   Answers the watch descriptor, or a negative number on failure. Watching a
   DIRECTORY is what usually wants doing: a file watch follows the inode, so an
   editor that saves by renaming a temp file over the target silently outlives
   it, while a directory watch reports the rename by name."
  (c-inotify-add-watch fd (string->pointer path) mask))

(define (inotify-remove-watch fd wd)
  "Drop the watch WD from the inotify instance FD."
  (c-inotify-rm-watch fd wd))

(define (inotify-close fd)
  "Close an inotify file descriptor."
  (c-close fd))

;; One event: the header is 16 bytes (int wd; uint32 mask; uint32 cookie;
;; uint32 len) followed by the NUL-padded name when len is non-zero. 16 is the
;; size on every 64-bit target this plugin builds for.
(define EVENT-HEADER 16)

(define (inotify-event-wd ev)   "The watch descriptor an event came from." (assq-ref ev 'wd))
(define (inotify-event-mask ev) "The event's mask — the flags it fired for." (assq-ref ev 'mask))
(define (inotify-event-name ev) "The NAME within the watched directory, as a string, or #f."
  (assq-ref ev 'name))

(define (parse-events bv n)
  ;; ONE read(2) RETURNS EVERY QUEUED EVENT, concatenated — not one per call.
  ;; Parsing the first and dropping the rest loses reloads with no error, which
  ;; is why this walks the buffer by each event's own length instead. (The
  ;; version this was based on returned only the first and discarded the tail.)
  (let ((base (bytevector->pointer bv)))
    (let walk ((off 0) (acc '()))
      (if (> (+ off EVENT-HEADER) n)
          (reverse acc)
          (let* ((wd     (bytevector-s32-native-ref bv off))
                 (mask   (bytevector-u32-native-ref bv (+ off 4)))
                 (cookie (bytevector-u32-native-ref bv (+ off 8)))
                 (len    (bytevector-u32-native-ref bv (+ off 12)))
                 ;; the name is NUL-terminated and NUL-padded by the kernel, so
                 ;; a plain C string read is exact; it is a STRING, not a symbol:
                 ;; every filename in the system would otherwise be interned
                 ;; forever
                 (name   (if (> len 0)
                             (pointer->string
                               (make-pointer (+ (pointer-address base) off EVENT-HEADER)))
                             #f)))
            (walk (+ off EVENT-HEADER len)
                  (cons (list (cons 'wd wd) (cons 'mask mask) (cons 'cookie cookie)
                              (cons 'len len) (cons 'name name))
                        acc)))))))

(define (inotify-read-events fd)
  "Read ONE bufferful of events from the NON-BLOCKING inotify instance FD, and
   answer them as a list of alists ((wd . n) (mask . n) (cookie . n) (len . n)
   (name . string-or-#f)), in the order the kernel queued them.

   ONE READ PER CALL on purpose. A read returns however many events fit, and
   there may be more behind it — but the fd stays READABLE until it is drained,
   so the event loop fires again and the next call takes the rest. Looping here
   instead would hang on a blocking fd, and this is not the place to find that
   out. (What matters for correctness is the other half: parsing only the FIRST
   event of a buffer and dropping its tail — which the version this was based on
   did — loses events silently.)"
  (let ((bv (make-bytevector 4096 0)))
    (let ((n (c-read fd (bytevector->pointer bv) 4096)))
      (if (<= n 0)
          '()                      ; nothing queued, or an error: both mean stop
          (parse-events bv n)))))
