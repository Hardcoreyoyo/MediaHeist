#!/usr/bin/env bash
# frames.sh - Dynamic segmentation, keyframe extraction, duplicate removal
# Usage:  frames.sh <video_dir> [--ext jpg] [--scene 0.06] [--min-gap 5] [--hash-threshold 4]
# Requires: ffmpeg, ffprobe, GNU parallel (or xargs -P), ImageMagick (phash metric)

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

###############################################################################
# Argument parsing                                                             #
###############################################################################
if [[ $# -lt 1 ]]; then
  error "Usage: $0 <video_dir> [options]"; exit 1
fi

DIR="$1"; shift
RAW="$DIR/raw.mp4"
EXT="jpg"
SCENE="0.07"
MIN_GAP="5"
HASH_THRESHOLD="5999"
BLUR_THRESHOLD_INT="10"  # Threshold after scaling blur_abs*1e6; lower => stricter

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ext)            EXT="$2"; shift 2;;
    --scene)          SCENE="$2"; shift 2;;
    --min-gap)        MIN_GAP="$2"; shift 2;;
    --hash-threshold) HASH_THRESHOLD="$2"; shift 2;;
    --blur-threshold-int) BLUR_THRESHOLD_INT="$2"; shift 2;;
    *) error "Unknown option: $1"; exit 1;;
  esac
done

FRAME_DIR="$DIR/frames"
SEG_DIR="$DIR/segments"
mkdir -p "$FRAME_DIR" "$SEG_DIR"

###############################################################################
# 1. Dynamic segmentation                                                     #
###############################################################################
if [[ ! -f "$RAW" ]]; then
  error "Missing input $RAW"; exit 1
fi

if [[ -z "$(ls -A "$SEG_DIR" 2>/dev/null)" ]]; then
  DURATION=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$RAW")
  DURATION=${DURATION%.*} # truncate to int seconds
  if (( DURATION <= 600 )); then N=2
  elif (( DURATION <= 1800 )); then N=3
  elif (( DURATION <= 3600 )); then N=6
  else N=$(((DURATION + 599)/600))
  fi
  SEG_LEN=$(((DURATION + N - 1)/N))
  info "Splitting into $N segments, ~${SEG_LEN}s each"

  "$FFMPEG" -hide_banner -loglevel error -y -i "$RAW" \
    -c copy -map 0 -segment_time "$SEG_LEN" -f segment "$SEG_DIR/seg%04d.mp4"
else
  info "Segments already exist, skipping split"
fi

###############################################################################
# 2. Keyframe extraction                                                      #
###############################################################################
export FFMPEG EXT SCENE MIN_GAP FRAME_DIR MAX_JOBS
extract_frames() {
  local seg="$1"
  local bn
  bn=$(basename "$seg" .mp4)
  local codec_args
  if [[ "$EXT" == "jpg" ]]; then
    codec_args="-q:v 4 -c:v mjpeg -pix_fmt yuvj420p -strict unofficial"
  else
    codec_args="-compression_level 3 -c:v png"
  fi
  "$FFMPEG" -hide_banner -loglevel error -i "$seg" \
    -vf "select='gt(scene,${SCENE})',fps=fps=1/${MIN_GAP},scale=480:270" \
    -vsync vfr -frame_pts 1 $codec_args -threads 2 \
    "$FRAME_DIR/tmp_${bn}_%06d.${EXT}" || return 1
}

# Export the function for GNU Parallel
export -f extract_frames

if [[ -z "$(ls -A "$FRAME_DIR" 2>/dev/null)" ]]; then
  info "Extracting frames in parallel"
  find "$SEG_DIR" -name 'seg*.mp4' | parallel -j "$MAX_JOBS" --halt soon,fail=1 extract_frames {}
else
  info "Frame directory already populated, skipping extraction"
fi

###############################################################################
# 3. Rename frames to original timestamp                                      #
###############################################################################
# 邏輯嚴重錯誤，造成處理好的的檔案消失

