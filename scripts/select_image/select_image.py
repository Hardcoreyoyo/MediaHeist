"""
Minimal FastAPI image selection server.

This script serves images from a given directory via a web interface
so that the user can preview and select images. It intentionally avoids
external state mutations; selected filenames are POSTed back to the
server and logged to STDOUT, which the caller can redirect to a file or
pipe to another process.

Key design goals:
1. High performance: Files are streamed via StaticFiles, directory scan
   is cached in memory and refreshed via a background task every SECS.
2. Security: Static file serving is limited to the configured base
   directory. Filename inputs are validated strictly.
3. Comprehensive error handling: The API returns clear HTTP errors for
   invalid requests; unexpected exceptions are logged.
4. Readability: Small, single-file implementation with clear function
   boundaries and type hints.
5. Industry standards: Follows FastAPI best practices and uses ASGI-
   compliant Uvicorn.

Run:
    # Create virtual env (once) in project root
    pipenv install fastapi "uvicorn[standard]" Jinja2

    # Activate env and start server, default host=127.0.0.1:8000
    pipenv run python scripts/select_image.py \
        --base-dir /path/to/your/images \
        --refresh-secs 15 \
        --output-dir /path/to/output
"""

from __future__ import annotations

import argparse
import logging
import os
import pathlib
import re
import sys
from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field

LOGGER = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)

# --------------------------- Config & I/O models ---------------------------- #

class Settings(BaseModel):
    base_dir: pathlib.Path = Field(..., description="Directory containing images")
    refresh_secs: int = Field(15, ge=5, description="Directory rescan interval")
    port: int = Field(8000, ge=1, le=65535, description="HTTP port")
    transcript_path: Optional[pathlib.Path] = Field(None, description="Transcript text file")
    output_dir: Optional[pathlib.Path] = Field(None, description="Directory to save exported markdown")


class SelectionPayload(BaseModel):
    filename: str


class ExportPayload(BaseModel):
    selections: Dict[str, List[str]]  # segment_id -> list of filenames


# ------------------------------- Utilities --------------------------------- #

def scan_images(directory: pathlib.Path) -> List[pathlib.Path]:
    """Return list of image files under *directory*, relative to *directory*.
    Only .jpg, .jpeg, .png, .gif are included.
    """
    allowed_exts = {".jpg", ".jpeg", ".png", ".gif"}
    images: List[pathlib.Path] = []
    for path in directory.rglob("*"):
        if path.is_file() and path.suffix.lower() in allowed_exts:
            images.append(path.relative_to(directory))
    return sorted(images)


def parse_frame_timestamp(filename: str) -> Optional[float]:
    """Parse frame filename (frame_xx_xx_xx_xxx) to timestamp in seconds.
    Returns None if filename doesn't match expected format.
    """
    pattern = re.compile(r"frame_(\d{2})_(\d{2})_(\d{2})_(\d{3})")
    match = pattern.search(filename)
    if not match:
        return None
    
    hours, minutes, seconds, milliseconds = map(int, match.groups())
    return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000.0


def parse_transcript_timestamp(timestamp_str: str) -> float:
    """Parse transcript timestamp (hh:mm:ss,mmm) to seconds."""
    # Handle both comma and dot as millisecond separator
    timestamp_str = timestamp_str.replace(',', '.')
    parts = timestamp_str.split(':')
    hours, minutes = int(parts[0]), int(parts[1])
    seconds_parts = parts[2].split('.')
    seconds = int(seconds_parts[0])
    milliseconds = int(seconds_parts[1]) if len(seconds_parts) > 1 else 0
    return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000.0


def group_images_by_segments(images: List[pathlib.Path], segments: List[dict]) -> dict:
    """Group images by transcript segments based on timestamp matching."""
    # Initialize groups for each segment
    grouped = {f"segment_{i}": [] for i in range(len(segments))}

    # Edge case: no segments defined – fall back to single bucket
    if not segments:
        grouped["segment_0"] = images.copy()
        return grouped

    last_seg_key = f"segment_{len(segments)-1}"

    for img in images:
        frame_time = parse_frame_timestamp(str(img))
        if frame_time is None:
            # No timestamp in filename; treat as belonging to last segment
            grouped[last_seg_key].append(img)
            continue

        # Find which segment this frame belongs to
        assigned = False
        for i, segment in enumerate(segments):
            start_time = parse_transcript_timestamp(segment["start"])
            end_time = parse_transcript_timestamp(segment["end"])
            if start_time <= frame_time <= end_time:
                grouped[f"segment_{i}"].append(img)
                assigned = True
                break

        # Frames beyond last segment end are also put into last segment
        if not assigned:
            grouped[last_seg_key].append(img)

    return grouped

