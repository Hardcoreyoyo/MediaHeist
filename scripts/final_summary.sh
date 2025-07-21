#!/usr/bin/env bash
# final_summary.sh - Aggregate transcript + OCR via Gemini into Markdown summary
#   $1: <hash>/ directory
# Produces: summary/final_<hash>.md

source "$(dirname "$0")/common.sh"

DIR="$1"
SRT="$DIR/transcript.srt"
OCR_TXT="$DIR/frames_ocr.txt"
[ -f "$SRT" ] || { error "transcript.srt missing"; exit 1; }
[ -f "$OCR_TXT" ] || { error "frames_ocr.txt missing"; exit 1; }

PAYLOAD=$(jq -n --arg srt "$(cat "$SRT")" --arg ocr "$(cat "$OCR_TXT")" '{contents:[{role:"user",parts:[{text:$srt+$"\n\n"+$ocr}]}],generationConfig:{responseMimeType:"text/markdown"}}')

RESP=$(curl -s -X POST -H "Content-Type: application/json" \
       "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL_ID}:streamGenerateContent?key=${GEMINI_API_KEY}" \
       -d "$PAYLOAD")

SUMMARY_DIR="$(pwd)/summary"
mkdir -p "$SUMMARY_DIR"
HASH="$(basename "$DIR")"
FINAL_MD="$SUMMARY_DIR/final_${HASH}.md"

echo "$RESP" | jq -r '.candidates[0].content.parts[0].text' > "$FINAL_MD"

touch "$DIR/final.done"
info "Markdown summary saved to $FINAL_MD"
