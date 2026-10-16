#!/usr/bin/env bash
# Entry point for The Road to Mammoth pipeline.
#   bash run.sh                      start a new run (bash run.sh --mode replay labels it a replay)
#   bash run.sh --package RUN_DIR    after you approve a run: recheck it and build its package
#
# A new run: checks the settings, creates runs/RUN_ID/ with run.json and copies of config/ and
# prompts/ (every step reads these copies), opens the evidence store, runs the collection and
# series workflows, and always saves summary.json last. It ends "awaiting_review" when the
# drafts pass the content checks.
# --package: reruns the content checks; if approval.json is missing or out of date, asks you to
# type your decision, name, and notes and saves approval.json; then builds the package if the
# approval matches and refreshes summary.json. It never changes drafts, briefs, evidence, or the
# saved copies.
# Exit: 0 awaiting_review or ready_for_production, 1 failed or packaging blocked, 2 bad setup.
set -uo pipefail
cd "$(dirname "$0")"

# Load settings such as OPENAI_API_KEY from .env (gitignored; plain text, one KEY=value per line).
# Read as data, never run as shell code; anything already set in the environment wins.
# The key is only ever passed to curl through a file descriptor, never on a command line.
if [ -f .env ]; then
  [ -z "$(find .env -perm +044)" ] || echo "run.sh: .env is readable by other users; run: chmod 600 .env" >&2
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[3]}"
    [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
    [ -n "${!name+x}" ] || export "$name=$value"
  done < .env
  unset line name value
fi

source helpers/model_settings.sh || exit 2

# Save summary.json, print it, and exit. A second argument of 1 forces exit 1.
summarize() {
  bash reporting/summarize_run.sh "$1" > "$1/summary.json" || exit 1
  cat "$1/summary.json"
  status="$(jq -r .status "$1/summary.json")"
  echo "run.sh: $1 finished with status $status" >&2
  [ "${2:-0}" -eq 0 ] && [ "$status" != failed ] && exit 0
  exit 1
}

# --package RUN_DIR
if [ "${1:-}" = --package ]; then
  RUN_DIR="${2%/}"
  [ -f "$RUN_DIR/run.json" ] || { echo "run.sh: $RUN_DIR is not a run folder" >&2; exit 2; }
  bash review/check_content.sh "$RUN_DIR" > "$RUN_DIR/review.json"
  review_id="$(jq -r .review_id "$RUN_DIR/review.json")"

  # Ask for your approval when the checks passed but approval.json is missing or is for an
  # older version of the drafts. Only asks when someone is typing at a terminal.
  if [ -t 0 ] && [ "$(jq .passed "$RUN_DIR/review.json")" = true ] \
     && [ "$(jq -r .review_id "$RUN_DIR/approval.json" 2> /dev/null)" != "$review_id" ]; then
    echo "The content checks passed. Warnings to look at:"
    jq -r '.issues[] | "  - \(.artifact): \(.message)"' "$RUN_DIR/review.json"
    echo "Drafts to read: $RUN_DIR/articles/ and $RUN_DIR/video_scripts/"
    read -r -p "Have you read them? Type approve or revise: " decision
    decision="$(echo "$decision" | tr -d ' \r' | tr '[:upper:]' '[:lower:]')"    # accept " Approve" too
    case "$decision" in approve|revise) ;; *) echo "run.sh: no approval recorded" >&2; exit 1 ;; esac
    read -r -p "Your name: " reviewer
    read -r -p "Corrections you made and why (one line): " notes
    reviewer="${reviewer%$'\r'}"; notes="${notes%$'\r'}"
    jq -n --arg id "$review_id" --arg decision "$decision" --arg reviewer "$reviewer" --arg notes "$notes" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{review_id: $id, decision: $decision, reviewer: $reviewer, reviewed_at: $at, notes: $notes}' \
      > "$RUN_DIR/approval.json"
    echo "Saved $RUN_DIR/approval.json"
  fi

  bash publishing/prepare_package.sh "$RUN_DIR" > /dev/null || summarize "$RUN_DIR" 1
  summarize "$RUN_DIR"
