#!/usr/bin/env bash
# Podcast collector: list the newest episodes of every "podcast" source and their audio files.
#   bash collectors/fetch_podcasts.sh RUN_DIR > RUN_DIR/candidates/podcasts.jsonl
# Prints one candidate per episode, with media_url = the episode's audio file. Podcast feeds
# hold their whole archive, so only the newest episodes are kept: 8 per show, or the source's
# "max_items" in sources.json. If an episode publishes its own transcript (JSON), its link is
# saved as transcript_url so extraction can skip transcribing it.
# A source may also list "title_keywords" in sources.json: then only episodes whose title
# contains one of those words (whole word, any case, plural allowed) are kept, before taking the
# newest max_items. This scopes the source to its gear episodes so off-topic audio is never
# downloaded or transcribed; select_items.sh still judges the relevance of every kept episode.
# Episodes this skips (among the newest max_items) are listed in the receipt as title_skipped.
# Exit: 0 all podcasts read, 1 some podcasts failed (the rest are still printed), 2 bad arguments.
set -uo pipefail

RUN_DIR="${1:-}"
[ -f "$RUN_DIR/config/sources.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
: > "$tmp/errors"; : > "$tmp/skipped"

# Python: read a podcast RSS file and print the newest MAX episodes as candidates.
PARSE='
import json, re, sys, xml.etree.ElementTree as ET
from datetime import timezone
from email.utils import parsedate_to_datetime
path, source_id, publisher_id, now, max_items, keywords, skipped_path = sys.argv[1:8]
keywords = json.loads(keywords)
PODCAST = "{https://podcastindex.org/namespace/1.0}"

def utc(date):  # "Thu, 09 Oct 2026 14:00 +0000" -> "2026-10-09T14:00:00Z"
    try:
        t = parsedate_to_datetime(date)
        return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return date or None  # missing or unreadable: filter_items.sh will exclude it

episodes = []
for item in ET.parse(path).getroot().iter("item"):
    audio = item.find("enclosure")
    transcript = [t.get("url") for t in item.findall(PODCAST + "transcript") if t.get("type") == "application/json"]
    page = (item.findtext("link") or "").strip() or (audio.get("url") if audio is not None else "")
    episodes.append({"item_id": "podcast:" + ((item.findtext("guid") or "").strip() or page),
                     "source_id": source_id, "publisher_id": publisher_id, "kind": "podcast",
                     "title": (item.findtext("title") or "").strip(), "url": page,
                     "published_at": utc(item.findtext("pubDate")), "retrieved_at": now,
                     "media_url": audio.get("url") if audio is not None else None,
                     "transcript_url": transcript[0] if transcript else None})
episodes.sort(key=lambda e: e["published_at"] or "", reverse=True)
if keywords:  # e.g. "scope" matches "Scope" and "Scopes" but not "Telescope"
    pattern = re.compile(r"\b(" + "|".join(re.escape(k) for k in keywords) + r")(s|es)?\b", re.IGNORECASE)
    with open(skipped_path, "a") as skipped:
        for e in episodes[:int(max_items)]:
            if not pattern.search(e["title"]):
                skipped.write(json.dumps({k: e[k] for k in ("source_id", "title", "published_at")}) + "\n")
    episodes = [e for e in episodes if pattern.search(e["title"])]
for e in episodes[:int(max_items)]:
    print(json.dumps(e))
'

sources=0; ok=0; items=0
while IFS=$'\t' read -r id publisher url max keywords; do
  sources=$((sources + 1))
  if ! curl -fsSL --compressed --retry 3 --max-time 60 -o "$tmp/feed.xml" "$url" 2> "$tmp/err"; then
    echo "$id: download failed: $(cat "$tmp/err")" | tee -a "$tmp/errors" >&2; continue
  fi
  if ! python3 -c "$PARSE" "$tmp/feed.xml" "$id" "$publisher" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$max" "$keywords" "$tmp/skipped" > "$tmp/out" 2> /dev/null; then
    echo "$id: not a readable podcast feed" | tee -a "$tmp/errors" >&2; continue
  fi
  cat "$tmp/out"
  ok=$((ok + 1)); items=$((items + $(wc -l < "$tmp/out")))
  echo "fetch_podcasts: $id: $(wc -l < "$tmp/out" | tr -d ' ') episodes" >&2
done < <(jq -r '.[] | select(.kind == "podcast") | [.source_id, .publisher_id, .url, (.max_items // 8), (.title_keywords // [] | tojson)] | @tsv' "$RUN_DIR/config/sources.json")

# Receipt. A failed podcast means coverage is incomplete.
if [ "$ok" -eq "$sources" ]; then status=completed; code=0; else status=incomplete; code=1; fi
mkdir -p "$RUN_DIR/logs"
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$sources" --argjson out "$items" --argjson ok "$ok" --rawfile errors "$tmp/errors" --slurpfile skipped "$tmp/skipped" \
  '{stage: "fetch_podcasts", status: $status, input_count: $in, output_count: $out, sources_succeeded: $ok,
    title_skipped_count: ($skipped | length), title_skipped: $skipped,
    started_at: $started, finished_at: $finished, tools: ["curl", "python3"], models: [],
    cost_usd: 0, cost_estimated: false, errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/fetch_podcasts-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
exit "$code"
