#!/usr/bin/env bash
# Editorial briefs: the AI plans the three pieces from the accepted evidence.
#   bash editorial/create_briefs.sh RUN_DIR < decisions.jsonl > briefs.jsonl
# Sends the configured model one bounded request:
#   instructions = prompts/create_briefs.md + config/editorial_policy.md + config/project.json
#   message      = every accepted item (from RUN_DIR/eligible.jsonl) with its selection reason,
#                  source notes, and bounded verbatim text/transcript excerpts with IDs and times
# and prints the three briefs (piece 01, 02, 03).
# Then checks the briefs against the evidence. Any problem (a quote that is not in the article,
# a segment that does not exist, fewer than 3 publishers behind an argument, a missing input type,
# or "INSUFFICIENT EVIDENCE:") is listed and the script exits 1, so unsupported briefs are never
# passed on silently.
# Needs OPENAI_API_KEY and OPENAI_MODEL (see editorial/select_items.sh for optional prices).
# Exit: 0 three valid briefs, 1 briefs missing or failing the checks, 2 bad setup.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/helpers/model_settings.sh" || exit 2
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/eligible.jsonl" ] || { echo "usage: $0 RUN_DIR < decisions.jsonl (needs RUN_DIR/eligible.jsonl)" >&2; exit 2; }
{ [ "${LLM_PROVIDER:-codex}" = codex ] || [ "$LLM_PROVIDER" = claude ] || [ -n "${OPENAI_API_KEY:-}" ]; } && [ -n "${OPENAI_MODEL:-}" ] || { echo "create_briefs: set OPENAI_API_KEY and OPENAI_MODEL" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
reply="$RUN_DIR/logs/create_briefs-reply.json"
mkdir -p "$RUN_DIR/logs"

# 1. The accepted items: their decisions and their full records from eligible.jsonl.
jq -c 'select(.decision == "accept")' > "$tmp/accepted_decisions.jsonl"
jq -c --slurpfile d "$tmp/accepted_decisions.jsonl" 'select(.version_id as $v | $d | any(.version_id == $v))' \
  "$RUN_DIR/eligible.jsonl" > "$tmp/accepted.jsonl"

# 2. Compact verbatim evidence; retain the packet for review against full originals.
python3 "$REPO/editorial/brief_evidence.py" "$REPO" "$RUN_DIR" "$tmp/accepted.jsonl" \
  "$tmp/accepted_decisions.jsonl" "$tmp/message" || exit 2
cp "$tmp/message" "$RUN_DIR/logs/create_briefs-evidence-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"

# 3. Ask the model, then keep the lines of its reply that are briefs.
cat "$RUN_DIR/prompts/create_briefs.md" "$RUN_DIR/config/editorial_policy.md" "$RUN_DIR/config/project.json" > "$tmp/instructions"
jq -n --arg model "$OPENAI_MODEL" --rawfile instructions "$tmp/instructions" --rawfile message "$tmp/message" \
  '{model: $model, messages: [{role: "system", content: $instructions}, {role: "user", content: $message}]}' \
| model_request "$reply"
jq -r '.choices[0].message.content // ""' "$reply" 2> /dev/null | jq -R -c 'fromjson? | select(.piece_id?)' | tee "$tmp/briefs.jsonl"

# 4. Check the briefs against the accepted evidence; print one problem per line.
CHECK='
import json, re, sys
briefs = [json.loads(line) for line in open(sys.argv[1])]
items = {i["version_id"]: i for i in map(json.loads, open(sys.argv[2]))}
repo = sys.argv[3]
def squash(s):  # compare quotes ignoring spacing, case, and curly apostrophes
    return re.sub(r"\s+", " ", s.replace("’", "\x27")).strip().lower()

if [b.get("piece_id") for b in briefs] != ["01", "02", "03"]:
    print("expected briefs 01, 02, 03; got", [b.get("piece_id") for b in briefs])
kinds = set()
for b in briefs:
    publishers = set()
    if str(b.get("limitations", "")).startswith("INSUFFICIENT EVIDENCE:"):
        print(b["piece_id"], "model reported", b["limitations"][:200])
    for c in b.get("claims", []):
        claim = c.get("claim_id")
        if not c.get("evidence"):
            print(claim, "has no evidence")
        for ev in c.get("evidence", []):
            item, locator = items.get(ev.get("version_id")), ev.get("locator", {})
            if not item or item["item_id"] != ev.get("item_id"):
                print(claim, "cites an item version that was not accepted:", ev.get("item_id"))
                continue
            publishers.add(item["publisher_id"])
            kinds.add(item["kind"])
            if locator.get("type") == "text":
                if squash(locator.get("quote", "")) not in squash(open(repo + "/" + item["text_path"]).read()):
                    print(claim, "quote not found word for word in", item["item_id"])
            else:
                segments = json.load(open(repo + "/" + item["segments_path"])) if item["segments_path"] else []
                if locator.get("segment_id") not in [s["segment_id"] for s in segments]:
                    print(claim, "segment", locator.get("segment_id"), "not found in", item["item_id"])
    if len(publishers) < 3:
        print(b.get("piece_id"), "cites", len(publishers), "independent publisher(s); at least 3 are required")
for kind in ("feed", "youtube", "podcast"):
    if kind not in kinds:
        print("series cites no", kind, "evidence; all three input types must contribute")
'
python3 -c "$CHECK" "$tmp/briefs.jsonl" "$tmp/accepted.jsonl" "$REPO" > "$tmp/errors" 2>&1
[ -s "$tmp/briefs.jsonl" ] || echo "no briefs in the reply (saved in $reply)" >> "$tmp/errors"
sed 's/^/create_briefs: PROBLEM /' "$tmp/errors" >&2

# Receipt.
tokens_in="$(jq '.usage.prompt_tokens // 0' "$reply" 2> /dev/null || echo 0)"
tokens_out="$(jq '.usage.completion_tokens // 0' "$reply" 2> /dev/null || echo 0)"
cost=null
[ -n "${OPENAI_INPUT_PRICE:-}" ] && cost="$(awk "BEGIN {printf \"%.4f\", ($tokens_in * $OPENAI_INPUT_PRICE + $tokens_out * ${OPENAI_OUTPUT_PRICE:-0}) / 1000000}")"
if [ -s "$tmp/errors" ]; then status=needs_repair; code=1; else status=completed; code=0; fi
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$(wc -l < "$tmp/accepted.jsonl")" --argjson out "$(wc -l < "$tmp/briefs.jsonl")" --arg model "$OPENAI_MODEL" --arg model_tool "${LLM_PROVIDER:-codex}" \
  --argjson tin "$tokens_in" --argjson tout "$tokens_out" --argjson cost "$cost" --rawfile errors "$tmp/errors" \
  '{stage: "create_briefs", status: $status, input_count: $in, output_count: $out,
    started_at: $started, finished_at: $finished, tools: [$model_tool, "jq", "python3"], models: [$model],
    tokens: {input: $tin, output: $tout}, cost_usd: $cost, cost_estimated: ($cost != null),
    errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/create_briefs-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
echo "create_briefs: $status" >&2
exit "$code"
