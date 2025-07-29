# MediaHeist

MediaHeist is a modular, high-performance automation toolkit for downloading, processing, and summarizing audio-visual content, with a focus on YouTube videos and local media files. It provides a robust pipeline covering download, audio extraction, keyframe analysis, subtitle generation, and AI-powered summarization, all orchestrated via a Makefile and extensible Bash scripts.

---

## Features

- **Flexible Input**: Supports YouTube URLs, video IDs, local file paths, and batch lists.
- **Automated Workflow**: Download/copy videos, extract audio, keyframe extraction, subtitle generation, and markdown summarization.
- **Parallel & Batch Processing**: Efficiently handles large-scale datasets with parallel job support.
- **Robust Logging & Error Handling**: Centralized logs for every run, strict error propagation, and clear process markers.
- **Environment & Dependency Management**: Uses `.env` for configuration, supports override via environment variables, and validates all required dependencies.
- **Cross-Platform Packaging**: Multiple binary packaging options (Go, makeself, SHC) for easy deployment.
- **AI Integration**: Supports both local LLM (Ollama) and Google Gemini API for transcript summarization.

---

## Directory Structure

```
MediaHeist/
├── Makefile
├── build_binary.sh
├── scripts/
│   ├── audio.sh
│   ├── common.sh
│   ├── download.sh
│   ├── frames.sh
│   ├── pre_srt_summary.sh
│   └── transcribe.sh
├── cmd/
│   └── mediaheist/
│       └── main.go
├── summary/
├── logs/
└── .env
```

---

## Quick Start

### 1. Prerequisites

- **System**: macOS, Linux, or Windows (WSL recommended)
- **Dependencies**:
  - `yt-dlp`
  - `ffmpeg`, `ffprobe`
  - `jq`, `curl`
  - `ImageMagick` (for phash)
  - `GNU parallel` or `xargs`
  - `Go` (for binary build)
  - `ollama` (optional, for local LLM summarization)
  - `whisper.cpp` (for fallback speech-to-text)

### 2. Configuration

Copy and edit `.env` as needed:

```bash
cp .env.example .env
# Edit .env to set:
# GEMINI_API_KEY, GEMINI_MODEL_ID, WHISPER_BIN, WHISPER_MODEL, etc.
```

### 3. Usage Examples

#### Download and Process a Single Video

```bash
make download URL="https://youtu.be/xxxx"
make all URL="https://youtu.be/xxxx"
```

#### Process a Local Video File

```bash
make download URL="/path/to/video.mp4"
make all URL="/path/to/video.mp4"
```

#### Batch Processing

```bash
make download LIST=urls.txt
make all LIST=urls.txt MAX_JOBS=8
```

#### Build Go Binary

```bash
./build_binary.sh
```

---

## Workflow Overview

1. **Download/Copy Video**: Detects input type, downloads via `yt-dlp` or copies local file, and records mapping.
2. **Audio Extraction**: Uses `ffmpeg` to produce a 16kHz mono MP3.
3. **Keyframe Extraction**: Dynamically segments video, extracts keyframes, removes duplicates (based on phash).
4. **Subtitle Generation**: Downloads YouTube CC subtitles (priority: zh-TW, zh, zh-CN, en); falls back to `whisper.cpp` if unavailable.
5. **Summarization**: Feeds transcript to Gemini API or local LLM to generate a Markdown summary.
6. **Logging**: All stages log to a timestamped file in `logs/`.

---

## Packaging & Deployment

- **Go Binary**: Use `build_binary.sh` to build a standalone binary for your platform.
- **Makeself**: (Recommended for easy distribution) Use `build_package.sh` (not shown above) for self-extracting installer.
- **SHC**: Use `build_shc_binary.sh` to compile shell scripts into binaries.

All packaging scripts ensure scripts and dependencies are bundled, and maintain compatibility with the Makefile workflow.

---

## Environment Variables

Key variables (set in `.env` or exported):

- `GEMINI_API_KEY`, `GEMINI_MODEL_ID`: For Gemini summarization.
- `WHISPER_BIN`, `WHISPER_MODEL`: For speech-to-text fallback.
- `MAX_JOBS`: Controls parallel processing.
- `YTDLP`, `FFMPEG`: Tool overrides.

---

## Logging & Error Handling

- All scripts redirect output to both console and a central log file.
- Strict error handling (`set -eEuo pipefail`) throughout all scripts.
- Each processing stage produces `.done` marker files for workflow tracking.

---

## Extending & Customizing

- Add new scripts to `scripts/` and integrate with the Makefile.
- Override tool paths or parameters via `.env` or environment variables.
- Easily swap LLM models or endpoints in `pre_srt_summary.sh`.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/)
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- [Google Gemini](https://ai.google.dev/)

---

## Contact

For questions, suggestions, or contributions, please open an issue or pull request on GitHub.

---
