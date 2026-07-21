#!/bin/bash

path="$CHESTNUT_FILE_PATH"
if [[ -z "$path" || ! -f "$path" ]]; then
    echo "No image file" >&2
    exit 1
fi

width=$(mdls -name kMDItemPixelWidth -raw "$path" 2>/dev/null)
height=$(mdls -name kMDItemPixelHeight -raw "$path" 2>/dev/null)
color=$(mdls -name kMDItemColorSpace -raw "$path" 2>/dev/null)

bytes=$(stat -f%z "$path" 2>/dev/null || echo "0")
if (( bytes >= 1048576 )); then
    size="$(( bytes / 1048576 )) MB"
elif (( bytes >= 1024 )); then
    size="$(( bytes / 1024 )) KB"
else
    size="${bytes} B"
fi

dims=""
if [[ "$width" != "(null)" && "$height" != "(null)" ]]; then
    dims="${width}×${height}"
fi

parts=()
[[ -n "$dims" ]] && parts+=("$dims")
parts+=("$size")
[[ "$color" != "(null)" && -n "$color" ]] && parts+=("$color")

info=$(IFS=" · "; echo "${parts[*]}")

printf '%s' "$info"
