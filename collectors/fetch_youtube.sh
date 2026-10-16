#!/usr/bin/env bash
# YouTube collector: list the newest videos (about 15) of every "youtube" source.
#   bash collectors/fetch_youtube.sh RUN_DIR > RUN_DIR/candidates/youtube.jsonl
# Supports channel IDs, handles, playlists, and individual video URLs.
# Tries channel RSS, then bounded yt-dlp metadata discovery. Captions are fetched
# later by processing/extract_content.sh.
# Exit: 0 all channels read, 1 some channels failed (the rest are still printed), 2 bad arguments.
set -uo pipefail

RUN_DIR="${1:-}"
[ -f "$RUN_DIR/config/sources.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
: > "$tmp/errors"; : > "$tmp/warnings"
COLLECTOR_DIR="$(cd "$(dirname "$0")" && pwd)"

# Python: read a YouTube channel feed and print one candidate per video.
PARSE='
import json, sys, xml.etree.ElementTree as ET
from datetime import datetime, timezone
path, source_id, publisher_id, now = sys.argv[1:5]
ATOM, YT = "{http://www.w3.org/2005/Atom}", "{http://www.youtube.com/xml/schemas/2015}"
for e in ET.parse(path).getroot().iter(ATOM + "entry"):
    video_id = e.findtext(YT + "videoId")
    published = datetime.fromisoformat(e.findtext(ATOM + "published")).astimezone(timezone.utc)
    print(json.dumps({"item_id": "youtube:" + video_id, "source_id": source_id, "publisher_id": publisher_id,
                      "kind": "youtube", "title": e.findtext(ATOM + "title").strip(),
                      "url": "https://www.youtube.com/watch?v=" + video_id,
                      "published_at": published.strftime("%Y-%m-%dT%H:%M:%SZ"),
                      "retrieved_at": now, "media_url": None}))
'

sources=0; ok=0; items=0
while IFS=$'\t' read -r id publisher url; do
  sources=$((sources + 1))
  channel="$(grep -oE 'UC[A-Za-z0-9_-]{22}' <<< "$url" | head -1)"
  rss_ok=false
  if [ -n "$channel" ] && curl -fsS --retry 2 --max-time 30 -o "$tmp/feed.xml" \
       "https://www.youtube.com/feeds/videos.xml?channel_id=$channel" 2> "$tmp/err"; then
    if python3 -c "$PARSE" "$tmp/feed.xml" "$id" "$publisher" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/out" 2> "$tmp/err"; then
      rss_ok=true
    fi
  fi
  if ! $rss_ok; then
    echo "$id: RSS unavailable; trying yt-dlp discovery" | tee -a "$tmp/warnings" >&2
    target="$url"
    case "$url" in
      *youtube.com/channel/*|*youtube.com/@*)
        case "${url%/}" in */videos|*/shorts|*/streams) ;; *) target="${url%/}/videos" ;; esac ;;
    esac
    # Full metadata is needed for upload dates; flat playlist listings can omit them.
    # Bound the discovery to 15 videos and five minutes; never download media here.
    python3 - "$target" "$tmp/metadata" "$tmp/err" "${YOUTUBE_DISCOVERY_LIMIT:-15}" <<'DISCOVER'
import subprocess, sys
with open(sys.argv[2], 'w') as out, open(sys.argv[3], 'w') as err:
    try:
        result = subprocess.run(['yt-dlp', '--ignore-config', '--skip-download', '--dump-json',
                                 '--playlist-end', sys.argv[4], '--socket-timeout', '20', '--retries', '1',
                                 '--ignore-errors', '--no-warnings', '--', sys.argv[1]],
                                stdout=out, stderr=err, timeout=300)
        sys.exit(result.returncode)
    except subprocess.TimeoutExpired:
        print('discovery timed out after 300 seconds', file=err)
        sys.exit(1)
    except OSError as error:
        print(str(error), file=err)
        sys.exit(1)
DISCOVER
    discovery_code=$?
    if ! python3 "$COLLECTOR_DIR/youtube_metadata.py" "$id" "$publisher" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        < "$tmp/metadata" > "$tmp/out"; then
      echo "$id: invalid yt-dlp metadata" | tee -a "$tmp/errors" >&2; continue
    fi
    if [ "$discovery_code" -ne 0 ] || [ ! -s "$tmp/out" ]; then
      echo "$id: yt-dlp discovery incomplete: $(tail -c 1000 "$tmp/err")" | tee -a "$tmp/errors" >&2
      cat "$tmp/out"
      items=$((items + $(wc -l < "$tmp/out")))
      continue
    fi
  fi
  cat "$tmp/out"
  ok=$((ok + 1)); items=$((items + $(wc -l < "$tmp/out")))
  echo "fetch_youtube: $id: $(wc -l < "$tmp/out" | tr -d ' ') videos" >&2
done < <(jq -r '.[] | select(.kind == "youtube") | [.source_id, .publisher_id, .url] | @tsv' "$RUN_DIR/config/sources.json")

# Receipt. A failed channel means coverage is incomplete.
if [ "$ok" -eq "$sources" ]; then status=completed; code=0; else status=incomplete; code=1; fi
mkdir -p "$RUN_DIR/logs"
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$sources" --argjson out "$items" --argjson ok "$ok" --rawfile errors "$tmp/errors" --rawfile warnings "$tmp/warnings" \
  '{stage: "fetch_youtube", status: $status, input_count: $in, output_count: $out, sources_succeeded: $ok,
    started_at: $started, finished_at: $finished, tools: ["curl", "python3", "yt-dlp"], models: [],
    cost_usd: 0, cost_estimated: false, warnings: ($warnings | split("\n") | map(select(. != ""))), errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/fetch_youtube-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
exit "$code"
