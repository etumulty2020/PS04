# Problem Set 4 Student Submission

Complete this document with your project details and links. Keep the course instructions in [README.md](README.md) and the required contracts in [ARCHITECTURE.md](ARCHITECTURE.md).

**Student:** Erin Tumulty  
**GitHub repository:** Add your repository link

## Topic and Audience

| **Publication name** | The Road to Mammoth |
| **Topic** | Non-firearm gear for the Mammoth Sniper Challenge, comparing manufacturer claims against independent reviewers and practitioner experience |
| **Audience and assumed knowledge** | Prospective Mammoth competitors who already shoot precision rifle recreationally and know basic gear terminology, but haven't yet competed in a multi-day team endurance event where all gear is carried on foot |
| **Central question** | Would this gear be good, required, or effective at Mammoth? What do independent tests and field experience show, and what tradeoffs should competitors consider? |
| **Scope** | Spotting and measuring gear · shooting support · rucking and endurance gear · clothing and protection · weather and survival gear |
| **Exclusions** | Firearms, ammunition, chassis, and stocks · gunsmithing · suppressors and NFA items · reloading · sales and deals posts · purchase or affiliate links |
| **Reason for readers to return** | To complete |

## Published Series

Replace each placeholder with the title or working link. Verify that course staff can open every publication.

| Piece | Title | Substack article | YouTube video |
| --- | --- | --- | --- |
| 1 | To complete | Add link | Add link |
| 2 | To complete | Add link | Add link |
| 3 | To complete | Add link | Add link |

**Separate technical demonstration video:** Add link

## Setup and Execution

### Required tools

Tested on macOS (Apple Silicon) with these versions:

| Tool | Version tested | Used for |
| --- | --- | --- |
| bash | 3.2.57 (macOS system bash) | Every pipeline component |
| jq | 1.7.1 | JSON/JSONL handling in every component |
| curl | 8.7.1 | Feed, page, and podcast downloads; OpenAI-compatible requests |
| Python 3 | 3.13.3 | Embedded parsing, the evidence-check helpers, and the model adapter |
| yt-dlp | 2026.08.19 | YouTube discovery, captions, and audio |
| ffmpeg | 9.0.2 | Audio conversion before transcription |
| mlx-whisper (Python package) | 0.4.3 | Local transcription with `mlx-community/whisper-large-v3-turbo` |
| Codex CLI | 0.161.0 | Default model provider (ChatGPT sign-in) |
| git | 2.50.1 | Version control |

`shasum` (built into macOS) computes the content hashes that the evidence store uses as version IDs. Ollama and Claude Code are needed only if you choose those providers (see below).

### Installation

```bash
# Homebrew packages
brew install jq yt-dlp ffmpeg python@3.13

# Local Whisper transcription (Apple Silicon)
python3 -m pip install mlx-whisper

# Codex CLI, then sign in with ChatGPT
brew install codex          # or: npm install -g @openai/codex
codex login
codex login status          # must report "Logged in using ChatGPT"
```

The first transcription downloads the Whisper model from Hugging Face (about 1.6 GB). The download is cached after that.

### Model and provider choices

Each AI stage (`select_items`, `create_briefs`, `write_articles`, `write_video_scripts`) loads [helpers/model_settings.sh](helpers/model_settings.sh), which reads `LLM_PROVIDER` and sends that stage's prompt to the chosen backend. The stage still does its own parsing, validation, and receipt writing.

