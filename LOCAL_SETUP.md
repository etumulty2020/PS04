# Running without OpenAI credits

Set `LLM_PROVIDER=ollama` to use Ollama on this Mac for selection, briefs, articles, and video scripts. Transcription uses local Whisper. No OpenAI key is needed in this mode; the existing key in `.env` is replaced in the process environment with a dummy value for local requests, and the file is left intact.

1. Install Ollama from https://ollama.com/download/mac and open the app.
2. In Terminal, download the model once:

   ```bash
   ollama pull qwen2.5:7b
   ```

3. From the `ps04` folder, run:

   ```bash
   LLM_PROVIDER=ollama bash run.sh
   ```

The script loads `.env` and checks that Ollama has the selected model before collecting sources. Set `OLLAMA_MODEL` in `.env` to use another installed local model. Set `LLM_PROVIDER=ollama` explicitly if your shell previously selected OpenAI. Local model API charges are zero; downloads, disk space, electricity, and execution time still apply. Internet access is still needed to collect sources and initially download models.

A local model may fail the structured output or evidence checks, especially when many transcripts exceed its context window. Failed checks remain failures; review receipts and model replies rather than treating incomplete output as a completed assignment. Existing human review and packaging requirements still apply.

To explicitly return to paid OpenAI inference, set `LLM_PROVIDER=openai` with your `OPENAI_API_KEY` and `OPENAI_MODEL`. Each AI component sources `helpers/model_settings.sh`, preserving the independently runnable architecture. Receipts record the chosen model and zero estimated inference cost in local mode.
