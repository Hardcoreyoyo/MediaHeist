#!/bin/bash

# Enhanced Interactive File Browser with Image Preview
# Compatible with older bash versions
# Usage: ./file_browser.sh <directory> <markdown_file> [notes_file]

set -e

# Check bash version and dependencies
check_dependencies() {
    local missing=()
    command -v tput >/dev/null 2>&1 || missing+=("tput")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "缺少必要工具："
        for tool in "${missing[@]}"; do
            echo "  $tool"
        done
        exit 1
    fi
    
    # Check bash version for associative arrays
    if [[ ${BASH_VERSION%%.*} -lt 4 ]]; then
        echo "警告: 使用舊版 bash，某些功能可能受限"
        USE_SIMPLE_CACHE=1
    else
        USE_SIMPLE_CACHE=0
    fi
}

# Parameters
DIRECTORY="${1:-.}"
MARKDOWN_FILE="${2:-README.md}"
NOTES_FILE="${3:-notes.txt}"
USE_SIMPLE_CACHE=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m'
BOLD='\033[1m'

# Terminal state
TERM_WIDTH=0
TERM_HEIGHT=0
SPLIT_WIDTH=0
LEFT_WIDTH=0
RIGHT_WIDTH=0
MARKDOWN_HEIGHT=4
HEADER_HEIGHT=3
FOOTER_HEIGHT=2

# File list and cache
FILE_LIST=()
CACHE_DIR="/tmp/file_browser_$$"

# Update terminal dimensions
update_dimensions() {
    TERM_WIDTH=$(tput cols)
    TERM_HEIGHT=$(tput lines)
    SPLIT_WIDTH=$((TERM_WIDTH / 2))
    LEFT_WIDTH=$((SPLIT_WIDTH - 2))
    RIGHT_WIDTH=$((TERM_WIDTH - SPLIT_WIDTH - 1))
}

# Initialize display
init_display() {
    tput smcup  # Save screen
    tput civis  # Hide cursor
    stty -echo  # Disable echo
    update_dimensions
    
    # Create cache directory
    mkdir -p "$CACHE_DIR"
}

# Cleanup function
cleanup() {
    # Clean up cache
    [[ -d "$CACHE_DIR" ]] && rm -rf "$CACHE_DIR"
    
    tput rmcup  # Restore screen
    tput cnorm  # Show cursor
    stty echo   # Enable echo
    echo "程式已退出"
    exit 0
}

trap cleanup EXIT INT TERM

# Cache functions using files instead of associative arrays
get_cache_file() {
    local filename="$1"
    local cache_key=$(echo "$filename" | tr '/' '_' | tr ' ' '_')
    echo "$CACHE_DIR/${cache_key}.info"
}

set_cache() {
    local filename="$1"
    local info="$2"
    local cache_file=$(get_cache_file "$filename")
    echo "$info" > "$cache_file"
}

get_cache() {
    local filename="$1"
    local cache_file=$(get_cache_file "$filename")
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    else
        return 1
    fi
}

# Read markdown content
read_markdown() {
    if [[ -f "$MARKDOWN_FILE" ]]; then
        head -n 3 "$MARKDOWN_FILE" | while IFS= read -r line; do
            echo "${line:0:$((TERM_WIDTH-4))}"
        done
    else
        echo "Markdown 檔案不存在: $MARKDOWN_FILE"
    fi
}