| `LLM_PROVIDER` | Backend | Model setting | Credentials |
| --- | --- | --- | --- |
| `codex` (default; used for runs from `run-20261015T041643Z` on) | `codex exec`, via [helpers/codex_request.py](helpers/codex_request.py) | `CODEX_MODEL` (unset = Codex's default model) | ChatGPT sign-in through `codex login`; no API key |
| `claude` | `claude -p` (Claude Code) | `CLAUDE_MODEL` (default `claude-haiku-5-5`) | Claude Code sign-in |
| `ollama` | Local Ollama, OpenAI-compatible endpoint | `OLLAMA_MODEL` (default `qwen2.5:7b`) | None (see [LOCAL_SETUP.md](LOCAL_SETUP.md)) |
| `openai` | OpenAI Chat Completions | `OPENAI_MODEL` | `OPENAI_API_KEY` |

With Codex, each request runs in a new ephemeral session in a read-only sandbox, with shell tools disabled and user config ignored. All API-key variables are removed from the environment first. Codex doesn't report token counts, so the cost of those runs is recorded as `null` (unknown), not zero. Transcription always uses local Whisper unless `TRANSCRIBE_ENGINE=openai` is set with the `openai` provider.

### Credentials and environment variables

Put settings in a `.env` file in the repository root. `.env` is git-ignored and must never be committed. Only the variable names are listed here.

- **Credentials:** `OPENAI_API_KEY` (only for `LLM_PROVIDER=openai` or `TRANSCRIBE_ENGINE=openai`). The Codex and Claude providers use the CLIs' own sign-ins and remove any API keys from the environment.
- **Required by the `run.sh` config check:** `OPENAI_MODEL` must be set (non-empty), even though Codex mode ignores its value.
- **Provider and model:** `LLM_PROVIDER`, `CODEX_MODEL`, `CODEX_TIMEOUT` (seconds, default 1800), `CLAUDE_MODEL`, `CLAUDE_TIMEOUT`, `OLLAMA_MODEL`, `OPENAI_BASE_URL`.
- **Transcription:** `TRANSCRIBE_ENGINE` (`local` or `openai`), `WHISPER_MODEL`, `TRANSCRIBE_PARALLEL` (default 6), `OPENAI_TRANSCRIBE_MODEL`.
- **Cost estimates (optional; unset means unknown):** `OPENAI_INPUT_PRICE`, `OPENAI_OUTPUT_PRICE`, `OPENAI_TRANSCRIBE_PRICE`.
- **Tuning:** `SELECT_BATCH_ITEMS` (default 10), `SELECT_BATCH_CHARS` (default 120000), `YOUTUBE_DISCOVERY_LIMIT` (default 15), `EVIDENCE_DIR` (store location, for testing only).

Example `.env` for the default setup:

```bash
LLM_PROVIDER=codex
CODEX_MODEL=gpt-5.4-mini
OPENAI_MODEL=gpt-5.4-mini
```

### Populating the configuration

`run.sh` validates these files before it collects anything. Each run copies them into `RUN_DIR/config/` and `RUN_DIR/prompts/`, and the stages read those copies. Editing a file therefore affects only later runs.

1. **[config/project.json](config/project.json):** `publication_name`, `topic`, `audience`, and `central_question`, each a non-empty string. The topic text sets what's in scope (the gear categories) and the exclusions (firearms and ammunition reviews). The audience text sets the assumed knowledge (recreational precision-rifle shooters who haven't yet done a multi-day endurance event).
2. **[config/sources.json](config/sources.json):** a JSON array. Each entry has `source_id` (unique), `publisher_id`, `kind` (`feed`, `youtube`, or `podcast`), and `url`. Entries from the same producer share a `publisher_id` (for example `ruckauthority_feed` and `ruckauthority_yt`), so they count as one publisher when checking independence. I added two optional fields, `perspective` (manufacturer, independent, or practitioner) and `notes` (affiliate links, sponsorships, free review units, Mammoth sponsor ties); the selection prompt shows both to the model. The current list has 26 sources: 8 feeds, 11 YouTube channels or videos, and 7 podcasts. For YouTube, use a channel's RSS URL when you have the channel ID; handles, playlists, and single videos fall back to yt-dlp (see [collectors/YOUTUBE.md](collectors/YOUTUBE.md)).
3. **[config/editorial_policy.md](config/editorial_policy.md):** the rules the selection and brief stages must apply: relevance, official requirements, credibility, commercial incentives, freshness and novelty, diversity of perspectives, uncertainty, conflicting evidence, unsupported claims, exclusions, accept/reject/defer criteria, and the questions for the three pieces. The pre-revision version is kept in [config/editorial_policy_v0.md](config/editorial_policy_v0.md) for the policy comparison.
4. **Prompts in [prompts/](prompts/):** each stage has its own prompt. The policy and project brief are attached after the prompt at run time, so the prompts point to the policy instead of repeating it.
   - [select_items.md](prompts/select_items.md): one accept, reject, or defer decision per item, with reasons that name policy rules, returned as JSON Lines.
   - [create_briefs.md](prompts/create_briefs.md): three distinct arguments, with each claim linked to an item, a version, and an exact passage or timestamp.
   - [write_articles.md](prompts/write_articles.md): turns a brief into a Substack article for the audience.
   - [write_video_scripts.md](prompts/write_video_scripts.md): turns the same brief into a narrated video script with visual and on-screen-text cues.

