;;; tests/run-tests.scm -- the suites for scheme-utils.
;;;
;;;   make test
;;;
;;; TIER 1 IS NOT ENOUGH FOR THIS TREE.  Two of its three modules are about
;;; events arriving from the kernel, and a unit test of a parser would pass with
;;; the watch never armed at all.  So the watch tests here drive the REAL
;;; machinery: a real inotify fd, a real file written by this process, and a real
;;; GLib main loop run until the debounce has had its chance.  What they assert is
;;; the thing that would otherwise be found by hand -- that an edit reaches the
;;; reload, once, and that rewriting identical bytes does not.

(use-modules (srfi srfi-64)
             (srfi srfi-1)
             (ice-9 format)
             (ice-9 ftw)              ; scandir
             (ice-9 textual-ports)
             (scheme-utils inotify)
             (scheme-utils load)
             (scheme-utils watch))

(test-begin "scheme-utils")

;;; ---------------------------------------------------------------------------
;;; A scratch directory of our own
;;; ---------------------------------------------------------------------------
;; Named for the process, so two runs -- or one run left behind by a crash --
;; cannot see each other's files.

(define %scratch
  (string-append "/tmp/scheme-utils-test-" (number->string (getpid))))

(define (scratch name) (string-append %scratch "/" name))

(define (scratch-files)
  (if (file-exists? %scratch)
      (scandir %scratch (lambda (f) (not (member f '("." "..")))))
      '()))

(define (scratch-reset!)
  (when (file-exists? %scratch)
    (for-each (lambda (f) (delete-file (scratch f))) (scratch-files)))
  (unless (file-exists? %scratch) (mkdir %scratch)))

(define (write-text path text)
  (call-with-output-file path (lambda (p) (display text p))))

(scratch-reset!)

;;; ---------------------------------------------------------------------------
;;; inotify
;;; ---------------------------------------------------------------------------

(test-group "inotify"
  ;; a GROUP rather than a test-assert around a let: srfi-64 wants nesting spelt
  ;; with test-group, and an assert wrapped around other asserts is recorded
  ;; under the wrong name.
  (test-group "an instance opens non-blocking"
    (let ((fd (inotify-init1 (logior IN-NONBLOCK IN-CLOEXEC))))
      (test-assert "fd is a live descriptor" (and (exact-integer? fd) (> fd 0)))
      (test-assert "closing it works" (zero? (inotify-close fd)))))

  (test-group "a watch on a directory reports a file created in it"
    (let* ((fd (inotify-init1 (logior IN-NONBLOCK IN-CLOEXEC)))
           (wd (inotify-add-watch fd %scratch (logior IN-CREATE IN-CLOSE-WRITE))))
      (test-assert "the watch was accepted" (>= wd 0))
      (write-text (scratch "created.scm") ";; hello\n")
      ;; the kernel queues the event on the fd; one read takes it
      (let ((events (inotify-read-events fd)))
        (test-assert "at least one event came back" (pair? events))
        (test-assert "and it names the file"
          (any (lambda (ev) (equal? (inotify-event-name ev) "created.scm")) events))
        (test-assert "and it carries the create flag"
          (any (lambda (ev) (not (zero? (logand (inotify-event-mask ev) IN-CREATE))))
               events)))
      (inotify-close fd)))

  (test-group "reading an idle descriptor"
    (let ((fd (inotify-init1 (logior IN-NONBLOCK IN-CLOEXEC))))
      (test-equal "gives an empty list, not a block" '() (inotify-read-events fd))
      (inotify-close fd))))

;;; ---------------------------------------------------------------------------
;;; the loader
;;; ---------------------------------------------------------------------------
;; `auto-load-config' resolves against `auto-config-dir', which is the one place
;; a bare name can come from.  Both halves are worth pinning: a name that
;; resolves to the wrong file is worse than one that does not resolve.

(test-group "load"
  (auto-config-dir! %scratch)
  (write-text (scratch "greeting.scm") "(define greeting \"hi\")\n")

  (test-assert "a bare name resolves under the config directory"
    (string=? (auto-load-config "greeting") (scratch "greeting.scm")))

  (test-assert "an explicit .scm is not doubled up"
    (string=? (auto-load-config "greeting.scm") (scratch "greeting.scm")))

  (test-assert "a name with no file is #f, not an error"
    (not (auto-load-config "no-such-file-here")))

  (test-assert "clearing the config directory makes resolution report, not guess"
    (begin (auto-config-dir! #f)
           (and (not (auto-load-config "greeting"))
                (begin (auto-config-dir! %scratch) #t))))

  ;; THE CONTRACT THAT MATTERS: a file that raises answers #f and the caller
  ;; carries on.  A config is many files and one bad one is not the end of it.
  (write-text (scratch "broken.scm") "(this is (not (valid\n")
  (test-assert "a file that raises answers #f"
    (not (auto-load (scratch "broken.scm"))))
  (test-assert "and the next file still loads"
    (auto-load (scratch "greeting.scm"))))

;;; ---------------------------------------------------------------------------
;;; the watcher
;;; ---------------------------------------------------------------------------
;; THE POINT OF THE WHOLE MODULE.  Each of these drives a real fd and a real main
;; loop, because the failure they exist to catch -- an edit that produces no
;; reload, or a save that produces three -- is invisible to any test that stubs
;; the event.

(define %reloads 0)

(test-group "watch"
  ;; NOTHING HAS HAPPENED YET, and that is assertable: the module was loaded
  ;; several groups ago and has opened no fd.
  (test-assert "nothing is armed before the host says so"
    (not (auto-watch-armed?)))

  (auto-watch-configure! #:reload (lambda () (set! %reloads (+ %reloads 1))))
  (auto-watch-start!)

  (test-assert "start! opens the fd and reports it armed"
    (auto-watch-armed?))

  ;; A file the LOADER reads is a file the watcher must know about.  If this ever
  ;; stops being true, every reload silently stops working, so it is the first
  ;; thing pinned.
  (write-text (scratch "watched.scm") ";; version one\n")
  (auto-load (scratch "watched.scm"))
  (test-assert "the loader reports what it read"
    (member (scratch "watched.scm") (auto-loaded-files)))

  ;; AND NOTHING ELSE IS REPORTED.  This is the regression test for the way the
  ;; list used to be built: upstream took it from `%load-hook', which fires for
  ;; every file the PROCESS loads, so the moment anything was evaluated over the
  ;; REPL Guile compiled it -- and its compiler sources went into the watch list,
  ;; 60 of them, none of them anything a config asked for.
  ;;
  ;; The directory IS watched either way, so an event for this file does arrive;
  ;; what must not happen is the event matching anything.
  (let ((baseline %reloads))
    (write-text (scratch "by-hand.scm") ";; loaded by direct primitive-load\n")
    (primitive-load (scratch "by-hand.scm"))
    (test-assert "a file loaded by primitive-load is NOT recorded"
      (not (member (scratch "by-hand.scm") (auto-loaded-files))))
    (write-text (scratch "by-hand.scm") ";; and then changed\n")
    (auto--watch-settle! 600)
    (test-equal "so editing it does not reload" baseline %reloads))

  (let ((baseline %reloads))
    (write-text (scratch "watched.scm") ";; version two\n")
    (auto--watch-settle! 600)
    (test-equal "an edit reaches the reload, exactly once" (+ baseline 1) %reloads))

  (let ((baseline %reloads))
    (write-text (scratch "watched.scm") ";; version two\n")
    (auto--watch-settle! 600)
    (test-equal "rewriting the same bytes does not reload" baseline %reloads))

  (let ((baseline %reloads))
    (write-text (scratch "stranger.scm") ";; not loaded by anyone\n")
    (auto--watch-settle! 600)
    (test-equal "a file nothing loaded does not reload" baseline %reloads))

  ;; A FILE NAMED BUT NEVER LOADED is the case `auto--watch-begin!' exists for:
  ;; the host reads it itself (a data config it parses), so the load hook never
  ;; sees it, and without this it would never reload.
  (let ((baseline %reloads))
    (write-text (scratch "data.scm") "((a 1))\n")
    (auto--watch-begin! (scratch "data.scm"))
    (test-assert "begin! adds a file the loader never saw"
      (member (scratch "data.scm") (auto-loaded-files)))
    (write-text (scratch "data.scm") "((a 2))\n")
    (auto--watch-settle! 600)
    (test-equal "and an edit to it reloads" (+ baseline 1) %reloads))

  (test-assert "stop! disarms and forgets"
    (and (auto-watch-stop!)
         (not (auto-watch-armed?))
         (null? (auto-loaded-files)))))

;;; ---------------------------------------------------------------------------
;;; the back door
;;; ---------------------------------------------------------------------------
;; LOADED rather than run as a second process: srfi-64 nests, so its assertions
;; join this suite's total instead of printing another summary that `make test'
;; would have to know how to read.  It is still a real file with its own
;; test-begin and test-end, so it can be run on its own while debugging:
;;
;;   SCHEME_UTILS_TEST_DIR=/tmp/x guile -L . tests/repl.scm
;;
;; THE ENVIRONMENT IT NEEDS IS SET HERE, and it is the point of the variable:
;; the suite puts its sockets in the scratch directory rather than in the user's
;; XDG_RUNTIME_DIR.  A test that wrote there would leave sockets behind in the
;; one directory they would be least welcome in.
;;
;; THE REAL XDG_RUNTIME_DIR IS LEFT ALONE apart from one assertion, which unsets
;; it, checks the refusal, and puts it back -- see the last group.

(setenv "SCHEME_UTILS_TEST_DIR" %scratch)
;; "repl.scm", NOT "tests/repl.scm": Guile resolves a relative `load' against the
;; directory of the file DOING the loading, so the longer path became
;; "tests/tests/repl.scm" and the runner died with "Unable to find file".
(load "repl.scm")

;;; ---------------------------------------------------------------------------

(test-end "scheme-utils")

;; Leave nothing behind.
(catch #t
  (lambda ()
    (for-each (lambda (f) (delete-file (scratch f))) (scratch-files))
    (rmdir %scratch))
  (lambda args #f))
