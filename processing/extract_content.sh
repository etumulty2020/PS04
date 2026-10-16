#!/usr/bin/env bash
# Content extraction: get the full text or transcript of each candidate.
#   bash processing/extract_content.sh RUN_DIR < date_filtered_candidates.jsonl > items.jsonl
#
#   feed     download the article page and keep its readable text
#   youtube  download YouTube's captions (transcribe the audio if there are none)
#   podcast  use the show's published transcript if it has one, otherwise transcribe the audio
# Audio and video already in the store reuse their saved transcript (found with store.sh get).
#
# Saves:  data/media/podcast/KEY.audio              downloaded audio
#         data/assets/KIND/KEY/VERSION_ID.txt       full text or transcript
#         data/assets/KIND/KEY/VERSION_ID.json      transcript segments with start/end seconds
# KEY is a hash of the item_id. version_id is a hash of the title, url, date, text, and
# segments (not retrieved_at), so unchanged content always gets the same version_id.
#
# Transcription: TRANSCRIBE_ENGINE=local (default, Whisper on this Mac) or openai (OpenAI's API,
# TRANSCRIBE_PARALLEL episodes at once, default 6; model OPENAI_TRANSCRIBE_MODEL, default
# whisper-1; set OPENAI_TRANSCRIBE_PRICE in $ per minute to estimate cost).
# Exit: 0 all items extracted, 1 some items failed (the rest are still printed), 2 bad arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR < candidates.jsonl" >&2; exit 2; }
ENGINE="${TRANSCRIBE_ENGINE:-local}"
WHISPER_MODEL="${WHISPER_MODEL:-mlx-community/whisper-large-v3-turbo}"
API_MODEL="${OPENAI_TRANSCRIBE_MODEL:-whisper-1}"
if [ "$ENGINE" = openai ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "extract_content: TRANSCRIBE_ENGINE=openai needs OPENAI_API_KEY" >&2; exit 2
fi
BROWSER="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/ready" "$REPO/data/media/podcast"
: > "$tmp/errors"; : > "$tmp/api_seconds"
cat > "$tmp/candidates.jsonl"

# ---------------------------------------------------------------------------
# Python helpers. Each transcript source is turned into a list of
# {"start": seconds, "end": seconds, "text": ...} pieces ("raw segments").
# ---------------------------------------------------------------------------

# Article page (HTML) -> readable text: headings, paragraphs, and list items.
HTML_TO_TEXT='
import sys
from html.parser import HTMLParser
SKIP = ("script", "style", "nav", "header", "footer", "aside", "form")
KEEP = ("p", "h1", "h2", "h3", "li", "blockquote")
class Reader(HTMLParser):
    def __init__(self):
        super().__init__(); self.blocks, self.words, self.inside, self.skip = [], [], 0, 0
    def handle_starttag(self, tag, attrs):
        if tag in SKIP: self.skip += 1
        if tag in KEEP: self.inside += 1
    def handle_endtag(self, tag):
        if tag in SKIP and self.skip: self.skip -= 1
        if tag in KEEP and self.inside:
            self.inside -= 1
            text = " ".join("".join(self.words).split())
            if text: self.blocks.append(text)
            self.words = []
    def handle_data(self, data):
        if self.inside and not self.skip: self.words.append(data)
reader = Reader(); reader.feed(open(sys.argv[1], encoding="utf-8", errors="replace").read())
print("\n\n".join(reader.blocks))
'

# YouTube captions (json3 file) -> raw segments.
CAPTIONS_TO_RAW='
import json, sys
raw = []
for e in json.load(open(sys.argv[1])).get("events", []):
    text = "".join(s.get("utf8", "") for s in e.get("segs", [])).strip()
    if text:
        start = e.get("tStartMs", 0) / 1000
        raw.append({"start": start, "end": start + (e.get("dDurationMs") or 0) / 1000, "text": text})
json.dump(raw, sys.stdout)
'

# A podcast published transcript (podcast-namespace JSON) -> raw segments.
PUBLISHED_TO_RAW='
import json, sys
segments = json.load(open(sys.argv[1]))["segments"]
json.dump([{"start": s["startTime"], "end": s["endTime"], "text": s["body"]} for s in segments if s["body"].strip()], sys.stdout)
'

# Audio file -> raw segments with local Whisper. Arguments: audio file, model.
WHISPER_TO_RAW='
import json, sys, mlx_whisper
result = mlx_whisper.transcribe(sys.argv[1], path_or_hf_repo=sys.argv[2])
json.dump([{"start": s["start"], "end": s["end"], "text": s["text"].strip()} for s in result["segments"]], sys.stdout)
'

# OpenAI transcription of one audio chunk -> raw segments, shifted by the chunk start time.
# Arguments: API response file, chunk start in seconds.
API_TO_RAW='
import json, sys
response, offset = json.load(open(sys.argv[1])), float(sys.argv[2])
json.dump([{"start": s["start"] + offset, "end": s["end"] + offset, "text": s["text"].strip()} for s in response["segments"]], sys.stdout)
'

# Save the item. Arguments: candidate JSON, text file, raw segments file ("" for articles), repo.
# Joins raw segments into ~30-second segments (s-0001, s-0002, ...), computes version_id,
# writes the asset files (never overwriting an existing version), and prints the item record.
SAVE_ITEM='
import hashlib, json, os, sys
candidate, text_file, raw_file, repo = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
text, segments = open(text_file, encoding="utf-8").read().strip(), None
if raw_file:
    segments, group = [], []
    for piece in json.load(open(raw_file)) + [None]:
        if piece: group.append(piece)
        if group and (piece is None or piece["end"] - group[0]["start"] >= 30):
            segments.append({"segment_id": "s-%04d" % (len(segments) + 1), "start_seconds": round(group[0]["start"], 2),
                             "end_seconds": round(group[-1]["end"], 2), "text": " ".join(p["text"] for p in group)})
            group = []
    text = " ".join(s["text"] for s in segments)
content = {k: candidate.get(k) for k in ("title", "url", "published_at")}
content.update(text=text, segments=segments)
version = hashlib.sha256(json.dumps(content, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
folder = "data/assets/%s/%s" % (candidate["kind"], hashlib.sha256(candidate["item_id"].encode()).hexdigest()[:32])
os.makedirs(os.path.join(repo, folder), exist_ok=True)
text_path, segments_path = "%s/%s.txt" % (folder, version), ("%s/%s.json" % (folder, version) if segments else None)
if not os.path.exists(os.path.join(repo, text_path)):
    open(os.path.join(repo, text_path), "w", encoding="utf-8").write(text)
if segments_path and not os.path.exists(os.path.join(repo, segments_path)):
    json.dump(segments, open(os.path.join(repo, segments_path), "w"), indent=1)
print(json.dumps({**candidate, "version_id": version, "text_path": text_path, "segments_path": segments_path}))
'

# ---------------------------------------------------------------------------
# Steps. Each writes its raw segments (or article text) to the file it is given.
# ---------------------------------------------------------------------------

# Transcribe an audio file. Arguments: audio file, output file.
transcribe() {
  if [ "$ENGINE" = local ]; then
    python3 -c "$WHISPER_TO_RAW" "$1" "$WHISPER_MODEL" > "$2"
    return
  fi
  # OpenAI: compress to mono 32 kbps and cut into 30-minute chunks (under the 25 MB upload limit),
  # then send each chunk and shift its timestamps by the chunk's start time.
  local chunks="$2.chunks" start=0 chunk length
  mkdir -p "$chunks"
  ffmpeg -nostdin -loglevel error -y -i "$1" -vn -ac 1 -ar 16000 -b:a 32k -f segment -segment_time 1800 "$chunks/%03d.mp3" || return 1
  echo "[]" > "$2"
  for chunk in "$chunks"/*.mp3; do
    curl -sS --retry 3 --max-time 900 -H @<(printf 'Authorization: Bearer %s\n' "$OPENAI_API_KEY") \
      -F "file=@$chunk" -F "model=$API_MODEL" -F "response_format=verbose_json" -F "timestamp_granularities[]=segment" \
      -o "$chunk.json" "${OPENAI_BASE_URL:-https://api.openai.com/v1}/audio/transcriptions" || return 1
    python3 -c "$API_TO_RAW" "$chunk.json" "$start" > "$chunk.raw" 2> /dev/null \
      || { jq -r '.error.message // "unreadable API reply"' "$chunk.json" >&2; return 1; }
    jq -s '.[0] + .[1]' "$2" "$chunk.raw" > "$2.next" && mv "$2.next" "$2"
    length="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$chunk")"
    echo "$length" >> "$tmp/api_seconds"
    start="$(awk "BEGIN {print $start + $length}")"
  done
}

# Download a podcast episode's audio once, then transcribe it. Arguments: candidate, key, output.
transcribe_podcast() {
  local audio="$REPO/data/media/podcast/$2.audio"
  [ -s "$audio" ] || curl -fsSL --retry 2 --max-time 1800 -o "$audio" "$(jq -r .media_url <<< "$1")" || return 1
  transcribe "$audio" "$3"
}

# Get one item's content into $tmp/text (articles) or $tmp/raw.json (audio/video).
# Arguments: candidate, key.
extract() {
  local candidate="$1" key="$2" url
  url="$(jq -r .url <<< "$candidate")"
  : > "$tmp/text"; rm -f "$tmp/raw.json" "$tmp"/captions*
  case "$(jq -r .kind <<< "$candidate")" in
    feed)
      curl -fsSL --compressed --retry 2 --max-time 60 -A "$BROWSER" -o "$tmp/page.html" "$url" || return 1
      python3 -c "$HTML_TO_TEXT" "$tmp/page.html" > "$tmp/text" || return 1
      [ "$(wc -w < "$tmp/text")" -ge 100 ] || { echo "page has under 100 words of text" >&2; return 1; } ;;
    youtube)
      # A download error (e.g. YouTube rate limiting) fails the item so a later run retries it;
      # only a video that truly has no captions is transcribed.
      yt-dlp --quiet --no-warnings --skip-download --write-subs --write-auto-subs --sub-langs en \
        --sub-format json3 -o "$tmp/captions.%(ext)s" "$url" < /dev/null || return 1
      if ls "$tmp"/captions*.json3 > /dev/null 2>&1; then
        python3 -c "$CAPTIONS_TO_RAW" "$(ls "$tmp"/captions*.json3 | head -1)" > "$tmp/raw.json"
      else
        yt-dlp --quiet --no-warnings -f bestaudio -o "$tmp/video.audio" "$url" < /dev/null &&
          transcribe "$tmp/video.audio" "$tmp/raw.json"
      fi ;;
    podcast)
      if [ -s "$tmp/ready/$key.json" ]; then             # already transcribed in the parallel step
        cp "$tmp/ready/$key.json" "$tmp/raw.json"
      elif [ -n "$(jq -r '.transcript_url // empty' <<< "$candidate")" ]; then
        curl -fsSL --retry 2 --max-time 120 -o "$tmp/published.json" "$(jq -r .transcript_url <<< "$candidate")" &&
          python3 -c "$PUBLISHED_TO_RAW" "$tmp/published.json" > "$tmp/raw.json"
      else
        transcribe_podcast "$candidate" "$key" "$tmp/raw.json"
      fi ;;
  esac
}

# Print the saved segments file of an audio/video item already in the store (same media).
stored_segments() {
  bash "$REPO/data/store.sh" get "$(jq -r .item_id <<< "$1")" 2> /dev/null \
    | jq -r --argjson c "$1" 'select(.segments_path != null and .media_url == $c.media_url) | .segments_path'
}

key_for() { printf '%s' "$(jq -r .item_id <<< "$1")" | shasum -a 256 | cut -c1-32; }

# ---------------------------------------------------------------------------
# Parallel step (openai only): transcribe podcast episodes that have no published transcript
# and nothing in the store, several at a time. The main loop then picks up the results.
# ---------------------------------------------------------------------------
if [ "$ENGINE" = openai ]; then
  while IFS= read -r candidate; do
    [ -z "$(stored_segments "$candidate")" ] || continue
    key="$(key_for "$candidate")"
    while [ "$(jobs -rp | wc -l)" -ge "${TRANSCRIBE_PARALLEL:-6}" ]; do sleep 1; done
    transcribe_podcast "$candidate" "$key" "$tmp/ready/$key.json" 2> /dev/null &
  done < <(jq -c 'select(.kind == "podcast" and .media_url != null and .transcript_url == null)' "$tmp/candidates.jsonl")
  wait
fi

# ---------------------------------------------------------------------------
# Main loop: one item at a time.
# ---------------------------------------------------------------------------
total=0; extracted=0; reused=0
while IFS= read -r candidate <&3; do
  total=$((total + 1))
  item_id="$(jq -r .item_id <<< "$candidate")"
  stored=""
  [ "$(jq -r .kind <<< "$candidate")" = feed ] || stored="$(stored_segments "$candidate")"
  if [ -n "$stored" ] && [ -f "$REPO/$stored" ]; then
    # Reuse the saved transcript instead of transcribing again.
    jq '[.[] | {start: .start_seconds, end: .end_seconds, text}]' "$REPO/$stored" > "$tmp/raw.json"
    : > "$tmp/text"; reused=$((reused + 1))
  elif extract "$candidate" "$(key_for "$candidate")" 2> "$tmp/err" && { [ -s "$tmp/text" ] || [ -s "$tmp/raw.json" ]; }; then
    extracted=$((extracted + 1))
  else
    echo "$item_id: $(tail -1 "$tmp/err")" | tee -a "$tmp/errors" >&2; continue
  fi
  raw=""; [ -s "$tmp/raw.json" ] && raw="$tmp/raw.json"
  python3 -c "$SAVE_ITEM" "$candidate" "$tmp/text" "$raw" "$REPO"
  echo "extract_content: ok $item_id" >&2
done 3< "$tmp/candidates.jsonl"

# ---------------------------------------------------------------------------
# Receipt. OpenAI transcription is billed per audio minute; the cost is only known when
# OPENAI_TRANSCRIBE_PRICE is set, otherwise it is recorded as null (unknown).
# ---------------------------------------------------------------------------
minutes="$(awk '{s += $1} END {printf "%.1f", s / 60}' "$tmp/api_seconds")"
if [ "$minutes" = "0.0" ]; then cost=0
elif [ -n "${OPENAI_TRANSCRIBE_PRICE:-}" ]; then cost="$(awk "BEGIN {printf \"%.4f\", $minutes * $OPENAI_TRANSCRIBE_PRICE}")"
else cost=null; fi
if [ -s "$tmp/errors" ]; then status=incomplete; code=1; else status=completed; code=0; fi
model="$WHISPER_MODEL"; [ "$ENGINE" = openai ] && model="$API_MODEL"
mkdir -p "$RUN_DIR/logs"
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson in "$total" --argjson extracted "$extracted" --argjson reused "$reused" --arg model "$model" \
  --arg engine "$ENGINE" --argjson minutes "$minutes" --argjson cost "$cost" --rawfile errors "$tmp/errors" \
  '{stage: "extract_content", status: $status, input_count: $in, output_count: ($extracted + $reused),
    extracted: $extracted, reused_transcripts: $reused, transcribe_engine: $engine, api_audio_minutes: $minutes,
    started_at: $started, finished_at: $finished, tools: ["curl", "yt-dlp", "ffmpeg", "python3"], models: [$model],
    cost_usd: $cost, cost_estimated: ($cost != null and $cost != 0), errors: ($errors | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/extract_content-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
echo "extract_content: $status: $total items, $extracted extracted, $reused reused" >&2
exit "$code"
