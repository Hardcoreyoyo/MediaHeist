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
SCENE="0.04"
MIN_GAP="5"
# HASH_THRESHOLD="5999"
HASH_THRESHOLD="999"
# determine stream time_base denominator (e.g., 90000)
TIME_BASE_DEN=$(ffprobe -v error -select_streams v:0 -show_entries stream=time_base -of csv=p=0 "$RAW" | awk -F'/' '{print $2}')
if [[ -z "$TIME_BASE_DEN" ]]; then TIME_BASE_DEN=90000; fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ext)            EXT="$2"; shift 2;;
    --scene)          SCENE="$2"; shift 2;;
    --min-gap)        MIN_GAP="$2"; shift 2;;
    --hash-threshold) HASH_THRESHOLD="$2"; shift 2;;
    *) error "Unknown option: $1"; exit 1;;
  esac
done

FRAME_DIR="$DIR/frames"
SEG_DIR="$DIR/segments"
mkdir -p "$FRAME_DIR" "$SEG_DIR"

###############################################################################
# 1. Dynamic segmentation                                                     #
###############################################################################
# if [[ ! -f "$RAW" ]]; then
#   error "Missing input $RAW"; exit 1
# fi

# if [[ -z "$(ls -A "$SEG_DIR" 2>/dev/null)" ]]; then
#   DURATION=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$RAW")
#   DURATION=${DURATION%.*} # truncate to int seconds
#   if (( DURATION <= 600 )); then N=2
#   elif (( DURATION <= 1800 )); then N=3
#   elif (( DURATION <= 3600 )); then N=6
#   else N=$(((DURATION + 599)/600))
#   fi
#   SEG_LEN=$(((DURATION + N - 1)/N))
#   info "Splitting into $N segments, ~${SEG_LEN}s each"

#   "$FFMPEG" -hide_banner -loglevel error -y -i "$RAW" \
#     -c copy -map 0 -segment_time "$SEG_LEN" -reset_timestamps 0 -f segment "$SEG_DIR/seg%04d.mp4"
# else
#   info "Segments already exist, skipping split"
# fi


###############################################################################
# 2. Keyframe extraction                                                      #
###############################################################################
export FFMPEG EXT SCENE MIN_GAP FRAME_DIR MAX_JOBS SEG_LEN

# 智能動態檢測函數
detect_video_dynamics() {
  local input="$1"
  local FF="$FFMPEG"
  
  info "=== 使用混合策略分析影片動態程度 ==="
  
  # 取得影片總長度 (秒)
  local duration=$(ffprobe -v error -select_streams v:0 -show_entries format=duration -of csv="p=0" "$input")
  duration=${duration%.*}
  [[ -z "$duration" ]] && duration=0
  info "Video duration: ${duration}s"
  
  # 依片長決定抽樣段數與每段秒數
  local sample_count sample_len
  if   (( duration <= 60 ));        then sample_count=1; sample_len=20
  elif (( duration <= 300 ));       then sample_count=3; sample_len=10
  elif (( duration <= 1200 ));      then sample_count=5; sample_len=8
  else                                   sample_count=7; sample_len=10
  fi
  info "Sample ${sample_count} segments, each ${sample_len}s"
  
  # 計算抽樣起始時間點 (均分位置)
  local -a offsets=()
  if (( sample_count == 1 )); then
    offsets=(0)
  else
    local step=$(( duration / (sample_count + 1) ))
    for ((i=1;i<=sample_count;i++)); do
      offsets+=( $(( i * step )) )
    done
  fi
  
  # 逐段統計 scene > 0.01 的畫格數量
  local total_scene_frames=0
  for off in "${offsets[@]}"; do
    info " -> 抽樣 offset=${off}s"
    local frames=$("$FF" -ss "$off" -i "$input" -t "$sample_len" \
                   -vf "select='gt(scene,0.01)',showinfo" \
                   -f null - 2>&1 | grep -c pts_time || echo 0)
    total_scene_frames=$(( total_scene_frames + frames ))
  done
  
  # 平均每秒場景變化率
  local total_seconds=$(( sample_count * sample_len ))
  local quick_rate=$(awk "BEGIN{printf \"%.3f\", $total_scene_frames/$total_seconds}")
  info "抽樣共偵測到 $total_scene_frames 個場景變化，平均 $quick_rate /sec"
  
  # 回傳動態級別參數
  if awk "BEGIN{exit !($quick_rate > 3.0)}"; then
    echo "high 0.10 5"  # 高動態：scene_threshold=0.10, min_gap=5
  elif awk "BEGIN{exit !($quick_rate > 1.0)}"; then
    echo "medium 0.01 2"  # 中動態：scene_threshold=0.01, min_gap=2
  else
    if (( duration <= 1800 )); then
      echo "low 0.004 1"   # 低動態：scene_threshold=0.004, min_gap=1
    else
      echo "low 0.008 3"   # 低動態：scene_threshold=0.008, min_gap=3
    fi
  fi
}

