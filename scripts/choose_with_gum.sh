#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "用法: $0 <shots_dir> <notes_file>" >&2
  exit 1
fi

shots_dir="$1"
notes_file="$2"

# 收集可用圖片（自訂附檔名即可）
mapfile -t files < <(find "$shots_dir" -type f \( -iname '*.jpg' -o -iname '*.png' \) | sort)
[[ ${#files[@]} -eq 0 ]] && { echo "找不到圖片"; exit 1; }

while true; do
  # gum choose 一次只選一個；選空代表離開
  file=$(gum choose --cursor.foreground="#FFAF00" --header "選擇一張圖片 (Esc 焦退出)" \
        --height 20 --item.foreground="#00D7FF" "${files[@]}") || break
  [[ -z "$file" ]] && break

  clear
  imgcat "$file"            # 全幅預覽
  echo -e "\n附註文字 (Enter 空行即跳過並採用檔名作 alt)："
  read -r caption

  # 轉相對路徑較乾淨
  relpath=$(realpath --relative-to="$(dirname "$notes_file")" "$file")
  alt=${caption:-$(basename "$file")}

  echo "![]($relpath \"$alt\")" >> "$notes_file"
  echo -e "已加入 $notes_file\n按任意鍵繼續，或 Ctrl-C 結束"; read -n1 -s
done