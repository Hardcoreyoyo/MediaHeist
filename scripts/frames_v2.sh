#!/usr/bin/env bash

set -eEuo pipefail



# 



extract_hybrid_method() {
    local input="$1"
    local output_dir="$2"
    local codec_args="$3"
    local ext="${4:-jpg}"
    local FF="$FFMPEG"

    echo "=== 使用混合策略分析影片 ==="

    # --------------------------------------------------
    # A. 取得影片總長度 (秒)  → duration
    # --------------------------------------------------
    local duration=$("$FF" -v error -i "$input" \
                     -map 0:v:0 -show_entries stream=duration \
                     -of default=noprint_wrappers=1:nokey=1 2>/dev/null)
    duration=${duration%.*}          # 去掉小數
    [[ -z "$duration" ]] && duration=0
    echo "影片長度: ${duration}s"

    # --------------------------------------------------
    # B. 依片長決定抽樣段數與每段秒數
    # --------------------------------------------------
    local sample_count sample_len
    if   (( duration <= 60 ));        then sample_count=1; sample_len=20
    elif (( duration <= 300 ));       then sample_count=3; sample_len=10
    elif (( duration <= 1200 ));      then sample_count=5; sample_len=8
    else                                   sample_count=7; sample_len=10
    fi
    echo "將抽樣 ${sample_count} 段，每段 ${sample_len}s"

    # --------------------------------------------------
    # C. 計算抽樣起始時間點 (固定均分；可改隨機)
    # --------------------------------------------------
    local -a offsets=()
    if (( sample_count == 1 )); then
        offsets=(0)
    else
        # 均分位置；避開太靠邊 3% 區域，較穩定
        local step=$(( duration / (sample_count + 1) ))
        for ((i=1;i<=sample_count;i++)); do
            offsets+=( $(( i * step )) )
        done
    fi

    # 若想隨機取樣 (含開頭)，可改成：
    # offsets=( $(shuf -i 0-$((duration-sample_len)) -n $sample_count) )

    # --------------------------------------------------
    # D. 逐段統計 scene > 0.04 的畫格數量
    # --------------------------------------------------
    local total_scene_frames=0
    for off in "${offsets[@]}"; do
        echo "  ↪ 抽樣 offset=${off}s"
        local frames=$("$FF" -ss "$off" -i "$input" -t "$sample_len" \
                       -vf "select='gt(scene,0.04)',showinfo" \
                       -f null - 2>&1 | grep -c pts_time )
        total_scene_frames=$(( total_scene_frames + frames ))
    done

    # 平均每秒場景變化率
    local total_seconds=$(( sample_count * sample_len ))
    local quick_rate=$(awk "BEGIN{printf \"%.3f\", $total_scene_frames/$total_seconds}")
    echo "抽樣共偵測到 $total_scene_frames 個場景變化，平均 $quick_rate /sec"

    # --------------------------------------------------
    # E. 依 quick_rate 判斷動態級別
    #    (≈ 原先 quick_test>30/10 的邏輯，但改成比率)
    #    → 閾值可再依實測微調
    # --------------------------------------------------
    if awk "BEGIN{exit !($quick_rate > 3.0)}"; then
        # -------- 高動態 --------
        local S_thr=0.12 MIN_GAP=0.30
        echo "檢測為高動態影片"
        "$FF" -hide_banner -loglevel error -copyts -i "$input" \
            -vf "select='isnan(prev_selected_t)+gt(scene,${S_thr})*gte(t-prev_selected_t,${MIN_GAP})',\
mpdecimate,scale=1280:720" \
            -vsync 0 -frame_pts 1 -threads 2 $codec_args \
            "$output_dir/temp_%012d.${ext}" || return 1

    elif awk "BEGIN{exit !($quick_rate > 1.0)}"; then
        # -------- 中動態 --------
        local S_thr=0.08 MIN_GAP=0.50
        echo "檢測為中動態影片"
        "$FF" -hide_banner -loglevel error -copyts -i "$input" \
            -vf "select='isnan(prev_selected_t)+gt(scene,${S_thr})*gte(t-prev_selected_t,${MIN_GAP})',\
fps=2,scale=1280:720" \
            -vsync 0 -frame_pts 1 -threads 2 $codec_args \
            "$output_dir/temp_%012d.${ext}" || return 1
    else
        # -------- 低動態（簡報）--------
        local S_thr=0.04 MIN_GAP=0.80
        echo "檢測為低動態影片"
        "$FF" -hide_banner -loglevel error -copyts -i "$input" \
            -vf "select='isnan(prev_selected_t)+gt(scene,${S_thr})*gte(t-prev_selected_t,${MIN_GAP})',\
mpdecimate=hi=64*8:lo=64*3,scale=1280:720" \
            -vsync 0 -frame_pts 1 -threads 2 $codec_args \
            "$output_dir/temp_%012d.${ext}" || return 1
    fi
}


extract_hybrid_method