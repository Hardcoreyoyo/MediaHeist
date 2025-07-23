#!/usr/bin/env bash
set -euo pipefail

shots_dir="${1:-shots}"            # 預設圖片目錄
notes_file="${2:-notes.md}"        # 預設筆記

tmp_sel="$(mktemp)"
lf -selection-path "$tmp_sel" "$shots_dir"

# 逐行附加 Markdown 連結
while IFS= read -r img; do
  [[ -z "$img" ]] && continue
  echo "![]($img)" >> "$notes_file"
done < "$tmp_sel"

rm -f "$tmp_sel"