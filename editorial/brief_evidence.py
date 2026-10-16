#!/usr/bin/env python3
"""Build bounded, verbatim evidence excerpts for brief planning."""
import json
from pathlib import Path
import re
import sys

repo, run, accepted, decisions, output = map(Path, sys.argv[1:6])
items = [json.loads(line) for line in accepted.read_text().splitlines() if line.strip()]
decisions = {d['version_id']: d for d in map(json.loads, decisions.read_text().splitlines())}
sources = {s['source_id']: s for s in json.loads((run / 'config/sources.json').read_text())}
project = json.loads((run / 'config/project.json').read_text())
# Equal per-source budgets prevent long episodes from dominating the input.
budget = min(12000, 450000 // max(1, len(items)))
stop = set('about after before from have into that their these they this those with which would source evidence accepted'.split())
packets = []
for item in items:
    decision = decisions[item['version_id']]
    source = sources.get(item['source_id'], {})
    query = item.get('title', '') + ' ' + decision.get('reason', '') + ' ' + project.get('central_question', '')
    terms = set(re.findall(r'[a-z]{4,}', query.lower())) - stop
    media = bool(item.get('segments_path'))
    if media:
        candidates = json.loads((repo / item['segments_path']).read_text())
    else:
        text = (repo / item['text_path']).read_text()
        # Exact contiguous slices; never paraphrase or join text within a quote.
        candidates = [{'text': text[i:i+1200]} for i in range(0, len(text), 1200)]
    def cost(i):
        return len(json.dumps(candidates[i], ensure_ascii=False))
    total = sum(cost(i) for i in range(len(candidates)))
    if total <= budget:
        chosen = list(range(len(candidates)))
    else:
        chosen = []; used = 0
        # Reserve a third for passages spread across the original, including its end.
        count = max(2, min(8, len(candidates)))
        spread = sorted({round(i * (len(candidates)-1) / (count-1)) for i in range(count)}) if candidates else []
        for i in spread:
            if used + cost(i) <= budget // 3:
                chosen.append(i); used += cost(i)
        ranked = sorted(range(len(candidates)), key=lambda i: (-len(terms & set(re.findall(r'[a-z]{4,}', candidates[i]['text'].lower()))), i))
        for i in ranked:
            if i not in chosen and used + cost(i) <= budget:
                chosen.append(i); used += cost(i)
        chosen.sort()
    if candidates and not chosen:
        raise SystemExit('An evidence segment exceeds the brief packet budget; split source segments before planning')
    packet = {k: item.get(k) for k in ('item_id','version_id','kind','publisher_id','title','url','published_at')}
    packet.update(source_notes={k: source.get(k) for k in ('perspective','notes')},
                  selection_reason=decision.get('reason'), excerpted=len(chosen)<len(candidates),
                  passages=[candidates[i] for i in chosen])
    packets.append(packet)
text = ('Evidence packets contain verbatim excerpts, not full sources. Omitted passages may contain '
        'qualifications or counterevidence. Do not infer absence from omission; acknowledge this limitation. '
        'Cite text exactly or use the original segment_id and timestamps.\n' +
        '\n'.join(json.dumps(p, ensure_ascii=False, separators=(',', ':')) for p in packets))
if len(text) > 600000:
    raise SystemExit('Brief evidence exceeds the 600000-character budget; reduce accepted items or metadata')
output.write_text(text)
print(f'create_briefs: evidence packet {len(text)} characters for {len(items)} sources', file=sys.stderr)
