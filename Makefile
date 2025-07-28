# MediaHeist Makefile ---------------------------------------------------------
# Usage examples:
#   make download URL="https://youtu.be/xxxx"              # Full YouTube URL
#   make download URL="q6qw0IJ1i7w"                       # YouTube video ID
#   make download URL="/path/to/video.mp4"                # Local file path
#   make download LIST=urls.txt                           # Batch processing
#   make all LIST=urls.txt MAX_JOBS=8                     # Parallel processing
# 
# Supported input formats:
#   - YouTube URLs: https://www.youtube.com/watch?v=VIDEO_ID
#   - YouTube short URLs: https://youtu.be/VIDEO_ID
#   - YouTube video IDs: VIDEO_ID (11 characters)
#   - Local file paths: /absolute/path/to/video.mp4
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
.PHONY: audio srt frames pre_srt_summary ocr final all

audio: $(addsuffix /audio.done,$(HASHED_DIRS))
frames: $(addsuffix /frames.done,$(HASHED_DIRS))
pre_srt_summary: $(addsuffix /pre_srt_summary.done,$(HASHED_DIRS))
srt:    $(addsuffix /srt.done,$(HASHED_DIRS))
ocr:    $(addsuffix /ocr.done,$(HASHED_DIRS))
final:  $(addsuffix /final.done,$(HASHED_DIRS))

$(SRC_DIR)/%/audio.done: $(SRC_DIR)/%/download.done
	{ \
		$(SHELL) scripts/audio.sh "$(@D)" 2>&1 | sed -u "s/^/[audio $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/srt.done: $(SRC_DIR)/%/audio.done
	HASH="$(notdir $(@D))"; \
	ORIGINAL_URL=""; \
	for url in $(URLS); do \
	  if [ "$$(echo -n "$$url" | $(SHA1SUM_CMD) | awk '{print $$1}')" = "$$HASH" ]; then \
	    ORIGINAL_URL="$$url"; \
	    break; \
	  fi; \
	done; \
	if [ -z "$$ORIGINAL_URL" ]; then \
	  echo "[WARNING] Cannot find original URL for hash: $$HASH, transcription will use Whisper only"; \
	fi; \
	{ \
		ORIGINAL_URL="$$ORIGINAL_URL" $(SHELL) scripts/transcribe.sh "$(@D)" 2>&1 | sed -u "s/^/[srt $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/frames.done: $(SRC_DIR)/%/audio.done
	{ \
		$(SHELL) scripts/frames.sh "$(@D)" 2>&1 | sed -u "s/^/[frames $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/pre_srt_summary.done: $(SRC_DIR)/%/frames.done
	{ \
		$(SHELL) scripts/pre_srt_summary.sh "$(@D)" 2>&1 | sed -u "s/^/[pre_srt_summary $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		wait $$pid; \
	}

$(SRC_DIR)/%/final.done: $(SRC_DIR)/%/pre_srt_summary.done
	{ \
		HASH="$(notdir $(@D))"; \
		BASE_DIR="$(@D)/frames"; \
		TRANSCRIPT="$(SUMMARY_DIR)/pre_$${HASH}.md"; \
		OUTPUT_DIR="$(SUMMARY_DIR)"; \
		\
		PORT_BASE=15687; \
		PORT=$$PORT_BASE; \
		while netstat -an | grep -q ":$$PORT " 2>/dev/null; do \
			PORT=$$((PORT + 1)); \
			if [ $$PORT -gt $$((PORT_BASE + 100)) ]; then \
				echo "[final $(notdir $(@D))] Error: Cannot find available port in range $$PORT_BASE-$$((PORT_BASE + 100))"; \
				exit 1; \
			fi; \
		done; \
		\
		URL="http://127.0.0.1:$$PORT"; \
		echo "[final $(notdir $(@D))] Starting image selection server on port $$PORT..."; \
		scripts/select_image \
			--base-dir "$$BASE_DIR" \
			--transcript "$$TRANSCRIPT" \
			--output-dir "$$OUTPUT_DIR" \
			--port "$$PORT" \
			2>&1 | sed -u "s/^/[final $(notdir $(@D))] /" & pid=$$!; \
		sleep 2; \
		echo "[final $(notdir $(@D))] Opening browser at $$URL"; \
		open "$$URL" 2>/dev/null || echo "[final $(notdir $(@D))] Please manually open: $$URL"; \
		echo "[final $(notdir $(@D))] Server is running at $$URL"; \
		echo "[final $(notdir $(@D))] After completing your selection and export, press Ctrl+C here to continue."; \
		echo "[final $(notdir $(@D))] Or press 'q' + Enter to quit immediately."; \
		trap 'echo "[final $(notdir $(@D))] Shutting down gracefully..."; kill $$pid 2>/dev/null; touch "$(@)"; exit 0' INT TERM; \
		wait $$pid; \
		kill $$input_pid 2>/dev/null; \
	}

all: download audio srt frames pre_srt_summary final

# -----------------------------------------------------------------------------
# House-keeping ----------------------------------------------------------------
clean:
	rm -rf $(TMP_DIR) $(SRC_DIR) $(SUMMARY_DIR)

.PHONY: clean
