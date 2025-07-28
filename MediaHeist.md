# MediaHeist

## 核心理念

> yt-dlp -> ffmpeg -> whisper.cpp -> LLM OCR -> LLM -> summary markdown file

07/18
~~試試看 先用 llm 將 srt 做總結 然後留下關鍵秒數，再去擷取影格，最後再用 llm 去做總結~~


07/19
目前想到一個辦法

/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/scripts/frames.sh
先想一格合理高效的公式把影片切段再往下處理 (類似 10 分鐘內切成兩段影片, 60 分鐘切成 6 段影片等等之類的方法)。
ffmpeg 必須至少間隔 5 秒擷取影格並使用場景偵測 gt(scene,0.06) 擷取的圖片，並且要標註擷取圖片的時間(或許可以直接將時間以某種形式結合檔案命名，檔案命名絕對不可以有空格)，並且最後一定要將圖片 resize 到 480x270。
處理完畢後利用工具加上去除重複圖片的邏輯。



利用 llm 將 srt 檔案內容做重點整理與分析(決定用 ollama run qwen3:4b)，輸出一份 markdown 檔案。
輸出資料的格式如 prompt.txt 中的內容。



~~根據秒數去抓取對應(最靠近)時間的圖片 (圖片檔案在儲存時都是以特殊形式 frame_00_06_18_600.jpg 命名，代表 frame_小時_分鐘_秒數_毫秒.jpg，可以再用邏輯判斷)，(決定用 ollama run qwen3:4b) ~~
~~最後用~~
~~ocrit~~
~~+ ~~
~~ollama run qwen2.5vl:3b-q4_K_M "詳細完整敘述這張圖片任何細節，圖形，表格，文字，並使用繁體中文回覆 /Users/danos/xxxx.jpg" ~~
~~利用  LLM (ollama run qwen3:4b) 去分析全部被選中的圖片敘述，~~
~~分析被選中的圖片敘述是否有沒有真的符合 srt 的內容。沒有符合的話，找該圖片的前後 5 秒的圖片(共兩張)，再用做一次圖片分析流程(ocrit + ollama run qwen2.5vl:3b-q4_K_M) 選擇一張，最後要有個規則來限制，不能無限一直找下去。~~
~~最後要依照最終選出的圖片時間資料去重新抓取高清的影片截圖。~~


無法做到統一標準，少部分可以：自己要的不一定是科學實證或工具產生的產物


因為最後自己一定會要看過這份重點整理：
最後一個 recipe 可以改成有一個良好的介面(方便閱讀及選擇圖片)可以選擇你要加入筆記的圖片。
影片的截圖要先改成以 pre_srt_summary.sh 做出的總結中的時間標記來做資料夾區分存放截圖。

現在 "良好的介面程式已經做好了"，已經打包成二進制，可以 直接執行 /Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/scripts/select_image
使用說明在 /Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/scripts/select_image_go/README.md

現在要結合 /Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/Makefile 繼續完成目標







07/19 
~~最後再去新增 yt-dlp 先去判斷下載使否有原本的字幕~~

~~輸出的檔案名稱全都要加上前綴~~

~~修正 網頁輸出框的 max height 問題~~

~~修正 000 的截圖總是被分類在最後時間區段~~

~~網頁 server port 不能每次相同，遇到不同進程要執行時會撞到。~~

日誌輸出問題
 ~~recipe 總是要輸出~~
 同一行輸出兩次



## 詳細需求

產生一個 Makefile，可以透過參數直接輸入 youtube url，或是輸入指定 txt 目錄位置，讀取一份 txt 檔案，其中每行都是 youtube url，
讀取且使用 yt-dlp 下載最高畫質及音質的影片，儲存時檔案名稱要去除所有空格與特殊字元與表情符號只留下英文與中文，並且要建立獨立資料夾，
然後要而外輸出一個 mp3 音訊檔案 (必須是 16kHz, mono)。