# rename_frames() {
#   local f="$1"
#   # pts in microseconds stored in name after last _ before ext
#   local pts=${f##*_}
#   pts=${pts%.*}
#   # Convert to base10 to avoid leading-zero octal issue
#   local pts_dec=$((10#$pts))
#   # ffmpeg frame_pts 1 gives pts starting at 0 based on segment; need offset
#   local seg_bn idx offset total_ms
#   seg_bn=$(basename "$f")
#   seg_bn=${seg_bn#tmp_}
#   seg_bn=${seg_bn%%_*}
#   idx=${seg_bn#seg}
#   idx=$((10#$idx))
#   offset=$((idx * SEG_LEN * 1000)) # ms
#   total_ms=$(((pts_dec/90) + offset)) # 90kHz clock
#   hh=$((total_ms/3600000))
#   mm=$(((total_ms%3600000)/60000))
#   ss=$(((total_ms%60000)/1000))
#   ms=$(((total_ms%1000)))
#   printf -v stamp '%02d%02d%02d%03d' "$hh" "$mm" "$ss" "$ms"
#   mv "$f" "$FRAME_DIR/${stamp}.${EXT}"
# }

# info "Renaming frames to timestamp filenames"
# find "$FRAME_DIR" -name 'tmp_*' | while read -r f; do rename_frames "$f"; done

###############################################################################
# 4. Deduplicate frames (ImageMagick phash)                                   #
###############################################################################
if ! command -v magick >/dev/null 2>&1; then
  error "ImageMagick not found. Install via: brew install imagemagick"; exit 1
fi

DEDUP_LOG="$DIR/logs/dedup.log"
mkdir -p "$(dirname "$DEDUP_LOG")"
: > "$DEDUP_LOG"

info "Deduplicating frames with threshold $HASH_THRESHOLD"
last_keep=""

不在 ffmpeg 與 ImageMagick 處理過濾模糊圖片，效果不理想。
# for img in $(find "$FRAME_DIR" -type f -name "*.${EXT}" | sort); do

#   # Blur detection using Laplacian mean; low values indicate blur
#   # 使用 Laplacian 標準差作為銳利度指標，避免正負相抵
#   blur=$(magick "$img" -colorspace gray -morphology Convolve Laplacian -format "%[fx:standard_deviation]" info:)
#   # 取絕對值後放大 1e6 並轉成整數，便於比較
#   blur_abs=$(awk -v b="$blur" 'BEGIN{if(b<0) b=-b; printf "%.10f", b}')
#   blur_int=$(awk -v b="$blur_abs" 'BEGIN{printf "%d", b*1000000 + 0.5}')
#   is_blur=$(( blur_int < BLUR_THRESHOLD_INT ? 1 : 0 ))

#   info "img: $img - blur_int: $blur_int - is_blur: $is_blur"

#   # if [[ "$is_blur" -eq 1 ]]; then
#   #   echo "DELETE $(basename "$img") (blur=$blur)" >> "$DEDUP_LOG"
#   #   rm -f "$img"
#   #   continue
#   # fi

# done

for img in $(find "$FRAME_DIR" -type f -name "*.${EXT}" | sort); do
  if [[ -z "$last_keep" ]]; then
    last_keep="$img"
    continue
  fi

  # Use awk to grab first token from RMSE; wrap in subshell and tolerate empty input to avoid pipefail
  dist=$( { magick compare -metric RMSE "$last_keep" "$img" null: 2>&1 | awk '{print $1}'; } || true )
  dist=${dist%.*}
  info "last_keep $last_keep  -vs- img $img - dist%: $dist"

  if [[ -n "$dist" && "$dist" =~ ^[0-9]+$ && $dist -le $HASH_THRESHOLD ]]; then
    echo "DELETE $(basename "$img") (dist=$dist)" >> "$DEDUP_LOG"
    rm -f "$img"
  else
    last_keep="$img"
  fi
done

info "Deduplication finished; log: $DEDUP_LOG"

touch "$DIR/frames.done"
info "Frames pipeline completed for $DIR"




