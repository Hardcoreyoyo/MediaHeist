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
import sys
from typing import List

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
        return templates.TemplateResponse(
            "gallery.html",
            {
                "request": request,
                "images": image_cache,
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

    return app


# ------------------------------ Templates ---------------------------------- #

def _template_dir() -> pathlib.Path:
    """Return directory path containing HTML templates bundled with this file."""
    return pathlib.Path(__file__).with_suffix("").with_name("templates")


def _ensure_templates_exist() -> None:
    """Create minimal gallery template next to this script if missing."""
    tpl_dir = _template_dir()
    if tpl_dir.exists():
        return
    tpl_dir.mkdir(parents=True, exist_ok=True)
    (tpl_dir / "gallery.html").write_text(
        """<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\" />
<title>Image Selector</title>
<style>
body { font-family: Arial, sans-serif; margin: 0; padding: 1rem; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); grid-gap: 8px; }
.grid img { width: 100%; height: auto; cursor: pointer; transition: box-shadow .2s; }
.grid img:hover { box-shadow: 0 0 8px rgba(0,0,0,.5); }
</style>
</head>
<body>
<h2>Click an image to select</h2>
<div class=\"grid\">
{% for img in images %}
  <img src=\"/static/{{ img }}\" alt=\"{{ img }}\" data-file=\"{{ img }}\" />
{% endfor %}
</div>
<script>
async function postSelection(file) {
  const res = await fetch('/select', {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({filename: file})});
  if (res.ok) { alert('Selected: ' + file); }
  else { alert('Error: ' + (await res.text())); }
}

document.querySelectorAll('img').forEach(img => {
  img.addEventListener('click', () => postSelection(img.dataset.file));
});
</script>
</body>
</html>""",
        encoding="utf-8",
    )


# --------------------------------- Main ------------------------------------ #

def _parse_args(argv: List[str] | None = None) -> Settings:
    parser = argparse.ArgumentParser(description="Start image selection server")
    parser.add_argument("--base-dir", required=True, help="Directory containing images")
    parser.add_argument("--refresh-secs", type=int, default=15, help="Rescan interval in seconds")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on")
    ns = parser.parse_args(argv)
    return Settings(
        base_dir=pathlib.Path(ns.base_dir).expanduser().resolve(),
        refresh_secs=ns.refresh_secs,
        port=ns.port,
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
