#!/usr/bin/env bash
# download.sh - Download YouTube video or copy local file
#   $1: Input (YouTube URL, YouTube ID, or local file path)
#   $2: Output directory (hash dir already created by Makefile)
# Produces: raw.mp4 on success, plus .done marker.

source "$(dirname "$0")/common.sh"

INPUT="$1"; OUT_DIR="$2"
[ -z "$INPUT" ] && { error "Input argument missing"; exit 1; }
mkdir -p "$OUT_DIR"

RAW_MP4="$OUT_DIR/raw.mp4"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAPPING_FILE="$ROOT_DIR/.mediaheist_mapping"

# -----------------------------------------------------------------------------
# Function: save_mapping
# Save directory name to original URL mapping
# -----------------------------------------------------------------------------
save_mapping() {
    local input="$1"
    local dir_name="$2"
    local title="$3"
    local type="$4"
    
    # Ensure mapping file exists and create header if needed
    if [[ ! -f "$MAPPING_FILE" ]]; then
        echo "# MediaHeist Directory Mapping File" > "$MAPPING_FILE"
        echo "# Format: directory_name|original_url|title|type" >> "$MAPPING_FILE"
    fi
    
    # Check if mapping already exists to avoid duplicates
    if ! grep -q "^${dir_name}|" "$MAPPING_FILE" 2>/dev/null; then
        echo "${dir_name}|${input}|${title}|${type}" >> "$MAPPING_FILE"
        info "Saved mapping: $dir_name -> $input"
    fi
}

# -----------------------------------------------------------------------------
# Function: detect_input_type
# Determines the type of input and normalizes it for processing
# Returns: "youtube" or "local"
# Sets: NORMALIZED_INPUT (YouTube URL or local file path)
# -----------------------------------------------------------------------------
detect_input_type() {
    local input="$1"
    
    # Check if it's a local file path (absolute path starting with /)
    if [[ "$input" =~ ^/.* ]]; then
        if [[ -f "$input" ]]; then
            NORMALIZED_INPUT="$input"
            return 0  # local file
        else
            error "Local file not found: $input"
            exit 1
        fi
    fi
    
    # Check if it's already a full YouTube URL
    if [[ "$input" =~ ^https?://(www\.)?(youtube\.com|youtu\.be)/ ]]; then
        NORMALIZED_INPUT="$input"
        return 1  # youtube URL
    fi
    
    # Check if it's a YouTube video ID (11 characters, alphanumeric + _ -)
    if [[ "$input" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        NORMALIZED_INPUT="https://www.youtube.com/watch?v=$input"
        return 1  # youtube URL (converted from ID)
    fi
    
    # If none of the above, treat as potential YouTube URL and let yt-dlp handle it
    NORMALIZED_INPUT="$input"
    return 1  # assume youtube
}

# -----------------------------------------------------------------------------
# Function: copy_local_file
# Copy local video file to output directory
# -----------------------------------------------------------------------------
copy_local_file() {
    local src_file="$1"
    local dst_file="$2"
    
    info "Copying local file: $src_file -> $dst_file"
    
    # Use cp with error handling
    if cp "$src_file" "$dst_file"; then
        info "Local file copy succeeded: $src_file"
        
        # Save mapping relationship
        local dir_name="$(basename "$(dirname "$dst_file")")"
        local filename="$(basename "$src_file" | sed 's/\.[^.]*$//')"
        save_mapping "$src_file" "$dir_name" "$filename" "local"
        
        return 0
    else
        error "Failed to copy local file: $src_file"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Function: download_youtube
# Download YouTube video using yt-dlp with retry logic
# -----------------------------------------------------------------------------
download_youtube() {
    local url="$1"
    local output_file="$2"
    
    info "Downloading YouTube video: $url -> $output_file"
    
    # Extract title and YouTube ID before downloading
    local title=$($YTDLP --get-title "$url" 2>/dev/null | head -1 || echo "Unknown_Title")
    local youtube_id=$(echo "$url" | sed -E 's/.*[?&]v=([a-zA-Z0-9_-]{11}).*/\1/; s/.*youtu\.be\/([a-zA-Z0-9_-]{11}).*/\1/; s/^([a-zA-Z0-9_-]{11})$/\1/')
    
    # Retry up to 3 times with exponential backoff
    for attempt in {1..3}; do
        if "$YTDLP" -f "bestvideo+bestaudio/best" --merge-output-format mp4 -o "$output_file" "$url"; then
            info "YouTube download succeeded: $url"
            
            # Save mapping relationship
            local dir_name="$(basename "$(dirname "$output_file")")"
            save_mapping "$url" "$dir_name" "$title" "youtube"
            
            return 0
        fi
        warn "Attempt $attempt failed – retrying in $((attempt*attempt))s"
        sleep $((attempt*attempt))
    done
    
    error "Failed to download YouTube video after 3 attempts: $url"
    return 1
}

# -----------------------------------------------------------------------------
# Main processing logic
# -----------------------------------------------------------------------------
info "Processing input: $INPUT"

# Detect input type and normalize
if detect_input_type "$INPUT"; then
    # Local file
    if copy_local_file "$NORMALIZED_INPUT" "$RAW_MP4"; then
        touch "$OUT_DIR/download.done"
        info "Processing completed successfully"
        exit 0
    else
        exit 1
    fi
else
    # YouTube URL
    if download_youtube "$NORMALIZED_INPUT" "$RAW_MP4"; then
        touch "$OUT_DIR/download.done"
        info "Processing completed successfully"
        exit 0
    else
        exit 1
    fi
fi