# --- Transcript parsing ---------------------------------------------------- #

def parse_transcript(path: pathlib.Path) -> List[dict]:
    """Parse a transcript file that may contain arbitrary prose *and* timestamp
    sections.

    完全保留原始內容的修改版本：
    1. 第一個 segment 包含從文件開頭到第一個 Timestamp 段落結束的所有內容
    2. 後續 segment 包含完整的 Timestamp 段落內容
    3. 如果沒有 Timestamp，整個文件作為單一 segment

    傳回：List[dict] 其中每個 dict 包含 `start`, `end`, `text`
    """

    content = path.read_text(encoding="utf-8", errors="ignore")

    # Regex 捕捉 Timestamp 標題行
    heading_re = re.compile(
        r"^###\s*Timestamp:\s*\*\*(\d{2}:\d{2}:\d{2},\d{3})\*\*\s*~\s*\*\*(\d{2}:\d{2}:\d{2},\d{3})\*\*.*?$",
        re.MULTILINE,
    )

    matches = list(heading_re.finditer(content))

    # 若沒有任何 Timestamp，整篇視為單一段落
    if not matches:
        return [{"start": "", "end": "", "text": content.strip()}]

    segments: List[dict] = []

    for idx, match in enumerate(matches):
        # 取得時間戳
        start_time = match.group(1)
        end_time = match.group(2)
        
        # 計算內容範圍
        if idx == 0:
            # 第一個段落：從文件開頭開始，包含所有前言內容
            content_start = 0
        else:
            # 後續段落：從當前 Timestamp 行開始
            content_start = match.start()
        
        # 內容結束位置：到下一個 Timestamp 行開始之前，或文件結尾
        if idx + 1 < len(matches):
            content_end = matches[idx + 1].start()
        else:
            content_end = len(content)
        
        # 擷取完整的段落內容
        segment_content = content[content_start:content_end].strip()
        
        segments.append({
            "start": start_time,
            "end": end_time,
            "text": segment_content,
        })

    return segments


def generate_markdown(
    segments: List[dict],
    selections: Dict[str, List[str]],
    base_dir: pathlib.Path,
) -> str:
    """Generate markdown by *appending* images to the original transcript text.

    修改重點：
    1. 直接輸出 segment['text']，不再生成人工標題
    2. 僅在段落文字之後插入使用者選擇的圖片區塊
    3. 完全保留原始文件的結構和內容
    4. 移除所有人工添加的標題和時間戳
    """

    markdown_lines: List[str] = []

    # 注意：這裡不再添加人工標題如 "# 影片內容整理" 和時間戳
    # 直接處理原始內容
    
    for i, segment in enumerate(segments):
        segment_key = str(i)
        selected_images = selections.get(segment_key, [])

        # 直接輸出原始文字內容（包含前言、標題、Timestamp 等）
        markdown_lines.append(segment["text"])
        
        # 如果有選取圖片，插入於該段落後
        if selected_images:
            markdown_lines.append("")  # 空行分隔
            markdown_lines.append("### 相關圖片")
            markdown_lines.append("")
            for img_path in selected_images:
                markdown_lines.append(f"![{img_path}]({img_path})")
        
        # 段落間分隔（除了最後一個段落）
        if i < len(segments) - 1:
            markdown_lines.append("")
            markdown_lines.append("---")
            markdown_lines.append("")

    # 處理未分組的圖片
    ungrouped = selections.get("ungrouped", [])
    if ungrouped:
        markdown_lines.append("")
        markdown_lines.append("---")
        markdown_lines.append("")
        markdown_lines.append("## 其他圖片")
        markdown_lines.append("")
        for img_path in ungrouped:
            markdown_lines.append(f"![{img_path}]({img_path})")

    return "\n".join(markdown_lines)

# ------------------------------- App setup --------------------------------- #

