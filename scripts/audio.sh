#!/usr/bin/env bash
# audio.sh - Extract 16kHz mono MP3 from raw.mp4 (blocking)
# Arguments:
#   $1: <hash>/ directory that contains raw.mp4
# Produces: audio.mp3 and audio.done

source "$(dirname "$0")/common.sh"

DIR="$1"
RAW="$DIR/raw.mp4"
AUDIO="$DIR/audio.mp3"
[ -f "$RAW" ] || { error "raw.mp4 not found in $DIR"; exit 1; }

info "Extracting audio from $RAW"

if "$FFMPEG" -y -i "$RAW" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$AUDIO"; then
  touch "$DIR/audio.done"
  info "Audio extracted: $AUDIO"
else
  error "ffmpeg failed for $RAW"; exit 1
fi
