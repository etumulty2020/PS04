# Run PS04 with your ChatGPT Codex sign-in

The default provider is now `codex`. The four editorial and content components send their existing prompts and evidence to `codex exec`. They retain their own parsing, artifact creation, validation, and receipts. No API key is required. Codex uses your signed-in account's usage allowance; this is not unlimited or offline inference.

From `ps04`:

```bash
codex login status
# If needed: codex login, then choose ChatGPT sign-in.
bash run.sh
```

If `.env` or your shell explicitly selects an older provider, use:

```bash
LLM_PROVIDER=codex bash run.sh
```

Optional settings: `CODEX_MODEL` selects a model supported by your account; otherwise the CLI selects its default. `CODEX_TIMEOUT` is the per-request timeout in seconds (default 1800). Each invocation starts a fresh ephemeral session in an isolated temporary folder with a read-only sandbox, shell tools disabled, and user config omitted. API credential environment variables are removed before launch. Prompts include the needed evidence; the model is instructed not to use tools. Codex is an online service and receives those prompts and evidence.

Responses remain in the stage's existing reply JSON files. A sibling `.codex.log` records CLI diagnostics. Inference cost and token counts are not available through this adapter, so cost remains null; do not interpret missing usage as zero. Receipts identify the backend and configured model selection. All evidence checks and human review still apply. Rate limits or failed requests produce failed or incomplete stages rather than fabricated output.

Transcription uses local Whisper in Codex mode. Existing `.env` secrets are left on disk but not used by Codex requests. `LLM_PROVIDER=ollama` and `LLM_PROVIDER=openai` remain explicit alternatives. The Ollama instructions in LOCAL_SETUP.md are an optional alternative, not the default.
