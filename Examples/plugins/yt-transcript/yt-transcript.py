#!/usr/bin/env python3
"""Download a YouTube transcript and save it as a vault note."""

import json
import os
import re
import subprocess
import sys
import tempfile


def main():
    url = sys.stdin.read().strip()
    if not url:
        print("No URL provided", file=sys.stderr)
        sys.exit(1)

    if not re.match(r"https?://(www\.)?(youtube\.com|youtu\.be)/", url):
        print("Not a YouTube URL", file=sys.stderr)
        sys.exit(1)

    # Metadata via --dump-json (no download).
    try:
        proc = subprocess.run(
            ["yt-dlp", "--no-download", "--no-playlist", "--dump-json", url],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except FileNotFoundError:
        print("yt-dlp not found", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("yt-dlp timed out fetching metadata", file=sys.stderr)
        sys.exit(1)

    if proc.returncode != 0:
        print(proc.stderr.strip().split("\n")[-1], file=sys.stderr)
        sys.exit(1)

    meta = json.loads(proc.stdout)
    title = meta.get("title", "Untitled")
    channel = meta.get("channel") or meta.get("uploader", "")
    upload_date = meta.get("upload_date", "")
    duration = meta.get("duration") or 0
    video_id = meta.get("id", "")
    description = meta.get("description", "")

    formatted_date = (
        f"{upload_date[:4]}-{upload_date[4:6]}-{upload_date[6:8]}"
        if len(upload_date) == 8
        else upload_date
    )

    h, rem = divmod(int(duration), 3600)
    m, s = divmod(rem, 60)
    duration_str = f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"

    # Transcript: prefer manual subs, fall back to auto-generated.
    transcript = fetch_transcript(url, video_id)

    # Build the note.
    parts = []
    parts.append("---")
    parts.append(f'title: "{yaml_escape(title)}"')
    parts.append(f'channel: "{yaml_escape(channel)}"')
    parts.append(f"date: {formatted_date}")
    parts.append(f'duration: "{duration_str}"')
    parts.append(f"url: {url}")
    parts.append(f"video_id: {video_id}")
    parts.append("tags: [youtube, transcript]")
    parts.append("---")
    parts.append("")
    parts.append(f"# {title}")
    parts.append("")
    parts.append(f"**{channel}** · {formatted_date} · {duration_str}")
    parts.append("")
    parts.append(f"![Watch on YouTube]({url})")
    parts.append("")

    if description:
        desc = truncate_description(description)
        quoted = "\n".join(f"> {line}" if line else ">" for line in desc.split("\n"))
        parts.append("## Description")
        parts.append("")
        parts.append(quoted)
        parts.append("")

    if transcript:
        parts.append("## Transcript")
        parts.append("")
        for ts_str, seconds, text in transcript:
            link = f"https://youtu.be/{video_id}?t={seconds}"
            parts.append(f"**[{ts_str}]({link})** {text}")
        parts.append("")
    else:
        parts.append("> *No transcript available for this video.*")
        parts.append("")

    content = "\n".join(parts)
    safe_title = re.sub(r'[\\/:*?"<>|]', "", title)[:100].strip()

    envelope = {
        "action": "save",
        "content": content,
        "filename": f"{safe_title}.md",
        "vault": "ask",
        "notify": f"Transcript saved: {title}",
    }
    print(json.dumps(envelope))


def fetch_transcript(url, video_id):
    """Download subtitles via yt-dlp, parse SRT into (timestamp, seconds, text) triples."""
    with tempfile.TemporaryDirectory() as tmpdir:
        subprocess.run(
            [
                "yt-dlp",
                "--skip-download",
                "--write-subs",
                "--write-auto-subs",
                "--sub-lang",
                "en",
                "--convert-subs",
                "srt",
                "--no-playlist",
                "-o",
                os.path.join(tmpdir, "%(id)s.%(ext)s"),
                url,
            ],
            capture_output=True,
            timeout=20,
        )

        for f in sorted(os.listdir(tmpdir)):
            if f.endswith(".srt"):
                with open(os.path.join(tmpdir, f)) as fh:
                    return parse_srt(fh.read())
    return []


def parse_srt(srt_text):
    """Parse SRT into deduplicated (timestamp_str, total_seconds, text) triples.

    Auto-generated subs have two lines per cue: line 1 repeats from the
    previous cue, line 2 is new. Take only the last line to avoid overlap.
    """
    blocks = re.split(r"\n\n+", srt_text.strip())
    result = []
    seen = set()

    for block in blocks:
        lines = block.strip().split("\n")
        if len(lines) < 3:
            continue

        ts_match = re.match(r"(\d{2}):(\d{2}):(\d{2})", lines[1])
        if not ts_match:
            continue

        hours, mins, secs = (
            int(ts_match.group(1)),
            int(ts_match.group(2)),
            int(ts_match.group(3)),
        )
        total_seconds = hours * 3600 + mins * 60 + secs
        ts_str = f"{hours}:{mins:02d}:{secs:02d}" if hours else f"{mins}:{secs:02d}"

        text = re.sub(r"<[^>]+>", "", lines[-1]).strip()

        if not text or text in seen:
            continue
        seen.add(text)
        result.append((ts_str, total_seconds, text))

    return result


def truncate_description(desc, max_lines=10):
    lines = desc.split("\n")
    if len(lines) > max_lines:
        return "\n".join(lines[:max_lines]) + "\n…"
    return desc


def yaml_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


if __name__ == "__main__":
    main()