extract_frames() {
  # 智能檢測影片動態程度並調整參數
  local dynamics_result=$(detect_video_dynamics "$RAW")
  read -r dynamic_level scene_thr min_gap <<< "$dynamics_result"
  
  info "檢測為 ${dynamic_level} 動態影片 (scene_threshold=${scene_thr}, min_gap=${min_gap})"
  
  # 設定編碼參數
  local codec_args
  if [[ "$EXT" == "jpg" ]]; then
    codec_args="-q:v 2 -c:v mjpeg -pix_fmt yuvj420p -strict unofficial"
  else
    codec_args="-compression_level 3 -c:v png"
  fi
  
  # 使用智能參數和改進的過濾表達式
  local expr="isnan(prev_selected_t)+gt(scene\\,${scene_thr})*gte(t-prev_selected_t\\,${min_gap})"
  
  info "使用過濾表達式: select='${expr}'"
  
  info "==================================== Extracting catch frames... ========================================="

  # 提取關鍵影格 (使用智能參數 + mpdecimate 去重)
  "$FFMPEG" -hide_banner -loglevel error -copyts -i "$RAW" \
    -vf "select='${expr}',mpdecimate,scale=1280:720" \
    -vsync 0 -frame_pts 1 $codec_args -threads 2 \
    "$FRAME_DIR/temp_%012d.${EXT}" || return 1
  
  FRAME_EXTRACT_RESULT=$(find "$FRAME_DIR" -type f -name "*.${EXT}" | sort)
  info "frame extract result:"
  info "$FRAME_EXTRACT_RESULT"

  # 取得時間戳 (使用相同的過濾表達式)
  info "==================================== Get timestamps using showinfo filter ========================================="
  "$FFMPEG" -hide_banner -loglevel info -copyts -i "$RAW" \
    -vf "select='${expr}',mpdecimate,showinfo" \
    -vsync 0 -f null - 2>&1 | \
    grep 'pts_time:' | \
    sed 's/.*pts_time:\([0-9.]*\).*/\1/' > "$FRAME_DIR/timestamps.txt"
  
  info "Check if timestamps were extracted"
  if [[ ! -s "$FRAME_DIR/timestamps.txt" ]]; then
    info "Warning: No timestamps extracted, keeping original filenames"
    # Rename temp files to final format without timestamps
    for temp_file in "$FRAME_DIR"/temp_*.${EXT}; do
      if [[ -f "$temp_file" ]]; then
        num=$(basename "$temp_file" | sed "s/temp_0*\([0-9]*\)\.${EXT}/\1/")
        mv "$temp_file" "$FRAME_DIR/frame_${num}.${EXT}"
      fi
    done
    return 0
  fi
  
  info "Rename files using the timestamps"

  # Rename temp files to match timestamps one-to-one (avoid bash 4-only mapfile)
  if ls "$FRAME_DIR"/temp_*.${EXT} >/dev/null 2>&1; then
    paste <(ls "$FRAME_DIR"/temp_*.${EXT} | sort) "$FRAME_DIR/timestamps.txt" | \
    while IFS=$'\t' read -r temp_file timestamp; do
      # Safety: stop if either field is empty
      [[ -z "$temp_file" || -z "$timestamp" ]] && break

      # Convert timestamp to HH_MM_SS_mmm format
      h=$(awk "BEGIN {printf \"%02d\", int($timestamp/3600)}")
      m=$(awk "BEGIN {printf \"%02d\", int(($timestamp%3600)/60)}")
      s=$(awk "BEGIN {printf \"%02d\", int($timestamp%60)}")
      ms=$(awk "BEGIN {printf \"%03d\", int(($timestamp - int($timestamp)) * 1000)}")

      new_name="frame_${h}_${m}_${s}_${ms}.${EXT}"
      mv -f "$temp_file" "$FRAME_DIR/$new_name"
    done
  else
    info "No temp files found to rename"
  fi

  RENAME_RESULT=$(find "$FRAME_DIR" -type f -name "*.${EXT}" | sort)
  info "rename result:"
  info "$RENAME_RESULT"
  
  # Clean up temporary file
  rm -f "$FRAME_DIR/timestamps.txt"
}

