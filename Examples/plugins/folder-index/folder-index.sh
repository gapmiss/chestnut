#!/bin/bash

dir="$CHESTNUT_FILE_PATH"
if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "Not a directory" >&2
    exit 1
fi

dirname=$(basename "$dir")
timestamp="${CHESTNUT_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
date_prefix="${timestamp:0:10}"

attachments="["
content="---
type: folder-index
source: \"$dirname\"
date: $timestamp
tags: [import]
---

# $dirname

| File | Size |
|------|------|"

first=1
while IFS= read -r -d '' file; do
    name=$(basename "$file")
    bytes=$(stat -f%z "$file" 2>/dev/null || echo "0")
    if (( bytes >= 1048576 )); then
        size="$(( bytes / 1048576 )) MB"
    elif (( bytes >= 1024 )); then
        size="$(( bytes / 1024 )) KB"
    else
        size="${bytes} B"
    fi

    content+="
| [[$name]] | $size |"

    escaped_source=$(printf '%s' "$file" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')
    escaped_name=$(printf '%s' "$name" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')

    if (( first )); then
        first=0
    else
        attachments+=","
    fi
    attachments+="{\"source\":\"$escaped_source\",\"filename\":\"$escaped_name\"}"
done < <(find "$dir" -maxdepth 1 -type f -not -name '.*' -print0 | sort -z)

attachments+="]"

if (( first )); then
    echo "Folder is empty" >&2
    exit 1
fi

content+="
"

escaped_content=$(printf '%s' "$content" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')

cat <<EOF
{"action":"save","content":"$escaped_content","filename":"$date_prefix $dirname.md","folder":"$dirname","vault":"ask","notify":"Imported $dirname","attachments":$attachments}
EOF
