#!/usr/bin/env bash
# select_image_list.sh - 最簡 MVP：只列出圖片路徑，無預覽、無分割
# 用法：
#   select_image_list.sh screenshots_dir
# 依賴：bash、fzf
set -euo pipefail
ROOT="${1:-}"
[[ -d "$ROOT" ]] || { echo "Need screenshots directory" >&2; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf not found" >&2; exit 1; }

# 找 jpg/png
IMGLIST=$(find "$ROOT" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)
[[ -z "$IMGLIST" ]] && { echo "No images found" >&2; exit 1; }

printf '%s\n' "$IMGLIST" | fzf --height 80% --layout=reverse | {
  read -r sel || { echo "Aborted" >&2; exit 0; }
  rel=$(python3 - <<PY "$PWD" "$sel"
import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY)
  echo "![]($rel)"
}