def create_app(settings: Settings) -> FastAPI:
    app = FastAPI(title="Image Selector", docs_url=None, redoc_url=None)

    templates = Jinja2Templates(directory=str(_template_dir()))

    # Ensure base dir exists
    if not settings.base_dir.is_dir():
        LOGGER.error("Base directory does not exist: %s", settings.base_dir)
        sys.exit(1)

    # Ensure output dir exists
    if settings.output_dir:
        settings.output_dir.mkdir(parents=True, exist_ok=True)

    # Mount static file handler
    app.mount(
        "/static",
        StaticFiles(directory=str(settings.base_dir), html=False),
        name="static",
    )

    image_cache: List[pathlib.Path] = scan_images(settings.base_dir)

    # Preload transcript segments if provided
    segments_cache: List[dict] = []
    if settings.transcript_path and settings.transcript_path.is_file():
        try:
            segments_cache = parse_transcript(settings.transcript_path)
        except Exception as exc:  # pylint: disable=broad-except
            LOGGER.exception("Failed to parse transcript: %s", exc)

    @app.on_event("startup")
    async def _startup() -> None:  # noqa: D401  pylint: disable=unused-variable
        LOGGER.info("Image selector server started on base dir %s", settings.base_dir)

    # Background task to refresh image list periodically (fire-and-forget)
    async def _refresh_task():  # type: ignore[return-value]
        import asyncio  # local import to avoid forking issues on reload

        while True:
            try:
                new_list = scan_images(settings.base_dir)
                if new_list != image_cache:
                    image_cache[:] = new_list  # in-place mutation keeps refs valid
                await asyncio.sleep(settings.refresh_secs)
            except Exception as exc:  # pylint: disable=broad-except
                LOGGER.exception("Refresh task error: %s", exc)
                await asyncio.sleep(settings.refresh_secs)

    import asyncio

    asyncio.get_event_loop().create_task(_refresh_task())

    # --------------------------- Route handlers --------------------------- #

    @app.get("/", response_class=HTMLResponse)
    async def index(request: Request):  # type: ignore[valid-type]
        # Group images by segments if transcript is available
        grouped_images = {}
        if segments_cache:
            grouped_images = group_images_by_segments(image_cache, segments_cache)
        
        return templates.TemplateResponse(
            "gallery.html",
            {
                "request": request,
                "images": image_cache,
                "grouped_images": grouped_images,
                "segments": segments_cache,
            },
        )

    @app.post("/select", response_class=JSONResponse)
    async def select(payload: SelectionPayload):
        rel_path = pathlib.Path(payload.filename)
        if rel_path.is_absolute() or ".." in rel_path.parts:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid filename")
        full_path = settings.base_dir / rel_path
        if not full_path.exists():
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="File not found")

        # Here we simply log. In real usage, write to notes or DB.
        LOGGER.info("Selected image: %s", full_path)
        return {"ok": True, "file": str(rel_path)}

    @app.get("/segments", response_class=JSONResponse)
    async def segments():
        return segments_cache

    @app.post("/export", response_class=JSONResponse)
    async def export_markdown(payload: ExportPayload):
        if not settings.output_dir:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, 
                detail="Export functionality not available: output directory not configured"
            )
            
        try:
            # Generate markdown content
            markdown_content = generate_markdown(segments_cache, payload.selections, settings.base_dir)
            
            # Create filename with timestamp
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"exported_content_{timestamp}.md"
            output_path = settings.output_dir / filename
            
            # Write markdown file
            output_path.write_text(markdown_content, encoding="utf-8")
            
            LOGGER.info("Exported markdown to: %s", output_path)
            
            return {
                "ok": True, 
                "filename": filename,
                "path": str(output_path),
                "total_segments": len(segments_cache),
                "total_selections": sum(len(imgs) for imgs in payload.selections.values())
            }
            
        except Exception as exc:
            LOGGER.exception("Export failed: %s", exc)
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, 
                detail=f"Export failed: {str(exc)}"
            )

    return app


# ------------------------------ Templates ---------------------------------- #

def _template_dir() -> pathlib.Path:
    """Return directory path containing HTML templates bundled with this file."""
    return pathlib.Path(__file__).with_suffix("").with_name("templates")


