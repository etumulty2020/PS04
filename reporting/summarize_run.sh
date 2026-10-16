#!/usr/bin/env bash
# Run summary: a report card of one run, built from its saved files and receipts.
#   bash reporting/summarize_run.sh RUN_DIR > RUN_DIR/summary.json
# Works for unfinished runs. A count is null when that step never ran (its file is missing)
# and 0 when it ran and found nothing. Costs are added up only from receipts that recorded
# one; steps with unknown cost are listed, never counted as $0.
# Status: ready_for_production (packaged and approved), awaiting_review (drafts passed the
# checks and wait for you), or failed (anything else).
# Exit: 0 summary printed, 1 the summary could not be made, 2 bad arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

SUMMARY='
import glob, json, os, sys
from datetime import datetime
run_dir = sys.argv[1]
run = json.load(open(run_dir + "/run.json"))

def lines(name):   # the records in a .jsonl file, or None if the file does not exist
    path = run_dir + "/" + name
    return [json.loads(l) for l in open(path) if l.strip()] if os.path.exists(path) else None
def count(records, test=lambda r: True):
    return None if records is None else sum(1 for r in records if test(r))
def load(name):
    path = run_dir + "/" + name
    return json.load(open(path)) if os.path.exists(path) else None

candidates, items, changes = lines("candidates.jsonl"), lines("items.jsonl"), lines("changes.jsonl")
eligible, exclusions, decisions = lines("eligible.jsonl"), lines("exclusions.jsonl"), lines("decisions.jsonl")
articles, scripts = lines("articles.jsonl"), lines("video_scripts.jsonl")
review, approval, package = load("review.json"), load("approval.json"), load("package/manifest.json")
links = load("package/publication_links.json")

# Receipts: every file in logs/ that names a stage (the latest one per stage wins).
receipts = {}
for path in sorted(glob.glob(run_dir + "/logs/*.json")):
    try:
        r = json.load(open(path))
    except ValueError:
        continue
    if isinstance(r, dict) and "stage" in r and r["stage"] != "summarize_run":
        receipts[r["stage"]] = r

distinct = None if candidates is None else len({c["item_id"] for c in candidates})
counts = {
    "discovered": count(candidates), "duplicate_observations": None if candidates is None else len(candidates) - distinct,
    "extracted": count(items),
    "new": count(changes, lambda r: r["change"] == "new"), "changed": count(changes, lambda r: r["change"] == "changed"),
    "unchanged": count(changes, lambda r: r["change"] == "unchanged"),
    "eligible": count(eligible), "excluded": count(exclusions),
    "accepted": count(decisions, lambda r: r["decision"] == "accept"), "rejected": count(decisions, lambda r: r["decision"] == "reject"),
    "deferred": count(decisions, lambda r: r["decision"] == "defer"),
    "articles": count(articles), "video_scripts": count(scripts),
}

def coverage(records):   # distinct items by kind and by independent publisher
    if records is None:
        return None
    unique = {r["item_id"]: r for r in records}.values()
    by_kind, by_publisher = {}, {}
    for r in unique:
        by_kind[r["kind"]] = by_kind.get(r["kind"], 0) + 1
        by_publisher[r["publisher_id"]] = by_publisher.get(r["publisher_id"], 0) + 1
    return {"by_kind": by_kind, "independent_publishers": len(by_publisher), "by_publisher": by_publisher}

accepted = None if decisions is None or eligible is None else [e for e in eligible if e["item_id"] in {d["item_id"] for d in decisions if d["decision"] == "accept"}]

# Status: packaged and approved > drafts that passed the checks > failed.
approved = approval is not None and approval.get("decision") == "approve"
if package and approved and package.get("review_id") == approval.get("review_id"):
    status = "ready_for_production"
elif counts["articles"] == 3 and counts["video_scripts"] == 3 and review and review["passed"]:
    status = "awaiting_review"
else:
    status = "failed"

manual = {"failed": ["Fix the failed steps listed in problem_stages, then rerun them and the content checks."],
          "awaiting_review": ["Read and correct the drafts, create approval.json with the current review_id, then run: bash run.sh --package " + run_dir],
          "ready_for_production": ["Make the videos in Google Vids, upload them to YouTube, and publish the articles on Substack (see package/MANUAL_STEPS.md)."]}[status]
if links is None or any(l["substack_url"] is None or l["youtube_url"] is None for l in links):
    manual.append("After publishing, fill in package/publication_links.json.")

times = [r[k] for r in receipts.values() for k in ("started_at", "finished_at") if r.get(k)]
seconds = lambda t: datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").timestamp()
print(json.dumps({
    "run_id": run["run_id"], "as_of_date": run["as_of_date"], "mode": run["mode"], "status": status,
    "counts": counts,
    "coverage": {"collected": coverage(candidates), "eligible": coverage(eligible), "accepted": coverage(accepted)},
    "problem_stages": [{"stage": s, "status": r.get("status"), "errors": r.get("errors")} for s, r in receipts.items() if r.get("status") != "completed"],
    "elapsed_seconds": max(map(seconds, times)) - seconds(run["started_at"]) if times else None,
    "models": sorted({m for r in receipts.values() for m in r.get("models") or []}),
    "tools": sorted({t for r in receipts.values() for t in r.get("tools") or []}),
    "cost": {"known_usd": round(sum(r["cost_usd"] for r in receipts.values() if r.get("cost_usd") is not None), 4),
             "includes_estimates": any(r.get("cost_estimated") for r in receipts.values()),
             "unknown_cost_stages": sorted(s for s, r in receipts.items() if r.get("cost_usd") is None)},
    "review_passed": None if review is None else review["passed"],
    "approval": None if approval is None else approval.get("decision"),
    "published_links": links,
    "remaining_manual_actions": manual,
}, indent=2))
'

summary="$(cd "$REPO" && python3 -c "$SUMMARY" "$RUN_DIR")" || { echo "summarize_run: could not build the summary" >&2; exit 1; }
echo "$summary"
mkdir -p "$RUN_DIR/logs"
jq -n --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{stage: "summarize_run", status: "completed", input_count: null, output_count: 1, started_at: $started,
    finished_at: $finished, tools: ["python3"], models: [], cost_usd: 0, cost_estimated: false, errors: []}' \
  > "$RUN_DIR/logs/summarize_run-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
