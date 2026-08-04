# Thin wrappers around the shell scripts, which remain the real entry points.
#
# The targets exist mainly to stop make from doing something surprising: with
# no makefile at all, 'make install' matches make's built-in '%: %.sh' rule and
# "builds" a file called install by copying install.sh, instead of running it.
# The copy is a stale duplicate from the moment install.sh changes, and it looks
# exactly like a real installer. Declaring the targets phony makes 'make install'
# do what it reads like.
#
# Environment variables reach the scripts as usual:
#   NO_SERVICE=1 make install
#   PREFIX=/opt/claude-vps-guard make install
#   PURGE=1 make uninstall

.PHONY: install uninstall help

help:
	@echo 'make install     run ./install.sh'
	@echo 'make uninstall   run ./uninstall.sh'
	@echo
	@echo 'The scripts take the same variables either way, for example:'
	@echo '  NO_SERVICE=1 make install'

install:
	./install.sh

uninstall:
	./uninstall.sh
