#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pre_srt_summary.sh - Generate an initial markdown summary from transcript SRT
#                     using a local LLM (default: ollama qwen3:4b).
# -----------------------------------------------------------------------------
#   $1 : <hashdir> path (e.g. src/abcdef1234/)
# Produces: summary/pre_<hash>.md and marks <hashdir>/pre_srt_summary.done
# -----------------------------------------------------------------------------
# Requirements:
#   1. `ollama` CLI installed and model pulled: `ollama pull qwen3:4b`
#   2. `prompt.txt` located at repository root containing system/user prompts
# -----------------------------------------------------------------------------

set -eEuo pipefail

source "$(dirname "$0")/common.sh"

DIR="${1:-}"
if [[ -z "$DIR" ]]; then
  error "Usage: $0 <hashdir>"; exit 1; fi

SRT="$DIR/transcript.srt.srt"
PROMPT_FILE="$(cd "$(dirname "$0")/.." && pwd)/prompt.txt"
MODEL="${PRE_SUMMARY_MODEL:-qwen3-4b-tune:latest}"

# qwen3-4b-tune:latest
# qwen2.5vl:7b-q4_K_M         
# qwen2.5vl:3b-q4_K_M         
# llava:7b-v1.6-mistral-q4_K_M
# yi:6b-200k                  
# llama3.2:3b                 
# qwen3:4b                    
# deepseek-r1:1.5b            
# gemma3:4b                   


# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
[ -f "$SRT" ]        || { error "Missing transcript: $SRT"; exit 1; }
[ -f "$PROMPT_FILE" ] || { error "Missing prompt file: $PROMPT_FILE"; exit 1; }
# Require necessary command-line tools
command -v curl >/dev/null 2>&1 || { error "curl not found"; exit 1; }
command -v jq   >/dev/null 2>&1 || { error "jq not found"; exit 1; }

# -----------------------------------------------------------------------------
# Build prompt and invoke LLM
# -----------------------------------------------------------------------------
info "Generating pre-SRT summary for $(basename "$DIR") using $MODEL"
SYS_PROMPT="$(cat "$PROMPT_FILE")"
USER_PROMPT="$(cat "$SRT")"

if [[ "${DEBUG:-0}" == "1" ]]; then
  info "Prompt file loaded (${#SYS_PROMPT} chars)"
  info "SRT loaded (${#USER_PROMPT} chars)"
fi

info "Prompt content: "
info "$SYS_PROMPT"
info "SRT content: "
info "$USER_PROMPT"
info "--------------------------------------------------------------------------------"
info "Calling Ollama API via curl at ${OLLAMA_HOST:-http://localhost:11434}/api/chat"
info "--------------------------------------------------------------------------------"

# Endpoint can be overridden with OLLAMA_HOST (default: http://localhost:11434)
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

# Build JSON payload safely using jq to avoid quoting issues
JSON_PAYLOAD=$(jq -n \
  --arg model "$MODEL" \
  --arg sys "$SYS_PROMPT" \
  --arg user "$USER_PROMPT" \
  '{model:$model, stream:false, messages:[{role:"system",content:$sys},{role:"user",content:$user}]}' )

set -x
RESP_JSON=$(curl -sS -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  "$OLLAMA_HOST/api/chat")
set +x

# Extract assistant message content
RESP=$(printf '%s\n' "$RESP_JSON" | jq -r '.message.content // empty')

# -----------------------------------------------------------------------------
# Post-process: strip out <think>...</think> blocks (including newlines)
# -----------------------------------------------------------------------------
# Remove any lines between (and including) <think> and </think>
RESP=$(printf '%s\n' "$RESP" | sed '/<think>/,/<\/think>/d')

# -----------------------------------------------------------------------------
# Save output
# -----------------------------------------------------------------------------
SUMMARY_DIR="$(pwd)/summary"
mkdir -p "$SUMMARY_DIR"
HASH="$(basename "$DIR")"
OUT_MD="$SUMMARY_DIR/pre_${HASH}.md"

printf "%s\n" "$RESP" > "$OUT_MD"

touch "$DIR/pre_srt_summary.done"
info "Pre-SRT summary saved to $OUT_MD"
