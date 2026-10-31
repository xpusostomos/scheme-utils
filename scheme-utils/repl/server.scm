;;; (scheme-utils repl server) -- control a RUNNING program by evaluating Scheme
;;; in it: the server half.
;;;
;;; THIS FILE IS `server.scm' RATHER THAN `repl.scm', and it is in `repl/' with
;;; the client that will sit beside it.  The module name is the file path in
;;; Guile, so a `repl' module holding both halves would need one of them to be
;;; `(scheme-utils repl repl)' -- which reads as a stutter and says nothing.
;;; `(scheme-utils repl server)' and `(scheme-utils repl client)' say which is
;;; which, and the name is what a reader sees before the file is opened.
;;;
;;; A program that embeds this module gets a back door: another process connects
;; to it and evaluates expressions *in the program*, on the program's own thread,
;; with its own state in scope.  That is the whole idea, and it replaces the usual
;; arrangement -- a control protocol with a fixed list of verbs, a parser for
;; them, and a handler that switches on a string.
;;
;; TAKEN FROM schemacs' `schemacs/repl.scm' AND scheme-shell's
;; `scheme-toolkit/repl.scm', which were the same code twice.  What is here is the
;; part that is about BEING A BACK DOOR rather than about being either program:
;; the socket, the wake, the drain, the listing.  What is NOT here is anything a
;; host supplies -- see "the host contract".
;;
;; WHEN THIS IS WORTH IT, in the reference implementation's words, because the
;; argument is not obvious: the alternative for a GUI program is `wtype' to type
;; at the window and `grim' to look at it, and a keyed run goes to whichever
;; window the compositor has focused, which is not necessarily yours.  A silent
;; mis-focus then produces a screenshot of SOMETHING ELSE that looks exactly like
;; evidence, and one was believed.  A REPL cannot mis-focus: it is the process.
;;
;; ---------------------------------------------------------------------------
;; THE HOST CONTRACT
;; ---------------------------------------------------------------------------
;;
;; Two things a program must supply, and three it may:
;;
;;   (repl-name! (lambda () "my-thing"))     ; REQUIRED: what to call the socket
;;   (repl-module! '(my-thing user))         ; REQUIRED: where expressions are read
;;   (repl-wake! my-idle-source)             ; optional: how to be woken
;;   (repl-after-poll! redisplay)            ; optional: draw after evaluating
;;   (repl-before-start! open-env)           ; optional: prepare the namespace
;;   (start-repl!)                           ; and this is the whole of the rest
;;
;; THE WAKE IS THE SAME SEAM `(scheme-utils watch)' USES, for the same reason:
;; this module reads expressions in a thread but must EVALUATE them on the host's
;; own thread, so it has to be told when to poll.  Polling on a timer works and
;; costs a measurable fraction of a core at idle -- that is what the reference
;; implementation measured before adding the hook, and what made the GTK editor
;; stop shortening its waits.  GLib's idle source is the default, because every
;; program in this tree has one.
;;
;; ---------------------------------------------------------------------------
;; WHY THE COOPERATIVE SERVER, AND NEVER (system repl server)
;; ---------------------------------------------------------------------------
;;
;;   - A GUI program is single-threaded.  The plain server runs each session in
;;     its own thread, so anything it touches is a data race.
;;   - Guile PARAMETERS ARE THREAD-LOCAL.  A program that uses `parameterize' for
;;     state -- a current frame, a current buffer, a current scope -- has that
;;     state invisible to a REPL in its own thread, which would see every
;;     parameter's DEFAULT.  That is not subtle corruption; it is an expression
;;     that means something different from what was typed.
;;
;; The cooperative server reads in a thread but evaluates on the host's thread
;; when it is polled.  What upstream lacks is a way to know WHEN to poll; the
;; vendored `(scheme-utils repl coop-server)' adds a `#:notify' hook and this
;; wires it to the wake.
;;
;; ---------------------------------------------------------------------------
;; THE TRANSPORT, AND WHY IT IS NOT BAKED IN
;; ---------------------------------------------------------------------------
;;
;; A UNIX SOCKET IS THE DEFAULT, and it is the better choice: it is a filesystem
;; object with filesystem permissions, it cannot be reached from another machine,
;; and -- the part that matters day to day -- its NAME IS ITS ADDRESS.  Listing a
;; directory is listing the running instances, so a client needs no port file, no
;; port hunting, and no way of telling a live endpoint from a stale one but
;; connecting to it.  That is what `(scheme-utils repl client)' relies on.
;;
;; The reference implementation uses TCP ON LOCALHOST plus a port file, and it
;; says why: it wanted a name a client could find without computing anything, the
;; way `emacsclient' reads a socket path rather than working one out.  A Unix
;; socket gives the same discoverability with a better object, so that is the
;; default here -- but it is a SEAM, not a decision, because the TCP form is not
;; broken and a program already using it should not have to change in order to
;; share this code.  `repl-socket-maker!', `repl-announce!' and `repl-candidates'
;; are the three places the transport shows through; the defaults are the Unix
;; ones, and a TCP host overrides all three.
;;
;; ---------------------------------------------------------------------------
;; SECURITY, WHICH IS THE PRICE OF THE WHOLE IDEA
;; ---------------------------------------------------------------------------
;;
;; THIS IS ARBITRARY CODE EXECUTION OVER A SOCKET, by design: it is the
;; development and control back door.  It is confined as tightly as it can be:
;;
;;   - a UNIX socket, so the kernel checks filesystem permissions on connect;
;;   - under $XDG_RUNTIME_DIR, which is per-user and 0700 by construction;
;;   - REFUSING TO START AT ALL when that variable is unset, rather than falling
;;     back to /tmp, which is world-writable and shared between users;
;;   - never TCP unless a host asks for it explicitly;
;;   - the socket directory created 0700.
;;
;; The TCP form in the reference implementation lands on 127.0.0.1 and leans on
;; the loopback interface for confinement.  That is a real difference and worth
;; knowing: a Unix socket is unreachable by another user on the same machine, and
;; a loopback TCP port is reachable by every user on it.  A host that chooses TCP
;; should know which one it picked.

