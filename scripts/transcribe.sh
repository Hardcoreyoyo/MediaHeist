#!/usr/bin/env bash
# transcribe.sh - CC 字幕優先 + Whisper.cpp 降級
# $1: <hash>/ directory (expects audio.mp3 for Whisper fallback)
# Produces: transcript.srt + srt.done

source "$(dirname "$0")/common.sh"

DIR="$1"
AUDIO="$DIR/audio.mp3"
TRANSCRIPT="$DIR/transcript.srt"

# 語言優先順序：繁體中文 > 簡體中文 > 中文 > 英文
# 基於實際測試的 YouTube 語言代碼
# zh-TW: 台灣繁體中文, zh: 中文(通常是簡體), zh-CN: 中國簡體, en: 英文
LANG_PRIORITY=("zh-TW" "zh" "zh-CN" "en")

# 從目錄名稱取得原始 URL (支援映射檔案和環境變數)
get_original_url() {
    local url=""
    
    # 優先使用環境變數，但確保不是空字串
    if [[ -n "${ORIGINAL_URL:-}" && "${ORIGINAL_URL}" != "" ]]; then
        url="$ORIGINAL_URL"
        info "Using URL from environment variable: $url"
    else
        # 從映射檔案讀取
        local dir_name="$(basename "$DIR")"
        local root_dir="$(cd "$(dirname "$0")/.." && pwd)"
        local mapping_file="$root_dir/.mediaheist_mapping"
        
        info "Looking for URL in mapping file: $mapping_file for directory: $dir_name"
        
        if [[ -f "$mapping_file" ]]; then
            url=$(grep "^${dir_name}|" "$mapping_file" | cut -d'|' -f2 | head -1)
            if [[ -n "$url" && "$url" != "" ]]; then
                info "Found URL in mapping file: $url"
            else
                info "Directory $dir_name not found in mapping file or URL is empty"
                url=""
            fi
        else
            info "Mapping file not found: $mapping_file"
        fi
        
        # 如果映射檔案沒有找到，嘗試從 .url 檔案讀取（向後相容）
        if [[ -z "$url" && -f "$DIR/.url" ]]; then
            url=$(cat "$DIR/.url")
            if [[ -n "$url" && "$url" != "" ]]; then
                info "Found URL in .url file: $url"
            else
                url=""
            fi
        fi
    fi
    
    # 確保返回的URL不是空字串
    if [[ -n "$url" && "$url" != "" ]]; then
        echo "$url"
        return 0
    else
        info "No valid URL found for directory: $(basename "$DIR")"
        return 1
    fi
}

# 下載 CC 字幕 (按優先順序)
download_cc_subtitle() {
    local url="$1"
    local temp_dir="$(mktemp -d)"
    
    info "Attempting to download CC subtitles for: $url"
    
    # 嘗試下載所有可用語言的字幕
    local lang_list=$(IFS=,; echo "${LANG_PRIORITY[*]}")
    
    info "Downloading subtitles with command: yt-dlp --write-subs --sub-langs '$lang_list'"
    
    if yt-dlp --write-subs --sub-langs "$lang_list" --no-write-auto-subs \
              --convert-subs srt --output "$temp_dir/subtitle.%(ext)s" \
              --no-download "$url"; then
        
        info "Subtitle download completed, checking available files:"
        find "$temp_dir" -name "*.srt" -exec basename {} \; | while read f; do info "  Found: $f"; done
        
        # 除錯：顯示所有檔案
        info "All files in temp directory:"
        ls -la "$temp_dir/" | while read line; do info "  $line"; done
        
        # 按優先順序查找下載的字幕檔案
        for lang in "${LANG_PRIORITY[@]}"; do
            # 修正檔案名稱匹配邏輯：subtitle.LANG.srt
            subtitle_file=$(find "$temp_dir" -name "subtitle.$lang.srt" | head -1)
            info "Searching for language '$lang': subtitle_file='$subtitle_file'"
            
            if [[ -f "$subtitle_file" && -s "$subtitle_file" ]]; then
                info "Found $lang subtitle: $(basename "$subtitle_file")"
                
                # 驗證和轉換格式
                if process_subtitle "$subtitle_file" "$TRANSCRIPT"; then
                    info "Successfully processed $lang subtitle"
                    rm -rf "$temp_dir"
                    return 0
                else
                    warn "Failed to process $lang subtitle"
                fi
            else
                info "No valid subtitle found for language: $lang"
            fi
        done
        
        # 如果按優先順序找不到，嘗試任意一個 SRT 檔案
        subtitle_file=$(find "$temp_dir" -name "*.srt" | head -1)
        if [[ -f "$subtitle_file" && -s "$subtitle_file" ]]; then
            info "Using available subtitle: $(basename "$subtitle_file")"
            
            if process_subtitle "$subtitle_file" "$TRANSCRIPT"; then
                rm -rf "$temp_dir"
                return 0
            fi
        fi
    else
        warn "yt-dlp subtitle download command failed"
        info "Command was: yt-dlp --write-subs --sub-langs '$lang_list' --no-write-auto-subs --convert-subs srt --output '$temp_dir/subtitle.%(ext)s' --no-download '$url'"
    fi
    
    warn "CC subtitle download failed, cleaning up temp directory: $temp_dir"
    rm -rf "$temp_dir"
    return 1
}

