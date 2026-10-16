#!/usr/bin/env bash
# Freshness filter: keep only items published inside the 30-day window.
#
#   bash processing/filter_items.sh RUN_DIR < corpus.jsonl > eligible.jsonl
#
# For the run's as-of date D (from RUN_DIR/run.json), the window is D minus 29 days
# through D, inclusive: 30 calendar dates in UTC. Each item on stdin is either printed
# to stdout (eligible) or written to RUN_DIR/exclusions.jsonl with one of these reasons:
#   unknown_date    published_at is null or empty
#   invalid_date    published_at is not a readable date
#   outside_window  published before the window starts
#   future_date     published after the as-of date
#
# This is a mechanical date check only. Relevance and quality are judged later by
# editorial/select_items.sh. Older stored items are rechecked against every new window.
#
# Exit codes: 0 completed, 2 bad arguments or malformed input.
set -euo pipefail

RUN_DIR="${1:-}"
if [ -z "$RUN_DIR" ] || [ ! -f "$RUN_DIR/run.json" ]; then
  echo "usage: $0 RUN_DIR < items.jsonl (RUN_DIR must contain run.json)" >&2
  exit 2
fi

started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
input="$(mktemp)"
trap 'rm -f "$input"' EXIT
cat > "$input"

# Every input line must be a JSON object with an item_id.
if ! jq -e -s 'all(type == "object" and (.item_id | type == "string"))' "$input" > /dev/null 2>&1; then
  echo "filter_items: malformed input (each line needs a JSON object with item_id)" >&2
  exit 2
fi

# Work out the window from the as-of date.
as_of="$(jq -r '.as_of_date' "$RUN_DIR/run.json")"
if ! window_start="$(jq -nr --arg d "$as_of" '$d | strptime("%Y-%m-%d") | mktime - 29*86400 | strftime("%Y-%m-%d")' 2>/dev/null)"; then
  echo "filter_items: run.json has an invalid as_of_date: $as_of" >&2
  exit 2
fi

# Label every item with a reason (null = eligible). Dates are compared as calendar days
# (the first 10 characters, YYYY-MM-DD), so an item from later today is not "future".
labeled="$(jq -c --arg start "$window_start" --arg end "$as_of" '
  (.published_at // "") as $p
  | ($p[0:10]) as $day
  | ($day | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") and ((try (strptime("%Y-%m-%d") | mktime) catch null) != null)) as $readable
  | if   $p == ""      then {item: ., reason: "unknown_date",   detail: "no publication date"}
    elif $readable | not then {item: ., reason: "invalid_date", detail: "unreadable publication date: \($p)"}
    elif $day < $start then {item: ., reason: "outside_window", detail: "published \($day), before window start \($start)"}
    elif $day > $end   then {item: ., reason: "future_date",    detail: "published \($day), after as-of date \($end)"}
    else {item: ., reason: null}
    end' "$input")"

# Eligible items go to stdout; exclusions go to RUN_DIR/exclusions.jsonl.
jq -c 'select(.reason == null) | .item' <<< "$labeled"
jq -c 'select(.reason != null) | {item_id: .item.item_id, version_id: (.item.version_id // null), reason, detail}' \
  <<< "$labeled" > "$RUN_DIR/exclusions.jsonl"

eligible="$(jq -s 'map(select(.reason == null)) | length' <<< "$labeled")"
excluded="$(grep -c . "$RUN_DIR/exclusions.jsonl" || true)"
reasons="$(jq -s 'map(.reason) | group_by(.) | map({key: .[0], value: length}) | from_entries' "$RUN_DIR/exclusions.jsonl")"

mkdir -p "$RUN_DIR/logs"
jq -n --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg start "$window_start" --arg end "$as_of" \
  --argjson input "$((eligible + excluded))" --argjson eligible "$eligible" --argjson excluded "$excluded" \
  --argjson reasons "$reasons" \
  '{stage: "filter_items", status: "completed", input_count: $input, output_count: $eligible,
    excluded_count: $excluded, exclusion_reasons: $reasons, window_start: $start, window_end: $end,
    started_at: $started, finished_at: $finished,
    tools: ["jq"], models: [], cost_usd: 0, cost_estimated: false, errors: []}' \
  > "$RUN_DIR/logs/filter_items-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"

echo "filter_items: window $window_start to $as_of: $eligible eligible, $excluded excluded $(jq -c . <<< "$reasons")" >&2
