#!/usr/bin/guile
!#
;;; tools/mkdeps.scm -- emit Makefile prerequisites for the module tree.
;;;
;;;   tools/mkdeps.scm scheme-utils/load.scm scheme-utils/watch.scm ... > build/deps.mk
;;;
;;; A .go must be rebuilt when its own source changes, and when any module it
;;; uses changes: a module variable is resolved at run time, but a MACRO is
;;; expanded at compile time, so a dependent compiled against the old macro is
;;; silently wrong.  Rather than guess which imports are which, we take the
;;; whole dependency list from Guile's own tool -- `guild use2dot` -- which is
;;; conservative (it rebuilds more than strictly needed) and stays right as the
;;; tree changes.  Modules with no file here (srfi, ice-9, g-golf, ...) are
;;; dropped.
;;;
;;; Needs GUILE_LOAD_PATH to include the tree root, so that the modules can be
;;; found while their dependencies are read.
;;;
;;; Taken from ~/GIT/scsh/tools/mkdeps.scm, which solves the same problem for a
;;; tree laid out the same way; the module-name-to-path rule below is the whole
;;; of the port, and it is the same rule.

(use-modules (ice-9 popen) (ice-9 textual-ports) (ice-9 regex)
             (srfi srfi-1))

(define (module->file name)
  (string-append (string-join (string-split name #\space) "/") ".scm"))

(define (uses-of file)
  (let* ((port (open-pipe* OPEN_READ "guild" "use2dot" file))
         (out  (get-string-all port)))
    (close-pipe port)
    ;; edges look like:  "(structured-scsh scsh)" -> "(structured-scsh engine)";
    (delete-duplicates
     (filter-map (lambda (m)
                   (let ((f (module->file (match:substring m 1))))
                     (and (file-exists? f) f)))
                 (list-matches "-> *\"\\(([^)]*)\\)\"" out)))))

(define (emit file)
  (let ((go (string-append "build/" (substring file 0 (- (string-length file) 4)) ".go")))
    (display go) (display ": ") (display file)
    (for-each (lambda (d) (display " ") (display d)) (uses-of file))
    (newline)))

(for-each emit (cdr (command-line)))
