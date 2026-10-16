#!/usr/bin/env bash
# Video scripts: the AI writes one video script per brief (for Google Vids), from the same
# briefs and evidence as the articles, so each video and article make the same claims.
#   bash content/write_video_scripts.sh RUN_DIR < briefs.jsonl > video_scripts.jsonl
# For each brief, sends the OpenAI API one request:
#   instructions = prompts/write_video_scripts.md + config/editorial_policy.md + config/project.json
#   message      = the as-of date, the brief, and the evidence it cites (each cited item at the
#                  exact version cited, fetched with data/store.sh get, plus the cited passages)
# Saves the script as RUN_DIR/video_scripts/NN.md and prints {piece_id, path, claim_ids}, where
# claim_ids are the [NN-cN] markers actually found in the script's Claims lines.
# Needs OPENAI_API_KEY and OPENAI_MODEL (see editorial/select_items.sh for optional prices).
# Exit: 0 three scripts written, 1 a script failed (the others are still saved), 2 bad setup.
set -uo pipefail

STAGE="write_video_scripts"   # the only three lines that differ from content/write_articles.sh
PROMPT="write_video_scripts.md"
OUT="video_scripts"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/helpers/model_settings.sh" || exit 2
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR < briefs.jsonl" >&2; exit 2; }
{ [ "${LLM_PROVIDER:-codex}" = codex ] || [ "$LLM_PROVIDER" = claude ] || [ -n "${OPENAI_API_KEY:-}" ]; } && [ -n "${OPENAI_MODEL:-}" ] || { echo "$STAGE: set OPENAI_API_KEY and OPENAI_MODEL" >&2; exit 2; }
RUN_REL="$(cd "$RUN_DIR" && pwd)"; RUN_REL="${RUN_REL#"$REPO"/}"     # run folder relative to the repo
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$RUN_DIR/$OUT" "$RUN_DIR/logs"
: > "$tmp/errors"
cat "$RUN_DIR/prompts/$PROMPT" "$RUN_DIR/config/editorial_policy.md" "$RUN_DIR/config/project.json" > "$tmp/instructions"

# Python: print the evidence a brief cites. For each cited item version: its details and source
# notes, then each cited passage (the quote, or the transcript segment with its time).
EVIDENCE='
import json, subprocess, sys
brief, repo, sources = json.loads(sys.argv[1]), sys.argv[2], json.load(open(sys.argv[3]))
cited = {}
for claim in brief["claims"]:
    for ev in claim["evidence"]:
        cited.setdefault((ev["item_id"], ev["version_id"]), []).append((claim["claim_id"], ev["locator"]))
for (item_id, version_id), citations in cited.items():
    found = subprocess.run(["bash", repo + "/data/store.sh", "get", item_id, version_id], capture_output=True, text=True)
    if found.returncode != 0:
        print("### " + item_id + ": NOT IN THE EVIDENCE STORE"); continue
    item = json.loads(found.stdout)
    notes = next((s for s in sources if s["source_id"] == item["source_id"]), {})
    print("\n### Source: " + item["title"])
    print(json.dumps({k: item.get(k) for k in ("item_id", "version_id", "kind", "publisher_id", "url", "published_at")}
                     | {"perspective": notes.get("perspective"), "source_notes": notes.get("notes")}, indent=1))
    segments = {s["segment_id"]: s for s in json.load(open(repo + "/" + item["segments_path"]))} if item["segments_path"] else {}
    for claim_id, loc in citations:
        if loc["type"] == "text":
            print("- [%s] quote: \"%s\"" % (claim_id, loc["quote"]))
        elif loc.get("segment_id") in segments:
            s = segments[loc["segment_id"]]
            print("- [%s] segment %s at %d:%02d: \"%s\"" % (claim_id, s["segment_id"], s["start_seconds"] // 60, s["start_seconds"] % 60, s["text"]))
'

total=0; written=0; tokens_in=0; tokens_out=0
while IFS= read -r brief; do
  total=$((total + 1))
  piece="$(jq -r .piece_id <<< "$brief")"
  draft="$RUN_DIR/$OUT/$piece.md"
  reply="$RUN_DIR/logs/$STAGE-$piece-reply.json"

  # The message: as-of date, the brief, and its evidence.
  { echo "As-of date for this publication: $(jq -r .as_of_date "$RUN_DIR/run.json")"
    echo "# Brief for piece $piece"; jq . <<< "$brief"
    echo "# Evidence cited by this brief"; python3 -c "$EVIDENCE" "$brief" "$REPO" "$RUN_DIR/config/sources.json"
  } > "$tmp/message"

  # Ask the model and save the draft (dropping a ``` wrapper if the model added one).
  jq -n --arg model "$OPENAI_MODEL" --rawfile instructions "$tmp/instructions" --rawfile message "$tmp/message" \
    '{model: $model, messages: [{role: "system", content: $instructions}, {role: "user", content: $message}]}' \
  | model_request "$reply"
  tokens_in=$((tokens_in + $(jq '.usage.prompt_tokens // 0' "$reply" 2> /dev/null || echo 0)))
  tokens_out=$((tokens_out + $(jq '.usage.completion_tokens // 0' "$reply" 2> /dev/null || echo 0)))
  jq -r '.choices[0].message.content // ""' "$reply" 2> /dev/null | sed '/^```/d' > "$draft"
  if [ "$(wc -w < "$draft")" -lt 50 ]; then
    echo "piece $piece: no usable draft in the reply ($reply)" | tee -a "$tmp/errors" >&2; continue
  fi

  # Manifest record: the claim markers that actually appear in the draft.
  claims="$(grep -oE "\[$piece-c[0-9]+\]" "$draft" | tr -d '[]' | sort -u | jq -R . | jq -s -c .)"
  jq -n -c --arg piece "$piece" --arg path "$RUN_REL/$OUT/$piece.md" --argjson claims "$claims" \
    '{piece_id: $piece, path: $path, claim_ids: $claims}'
  written=$((written + 1))
  echo "$STAGE: wrote $RUN_REL/$OUT/$piece.md ($(wc -w < "$draft" | tr -d ' ') words)" >&2
done

# Receipt.
cost=null
[ -n "${OPENAI_INPUT_PRICE:-}" ] && cost="$(awk "BEGIN {printf \"%.4f\", ($tokens_in * $OPENAI_INPUT_PRICE + $tokens_out * ${OPENAI_OUTPUT_PRICE:-0}) / 1000000}")"
if [ -s "$tmp/errors" ]; then status=incomplete; code=1; else status=completed; code=0; fi
jq -n --arg stage "$STAGE" --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$total" --argjson out "$written" --arg model "$OPENAI_MODEL" --arg model_tool "${LLM_PROVIDER:-codex}" \
  --argjson tin "$tokens_in" --argjson tout "$tokens_out" --argjson cost "$cost" --rawfile errors "$tmp/errors" \
  '{stage: $stage, status: $status, input_count: $in, output_count: $out,
    started_at: $started, finished_at: $finished, tools: [$model_tool, "jq", "python3"], models: [$model],
    tokens: {input: $tin, output: $tout}, cost_usd: $cost, cost_estimated: ($cost != null),
    errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/$STAGE-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
exit "$code"
