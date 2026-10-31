;;; (scheme-utils repl client) -- talk to a program's back door
;;;
;;; The other half of `(scheme-utils repl server)'.  That module lets a program
;;; be controlled by evaluating Scheme in it; this one is how you get there --
;;; connect, send an expression, read the answer.
;;;
;;; THIS PROTOCOL IS THE COOPERATIVE REPL SERVER'S, and nothing invented: a
;;; banner and a prompt when a client arrives, then one answer per expression.
;;; Geiser speaks it, so a client written against this is a client Geiser would
;;; also accept.
;;;
;;; THREE DETAILS, ALL OF THEM EASY TO GET WRONG, AND ALL OF THEM MEASURED:
;;;
;;;   1. THE PROMPT HAS NO NEWLINE AFTER IT -- "scheme@(guile-user)> " -- so
;;;      reading the server's side a LINE at a time waits for ever.  It has to be
;;;      a CHARACTER at a time, testing the line built so far.
;;;
;;;   2. AN ERROR LEAVES A *NESTED* PROMPT: "scheme@(guile-user) [1]> ".  That
;;;      bracket is Guile saying it is in a debugger, and it is the only reliable
;;;      way to tell an error from a value that merely LOOKS like one.  Testing
;;;      for "ends in >" is not enough: a value can end in > too, as
;;;      `#<buffer README.md>' does, and the loose test then stops reading before
;;;      the prompt has arrived -- so the next expression is answered by the
;;;      remains of the previous one's answer.
;;;
;;;   3. THE PROMPT IS TESTED AS THE **LAST LINE**, not as the end of the text.
;;;      Same reason as (2), from the other side.
;;;
;;; WHAT THIS MODULE DOES NOT DO is find the program.  It takes a socket, or asks
;;; `(scheme-utils repl server)' for the ones that are running -- which is a
;;; directory listing, because that is the whole point of the Unix socket.  A
;;; host that speaks this protocol over something else supplies its own socket and
;;; uses everything here unchanged.

(define-module (scheme-utils repl client)
  #:use-module (scheme-utils repl server)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-13)
  ;; `filter-map', for the one-level directory listing the name search needs.
  #:use-module (srfi srfi-1)
  ;; `let-values', for `repl-eval-values'' two answers.  Named as an import
  ;; rather than reached through `call-with-values' because the two-value shape
  ;; is the contract, and a reader should see it.
  #:use-module (srfi srfi-11)
  ;; `scandir', `stat:type' and `stat:mtime': finding a program by NAME means
  ;; looking in the runtime directory, because the directory is named after the
  ;; PROGRAM and a bare instance name does not give a path.
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((guile) #:select (AF_UNIX AF_INET SOCK_STREAM socket connect
                                  close shutdown inet-pton))
  #:export (repl-connect
            repl-connect-tcp
            repl-connect-to
            repl-where-is
            repl-endpoints
            repl-guile-repl?
            repl-tcp-guile-repl?
            repl-banner
            repl-greeting
            repl-list
            basename-no-ext
            repl-socket-candidates
            repl-port-candidates
            repl-open-session
            repl-connect-any
            repl-close
            repl-send
            repl-read-to-prompt
            repl-answer-error?
            repl-answer-text
            repl-last-line
            repl-eval
            repl-eval-values
            repl-run-session
            repl-prompt?))

;;; ---------------------------------------------------------------------------
;;; Connecting
;;; ---------------------------------------------------------------------------

(define (repl-connect path)
  "A socket connected to the back door at PATH, or #f when there is none.

#f rather than an error, because a connection refused is the ORDINARY answer
here: a socket file outlives the program that made it, so a client that walks a
list of instances must be able to say \"not that one\" and move on."
  (catch #t
    (lambda ()
      (let ((s (socket AF_UNIX SOCK_STREAM 0)))
        (catch #t
          (lambda () (connect s AF_UNIX path) s)
          (lambda args (catch #t (lambda () (close s)) (lambda a #f)) #f))))
    (lambda args #f)))

(define (repl-connect-any names)
  "The first NAME in NAMES whose back door answers, or #f.

NAMES are instance names, as `live-instances' returns them; the socket path for
each comes from the server module, so a client does not have to know how the
endpoint is named."
  (let loop ((rest names))
    (cond ((null? rest) #f)
          (else (or (repl-connect (repl-endpoint-path (car rest)))
                    (loop (cdr rest)))))))

