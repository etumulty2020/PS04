#!/usr/bin/env bash
# Publication package: put the approved series in one folder for production and publishing.
#   bash publishing/prepare_package.sh RUN_DIR > RUN_DIR/package/manifest.json
# Only runs when:
#   - review.json passed,
#   - approval.json says "approve" and names a reviewer, and
#   - nothing changed since: the content checks are rerun now, and the new review_id must
#     match the review_id in both review.json and approval.json.
# Otherwise it lists what is missing or out of date and exits 1.
# The package holds the approved articles and scripts (copied unchanged), source notes for each
# piece, MANUAL_STEPS.md, publication_links.json (links start as null; links already entered are
# kept), and manifest.json. Packaging does not render videos or publish anything.
# Exit: 0 package created, 1 not approved or out of date, 2 bad arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
RUN_REL="$(cd "$RUN_DIR" && pwd)"; RUN_REL="${RUN_REL#"$REPO"/}"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
problems=""

# 1. Check the review, the approval, and that nothing changed since.
current="$(bash "$REPO/review/check_content.sh" "$RUN_DIR" 2> /dev/null)"
current_id="$(jq -r .review_id <<< "$current")"
[ "$(jq -r .passed <<< "$current")" = true ] || problems+="the content checks do not pass on the current files"$'\n'
if [ ! -f "$RUN_DIR/review.json" ]; then problems+="review.json is missing"$'\n'
elif [ "$(jq -r .review_id "$RUN_DIR/review.json")" != "$current_id" ]; then problems+="review.json is out of date: the drafts or briefs changed after it was written"$'\n'; fi
if [ ! -f "$RUN_DIR/approval.json" ]; then problems+="approval.json is missing: create it after reviewing the drafts"$'\n'
else
  [ "$(jq -r .decision "$RUN_DIR/approval.json")" = approve ] || problems+="approval.json does not say \"approve\""$'\n'
  [ -n "$(jq -r '.reviewer // empty' "$RUN_DIR/approval.json")" ] || problems+="approval.json has no reviewer"$'\n'
  [ "$(jq -r .review_id "$RUN_DIR/approval.json")" = "$current_id" ] || problems+="approval.json is for a different version than the current drafts (current review_id: $current_id)"$'\n'
fi

status=completed; code=0
if [ -n "$problems" ]; then
  printf '%s' "$problems" | sed 's/^/prepare_package: NOT READY: /' >&2
  status=blocked; code=1
else
  # 2. Build the package.
  PKG="$RUN_DIR/package"
  mkdir -p "$PKG/articles" "$PKG/video_scripts" "$PKG/sources"
  for p in 01 02 03; do
    cp "$RUN_DIR/articles/$p.md" "$PKG/articles/"
    cp "$RUN_DIR/video_scripts/$p.md" "$PKG/video_scripts/"
    # Source notes: each cited item (at the exact cited version) and the claims it supports.
    brief="$(jq -c --arg p "$p" 'select(.piece_id == $p)' "$RUN_DIR/briefs.jsonl")"
    { echo "# Sources for piece $p: $(jq -r .title <<< "$brief")"
      echo "Evidence as of $(jq -r .as_of_date "$RUN_DIR/run.json"). Claim IDs match the [$p-cN] markers in the drafts."
      jq -c '[.claims[] | .claim_id as $c | .statement as $s | .evidence[] | {item_id, version_id, line: "- [\($c)] \($s)"}]
             | group_by(.version_id)[]' <<< "$brief" | while IFS= read -r group; do
        item="$(bash "$REPO/data/store.sh" get "$(jq -r '.[0].item_id' <<< "$group")" "$(jq -r '.[0].version_id' <<< "$group")")"
        jq -r '"\n## \(.title)\n\(.publisher_id), \(.kind), published \(.published_at[0:10])\n\(.url)\n\nSupports:"' <<< "$item"
        jq -r '.[].line' <<< "$group"
      done
    } > "$PKG/sources/$p.md"
  done

  # Publication links: start as null, but keep any links already entered.
  old="[]"; [ -f "$PKG/publication_links.json" ] && old="$(cat "$PKG/publication_links.json")"
  jq -n --argjson old "$old" '["01", "02", "03"] | map(. as $p | ($old | map(select(.piece_id == $p))[0] // {}) as $o
    | {piece_id: $p, substack_url: ($o.substack_url // null), youtube_url: ($o.youtube_url // null)})' > "$PKG/publication_links.json"

  cat > "$PKG/MANUAL_STEPS.md" <<'EOF'
# Remaining manual steps
Nothing has been rendered or published yet. For each piece 01, 02, 03:
1. Google Vids: make the video from video_scripts/NN.md. Use the Visual and On-screen text lines for
   visuals and the Narration lines as the voiceover. Leave out the Claims lines. Aim for 3-5 minutes.
2. YouTube: upload it (public or unlisted) and paste the script's "YouTube Description" section.
3. Substack: publish articles/NN.md with free access. Remove the [NN-cN] claim markers (the Sources
   section lists every source) and replace [VIDEO LINK] with the YouTube link.
4. In the YouTube description, replace [ARTICLE LINK] with the Substack link.
5. Fill in publication_links.json and open every link in a private window to check it works.
Source notes for each piece are in sources/NN.md.
EOF

  jq -n --arg run_id "$(jq -r .run_id "$RUN_DIR/run.json")" --arg review_id "$current_id" --arg pkg "$RUN_REL/package" \
    --arg reviewer "$(jq -r .reviewer "$RUN_DIR/approval.json")" \
    '{run_id: $run_id, review_id: $review_id, approved_by: $reviewer, published: false,
      assets: [["01", "02", "03"][] as $p | ("articles", "video_scripts", "sources") as $kind
               | {piece_id: $p, type: $kind, path: "\($pkg)/\($kind)/\($p).md"}],
      manual_steps: "\($pkg)/MANUAL_STEPS.md", publication_links: "\($pkg)/publication_links.json"}' \
    | tee "$PKG/manifest.json"
fi

mkdir -p "$RUN_DIR/logs"
jq -n --arg status "$status" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg problems "$problems" \
  '{stage: "prepare_package", status: $status, input_count: 3, output_count: (if $status == "completed" then 9 else 0 end),
    started_at: $started, finished_at: $finished, tools: ["bash", "jq"], models: [], cost_usd: 0, cost_estimated: false,
    errors: ($problems | split("\n") | map(select(. != "")))}' \
  > "$RUN_DIR/logs/prepare_package-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
exit "$code"
