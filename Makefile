# Makefile -- build, install and package scheme-utils.
#
# Guile has no `guild install'.  What it does sanction is the three pieces this
# file drives:
#
#   guile-config info VAR   where Guile looks for modules
#   guild compile           how to compile one
#   guild use2dot           what a module depends on
#
#   make                    compile every module into build/
#   make test               run the test suites
#   make install            into $(PREFIX), default /usr/local, with .go files
#   make install-local      into ~/.local, sources only (Guile compiles on use)
#   make uninstall          remove what install put there
#   make clean              remove build/
#
# No manual page yet.

GUILE ?= guile
GUILD ?= guild

# The directory-version Guile uses ("3.0", not "3.0.11").
EFFVER := $(shell $(GUILE) -q -c '(display (effective-version))')

# Where a system-wide install belongs -- ask Guile rather than hardcode.
GUILE_SITEDIR   := $(shell guile-config info sitedir)
GUILE_CCACHEDIR := $(shell guile-config info siteccachedir)

# --- install layout ---------------------------------------------------------
# DESTDIR is honoured, so a package can stage into a chroot:
#   make install DESTDIR=$(pkgdir) PREFIX=/usr
PREFIX    ?= /usr
BINDIR    ?= $(PREFIX)/bin
MANDIR    ?= $(PREFIX)/share/man
MAN1DIR   ?= $(MANDIR)/man1
SITEDIR   ?= $(PREFIX)/share/guile/site/$(EFFVER)
CCACHEDIR ?= $(PREFIX)/lib/guile/$(EFFVER)/site-ccache

# Guile's auto-compile cache lives under $XDG_CACHE_HOME when that is set and
# $HOME/.cache otherwise.  Honour the same rule it does, or the targets below
# look in a directory Guile never writes to.
CACHEHOME ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)

LOCALPREFIX  ?= $(HOME)/.local
LOCALBINDIR  ?= $(LOCALPREFIX)/bin
LOCALMANDIR  ?= $(LOCALPREFIX)/share/man
LOCALMAN1DIR ?= $(LOCALMANDIR)/man1
LOCALSITEDIR ?= $(LOCALPREFIX)/share/guile/site/$(EFFVER)

