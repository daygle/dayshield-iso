# DayShield ISO Builder — Makefile
#
# Usage:
#   make iso ROOTFS=../dayshield-rootfs/rootfs.tar.zst ROOTFS_SHA256=<sha256>
#   make verify ISO=dayshield.iso
#   make clean

SHELL        := /usr/bin/env bash
.SHELLFLAGS  := -euo pipefail -c

# Inputs / outputs
ROOTFS       ?= rootfs.tar.zst
OUTPUT       ?= dayshield.iso
ARCH         ?= amd64
INSTALLER_UI ?= ../dayshield-installer-ui/installer-ui
ROOTFS_SHA256 ?=

SHELLCHECK   ?= shellcheck
SHELLCHECK_FILES := $(shell find scripts config -name '*.sh' | sort)

SCRIPTS_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))scripts

.PHONY: iso verify verify-qemu clean distclean lint help

##@ Main targets

iso: ## Build the DayShield installer ISO
	@test -f "$(ROOTFS)" || { \
	  echo "ERROR: ROOTFS not found: $(ROOTFS)"; \
	  echo "Usage: make iso ROOTFS=<path-to-rootfs.tar.zst> INSTALLER_UI=<path-to-installer-ui-dir>"; \
	  exit 1; \
	}
	@test -d "$(INSTALLER_UI)" || { \
	  echo "ERROR: INSTALLER_UI not found: $(INSTALLER_UI)"; \
	  echo "Usage: make iso ROOTFS=<path-to-rootfs.tar.zst> INSTALLER_UI=<path-to-installer-ui-dir>"; \
	  exit 1; \
	}
	@echo "==> Building DayShield ISO …"
	bash "$(SCRIPTS_DIR)/build-iso.sh" \
	    --rootfs "$(ROOTFS)" \
	    --output "$(OUTPUT)" \
	    --arch   "$(ARCH)" \
	    $(if $(ROOTFS_SHA256),--rootfs-sha256 "$(ROOTFS_SHA256)",) \
	    --installer-ui "$(INSTALLER_UI)"
	@echo ""
	@echo "ISO: $(OUTPUT)"

verify: ## Verify the DayShield installer ISO
	@test -f "$(ISO)" || { \
	  echo "ERROR: ISO not found: $(ISO)"; \
	  echo "Usage: make verify ISO=<path-to-dayshield.iso>"; \
	  exit 1; \
	}
	bash "$(SCRIPTS_DIR)/verify.sh" --iso "$(ISO)"

verify-qemu: ## Verify ISO by booting it in QEMU (requires qemu-system-x86_64)
	@test -f "$(ISO)" || { \
	  echo "ERROR: ISO not found: $(ISO)"; \
	  exit 1; \
	}
	bash "$(SCRIPTS_DIR)/verify.sh" \
	    --iso "$(ISO)" \
	    --qemu \
	    $(if $(OVMF),--ovmf "$(OVMF)",)

clean: ## Remove intermediate build artefacts
	@echo "==> Cleaning build artefacts …"
	rm -rf build/
	@echo "==> Done."

lint: ## Run ShellCheck on all shell scripts
	@command -v $(SHELLCHECK) >/dev/null 2>&1 || { \
	  echo "ERROR: $(SHELLCHECK) not found. Install shellcheck to run lint." >&2; \
	  exit 1; \
	}
	@$(SHELLCHECK) $(SHELLCHECK_FILES)

distclean: clean ## Remove build artefacts AND the generated ISO
	rm -f "$(OUTPUT)" "$(OUTPUT).md5" "$(OUTPUT).sha256"

##@ Help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} \
	      /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
	      /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' \
	    $(MAKEFILE_LIST)