def _ensure_templates_exist() -> None:
    """Create minimal gallery template next to this script if missing."""
    tpl_dir = _template_dir()
    tpl_dir.mkdir(parents=True, exist_ok=True)
    (tpl_dir / "gallery.html").write_text(
"""
<!DOCTYPE html>
    <html lang=\"en\">
        
        <head>
        
        <meta charset=\"utf-8\" />

        <title>Image Selector</title>

        <style>
            body { font-family: "Source Code Pro", "Courier New", monospace; margin:0; padding:0; background:#000; color:#eee; }
            a{color:#0af;}
            .container { display: flex; margin-top: 72px; height: calc(100vh - 72px); }
            #rightPane { flex: 1; display: flex; flex-direction: column; }
            #navBtns { padding:4px; border-top:1px solid #333; display:flex; gap:8px; justify-content:center; }
            #navBtns button { padding:4px 8px; cursor:pointer; }
            #infoPane { padding: 0.5rem; border-bottom: 1px solid #333; flex: 0 0 30%; max-height: 30%; overflow-y: auto; background:#000; }
            #fileList { width: 16%; border-right: 1px solid #333; overflow-y: auto; padding: 1rem; padding-top: 0px; box-sizing:border-box;padding-left: 24px; }
            #fileList ul { list-style: none; margin: 0; padding: 0; }
            #fileList li { cursor: pointer; padding: 4px 2px; user-select: none; }
            
            .segment-group { margin-bottom: 1rem; }
            .segment-header { 
                font-weight: bold; 
                color: #eee; 
                background-color: #111; 
                padding: 6px 8px; 
                margin: 4px 0; 
                border-left: 3px solid #007acc;
                font-size: 0.9em;
            }
            .segment-header.active { background-color: #222; border-left-color: #0f0; }
            .segment-images { margin-left: 8px; }
            .segment-images li { padding-left: 8px; border-left: 1px solid #e0e0e0; scroll-margin-top: 80px; }
            .selected {\n            background-color: transparent;\n            position: relative;\n            font-weight: bold;\n            }\n            .selected::before {
                color: #0f0;  /* bright green arrow */\n                content: \"\\2192\";\n                position: absolute;\n                left: -20px;\n\n                font-weight: bold;\n            }
            .confirmed {\n            background-color: transparent;\n            position: relative;\n            }\n            .confirmed::after {
                color: #0af;  /* bright cyan bullet */\n                content: \" \\2022\";\n\n                margin-left: 4px;\n\n                border-left: 3px solid #0f0;}
            #toast { position: fixed; right: 1rem; bottom: 1rem; background: rgba(0,0,0,0.8); color:#fff; padding:8px 12px; border-radius:4px; opacity:0; transition: opacity .3s; pointer-events:none; z-index: 1000; border-left: 3px solid #0f0; }
            #toast.show { opacity:1; }
            #preview { flex: 1; display: flex; justify-content: center; align-items: flex-start; padding: 1rem; }
            #preview img { height: auto; width: auto; max-width: 100%; max-height: 100%; }
            .segment { margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 1px solid #e0e0e0; padding-left: 8px;}
            .seg-title { font-weight: bold; color: #eee; margin-bottom: 0.25rem; }
            .seg-images { display:flex; flex-wrap:wrap; gap:4px; margin-top:4px; }
            .seg-images img { max-width:100px; height:auto; border:1px solid #ccc; }
            .current-seg { background-color:#222; border-left:3px solid #0f0; }
            
            /* Modal styles */
            .modal-overlay {
                position: fixed;
                top: 0;
                left: 0;
                width: 100%;
                height: 100%;
                background: rgba(0, 0, 0, 0.5);
                display: none;
                justify-content: center;
                align-items: center;
                z-index: 2000;
            }
            .modal-overlay.show {
                display: flex;
            }
            .modal-content {
                background: #000; color:#eee; border:1px solid #333;
                border-radius: 8px;
                padding: 2rem;
                max-width: 500px;
                width: 90%;
                box-shadow: 0 4px 20px rgba(0, 0, 0, 0.3);
            }
            .modal-header {
                font-size: 1.2em;
                font-weight: bold;
                margin-bottom: 1rem;
                color: #eee;
            }
            .modal-body {
                margin-bottom: 1.5rem;
                line-height: 1.5;
                color: #ccc;
            }
            .modal-stats {
                background: #111; color:#eee; border:1px solid #333;
                padding: 1rem;
                border-radius: 4px;
                margin: 1rem 0;
                font-family: monospace;
                font-size: 0.9em;
                white-space: pre-wrap;
            }
            .modal-buttons {
                display: flex;
                gap: 1rem;
                justify-content: flex-end;
            }
            .modal-btn {
                padding: 0.5rem 1.5rem;
                border: none;
                border-radius: 4px;
                cursor: pointer;
                font-size: 1em;
                transition: background-color 0.2s;
            }
            .modal-btn-cancel {
                background: #222; color:#eee; border:1px solid #333;
            }
            .modal-btn-cancel:hover {
                background: #444;
            }
            .modal-btn-confirm {
                background: #0f0; color:#000; font-weight:bold;
            }
            .modal-btn-confirm:hover {
                background: #0c0;
            }
            .modal-btn:disabled {
                opacity: 0.6;
                cursor: not-allowed;
            }
        </style>
        </head>

        <body>
            <h2 style=\"position:sticky; top:0; z-index:1500; background:#000; color:#eee; margin:0; padding:1rem; border-bottom:1px solid #333;\">Select an image <span style=\"font-size:0.7em; color:#888;\">(Cmd+Enter 匯出)</span></h2>
            <div class=\"container\">
            <div id=\"fileList\">
                {% if grouped_images and segments %}
                    <!-- Grouped by segments -->
                    {% for i in range(segments|length) %}
                        {% set segment = segments[i] %}
                        {% set segment_images = grouped_images.get('segment_' + i|string, []) %}
                        {% if segment_images %}
                        <div class="segment-group">
                            <div class="segment-header" data-segment="{{ i }}">
                                {{ segment.start }} ~ {{ segment.end }}
                                <br><span style="font-weight: normal; font-size: 0.85em; color: #666;">
                                {{ segment.text[:50] }}{% if segment.text|length > 50 %}...{% endif %}
                                </span>
                            </div>
                            <ul class="segment-images">
                                {% for img in segment_images %}
                                <li data-file="{{ img }}" data-segment="{{ i }}">{{ img }}</li>
                                {% endfor %}
                            </ul>
                        </div>
                        {% endif %}
                    {% endfor %}
                    
                    <!-- Ungrouped images -->
                    {% if grouped_images.get('ungrouped', []) %}
                    <div class="segment-group">
                        <div class="segment-header">其他圖片</div>
                        <ul class="segment-images">
                            {% for img in grouped_images.ungrouped %}
                            <li data-file="{{ img }}" data-segment="ungrouped">{{ img }}</li>
                            {% endfor %}
                        </ul>
                    </div>
                    {% endif %}
                {% else %}
                    <!-- Fallback: show all images without grouping -->
                    <ul>
                    {% for img in images %}
                    <li data-file="{{ img }}" data-segment="ungrouped">{{ img }}</li>
                    {% endfor %}
                    </ul>
                {% endif %}
            </div>
                <div id=\"rightPane\">
                    <div id=\"infoPane\"></div>
                    <div id=\"preview\" style=\"flex:1; display:flex; justify-content:center; align-items:flex-start; padding:1rem;\">
                        <img id=\"previewImg\" src=\"\" alt=\"preview\" />
                    </div>
                </div>
            </div>
            <div id=\"toast\" ></div>

            <!-- Export Confirmation Modal -->
            <div id="exportModal" class="modal-overlay">
                <div class="modal-content">
                    <div class="modal-header">準備匯出</div>
                    <div class="modal-body">
                        確定要匯出所有已選擇的圖片和文字內容嗎？
                        <div id="exportStats" class="modal-stats"></div>
                    </div>
                    <div class="modal-buttons">
                        <button class="modal-btn modal-btn-cancel" onclick="hideExportModal()">取消</button>
                        <button class="modal-btn modal-btn-confirm" onclick="confirmExport()" id="confirmExportBtn">確認匯出</button>
                    </div>
                </div>
            </div>

            <script>
            async function postSelection(file) {
            const res = await fetch('/select', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ filename: file })
            });
            if (!res.ok) {
                alert('Error: ' + (await res.text()));
            }
            }

            function showPreview(file) {
            const img = document.getElementById('previewImg');
            img.src = '/static/' + file;
            }

            
            </script>
            
            <script>
            // --- enhanced navigation and selection ---
            const listItems = Array.from(document.querySelectorAll('#fileList li[data-file]'));
            const segmentHeaders = Array.from(document.querySelectorAll('.segment-header[data-segment]'));

            // toast helper
            function showToast(msg){
            const toast=document.getElementById('toast');
            toast.textContent=msg;
            toast.classList.add('show');
            setTimeout(()=>toast.classList.remove('show'),2000);
            }

            function confirmFile(file, li){
            const segmentIdx = li ? li.dataset.segment : String(segIdx);
            const actualSegIdx = segmentIdx !== 'ungrouped' ? parseInt(segmentIdx) : segIdx;
            const selectionKey = segmentIdx === 'ungrouped' ? 'ungrouped' : String(actualSegIdx >= 0 ? actualSegIdx : segIdx);
            const selArr = (selections[selectionKey] ??= []);
            const wrap = segDivs[actualSegIdx >= 0 ? actualSegIdx : 0]?.querySelector('.seg-images');
            const idx = selArr.indexOf(file);
            if(idx === -1){
                // add
                postSelection(file);
                selArr.push(file);
                if(li) li.classList.add('confirmed');
                showToast('已添加內容');
                if(wrap && segmentIdx !== 'ungrouped'){
                    const thumb = document.createElement('img');
                    thumb.src = '/static/' + file;
                    thumb.dataset.file = file;
                    wrap.appendChild(thumb);
                    // after adding, align segment bottom to pane bottom
                    const pane = document.getElementById('infoPane');
                    const seg = segDivs[segIdx];
                    if(seg){
                        const bottom = seg.getBoundingClientRect().bottom - pane.getBoundingClientRect().top + pane.scrollTop;
                        const target = bottom - pane.clientHeight;
                        pane.scrollTo({top: target, behavior:'auto'});
                    }
                }
            }else{
                // remove
                selArr.splice(idx,1);
                if(li) li.classList.remove('confirmed');
                showToast('已移除');
                if(wrap && segmentIdx !== 'ungrouped'){
                    const img = wrap.querySelector(`img[data-file="${file}"]`);
                    if(img) img.remove();
                }

            }
            }

            let currentIndex = 0;
            function highlight(idx) {
            if (listItems.length === 0) return;
            listItems.forEach(li => li.classList.remove('selected'));
            segmentHeaders.forEach(h => h.classList.remove('active'));
            currentIndex = (idx + listItems.length) % listItems.length;
            const li = listItems[currentIndex];
            li.classList.add('selected');
            li.scrollIntoView({behavior:'auto',block:'nearest'});
            showPreview(li.dataset.file);
            
            // Highlight corresponding segment header
            const segmentIdx = li.dataset.segment;
            if (segmentIdx !== 'ungrouped' && segmentIdx !== '-1') {
                const header = segmentHeaders.find(h => h.dataset.segment === segmentIdx);
                if (header) header.classList.add('active');
            }
            }

            // Move cursor within current segment only
            function nextInSegment(delta){
                if(listItems.length===0) return;
                const currentSeg = String(segIdx);
                let idx = currentIndex;
                do{
                    idx = (idx + delta + listItems.length) % listItems.length;
                }while(listItems[idx].dataset.segment !== currentSeg && idx !== currentIndex);
                highlight(idx);
            }

            // initial highlight first item
            if (listItems.length) {
            highlight(0);
            }

            // click handler override to use highlight and confirm
            listItems.forEach((li, idx) => {
            li.addEventListener('click', () => {
                highlight(idx);
                confirmFile(li.dataset.file, li);
            });
            });

            // keyboard navigation
            const nextBtnEl = document.getElementById('nextBtn');
            if(nextBtnEl) nextBtnEl.addEventListener('click', advanceSegment);
            const prevBtnEl = document.getElementById('prevBtn');
            if(prevBtnEl) prevBtnEl.addEventListener('click', prevSegment);

            window.addEventListener('keydown', (ev) => {
            // Ignore global shortcuts while export modal is open
            const exportModal = document.getElementById('exportModal');
            if (exportModal && exportModal.classList.contains('show')) {
                return; // let modal handler manage keys
            }
            // Check for Cmd+Enter (Mac) or Ctrl+Enter (Windows/Linux)
            if ((ev.metaKey || ev.ctrlKey) && ev.key === 'Enter') {
                ev.preventDefault();
                showExportModal();
                return;
            }
            
            if (ev.key === 'ArrowDown') {
                ev.preventDefault();
                nextInSegment(1);
            } else if (ev.key === 'ArrowUp') {
                ev.preventDefault();
                nextInSegment(-1);
            } else if (ev.key === 'ArrowRight') {
                ev.preventDefault();
                advanceSegment();
            } else if (ev.key === 'ArrowLeft') {
                ev.preventDefault();
                prevSegment();
            } else if (ev.key === 'Enter' || ev.code === 'Space') {
                ev.preventDefault();
                if (listItems.length) {
                confirmFile(listItems[currentIndex].dataset.file, listItems[currentIndex]);
                }
            }
            });
            // --- end navigation ---

            // ------- load transcript segments incrementally -------
            let segments = [];
            let segIdx = 0;
            let segDivs = [];
            const selections = {}; // segIdx -> array of filenames
            async function loadSegments() {
                const res = await fetch('/segments');
                if (!res.ok) return;
                segments = await res.json();
                renderNextSegment();
            }
            function setCurrentSegment(idx){
                // update segment highlight
                segDivs.forEach(d=>d.classList.remove('current-seg'));
                if(idx>=0 && idx<segDivs.length){
                    segDivs[idx].classList.add('current-seg');
                    const pane = document.getElementById('infoPane');
                    const target = segDivs[idx].getBoundingClientRect().top - pane.getBoundingClientRect().top + pane.scrollTop;
                    pane.scrollTo({top: target, behavior:'smooth'});
                }

                // automatically highlight the first image belonging to this segment
                const firstLi = listItems.find(li => li.dataset.segment === String(idx));
                if(firstLi){
                    highlight(listItems.indexOf(firstLi));\n                    // scroll list so the first item is at top of view\n                    firstLi.scrollIntoView({behavior:'smooth', block:'start'});
                }
                // refresh confirmed state on file list
                listItems.forEach(li=>li.classList.remove('confirmed'));
                const selectedFiles = selections[String(idx)] ?? [];
                const ungroupedFiles = selections['ungrouped'] ?? [];
                listItems.forEach(li=>{
                    const segmentIdx = li.dataset.segment;
                    if(segmentIdx === 'ungrouped' && ungroupedFiles.includes(li.dataset.file)){
                        li.classList.add('confirmed');
                    } else if(segmentIdx === String(idx) && selectedFiles.includes(li.dataset.file)){
                        li.classList.add('confirmed');
                    }
                });
            }
            function renderNextSegment() {
                if (segIdx >= segments.length) return;
                const pane = document.getElementById('infoPane');
                const seg = segments[segIdx];
                const div = document.createElement('div');
                div.className = 'segment';
                const title = document.createElement('div');
                title.className = 'seg-title';
                title.textContent = `${seg.start} ~ ${seg.end}`;
                const p = document.createElement('p');
                p.textContent = seg.text;
                const imgWrap = document.createElement('div');
                imgWrap.className = 'seg-images';
                div.appendChild(title);
                div.appendChild(p);
                div.appendChild(imgWrap);
                pane.appendChild(div);
                segDivs.push(div);
                pane.scrollTop = pane.scrollHeight;
                setCurrentSegment(segIdx);
            }
            // Advance after confirming image for current segment
            function advanceSegment() {
                if(segIdx < segments.length-1){
                    segIdx += 1;
                    if(segDivs.length>segIdx){
                        setCurrentSegment(segIdx);
                    }else{
                        renderNextSegment();
                    }
                }
            }
            function prevSegment(){
                if(segIdx>0){
                    segIdx -=1;
                    setCurrentSegment(segIdx);
                }
            }
            loadSegments();
            // ------- end segments -------

            // ------- Export Modal Functions -------
            function modalKeyHandler(e) {
                const modal = document.getElementById('exportModal');
                if (!modal.classList.contains('show')) return;
                e.stopPropagation();
                if (e.key === 'Enter' || e.code === 'Space') {
                    e.preventDefault();
                    confirmExport();
                } else if (e.key === 'n' || e.key === 'N') {
                    e.preventDefault();
                    hideExportModal();
                }
            }

            function showExportModal() {
                const modal = document.getElementById('exportModal');
                const statsEl = document.getElementById('exportStats');
                
                // Calculate statistics
                let totalSelections = 0;
                let segmentCount = 0;
                let statsText = '';
                
                for (const [key, files] of Object.entries(selections)) {
                    if (files && files.length > 0) {
                        totalSelections += files.length;
                        if (key === 'ungrouped') {
                            statsText += `其他圖片: ${files.length} 張\n`;
                        } else {
                            segmentCount++;
                            const segmentIdx = parseInt(key);
                            const segment = segments[segmentIdx];
                            if (segment) {
                                statsText += `\n\n時間段 ${segment.start}~${segment.end}: ${files.length} 張\n\n\n`;
                            } else {
                                statsText += `\n\n段落 ${key}: ${files.length} 張\n\n\n`;
                            }
                        }
                    }
                }
                
                if (totalSelections === 0) {
                    statsText = '尚未選擇任何圖片';
                    document.getElementById('confirmExportBtn').disabled = true;
                } else {
                    statsText += `\n總計: ${totalSelections} 張圖片, ${segmentCount} 個時間段`;
                    document.getElementById('confirmExportBtn').disabled = false;
                }
                
                statsEl.textContent = statsText;
                // Ensure element can receive keyboard focus for arrow scrolling
                statsEl.setAttribute('tabindex', '-1');
                statsEl.focus();
                // Prevent background page from scrolling while modal open
                document.body.style.overflow = 'hidden';
                modal.classList.add('show');
                // Attach modal-specific key handler with high priority (capture phase)
                document.addEventListener('keydown', modalKeyHandler, true);
            }
            
            function hideExportModal() {
                const modal = document.getElementById('exportModal');
                modal.classList.remove('show');
                // Restore page scroll
                document.body.style.overflow = '';
                // Detach modal-specific key handler
                document.removeEventListener('keydown', modalKeyHandler, true);
            }
            
            async function confirmExport() {
                const confirmBtn = document.getElementById('confirmExportBtn');
                const originalText = confirmBtn.textContent;
                
                try {
                    confirmBtn.disabled = true;
                    confirmBtn.textContent = '匯出中...';
                    
                    const response = await fetch('/export', {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json'
                        },
                        body: JSON.stringify({
                            selections: selections
                        })
                    });
                    
                    const result = await response.json();
                    
                    if (response.ok) {
                        hideExportModal();
                        showToast(`匯出成功！檔案已儲存: ${result.filename}`);
                        console.log('Export result:', result);
                    } else {
                        throw new Error(result.detail || '匯出失敗');
                    }
                    
                } catch (error) {
                    console.error('Export error:', error);
                    showToast(`匯出失敗: ${error.message}`);
                } finally {
                    confirmBtn.disabled = false;
                    confirmBtn.textContent = originalText;
                }
            }
            
            // Close modal when clicking outside
            document.getElementById('exportModal').addEventListener('click', function(e) {
                if (e.target === this) {
                    hideExportModal();
                }
            });
            
            // Close modal with Escape key
            document.addEventListener('keydown', function(e) {
                if (e.key === 'Escape') {
                    const modal = document.getElementById('exportModal');
                    if (modal.classList.contains('show')) {
                        hideExportModal();
                    }
                }
            });
            </script>

        </body> 
    </html>
""", encoding="utf-8",)