使用 yt-dlp 工具時，請注意下載每個影片時必須要是異步執行非阻塞的，
先執行完成的就先去給 ffmpeg 與 whisper.cpp 去處理。

使用 ffmpeg 擷取關鍵影格必須按照下方範例 cli 與參數，擷取後的影格必須使用 WebP 格式儲存。
儲存時必須依照影片名稱分類清楚獨立資料夾。

使用 whisper.cpp 必須按照下方範例 cli 與參數去處理音訊檔案，產生 srt 檔案。

ffmpeg 影格先完成的影片先送去 LLM ORC (gemini-2.5-pro) 去將 WebP 圖片轉換成必要資訊，將所有圖片轉換完成的資訊儲存在同一份 txt 中。

最後等待所有的 ffmpeg 與 whisper.cpp 與 LLM ORC 完成後，再使用 LLM (gemini-2.5-pro) 去將所有準備好的文字檔案檔案轉換成 markdown 檔案。

# yt-dlp


yt-dlp -f "bestvideo+bestaudio/best" --merge-output-format mp4 "https://www.youtube.com/watch?v=57Tl5Lg_wpM&list=PLT3USJy3vydAu1XUGO5dY30gd2RBw1QgT&index=3"

# ffmpeg




```bash






#!/bin/bash

# 變數
# /Users/danos/自助式大數據平臺_平台工程的策略與價值.mp4
# IN="/Users/danos/自助式大數據平臺_平台工程的策略與價值.mp4"
OUT_DIR="/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/output/2025TSMC_DEVOPS"
BASENAME="$(basename "${IN%.*}")"

# Apple Silicon 硬解 + 只取 I-frame + 每 60 秒子取樣 + WebP
# ffmpeg -hwaccel videotoolbox -skip_frame nokey \
#        -i "$IN" \
#        -vf "fps=1/60" \
#        -lossless 1 -compression_level 6 -q:v 90 \
#        -threads 4 -c:v libwebp \
#        "${OUT_DIR}/${BASENAME}_%06d.webp"


# --- [修改後 v1 - 備份] ---
# # [修改後] Apple Silicon 硬解 + 只取 I-frame (更快速)
# ffmpeg -hwaccel videotoolbox \
#        -i "$IN" \
#        -vf "select='eq(pict_type,I)'" -vsync vfr \
#        -lossless 0 -compression_level 4 -q:v 80 \
#        -an -threads 8 -c:v libwebp \
#        "${OUT_DIR}/${BASENAME}_I-frame_%06d.webp"

# [修改後 v2] 使用場景偵測過濾相似影格 (推薦)
# 透過 'scene' 參數偵測畫面實際變化，只在變化超過閾值 (如 0.05) 時才擷取，有效避免重複圖片
# ffmpeg -hwaccel videotoolbox \
#        -i "$IN" \
#        -vf "select='gt(scene,0.05)'" \
#        -fps_mode vfr \
#        -lossless 0 -compression_level 4 -q:v 80 \
#        -an -threads 10 -c:v libwebp \
#        "${OUT_DIR}/${BASENAME}_scene-change_%06d.webp"




ffmpeg -hwaccel videotoolbox -i "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/source/2025TSMC_DEVOPS/2025TSMC_DEVOPS_蔡孟玹_從Monitoring到Observability_快速發現與解決問題的進化之路.mp4" -vf "select='gt(scene,0.05)'" -fps_mode vfr -lossless 0 -compression_level 4 -q:v 80 -an -threads 10 -c:v libwebp "${OUT_DIR}/2025TSMC_DEVOPS_蔡孟玹_從Monitoring到Observability_快速發現與解決問題的進化之路/${BASENAME}_scene-change_%06d.webp" ;




# 2025TSMC_DEVOPS_QA
# 2025TSMC_DEVOPS_HRInfoSession
# 2025TSMC_DEVOPS_趙秉祥_大型語言模型在軟體工程中的應用_多代理系統的創新與挑戰
# 2025TSMC_DEVOPS_莊育珊GenerativeAI在全球化擴廠中扮演的角色
# 2025TSMC_DEVOPS_李昭德_范哲誠_融合視覺AI與智慧製造_提升操作效率的創新策略
# 2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存






# ffmpeg -hwaccel videotoolbox -i "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/source/2025TSMC_DEVOPS/2025TSMC_DEVOPS_AI服務開發全解析_從技術藍圖到落地實踐.mp4" -vf "select='gt(scene,0.05)'" -fps_mode vfr -lossless 0 -compression_level 4 -q:v 80 -an -threads 10 -c:v libwebp "${OUT_DIR}/2025TSMC_DEVOPS_AI服務開發全解析_從技術藍圖到落地實踐/${BASENAME}_scene-change_%06d.webp" ;

# ffmpeg -hwaccel videotoolbox -i "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/SideProject/MediaHeist/source/2025TSMC_DEVOPS/2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存.mp4" -vf "select='gt(scene,0.05)'" -fps_mode vfr -lossless 0 -compression_level 4 -q:v 80 -an -threads 10 -c:v libwebp "${OUT_DIR}/2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存/${BASENAME}_scene-change_%06d.webp" ;




# 移除 -skip_frame nokey 和 -vf "fps=1/60"：
# 改用 -vf "select='eq(pict_type,I)'" 搭配 -vsync vfr。這是 ffmpeg 中擷取關鍵影格 (I-frame) 更為標準且高效的方法，它會精準地選取所有關鍵影格，而不會進行額外的影格率轉換。
# 調整 WebP 壓縮設定：
# -lossless 0：改為有損壓縮，這會大幅提升編碼速度。
# -compression_level 4：從 6 (最高壓縮，最慢) 降至 4 (速度與品質的良好平衡)。
# -q:v 80：設定有損壓縮的品質為 80 (範圍 0-100)，這在視覺上通常已經非常出色。
# 其他優化：
# -an：停用音訊處理 (因為我們只需要圖片)，避免不必要的資源消耗。
# -threads 8：將執行緒數量增加到 8，以更好地利用現代多核心 CPU 的性能。
# 輸出檔名：在檔名中加入 I-frame 以區分新舊方法產生的檔案。


# 在 ffmpeg 的場景偵測過濾器 select='gt(scene,VALUE)' 中，scene 的值是一個代表「目前影格與前一個影格之間差異程度」的浮點數。

# 這個值的範圍是：

# 最小值：0.0
# 最大值：1.0
# 詳細解釋：

# scene = 0.0：表示目前影格與前一個影格完全相同，沒有任何像素級的變化。
# scene = 1.0：表示兩個影格之間達到了最大可能的差異。一個典型的例子就是從一個全黑的畫面直接切換到一個全白的畫面。
# 如何選擇 VALUE (閾值)？

# 您在指令中使用的 0.2 就是一個「閾值」，用來告訴 ffmpeg 您對「變化」的敏感度要求有多高。

# 較低的值 (例如 0.1 或 0.08)：
# 更敏感。
# 即使是微小的變化（例如投影片上出現一個滑鼠指標、一行文字的細微動畫）也可能被偵測到。
# 會產生較多的圖片。
# 較高的值 (例如 0.3 或 0.4)：
# 較不敏感。
# 只會擷取非常明顯的、大範圍的場景變換（例如整張投影片切換、影片場景的硬切換）。
# 會產生較少的圖片。


```














