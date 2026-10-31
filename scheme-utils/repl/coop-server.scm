;;; Cooperative REPL server.
;;;
;;; This file is GNU Guile's `(system repl coop-server)', whole, plus a
;;; notification hook - so that a program embedding the server can be
;;; *told* that the server has work, instead of having to poll it.
;;;
;;; Two differences from upstream, and both are the point of the file:
;;;
;;;   1. The server record carries a NOTIFY procedure, given to
;;;      `spawn-coop-repl-server' with `#:notify', and
;;;      `coop-repl-server-eval' calls it after queueing an operation.
;;;      Upstream's contract - "poll-coop-repl-server be called
;;;      periodically" - is unchanged; what this adds is a way to know
;;;      *when* a poll is worth making, so that a host program with an
;;;      event loop of its own does not have to guess a period.
;;;
;;;   2. `poll-coop-repl-server' answers whether it applied anything. A
;;;      wake that is level-triggered - a byte in a pipe, an idle
;;;      source - says only "there is work", not "there is one item of
;;;      work", so a consumer has to drain the queue rather than poll it
;;;      once. Without an answer there is no way to know when to stop.
;;;
;;; The module is named `(scheme-utils repl coop-server)' rather than
;;; `(system repl coop-server)' only so that it can live in this tree
;;; without shadowing Guile's. Renaming it back is the whole of the edit
;;; needed to submit the rest as a patch.
;;;
;;; This file is SHARED, and byte-identical to the copies in schemacs
;;; (`schemacs/coop-server.scm') and in scheme-shell
;;; (`scheme-toolkit/repl/coop-server.scm') apart from that one line.
;;; Those two projects now import this one instead, which is the point:
;;; a file that is Guile's plus a hook has no business being maintained
;;; in three places.
;;;
;;; Everything else is upstream, verbatim, including the comments.

;;; Code:

(define-module (scheme-utils repl coop-server)
  #:use-module (ice-9 match)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 q)
  #:use-module (srfi srfi-9)
  #:export (spawn-coop-repl-server
            poll-coop-repl-server))

;; Hack to import private bindings from (system repl repl).
(define-syntax-rule (import-private module sym ...)
  (begin
    (define sym (@@ module sym))
    ...))
(import-private (system repl repl) start-repl* prompting-meta-read)
(import-private (system repl server)
                run-server* add-open-socket! close-socket!
                make-tcp-server-socket guard-against-http-request)