(define-module (scheme-utils repl server)
  #:use-module (scheme-utils repl coop-server)
  #:use-module (ice-9 threads)
  #:use-module (ice-9 match)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  ;; The socket calls and constants a Unix transport needs.
  #:use-module ((guile) #:select (AF_UNIX SOCK_STREAM socket connect close
                                  listen bind))
  #:use-module ((ice-9 ftw) #:select (scandir))
  #:use-module ((guile) #:select (resolve-module save-module-excursion
                                  set-current-module))
  ;; The coop server suppresses its banner through this flag; a program that was
  ;; CONNECTED TO is not one that was started.
  #:use-module ((system repl repl) #:select (%inhibit-welcome-message))
  ;; The Unix-socket server socket.  `(system repl server)' is where this lives;
  ;; it is a plain socket constructor, not the threaded server that the coop
  ;; server exists to avoid.
  ;; Both transports' constructors.  `make-unix-domain-server-socket' is the
  ;; default, `make-tcp-server-socket' is what `repl-transport-tcp!' publishes.
  #:use-module ((system repl server) #:select (make-unix-domain-server-socket
                                                make-tcp-server-socket))

  #:export (start-repl!
            poll-repl!
            stop-repl!
            repl-running?
            repl-state! repl-restore!
            ;; Naming, and where the endpoint lives.
            repl-name repl-name!
            repl-directory repl-directory!
            repl-directory-name repl-directory-name!
            repl-runtime-directory
            repl-create-directory?! repl-create-directory?
            repl-location repl-address repl-endpoint-path
            ;; The transport seams.
            repl-socket-maker! repl-announce! repl-candidates
            repl-candidates! repl-cleanup!
            ;; The TCP transport, provided rather than left to each host.
            repl-transport-tcp!
            repl-port-file repl-port-file-directory repl-port-file-prefix
            repl-publish-port! repl-unpublish-port! repl-tcp-ports
            ;; The host seams.
            repl-module repl-module!
            repl-wake repl-wake!
            repl-welcome repl-welcome!
            repl-before-start! repl-after-poll!
            ;; Finding a running program.
            socket-alive? live-instances list-instances endpoints instance-of))

;;; ---------------------------------------------------------------------------
;;; Naming, and where the endpoint lives
;;; ---------------------------------------------------------------------------

;; A PROGRAM'S NAME GOES IN THE PATH, and it is a separate setting from the
;; instance name below: `$XDG_RUNTIME_DIR/scheme-toolkit/scheme-desktop.sock' is
;; program-then-instance, so that `list-instances' in one program cannot see
;; another's.  Defaulted to this module's own name, so a program that does not
;; care gets a directory that cannot collide with anything else's.
(define %directory-name "scheme-utils")

(define (repl-directory-name)
  "The subdirectory of $XDG_RUNTIME_DIR the endpoints live in."
  %directory-name)

