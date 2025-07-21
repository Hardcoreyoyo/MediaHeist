#!/usr/bin/env bash
# ocr.sh - Batch OCR once all frames extracted
#   $1: <hash>/ directory (expects frames directory)
# Produces frames_ocr.txt + ocr.done

source "$(dirname "$0")/common.sh"

DIR="$1"; FRAME_DIR="$DIR/frames"
OUT_TXT="$DIR/frames_ocr.txt"
# Model to use; override via environment variable MODEL
MODEL="${MODEL:-google/gemma-3-4b}"
# Prompt prefix; override via environment variable PROMPT_PREFIX for custom instructions
PROMPT_PREFIX="${PROMPT_PREFIX:-詳細完整分析我上傳的圖片，盡全力非常仔細描述圖片上所有細節與文字及圖形或表格。}"
[ -d "$FRAME_DIR" ] || { error "frames/ missing in $DIR"; exit 1; }

# Helper: resolve absolute path (portable across macOS/Linux)
abs_path() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p"
  else
    echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  fi
}

info "OCR for frames in $FRAME_DIR"

> "$OUT_TXT"

# Enable nullglob so patterns expand to nothing if no matches
shopt -s nullglob
for f in "$FRAME_DIR"/*.{jpg,jpeg,png,webp}; do
  [ -e "$f" ] || continue
  
  info "OCR begin - $f"

  # Build data URI and invoke local completion API
  ABS_F=$(abs_path "$f")
  MIME=$(file -b --mime-type "$ABS_F" 2>/dev/null || echo "image/jpeg")
  IMG_B64=$(base64 -i "$ABS_F" | tr -d '\n')
  DATA_URI="data:${MIME};base64,${IMG_B64}"

  info "curl chat/completions ${ABS_F}"
  RESP=$(curl -s http://localhost:8898/v1/chat/completions \
    -H 'Content-Type: application/json' \
    --data-binary @- <<EOF
{
  "model": "${MODEL}",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "${PROMPT_PREFIX}" },
        { "type": "image_url", "image_url": { "url": "${DATA_URI}" } }
      ]
    }
  ]
}
EOF
  ) || true

  CONTENT=$(echo "$RESP" | jq -r '.choices[0].message.content // empty' | tr -d '\n' | sed 's/[[:space:]]\+/ /g')

  echo "# $f" >> "$OUT_TXT"
  echo "$CONTENT" >> "$OUT_TXT"
  echo >> "$OUT_TXT"

  info "OCR end - $f"
done
# Restore globbing defaults
shopt -u nullglob

touch "$DIR/ocr.done"
info "All OCR for $DIR completed"
