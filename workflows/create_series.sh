#!/usr/bin/env bash
# Series workflow: runs the editorial and writing steps in order and saves each result in RUN_DIR.
#   bash workflows/create_series.sh RUN_DIR
#   1. select_items.sh         eligible.jsonl  -> decisions.jsonl
#   2. create_briefs.sh        decisions.jsonl -> briefs.jsonl
#      STOPS HERE if the briefs fail their evidence checks, so nothing is written from
#      unsupported briefs and no sources are invented. The problems are listed for repair.
#   3. write_articles.sh       briefs.jsonl    -> articles.jsonl + articles/01-03.md
#      write_video_scripts.sh  briefs.jsonl    -> video_scripts.jsonl + video_scripts/01-03.md
#   4. check_content.sh                        -> review.json
# Exit: 0 drafts ready for human review, 1 a step failed or needs repair, 2 bad arguments.
set -uo pipefail

cd "$(dirname "$0")/.."
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
steps=""
record() { steps+="$1=$2"$'\n'; [ "$2" -eq 0 ] || echo "create_series: $1 exited with $2" >&2; }

# Write the receipt and stop. Arguments: status, exit code, message.
finish() {
  jq -n --arg status "$1" --arg message "$3" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg steps "$steps" \
    '{stage: "create_series", status: $status, message: $message, steps: ($steps | split("\n") | map(select(. != ""))),
      started_at: $started, finished_at: $finished, tools: ["bash"], models: [], cost_usd: 0, cost_estimated: false,
      errors: ($steps | split("\n") | map(select(. != "" and (endswith("=0") | not))))}' \
    > "$RUN_DIR/logs/create_series-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  echo "create_series: $1: $3" >&2
  exit "$2"
}

[ -s "$RUN_DIR/eligible.jsonl" ] || finish failed 1 "no eligible evidence; run the collection workflow first"

# 1. Decisions. If a few items could not be decided, carry on with the rest.
bash editorial/select_items.sh "$RUN_DIR" < "$RUN_DIR/eligible.jsonl" > "$RUN_DIR/decisions.jsonl"
code=$?; record select_items "$code"
[ "$code" -le 1 ] && [ -s "$RUN_DIR/decisions.jsonl" ] || finish failed 1 "no editorial decisions (check OPENAI_API_KEY and OPENAI_MODEL)"

# 2. Briefs. Stop if they are unsupported.
bash editorial/create_briefs.sh "$RUN_DIR" < "$RUN_DIR/decisions.jsonl" > "$RUN_DIR/briefs.jsonl"
code=$?; record create_briefs "$code"
[ "$code" -eq 0 ] || finish needs_repair 1 "the briefs failed their evidence checks; see the create_briefs receipt in $RUN_DIR/logs"

# 3. Articles and video scripts from the same briefs.
bash content/write_articles.sh "$RUN_DIR" < "$RUN_DIR/briefs.jsonl" > "$RUN_DIR/articles.jsonl"
record write_articles $?
bash content/write_video_scripts.sh "$RUN_DIR" < "$RUN_DIR/briefs.jsonl" > "$RUN_DIR/video_scripts.jsonl"
record write_video_scripts $?

# 4. Content checks. review.json says whether they passed.
bash review/check_content.sh "$RUN_DIR" > "$RUN_DIR/review.json"
code=$?; record check_content "$code"
[ "$code" -eq 0 ] || finish failed 1 "the content checks could not run"
[ "$(jq .passed "$RUN_DIR/review.json")" = true ] || finish needs_repair 1 "the content checks found errors; see $RUN_DIR/review.json"
finish completed 0 "drafts and scripts are ready for human review"
