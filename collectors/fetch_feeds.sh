#!/usr/bin/env bash
# RSS collector: list the articles in every "feed" source of the run's sources.json.
#   bash collectors/fetch_feeds.sh RUN_DIR > RUN_DIR/candidates/feeds.jsonl
# Prints one candidate per article (title, link, date). Article text is fetched later
# by processing/extract_content.sh.
# Exit: 0 all feeds read, 1 some feeds failed (the rest are still printed), 2 bad arguments.
set -uo pipefail

RUN_DIR="${1:-}"
[ -f "$RUN_DIR/config/sources.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
: > "$tmp/errors"
BROWSER="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

# Python: read an RSS or Atom file and print one candidate per entry.
PARSE='
import json, sys, xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
path, source_id, publisher_id, now = sys.argv[1:5]
ATOM = "{http://www.w3.org/2005/Atom}"

def utc(date):  # "Thu, 09 Oct 2026 14:00 +0000" or "2026-10-09T14:00Z" -> "2026-10-09T14:00:00Z"
    if not date:
        return None
    try:
        t = parsedate_to_datetime(date)
    except Exception:
        try:
            t = datetime.fromisoformat(date.strip().replace("Z", "+00:00"))
        except Exception:
            return date  # unreadable: filter_items.sh will exclude it as invalid_date
    return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

root = ET.parse(path).getroot()
entries = [(i.findtext("title"), i.findtext("link"), i.findtext("pubDate")) for i in root.iter("item")]
for e in root.iter(ATOM + "entry"):
    link = e.find(ATOM + "link")
    entries.append((e.findtext(ATOM + "title"), link.get("href") if link is not None else None,
                    e.findtext(ATOM + "published") or e.findtext(ATOM + "updated")))
for title, url, date in entries:
    if url:
        url = url.strip().split("#")[0]
        print(json.dumps({"item_id": "feed:" + url, "source_id": source_id, "publisher_id": publisher_id,
                          "kind": "feed", "title": (title or "").strip(), "url": url, "published_at": utc(date),
                          "retrieved_at": now, "media_url": None}))
'

sources=0; ok=0; items=0
while IFS=$'\t' read -r id publisher url; do
  sources=$((sources + 1))
  if ! curl -fsSL --compressed --retry 3 --max-time 60 -A "$BROWSER" -o "$tmp/feed.xml" "$url" 2> "$tmp/err"; then
    echo "$id: download failed: $(cat "$tmp/err")" | tee -a "$tmp/errors" >&2; continue
  fi
  if ! python3 -c "$PARSE" "$tmp/feed.xml" "$id" "$publisher" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/out" 2> /dev/null; then
    echo "$id: not a readable RSS/Atom feed" | tee -a "$tmp/errors" >&2; continue
  fi
  cat "$tmp/out"
  ok=$((ok + 1)); items=$((items + $(wc -l < "$tmp/out")))
  echo "fetch_feeds: $id: $(wc -l < "$tmp/out" | tr -d ' ') items" >&2
done < <(jq -r '.[] | select(.kind == "feed") | [.source_id, .publisher_id, .url] | @tsv' "$RUN_DIR/config/sources.json")

# Receipt. A failed feed means coverage is incomplete.
if [ "$ok" -eq "$sources" ]; then status=completed; code=0; else status=incomplete; code=1; fi
mkdir -p "$RUN_DIR/logs"
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$sources" --argjson out "$items" --argjson ok "$ok" --rawfile errors "$tmp/errors" \
  '{stage: "fetch_feeds", status: $status, input_count: $in, output_count: $out, sources_succeeded: $ok,
    started_at: $started, finished_at: $finished, tools: ["curl", "python3"], models: [],
    cost_usd: 0, cost_estimated: false, errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/fetch_feeds-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
exit "$code"
