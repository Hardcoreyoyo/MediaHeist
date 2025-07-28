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
# Helper functions for new directory naming system
# Mapping file to store directory name -> original URL relationships
MAPPING_FILE := .mediaheist_mapping

# Function: extract YouTube ID from URL or return as-is if already an ID
extract_youtube_id = $(shell \
  echo "[makefile main] 準備提取 YouTube ID: $1" >&2; \
  result=$$(echo "$1" | sed -E 's/.*[?&]v=([a-zA-Z0-9_-]{11}).*/\1/; s/.*youtu\.be\/([a-zA-Z0-9_-]{11}).*/\1/; s/^([a-zA-Z0-9_-]{11})$$/\1/'); \
  echo "[makefile main] 提取到的 YouTube ID: $$result" >&2; \
  echo "$$result")

# Function: generate 6-character UUID prefix for local files
generate_uuid_prefix = $(shell \
  echo "[makefile main] 準備生成 6 位 UUID 前綴" >&2; \
  result=$$(head -c 6 /dev/urandom | base64 | tr -d '+/=' | head -c 6 2>/dev/null || date +%s | tail -c 7); \
  echo "[makefile main] 生成的 UUID 前綴: $$result" >&2; \
  echo "$$result")

# Function: clean title/filename (replace special chars with underscore, keep ASCII and CJK)
clean_name = $(shell \
  echo "[makefile main] 準備清理名稱: $1" >&2; \
  result=$$(echo "$1" | sed 's/[[:space:]]\+/_/g' | perl -CSD -pe 's/[^A-Za-z0-9_\-\x{4E00}-\x{9FFF}]/_/g; s/_+/_/g' 2>/dev/null || echo "$1" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]/_/g; s/_\+/_/g'); \
  echo "[makefile main] 清理後的名稱: $$result" >&2; \
  echo "$$result")
  
# Main function: generate directory name based on input type
generate_dir_name = $(shell \
  input="$1"; \
  echo "[makefile main] 準備生成目錄名稱，輸入: $$input" >&2; \
  ytdlp_cmd="$${YTDLP:-yt-dlp}"; \
  if echo "$$input" | grep -qE "(youtube\.com|youtu\.be)"; then \
    url="$$input"; \
    echo "[makefile main] 識別為 YouTube URL" >&2; \
  elif echo "$$input" | grep -qE "^[a-zA-Z0-9_-]{11}$$"; then \
    url="https://www.youtube.com/watch?v=$$input"; \
    echo "[makefile main] 識別為 YouTube ID，轉換為 URL" >&2; \
  else \
    url=""; \
    echo "[makefile main] 非 YouTube 輸入" >&2; \
  fi; \
  if [ -n "$$url" ]; then \
    echo "[makefile main] 開始處理 YouTube 內容: $$url" >&2; \
    title=$$($$ytdlp_cmd --get-title "$$url" 2>/dev/null | head -1 || echo "Unknown_Title"); \
    echo "[makefile main] 取得標題: $$title" >&2; \
    youtube_id=$$(echo "$$input" | sed -E 's/.*[?&]v=([a-zA-Z0-9_-]{11}).*/\1/; s/.*youtu\.be\/([a-zA-Z0-9_-]{11}).*/\1/; s/^([a-zA-Z0-9_-]{11})$$/\1/'); \
    echo "[makefile main] 提取 YouTube ID: $$youtube_id" >&2; \
    clean_title=$$(echo "$$title" | sed 's/[[:space:]]\+/_/g' | perl -CSD -pe 's/[^A-Za-z0-9_\-\x{4E00}-\x{9FFF}]//g' 2>/dev/null || echo "$$title" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
    echo "[makefile main] 清理後標題: $$clean_title" >&2; \
    result="$${clean_title}_$${youtube_id}"; \
    echo "[makefile main] 生成的 YouTube 目錄名稱: $$result" >&2; \
    echo "$$result"; \
  elif echo "$$input" | grep -q "^/"; then \
    echo "[makefile main] 開始處理本地檔案: $$input" >&2; \
    filename=$$(basename "$$input" | sed 's/\.[^.]*$$//'); \
    echo "[makefile main] 提取檔案名: $$filename" >&2; \
    clean_filename=$$(echo "$$filename" | sed 's/[[:space:]]\+/_/g' | perl -CSD -pe 's/[^A-Za-z0-9_\-\x{4E00}-\x{9FFF}]//g' 2>/dev/null || echo "$$filename" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
    echo "[makefile main] 清理後檔案名: $$clean_filename" >&2; \
    uuid_prefix=$$(head -c 6 /dev/urandom | base64 | tr -d '+/=' | head -c 6 2>/dev/null || date +%s | tail -c 7); \
    echo "[makefile main] 生成 UUID 前綴: $$uuid_prefix" >&2; \
    result="$${clean_filename}_$${uuid_prefix}"; \
    echo "[makefile main] 生成的本地檔案目錄名稱: $$result" >&2; \
    echo "$$result"; \
  else \
    echo "[makefile main] 處理其他類型輸入" >&2; \
    result=$$(echo "$1" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
    echo "[makefile main] 生成的一般目錄名稱: $$result" >&2; \
    echo "$$result"; \
  fi)



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

.PHONY: download
download: create-url-mapping
	@for mapping in $$(cat $(SRC_DIR)/.url_mapping | grep -v '^#'); do \
	  dir_name=$${mapping%%|*}; \
	  if [ -n "$$dir_name" ]; then \
	    $(MAKE) $(SRC_DIR)/$$dir_name/download.done; \
	  fi; \
	done

# Create URL mapping file to avoid shell expansion issues
.PHONY: create-url-mapping
create-url-mapping:
	@mkdir -p $(SRC_DIR)
	@echo "# URL to directory mapping" > $(SRC_DIR)/.url_mapping
	@for url in $(URLS); do \
	  echo "[create-url-mapping] Processing URL: $$url" >&2; \
	  if echo "$$url" | grep -E '(youtube\.com|youtu\.be)' >/dev/null 2>&1; then \
	    echo "[create-url-mapping] Detected as YouTube URL" >&2; \
	    ytdlp_cmd="$${YTDLP:-yt-dlp}"; \
	    title=$$($$ytdlp_cmd --get-title "$$url" 2>/dev/null | head -1 || echo "Unknown_Title"); \
	    echo "[create-url-mapping] Got title: $$title" >&2; \
	    youtube_id=$$(echo "$$url" | sed -E 's/.*[?&]v=([a-zA-Z0-9_-]{11}).*/\1/; s/.*youtu\.be\/([a-zA-Z0-9_-]{11}).*/\1/; s/^([a-zA-Z0-9_-]{11})$$/\1/'); \
	    echo "[create-url-mapping] Extracted YouTube ID: $$youtube_id" >&2; \
	    clean_title=$$(echo "$$title" | sed 's/[[:space:]]\+/_/g' | perl -CSD -pe 's/[^A-Za-z0-9_\-\x{4E00}-\x{9FFF}]//g' 2>/dev/null || echo "$$title" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
	    echo "[create-url-mapping] Cleaned title: $$clean_title" >&2; \
	    dir_name="$${clean_title}_$${youtube_id}"; \
	  elif echo "$$url" | grep -E '^[a-zA-Z0-9_-]{11}$$' >/dev/null 2>&1; then \
	    echo "[create-url-mapping] Detected as YouTube ID" >&2; \
	    full_url="https://www.youtube.com/watch?v=$$url"; \
	    echo "[create-url-mapping] Converted to full URL: $$full_url" >&2; \
	    ytdlp_cmd="$${YTDLP:-yt-dlp}"; \
	    title=$$($$ytdlp_cmd --get-title "$$full_url" 2>/dev/null | head -1 || echo "Unknown_Title"); \
	    echo "[create-url-mapping] Got title: $$title" >&2; \
	    clean_title=$$(echo "$$title" | sed 's/[[:space:]]\+/_/g' | perl -CSD -pe 's/[^A-Za-z0-9_\-\x{4E00}-\x{9FFF}]//g' 2>/dev/null || echo "$$title" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
	    echo "[create-url-mapping] Cleaned title: $$clean_title" >&2; \
	    dir_name="$${clean_title}_$$url"; \
	  elif echo "$$url" | grep '^/' >/dev/null 2>&1; then \
	    echo "[create-url-mapping] Detected as local file" >&2; \
	    filename=$$(basename "$$url" | sed 's/\.[^.]*$$//'); \
	    echo "[create-url-mapping] Extracted filename: $$filename" >&2; \
	    clean_filename=$$(echo "$$filename" | sed 's/[[:space:]]\+/_/g' | perl -CSD -pe 's/[^A-Za-z0-9_\-\x{4E00}-\x{9FFF}]//g' 2>/dev/null || echo "$$filename" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
	    echo "[create-url-mapping] Cleaned filename: $$clean_filename" >&2; \
	    uuid_prefix=$$(head -c 6 /dev/urandom | base64 | tr -d '+/=' | head -c 6 2>/dev/null || date +%s | tail -c 7); \
	    echo "[create-url-mapping] Generated UUID prefix: $$uuid_prefix" >&2; \
	    dir_name="$${clean_filename}_$${uuid_prefix}"; \
	  else \
	    echo "[create-url-mapping] Processing as general input" >&2; \
	    dir_name=$$(echo "$$url" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]//g'); \
	  fi; \
	  echo "[create-url-mapping] Final directory name: $$dir_name" >&2; \
	  echo "$$dir_name|$$url" >> $(SRC_DIR)/.url_mapping; \
	done

$(SRC_DIR)/%/download.done:
	@mkdir -p "$(@D)"
	@# Find the URL that corresponds to this directory using mapping file
	@DIR_NAME="$(notdir $(@D))"; \
	if [ -f "$(SRC_DIR)/.url_mapping" ]; then \
	  U=$$(grep "^$$DIR_NAME|" "$(SRC_DIR)/.url_mapping" | cut -d'|' -f2 | head -1); \
	else \
	  echo "[ERROR] URL mapping file not found"; \
	  exit 1; \
	fi; \
	if [ -z "$$U" ]; then \
	  echo "[ERROR] Cannot find URL for directory: $$DIR_NAME"; \
	  exit 1; \
	fi; \
	echo "[Make] Starting download $$U -> $(@D)"; \
	if $(SHELL) scripts/download.sh "$$U" "$(@D)" 2>&1 | sed -u "s/^/[download $(notdir $(@D))] /"; then \
	  echo "[Make] Download completed successfully: $$U"; \
	else \
	  echo "[Make] Download failed: $$U"; \
	  exit 1; \
	fi

# -----------------------------------------------------------------------------
# Rules for audio, frames, srt, ocr -------------------------------------------
# Each depends on .done of previous stage
# Parallelised via GNU make -j or MAX_JOBS
# -----------------------------------------------------------------------------
.PHONY: audio srt frames pre_srt_summary final all

audio: create-url-mapping
	@for mapping in $$(cat $(SRC_DIR)/.url_mapping | grep -v '^#'); do \
	  dir_name=$${mapping%%|*}; \
	  if [ -n "$$dir_name" ]; then \
	    $(MAKE) $(SRC_DIR)/$$dir_name/audio.done; \
	  fi; \
	done

frames: create-url-mapping
	@for mapping in $$(cat $(SRC_DIR)/.url_mapping | grep -v '^#'); do \
	  dir_name=$${mapping%%|*}; \
	  if [ -n "$$dir_name" ]; then \
	    $(MAKE) $(SRC_DIR)/$$dir_name/frames.done; \
	  fi; \
	done

pre_srt_summary: create-url-mapping
	@for mapping in $$(cat $(SRC_DIR)/.url_mapping | grep -v '^#'); do \
	  dir_name=$${mapping%%|*}; \
	  if [ -n "$$dir_name" ]; then \
	    $(MAKE) $(SRC_DIR)/$$dir_name/pre_srt_summary.done; \
	  fi; \
	done

srt: create-url-mapping
	@for mapping in $$(cat $(SRC_DIR)/.url_mapping | grep -v '^#'); do \
	  dir_name=$${mapping%%|*}; \
	  if [ -n "$$dir_name" ]; then \
	    $(MAKE) $(SRC_DIR)/$$dir_name/srt.done; \
	  fi; \
	done

final: create-url-mapping
	@for mapping in $$(cat $(SRC_DIR)/.url_mapping | grep -v '^#'); do \
	  dir_name=$${mapping%%|*}; \
	  if [ -n "$$dir_name" ]; then \
	    $(MAKE) $(SRC_DIR)/$$dir_name/final.done; \
	  fi; \
	done

$(SRC_DIR)/%/audio.done: $(SRC_DIR)/%/download.done
	{ \
		$(SHELL) scripts/audio.sh "$(@D)" 2>&1 | sed -u "s/^/[audio $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		if wait $$pid; then \
			echo "[audio $(notdir $(@D))] Audio extraction completed successfully"; \
		else \
			echo "[audio $(notdir $(@D))] Audio extraction failed"; \
			exit 1; \
		fi; \
	}

$(SRC_DIR)/%/srt.done: $(SRC_DIR)/%/audio.done
	DIR_NAME="$(notdir $(@D))"; \
	ORIGINAL_URL=""; \
	echo "[srt $$DIR_NAME] Looking for original URL..."; \
	if [ -f "$(MAPPING_FILE)" ]; then \
		echo "[srt $$DIR_NAME] Checking mapping file: $(MAPPING_FILE)"; \
		ORIGINAL_URL=$$(grep "^$$DIR_NAME|" "$(MAPPING_FILE)" | cut -d'|' -f2 | head -1); \
		if [ -n "$$ORIGINAL_URL" ] && [ "$$ORIGINAL_URL" != "" ]; then \
			echo "[srt $$DIR_NAME] Found URL in mapping file: $$ORIGINAL_URL"; \
		else \
			echo "[srt $$DIR_NAME] Directory $$DIR_NAME not found in mapping file or URL is empty"; \
			ORIGINAL_URL=""; \
		fi; \
	else \
		echo "[srt $$DIR_NAME] Mapping file not found: $(MAPPING_FILE)"; \
	fi; \
	if [ -z "$$ORIGINAL_URL" ]; then \
		echo "[srt $$DIR_NAME] No URL found, transcription will use Whisper.cpp only"; \
	fi; \
	echo "[srt $$DIR_NAME] Starting transcription with URL: '$$ORIGINAL_URL'"; \
	{ \
		ORIGINAL_URL="$$ORIGINAL_URL" $(SHELL) scripts/transcribe.sh "$(@D)" 2>&1 | sed -u "s/^/[srt $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		if wait $$pid; then \
			echo "[srt $(notdir $(@D))] Transcription completed successfully"; \
		else \
			echo "[srt $(notdir $(@D))] Transcription failed"; \
			exit 1; \
		fi; \
	}

$(SRC_DIR)/%/frames.done: $(SRC_DIR)/%/download.done
	{ \
		$(SHELL) scripts/frames.sh "$(@D)" 2>&1 | sed -u "s/^/[frames $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		if wait $$pid; then \
			echo "[frames $(notdir $(@D))] Frame extraction completed successfully"; \
		else \
			echo "[frames $(notdir $(@D))] Frame extraction failed"; \
			exit 1; \
		fi; \
	}

$(SRC_DIR)/%/pre_srt_summary.done: $(SRC_DIR)/%/srt.done
	{ \
		$(SHELL) scripts/pre_srt_summary.sh "$(@D)" 2>&1 | sed -u "s/^/[pre_srt_summary $(notdir $(@D))] /" & pid=$$!; \
		trap 'kill $$pid 2>/dev/null' INT TERM; \
		if wait $$pid; then \
			echo "[pre_srt_summary $(notdir $(@D))] Pre-summary completed successfully"; \
		else \
			echo "[pre_srt_summary $(notdir $(@D))] Pre-summary failed"; \
			exit 1; \
		fi; \
	}

$(SRC_DIR)/%/final.done: $(SRC_DIR)/%/pre_srt_summary.done $(SRC_DIR)/%/frames.done
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

all: final

# Abstract target dependencies (must match the actual file target dependencies)
final: pre_srt_summary frames
pre_srt_summary: srt
srt: audio
audio: download
frames: download

# -----------------------------------------------------------------------------
# House-keeping ----------------------------------------------------------------
clean:
	rm -rf $(TMP_DIR) $(SRC_DIR) $(SUMMARY_DIR)

.PHONY: clean
