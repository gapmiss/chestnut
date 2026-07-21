#!/usr/bin/env python3
"""Save a URL as a bookmark note with page title and description."""

import json
import os
import re
import sys
import urllib.request
from html.parser import HTMLParser


class MetaParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.title = ""
        self.description = ""
        self._in_title = False
        self._title_parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "title":
            self._in_title = True
        elif tag == "meta":
            d = dict(attrs)
            name = (d.get("name") or d.get("property") or "").lower()
            content = d.get("content", "")
            if name in ("description", "og:description") and not self.description:
                self.description = content
            elif name == "og:title" and not self.title:
                self.title = content

    def handle_data(self, data):
        if self._in_title:
            self._title_parts.append(data)

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
            if not self.title:
                self.title = "".join(self._title_parts).strip()


def fetch_meta(url):
    """Fetch page title and description from HTML meta tags."""
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0 (Macintosh; chestnut-plugin)"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            charset = resp.headers.get_content_charset() or "utf-8"
            html = resp.read(65536).decode(charset, errors="replace")
    except Exception:
        return "", ""

    parser = MetaParser()
    try:
        parser.feed(html)
    except Exception:
        pass
    return parser.title, parser.description


def main():
    url = sys.stdin.read().strip()
    if not url:
        print("No URL provided", file=sys.stderr)
        sys.exit(1)

    timestamp = os.environ.get("CHESTNUT_TIMESTAMP", "")
    source_app = os.environ.get("CHESTNUT_SOURCE_APP", "")
    date_prefix = timestamp[:10] if len(timestamp) >= 10 else ""

    title, description = fetch_meta(url)
    if not title:
        title = re.sub(r"^https?://", "", url).split("?")[0].rstrip("/")

    from urllib.parse import urlparse

    parsed = urlparse(url)
    domain = parsed.netloc.removeprefix("www.")

    parts = []
    parts.append("---")
    parts.append(f'title: "{yaml_escape(title)}"')
    parts.append(f"url: {url}")
    parts.append(f"domain: {domain}")
    if source_app:
        parts.append(f'source_app: "{source_app}"')
    parts.append(f"date: {timestamp}")
    parts.append("tags: [bookmark]")
    parts.append("---")
    parts.append("")
    parts.append(f"# [{title}]({url})")
    parts.append("")
    parts.append(f"**{domain}**" + (f" · {date_prefix}" if date_prefix else ""))
    parts.append("")

    if description:
        parts.append(f"> {description}")
        parts.append("")

    parts.append("")
    content = "\n".join(parts)

    safe_title = re.sub(r'[\\/:*?"<>|]', "", title)[:80].strip()
    filename = f"{safe_title}.md" if safe_title else "bookmark.md"

    envelope = {
        "action": "save",
        "content": content,
        "filename": filename,
        "vault": "ask",
        "notify": f"Bookmark saved: {domain}",
    }
    print(json.dumps(envelope))


def yaml_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


if __name__ == "__main__":
    main()