(define (repl-directory-name! name)
  "Say what this program's directory under $XDG_RUNTIME_DIR is called.

SET THIS BEFORE `start-repl!' AND BEFORE ANYTHING ASKS FOR A PATH.  A program
that has already published its socket path somewhere -- a launcher that computes
it, a tool that lists it -- must keep the same name across the move, or its
sockets quietly relocate and every client starts reporting \"no running
instances\" while the program is running perfectly well.

Returns NAME."
  (set! %directory-name name)
  name)

;; CREATED 0700, IF THE HOST WANTS IT.  A program that manages its own directory
;; -- one that names its sockets by pid and has nothing to collect them -- sets
;; this #f.  The permission is the point: 0700 on the directory is what makes the
;; socket inside it unreachable by another user.
(define %create-directory? #t)

(define (repl-runtime-directory)
  "Where per-user runtime files belong: $XDG_RUNTIME_DIR, or an error.

AN ERROR RATHER THAN /tmp.  /tmp is world-writable and shared, so a
code-execution socket there would be reachable by anyone on the machine.  A
program that genuinely has no runtime directory must say where its endpoint goes
with `repl-directory!', which is an explicit statement -- not a silent fallback
that looks like it worked."
  (let ((runtime (getenv "XDG_RUNTIME_DIR")))
    (unless (and runtime (not (string=? runtime "")))
      (error "scheme-utils repl server: XDG_RUNTIME_DIR is unset, so there is nowhere safe to put a code-execution endpoint.  Set it, or name a directory with repl-directory!"))
    runtime))

