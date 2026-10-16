Plan three distinct, connected editorial briefs for The Road to Mammoth. Apply the supplied editorial policy and project brief. Use only the supplied accepted evidence packets. Packets may be excerpted: omitted material is not proof that a limitation or opposing view does not exist. Acknowledge material gaps. Never invent facts, quotations, sources, or segments.

Return only three JSONL objects, in order 01, 02, 03, with these fields:
{"piece_id":"01","title":"...","question":"...","argument":"...","synthesis":"...","limitations":"...","claims":[{"claim_id":"01-c1","statement":"...","type":"source_claim","evidence":[{"item_id":"...","version_id":"...","locator":{"type":"text","quote":"exact passage"}}]}]}

Use the policy's three editorial questions. Give each piece a distinct, defensible argument, synthesis connecting multiple sources with explicit reasoning, and a meaningful limitation or counterargument. Cite at least three independent publishers per piece. Across the series, use feeds, YouTube, and podcasts. Reusing evidence must serve a different argument.

Every claim must have evidence. Types: reported_fact (documented observation or measurement), source_claim (attributed assertion without independent confirmation), or inference (interpretation whose reasoning is in synthesis). Preserve item_id and version_id exactly. Written locators use {"type":"text","quote":"short verbatim passage"}; media locators use {"type":"segment","segment_id":"original ID"}. Cite only passages actually supplied; never a title or whole source. Do not treat commercial claims as independent confirmation.

If requirements cannot be supported, begin the affected brief's limitations with "INSUFFICIENT EVIDENCE:" and specify what is missing. Do not fill gaps. No headings, code fences, or extra text.
