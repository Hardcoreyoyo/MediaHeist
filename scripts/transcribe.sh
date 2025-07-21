#!/usr/bin/env bash
# transcribe.sh - Whisper.cpp transcription producing .srt
#   $1: <hash>/ directory (expects audio.mp3)
# Produces: transcript.srt + srt.done

source "$(dirname "$0")/common.sh"

DIR="$1"
AUDIO="$DIR/audio.mp3"
SRT="$DIR/transcript.srt"
[ -f "$AUDIO" ] || { error "audio.mp3 missing in $DIR"; exit 1; }

info "Transcribing $AUDIO via Whisper.cpp"

if "$WHISPER_BIN" -m "$WHISPER_MODEL" "$AUDIO" -l zh -t "$MAX_JOBS" -osrt -of "$SRT"; then
  touch "$DIR/srt.done"
  info "Transcript saved at $SRT"
else
  error "Whisper transcription failed for $AUDIO";
  exit 1
fi
