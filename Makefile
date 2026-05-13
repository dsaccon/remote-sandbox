SHELL := /usr/bin/env bash

SHELL_FILES := $(shell find bin lib ami test -type f \( -name '*.sh' -o -path 'bin/sandbox*' \) 2>/dev/null)

.PHONY: lint test smoke clean help

help:
	@echo "Targets: lint, test, smoke"

lint:
	@shellcheck -x $(SHELL_FILES)

test:
	@bats test/unit

smoke:
	@bash test/smoke.sh
