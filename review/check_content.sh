#!/usr/bin/env bash
# Content checks: automatic proofreading of the briefs, drafts, and scripts before human review.
#   bash review/check_content.sh RUN_DIR > RUN_DIR/review.json
# Prints {review_id, passed, issues: [{artifact, piece_id, severity, message}]}.
#   error    blocks publication (passed becomes false)
#   warning  needs a human look (lengths, unused claims, judgment calls)
# review_id is a fingerprint of the as-of date, briefs, articles, and scripts: any edit changes it,
# so approval.json can prove which exact version was approved.
# Exit: 0 the check ran (even if passed is false), 1 the check could not run, 2 bad arguments.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:-}"
[ -f "$RUN_DIR/run.json" ] || { echo "usage: $0 RUN_DIR" >&2; exit 2; }
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CHECKS='
import hashlib, json, os, re, subprocess, sys
from datetime import date, timedelta
run_dir, repo = sys.argv[1], sys.argv[2]
run = json.load(open(run_dir + "/run.json"))
as_of = date.fromisoformat(run["as_of_date"])
issues = []
def issue(severity, artifact, message, piece=None):
    issues.append({"artifact": artifact, "piece_id": piece, "severity": severity, "message": message})
def read(path):
    return open(path, encoding="utf-8").read() if os.path.exists(path) else None
def squash(s):  # compare quotes ignoring spacing, case, and curly apostrophes
    return re.sub(r"\s+", " ", s.replace("’", "\x27")).strip().lower()
PIECES = ["01", "02", "03"]

# 1. Required files.
briefs = [json.loads(l) for l in open(run_dir + "/briefs.jsonl")] if os.path.exists(run_dir + "/briefs.jsonl") else []
drafts = {(kind, p): read("%s/%s/%s.md" % (run_dir, kind, p)) for kind in ("articles", "video_scripts") for p in PIECES}
for (kind, p), text in drafts.items():
    if text is None:
        issue("error", "%s/%s.md" % (kind, p), "file is missing", p)
for manifest in ("articles.jsonl", "video_scripts.jsonl"):
    if not os.path.exists(run_dir + "/" + manifest):
        issue("error", manifest, "manifest is missing")

# 2. Three distinct pieces.
by_piece = {b.get("piece_id"): b for b in briefs}
if sorted(by_piece) != PIECES:
    issue("error", "briefs.jsonl", "expected briefs 01, 02, 03; found %s" % sorted(by_piece))
arguments = [squash(b.get("argument", "")) for b in briefs]
if len(set(arguments)) < len(arguments):
    issue("error", "briefs.jsonl", "two pieces make the same argument")

# 3. Evidence: every reference resolves, is recent, and the series is well sourced.
kinds = set()
for p, b in by_piece.items():
    publishers = set()
    for c in b.get("claims", []):
        for ev in c.get("evidence", []):
            found = subprocess.run(["bash", repo + "/data/store.sh", "get", ev["item_id"], ev["version_id"]], capture_output=True, text=True)
            if found.returncode != 0:
                issue("error", "briefs.jsonl", "%s cites an item version not in the evidence store" % c["claim_id"], p); continue
            item, loc = json.loads(found.stdout), ev["locator"]
            publishers.add(item["publisher_id"]); kinds.add(item["kind"])
            if loc["type"] == "text" and squash(loc.get("quote", "")) not in squash(read(repo + "/" + item["text_path"])):
                issue("error", "briefs.jsonl", "%s quote not found word for word in %s" % (c["claim_id"], item["item_id"]), p)
            if loc["type"] == "segment":
                segments = json.load(open(repo + "/" + item["segments_path"])) if item["segments_path"] else []
                if loc.get("segment_id") not in [s["segment_id"] for s in segments]:
                    issue("error", "briefs.jsonl", "%s segment not found in %s" % (c["claim_id"], item["item_id"]), p)
            day = str(item.get("published_at"))[:10]
            if not (str(as_of - timedelta(days=29)) <= day <= str(as_of)):
                issue("error", "briefs.jsonl", "%s cites %s, published %s, outside the 30-day window" % (c["claim_id"], item["item_id"], day), p)
    if len(publishers) < 3:
        issue("error", "briefs.jsonl", "argument rests on %d independent publisher(s); 3 required" % len(publishers), p)
for kind in ("feed", "youtube", "podcast"):
    if kind not in kinds:
        issue("error", "briefs.jsonl", "the series cites no %s evidence" % kind)

# 4. Drafts and scripts: claim markers, sections, lengths, as-of date, and article/script match.
for p in PIECES:
    brief_claims = {c["claim_id"] for c in by_piece.get(p, {}).get("claims", [])}
    used = {}
    for kind in ("articles", "video_scripts"):
        text = drafts[(kind, p)]
        if text is None:
            continue
        name = "%s/%s.md" % (kind, p)
        used[kind] = set(re.findall(r"\[(\d\d-c\d+)\]", text))
        for claim in sorted(used[kind] - brief_claims):
            issue("error", name, "claim marker [%s] is not in brief %s" % (claim, p), p)
        for claim in sorted(brief_claims - used[kind]):
            issue("warning", name, "brief claim %s is not used" % claim, p)
        if run["as_of_date"] not in text and as_of.strftime("%B %-d, %Y") not in text:
            issue("warning", name, "no as-of date (%s) stated" % run["as_of_date"], p)
        if kind == "articles":
            body = re.split(r"^## Sources", text, flags=re.M)
            words = len(body[0].split())
            if len(body) < 2: issue("error", name, "no \"## Sources\" section for readers", p)
            if not 600 <= words <= 900: issue("warning", name, "body is %d words; target 600-900" % words, p)
        else:
            narration = " ".join(re.findall(r"^Narration:\s*(.*)$", text, flags=re.M))
            if "## YouTube Description" not in text: issue("error", name, "no \"## YouTube Description\" section", p)
            if re.search(r"\[\d\d-c\d+\]", narration): issue("error", name, "claim markers inside narration would be read aloud", p)
            if len(narration) > 2500: issue("error", name, "narration is %d characters; Google Vids allows at most 2500" % len(narration), p)
    if len(used) == 2 and used["articles"] != used["video_scripts"]:
        issue("warning", "video_scripts/%s.md" % p, "article and script use different claims; confirm their facts agree", p)

issue("warning", "all", "Human review required: check that interpretations are sound, sponsorships are disclosed, and uncertainty is stated honestly.")

# review_id: fingerprint of everything that was checked.
fingerprint = run["as_of_date"] + json.dumps(briefs, sort_keys=True) + "".join(drafts[k] or "" for k in sorted(drafts))
print(json.dumps({"review_id": hashlib.sha256(fingerprint.encode()).hexdigest(),
                  "passed": not any(i["severity"] == "error" for i in issues), "issues": issues}, indent=2))
'

review="$(python3 -c "$CHECKS" "$RUN_DIR" "$REPO")" || { echo "check_content: the check could not run" >&2; exit 1; }
echo "$review"
mkdir -p "$RUN_DIR/logs"
jq -n --argjson r "$review" --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{stage: "check_content", status: "completed", review_id: $r.review_id, passed: $r.passed,
    input_count: 3, output_count: 1, errors_found: ([$r.issues[] | select(.severity == "error")] | length),
    started_at: $started, finished_at: $finished, tools: ["python3"], models: [],
    cost_usd: 0, cost_estimated: false, errors: []}' \
  > "$RUN_DIR/logs/check_content-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
echo "check_content: passed=$(jq .passed <<< "$review"), $(jq '[.issues[] | select(.severity == "error")] | length' <<< "$review") errors" >&2
