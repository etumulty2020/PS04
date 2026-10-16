#!/usr/bin/env bash
# Shared provider settings; source from each AI component after loading .env.
# Default to ChatGPT-authenticated Codex. Other providers are explicit.
case "${LLM_PROVIDER:-codex}" in
  codex)
    export LLM_PROVIDER=codex
    unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL OPENAI_INPUT_PRICE OPENAI_OUTPUT_PRICE
    export OPENAI_MODEL="${CODEX_MODEL:-codex-configured-default}"
    export TRANSCRIBE_ENGINE=local
    ;;
  claude)
    export LLM_PROVIDER=claude
    unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL OPENAI_INPUT_PRICE OPENAI_OUTPUT_PRICE
    export CLAUDE_MODEL="${CLAUDE_MODEL:-claude-haiku-5-5}" OPENAI_MODEL="${CLAUDE_MODEL:-claude-haiku-5-5}"
    export TRANSCRIBE_ENGINE=local
    ;;
  ollama)
    export OPENAI_BASE_URL=http://127.0.0.1:11434/v1
    export OPENAI_API_KEY=ollama
    export OPENAI_MODEL="${OLLAMA_MODEL:-qwen2.5:7b}"
    export OPENAI_INPUT_PRICE=0 OPENAI_OUTPUT_PRICE=0
    export TRANSCRIBE_ENGINE=local
    ;;
  openai)
    export OPENAI_BASE_URL=https://api.openai.com/v1
    ;;
  *) echo 'model settings: LLM_PROVIDER must be codex, claude, ollama, or openai' >&2; return 2 ;;
esac

# Keep component-owned prompts and parsing; adapt only model transport.
model_request() {
  if [ "${LLM_PROVIDER:-codex}" = codex ] || [ "$LLM_PROVIDER" = claude ]; then
    python3 "$REPO/helpers/codex_request.py" "$1"
  else
    curl -sS --retry 3 --max-time 900 \
      -H @<(printf 'Authorization: Bearer %s\n' "$OPENAI_API_KEY") \
      -H 'Content-Type: application/json' -d @- -o "$1" \
      "${OPENAI_BASE_URL:-https://api.openai.com/v1}/chat/completions"
  fi
}
