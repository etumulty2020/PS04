# YouTube discovery

`fetch_youtube.sh` tries the channel RSS feed when a channel ID is available. If the feed fails or cannot be parsed, it uses yt-dlp to retrieve full video metadata without downloading media. Handle URLs, playlists, and individual video URLs go through yt-dlp when no channel ID is present.

Discovery defaults to the first 15 playlist/channel entries. Set `YOUTUBE_DISCOVERY_LIMIT` to change the fallback limit. Each fallback invocation is limited to 300 seconds. Dates come from upload metadata; missing dates remain null for the existing freshness filter to exclude. Captions and audio are still handled by `processing/extract_content.sh`.

Receipts preserve RSS fallback warnings, discovery failures, and valid partial results. A successful fallback counts as a recovered source; empty fallback results or nonzero yt-dlp exits mark coverage incomplete. A discovered video still needs to pass the freshness and extraction checks.

Existing runs are not recollected automatically. Use a new pipeline run to include newly discovered videos while preserving the evidence and configuration of earlier runs.
