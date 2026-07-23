#!/bin/bash
set -euo pipefail

img="$CHESTNUT_FILE_PATH"
[ -f "$img" ] || { echo "No image file" >&2; exit 1; }

ext="${img##*.}"
ts=$(date +%Y%m%d-%H%M%S)
attach="clip-${ts}.${ext}"

cat <<EOF
{"action":"capture","content":"![[${attach}]]","attachments":[{"source":"${img}","filename":"${attach}"}]}
EOF
