#!/usr/bin/env bash
# download.sh - Download one YouTube video at best quality (video + audio)
#   $1: YouTube URL
#   $2: Output directory (hash dir already created by Makefile)
# Produces: raw.mp4 on success, plus .done marker.

source "$(dirname "$0")/common.sh"

URL="$1"; OUT_DIR="$2"
[ -z "$URL" ] && { error "URL argument missing"; exit 1; }
mkdir -p "$OUT_DIR"

RAW_MP4="$OUT_DIR/raw.mp4"

info "Downloading $URL -> $RAW_MP4"

# Retry up to 3 times with exponential backoff.
for attempt in {1..3}; do
  if "$YTDLP" -f "bestvideo+bestaudio/best" --merge-output-format mp4 -o "$RAW_MP4" "$URL"; then
    touch "$OUT_DIR/download.done"
    info "Download succeeded: $URL"
    exit 0
  fi
  warn "Attempt $attempt failed – retrying in $((attempt*attempt))s"
  sleep $((attempt*attempt))
done
error "Failed to download $URL after 3 attempts"
