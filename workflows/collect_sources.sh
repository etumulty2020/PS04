#!/usr/bin/env bash
# Collection workflow: runs the collection steps in order and saves each result in RUN_DIR.
#   bash workflows/collect_sources.sh RUN_DIR
#   1. collectors (feeds, youtube, podcasts)  -> candidates/*.jsonl, combined into candidates.jsonl
#   2. filter_items.sh: the new candidates plus everything already in the store (so older
#      items are rechecked against this run's 30-day window)
#                                             -> date_filtered_candidates.jsonl, exclusions.jsonl
#   3. extract_content.sh | store.sh upsert   -> items.jsonl, changes.jsonl
#   4. store.sh list                          -> corpus.jsonl
#   5. the extracted items                    -> eligible.jsonl (read by the series workflow)
# DEVIATION FROM ARCHITECTURE.md: the filter runs before extraction (the specification has
# extract -> store -> filter) so old episodes are never downloaded or transcribed.
# A failed collector does not stop the others; it is recorded and the run continues.
# Exit: 0 everything completed, 1 something failed or coverage is incomplete, 2 bad arguments.
set -uo pipefail

cd "$(dirname "$0")/.."
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
steps=""                                  # one "step=exit code" line per step, for the receipt
ok=true
record() { steps+="$1=$2"$'\n'; [ "$2" -eq 0 ] || { ok=false; echo "collect_sources: $1 exited with $2" >&2; }; }

# 1. Collect.
mkdir -p "$RUN_DIR/candidates"
for kind in feeds youtube podcasts; do
  bash "collectors/fetch_$kind.sh" "$RUN_DIR" > "$RUN_DIR/candidates/$kind.jsonl"
  record "fetch_$kind" $?
done
cat "$RUN_DIR"/candidates/{feeds,youtube,podcasts}.jsonl > "$RUN_DIR/candidates.jsonl"

# 2. Filter the new candidates and the items stored by earlier runs. A stored item that was
#    collected again is passed only once (as the new candidate).
bash data/store.sh list > "$RUN_DIR/stored_before.jsonl"
jq -c --slurpfile new "$RUN_DIR/candidates.jsonl" 'select(.item_id as $id | $new | all(.item_id != $id))' \
    "$RUN_DIR/stored_before.jsonl" \
  | cat "$RUN_DIR/candidates.jsonl" - \
  | bash processing/filter_items.sh "$RUN_DIR" > "$RUN_DIR/date_filtered_candidates.jsonl"
record filter_items $?

# 3. Extract, piped straight into the store (tee keeps a copy as items.jsonl).
bash processing/extract_content.sh "$RUN_DIR" < "$RUN_DIR/date_filtered_candidates.jsonl" \
  | tee "$RUN_DIR/items.jsonl" \
  | bash data/store.sh upsert "$RUN_DIR" > "$RUN_DIR/changes.jsonl"
codes=("${PIPESTATUS[@]}")
record extract_content "${codes[0]}"
record store_upsert "${codes[2]}"

# 4-5. Export the store, and hand the extracted items to the series workflow.
bash data/store.sh list > "$RUN_DIR/corpus.jsonl"
record store_list $?
cp "$RUN_DIR/items.jsonl" "$RUN_DIR/eligible.jsonl"

# Receipt.
if $ok; then status=completed; code=0; else status=incomplete; code=1; fi
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg steps "$steps" \
  '{stage: "collect_sources", status: $status, steps: ($steps | split("\n") | map(select(. != ""))),
    order_note: "filter_items runs before extract_content (documented deviation)",
    started_at: $started, finished_at: $finished, tools: ["bash"], models: [], cost_usd: 0, cost_estimated: false,
    errors: ($steps | split("\n") | map(select(. != "" and (endswith("=0") | not))))}' \
  > "$RUN_DIR/logs/collect_sources-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
echo "collect_sources: $status" >&2
exit "$code"
