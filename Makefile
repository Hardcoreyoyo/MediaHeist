# MediaHeist Makefile ---------------------------------------------------------
# Usage examples:
#   make download URL="https://youtu.be/xxxx"
#   make download LIST=urls.txt
#   make all LIST=urls.txt MAX_JOBS=8
# -----------------------------------------------------------------------------
SHELL := /usr/bin/env bash

# Root dirs
SRC_DIR := src
TMP_DIR := tmp
SUMMARY_DIR := summary

# Central logging (one file per make invocation)
LOG_DIR := logs
START_TS := $(shell date '+%m%d_%H%M%S')
LOG_FILE := $(LOG_DIR)/$(START_TS).log

# Make sure LOG_FILE propagates to every recipe's environment
export LOG_FILE LOG_DIR

# Ensure log directory exists before anything runs
$(shell mkdir -p $(LOG_DIR))

# Inherit env from caller or .env
-include .env
# Export all variables (including those from .env) to recipe environment
export

# -----------------------------------------------------------------------------
# Validate required configuration and apply MAX_JOBS for parallelism
# -----------------------------------------------------------------------------
REQUIRED_VARS := GEMINI_API_KEY GEMINI_MODEL_ID WHISPER_BIN WHISPER_MODEL
MISSING := $(strip $(foreach v,$(REQUIRED_VARS),$(if $($(v)),,$(v))))
ifeq ($(MISSING),)
  # All required variables present
else
  $(error Missing required variables in .env: $(MISSING))
endif

# Apply parallel jobs setting if provided
ifneq ($(strip $(MAX_JOBS)),)
  MAKEFLAGS += -j$(MAX_JOBS)
endif

# -----------------------------------------------------------------------------
# Helper functions (bash) used inside $(shell) context
# Detect SHA1 hashing command (sha1sum on Linux, shasum on macOS)
ifeq ($(shell command -v sha1sum >/dev/null 2>&1 && echo yes),yes)
  SHA1SUM_CMD := sha1sum
else
  SHA1SUM_CMD := shasum
endif

# Helper function: returns SHA1 hash of a string (URL)
hash_url = $(shell echo -n "$1" | $(SHA1SUM_CMD) | awk '{print $$1}')

# -----------------------------------------------------------------------------
# Target: download -------------------------------------------------------------
# Creates per-video hash dir and spawns downloads in parallel
# -----------------------------------------------------------------------------
ifeq ($(origin URL),undefined)
ifeq ($(origin LIST),undefined)
$(error Must provide URL or LIST)
endif
endif

URLS := $(if $(URL),$(URL),$(shell cat $(LIST)))
HASHED_DIRS := $(patsubst %,$(SRC_DIR)/%,$(foreach u,$(URLS),$(call hash_url,$(u))))

.PHONY: download
 download: $(addsuffix /download.done,$(HASHED_DIRS))

$(SRC_DIR)/%/download.done:
	@mkdir -p "$(@D)"
		@# Resolve the original URL that maps to this hash directory
	@U=""; \
	for url in $(URLS); do \
	  if [ "$$(echo -n "$$url" | $(SHA1SUM_CMD) | awk '{print $$1}')" = "$(notdir $(@D))" ]; then U="$$url"; break; fi; \
	done; \
	echo "[Make] Starting download $$U -> $(@D)"; \
	{ \
		$(SHELL) scripts/download.sh "$$U" "$(@D)" 2>&1 | sed -u "s/^/[download $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

# -----------------------------------------------------------------------------
# Rules for audio, frames, srt, ocr -------------------------------------------
# Each depends on .done of previous stage
# Parallelised via GNU make -j or MAX_JOBS
# -----------------------------------------------------------------------------
.PHONY: audio srt frames ocr final all

audio: $(addsuffix /audio.done,$(HASHED_DIRS))
frames: $(addsuffix /frames.done,$(HASHED_DIRS))
srt:    $(addsuffix /srt.done,$(HASHED_DIRS))
ocr:    $(addsuffix /ocr.done,$(HASHED_DIRS))
# final:  $(addsuffix /final.done,$(HASHED_DIRS))

$(SRC_DIR)/%/audio.done: $(SRC_DIR)/%/download.done
	{ \
		$(SHELL) scripts/audio.sh "$(@D)" 2>&1 | sed -u "s/^/[audio $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/srt.done: $(SRC_DIR)/%/audio.done
	{ \
		$(SHELL) scripts/transcribe.sh "$(@D)" 2>&1 | sed -u "s/^/[srt $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/frames.done: $(SRC_DIR)/%/audio.done
	{ \
		$(SHELL) scripts/frames.sh "$(@D)" 2>&1 | sed -u "s/^/[frames $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/ocr.done: $(SRC_DIR)/%/frames.done
	{ \
		$(SHELL) scripts/ocr.sh "$(@D)" 2>&1 | sed -u "s/^/[ocr $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

# $(SRC_DIR)/%/final.done: $(SRC_DIR)/%/ocr.done $(SRC_DIR)/%/srt.done
# 			( $(SHELL) scripts/final_summary.sh "$(@D)" 2>&1 | sed -u "s/^/[final $(notdir $(@D))] /" ) &

# all: download audio frames srt ocr final
# all: download audio srt frames ocr
all: download audio srt frames

# -----------------------------------------------------------------------------
# House-keeping ----------------------------------------------------------------
clean:
	rm -rf $(TMP_DIR) $(SRC_DIR) $(SUMMARY_DIR)

.PHONY: clean
