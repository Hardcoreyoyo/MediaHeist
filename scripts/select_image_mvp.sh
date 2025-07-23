#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# select_image_mvp.sh - *Minimal* interactive picker for screenshots
# -----------------------------------------------------------------------------
# 依賴：bash、fzf，以及至少一個 imgcat/timg/viu/chafa
# 用法：
#   select_image_mvp.sh summary.txt screenshots_dir
# 選取圖片後於 stdout 輸出 Markdown 語法，方便快速測試。
# -----------------------------------------------------------------------------
set -euo pipefail

SUMMARY_FILE="${1:-}"
IMG_ROOT="${2:-}"
[[ -f "$SUMMARY_FILE" ]] || { echo "Missing summary file" >&2; exit 1; }
[[ -d "$IMG_ROOT"    ]] || { echo "Missing screenshots dir" >&2; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf not found" >&2; exit 1; }

# --- pick first available preview tool ---------------------------------------
detect_preview() {
  local w=480 h=270
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v imgcat >/dev/null; then
    echo "imgcat --height $h"
  elif command -v timg >/dev/null 2>&1; then
    echo "timg --width $w --height $h"
  elif command -v viu >/dev/null 2>&1; then
    echo "viu -w $w -h $h --quiet"
  elif command -v chafa >/dev/null 2>&1; then
    echo "chafa -s ${w}x${h}"
  else
    echo "echo '(no preview tool)'"  # fallback to plain echo
  fi
}
PREVIEW_CMD=$(detect_preview)

# --- generate list: time | summary | img_path --------------------------------
shopt -s nullglob dotglob  # glob fails to empty if no match
while IFS= read -r line; do
  # Skip empty lines
  [[ -z "$line" ]] && continue
  # Detect delimiter
  if [[ "$line" == *"|"* ]]; then
    range="${line%%|*}"
    summary="${line#*|}"
  else
    range="$line"
    summary=""
  fi
    for img in "$IMG_ROOT/$range"/*.{jpg,jpeg,png,JPG,JPEG,PNG}; do
    [[ -e "$img" ]] || continue
    printf '%s | %s | %s\n' "$range" "$summary" "$img"
  done
done < "$SUMMARY_FILE" | \
  fzf --delimiter '|' --with-nth 1,2 \
      --preview "$PREVIEW_CMD {3}" \
      --preview-window=right:60%:border-left | {
        read -r sel || { echo "Aborted" >&2; exit 0; }
        img=$(echo "$sel" | awk -F'|' '{print $3}' | xargs)
        rel=$(python3 - <<PY "$PWD" "$img"
import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY)
        echo "![]($rel)"
      }