fi

# Verify Codex login before downloading source material.
if [ "${LLM_PROVIDER:-codex}" = codex ]; then
  command -v codex > /dev/null || { echo 'run.sh: install Codex CLI, then run codex login' >&2; exit 2; }
  codex_auth="$(env -u OPENAI_API_KEY -u CODEX_API_KEY codex login status 2>&1)"
  [[ "$codex_auth" == *"Logged in using ChatGPT"* ]] || { echo 'run.sh: run codex login and sign in with ChatGPT' >&2; exit 2; }
  unset codex_auth
fi

# Check local inference before downloading source material.
if [ "${LLM_PROVIDER:-codex}" = ollama ]; then
  if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags | jq -e --arg model "$OPENAI_MODEL" 'any(.models[]?; .name == $model)' > /dev/null; then
    echo "run.sh: start Ollama and install the local model: ollama pull $OPENAI_MODEL" >&2
    exit 2
  fi
fi

# New run: check the settings first, so a mistake is caught before hours of collecting.
MODE=live
[ $# -eq 0 ] || MODE="${2:-}"
[ $# -eq 0 ] || [ "$1" = --mode ] || MODE=invalid
case "$MODE" in live|replay) ;; *) echo "usage: bash run.sh [--mode replay] | bash run.sh --package RUN_DIR" >&2; exit 2 ;; esac
problems=""
jq -e '[.publication_name, .topic, .audience, .central_question] | all(type == "string" and . != "")' config/project.json > /dev/null 2>&1 \
  || problems+="config/project.json needs publication_name, topic, audience, and central_question"$'\n'
jq -e 'all(.[]; .source_id and .publisher_id and .url and (.kind == "feed" or .kind == "youtube" or .kind == "podcast"))' \
  config/sources.json > /dev/null 2>&1 || problems+="config/sources.json: every source needs source_id, publisher_id, kind, url"$'\n'
for f in config/editorial_policy.md prompts/select_items.md prompts/create_briefs.md prompts/write_articles.md prompts/write_video_scripts.md; do
  [ -s "$f" ] || problems+="$f is missing or empty"$'\n'
done
{ [ "${LLM_PROVIDER:-codex}" = codex ] || [ "$LLM_PROVIDER" = claude ] || [ -n "${OPENAI_API_KEY:-}" ]; } && [ -n "${OPENAI_MODEL:-}" ] || problems+="set OPENAI_API_KEY and OPENAI_MODEL"$'\n'
if [ -n "$problems" ]; then printf '%s' "$problems" | sed 's/^/run.sh: /' >&2; exit 2; fi

# Create the run folder, run.json (the as-of date is captured once, here), and the saved copies.
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_DIR="runs/run-$(date -u +%Y%m%dT%H%M%SZ)"
previous="$(ls -d runs/run-* 2> /dev/null | tail -1 | xargs -n1 basename 2> /dev/null)"
mkdir -p "$RUN_DIR/logs"
jq -n --arg id "$(basename "$RUN_DIR")" --arg started "$started_at" --arg mode "$MODE" --arg prev "$previous" --arg provider "${LLM_PROVIDER:-codex}" --arg model "$OPENAI_MODEL" \
  '{run_id: $id, started_at: $started, as_of_date: $started[0:10], mode: $mode, model_provider: $provider, model: $model,
    previous_run_id: (if $prev == "" then null else $prev end)}' > "$RUN_DIR/run.json"
cp -R config "$RUN_DIR/config"
cp -R prompts "$RUN_DIR/prompts"
echo "run.sh: started $RUN_DIR" >&2

# Open the evidence store, then run both workflows. Collection problems are recorded but the
# run continues; the series workflow stops itself if the evidence is not enough.
bash data/store.sh init || summarize "$RUN_DIR" 1
bash workflows/collect_sources.sh "$RUN_DIR"
bash workflows/create_series.sh "$RUN_DIR"
summarize "$RUN_DIR"
