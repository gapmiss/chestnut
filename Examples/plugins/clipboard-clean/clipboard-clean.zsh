#!/bin/zsh

text=$(cat)

if [[ -z "$text" ]]; then
    echo "No text provided" >&2
    exit 1
fi

# Smart double quotes -> straight
text="${text//“/\"}"
text="${text//”/\"}"

# Smart single quotes / apostrophes -> straight
text="${text//‘/\'}"
text="${text//’/\'}"

# Em dash -> --
text="${text//—/--}"

# En dash -> -
text="${text//–/-}"

# Ellipsis -> ...
text="${text//…/...}"

# Non-breaking space -> regular space
text="${text// / }"

# Strip trailing whitespace from each line
text=$(printf '%s\n' "$text" | sed 's/[[:space:]]*$//')

# Collapse multiple blank lines to one
text=$(printf '%s\n' "$text" | cat -s)

printf '%s' "$text"