### Running

The required entry commands are:

```bash
bash run.sh                          # new live run (Codex by default)
bash run.sh --package runs/RUN_ID    # after human approval: recheck content and build the package
```

Replace `RUN_ID` with a run directory, for example `runs/run-20261015T135930Z`. Other useful forms:

```bash
LLM_PROVIDER=codex CODEX_MODEL=gpt-5.4-mini bash run.sh   # choose provider/model for one run
bash run.sh --mode replay                                  # label a run as a replay
```

Each component can be rerun on its own against an existing run directory, for example to replay one stage without recollecting:

```bash
bash workflows/collect_sources.sh RUN_DIR
bash workflows/create_series.sh RUN_DIR
bash editorial/select_items.sh RUN_DIR < RUN_DIR/eligible.jsonl > RUN_DIR/decisions.jsonl
bash editorial/create_briefs.sh RUN_DIR < RUN_DIR/decisions.jsonl > RUN_DIR/briefs.jsonl
bash content/write_articles.sh RUN_DIR < RUN_DIR/briefs.jsonl > RUN_DIR/articles.jsonl
bash content/write_video_scripts.sh RUN_DIR < RUN_DIR/briefs.jsonl > RUN_DIR/video_scripts.jsonl
bash review/check_content.sh RUN_DIR > RUN_DIR/review.json
bash reporting/summarize_run.sh RUN_DIR > RUN_DIR/summary.json
bash data/store.sh list                     # latest version of every stored item
bash data/store.sh get ITEM_ID [VERSION_ID] # one stored item version
```

## Architecture and Manual Handoffs

Add a diagram of your implemented pipeline and explain any additional components or helpers. Show where models are called and where evidence is stored.

Describe the human editorial review, Google Vids or HeyGen production, and Substack and YouTube publishing steps. Identify the files passed into each manual step and the resulting artifacts.

## Evidence and Runs

Link to the retained evidence, editorial decisions, briefs, content checks, and intermediate artifacts needed to inspect the complete workflow. Keep referenced text and transcript files accessible. Explain how to retrieve media omitted from the repository.

| Run | Actual date | Run artifacts and logs | Elapsed time | Approximate cost |
| --- | --- | --- | --- | --- |
| First live run | To complete | Add path or link | To complete | To complete |
| Second live run | To complete | Add path or link | To complete | To complete |

Explain what changed between runs. Identify unknown or estimated costs. Provide the records demonstrating duplicate handling, the date-window checks, and collection failure or recovery. Label any fixture replay or simulated failure.

Trace one published claim to its brief, editorial decision, source version, and exact supporting passage or timestamp.

## Editorial Review

Link to the editorial policy and prompts used. Provide your review of at least three accepted and three rejected or deferred items, comparing the AI's reasons with your own judgment.

Show the policy before and after your revision, the affected stage outputs, and what changed. Record factual corrections, remaining limitations, and the evidence for your final publication approval.

## Reflection

Explain one insight the system produced, one editorial failure or limitation, and the next improvement you would make. Discuss one architectural tradeoff and why your choice fits this project.