# (Parallel extraction disabled to avoid filename conflicts)

if [[ -z "$(ls -A "$FRAME_DIR" 2>/dev/null)" ]]; then
  info "Extracting keyframes from full video"
  extract_frames
else
  info "Frame directory already populated, skipping extraction"
fi

KEYFRAME_RESULT=$(find "$FRAME_DIR" -type f -name "*.${EXT}" | sort)

info "keyframe result: $KEYFRAME_RESULT"


###############################################################################
# 3. Rename frames to HH_MM_SS_mmm filenames                                  #
###############################################################################
# FFmpeg 以 frame_pts 產生檔名 frame_<ticks>.EXT（ticks 依原始 time_base，如 1/90000）
# 此處將其轉換成 HH_MM_SS_mmm.EXT

# format_timestamp_filename() {
#   local f="$1"
#   local file seg pts pts_ms secs ms hh mm ss new target
#   file=$(basename "$f")
#   pts=${file#frame_}; pts=${pts%.*}   # integer ticks
#   pts_ms=$(( pts * 1000 / TIME_BASE_DEN ))
#   secs=$((pts_ms / 1000))
#   ms=$(printf "%03d" $((pts_ms % 1000)))
#   hh=$(printf "%02d" $((secs / 3600)))
#   mm=$(printf "%02d" $(((secs % 3600) / 60)))
#   ss=$(printf "%02d" $((secs % 60)))
#   new=$(printf "%02d_%02d_%02d_%03d.%s" "$hh" "$mm" "$ss" "$ms" "$EXT")
#   target="$FRAME_DIR/$new"
#   if [[ -e "$target" ]]; then
#     local dup=1
#     while [[ -e "${target%.*}_$dup.${EXT}" ]]; do
#       dup=$((dup+1))
#     done
#     target="${target%.*}_$dup.${EXT}"
#   fi
#   mv -n "$f" "$target"
# }
# # not exporting since no parallel


# info "Renaming frames to HH_MM_SS_mmm format"
# shopt -s nullglob
# for f in "$FRAME_DIR"/frame_*.$EXT; do
#   format_timestamp_filename "$f"
# done

# RENAME_RESULT=$(find "$FRAME_DIR" -type f -name "*.${EXT}" | sort)
# info "rename result: \n$RENAME_RESULT"


###############################################################################
# 4. Deduplicate frames (ImageMagick phash)                                   #
###############################################################################
if ! command -v magick >/dev/null 2>&1; then
  error "ImageMagick not found. Install via: brew install imagemagick"; exit 1
fi

# DEDUP_LOG="$DIR/logs/dedup.log"
# mkdir -p "$(dirname "$DEDUP_LOG")"
# : > "$DEDUP_LOG"

info "Deduplicating frames with threshold $HASH_THRESHOLD"
last_keep=""

# 不在 ffmpeg 與 ImageMagick 處理過濾模糊圖片，效果不理想。
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
    # echo "DELETE $(basename "$img") (dist=$dist)" >> "$DEDUP_LOG"
    info "DELETE $(basename "$img") (dist=$dist)"
    rm -f "$img"
  else
    last_keep="$img"
  fi
done

# info "Deduplication finished; log: $DEDUP_LOG"
info "Deduplication finished"

touch "$DIR/frames.done"
info "Frames pipeline completed for $DIR"