# whisper.ccp

```bash

#!/usr/bin/env bash
# 用法：./mp42srt.sh <video.mp4> [output_dir] [lang]
# ./mp42srt.sh demo.mp4 ./subtitle zh
# ./mp42srt.sh /Users/danos/GetKeyframesInVideo/自助式大數據平臺_平台工程的策略與價值/自助式大數據平臺_平台工程的策略與價值.mp4 /Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp zh
set -euo pipefail



VID="$1"; OUTDIR="${2:-$(pwd)}"; LANG="${3:-auto}"
BIN="./whisper.cpp/build/bin/whisper-cli"
# /Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/build/bin/whisper-cli
MODEL="./whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin"
CPU=$(sysctl -n hw.physicalcpu)

tmp=$(mktemp -d)

# ffmpeg -i "$VID" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$tmp/audio.wav" -y
# ffmpeg -i "/Users/danos/GetKeyframesInVideo/自助式大數據平臺_平台工程的策略與價值/自助式大數據平臺_平台工程的策略與價值.mp4" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$HOME/自助式大數據平臺_平台工程的策略與價值.wav" -y
# ffmpeg -i "/Users/danos/GetKeyframesInVideo/自助式大數據平臺_平台工程的策略與價值/自助式大數據平臺_平台工程的策略與價值.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/自助式大數據平臺_平台工程的策略與價值.mp3" -y





ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_周威廷_自助式大數據平臺_平台工程的策略與價值.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_周威廷_自助式大數據平臺_平台工程的策略與價值.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_蔡孟玹_從 Monitoring到Observability_快速發現與解決問題的進化之路.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_蔡孟玹_從 Monitoring到Observability_快速發現與解決問題的進化之路.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_AI服務開發全解析_從技術藍圖到落地實踐.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_AI服務開發全解析_從技術藍圖到落地實踐.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_李昭德_范哲誠_融合視覺AI與智慧製造_提升操作效率的創新策略.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_李昭德_范哲誠_融合視覺AI與智慧製造_提升操作效率的創新策略.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_莊育珊GenerativeAI在全球化擴廠中扮演的角色.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_莊育珊GenerativeAI在全球化擴廠中扮演的角色.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_趙秉祥_大型語言模型在軟體工程中的應用_多代理系統的創新與挑戰.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_趙秉祥_大型語言模型在軟體工程中的應用_多代理系統的創新與挑戰.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_HRInfoSession.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_HRInfoSession.mp3" -y ;
ffmpeg -i "/Users/danos/2025TSMC_DEVOPS_QA.mp4" -vn -ac 1 -ar 16000 -c:a libmp3lame -q:a 2 "$HOME/2025TSMC_DEVOPS_QA.mp3" -y ;

./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_周威廷_自助式大數據平臺_平台工程的策略與價值.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_蔡孟玹_從 Monitoring到Observability_快速發現與解決問題的進化之路.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_AI服務開發全解析_從技術藍圖到落地實踐.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_李昭德_范哲誠_融合視覺AI與智慧製造_提升操作效率的創新策略.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_莊育珊GenerativeAI在全球化擴廠中扮演的角色.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_趙秉祥_大型語言模型在軟體工程中的應用_多代理系統的創新與挑戰.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_HRInfoSession.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;
./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_QA.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt ;






echo "Start transcribe"

# ./build/bin/whisper-cli -m "/Users/danos/syncthing-danoslive_20250210/danoslive/ResearchProject/LLM/Whisper/whisper_cpp/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin" "/Users/danos/2025TSMC_DEVOPS_邱宏瑋_面對大規模Kubernetes叢集_挑戰與機遇並存.mp3" -l zh --prompt "這是一段使用繁體中文的語音" -t 10 -osrt


echo "End transcribe"
echo "Move subtitle file"

mv "$tmp/sub.srt" "$OUTDIR/$(basename "${VID%.*}").srt"
rm -rf "$tmp"

echo "完成：${OUTDIR}/$(basename "${VID%.*}").srt"

```














