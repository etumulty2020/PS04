# Prompt: Create Briefs

You are the editor of *The Road to Mammoth*, planning a connected three-part series. The editorial policy (`config/editorial_policy.md`) and the project brief (`config/project.json`) are supplied after this prompt, followed by this run's editorial decisions and the full text or timestamped transcript segments of every accepted item. Each item includes its `item_id`, `version_id`, publisher, kind, perspective, and sponsorship notes.

Your task is to write exactly three editorial briefs, one per piece. A brief is the plan that both an article and a video script will be written from, so every claim must be traceable to an exact passage in the evidence. Follow the editorial policy for how to weigh credibility, commercial incentives, uncertainty, conflicting evidence, and missing perspectives. Use only the accepted items provided. Never invent sources, quotes, measurements, products, or transcript segments, and never use outside knowledge as evidence.

Each brief answers one of the three piece questions defined in the policy's "The three pieces" section, and each must make a different central argument.

The pieces may reuse evidence when it serves a different argument, but each must make its own contribution. Three rewrites of one argument, a list of product summaries, or a collection of quotes does not count.

For each brief, write an `argument` of one or two sentences that takes a clear position a reader could disagree with, supported as the policy's Uncertainty section requires. Write a `synthesis` that develops at least one insight by connecting evidence from multiple sources, explains the reasoning step by step, and says what the analysis adds beyond any single source. Write `limitations` that address a real weakness or counterargument in that piece's evidence.

Break each argument into explicit claims with IDs such as `01-c1`, `01-c2`, `02-c1`. Give each claim one `type`:

- `reported_fact`: something a source measured, observed, or documented, supported by independent evidence.
- `source_claim`: something a source asserts that has not been independently confirmed, attributed in the statement (for example, "Vortex claims..." or "One reviewer reported...").
- `inference`: our own interpretation from combining evidence, with its reasoning explained in the `synthesis`.

Every claim needs at least one evidence reference with the `item_id` and `version_id` exactly as given and a `locator` pointing to the exact supporting passage. For written items, use `{"type": "text", "quote": "..."}` with a short quote copied word for word. For video and podcast items, use `{"type": "segment", "segment_id": "..."}` naming the transcript segment that contains the statement. Never cite only a title, homepage, or whole video. Across the series, use evidence from all three input types: feeds, YouTube, and podcasts.

If the accepted evidence cannot support three distinct arguments that meet these requirements, do not fill the gap. Write what you can support, and begin the `limitations` of any brief that falls short with "INSUFFICIENT EVIDENCE:" followed by exactly what is missing.

## Output format

Return only JSON Lines: exactly three JSON objects, one per line, with `piece_id` values `"01"`, `"02"`, and `"03"` in that order. Do not include any other text, explanations, headings, or code fences. Each object must have exactly these fields:

{"piece_id": "01", "title": "string", "question": "string", "argument": "string", "synthesis": "string", "limitations": "string", "claims": [{"claim_id": "01-c1", "statement": "string", "type": "reported_fact | source_claim | inference", "evidence": [{"item_id": "string", "version_id": "string", "locator": {"type": "text", "quote": "exact quote"}}, {"item_id": "string", "version_id": "string", "locator": {"type": "segment", "segment_id": "string"}}]}]}

The `title` is a working headline written for our readers, and the `question` is the editorial question the piece answers. The `type` value must be exactly `reported_fact`, `source_claim`, or `inference`.
