#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BLIP-2 Image Captioning Utility
================================
This script generates captions for one or more images using the BLIP-2 model
from Hugging Face *transformers*.

Key features
------------
1. Loads the model **once** and re-uses it for all images to minimise GPU/CPU
   usage.
2. Provides a simple CLI for captioning individual files, a directory, or a
   glob pattern (e.g. ``frames/*.jpg``).
3. Writes results to **stdout** and, optionally, to a JSON file for downstream
   consumption in the RAG pipeline.
4. Comprehensive error handling and graceful degradation when running on a
   system without GPU support.

Usage examples
--------------
Caption a single file and print the result:

    pipenv run python blip2_caption.py path/to/image.jpg

Caption all ``.png`` files under ``./frames`` and save to ``captions.json``:

    pipenv run python blip2_caption.py ./frames/*.png --out captions.json

Environment variables
---------------------
``MODEL_NAME``  Override the default BLIP-2 model checkpoint.
``DEVICE``      Set the Torch device manually (e.g. ``cpu`` or ``cuda:1``).

All comments and code use ASCII only to comply with project guidelines.
"""
from __future__ import annotations

import argparse
import glob
import json
import logging
import os
import sys
from pathlib import Path
from typing import Iterable, List, Tuple

import torch
from PIL import Image
from transformers import Blip2ForConditionalGeneration, Blip2Processor

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DEFAULT_MODEL = os.getenv("MODEL_NAME", "Salesforce/blip2-opt-2.7b")
DEFAULT_DEVICE = os.getenv(
    "DEVICE",
    "mps" if torch.backends.mps.is_available() else ("cuda" if torch.cuda.is_available() else "cpu"),
)
CAPTION_MAX_LENGTH = 64  # Prevent excessively long captions
BATCH_SIZE = 4           # Tune for performance vs. memory

def _setup_logging() -> None:
    """Configure root logger for console output."""
    logging.basicConfig(
        level=logging.INFO,
        format="[%(levelname)s] %(message)s",
        stream=sys.stdout,
    )

# ---------------------------------------------------------------------------
# Model Loading
# ---------------------------------------------------------------------------

def load_model(
    model_name: str = DEFAULT_MODEL,
    device: str = DEFAULT_DEVICE,
    int4: bool = False,
) -> Tuple[Blip2Processor, Blip2ForConditionalGeneration]:
    """Load BLIP-2 processor and model.

    If *int4* is True and CUDA is available, the model is loaded in 4-bit
    precision using *bitsandbytes* to greatly reduce VRAM.
    """
    logging.info("Loading BLIP-2 model '%s' on device '%s' (int4=%s)...", model_name, device, int4)
    processor = Blip2Processor.from_pretrained(model_name)

    # bitsandbytes 4-bit quantization is only supported on CUDA GPUs
    if int4 and "cuda" not in device:
        logging.warning("4-bit quantization requested but device '%s' is not CUDA; falling back to standard precision.", device)
        int4 = False

    if int4 and "cuda" in device:
        try:
            from transformers import BitsAndBytesConfig  # type: ignore
            bnb_config = BitsAndBytesConfig(
                load_in_4bit=True,
                bnb_4bit_use_double_quant=True,
                bnb_4bit_compute_dtype=torch.float16,
            )
            model = Blip2ForConditionalGeneration.from_pretrained(
                model_name,
                quantization_config=bnb_config,
                device_map="auto",
            )
        except ImportError as exc:
            logging.warning("bitsandbytes not available (%s); falling back to standard precision", exc)
            model = Blip2ForConditionalGeneration.from_pretrained(
                model_name,
                torch_dtype=torch.float16 if "cuda" in device else torch.float32,
            )
            model.to(device)
    else:
        model = Blip2ForConditionalGeneration.from_pretrained(
            model_name,
            torch_dtype=torch.float16 if "cuda" in device else torch.float32,
        )
        model.to(device)

    model.eval()
    return processor, model

# ---------------------------------------------------------------------------
# Caption Generation
# ---------------------------------------------------------------------------

def caption_images(paths: List[Path], processor: Blip2Processor, model: Blip2ForConditionalGeneration, device: str = DEFAULT_DEVICE) -> List[Tuple[str, str]]:
    """Generate captions for *paths*.

    Returns a list of ``(path, caption)`` tuples in the same order as input.
    """
    results: List[Tuple[str, str]] = []
    for i in range(0, len(paths), BATCH_SIZE):
        batch_paths = paths[i : i + BATCH_SIZE]
        images: List[Image.Image] = []
        valid_paths: List[Path] = []
        for p in batch_paths:
            try:
                img = Image.open(p).convert("RGB")
            except Exception as exc:  # pylint: disable=broad-except
                logging.error("Failed to open '%s': %s", p, exc)
                continue
            images.append(img)
            valid_paths.append(p)

        if not images:
            continue

        with torch.no_grad():
            inputs = processor(images=images, return_tensors="pt").to(device)
            generated_ids = model.generate(**inputs, max_length=CAPTION_MAX_LENGTH)
            captions: List[str] = processor.batch_decode(generated_ids, skip_special_tokens=True)

        for path_obj, caption in zip(valid_paths, captions):
            results.append((str(path_obj), caption.strip()))
    return results

# ---------------------------------------------------------------------------
# CLI Helpers
# ---------------------------------------------------------------------------

def _collect_image_paths(patterns: Iterable[str]) -> List[Path]:
    """Resolve *patterns* (files, directories or globs) into image file paths."""
    exts = {".jpg", ".jpeg", ".png", ".bmp", ".gif", ".webp"}
    paths: List[Path] = []
    for pattern in patterns:
        for p in glob.glob(pattern):
            p_path = Path(p)
            if p_path.is_dir():
                paths.extend([fp for fp in p_path.rglob("*") if fp.suffix.lower() in exts])
            elif p_path.suffix.lower() in exts:
                paths.append(p_path)
    unique_paths = sorted(set(paths))
    if not unique_paths:
        logging.warning("No images found for patterns: %s", ", ".join(patterns))
    return unique_paths

# ---------------------------------------------------------------------------
# Main entry
# ---------------------------------------------------------------------------

def main(argv: List[str] | None = None) -> None:
    _setup_logging()

    parser = argparse.ArgumentParser(description="Generate image captions using BLIP-2.")
    parser.add_argument("patterns", nargs="+", help="Files, directories or glob patterns to caption.")
    parser.add_argument("--out", metavar="FILE", help="Save captions as JSON to FILE.")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Model checkpoint (default: {DEFAULT_MODEL})")
    parser.add_argument("--device", default=DEFAULT_DEVICE, help=f"Torch device (default: {DEFAULT_DEVICE})")
    parser.add_argument("--int4", action="store_true", help="Load model in 4-bit precision (CUDA only)")

    args = parser.parse_args(argv)

    image_paths = _collect_image_paths(args.patterns)
    if not image_paths:
        sys.exit(1)

    processor, model = load_model(args.model, args.device, int4=args.int4)
    captions = caption_images(image_paths, processor, model, device=args.device)

    for path_str, caption in captions:
        print(f"{path_str}\t{caption}")

    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as fp:
                json.dump({p: c for p, c in captions}, fp, ensure_ascii=False, indent=2)
        except Exception as exc:  # pylint: disable=broad-except
            logging.error("Failed to write JSON to '%s': %s", args.out, exc)

if __name__ == "__main__":  # pragma: no cover
    main()