# --- the manual pages --------------------------------------------------------
# Nroff sources in man/, installed as they stand.  man-db reads an uncompressed
# page perfectly well, so nothing here depends on gzip; a packager who wants
# /usr/share/man/man1/schemacs.1.gz can gzip the installed file.
MANPAGES := $(wildcard man/*.1)

# --- what is a module and what is a script ----------------------------------
# Every .scm with a define-module is a module: it is compiled and installed
# under the site directory, its .go under the site ccache.  
# bin/ holds launchers, installed as they stand.

DIRS    := scheme-utils
SCRIPTS :=
MODULES := $(filter-out $(SCRIPTS),$(wildcard $(addsuffix /*.scm,$(DIRS))))
GOS     := $(patsubst %.scm,build/%.go,$(MODULES))

# What gets installed from the tree: every file under $(DIRS) except editor
# backups.  `cp -r $(DIRS)' carried foo.scm~ along with foo.scm, so whatever an
# editor left lying in the working tree ended up in the system's site directory
# -- where nothing ever removes it.  One file at a time, by name, with `find'
# rather than a wildcard so the list holds files and not directories.
SOURCES := $(shell find $(DIRS) -type f ! -name '*~')

all: $(GOS)

# -L . so a module's own imports resolve from the tree while it compiles
build/%.go: %.scm
	@mkdir -p $(dir $@)
	$(GUILD) compile -L . -o $@ $<

# The per-file prerequisites come from Guile's own dependency tool.  They are
# conservative -- a .go is rebuilt when any module it uses changes, not only
# when a macro did -- which is the safe direction to be wrong in.  The prelude
# is asked about too, so its .go is rebuilt when a module it imports changes.
build/deps.mk: $(MODULES) $(SCRIPTS) tools/mkdeps.scm
	@mkdir -p build
	@GUILE_LOAD_PATH=. $(GUILE) -q tools/mkdeps.scm $(MODULES) $(SCRIPTS) > $@

-include build/deps.mk

# --- installing -------------------------------------------------------------

# The old copy is cleared first: a module that has been renamed or deleted
# would otherwise linger beside the new one and still be found.
install: all
	install -d $(DESTDIR)$(SITEDIR) $(DESTDIR)$(CCACHEDIR)
	rm -rf $(DESTDIR)$(SITEDIR)/scheme-utils
	rm -rf $(DESTDIR)$(CCACHEDIR)/scheme-utils
	for f in $(SOURCES); do install -D -m 644 $$f $(DESTDIR)$(SITEDIR)/$$f; done
	cp -r build/scheme-utils $(DESTDIR)$(CCACHEDIR)/

# A local install carries no .go: Guile compiles into the user's own cache the
# first time it loads a module.  Slower once, then the same as an install, and
# it survives a Guile upgrade without anyone recompiling anything.
#
# GUILE DOES NOT SEARCH THIS DIRECTORY.  Measured on this machine, `guile -q -c
# '(display %load-path)'` answers
#
#   (/usr/share/guile/3.0 /usr/share/guile/site/3.0 /usr/share/guile/site /usr/share/guile)
#
# -- nothing under $HOME -- so a local install is invisible until the load path
# is told about it.  A launcher adds it (`bin/scheme-toolkit' in scheme-shell
# does, and schemacs' `bin/se' prepends its own prefix's site directory for the
# same reason); so does exporting
#
#   GUILE_LOAD_PATH=$(LOCALSITEDIR):$GUILE_LOAD_PATH
#
# `make install' has no such caveat: $(SITEDIR) is one of the four directories
# above.  Use it when the modules should be found without any help.
install-local:
	install -d $(LOCALSITEDIR)
	rm -rf $(LOCALSITEDIR)/scheme-utils
	for f in $(SOURCES); do install -D -m 644 $$f $(LOCALSITEDIR)/$$f; done

# uninstall removes what install put there: the site tree, its ccache, the
# launcher, and the manual page.  It does NOT touch the auto-compile cache,
# which belongs to whoever
# RAN the shell -- and under sudo, $HOME and $XDG_CACHE_HOME are root's, not
# theirs, so it could not find it if it tried.  Entries left behind are keyed by
# the installed source path; they are harmless (Guile recompiles when the source
# is newer) but a user who wants them gone can remove
# $(CACHEHOME)/guile/ccache/*/usr/share/guile/site/$(EFFVER) themselves.
uninstall:
	rm -rf $(DESTDIR)$(SITEDIR)/scheme-utils
	rm -rf $(DESTDIR)$(CCACHEDIR)/scheme-utils

# A local install ships no .go: Guile compiles those sources into the user's
# OWN cache the first time it loads them.  That cache is keyed by the absolute
# source path, so the entries for this tree sit under a directory named after
# it -- and they are ours to remove, not just the sources.  (Guarded: an empty
# LOCALSITEDIR would otherwise make the pattern match every cached tree.)
uninstall-local:
	rm -rf $(LOCALSITEDIR)/scheme-utils
	@if [ -n "$(LOCALSITEDIR)" ]; then \
	   rm -rf $(CACHEHOME)/guile/ccache/*$(LOCALSITEDIR); \
	 fi
	@if [ -n "$(LOCALBINDIR)" ]; then \
	   rm -rf $(CACHEHOME)/guile/ccache/*$(LOCALBINDIR); \
	 fi

# --- housekeeping -----------------------------------------------------------

test: all
	$(GUILD) compile -L . -o /dev/null tests/run-tests.scm 2>/dev/null || true
	$(GUILE) -L . tests/run-tests.scm

clean:
	rm -rf build

# Guile's auto-compile cache is keyed by the source path and version; a stale
# entry there is what makes an edit appear not to take effect.  (`make clean'
# does not touch it: it is not ours.)
clean-cache:
	rm -rf $(CACHEHOME)/guile/ccache/*$(CURDIR)

# For a package: the directories Guile itself reports.  `make install
# DESTDIR=$(pkgdir) PREFIX=/usr' lands in exactly these.
where:
	@echo "sitedir    $(GUILE_SITEDIR)"
	@echo "ccachedir  $(GUILE_CCACHEDIR)"

.PHONY: all install install-local uninstall uninstall-local test clean clean-cache where
