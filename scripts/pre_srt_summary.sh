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

SRT="$DIR/transcript.srt"
PROMPT_FILE="$(cd "$(dirname "$0")/.." && pwd)/prompt.txt"
# MODEL="${PRE_SUMMARY_MODEL:-qwen3-4b-tune:latest}"

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
# Smart chunking logic for large files
# -----------------------------------------------------------------------------
SYS_PROMPT="$(cat "$PROMPT_FILE")"
USER_PROMPT="$(cat "$SRT")"

# Calculate input size
INPUT_SIZE=${#USER_PROMPT}
INPUT_SIZE_KB=$((INPUT_SIZE / 1024))
MAX_SAFE_SIZE_KB=300  # Conservative limit to avoid API issues

info "📊 Input analysis:"
info "   - System prompt: ${#SYS_PROMPT} chars"
info "   - User input: ${INPUT_SIZE} chars (${INPUT_SIZE_KB}KB)"


info "🚀 Calling Google Gemini API..."
info "📡 Endpoint: ${GOOGLE_GEMINI_HOST:-https://generativelanguage.googleapis.com/v1beta/models}/${GEMINI_MODEL_ID}/generateContent"
info "--------------------------------------------------------------------------------"

# Endpoint can be overridden with OLLAMA_HOST (default: http://localhost:11434)
# OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
GOOGLE_GEMINI_HOST="${GOOGLE_GEMINI_HOST:-https://generativelanguage.googleapis.com/v1beta/models}"

# Base64-encode the transcript (USER_PROMPT) because Gemini inlineData expects base64
# ENCODED_SRT=$(base64 < "$SRT" | tr -d '\n')

# Check payload size before building JSON
info "Input sizes -------------------------------------------------------------------------"
info "System prompt:"
info "${#SYS_PROMPT}"
info " ------------------------------------------------------------------------------------"
info "User input:"
info "${#USER_PROMPT}"

# Build JSON payload in Gemini format with size optimization
JSON_PAYLOAD=$(jq -nc \
  --arg user_input "$USER_PROMPT" \
  --arg instructions "$SYS_PROMPT" \
  '{
    system_instruction: {
      parts: [
        {
          text: $instructions
        }
      ]
    },
    contents: [
      {
        role: "user",
        parts: [
          { text: $user_input }
        ]
      }
    ],
    generationConfig: {
      temperature: 0.3,
      responseMimeType: "text/plain",
      maxOutputTokens: 320000
    }
  }')

# Check final payload size
PAYLOAD_SIZE=${#JSON_PAYLOAD}
info "📦 Final JSON payload size: $PAYLOAD_SIZE bytes"

# Warn if payload is large (approaching 20MB limit)
if [ $PAYLOAD_SIZE -gt 15000000 ]; then
  error "⚠️  WARNING: Payload size ($PAYLOAD_SIZE bytes) is approaching Gemini API limit (20MB)"
  error "Consider splitting the input into smaller chunks"
fi

# -----------------------------------------------------------------------------
# Enhanced curl function with retry mechanism and better error handling
# -----------------------------------------------------------------------------
call_gemini_api() {
  local payload="$1"
  local max_retries=3
  local retry_count=0
  local backoff_base=2
  
  while [ $retry_count -lt $max_retries ]; do
    info "Attempt $((retry_count + 1))/$max_retries - Calling Gemini API..."
    
    # Create temporary file for payload to avoid command line length limits
    local temp_payload=$(mktemp)
    printf '%s' "$payload" > "$temp_payload"
    
    # Enhanced curl with better timeout and chunked transfer
    set -x
    local response=$(curl -sS \
      --connect-timeout 30 \
      --max-time 300 \
      --retry 0 \
      --fail-with-body \
      -H "Content-Type: application/json" \
      -H "Transfer-Encoding: chunked" \
      --data-binary "@$temp_payload" \
      "$GOOGLE_GEMINI_HOST/${GEMINI_MODEL_ID}:generateContent?key=${GEMINI_API_KEY}" 2>&1)
    local curl_exit_code=$?
    set +x
    
    # Clean up temp file
    rm -f "$temp_payload"
    
    # Check if request was successful
    if [ $curl_exit_code -eq 0 ]; then
      # Validate JSON response
      if echo "$response" | jq -e '.candidates[0].content.parts[]?.text' >/dev/null 2>&1; then
        info "✅ API call successful on attempt $((retry_count + 1))"
        echo "$response"
        return 0
      else
        error "❌ Invalid JSON response: $response"
      fi
    else
      error "❌ curl failed with exit code $curl_exit_code: $response"
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      local wait_time=$((backoff_base ** retry_count))
      info "⏳ Waiting ${wait_time}s before retry..."
      sleep $wait_time
    fi
  done
  
  error "❌ All $max_retries attempts failed"
  return 1
}

# Call the enhanced API function
RESP_JSON=$(call_gemini_api "$JSON_PAYLOAD")

# Extract assistant message content (first candidate, concatenate all part texts)
info "Gemini response:"
# echo "$RESP_JSON"
RESP=$(printf '%s\n' "$RESP_JSON" | jq -r '.candidates[0].content.parts[]?.text // empty')


# -----------------------------------------------------------------------------
# Post-process: strip out <think>...</think> blocks (including newlines)
# -----------------------------------------------------------------------------
# Remove any lines between (and including) <think> and </think>
# RESP=$(printf '%s\n' "$RESP" | sed '/<think>/,/<\/think>/d')

# -----------------------------------------------------------------------------
# Save output
# -----------------------------------------------------------------------------
SUMMARY_DIR="$(pwd)/summary"
mkdir -p "$SUMMARY_DIR"
HASH="$(basename "$DIR")"
OUT_MD="$SUMMARY_DIR/pre_${HASH}.md"

printf "%s\n" "$RESP" > "$OUT_MD"
# printf "%s\n" "$RESP_JSON" > "$OUT_MD.json"

touch "$DIR/pre_srt_summary.done"
info "Pre-SRT summary saved to $OUT_MD"