;;; ---------------------------------------------------------------------------
;;; Finding a program by NAME, whichever way it published its endpoint
;;; ---------------------------------------------------------------------------
;;
;; ONE NAME, POSSIBLY TWO TRANSPORTS.  A client that has to be told a socket path
;; is a client for one program; a client that takes a NAME is a client for all of
;; them, and the price of that is knowing every way an endpoint gets published.
;; There are two in this tree, and they are not variations of each other:
;;
;;   - A UNIX SOCKET, which is what `(scheme-utils repl server)' opens by
;;     default: $XDG_RUNTIME_DIR/<program>/<instance>.sock.  The DIRECTORY is the
;;     program, which is why a bare instance name cannot be turned into a path
;;     without looking -- hence the search below.
;;
;;   - A TCP PORT WRITTEN TO A FILE: $XDG_RUNTIME_DIR/<program>-repl-<pid>.port,
;;     which is what schemacs opens.  The port is not knowable in advance and the
;;     file is the only place it exists, so this cannot be computed either.
;;
;; The protocol above both is IDENTICAL, which is the whole reason one client can
;; serve both: a socket is a socket once it is connected, and Guile's REPL does
;; not know or care what is underneath it.
;;
;; LIVENESS IS SETTLED BY CONNECTING, in both cases: a socket file and a port file
;; both outlive the program that wrote them, and there are four stale schemacs
;; port files in the runtime directory of the machine this was written on.

(define (repl-runtime)
  "The directory endpoints are published in: $XDG_RUNTIME_DIR, or #f."
  (let ((runtime (getenv "XDG_RUNTIME_DIR")))
    (and runtime (not (string=? runtime "")) runtime)))

(define (repl-runtime-subdirectories runtime)
  "The directories directly under RUNTIME, as full paths.  '() on any failure."
  (catch #t
    (lambda ()
      (filter-map
       (lambda (entry)
         (and (not (member entry '("." "..")))
              (let ((path (string-append runtime "/" entry)))
                (and (catch #t
                            (lambda () (eq? 'directory (stat:type (stat path))))
                            (lambda args #f))
                     path))))
       (catch #t (lambda () (scandir runtime)) (lambda args '()))))
    (lambda args '())))

(define (repl-socket-candidates name)
  "The Unix socket paths NAME might be listening on, most specific first.

Three shapes, because a program may put its sockets anywhere under the runtime
directory and there is no registry to ask:

  $XDG_RUNTIME_DIR/<name>.sock             a program that needs one socket only
  $XDG_RUNTIME_DIR/<program>/<name>.sock   this tree's layout
  $XDG_RUNTIME_DIR/<program>/<name>.sock   for EVERY program directory, which is
                                           the search that makes a bare name work

The last is a directory listing one level deep, not a walk: an endpoint belongs
directly in its program's directory, and anything deeper is not one of ours."
  (let ((runtime (repl-runtime)))
    (if (not runtime)
        '()
        (cons (string-append runtime "/" name ".sock")
              (map (lambda (dir) (string-append dir "/" name ".sock"))
                   (repl-runtime-subdirectories runtime))))))

(define (repl-port-in path)
  "The port number in a `.port' file, or #f."
  (catch #t
    (lambda ()
      (call-with-input-file path
        (lambda (in)
          (let ((line (read-line in)))
            (and (not (eof-object? line))
                 (string->number (string-trim-right line)))))))
    (lambda args #f)))

(define (repl-port-candidates name)
  "The TCP ports NAME might be listening on, NEWEST FIRST, or '().

The `*-repl-<pid>.port' convention, taken from schemacs, which is where it comes
from and which still uses it.  Newest first because that is what a bare name
should mean when several are running: the one started last.

THE PID IN THE NAME IS NOT CHECKED.  A port file outlives the program that wrote
it -- the machine this was written on has four stale ones -- and a pid can be
reused, so testing the pid proves nothing about the PORT.  The caller connects
instead, which is the test that matters."
  (let ((runtime (repl-port-file-directory)))
    (let* ((names (catch #t
                    (lambda () (scandir runtime))
                    (lambda args '())))
           ;; THE PATTERN COMES FROM THE SERVER MODULE, not from a copy of it
           ;; here.  A client that spelled it out again would be the second
           ;; place the convention lives, and the two would drift the first
           ;; time either changed -- which is exactly the asymmetry this used
           ;; to have, when only this side knew it.
           (mine (filter (lambda (n)
                           (and (string-suffix? ".port" n)
                                (string-prefix? (repl-port-file-prefix name) n)))
                         names)))
          (let loop ((rest mine) (found '()))
            (cond ((null? rest)
                   (map cadr (sort found (lambda (a b) (> (car a) (car b))))))
                  (else
                   (let* ((path (string-append runtime "/" (car rest)))
                          (port (repl-port-in path))
                          (mtime (and (file-exists? path)
                                      (catch #t
                                        (lambda () (stat:mtime (stat path)))
                                        (lambda args 0)))))
                     (if (and port mtime)
                         (loop (cdr rest) (cons (list mtime port) found))
                         (loop (cdr rest) found)))))))))

(define* (repl-connect-tcp port #:optional (host "127.0.0.1"))
  "A socket connected to PORT on HOST, or #f when nothing answers.

127.0.0.1 AND NOT A NAME: the endpoint is on this machine, and asking a resolver
about it is a way to be told something else, slowly.

A LOOPBACK TCP PORT IS NOT AS PRIVATE AS A UNIX SOCKET, and a host that chooses
one should know which it picked: the kernel checks filesystem permissions on a
socket, and it does not check anything on a port.  Every user on the machine can
reach a loopback port.  This is why the Unix socket is the default here."
  (catch #t
    (lambda ()
      (let ((s (socket AF_INET SOCK_STREAM 0)))
        (catch #t
          (lambda () (connect s AF_INET (inet-pton AF_INET host) port) s)
          (lambda args (catch #t (lambda () (close s)) (lambda a #f)) #f))))
    (lambda args #f)))

(define (repl-connect-to name)
  "A socket to the back door of NAME, or #f when nothing answers.

WHICHEVER WAY IT PUBLISHED.  Unix sockets first, then port files -- not because
one is better but because the file forms are different and a program only uses
one, so the order never actually decides anything; it just has to be fixed.

NAME may also be a PATH, which is how a caller says exactly which endpoint it
means and skips the search."
  (cond
   ((not name) #f)
   ;; An explicit path, or a name that could only be one.
   ((or (string-contains name "/") (string-suffix? ".sock" name))
    (repl-connect name))
   (else
    (or (let loop ((rest (repl-socket-candidates name)))
          (cond ((null? rest) #f)
                (else (or (repl-connect (car rest)) (loop (cdr rest))))))
        (let loop ((rest (repl-port-candidates name)))
          (cond ((null? rest) #f)
                (else (or (repl-connect-tcp (car rest)) (loop (cdr rest))))))))))

(define (repl-where-is name)
  "The description of NAME's endpoint that answers, or #f.

For a client that wants to SAY where it connected -- a tool that prints the
socket it used, or a test that asserts the right one was chosen.  Answers a
string, which is a path for a Unix socket and \"host:port\" for a TCP one."
  (or (let loop ((rest (repl-socket-candidates name)))
        (cond ((null? rest) #f)
              ((socket-alive? (car rest)) (car rest))
              (else (loop (cdr rest)))))
      (let loop ((rest (repl-port-candidates name)))
        (cond ((null? rest) #f)
              ((repl-connect-tcp (car rest)) (format #f "127.0.0.1:~a" (car rest)))
              (else (loop (cdr rest)))))))

(define (dir-entries dir)
  "The names directly in DIR, or '() when it cannot be read."
  (catch #t (lambda () (scandir dir)) (lambda args '())))

(define* (repl-greeting socket #:key (tries 120))
  "The banner SOCKET sends on connect, or #f when it is not a Guile REPL.

CONSUMES IT, so the caller has it and the socket is ready for an expression.

HOW A BACK DOOR IS TOLD FROM AN ORDINARY SOCKET, and the runtime directory has
plenty of the latter -- measured on the machine this was written on, a top-level
listing is hyprmoncfgd, mousehop-gui, jb.station and more, none of them a Guile
REPL.  Guile's REPL announces itself with `scheme@(...)> ' and nothing else here
does, so that string is the test.

WAIT AND LOOK, RATHER THAN BLOCK.  A program that is not a REPL may accept the
connection and then say nothing at all, and a client that read until a prompt
would wait for ever on it.  Forty short turns is enough for a banner that is
already in the socket buffer, which is where it is when the program IS a REPL.

IT READS TO THE END OF THE PROMPT, and that is not a detail: stopping as soon as
the text STARTS with `scheme@' leaves `(guile-user)> ' in the socket, and the
next read takes that for the beginning of the answer.  Measured -- the answer to
`(+ 1 2)' came back as `(guile-user)> $32 = 3'."
  (let loop ((n 0) (seen ""))
    (let ((line (repl-last-line seen)))
      (cond ((repl-prompt? line)
             (and (string-prefix? "scheme@" line) seen))
            ((>= n tries) #f)
            ((char-ready? socket)
             (let ((c (catch #t (lambda () (read-char socket)) (lambda args #f))))
               (if (not c) #f (loop n (string-append seen (string c))))))
            (else (usleep 5000) (loop (+ n 1) seen))))))

(define* (repl-banner path #:key (tries 120))
  "The banner of whatever is at PATH, on a connection that is closed again.

For asking about an endpoint WITHOUT using it -- which is what the listing does,
over every socket it finds."
  (let ((socket (repl-connect path)))
    (and socket
         (let ((banner (repl-greeting socket #:tries tries)))
           (repl-close socket)
           banner))))

(define (repl-guile-repl? path)
  "Whether something at PATH answers like a Guile REPL."
  (and (repl-banner path) #t))

(define* (repl-tcp-guile-repl? port #:optional (host "127.0.0.1"))
  "Whether PORT on HOST answers like a Guile REPL.

THE SAME QUESTION AS `repl-guile-repl?' FOR THE OTHER TRANSPORT, and it has to be
asked separately because that one takes a path: a TCP endpoint is found by
connecting, not by looking at a file. Leaving it out is what made the listing
report a port as live merely because something was listening on it -- which is
exactly what a stale port file CANNOT do (nothing is listening) and what an
unrelated service on a reused port CAN."
  (let ((socket (repl-connect-tcp port host)))
    (and socket
         (let ((banner (repl-greeting socket)))
           (repl-close socket)
           (and banner #t)))))

(define (repl-endpoints)
  "Every endpoint published in the runtime directory, dead ones included.

Each is `(NAME KIND WHERE ALIVE?)': KIND is 'unix or 'tcp, WHERE is the socket
path or a host:port, and ALIVE? is settled by CONNECTING -- both a socket file
and a port file outlive the program that wrote them.

ONLY SOCKETS IN A PROGRAM SUBDIRECTORY ARE CONSIDERED, because that is the
convention: a program publishes `$XDG_RUNTIME_DIR/<program>/<instance>.sock'.
The top level of the runtime directory belongs to everything else on the machine
-- editors, keyrings, compositors -- and listing those would bury the four lines
that matter under twenty that do not.

AND EACH CANDIDATE IS ASKED ITS NAME.  A socket in a subdirectory is still not
necessarily a Guile REPL (colorshell publishes one), so the ones that answer
with Guile's banner are listed and the rest are left alone.

THE DEAD ONES ARE LISTED ON PURPOSE.  A listing that showed only live instances
would make the commonest failure -- a program that crashed and left its endpoint
behind -- indistinguishable from one that was never started, and the two need
different fixes.

Sorted by name, so the output does not shuffle between runs."
  (let ((runtime (repl-runtime)))
    (if (not runtime)
        '()
        (let* ((dirs (repl-runtime-subdirectories runtime))
               ;; TWO LISTS, AND THE DIFFERENCE MATTERS.  A SOCKET is published
               ;; in a program's own subdirectory, so only those are searched --
               ;; that is what keeps the machine's other sockets out of the
               ;; listing.  A PORT FILE is published at the TOP of the runtime
               ;; directory (that is schemacs' convention), so restricting ports
               ;; to subdirectories would find nothing at all, which is exactly
               ;; what happened the first time this was written.
               (sub-files (append-map
                           (lambda (dir)
                             (map (lambda (f) (cons f dir)) (dir-entries dir)))
                           dirs))
               (top-files (map (lambda (f) (cons f runtime)) (dir-entries runtime)))
               (socket-rows
                (filter-map
                 (lambda (entry)
                   (let ((name (car entry)) (dir (cdr entry)))
                     (and (string-suffix? ".sock" name)
                          (let ((path (string-append dir "/" name)))
                            (and (socket-alive? path)
                                 (repl-guile-repl? path)
                                 (list (basename-no-ext name) 'unix path #t))))))
                 sub-files))
               (port-rows
                (filter-map
                 (lambda (entry)
                   (let ((name (car entry)) (dir (cdr entry)))
                     (and (string-suffix? ".port" name)
                          (string-contains name "-repl-")
                          (let* ((path (string-append dir "/" name))
                                 (port (repl-port-in path)))
                            (and port
                                 (list (car (string-split name #\-)) 'tcp
                                       (format #f "127.0.0.1:~a" port)
                                       ;; ASKED, not merely connected to --
                                       ;; see repl-tcp-guile-repl?.
                                       (repl-tcp-guile-repl? port)))))))
                 (append top-files sub-files))))
          (sort (append socket-rows port-rows)
                (lambda (a b) (string<? (car a) (car b))))))))

(define (basename-no-ext path)
  "PATH's file name with any extension removed."
  (let* ((f (let loop ((i (- (string-length path) 1)))
              (cond ((< i 0) path)
                    ((char=? (string-ref path i) #\/)
                     (substring path (+ i 1) (string-length path)))
                    (else (loop (- i 1))))))
         (dot (string-index-right f #\.)))
    (if dot (substring f 0 dot) f)))

(define* (repl-list #:optional (port (current-output-port)))
  "Print every published endpoint, marking the ones that do not answer.

Returns the number of LIVE ones, so a caller can branch on it.  Printing rather
than returning strings because this is the body of a `list' subcommand, and the
caller that wants data uses `repl-endpoints'."
  (let ((rows (repl-endpoints)))
    (if (null? rows)
        (begin (format port "no programs publishing an endpoint~%") 0)
        (begin
          (for-each (lambda (row)
                      (format port "~a~a  (~a)  ~a~%"
                              (car row)
                              (if (cadddr row) "" "  (stale)")
                              (cadr row)
                              (caddr row)))
                    rows)
          (length (filter cadddr rows))))))

(define (repl-open-session path)
  "A socket for PATH, or an error that says what was missing.

FOR A CLIENT THAT WAS TOLD WHERE TO LOOK.  The message names the path, because
\"the program is not running\" and \"you gave me the wrong socket\" look
identical from here, and the two need different fixes."
  (or (repl-connect path)
      (error "no back door is listening on" path)))

(define (repl-close socket)
  "Close SOCKET, ignoring an already-closed one."
  (when socket
    (catch #t (lambda () (close socket)) (lambda args #f)))
  #t)

;;; ---------------------------------------------------------------------------
;;; The protocol
;;; ---------------------------------------------------------------------------

(define (repl-last-line text)
  "TEXT after its last newline."
  (let loop ((i (- (string-length text) 1)))
    (cond ((< i 0) text)
          ((char=? #\newline (string-ref text i))
           (substring text (+ i 1) (string-length text)))
          (else (loop (- i 1))))))

(define (repl-prompt? line)
  "Whether LINE is the REPL's prompt, plain or nested."
  (and (string-prefix? "scheme@" line)
       (string-suffix? "> " line)))

(define (repl-read-to-prompt socket)
  "Everything the server writes up to and including the next prompt, or #f when
the connection ends first.

A CHARACTER at a time -- see (1) in the header.  The prompt is tested as the last
line, not as a suffix of the whole text, which is what lets a value ending in >
be read past."
  (let loop ((out '()) (line ""))
    (let ((c (read-char socket)))
      (if (eof-object? c)
          #f
          (let ((out (cons c out))
                (line (if (char=? c #\newline)
                          ""
                          (string-append line (string c)))))
            (if (repl-prompt? line)
                (list->string (reverse out))
                (loop out line)))))))

(define (repl-send socket text)
  "Send TEXT as one expression, with the newline that ends it."
  (display text socket)
  (newline socket)
  (force-output socket))

(define (repl-answer-error? answer)
  "Whether ANSWER is an error's rather than a value's.

The nested prompt is the test -- see (2) in the header.  A value that happens to
end in > does not have a bracket in it."
  (let ((line (repl-last-line answer)))
    (and (repl-prompt? line)
         (string-contains line "[")
         #t)))

(define (repl-answer-text answer)
  "ANSWER without the prompt line it ends with, for showing to a person."
  (if (not answer)
      ""
      (let loop ((i (- (string-length answer) 1)))
        (cond ((< i 0) answer)
              ((char=? #\newline (string-ref answer i))
               (string-trim-right (substring answer 0 i)))
              (else (loop (- i 1)))))))

;;; ---------------------------------------------------------------------------
;;; Evaluating
;;; ---------------------------------------------------------------------------

(define (repl-eval-values socket expression)
  "Send EXPRESSION and answer two values: its text, and whether it was an error.

Both values are returned rather than one because \"it failed\" and \"it printed
nothing\" are different, and a caller that has only the text cannot tell them
apart.  A caller that does not care uses `repl-eval'."
  (repl-read-to-prompt socket)          ; the banner
  (repl-send socket expression)
  (let ((answer (repl-read-to-prompt socket)))
    (values (repl-answer-text answer)
            (if answer (repl-answer-error? answer) #t))))

(define* (repl-eval path expression #:key (on-error 'raise))
  "Evaluate EXPRESSION at the back door on PATH.  Returns its text.

ON-ERROR is what to do when the program's answer was an error: 'raise (the
default) calls `error' with the text, and anything else returns the text anyway.
Raising is the default because an expression that failed is normally a mistake
the caller wants to hear about -- but a caller iterating over many expressions
may want to carry on, and that is what the other value is for."
  (let ((socket (repl-open-session path)))
    ;; **THE SOCKET IS CLOSED EITHER WAY, AND THAT IS NOT TIDINESS.** A program
    ;; serves ONE client session at a time, and a session nobody closes leaves
    ;; its reader parked on it -- so the next client is accepted, and then never
    ;; greeted: `repl -e' reports "nothing is answering for NAME" and exits 2,
    ;; and a session client hangs with no banner at all. Measured, the day
    ;; `se --remote FILE' was followed by `se --repl' against the same program.
    ;; (The socket does close when the port is collected, so this is a race
    ;; rather than a certainty, which is exactly what makes it worth closing
    ;; here as one.)
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (let-values (((text failed) (repl-eval-values socket expression)))
          (when (and failed (eq? on-error 'raise))
            (error "the program reported an error:" text))
          text))
      (lambda () (repl-close socket)))))

;;; ---------------------------------------------------------------------------
;;; Being a REPL for it
;;; ---------------------------------------------------------------------------

(define* (repl-run-session socket #:optional (in (current-input-port))
                                           (out (current-output-port)))
  "Be a REPL for the program on SOCKET: copy what it says to OUT as it arrives,
and send what is typed at IN.

Answers when the server closes its end, or when IN ends -- the terminal's C-d, or
a pipe running out.

THE TWO DIRECTIONS ARE TWO THREADS, because both ends can be silent at once and
one thread would be waiting on one of them.  The TERMINAL's side is the thread
and the server's is this one, so that the server closing is what ends the
session; the reverse would leave this blocked on a socket nobody is reading.

IN and OUT are arguments rather than always the terminal, so a test can drive a
session from string ports -- which is how this module's own test exercises the
interactive path without a terminal."
  (call-with-new-thread
   (lambda ()
     (let loop ()
       ;; A CLOSED STDIN IS AN END, NOT AN ERROR.  `read-line' on a closed port
       ;; RAISES rather than answering the eof object, so a piped session --
       ;; `echo EXPR | thing repl` -- used to end with "Wrong type argument ...
       ;; #<closed: file>" instead of closing the socket and leaving.
       ;;
       ;; The handler answers 'closed rather than an eof OBJECT, and that is
       ;; deliberate: there is no portable zero-argument constructor for one
       ;; (measured -- `(eof-object)' is unbound in every standard module, and
       ;; the toolkit's own client only gets away with calling it because it
       ;; imports G-Golf, which re-exports it).  A sentinel says the same thing
       ;; without depending on that accident.
       (let ((line (catch #t (lambda () (read-line in)) (lambda args 'closed))))
         (cond
          ((eq? line 'closed) (catch #t (lambda () (shutdown socket 1)) (lambda args #f)))
          ((eof-object? line) (catch #t (lambda () (shutdown socket 1)) (lambda args #f)))
          (else
           (begin
             (display line socket)
             (newline socket)
             (force-output socket)
             (loop))))))))
  (let loop ()
    ;; AND THE SAME AT THIS END: when the input thread sees the end it half-closes
    ;; the socket, and this loop is still reading it -- a closed port raises here
    ;; too, so the session ended with an error rather than a prompt.  Same
    ;; sentinel reasoning as above: character, then "was it the end?".
    (let ((c (catch #t (lambda () (read-char socket)) (lambda args 'closed))))
      (unless (or (eq? c 'closed) (eof-object? c))
        (write-char c out)
        (force-output out)
        (loop))))
  #t)
