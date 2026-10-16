#!/usr/bin/env python3
"""Normalize yt-dlp metadata without inventing publication dates."""
import json
import sys
from datetime import datetime, timezone

source, publisher, collected = sys.argv[1:4]
seen = set()
for line in sys.stdin:
    record = json.loads(line)
    video = record.get('id')
    if not video or video in seen:
        continue
    seen.add(video)
    published = None
    if record.get('upload_date'):
        try:
            published = datetime.strptime(record['upload_date'], '%Y%m%d').strftime('%Y-%m-%dT00:00:00Z')
        except ValueError:
            pass
    elif record.get('timestamp') is not None:
        published = datetime.fromtimestamp(record['timestamp'], timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    print(json.dumps(dict(item_id='youtube:' + video, source_id=source, publisher_id=publisher,
                         kind='youtube', title=record.get('title') or '',
                         url='https://www.youtube.com/watch?v=' + video,
                         published_at=published, retrieved_at=collected, media_url=None)))
