#!/usr/bin/env bash
# Editorial selection: the AI decides accept, reject, or defer for every eligible item.
#   bash editorial/select_items.sh RUN_DIR < eligible.jsonl > decisions.jsonl
# Items are sent in batches, one request per batch:
#   instructions = prompts/select_items.md + config/editorial_policy.md + config/project.json
#                  (the copies saved in RUN_DIR)
#   message      = for each item: its details, its source's notes, and its full text or transcript
# and prints {item_id, version_id, decision, reason, piece_ids} for each item.
# A batch holds at most SELECT_BATCH_ITEMS items (default 10) and SELECT_BATCH_CHARS characters
# of message (default 120000); an item larger than that is sent alone.
# Needs OPENAI_API_KEY and OPENAI_MODEL. Optional OPENAI_INPUT_PRICE / OPENAI_OUTPUT_PRICE
# ($ per million tokens) turn on cost estimates. Raw replies are kept in RUN_DIR/logs/select_items/.
# Exit: 0 every item decided, 1 some items failed (the rest are still printed), 2 bad setup.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/helpers/model_settings.sh" || exit 2
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR < eligible.jsonl" >&2; exit 2; }
{ [ "${LLM_PROVIDER:-codex}" = codex ] || [ "$LLM_PROVIDER" = claude ] || [ -n "${OPENAI_API_KEY:-}" ]; } && [ -n "${OPENAI_MODEL:-}" ] || { echo "select_items: set OPENAI_API_KEY and OPENAI_MODEL" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$RUN_DIR/logs/select_items"
: > "$tmp/errors"

# The instructions are the same for every item.
cat "$RUN_DIR/prompts/select_items.md" "$RUN_DIR/config/editorial_policy.md" "$RUN_DIR/config/project.json" > "$tmp/instructions"

BATCH_ITEMS="${SELECT_BATCH_ITEMS:-10}"
BATCH_CHARS="${SELECT_BATCH_CHARS:-120000}"
total=0; decided=0; tokens_in=0; tokens_out=0
: > "$tmp/batch"; : > "$tmp/message"

# Send the items in $tmp/batch (whose blocks are in $tmp/message) as one request,
# then print a decision for each item the reply decided validly.
ask_batch() {
  local count reply item item_id version_id decision
  count="$(wc -l < "$tmp/batch" | tr -d ' ')"
  [ "$count" -gt 0 ] || return 0
  reply="$RUN_DIR/logs/select_items/$(jq -r .item_id "$tmp/batch" | shasum | cut -c1-16).json"
  echo "select_items: asking about $count items ($(wc -c < "$tmp/message" | tr -d ' ') characters)" >&2

  jq -n --arg model "$OPENAI_MODEL" --rawfile instructions "$tmp/instructions" --rawfile message "$tmp/message" \
    '{model: $model, messages: [{role: "system", content: $instructions}, {role: "user", content: $message}]}' \
  | model_request "$reply"
  tokens_in=$((tokens_in + $(jq '.usage.prompt_tokens // 0' "$reply" 2> /dev/null || echo 0)))
  tokens_out=$((tokens_out + $(jq '.usage.completion_tokens // 0' "$reply" 2> /dev/null || echo 0)))

  # The reply's answers: read as a JSON stream (or array) if it parses, otherwise line by line,
  # ignoring anything that is not a JSON object.
  jq -r '.choices[0].message.content // empty' "$reply" 2> /dev/null | sed '/^```/d' > "$tmp/content"
  jq -c 'if type == "array" then .[] else . end | objects' "$tmp/content" > "$tmp/answers" 2> /dev/null \
    || jq -c -R 'fromjson? | objects' "$tmp/content" > "$tmp/answers" 2> /dev/null

  # Keep a decision only if it is valid. Answers are matched by item_id, not by position;
  # item_id and version_id always come from the input, and piece_ids is emptied for
  # rejected or deferred items.
  while IFS= read -r item; do
    item_id="$(jq -r .item_id <<< "$item")"
    version_id="$(jq -r .version_id <<< "$item")"
    if decision="$(jq -c -e -s --arg id "$item_id" --arg v "$version_id" \
         'map(select(.item_id == $id)) | .[0] // empty
          | select(.decision == "accept" or .decision == "reject" or .decision == "defer") | select((.reason // "") != "")
          | {item_id: $id, version_id: $v, decision, reason,
             piece_ids: (if .decision == "accept" then [.piece_ids[]? | select(. == "01" or . == "02" or . == "03")] else [] end)}' \
         "$tmp/answers" 2> /dev/null)"; then
      echo "$decision"; decided=$((decided + 1))
      echo "select_items: $(jq -r .decision <<< "$decision") $item_id" >&2
    else
      echo "$item_id: no valid decision (reply saved in $reply)" | tee -a "$tmp/errors" >&2
    fi
  done < "$tmp/batch"
  : > "$tmp/batch"; : > "$tmp/message"
}

while IFS= read -r item; do
  total=$((total + 1))
  item_id="$(jq -r .item_id <<< "$item")"

  # The item's block: item details + the source's notes from sources.json, then the full text.
  {
    echo "===== ITEM $item_id ====="
    jq --slurpfile sources "$RUN_DIR/config/sources.json" \
      '. as $i | {item_id, version_id, kind, publisher_id, title, url, published_at,
                  source_notes: ($sources[0][] | select(.source_id == $i.source_id) | {perspective, notes})}' <<< "$item"
    echo "## Item text"
    cat "$REPO/$(jq -r .text_path <<< "$item")"
    echo
    echo "===== END ITEM $item_id ====="
    echo
  } > "$tmp/block"

  # Send the current batch first if this item would make it too big.
  if [ -s "$tmp/batch" ] && { [ "$(wc -l < "$tmp/batch")" -ge "$BATCH_ITEMS" ] ||
       [ $(( $(wc -c < "$tmp/message") + $(wc -c < "$tmp/block") )) -gt "$BATCH_CHARS" ]; }; then
    ask_batch
  fi
  cat "$tmp/block" >> "$tmp/message"
  printf '%s\n' "$item" >> "$tmp/batch"
done
ask_batch

# Receipt. Cost is estimated only when prices are given; otherwise it is null (unknown).
cost=null
[ -n "${OPENAI_INPUT_PRICE:-}" ] && cost="$(awk "BEGIN {printf \"%.4f\", ($tokens_in * $OPENAI_INPUT_PRICE + $tokens_out * ${OPENAI_OUTPUT_PRICE:-0}) / 1000000}")"
if [ -s "$tmp/errors" ]; then status=incomplete; code=1; else status=completed; code=0; fi
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$total" --argjson out "$decided" --arg model "$OPENAI_MODEL" --arg model_tool "${LLM_PROVIDER:-codex}" \
  --argjson tin "$tokens_in" --argjson tout "$tokens_out" --argjson cost "$cost" --rawfile errors "$tmp/errors" \
  '{stage: "select_items", status: $status, input_count: $in, output_count: $out,
    started_at: $started, finished_at: $finished, tools: [$model_tool, "jq"], models: [$model],
    tokens: {input: $tin, output: $tout}, cost_usd: $cost, cost_estimated: ($cost != null),
    errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/select_items-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
echo "select_items: $status: $decided of $total items decided" >&2
exit "$code"
