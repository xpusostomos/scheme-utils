;;; tests/repl.scm -- the back door, end to end, with no editor and no display.
;;;
;;; THE POINT OF THIS FILE is that it drives the real machinery: a real Unix
;;; socket in a scratch directory, a real client, a real evaluation that sees the
;;; program's own live state.  What it must NOT need is a display or a second
;;; process -- so it plays both halves itself.
;;;
;;; PLAYING BOTH HALVES IS THE WHOLE DIFFICULTY, AND IT HAS ONE RULE:
;;; THE CLIENT HALF RUNS IN A THREAD AND THE PUMPING HAPPENS HERE.  The
;;; cooperative server reads on its own thread but EVALUATES on whichever thread
;;; calls `poll-repl!', so this thread polls (which is what makes the program
;;; evaluate anything) and the client thread does the blocking reads.
;;;
;;; ONE THREAD CANNOT DO BOTH.  It is tempting to write send-poll-read in a single
;;; thread, and it works for a VALUE -- but an expression that ERRORS leaves the
;;; program in a debugger waiting to read from this same socket, and the thread
;;; that would answer it is the one blocked inside `poll-repl!'.  That deadlock is
;;; real: it is what this file hit first, it hangs with no output at all, and it
;;; is why every group below runs its client in a thread.

