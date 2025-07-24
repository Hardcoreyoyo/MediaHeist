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
        --refresh-secs 15
"""

from __future__ import annotations

import argparse
import logging
import os
import pathlib
import re
import sys
from typing import List, Optional

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


class SelectionPayload(BaseModel):
    filename: str


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
    grouped = {"ungrouped": []}
    
    # Initialize groups for each segment
    for i in range(len(segments)):
        grouped[f"segment_{i}"] = []
    
    for img in images:
        frame_time = parse_frame_timestamp(str(img))
        if frame_time is None:
            grouped["ungrouped"].append(img)
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
        
        if not assigned:
            grouped["ungrouped"].append(img)
    
    return grouped

# --- Transcript parsing ---------------------------------------------------- #

def parse_transcript(path: pathlib.Path) -> List[dict]:
    """Parse transcript file separated by headings of the form
    ### Timestamp: **hh:mm:ss,mmm** ~ **hh:mm:ss,mmm**

    Returns list of dicts with keys: start, end, text.
    """
    content = path.read_text(encoding="utf-8", errors="ignore")
    pattern = re.compile(r"^###\s*Timestamp:\s*\*\*(\d{2}:\d{2}:\d{2},\d{3})\*\*\s*~\s*\*\*(\d{2}:\d{2}:\d{2},\d{3})\*\*", re.MULTILINE)
    matches = list(pattern.finditer(content))
    segments: List[dict] = []
    for idx, match in enumerate(matches):
        start_pos = match.end()
        end_pos = matches[idx + 1].start() if idx + 1 < len(matches) else len(content)
        segment_text = content[start_pos:end_pos].strip()
        segments.append({
            "start": match.group(1),
            "end": match.group(2),
            "text": segment_text,
        })
    return segments


# ------------------------------- App setup --------------------------------- #

def create_app(settings: Settings) -> FastAPI:
    app = FastAPI(title="Image Selector", docs_url=None, redoc_url=None)

    templates = Jinja2Templates(directory=str(_template_dir()))

    # Ensure base dir exists
    if not settings.base_dir.is_dir():
        LOGGER.error("Base directory does not exist: %s", settings.base_dir)
        sys.exit(1)

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
            body { font-family: Arial, sans-serif; margin: 0; padding: 0; }
            .container { display: flex; height: 100vh; }
            #rightPane { flex: 1; display: flex; flex-direction: column; }
            #navBtns { padding:4px; border-top:1px solid #ccc; display:flex; gap:8px; justify-content:center; }
            #navBtns button { padding:4px 8px; cursor:pointer; }
            #infoPane { padding: 0.5rem; border-bottom: 1px solid #ccc; flex: 0 0 30%; max-height: 30%; overflow-y: auto; }
            #fileList { width: 320px; border-right: 1px solid #ccc; overflow-y: auto; padding: 1rem; }
            #fileList ul { list-style: none; margin: 0; padding: 0; }
            #fileList li { cursor: pointer; padding: 4px 2px; user-select: none; }
            #fileList li:hover { background-color: #f0f0f0; }
            .segment-group { margin-bottom: 1rem; }
            .segment-header { 
                font-weight: bold; 
                color: #333; 
                background-color: #f5f5f5; 
                padding: 6px 8px; 
                margin: 4px 0; 
                border-left: 3px solid #007acc;
                font-size: 0.9em;
            }
            .segment-header.active { background-color: #e6f3ff; border-left-color: #0056b3; }
            .segment-images { margin-left: 8px; }
            .segment-images li { padding-left: 8px; border-left: 1px solid #e0e0e0; }
            .selected { background-color: #d0e0ff; }
            .confirmed { background-color: #cccccc; }
            #toast { position: fixed; right: 1rem; bottom: 1rem; background: rgba(0,0,0,0.8); color:#fff; padding:8px 12px; border-radius:4px; opacity:0; transition: opacity .3s; pointer-events:none; }
            #toast.show { opacity:1; }
            #preview { flex: 1; display: flex; justify-content: center; align-items: flex-start; padding: 1rem; }
            #preview img { height: auto; width: auto; max-width: 100%; max-height: 100%; }
            .segment { margin-bottom: 1rem; padding-bottom: 0.5rem; border-bottom: 1px solid #e0e0e0; }
            .seg-title { font-weight: bold; color: #333; margin-bottom: 0.25rem; }
            .seg-images { display:flex; flex-wrap:wrap; gap:4px; margin-top:4px; }
            .seg-images img { max-width:100px; height:auto; border:1px solid #ccc; }
            .current-seg { background-color:#fffbe6; }
        </style>
        </head>

        <body>
            <h2 style=\"margin:0; padding:1rem;\">Select an image</h2>
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
                            <li data-file="{{ img }}" data-segment="-1">{{ img }}</li>
                            {% endfor %}
                        </ul>
                    </div>
                    {% endif %}
                {% else %}
                    <!-- Fallback: show all images without grouping -->
                    <ul>
                    {% for img in images %}
                    <li data-file="{{ img }}" data-segment="-1">{{ img }}</li>
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
            const segmentIdx = li ? parseInt(li.dataset.segment) : segIdx;
            const actualSegIdx = segmentIdx >= 0 ? segmentIdx : segIdx;
            const selArr = (selections[actualSegIdx] ??= []);
            const wrap = segDivs[actualSegIdx]?.querySelector('.seg-images');
            const idx = selArr.indexOf(file);
            if(idx === -1){
                // add
                postSelection(file);
                selArr.push(file);
                if(li) li.classList.add('confirmed');
                showToast('已添加內容');
                if(wrap){
                    const thumb = document.createElement('img');
                    thumb.src = '/static/' + file;
                    thumb.dataset.file = file;
                    wrap.appendChild(thumb);
                }
            }else{
                // remove
                selArr.splice(idx,1);
                if(li) li.classList.remove('confirmed');
                showToast('已移除');
                if(wrap){
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
            const segmentIdx = parseInt(li.dataset.segment);
            if (segmentIdx >= 0) {
                const header = segmentHeaders.find(h => parseInt(h.dataset.segment) === segmentIdx);
                if (header) header.classList.add('active');
            }
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
            if (ev.key === 'ArrowDown') {
                ev.preventDefault();
                highlight(currentIndex + 1);
            } else if (ev.key === 'ArrowUp') {
                ev.preventDefault();
                highlight(currentIndex - 1);
            } else if (ev.key === 'ArrowRight') {
                ev.preventDefault();
                advanceSegment();
            } else if (ev.key === 'ArrowLeft') {
                ev.preventDefault();
                prevSegment();
            } else if (ev.key === 'Enter') {
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
                    segDivs[idx].scrollIntoView({behavior:'smooth',block:'nearest'});
                }
                // refresh confirmed state on file list
                listItems.forEach(li=>li.classList.remove('confirmed'));
                const selectedFiles = selections[idx] ?? [];
                listItems.forEach(li=>{
                    if(selectedFiles.includes(li.dataset.file)){
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
            </script>

        </body> 
    </html>
""", encoding="utf-8",)


# --------------------------------- Main ------------------------------------ #

def _parse_args(argv: List[str] | None = None) -> Settings:
    parser = argparse.ArgumentParser(description="Start image selection server")
    parser.add_argument("--base-dir", required=True, help="Directory containing images")
    parser.add_argument("--refresh-secs", type=int, default=15, help="Rescan interval in seconds")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on")
    parser.add_argument("--transcript", help="Transcript text file (optional)")
    ns = parser.parse_args(argv)
    return Settings(
        base_dir=pathlib.Path(ns.base_dir).expanduser().resolve(),
        refresh_secs=ns.refresh_secs,
        port=ns.port,
        transcript_path=pathlib.Path(ns.transcript).expanduser().resolve() if ns.transcript else None,
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