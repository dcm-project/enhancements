# Define variables at the top for easier maintenance
PRETTIER ?= npx prettier
FILE ?= **/*.md

# First target is the default (running just 'make')
help:
	@echo "Usage:"
	@echo "  make format              - Format all markdown files"
	@echo "  make format FILE=x.md    - Format specific file"
	@echo "  make check-format        - Check all markdown files"
	@echo "  make check-format FILE=x - Check specific file"
	@echo "  make new NAME=xxx        - Create new enhancement"

format:
	$(PRETTIER) --write --prose-wrap always --print-width 80 "$(FILE)"

check-format:
	$(PRETTIER) --check --prose-wrap always --print-width 80 "$(FILE)"

new:
	@# Shell logic: Check if NAME is empty
	@if [ -z "$(NAME)" ]; then \
		echo "Error: NAME is required."; \
		echo "Usage: make new NAME=your-enhancement-name"; \
		exit 1; \
	fi
	@# Shell logic: Check regex format
	@if ! echo "$(NAME)" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$$'; then \
		echo "Error: NAME must be lowercase, words separated by hyphens"; \
		echo "Example: my-enhancement-name"; \
		exit 1; \
	fi
	@mkdir -p enhancements/$(NAME)
	@cp enhancements/template.md enhancements/$(NAME)/$(NAME).md
	@echo "Created enhancements/$(NAME)/$(NAME).md"

.PHONY: help format check-format new