# --------------------------------- Main ------------------------------------ #

def _parse_args(argv: List[str] | None = None) -> Settings:
    parser = argparse.ArgumentParser(description="Start image selection server")
    parser.add_argument("--base-dir", required=True, help="Directory containing images")
    parser.add_argument("--refresh-secs", type=int, default=15, help="Rescan interval in seconds")
    parser.add_argument("--port", type=int, default=15687, help="Port to listen on")
    parser.add_argument("--transcript", help="Transcript text file (optional)")
    parser.add_argument("--output-dir", help="Directory to save exported markdown files (default: ./output)")
    ns = parser.parse_args(argv)
    
    # Set default output directory if not provided
    output_dir = ns.output_dir if ns.output_dir else "./output"
    
    return Settings(
        base_dir=pathlib.Path(ns.base_dir).expanduser().resolve(),
        refresh_secs=ns.refresh_secs,
        port=ns.port,
        transcript_path=pathlib.Path(ns.transcript).expanduser().resolve() if ns.transcript else None,
        output_dir=pathlib.Path(output_dir).expanduser().resolve(),
    )

def main() -> None:  # pragma: no cover
    _ensure_templates_exist()
    settings = _parse_args()

    # Defer import to keep top-level lightweight
    import uvicorn  # type: ignore

    uvicorn.run(
        create_app(settings),
        host="127.0.0.1",
        port=settings.port,
        log_level="info",
        reload=False,
    )


if __name__ == "__main__":
    main()