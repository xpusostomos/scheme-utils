# scheme-utils

Guile utilities for programs that load a config file and reload it when it
changes, and for programs that can be talked to while they run. No C.

| module | what it is |
|---|---|
| `(scheme-utils inotify)` | Linux inotify through `(system foreign)`. libc called directly; the names are the inotify(7) ones on purpose, because the whole value of the module is that it reads like the man page. |
| `(scheme-utils load)` | `auto-load` / `auto-load-config`: evaluate a config file into a module the caller names, resolving bare names under a config directory. |
| `(scheme-utils watch)` | Watch every file a config loaded and call a reload when one changes. |
| `(scheme-utils repl server)` | A back door: evaluate Scheme IN a running program over a Unix socket under `$XDG_RUNTIME_DIR`. |
| `(scheme-utils repl client)` | The other end of it: connect, send an expression, read the answer. |
| `(scheme-utils repl coop-server)` | Guile's own `(system repl coop-server)`, vendored with one `#:notify` hook added. Drives the server above; knows nothing about sockets. |

The first three are taken from Hyprscheme's `hyprscheme/{inotify,watch}.scm` and
its `hl-load` / `hl-load-config`, with the renames and the host seams described
in each file's header. The comments explaining *when* to watch and *what* an
event means are theirs, and are the reason the code exists.

The `repl` three are taken from schemacs' `repl.scm` and scheme-shell's
`scheme-toolkit/repl.scm`, which were the same code in two projects with the host
details woven through it. What is shared is the part about BEING a back door --
the socket, the wake, the drain, the instance listing -- and what stayed behind
is everything specific to either program, as the seams below.

## The back door

A program that embeds `(scheme-utils repl server)` can be talked to while it
runs: another process connects to its socket and evaluates expressions *in it*,
on its own thread, with its own state in scope. That replaces the usual
arrangement -- a control protocol with a fixed list of verbs, a parser for them,
and a handler that switches on a string.

**It is arbitrary code execution over a socket, by design**, and it is confined
as tightly as that allows: a UNIX socket, so the kernel checks filesystem
permissions on connect; under `$XDG_RUNTIME_DIR`, which is per-user and 0700;
**refusing to start at all** when that variable is unset rather than falling
back to `/tmp`, which is world-writable and shared; never TCP unless a host asks
for it explicitly.

```scheme
;; Two things a program must supply, three it may:
(repl-directory-name! "my-thing")            ; $XDG_RUNTIME_DIR/my-thing/
(repl-name! (lambda () "my-thing-1"))        ; what THIS instance is called
(repl-module! '(my-thing user))              ; where expressions are evaluated
(repl-wake! my-idle-source)                  ; how to be woken (GLib is the default)
(repl-before-start! open-user-environment)   ; prepare the namespace first
(repl-after-poll! redraw)                    ; repaint after something ran

(start-repl!)      ; -> the socket path, or #f when none was free
(poll-repl!)       ; run what has been queued, ON THIS THREAD
(stop-repl!)       ; close it and remove the socket
```

**The wake is the same seam `(scheme-utils watch)` uses**, and for the same
reason: waiting means an event loop, and the loop belongs to the host. GLib's
idle source is the default; anything else is `repl-wake!`.

**The transport is a seam too.** A Unix socket is the default because its NAME
IS ITS ADDRESS -- listing a directory is listing the running instances, so a
client needs no port file and no way of telling a live endpoint from a stale one
but connecting to it. `repl-socket-maker!`, `repl-announce!` and
`repl-candidates` are the three places a TCP host overrides to keep the port
file it already has.

A client uses `(scheme-utils repl client)`:

```scheme
(repl-eval (repl-endpoint-path "my-thing-1") "(+ 1 2)")   ; => "$1 = 3"
(repl-eval-values socket expr)                            ; => text, and failed?
(repl-run-session socket)                                 ; be a REPL for it
```

### `bin/repl` -- the same thing from a terminal

Installed as `repl`, and it takes the INSTANCE NAME, not the program:

```
$ repl                  what has a back door open, and whether it answers
$ repl list             the same
$ repl scheme-desktop   an interactive session with the shell
$ repl schemacs         ... or with the editor
$ repl -e '(+ 1 2)' scheme-desktop        evaluate once and print, then exit
$ repl -p ~/some/socket.sock              an explicit path, no search
```

**The exit status is the point for `-e`**: 0 when the expression produced a
value, 1 when the program reported an error, 2 when there was nothing to connect
to. A script driving a running program can tell those apart, which the answer
text alone cannot.

**It speaks both transports.** An endpoint in this tree is a Unix socket under a
program's directory; schemacs publishes a *port file* instead. The protocol is
identical either way, so only finding it differs -- and a NAME is resolved
against both, liveness settled by connecting rather than by looking at a file,
because a socket file and a port file both outlive the program that wrote them.
A stale one is listed and marked `(stale)` rather than hidden: a program that
crashed and left its endpoint behind is not the same as one that never started,
and the two need different fixes.