# 處理字幕檔案 (驗證 + 轉換)
process_subtitle() {
    local input="$1"
    local output="$2"
    
    info "Processing subtitle: $input -> $output"
    
    # 檢查檔案是否存在且非空
    if [[ ! -f "$input" || ! -s "$input" ]]; then
        warn "Subtitle file is empty or missing: $input"
        return 1
    fi
    
    # 轉換為 UTF-8 編碼
    if ! iconv -f UTF-8 -t UTF-8 "$input" > /dev/null 2>&1; then
        info "Converting to UTF-8 encoding"
        iconv -f "$(file -b --mime-encoding "$input")" -t UTF-8 "$input" > "${input}.utf8"
        mv "${input}.utf8" "$input"
    fi
    
    # 清理和標準化 SRT 格式
    sed -e 's/<[^>]*>//g' \
        -e 's/\r$//' \
        -e '/^$/N;/^\n$/d' \
        "$input" > "$output"
    
    # 驗證結果
    if [[ -s "$output" ]] && grep -q "\-\->" "$output"; then
        info "Subtitle processing successful"
        return 0
    else
        warn "Subtitle processing failed: output size=$(wc -c < "$output" 2>/dev/null || echo 0)"
        if [[ -f "$output" ]]; then
            warn "First few lines of failed output:"
            head -3 "$output" | while read line; do warn "  $line"; done
        fi
        rm -f "$output"
        return 1
    fi
}

# 判斷是否為 YouTube 來源 (與 download.sh 邏輯一致)
is_youtube_source() {
    local url="$1"
    
    # 檢查是否為本地檔案路徑
    if [[ "$url" =~ ^/.* ]]; then
        return 1  # 本地檔案，不是 YouTube
    fi
    
    # 檢查是否為 YouTube URL
    if [[ "$url" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]; then
        return 0  # YouTube URL
    fi
    
    # 檢查是否為 YouTube 影片 ID (11 字元)
    if [[ "$url" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        return 0  # YouTube ID
    fi
    
    # 其他情況假設為 YouTube (與 download.sh 邏輯一致)
    return 0
}

# 主處理邏輯
info "Starting transcription process for: $DIR"

# 1. 嘗試取得原始URL並下載 CC 字幕 (針對 YouTube 來源)
ORIGINAL_URL=""
if ORIGINAL_URL=$(get_original_url); then
    info "Original URL obtained: $ORIGINAL_URL"
    
    if is_youtube_source "$ORIGINAL_URL"; then
        info "YouTube source detected: $ORIGINAL_URL"
        info "Trying CC subtitles first"
        
        if download_cc_subtitle "$ORIGINAL_URL"; then
            touch "$DIR/srt.done"
            info "CC subtitle processing completed successfully"
            exit 0
        else
            info "No suitable CC subtitle found, falling back to Whisper.cpp"
        fi
    else
        info "Local file detected: $ORIGINAL_URL"
        info "Skipping CC subtitle download, using Whisper.cpp directly"
    fi
else
    info "Original URL unavailable, using Whisper.cpp directly"
    info "This may happen if: 1) No mapping file exists, 2) Directory not in mapping file, 3) URL is empty"
fi

# 2. 降級到 Whisper.cpp 轉錄
[[ -f "$AUDIO" ]] || { error "audio.mp3 missing in $DIR"; exit 1; }

info "Transcribing $AUDIO via Whisper.cpp"

# Whisper.cpp 會自動添加 .srt 副檔名，所以需要移除原有的 .srt
TRANSCRIPT_BASE="${TRANSCRIPT%.srt}"
if "$WHISPER_BIN" -m "$WHISPER_MODEL" "$AUDIO" -l zh -t "$MAX_JOBS" -osrt -of "$TRANSCRIPT_BASE"; then
    touch "$DIR/srt.done"
    info "Whisper transcription completed: $TRANSCRIPT"
else
    error "Whisper transcription failed for $AUDIO"
    exit 1
fi