(define-record-type <coop-repl-server>
  (%make-coop-repl-server mutex queue notify)
  coop-repl-server?
  (mutex coop-repl-server-mutex)
  (queue coop-repl-server-queue)
  ;; NOTIFY, or #f for a server nobody asked to be told about. It is
  ;; called by `coop-repl-server-eval', which is the only thing that
  ;; does.
  (notify coop-repl-server-notify))

(define (make-coop-repl-server notify)
  (%make-coop-repl-server (make-mutex) (make-q) notify))

(define (coop-repl-server-eval coop-server opcode . args)
  "Queue a new instruction with the symbolic name OPCODE and an arbitrary
number of arguments, to be processed the next time COOP-SERVER is polled.

COOP-SERVER's notify procedure, if it has one, is called afterwards, with
COOP-SERVER, once the queue's mutex has been released.

The notify procedure may be called from any thread - the thread that
accepted a connection, or the thread reading for a session - and nothing
serialises it, so two threads may call it at once. It is called *after*
the operation is on the queue and never before, which is what makes the
queue safe to poll for: a consumer whose wake is level-triggered cannot
miss an operation, because the thing it watches is not raised until the
operation is there. A consumer whose wake is edge-triggered must drain
the queue rather than poll it once - see `poll-coop-repl-server'."
  (with-mutex (coop-repl-server-mutex coop-server)
    (enq! (coop-repl-server-queue coop-server)
          (cons opcode args)))
  ;; Outside the lock: NOTIFY is the caller's procedure, and running it
  ;; with this mutex held would deadlock the moment it touched the
  ;; server - which is exactly what a consumer that drains the queue from
  ;; its notify would do.
  ;;
  ;; The server is passed as the argument because it cannot be captured by
  ;; a closure instead: `spawn-coop-repl-server' starts the accepting
  ;; thread before it returns the server, so a notify that wants to poll
  ;; would have nothing to name yet.
  (let ((notify (coop-repl-server-notify coop-server)))
    (when notify (notify coop-server))))

(define-record-type <coop-repl>
  (%make-coop-repl mutex condvar thunk cont)
  coop-repl?
  (mutex coop-repl-mutex)
  (condvar coop-repl-condvar)  ; signaled when thunk becomes non-#f
  (thunk coop-repl-read-thunk set-coop-repl-read-thunk!)
  (cont coop-repl-cont set-coop-repl-cont!))

(define (make-coop-repl)
  (%make-coop-repl (make-mutex) (make-condition-variable) #f #f))

(define (coop-repl-read coop-repl)
  "Read an expression via the thunk stored in COOP-REPL."
  (let ((thunk
         (with-mutex (coop-repl-mutex coop-repl)
           (unless (coop-repl-read-thunk coop-repl)
             (wait-condition-variable (coop-repl-condvar coop-repl)
                                      (coop-repl-mutex coop-repl)))
           (let ((thunk (coop-repl-read-thunk coop-repl)))
             (unless thunk
               (error "coop-repl-read: condvar signaled, but thunk is #f!"))
             (set-coop-repl-read-thunk! coop-repl #f)
             thunk))))
    (thunk)))

(define (store-repl-cont cont coop-repl)
  "Save the partial continuation CONT within COOP-REPL."
  (set-coop-repl-cont! coop-repl
                       (lambda (exp)
                         (coop-repl-prompt
                          (lambda () (cont exp))))))

(define (coop-repl-prompt thunk)
  "Apply THUNK within a prompt for cooperative REPLs."
  (call-with-prompt 'coop-repl-prompt thunk store-repl-cont))

(define (make-coop-reader coop-repl)
  "Return a new procedure for reading user input from COOP-REPL.  The
generated procedure passes the responsibility of reading input to
another thread and aborts the cooperative REPL prompt."
  (lambda (repl)
    (let ((read-thunk
           ;; Need to preserve the REPL stack and current module across
           ;; threads.
           (let ((stack (fluid-ref *repl-stack*))
                 (module (current-module)))
             (lambda ()
               (with-fluids ((*repl-stack* stack))
                 (set-current-module module)
                 (prompting-meta-read repl))))))
      (with-mutex (coop-repl-mutex coop-repl)
        (when (coop-repl-read-thunk coop-repl)
          (error "coop-reader: read-thunk is not #f!"))
        (set-coop-repl-read-thunk! coop-repl read-thunk)
        (signal-condition-variable (coop-repl-condvar coop-repl))))
    (abort-to-prompt 'coop-repl-prompt coop-repl)))

(define (reader-loop coop-server coop-repl)
  "Run an unbounded loop that reads an expression for COOP-REPL and
stores the expression within COOP-SERVER for later evaluation."
  (coop-repl-server-eval coop-server 'eval coop-repl
                         (coop-repl-read coop-repl))
  (reader-loop coop-server coop-repl))

(define (poll-coop-repl-server coop-server)
  "Poll the cooperative REPL server COOP-SERVER and apply a pending
operation if there is one, such as evaluating an expression typed at the
REPL prompt.  This procedure must be called from the same thread that
called spawn-coop-repl-server.

Answers #t when it applied an operation, and #f when the queue was
empty, so that a caller woken by the server's notify procedure can drain
the queue:

  (let loop () (when (poll-coop-repl-server server) (loop)))"
  (let ((op (with-mutex (coop-repl-server-mutex coop-server)
              (let ((queue (coop-repl-server-queue coop-server)))
                (and (not (q-empty? queue))
                     (deq! queue))))))
    (when op
      (match op
        (('new-repl client)
         (start-repl-client coop-server client))
        (('eval coop-repl exp)
         ((coop-repl-cont coop-repl) exp))))
    (and op #t)))

(define (start-coop-repl coop-server)
  "Start a new cooperative REPL process for COOP-SERVER."
  ;; Calling stop-server-and-clients! from a REPL will cause an
  ;; exception to be thrown when trying to read from the socket that has
  ;; been closed, so we catch that here.
  (false-if-exception
   (let ((coop-repl (make-coop-repl)))
     (make-thread reader-loop coop-server coop-repl)
     (start-repl* (current-language) #f (make-coop-reader coop-repl)))))

(define (run-coop-repl-server coop-server server-socket)
  "Start the cooperative REPL server for COOP-SERVER using the socket
SERVER-SOCKET."
  (run-server* server-socket (make-coop-client-proc coop-server)))

(define* (spawn-coop-repl-server
          #:optional (server-socket (make-tcp-server-socket))
          #:key notify)
  "Create and return a new cooperative REPL server object, and spawn a
new thread to listen for connections on SERVER-SOCKET.  Proper
functioning of the REPL server requires that poll-coop-repl-server be
called periodically on the returned server object.

NOTIFY, when given, is called with the server whenever an operation is
queued.  It is what makes a timely poll possible without polling: a host
program with an event loop of its own uses it to arrange for
poll-coop-repl-server to be called.  See coop-repl-server-eval for the
guarantees it gives and the threading it may be called with."
  (let ((coop-server (make-coop-repl-server notify)))
    (make-thread run-coop-repl-server
                 coop-server
                 server-socket)
    coop-server))

(define (make-coop-client-proc coop-server)
  "Return a new procedure that is used to schedule the creation of a new
cooperative REPL for COOP-SERVER."
  (lambda (client addr)
    (coop-repl-server-eval coop-server 'new-repl client)))

(define (start-repl-client coop-server client)
  "Run a cooperative REPL for COOP-SERVER within a prompt.  All input
and output is sent over the socket CLIENT."

  ;; Add the client to the list of open sockets, with a 'force-close'
  ;; procedure that closes the underlying file descriptor.  We do it
  ;; this way because we cannot close the port itself safely from
  ;; another thread.
  (add-open-socket! client (lambda () (close-fdes (fileno client))))

  (guard-against-http-request client)

  (with-continuation-barrier
   (lambda ()
     (coop-repl-prompt
      (lambda ()
        (parameterize ((current-input-port client)
                       (current-output-port client)
                       (current-error-port client)
                       (current-warning-port client))
          (with-fluids ((*repl-stack* '()))
            (save-module-excursion
             (lambda ()
               (start-coop-repl coop-server)))))

        ;; This may fail if 'stop-server-and-clients!' is called,
        ;; because the 'force-close' procedure above closes the
        ;; underlying file descriptor instead of the port itself.
        (false-if-exception
         (close-socket! client)))))))
