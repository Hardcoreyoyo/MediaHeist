#!/usr/bin/env bash
# select_image_list.sh - 最簡 MVP：只列出圖片路徑，無預覽、無分割
# 用法：
#   select_image_list.sh screenshots_dir
# 依賴：bash、fzf
set -euo pipefail
ROOT="${1:-}"
[[ -d "$ROOT" ]] || { echo "Need screenshots directory" >&2; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf not found" >&2; exit 1; }

# 顯示名稱最長字數，可透過環境變數 MAXLEN 覆寫，預設 100
MAXLEN=${MAXLEN:-100}

# 找 jpg/png
# 收集圖片檔案並產生顯示欄
IMAGES=$(find "$ROOT" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | sort)
[[ -z "$IMAGES" ]] && { echo "No images found" >&2; exit 1; }

echo "$IMAGES" | awk -v L="$MAXLEN" '
{
  path=$0
  if(length(path) > L) disp="..." substr(path, length(path)-L+1); else disp=path
  printf "%s\t%s\n", disp, path
}' | \
fzf --height 80% --layout=reverse \
          --with-nth 1 --delimiter $'\t' \
          --preview 'printf "\n"' --preview-window=right:60%:border-left | {
  read -r sel || { echo "Aborted" >&2; exit 0; }
  full=$(echo "$sel" | awk -F'\t' '{print $2}')
  rel=$(python3 - <<PY "$PWD" "$full"
import os,sys; print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY)
  echo "![]($rel)"
}