# LLM OCR



```bash


#!/bin/bash
set -e -E

GEMINI_API_KEY="$GEMINI_API_KEY"
MODEL_ID="gemini-2.5-pro"
GENERATE_CONTENT_API="streamGenerateContent"

cat << EOF > request.json
{
    "contents": [
      {
        "role": "user",
        "parts": [
          {
            "text": "INSERT_INPUT_HERE"
          },
        ]
      },
    ],
    "generationConfig": {
      "thinkingConfig": {
        "thinkingBudget": -1,
      },
      "responseMimeType": "text/plain",
    },
    "tools": [
      {
        "googleSearch": {
        }
      },
    ],
}
EOF

curl \
-X POST \
-H "Content-Type: application/json" \
"https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:${GENERATE_CONTENT_API}?key=${GEMINI_API_KEY}" -d '@request.json'


```




```bash



#!/bin/bash
set -e -E

GEMINI_API_KEY="$GEMINI_API_KEY"
MODEL_ID="gemini-2.5-pro"
GENERATE_CONTENT_API="streamGenerateContent"

cat << EOF > request.json
{
    "contents": [
      {
        "role": "user",
        "parts": [
          {
            "inlineData": {
              "mimeType": "image/webp",
              "data": "UklGRuZtAQBXRUJQVlA4INptAQBQuIAA..."
            }
          },
          {
            "text": "詳細完整分析我上傳的圖片，盡全力非常仔細描述圖片上所有的文字與圖形與表格。\n\n"
          },
        ]
      },
      {
        "role": "model",
        "parts": [
          {
            "text": "**Begin Analyzing the Image**\n\nI'm starting by carefully dissecting ..."
          },
          {
            "text": "好的，這張圖片是一張來自台積電（TSMC）的技術簡報投影片，標題為「第一代資料平台（1st Generation Data Platform）」。一位 ..."
          },
        ]
      },
      {
        "role": "user",
        "parts": [
          {
            "text": "INSERT_INPUT_HERE"
          },
        ]
      },
    ],
    "generationConfig": {
      "thinkingConfig": {
        "thinkingBudget": -1,
      },
      "responseMimeType": "text/plain",
    },
    "tools": [
      {
        "googleSearch": {
        }
      },
    ],
}
EOF

curl \
-X POST \
-H "Content-Type: application/json" \
"https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:${GENERATE_CONTENT_API}?key=${GEMINI_API_KEY}" -d '@request.json'


```

