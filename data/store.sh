#!/usr/bin/env bash
# Evidence store: the only component that reads or writes data/evidence/.
#
# Commands:
#   bash data/store.sh init                       create the store if missing (never erases)
#   bash data/store.sh upsert RUN_DIR             read items (JSONL) on stdin, print one change record per item
#   bash data/store.sh list                       print the latest version of every item
#   bash data/store.sh get ITEM_ID [VERSION_ID]   print one item (latest version if VERSION_ID is omitted)
#
# Storage format (plain files inside data/evidence/):
#   items.txt                     every item_id, one per line, in the order first seen
#   versions/KEY/VERSION_ID.json  every version of an item, saved once and never overwritten
#   latest/KEY                    the item's current version_id
#   history.jsonl                 one line per upsert: run_id, item_id, version_id, change
# KEY is a hash of the item_id, because item_ids contain characters like ":" and "/".
#
# The version_id comes from processing/extract_content.sh and does not include retrieved_at,
# so re-fetching unchanged content gives the same version_id and is recorded as "unchanged".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="${EVIDENCE_DIR:-$REPO_ROOT/data/evidence}"   # EVIDENCE_DIR lets you test in a scratch folder

usage() {
  echo "usage: $0 init | upsert RUN_DIR | list | get ITEM_ID [VERSION_ID]" >&2
  exit 2
}

# Stop with exit 1 if init has not been run yet.
require_store() {
  if [ ! -f "$STORE/items.txt" ]; then
    echo "store: not initialized at $STORE (run: bash data/store.sh init)" >&2
    exit 1
  fi
}

# Turn an item_id into a safe folder/file name.
key_for() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-32
}

cmd="${1:-}"
case "$cmd" in

  init)
    [ $# -eq 1 ] || usage
    # mkdir -p and touch never erase existing files.
    mkdir -p "$STORE/versions" "$STORE/latest"
    touch "$STORE/items.txt" "$STORE/history.jsonl"
    ;;

  upsert)
    [ $# -eq 2 ] || usage
    run_dir="$2"
    [ -f "$run_dir/run.json" ] || { echo "store: $run_dir/run.json not found" >&2; exit 2; }
    require_store
    run_id="$(jq -r '.run_id' "$run_dir/run.json")"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Save stdin to a temp file so we can check it before writing anything.
    input="$(mktemp)"
    trap 'rm -f "$input"' EXIT
    cat > "$input"

    # Every line must be a JSON object with string item_id and version_id; otherwise exit 2.
    # (-s reads all lines into one array so `all` checks every line, not just the last.)
    if ! jq -e -s 'all(type == "object" and (.item_id | type == "string") and (.version_id | type == "string"))' \
         "$input" > /dev/null 2>&1; then
      echo "store: malformed input (each line needs a JSON object with item_id and version_id)" >&2
      exit 2
    fi

    new=0; changed=0; unchanged=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      item_id="$(jq -r '.item_id' <<< "$line")"
      version_id="$(jq -r '.version_id' <<< "$line")"
      key="$(key_for "$item_id")"

      # Decide the change type by comparing with the item's current version.
      if [ ! -f "$STORE/latest/$key" ]; then
        change="new"
        echo "$item_id" >> "$STORE/items.txt"
      elif [ "$(cat "$STORE/latest/$key")" = "$version_id" ]; then
        change="unchanged"
      else
        change="changed"
      fi

      # Save the version only if we have never seen it, so nothing is duplicated or overwritten.
      mkdir -p "$STORE/versions/$key"
      if [ ! -f "$STORE/versions/$key/$version_id.json" ]; then
        jq -c . <<< "$line" > "$STORE/versions/$key/$version_id.json"
      fi
      echo "$version_id" > "$STORE/latest/$key"

      # Record this observation in the history, then print the change record.
      jq -cn --arg run_id "$run_id" --arg item_id "$item_id" --arg version_id "$version_id" --arg change "$change" \
        '{run_id: $run_id, item_id: $item_id, version_id: $version_id, change: $change}' >> "$STORE/history.jsonl"
      jq -cn --arg item_id "$item_id" --arg version_id "$version_id" --arg change "$change" \
        '{item_id: $item_id, version_id: $version_id, change: $change}'

      case "$change" in
        new) new=$((new + 1)) ;;
        changed) changed=$((changed + 1)) ;;
        unchanged) unchanged=$((unchanged + 1)) ;;
      esac
    done < "$input"

    # Write a receipt for this run; the PID in the name keeps earlier receipts from being overwritten.
    mkdir -p "$run_dir/logs"
    jq -n --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson total "$((new + changed + unchanged))" \
      --argjson new "$new" --argjson changed "$changed" --argjson unchanged "$unchanged" \
      '{stage: "store-upsert", status: "completed", input_count: $total, output_count: $total,
        changes: {new: $new, changed: $changed, unchanged: $unchanged},
        started_at: $started, finished_at: $finished,
        tools: ["bash", "jq"], models: [], cost_usd: 0, cost_estimated: false, errors: []}' \
      > "$run_dir/logs/store-upsert-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
    echo "store: $new new, $changed changed, $unchanged unchanged" >&2
    ;;

  list)
    [ $# -eq 1 ] || usage
    require_store
    # For each item in first-seen order, print its latest saved version.
    while IFS= read -r item_id; do
      key="$(key_for "$item_id")"
      cat "$STORE/versions/$key/$(cat "$STORE/latest/$key").json"
    done < "$STORE/items.txt"
    ;;

  get)
    [ $# -eq 2 ] || [ $# -eq 3 ] || usage
    require_store
    item_id="$2"
    key="$(key_for "$item_id")"
    # Use the requested version, or the latest one if none was given.
    if [ $# -eq 3 ]; then
      version_id="$3"
    elif [ -f "$STORE/latest/$key" ]; then
      version_id="$(cat "$STORE/latest/$key")"
    else
      version_id=""
    fi
    if [ -z "$version_id" ] || [ ! -f "$STORE/versions/$key/$version_id.json" ]; then
      echo "store: not found: $item_id ${3:-}" >&2
      exit 1
    fi
    cat "$STORE/versions/$key/$version_id.json"
    ;;

  *)
    usage
    ;;
esac