**Only real back doors are listed.** The runtime directory is full of other
programs' sockets -- `hyprmoncfgd`, `mousehop-gui`, a keyring -- so a candidate
is asked its name: Guile's REPL announces itself with `scheme@(...)> ` and
nothing else does. That check is what stops `repl somename` hanging on a program
which accepts the connection and then says nothing at all.

## The host contract

scheme-utils does not own an event loop, and does not pretend to. A program
supplies three things and gets a working watcher:

```scheme
(auto-config-dir! "/home/me/.config/my-thing")   ; where a bare name resolves
(auto-load-module! '(my-thing user))             ; where a loaded file's defines land
(auto-watch-configure! #:reload (lambda () (rebuild!)))
(auto-watch-start!)                              ; arms; call BEFORE loading
(auto-load (string-append (auto-config-dir) "/init.scm"))
```

`auto-watch-start!` must come **before** anything is loaded. It is what *arms*
the watcher, and an unarmed watcher records nothing -- a file loaded before it
was loaded by the program, not by the config.

**The watched set is exactly the files `auto-load` read**, reported by the loader
as it reads them. Nothing else is watched and nothing is guessed: a file loaded
by a bare `load` / `primitive-load` is invisible to the watcher, and so is
anything the Scheme compiler reads. (Upstream took this list from Guile's
`%load-hook`, which fires for every file the *process* loads -- so evaluating
anything over a REPL pulled Guile's own compiler sources into the watch list, 60
files of them. This is the one place this tree deliberately parts company with
it.) A file loaded before `auto-watch-start!`, or reported while unarmed, is not
recorded.

**Waiting on the file descriptor is a seam.** `auto-watch-waiter!` takes
`(proc fd thunk)`. GLib's is supplied by default, so a GLib program says
nothing; a Hyprland plugin passes `hl--c-on-readable` and gets the same
behaviour on the compositor's loop.

A file the *host* reads itself rather than by loading -- a data config it parses
-- is named with `auto--watch-begin!`, which records it and marks its current
text as what has been acted on. Without it, editing that file would do nothing,
because nothing ever loaded it and so the loader never reported it.

## Building and installing

```
make                 compile every module into build/
make test            run the suites (22 checks; drives a real inotify fd)
make install         into $(SITEDIR), with .go files   (default PREFIX=/usr)
make install-local   into ~/.local/share/guile/site/$(EFFVER), sources only
make uninstall-local
make clean-cache     drop this tree's entries from Guile's auto-compile cache
```

Both install targets also put the `repl` program in `$(BINDIR)` (`/usr/bin` for
`install`, `~/.local/bin` for `install-local`); the matching uninstall targets
remove it. The suite count in the line above is the historical one -- the real
count is whatever `make test` says.

### `install-local` needs the load path, and Guile will not add it

Guile does **not** search `~/.local/share/guile/site/3.0`. Measured on this
machine:

```
$ guile -q -c '(display %load-path)'
(/usr/share/guile/3.0 /usr/share/guile/site/3.0 /usr/share/guile/site /usr/share/guile)
```

-- nothing under `$HOME`. So a local install is invisible until something puts
it on the path. `make install` has no such caveat: `$(SITEDIR)` is one of the
four directories above.

Two launchers in this family do it for you: `scheme-shell`'s
`scheme-toolkit/bin/scheme-toolkit` prepends the local site directory when it
exists, and schemacs' `bin/se` prepends its own prefix's site directory. For
anything else:

```
export GUILE_LOAD_PATH="$HOME/.local/share/guile/site/$(guile -q -c '(display (effective-version))'):$GUILE_LOAD_PATH"
```

## Testing without touching a real config

The suites drive the real machinery -- a real fd, real files, a real main loop,
a real socket -- and write to `/tmp/scheme-utils-test-<pid>`. When probing a
*consumer's* config by hand, set the config environment on the **command line**,
not with `setenv` from inside the script: a program's modules are often loaded
before the script's first line, and a config path computed in a top-level
`define` will already have resolved to the real one.

`tests/repl.scm` runs on its own with nothing set, which is the way to debug it:

```
guile -L . tests/repl.scm
```

Under `make test` it is *loaded* into `tests/run-tests.scm` instead, so its
assertions join that suite's total rather than printing a second summary. The
runner sets `SCHEME_UTILS_TEST_DIR` and both suites use it, so the sockets go in
one scratch directory -- never in the real `$XDG_RUNTIME_DIR`, which is the one
place leftover sockets would be least welcome.

**One rule if you add to that file: the client half runs in a THREAD and the
polling happens on the main one.** The server reads on its own thread but
evaluates on whichever thread calls `poll-repl!`, so a single thread that sends,
polls and then reads works for a value and DEADLOCKS on an error -- the program
enters a debugger waiting to read from that same socket, and the thread that
would answer it is the one blocked inside the poll. It hangs with no output at
all, which is a long way from the cause.