;; #f means "under the runtime directory, in the directory named above".  A
;; string is an override, which is how a host puts its endpoints directly in
;; $XDG_RUNTIME_DIR.
(define %directory #f)

(define (repl-directory! dir)
  "Put the endpoints in DIR.  #f restores the default under $XDG_RUNTIME_DIR."
  (set! %directory dir)
  dir)

(define (repl-create-directory?! flag)
  "Whether `repl-directory' creates the directory it names, and 0700.

#f for a host that manages the directory itself.  Returns FLAG."
  (set! %create-directory? (and flag #t))
  %create-directory?)

(define (repl-create-directory?) %create-directory?)

(define (repl-directory)
  "The directory the endpoints live in, created if it should be.

BOTH WAYS OF NAMING IT ARE CREATED, which is the fix for a real gap: an
overridden directory used to be returned as-is, so a host that named its own --
`repl-directory!' -- got a path nothing had made, and every start failed at the
bind with a message about a missing file.  The 0700 is the point either way."
  (let ((dir (or %directory
                 (string-append (repl-runtime-directory) "/" %directory-name))))
    (when (and %create-directory? (not (file-exists? dir)))
      (catch #t (lambda () (mkdir dir #o700)) (lambda args #f)))
    dir))

;; A PROC, not a string, because the name may not be knowable at load time: a
;; program that opens a back door once per document has a name per document.  The
;; host sets it; THERE IS NO DEFAULT, and the error says so, because a default
;; would be an endpoint every instance of the program shares -- and the second one
;; to start would fail to bind with a message about a file already existing.
(define %name #f)

(define (repl-name)
  "The name this program's back door is known by, or an error."
  (let ((name (%name)))
    (unless (and name (not (string=? name "")))
      (error "scheme-utils repl server: no name.  Call repl-name! with a thunk returning one -- for example (lambda () (getenv \"MY_INSTANCE\"))"))
    name))

(define (repl-name! proc)
  "Say what this program's back door is called.

PROC is called for the name each time one is needed, so it may consult the
environment, the process id, or a value the program only learns at run time.

  (repl-name! (lambda () (getenv \"MY_INSTANCE\")))
  (repl-name! (lambda () (number->string (getpid))))

Returns PROC.  Name it from the ENVIRONMENT where you can: the launcher that
starts the program is what knows what to call it, and an environment variable
needs no shared state between the two."
  (set! %name proc)
  proc)

;;; ---------------------------------------------------------------------------
;;; The transport
;;; ---------------------------------------------------------------------------

(define* (repl-endpoint-path #:optional (name #f))
  "The Unix socket path for NAME, or for this program's own name."
  (string-append (repl-directory) "/" (or name (repl-name)) ".sock"))

;; WHERE THE ENDPOINT IS.  A string for a Unix socket path, a number for a TCP
;; port -- the two shapes the transports below take.  One variable rather than
;; two, so that `repl-location' says what the host chose without this module
;; having to know which kind it is.
(define %location #f)

(define (repl-location)
  "Where the endpoint is: a socket path, or a port number when the host said so.

#f before the back door is opened."
  %location)

(define (repl-address)
  "The location to open on, computed but not yet bound."
  (or %location (repl-endpoint-path)))

;; THE TRANSPORT, IN ONE PROCEDURE.  Everything above is naming; this is the part
;; that differs between a Unix socket and a TCP one, so it is the seam.
;;
;; A maker takes a location and returns a server socket, or raises.  `listen' is
;; NOT the maker's job: see `open-endpoint!'.
(define (default-socket-maker location)
  (make-unix-domain-server-socket #:path location))

(define %socket-maker default-socket-maker)

(define (repl-socket-maker! proc)
  "Say how to make the server socket at a location.

PROC takes the location -- a socket path by default, a port for a host that
overrode `repl-location' -- and returns a SERVER SOCKET, ready to listen on.  It
should raise when the location cannot be had; `start-repl!' reports that.

The default makes a Unix domain socket, which is the safer choice and the reason
this module refuses to work without a runtime directory:

  (repl-socket-maker! (lambda (p) (make-unix-domain-server-socket #:path p)))
  (repl-socket-maker! (lambda (port) (make-tcp-server-socket #:port port)))

Returns PROC."
  (set! %socket-maker proc)
  proc)

;; CALLED WITH THE LOCATION ONCE THE DOOR IS OPEN, and the hook exists for one
;; specific use: a TCP host must PUBLISH its port somewhere a client can find, or
;; a port nobody can name is no better than a fixed one.  A Unix host needs this
;; for nothing -- the path is the address -- and the default does nothing.
(define %announce! #f)

(define (repl-announce! proc)
  "Say what to call once the endpoint is open, with its location.

A program that writes the port it took to a file does it here.  Returns PROC."
  (set! %announce! proc)
  proc)

;; THE CANDIDATES TO TRY.  A Unix host has one; a TCP host walks upward from a
;; starting port until one binds, because a port already in use is ordinary and
;; not worth stopping for.
(define %candidates (lambda () (list (repl-endpoint-path))))

(define (repl-candidates)
  "The locations `start-repl!' should try, in order."
  (%candidates))

(define (repl-candidates! proc)
  "Say how to list the locations `start-repl!' tries, in order.

PROC takes no arguments and returns a list.  The default is the single Unix
socket path; a TCP host returns a run of port numbers."
  (set! %candidates proc)
  proc)

;; CALLED ON THE WAY OUT, with the location.  A host that published something --
;; a port file -- removes it here.
(define %cleanup! #f)
(define (repl-cleanup! proc) (set! %cleanup! proc) proc)

;;; ---------------------------------------------------------------------------
;;; The second transport, provided: TCP on loopback, published in a port file
;;; ---------------------------------------------------------------------------
;;
;; THIS WAS A SEAM WITH NOTHING BEHIND IT, and the asymmetry showed: a client
;; could READ a port file -- the convention is in `(scheme-utils repl client)',
;; because a name typed at a terminal has to be turned into somewhere to connect
;; -- while a SERVER could not write one, so every host that used this transport
;; wrote the same three procedures itself.  That is the convention living in two
;; places with one of them outside the library.
;;
;; It is here now for the same reason the Unix socket is: it is how a program
;; publishes where to find it, which is this module's business.  A host that uses
;; it says so in one line, `(repl-transport-tcp!)', and one that wants something
;; else still has the four seams below it.

;; WHERE PUBLISHED PORT FILES LIVE, which is NOT the rule for sockets above.
;;
;; A SOCKET IS THE ACCESS CONTROL: the kernel checks the filesystem permissions
;; on the path, which is why `repl-runtime-directory' refuses to put one
;; anywhere world-writable and why this module will not start without
;; $XDG_RUNTIME_DIR.
;;
;; A PORT FILE IS A SIGNPOST.  It says where to connect and grants nothing: the
;; endpoint is the port, and a loopback port is reachable by every user on the
;; machine whatever the file says.  So /tmp is an acceptable home for the
;; signpost in a way it is not for the socket, and a host without a runtime
;; directory should not lose its back door over a file that only contains a
;; number.
(define (repl-port-file-directory)
  "$XDG_RUNTIME_DIR, or /tmp.  See the note above on why the rule differs."
  (or (getenv "XDG_RUNTIME_DIR") "/tmp"))

(define* (repl-port-file-prefix #:optional (name #f))
  "What a NAME's port file starts with: `<name>-repl-'.

THE MATCHING HALF IS THE CLIENT'S, and this is here so the two agree: a client
looking for `schemacs' finds `<name>-repl-<pid>.port', and it can only do that if
the writing side and the reading side share this string."
  (string-append (or name %directory-name) "-repl-"))

(define* (repl-port-file #:optional (name #f))
  "The file NAME's port is published in, for THIS process.

Named for the pid so that several instances can have a back door open at once and
each file says which one it belongs to."
  (string-append (repl-port-file-directory) "/"
                 (repl-port-file-prefix name)
                 (number->string (getpid))
                 ".port"))

(define (repl-publish-port! port)
  "Write PORT where a client can find it.  Returns the file's path."
  (let ((path (repl-port-file)))
    (call-with-output-file path
      (lambda (out) (display port out)))
    path))

(define (repl-unpublish-port!)
  "Remove this process's port file, if it wrote one.

A file a CRASH leaves behind is the reader's problem -- the client ignores one
whose program is gone, because it connects rather than trusting the file."
  (catch #t (lambda () (delete-file (repl-port-file))) (lambda args #f)))

(define (repl-tcp-ports)
  "The ports to try when none was named: a run starting below the ephemeral
range and walking upward.

A CHOSEN PORT STARTS AT 20000 + this process's pid reduced into 0..11999, which
is below Linux's ephemeral range (32768..60999 by default) so that an ordinary
outbound connection is not sitting on it.  The number never has to be known by
anyone: it is in the file."
  (let ((start (+ 20000 (modulo (getpid) 12000))))
    (let loop ((n 0) (out '()))
      (if (>= n 32)
          (reverse out)
          (loop (+ n 1) (cons (+ start n) out))))))

(define* (repl-transport-tcp! #:key (port #f))
  "Publish the back door on TCP over loopback, with the port written to a file.

THE WHOLE TRANSPORT IN ONE CALL: how to make the socket, which ports to try, how
to publish the one that was taken, and how to remove the file on the way out.
A host that uses this is saying `serve on TCP and put the port in
$XDG_RUNTIME_DIR/<name>-repl-<pid>.port', which is the reference
implementation's arrangement and what its own client reads.

PORT, when given, is used rather than choosing one -- and calling this again with
a port is how a host honours one named on its command line, which may arrive
after this file is loaded.

Note what is NOT here: the listener is still on 127.0.0.1, and this module says
elsewhere why that is weaker than the Unix socket it defaults to.  A host with a
choice should take the socket."
  (repl-socket-maker! (lambda (p) (make-tcp-server-socket #:port p)))
  (repl-candidates! (lambda () (if port (list port) (repl-tcp-ports))))
  (repl-announce! (lambda (p) (repl-publish-port! p)))
  (repl-cleanup! (lambda (p) (repl-unpublish-port!)))
  #t)

;;; ---------------------------------------------------------------------------
;;; The host's module, wake and banner
;;; ---------------------------------------------------------------------------

;; The module every expression is read and evaluated in.
;;
;; PINNED, and that is not decoration.  `poll-repl!' is reached from wherever the
;; host's thread happened to be waiting -- a signal handler, a command's own
;; nested prompt -- so without this, what a name MEANS at the back door would
;; depend on how deep the program happened to be nested.  Measured in the
;; reference implementation: `(module-name (current-module))' answered
;; `(guile-user)' at idle and was an UNBOUND VARIABLE while a prompt was up,
;; because the module was then an editor library with no `import' to offer.
(define %module '(guile-user))

(define (repl-module) %module)
(define (repl-module! module) (set! %module module) module)

;; Whether to let Guile's welcome banner through.  A program is CONNECTED TO, not
;; started, so the answer is normally no.  Kept as a plain flag and applied with
;; `parameterize' at poll time -- see `drain'.  `set!' on a PARAMETER replaces the
;; binding itself, after which `parameterize' on it fails with "Not a parameter",
;; which is exactly what it did once.
(define %welcome? #f)
(define (repl-welcome) %welcome?)
(define (repl-welcome! flag) (set! %welcome? (and flag #t)) %welcome?)

(define (default-wake thunk)
  "Arrange for THUNK to be called when the main loop is next idle.

GLib's idle source, which is what every program in this tree runs on.  A default
rather than a requirement: `repl-wake!' replaces it, and a host with its own loop
supplies its own.

`g-idle-add' is reached through `resolve-module' rather than imported, so that
loading this module does not require G-Golf -- a program with no GLib in it uses
everything else here."
  (let ((m (resolve-module '(g-golf hl-api glib))))
    ((module-ref m 'g-idle-add) thunk)))

(define %wake default-wake)

(define (repl-wake) %wake)

(define (repl-wake! proc)
  "Say how to be woken when the back door has work.

PROC takes one argument -- a thunk -- and must arrange for it to be called ON THE
THREAD THAT OWNS THE PROGRAM'S STATE.

RETURN A TRUTHY VALUE WHEN A WAKE WAS ACTUALLY ARRANGED, and #f when it was not
-- a front end that has no hook yet is the ordinary case, and the difference
matters: a wake that arranged nothing must not be remembered as pending, or this
module stops trying to wake the host at all (see `wake!').  GLib's idle source is the default; a
compositor's fd watcher, a pipe a terminal selects on, or a plain
`call-with-new-thread' for a program with no loop at all, are what this is for.

A PLAIN VARIABLE, NOT A PARAMETER, AND THAT IS THE WHOLE POINT.  A parameter is a
fluid, and a fluid's value is captured per thread at the moment the thread is
made.  This is called from the server's READER thread, which is made by
`start-repl!' -- and a host that wires its wake up after that, which is the normal
order, would then read #f in every server thread for ever.  The wake would do
nothing, and a program whose waits are shortened precisely BECAUSE it believes it
can be woken would block until a keystroke.  The symptom is an idle program that
answers the back door only after you press a key, at 0% CPU, which reads as the
idle-burn having been fixed.  It had not been: the program had stopped hearing the
back door at all.

The value is a fact about the process -- which front end this is -- and not state
that varies with the dynamic extent, so a variable is what it is."
  (set! %wake proc)
  proc)

;; CALLED AFTER SOMETHING HAS BEEN EVALUATED, and it is not a convenience.  A
;; program that draws does so from its OWN command loop, so a change made from
;; outside that loop is never painted: measured in the reference implementation,
;; opening a file over the back door left the screen showing the previous buffer
;; until the next keypress.  A socket IS input, so the host redraws here.
(define %after-poll! #f)
(define (repl-after-poll! proc) (set! %after-poll! proc) proc)

;; CALLED BEFORE THE ENDPOINT OPENS.  A host uses it to build the namespace the
;; session will be evaluated in, so that a client already connected when the first
;; expression arrives finds the program there.
(define %before-start! #f)
(define (repl-before-start! proc) (set! %before-start! proc) proc)

;;; ---------------------------------------------------------------------------
;;; The server
;;; ---------------------------------------------------------------------------

;; THE PAIR OF GLOBALS A RUNNING SERVER NEEDS.  They are two rather than one
;; because the wake id outlives a poll: a wake says "there is work", and the id is
;; cleared when the queue is drained.
;;
;; `repl-state!' hands them out and `repl-restore!' puts them back, which is what
;; lets a host keep them in its own record -- and what lets two independent back
;; doors exist in one process, which this module's own test does.
(define %repl #f)              ; the coop server, or #f
(define %repl-location #f)     ; its location, for removal on shutdown
(define %wake-id #f)           ; the wake's id while a wake is pending
(define %wake-mutex (make-mutex))

(define (repl-state!)
  "The (server . location) this module currently holds, for a host to keep."
  (cons %repl %repl-location))

(define (repl-restore! state)
  "Make STATE -- from `repl-state!' -- the running server again."
  (set! %repl (car state))
  (set! %repl-location (cdr state))
  state)

;; Drain the WHOLE queue, not one operation.
;;
;; The wake is LEVEL-TRIGGERED: it says "there is work", not "there is one item
;; of work".  A single poll would therefore leave operations queued with no
;; further wake coming, and the client would HANG -- waiting for an answer to
;; something the server had already been told about.  That is what
;; `poll-coop-repl-server' answering #t or #f is for.
(define (drain)
  (set! %wake-id #f)
  ;; save-module-excursion + set-current-module + %inhibit-welcome-message,
  ;; which is what the reference implementation does and for the same reasons:
  ;; the first two make an expression mean the same thing wherever the program
  ;; was when it arrived, and the third keeps the copyright banner off a session
  ;; the user connected to rather than started.
  (let ((ran? #f))
    (save-module-excursion
     (lambda ()
       (set-current-module (resolve-module %module))
       (parameterize ((%inhibit-welcome-message (not %welcome?)))
         (let loop ()
           (when (poll-coop-repl-server %repl)
             (set! ran? #t)
             (loop))))))
    ;; A HOST'S REDISPLAY MUST NOT BE ABLE TO WEDGE THE DOOR.  This runs on the
    ;; main thread, inside the poll the front end makes -- so an error escaping
    ;; it takes the front end's own loop with it, and the program stops polling
    ;; for good while still looking perfectly healthy.  Reported loudly and
    ;; survived, because a back door that stops answering is worse than one that
    ;; prints a repaint error.
    (when (and ran? %after-poll!)
      (catch #t
        (lambda () (%after-poll!))
        (lambda (key . args)
          (format (current-error-port)
                  "scheme-utils repl server: the after-poll hook raised: ~a ~s~%"
                  key args)))))
  ;; #f removes the source the wake attached; see wake!.
  #f)

(define (wake! server)
  "Tell the host's loop that the back door has work.  Called from the reader
thread, and safe to call several times at once."
  ;; The check-and-set is guarded because the hook fires from the reader thread,
  ;; once per expression a client sends.  Attaching a source per wake would leak
  ;; one per keystroke.
  ;;
  ;; ONLY A TRUTHY ANSWER IS REMEMBERED AS PENDING.  A host's wake can do nothing
  ;; -- its front end has not installed a hook yet, which is the normal state
  ;; while a program is still starting -- and then it returns whatever its thunk
  ;; returned, which is usually nothing meaningful and in Guile is TRUTHY.  Cached
  ;; as "a wake is pending", that value silences EVERY LATER WAKE for the life of
  ;; the process: the door goes quiet and answers only when something else happens
  ;; to poll.  Measured -- a wake whose thunk did nothing swallowed the next one.
  ;;
  ;; **AND A WAKE THAT RAISES IS NOT ALLOWED TO TAKE THIS THREAD WITH IT.** This
  ;; runs on the server's READER thread -- the one thread that reads what a client
  ;; sends -- so an error escaping a host's wake costs more than that wake: it
  ;; kills the reader, and the door then answers whatever was already queued and
  ;; never reads another line.  Measured in a consumer: its wake applied the value
  ;; it had read instead of the wake itself and raised "Wrong type to apply", the
  ;; reader died on it, and the door served exactly one expression per connection
  ;; and then answered nothing, keystrokes included.  Nothing in that symptom
  ;; points here.  Reported, and answered #f, so the failure is loud, the wake is
  ;; not remembered as pending, and the next one tries again.
  (lock-mutex %wake-mutex)
  (unless %wake-id
    (let ((id (catch #t
                (lambda () (%wake drain))
                (lambda (key . args)
                  (format (current-error-port)
                          "scheme-utils repl server: the wake raised: ~a ~s~%"
                          key args)
                  #f))))
      (when id (set! %wake-id id))))
  (unlock-mutex %wake-mutex))

;;; ---------------------------------------------------------------------------
;;; Opening and closing
;;; ---------------------------------------------------------------------------

(define (open-endpoint! location)
  "A listening server socket at LOCATION, or #f when it cannot be had.

A location already in use is NOT an error worth stopping for -- the caller walks
to the next candidate -- so this answers #f rather than raising."
  (catch #t
    (lambda ()
      ;; A socket file left behind by a crashed program makes bind fail.  A live
      ;; one answers a connection; a dead one does not -- so it is removed here,
      ;; which is the only place that knows binding is about to be attempted.
      (when (and (string? location) (file-exists? location))
        (if (socket-alive? location)
            (error "in use")
            (delete-file location)))
      (let ((sock (%socket-maker location)))
        ;; `listen' IS REQUIRED AND NEITHER SOCKET CONSTRUCTOR DOES IT.  A Unix
        ;; `make-unix-domain-server-socket' creates the socket, sets SO_REUSEADDR
        ;; and binds -- and stops.  The path exists and is a socket, but nothing
        ;; ever accepts, so every client gets "Connection refused" and the back
        ;; door looks broken in a way that points at the CLIENT.
        ;;
        ;; The stock TCP REPL server gets away with the same omission because
        ;; something further down its path listens; over Unix, nothing does.
        (listen sock 16)
        sock))
    (lambda (key . args) #f)))

(define* (start-repl! #:key (name #f) (module #f) (welcome? #f))
  "Open the back door.  Returns the location it took, or #f when none was free.

NAME overrides the name this program was told to use.  MODULE, when given, is
pinned current before each evaluation -- see `repl-module' for why that is not
optional.

ASKING TWICE IS NOT AN ERROR: a door already open answers where it is.  This
matters more than it looks, because the two natural places to ask are a
program's own config file and its command line, and a program with both asks on
every start.  Raising there does not just print a message -- an error partway
through a config file ABANDONS THE REST OF IT, so a user who opens the door
from their init file loses every setting after that line the moment they pass
--server.  Measured in schemacs, which did exactly this."
  (cond
   (%repl %repl-location)               ; already open: say where, do nothing
   (else
    (when %before-start! (%before-start!))
    (let loop ((rest (if name
                         (list (repl-endpoint-path name))
                         (repl-candidates))))
      (cond
     ((null? rest)
      ;; Say so.  Otherwise "the door is shut" and "nobody asked for a door" look
      ;; exactly alike from outside, which is a confusing thing to debug.
      (format (current-error-port)
              "scheme-utils repl server: no free endpoint for the back door~%")
      #f)
     (else
      (let ((location (car rest)))
        (let ((sock (open-endpoint! location)))
          (cond
           ((not sock) (loop (cdr rest)))
           (else
            (set! %repl (spawn-coop-repl-server sock #:notify wake!))
            (set! %repl-location location)
            (when module (set! %module module))
            ;; The banner is suppressed around each poll, in `drain', NOT here.
            ;; %inhibit-welcome-message is a PARAMETER, and `set!' on a parameter
            ;; replaces the binding itself -- after which `parameterize' on it
            ;; fails with "Not a parameter", which is exactly what it did.
            (set! %welcome? (and welcome? #t))
            (when %announce! (%announce! location))
            location))))))))))

(define (poll-repl!)
  "Run everything the back door has queued, ON THE CALLING THREAD.

This is what the wake eventually calls, and what the program's main loop must
therefore run for a client to get an answer: the cooperative server reads in a
thread but evaluates here.  A program with a main loop gets this for free; a test
has to arrange it, which this module's own test does with a timeout."
  (when %repl (drain))
  #t)

(define (repl-running?) (and %repl #t))

(define (stop-repl!)
  "Close the back door and remove the endpoint, so `list-instances' stops
offering it.  A stale endpoint left behind makes the next start look like a
crash."
  (when %repl
    (set! %repl #f)
    (when %repl-location
      (if %cleanup!
          (%cleanup! %repl-location)
          ;; The default cleanup: a Unix socket is a FILE, and leaving it makes a
          ;; dead endpoint indistinguishable from a live one on disk.
          (when (and (string? %repl-location) (file-exists? %repl-location))
            (catch #t (lambda () (delete-file %repl-location)) (lambda args #f)))))
    (set! %repl-location #f)
    (set! %wake-id #f))
  #t)

;;; ---------------------------------------------------------------------------
;;; Finding a running program
;;; ---------------------------------------------------------------------------

(define (socket-alive? path)
  "Whether something is actually LISTENING on the Unix socket at PATH.

A stale socket file left by a crashed program looks identical to a live one on
disk -- same type, same permissions -- so this is settled by CONNECTING.  That is
the test that matters: the file existing proves only that something once ran.

An answer of #f is the ordinary case here, not a failure, because a socket file
outlives the program that made it."
  (catch #t
    (lambda ()
      (let ((s (socket AF_UNIX SOCK_STREAM 0)))
        (catch #t
          (lambda () (connect s AF_UNIX path) (close s) #t)
          (lambda args (catch #t (lambda () (close s)) (lambda a #f)) #f))))
    (lambda args #f)))

(define (basename path)
  (let loop ((i (- (string-length path) 1)))
    (cond ((< i 0) path)
          ((char=? (string-ref path i) #\/)
           (substring path (+ i 1) (string-length path)))
          (else (loop (- i 1))))))

(define (endpoints)
  "Every `.sock' file in this program's directory, sorted by name.

Empty rather than an error when there is no directory: a program asking what is
running before it has ever started is an ordinary state, not a fault.

This is the DIRECTORY LISTING, and it is the whole reason a Unix socket is worth
preferring: the names of the running programs are the names of the files."
  (let ((dir (catch #t repl-directory (lambda args #f))))
    (if (not dir)
        '()
        (sort (catch #t
                (lambda ()
                  (filter (lambda (f) (string-suffix? ".sock" f))
                          (map basename (scandir dir))))
                (lambda args '()))
              string<?))))

(define (instance-of path)
  "The instance name a socket PATH belongs to: its file name without `.sock'."
  (let ((f (basename path)))
    (string-drop-right f 5)))

(define (live-instances)
  "The instance names whose back door ANSWERS, in order.

This is the one to use programmatically.  `endpoints' lists what is ON DISK, which
includes whatever a crashed program left behind; only this settles which of them
anything is listening on."
  (let ((dir (catch #t repl-directory (lambda args #f))))
    (if (not dir)
        '()
        (map instance-of
             (filter socket-alive?
                     (map (lambda (f) (string-append dir "/" f)) (endpoints)))))))

(define* (list-instances #:optional (port (current-output-port)))
  "Print the instances, marking any that are stale.

Returns the count of LIVE ones, so a caller can branch on it.  Printing rather
than returning strings because this is the body of a `list' subcommand, and the
caller that wants data uses `live-instances'."
  (let ((dir (catch #t repl-directory (lambda args #f))))
    (if (not dir)
        (begin (format port "no XDG_RUNTIME_DIR, so no instances~%") 0)
        (let ((files (endpoints)))
          (if (null? files)
              (begin (format port "no running instances~%") 0)
              (let ((live (live-instances)))
                (for-each (lambda (f)
                            (let ((name (string-drop-right f 5)))
                              (format port "~a~a~%"
                                      name
                                      (if (member name live) "" "  (stale)"))))
                          files)
                (length live)))))))