(use-modules (scheme-utils repl server))
(use-modules (scheme-utils repl client))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-13))
(use-modules (srfi srfi-64))
(use-modules (ice-9 format))
(use-modules (ice-9 threads))
(use-modules ((guile) #:select (AF_UNIX SOCK_STREAM socket bind close)))

;; ---------------------------------------------------------------------------
;; The host settings, pointing at a scratch directory
;; ---------------------------------------------------------------------------
;;
;; `run-tests.scm' sets SCHEME_UTILS_TEST_DIR and the suite uses it, so both
;; suites share one scratch directory.  RUN STANDALONE with nothing set -- as
;; `guile -L . tests/repl.scm' -- it makes its own, named for the process, which
;; is what makes this file runnable on its own while debugging without also
;; needing the runner's environment.
;;
;; The real XDG_RUNTIME_DIR is left alone on purpose: a test that wrote into it
;; would leave sockets behind in the user's session directory, which is the one
;; place they would be least welcome.

(define %test-root
  (or (getenv "SCHEME_UTILS_TEST_DIR")
      (string-append "/tmp/scheme-utils-repl-test-" (number->string (getpid)))))

(define (test-dir)
  "The scratch directory, made if it is not there -- INCLUDING ITS PARENT.

The parent is the part that bit: `(mkdir .../repl)' fails with \"No such file or
directory\" when .../repl's own parent does not exist, so a standalone run died
before a single test with a message about mkdir rather than about sockets."
  (let ((dir (string-append %test-root "/repl")))
    (unless (file-exists? %test-root) (mkdir %test-root #o700))
    (unless (file-exists? dir) (mkdir dir #o700))
    dir))

(repl-directory! (test-dir))
(repl-create-directory?! #t)
(repl-name! (lambda () "scheme-utils-test-repl"))
(repl-module! '(guile-user))

;; ---------------------------------------------------------------------------
;; Driving it
;; ---------------------------------------------------------------------------

(define* (pump-until-readable! socket #:optional (tries 400))
  "Poll the program until SOCKET has something to read.  #t when it does.

THE POLL IS THE POINT: the server queues the banner and the answers from its
reader thread, and nothing happens on them until this thread polls."
  (let loop ((n 0))
    (cond ((char-ready? socket) #t)
          ((>= n tries) #f)
          (else (poll-repl!) (usleep 5000) (loop (+ n 1))))))

(define (open-and-greet! location)
  "A socket connected to LOCATION, its banner already consumed."
  (let ((socket (repl-open-session location)))
    (pump-until-readable! socket)
    (repl-read-to-prompt socket)        ; the banner
    socket))

(define (ask! socket expression)
  "Send EXPRESSION, answer the reply as a list (TEXT FAILED?).

THE CLIENT IS IN A THREAD -- see the header.  When the answer is an ERROR it also
puts the program's debugger away with `,q' before returning, and that is not
tidiness: a session left in a debugger reads the NEXT expression as a debugger
command, so without it every later assertion would be answering the wrong
reader.  It is the failure a one-shot client has in a long-lived session."
  (let ((box (list #f)))
    (call-with-new-thread
     (lambda ()
       (repl-send socket expression)
       (let ((answer (repl-read-to-prompt socket)))
         (if (and answer (repl-answer-error? answer))
             (begin
               ;; Leave the debugger, and consume the top-level prompt it returns
               ;; to, so the session is where the next expression expects it.
               (repl-send socket ",q")
               (let loop ((n 0))
                 (cond ((char-ready? socket) (repl-read-to-prompt socket))
                       ((>= n 400) #f)
                       (else (usleep 5000) (loop (+ n 1)))))
               (set-car! box (list (repl-answer-text answer) #t)))
             (set-car! box
                       (list (if answer (repl-answer-text answer) "") #f))))))
    ;; This thread polls until the client thread has its answer.
    (let loop ((n 0))
      (let ((done (car box)))
        (cond (done done)
              ((>= n 4000) (list "" #t))
              (else (poll-repl!) (usleep 2000) (loop (+ n 1))))))))

(define (answer-text reply) (car reply))
(define (answer-failed? reply) (cadr reply))

(define (value-of text)
  "TEXT with the REPL's `$N = ' echo taken off.

Guile's REPL prints `$1 = 3' rather than `3' when its input is NOT a terminal --
which a socket never is -- so the value a person means sits behind that prefix.
Stripped here rather than in the library: the client returns what the program
SAID, and a caller that wants the bare value is the one who knows."
  (let ((eq (string-contains text "= ")))
    (if (and eq (string-prefix? "$" text))
        (substring text (+ eq 2) (string-length text))
        text)))

(test-begin "repl")

(test-group "no fallback to /tmp when there is no runtime directory"
  ;; THE SAFETY PROPERTY, asserted rather than described.  The variable is
  ;; unset and restored rather than assumed absent: on a session where it IS set
  ;; the guard is never reached, and the test would pass without testing
  ;; anything -- which is how this one was written first.
  (let ((saved (getenv "XDG_RUNTIME_DIR")))
    (setenv "XDG_RUNTIME_DIR" "")
    (test-assert "the runtime directory is refused when unset"
      (catch #t (lambda () (repl-runtime-directory) #f) (lambda args #t)))
    (if saved
        (setenv "XDG_RUNTIME_DIR" saved)
        (unsetenv "XDG_RUNTIME_DIR")))
  (test-assert "and the directory it names is never /tmp"
    (let ((dir (repl-directory! #f)))
      (let ((resolved (catch #t (lambda () (repl-directory) #f) (lambda args #f))))
        (repl-directory! (test-dir))
        (or (not resolved) (not (string-prefix? "/tmp" resolved)))))))


;; ---------------------------------------------------------------------------

(test-group "the endpoint is where the host said, and is not a TCP port"
  (test-equal "the directory is the one the host configured"
    (test-dir) (repl-directory))
  (test-equal "the instance name is the one the host configured"
    "scheme-utils-test-repl" (repl-name))
  (test-assert "the endpoint is a path, not a port number"
    (string? (repl-endpoint-path)))
  (test-assert "and it ends in .sock, which is what makes listing a directory"
    (string-suffix? ".sock" (repl-endpoint-path))))

(test-group "the back door opens, answers, and closes"
  (test-assert "not running to begin with" (not (repl-running?)))
  (let ((location (start-repl!)))
    (test-assert "start-repl! answered a location" location)
    (test-assert "and it is the endpoint path we expect"
      (string=? location (repl-endpoint-path)))
    (test-assert "running now" (repl-running?))
    (test-assert "the socket file exists" (file-exists? location))
    (test-assert "and something is listening on it" (socket-alive? location))

    ;; THE ROUND TRIP the module exists for.
    (let ((socket (open-and-greet! location)))
      (test-assert "a client can connect and is greeted" socket)
      (let ((reply (ask! socket "(+ 1 2)")))
        (test-assert "the expression did not fail" (not (answer-failed? reply)))
        (test-equal "and its value came back" "3" (value-of (answer-text reply))))
      (repl-close socket))

    (stop-repl!)
    (test-assert "stopped" (not (repl-running?)))
    (test-assert "and the socket file is gone, so `list' stops offering it"
      (not (file-exists? location)))))

(test-group "an expression runs against the program's own live state"
  ;; THE REASON FOR A BACK DOOR RATHER THAN A PROTOCOL: what is evaluated is
  ;; live state, so a name one expression defines is visible to the next.
  (let* ((location (start-repl!))
         (socket (open-and-greet! location)))
    (ask! socket "(define repl-test-value 41)")
    (test-equal "a later expression sees an earlier one's define"
      "42" (value-of (answer-text (ask! socket "(+ repl-test-value 1)"))))
    (test-equal "and it is evaluated in the module the host pinned"
      "(guile-user)"
      (value-of (answer-text (ask! socket "(module-name (current-module))"))))
    (repl-close socket)
    (stop-repl!)))

(test-group "a session survives an error and is usable afterwards"
  ;; THE DEADLOCK THIS FILE FOUND, turned into an assertion: an error leaves the
  ;; program in a debugger, and a session that does not come back from it reads
  ;; the next expression as a debugger command.
  (let* ((location (start-repl!))
         (socket (open-and-greet! location)))
    (let ((reply (ask! socket "(car 5)")))
      (test-assert "the error is reported as an error" (answer-failed? reply))
      (test-assert "and the message says what failed"
        (string-contains (answer-text reply) "car")))
    (test-equal "and the very next expression is answered normally"
      "7" (value-of (answer-text (ask! socket "(+ 3 4)"))))
    (repl-close socket)
    (stop-repl!)))

(test-group "a value that merely LOOKS like an error is not one"
  ;; THE OTHER HALF OF THE DISTINCTION, and why "ends in >" was the wrong test:
  ;; a value can end in > too, and a string can hold a whole nested prompt.
  (let ((location (start-repl!)))
    (let ((socket (open-and-greet! location)))
      (test-assert "a string containing a nested prompt is a value"
        (not (answer-failed? (ask! socket "\"scheme@(guile-user) [1]> \""))))
      (repl-close socket))
    (stop-repl!)))

(test-group "the error test is about the prompt, not the text"
  ;; Unit-level, because these two helpers ARE the distinction and a live error
  ;; is expensive to arrange.
  (test-assert "a plain prompt is not an error"
    (not (repl-answer-error? "3\nscheme@(guile-user)> ")))
  (test-assert "a nested prompt is"
    (repl-answer-error? "boom\nscheme@(guile-user) [1]> "))
  (test-assert "a value ending in > is not, whatever it looks like"
    (not (repl-answer-error? "#<buffer README.md>\nscheme@(guile-user)> ")))
  (test-equal "and the prompt line is what gets stripped"
    "3" (repl-answer-text "3\nscheme@(guile-user)> ")))

(test-group "a client that walks the instances finds the one that answers"
  (let ((location (start-repl!)))
    (test-assert "the running instance is listed"
      (member "scheme-utils-test-repl" (live-instances)))
    (test-assert "and it is the socket that answers" (socket-alive? location))
    (test-assert "repl-connect-any skips a name that does not answer"
      (repl-connect-any '("scheme-utils-test-nope" "scheme-utils-test-repl")))
    (stop-repl!)))

(test-group "two back doors can be open at once"
  ;; WHY THE MODULE HOLDS NO SINGLETON.  A program that opens one back door per
  ;; document has several, which is what `repl-state!' and `repl-restore!' are
  ;; for -- the state is a pair the host keeps.
  (let* ((first-location (start-repl!))
         (saved (repl-state!)))
    (stop-repl!)
    (let ((second-location (start-repl! #:name "scheme-utils-test-repl-2")))
      (test-assert "the second has its own endpoint"
        (not (string=? first-location second-location)))
      (test-assert "and it is the live one" (socket-alive? second-location))
      (test-assert "while the first's file is gone"
        (not (file-exists? first-location)))
      (stop-repl!))
    (repl-restore! saved)
    (test-assert "the first is running again from its saved state" (repl-running?))
    (stop-repl!)
    (test-assert "and its socket was removed on the way out"
      (not (file-exists? first-location)))))

(test-group "a stale socket is not mistaken for a live one"
  ;; THE FAILURE THIS GUARDS: a socket left by a crashed program looks IDENTICAL
  ;; to a live one on disk -- same type, same permissions -- so anything that
  ;; tests for the FILE is wrong, and this is the test that says so.
  (let ((location (repl-endpoint-path "scheme-utils-test-stale")))
    (let ((sock (socket AF_UNIX SOCK_STREAM 0)))
      (bind sock AF_UNIX location)
      (close sock))
    (test-assert "the file is there" (file-exists? location))
    (test-assert "but nothing is listening on it" (not (socket-alive? location)))
    (test-assert "so it is not offered as an instance"
      (not (member "scheme-utils-test-stale" (live-instances))))
    (test-assert "and a client will not take it"
      (not (repl-connect location)))
    (catch #t (lambda () (delete-file location)) (lambda args #f))))

(test-group "a dead socket at the path does not stop a restart"
  (let ((location (start-repl!)))
    (stop-repl!)
    ;; Leave a dead socket where the live one was, exactly as a crash would.
    (let ((sock (socket AF_UNIX SOCK_STREAM 0)))
      (bind sock AF_UNIX location)
      (close sock))
    (test-assert "start-repl! copes with it"
      (catch #t (lambda () (start-repl!) #t) (lambda args #f)))
    (test-assert "and the back door is running" (repl-running?))
    (stop-repl!)))

(test-end "repl")
