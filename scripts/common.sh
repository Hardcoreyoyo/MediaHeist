#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# common.sh - Shared utility functions and environment defaults for MediaHeist
# -----------------------------------------------------------------------------
# This file is sourced by every helper script to provide:
#   * Strict bash settings (fail-fast, pipefail, nounset)
#   * Minimal logging helpers
#   * Filename sanitisation that preserves CJK while stripping emojis/symbols
#   * Default tool locations & parallelism (overridable via environment)
# -----------------------------------------------------------------------------

set -eEuo pipefail

# ----- Logging setup ---------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${LOG_DIR:-$ROOT_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_FILE:-$LOG_DIR/$(date '+%m%d_%H%M%S').log}"
export LOG_FILE

# -----------------------------------------------------------------------------
# Redirect all subsequent stdout and stderr to both console and $LOG_FILE.
# Guard with MH_LOG_REDIRECTED to avoid setting up multiple tee processes when
# common.sh is sourced repeatedly within the same shell.
# -----------------------------------------------------------------------------
if [[ -z "${MH_LOG_REDIRECTED:-}" ]]; then
  export MH_LOG_REDIRECTED=1
  # Use exec + process substitution so that *everything* (including output from
  # external commands) is appended to the log while still streaming to the
  # original stdout/stderr. We deliberately append (>>), allowing multiple
  # scripts/stages to share the same log file.
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

###############################################################################
# Logging helpers                                                              #
###############################################################################
log() {
  local level="$1"; shift
  local msg
  msg=$(printf '[%s] [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*")
  # stderr
  printf '%s\n' "$msg" >&2
  # file
  printf '%s\n' "$msg" >> "$LOG_FILE"
}
info()    { log INFO    "$*"; }
warn()    { log WARN    "$*"; }
error()   { log ERROR   "$*"; }

trap 'error "${BASH_SOURCE[0]}:$LINENO command \`$BASH_COMMAND\` failed with code $?"' ERR

# Optional: dump key environment variables for debugging when DEBUG_ENV=1
if [[ "${DEBUG_ENV:-0}" == "1" ]]; then
  info "Environment dump (selected vars):"
  for var in MAX_JOBS YTDLP FFMPEG WHISPER_BIN WHISPER_MODEL GEMINI_MODEL_ID; do
    printf '  %s=%q\n' "$var" "${!var-}"
  done >&2
fi

###############################################################################
# Parallelism & binary locations                                               #
###############################################################################
# Allow callers / CI to override via environment variables or .env (Makefile)  #
###############################################################################
MAX_JOBS="${MAX_JOBS:-$(sysctl -n hw.ncpu)}"
YTDLP="${YTDLP:-yt-dlp}"
FFMPEG="${FFMPEG:-ffmpeg}"
WHISPER_BIN="${WHISPER_BIN:-whisper.cpp/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin}"
GEMINI_MODEL_ID="${GEMINI_MODEL_ID:-gemini-2.5-pro}"
GEMINI_STREAM="${GEMINI_STREAM:-0}"

###############################################################################
# sanitize() – remove spaces/emoji/special chars, keep ASCII & CJK             #
###############################################################################
# Usage:  echo "$raw_name" | sanitize
###############################################################################
sanitize() {
  # Replace all kinds of whitespace with single underscore,  then delete
  # everything that is *not* A-Z a-z 0-9 dot underscore dash or CJK range.
  sed 's/[[:space:]]\+/_/g' | \
    perl -CSD -pe 's/[^A-Za-z0-9._\-\x{4E00}-\x{9FFF}]//g'
}