# Build file list
build_file_list() {
    FILE_LIST=()
    local temp_list=()
    
    # Use find to get files and read into array
    while IFS= read -r -d '' file; do
        temp_list+=("$(basename "$file")")
    done < <(find "$DIRECTORY" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.tiff" -o -iname "*.webp" \) -print0 2>/dev/null | sort -z)
    
    FILE_LIST=("${temp_list[@]}")
}

# Get detailed file info
get_file_info() {
    local filename="$1"
    local filepath="$DIRECTORY/$filename"
    
    # Try to get from cache first
    local cached_info
    if cached_info=$(get_cache "$filename" 2>/dev/null); then
        echo "$cached_info"
        return 0
    fi
    
    if [[ -f "$filepath" ]]; then
        local size=$(du -h "$filepath" 2>/dev/null | cut -f1 | tr -d ' ')
        local mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$filepath" 2>/dev/null || date)
        local dimensions=""
        local file_type=""
        
        # Get image dimensions and type
        if command -v sips >/dev/null 2>&1; then
            local sips_output=$(sips -g all "$filepath" 2>/dev/null)
            if [[ -n "$sips_output" ]]; then
                local width=$(echo "$sips_output" | grep "pixelWidth" | awk '{print $2}')
                local height=$(echo "$sips_output" | grep "pixelHeight" | awk '{print $2}')
                local format=$(echo "$sips_output" | grep "format" | awk '{print $2}')
                
                if [[ -n "$width" && -n "$height" ]]; then
                    dimensions="${width} × ${height}"
                fi
                if [[ -n "$format" ]]; then
                    file_type="$format"
                fi
            fi
        fi
        
        # Get color space info
        local color_info=""
        if command -v sips >/dev/null 2>&1; then
            local color_space=$(sips -g colorSpace "$filepath" 2>/dev/null | grep "colorSpace" | awk '{print $2}')
            if [[ -n "$color_space" ]]; then
                color_info="$color_space"
            fi
        fi
        
        local result="SIZE:$size|TIME:$mtime|DIM:$dimensions|TYPE:$file_type|COLOR:$color_info"
        set_cache "$filename" "$result"
        echo "$result"
    else
        local result="ERROR:檔案不存在"
        set_cache "$filename" "$result"
        echo "$result"
    fi
}

# Extract info from cache string
extract_info() {
    local info_string="$1"
    local key="$2"
    echo "$info_string" | grep -o "${key}:[^|]*" | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# Generate detailed preview info
generate_preview_info() {
    local filename="$1"
    local filepath="$DIRECTORY/$filename"
    
    if [[ -f "$filepath" ]]; then
        local file_info=$(get_file_info "$filename")
        
        # Parse info
        local size=$(extract_info "$file_info" "SIZE")
        local mtime=$(extract_info "$file_info" "TIME")
        local dimensions=$(extract_info "$file_info" "DIM")
        local file_type=$(extract_info "$file_info" "TYPE")
        local color_space=$(extract_info "$file_info" "COLOR")
        
        echo -e "${CYAN}檔案名稱:${NC} $filename"
        echo -e "${CYAN}檔案大小:${NC} $size"
        [[ -n "$dimensions" && "$dimensions" != " × " ]] && echo -e "${CYAN}圖片尺寸:${NC} $dimensions pixels"
        [[ -n "$file_type" ]] && echo -e "${CYAN}檔案格式:${NC} $file_type"
        [[ -n "$color_space" ]] && echo -e "${CYAN}色彩空間:${NC} $color_space"
        echo -e "${CYAN}修改時間:${NC} $mtime"
        echo ""
        
        # Add EXIF info if available
        if command -v exiftool >/dev/null 2>&1; then
            echo -e "${YELLOW}EXIF 資訊:${NC}"
            local exif_info=$(exiftool -s -s -s -Make -Model -DateTime -ExposureTime -FNumber -ISO -FocalLength "$filepath" 2>/dev/null)
            if [[ -n "$exif_info" ]]; then
                while IFS= read -r line; do
                    [[ -n "$line" ]] && echo "  $line"
                done <<< "$exif_info"
            else
                echo "  無 EXIF 資料"
            fi
            echo ""
        fi
        
        # File path info
        echo -e "${GRAY}完整路徑:${NC}"
        echo "  $filepath"
        echo ""
        
        # Quick actions
        echo -e "${GREEN}可用操作:${NC}"
        echo "  o - 使用預設程式開啟"
        echo "  f - 在 Finder 中顯示"
        echo "  c - 複製檔案路徑"
        
    else
        echo -e "${RED}檔案不存在: $filepath${NC}"
    fi
}

# Move cursor to position
move_cursor() {
    printf "\033[%d;%dH" $1 $2
}

# Draw static interface
draw_static() {
    clear
    
    # Draw markdown section
    move_cursor 1 1
    echo -e "${WHITE}${BOLD}┌$(printf '─%.0s' $(seq 1 $((TERM_WIDTH-2))))┐${NC}"
    
    move_cursor 2 1
    echo -e "${WHITE}${BOLD}│${NC} ${CYAN}Markdown 內容:${NC}$(printf ' %.0s' $(seq 1 $((TERM_WIDTH-18))))${WHITE}${BOLD}│${NC}"
    
    local row=3
    while IFS= read -r line; do
        move_cursor $row 1
        printf "${WHITE}${BOLD}│${NC} %-$((TERM_WIDTH-4))s ${WHITE}${BOLD}│${NC}\n" "$line"
        ((row++))
    done < <(read_markdown)
    
    while [[ $row -le $MARKDOWN_HEIGHT ]]; do
        move_cursor $row 1
        printf "${WHITE}${BOLD}│${NC}%*s${WHITE}${BOLD}│${NC}\n" $((TERM_WIDTH-2)) ""
        ((row++))
    done
    
    # Draw split border
    move_cursor $((MARKDOWN_HEIGHT + 1)) 1
    echo -e "${WHITE}${BOLD}├$(printf '─%.0s' $(seq 1 $((SPLIT_WIDTH-2))))┬$(printf '─%.0s' $(seq 1 $((RIGHT_WIDTH))))┤${NC}"
    
    # Column headers
    local header_row=$((MARKDOWN_HEIGHT + 2))
    move_cursor $header_row 1
    printf "${WHITE}${BOLD}│${NC} ${YELLOW}檔案列表 (${#FILE_LIST[@]} 個)${NC}"
    printf "%*s${WHITE}${BOLD}│${NC}" $((LEFT_WIDTH - 15 - ${#FILE_LIST[@]})) ""
    printf " ${YELLOW}檔案資訊${NC}%*s${WHITE}${BOLD}│${NC}\n" $((RIGHT_WIDTH - 8)) ""
    
    move_cursor $((header_row + 1)) 1
    echo -e "${WHITE}${BOLD}├$(printf '─%.0s' $(seq 1 $((SPLIT_WIDTH-2))))┼$(printf '─%.0s' $(seq 1 $((RIGHT_WIDTH))))┤${NC}"
    
    # Bottom border
    move_cursor $((TERM_HEIGHT - 1)) 1
    echo -e "${WHITE}${BOLD}└$(printf '─%.0s' $(seq 1 $((SPLIT_WIDTH-2))))┴$(printf '─%.0s' $(seq 1 $((RIGHT_WIDTH))))┘${NC}"
    
    # Instructions
    move_cursor $TERM_HEIGHT 1
    echo -e "${YELLOW}↑/↓:選擇 | Enter:加入筆記 | o:開啟 | f:Finder | c:複製路徑 | r:重新整理 | q:退出${NC}"
}

# Update file list
update_file_list() {
    local selected_index=$1
    local list_start_row=$((MARKDOWN_HEIGHT + HEADER_HEIGHT + 1))
    local list_height=$((TERM_HEIGHT - MARKDOWN_HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 1))
    
    local scroll_offset=0
    if [[ $selected_index -ge $list_height ]]; then
        scroll_offset=$((selected_index - list_height + 1))
    fi
    
    for ((i=0; i<list_height; i++)); do
        local file_index=$((i + scroll_offset))
        local row=$((list_start_row + i))
        
        move_cursor $row 1
        printf "${WHITE}${BOLD}│${NC}"
        
        if [[ $file_index -lt ${#FILE_LIST[@]} ]]; then
            local filename="${FILE_LIST[$file_index]}"
            local file_info=$(get_file_info "$filename")
            local size=$(extract_info "$file_info" "SIZE")
            local dimensions=$(extract_info "$file_info" "DIM")
            
            if [[ $file_index -eq $selected_index ]]; then
                printf " ${GREEN}${BOLD}►${NC} ${WHITE}%-$((LEFT_WIDTH-25))s${NC} ${GRAY}%s %s${NC}" \
                    "${filename:0:$((LEFT_WIDTH-25))}" "$size" "${dimensions:0:10}"
            else
                printf "   %-$((LEFT_WIDTH-25))s ${GRAY}%s %s${NC}" \
                    "${filename:0:$((LEFT_WIDTH-25))}" "$size" "${dimensions:0:10}"
            fi
        else
            printf "%*s" $((LEFT_WIDTH)) ""
        fi
        
        printf "${WHITE}${BOLD}│${NC}"
    done
}

# Update preview area
update_preview() {
    local selected_index=$1
    local preview_start_row=$((MARKDOWN_HEIGHT + HEADER_HEIGHT + 1))
    local preview_height=$((TERM_HEIGHT - MARKDOWN_HEIGHT - HEADER_HEIGHT - FOOTER_HEIGHT - 1))
    
    # Clear preview area
    for ((i=0; i<preview_height; i++)); do
        local row=$((preview_start_row + i))
        move_cursor $row $((SPLIT_WIDTH + 1))
        printf " %*s ${WHITE}${BOLD}│${NC}" $((RIGHT_WIDTH)) ""
    done
    
    if [[ $selected_index -ge 0 && $selected_index -lt ${#FILE_LIST[@]} ]]; then
        local filename="${FILE_LIST[$selected_index]}"
        
        local line_num=0
        while IFS= read -r line && [[ $line_num -lt $preview_height ]]; do
            local row=$((preview_start_row + line_num))
            move_cursor $row $((SPLIT_WIDTH + 1))
            printf " %-*s ${WHITE}${BOLD}│${NC}" $((RIGHT_WIDTH)) "$(echo -e "${line:0:$((RIGHT_WIDTH))}")"
            ((line_num++))
        done < <(generate_preview_info "$filename")
    fi
}

# File operations
open_file() {
    local filename="$1"
    local filepath="$DIRECTORY/$filename"
    open "$filepath" 2>/dev/null &
}

show_in_finder() {
    local filename="$1"
    local filepath="$DIRECTORY/$filename"
    open -R "$filepath" 2>/dev/null &
}

copy_path() {
    local filename="$1"
    local filepath="$DIRECTORY/$filename"
    echo -n "$filepath" | pbcopy
    show_message "路徑已複製到剪貼簿"
}

show_message() {
    local message="$1"
    move_cursor $((TERM_HEIGHT - 2)) 1
    echo -e "${GREEN}$message${NC}$(printf ' %.0s' $(seq 1 $((TERM_WIDTH - ${#message} - 10))))"
    sleep 1.5
    
    # Restore border
    move_cursor $((TERM_HEIGHT - 1)) 1
    echo -e "${WHITE}${BOLD}└$(printf '─%.0s' $(seq 1 $((SPLIT_WIDTH-2))))┴$(printf '─%.0s' $(seq 1 $((RIGHT_WIDTH))))┘${NC}"
}

# Add to notes
add_to_notes() {
    local filename="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local entry="[$timestamp] $filename"
    
    echo "$entry" >> "$NOTES_FILE"
    show_message "✓ 已添加到筆記: $filename"
}

# Main program
main() {
    check_dependencies
    
    if [[ ! -d "$DIRECTORY" ]]; then
        echo "錯誤: 目錄不存在: $DIRECTORY"
        exit 1
    fi
    
    init_display
    build_file_list
    
    if [[ ${#FILE_LIST[@]} -eq 0 ]]; then
        echo "在 $DIRECTORY 中沒有找到圖片檔案"
        echo "支援格式: jpg, jpeg, png, gif, bmp, tiff, webp"
        read -p "按 Enter 退出..."
        exit 0
    fi
    
    local selected_index=0
    local last_selected=-1
    
    # Initial draw
    draw_static
    update_file_list $selected_index
    update_preview $selected_index
    last_selected=$selected_index
    
    while true; do
        read -rsn1 key
        
        case "$key" in
            'q'|'Q')
                break
                ;;
            'r'|'R')
                # Clear cache and rebuild
                [[ -d "$CACHE_DIR" ]] && rm -rf "$CACHE_DIR"
                mkdir -p "$CACHE_DIR"
                build_file_list
                draw_static
                update_file_list $selected_index
                update_preview $selected_index
                last_selected=$selected_index
                ;;
            'o'|'O')
                if [[ ${#FILE_LIST[@]} -gt 0 ]]; then
                    open_file "${FILE_LIST[$selected_index]}"
                    show_message "已開啟檔案: ${FILE_LIST[$selected_index]}"
                fi
                ;;
            'f'|'F')
                if [[ ${#FILE_LIST[@]} -gt 0 ]]; then
                    show_in_finder "${FILE_LIST[$selected_index]}"
                    show_message "已在 Finder 中顯示: ${FILE_LIST[$selected_index]}"
                fi
                ;;
            'c'|'C')
                if [[ ${#FILE_LIST[@]} -gt 0 ]]; then
                    copy_path "${FILE_LIST[$selected_index]}"
                fi
                ;;
            $'\033')
                read -rsn2 key
                case "$key" in
                    '[A') # Up
                        if [[ $selected_index -gt 0 ]]; then
                            ((selected_index--))
                        fi
                        ;;
                    '[B') # Down  
                        if [[ $selected_index -lt $((${#FILE_LIST[@]} - 1)) ]]; then
                            ((selected_index++))
                        fi
                        ;;
                esac
                ;;
            $'\n'|$'\r') # Enter
                if [[ ${#FILE_LIST[@]} -gt 0 ]]; then
                    add_to_notes "${FILE_LIST[$selected_index]}"
                fi
                ;;
        esac
        
        # Update only if selection changed
        if [[ $selected_index -ne $last_selected ]]; then
            update_file_list $selected_index
            update_preview $selected_index  
            last_selected=$selected_index
        fi
    done
}

# Show usage
if [[ $# -eq 0 ]]; then
    echo "用法: $0 <目錄> [markdown檔案] [筆記檔案]"
    echo "範例: $0 ./images README.md notes.txt"
    echo ""
    echo "功能說明:"
    echo "  - 相容 macOS 預設 bash 版本"
    echo "  - 右側顯示詳細檔案資訊"
    echo "  - 支援圖片檔案快速操作"
    echo ""
    echo "可選工具:"
    echo "  brew install exiftool  # 顯示 EXIF 資訊"
    exit 1
fi

main