# LLM 總結



```bash


#!/bin/bash
set -e -E

GEMINI_API_KEY="$GEMINI_API_KEY"
MODEL_ID="gemini-2.5-pro"
GENERATE_CONTENT_API="streamGenerateContent"

cat << EOF > request.json
{
    "contents": [
      {
        "role": "user",
        "parts": [
          {
            "inlineData": {
              "mimeType": "image/webp",
              "data": "UklGRljJAABXRUJ..."
            }
          },
          {
            "inlineData": {
              "mimeType": "image/webp",
              "data": "UklGRuphAQBXR..."
            }
          },
          {
            "text": "幫我把上傳的圖片與檔案文字(逐字稿)內容，逐字逐句，結合成重點摘要，要段落明確，最後整理在一份 markdown 檔案給我下載，markdown 中的圖片只要清楚使用 markdown 圖片語法標注是哪一張圖片即可。"
          },
        ]
      },
      {
        "role": "model",
        "parts": [
          {
            "text": "**Synthesizing User Input**\n\nI'm currently focused on dissecting the user's request. My primary goal ..."
          },
          {
            "text": "好的，這就為您將簡報圖片與逐字稿內容，整合成一份重點摘要 Markdown 檔案。\n\n```markdown\n# TSMC 分享：打造自助式大數據平台 — 平台工程的策略與價值\n\n這份文件摘要整理了台積電平台聯邦查詢的方式為主。\n\n![Question 4](image_2.png)\n```"
          },
        ]
      },
      {
        "role": "user",
        "parts": [
          {
            "text": "INSERT_INPUT_HERE"
          },
        ]
      },
    ],
    "generationConfig": {
      "thinkingConfig": {
        "thinkingBudget": -1,
      },
      "responseMimeType": "text/plain",
    },
    "tools": [
      {
        "urlContext": {}
      },
      {
        "googleSearch": {
        }
      },
    ],
}
EOF

curl \
-X POST \
-H "Content-Type: application/json" \
"https://generativelanguage.googleapis.com/v1beta/models/${MODEL_ID}:${GENERATE_CONTENT_API}?key=${GEMINI_API_KEY}" -d '@request.json'



```