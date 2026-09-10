#!/usr/bin/env bash
set -euo pipefail

SOURCE_URL="${SOURCE_URL:-https://www.gutenberg.org/cache/epub/feeds/txt-files.tar.zip}"
CHUNK_MIB="${CHUNK_MIB:-90}"
TARGET_GIB="${TARGET_GIB:-8}"
PUSH_EVERY="${PUSH_EVERY:-8}"
START_OFFSET="${START_OFFSET:-8587837440}"
START_PART="${START_PART:-92}"
OUT_DIR="${OUT_DIR:-archive_parts}"
STATE_FILE="${STATE_FILE:-continuation-state.json}"
MANIFEST="${MANIFEST:-archive-manifest.tsv}"

CHUNK_BYTES=$((CHUNK_MIB * 1024 * 1024))
TARGET_BYTES=$((TARGET_GIB * 1024 * 1024 * 1024))

command -v curl >/dev/null 2>&1 || { echo 'curl is required'; exit 1; }
command -v git >/dev/null 2>&1 || { echo 'git is required'; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo 'sha256sum is required'; exit 1; }

mkdir -p "$OUT_DIR"

printf 'source_url\tpart\tstart_byte\tend_byte\tbytes\tsha256\tfilename\n' > "$MANIFEST".new
if [[ -f "$MANIFEST" ]]; then
  tail -n +2 "$MANIFEST" >> "$MANIFEST".new || true
fi
mv "$MANIFEST".new "$MANIFEST"

repo_added=0
offset="$START_OFFSET"
part="$START_PART"

while (( repo_added + CHUNK_BYTES <= TARGET_BYTES )); do
  start="$offset"
  end=$((start + CHUNK_BYTES - 1))
  filename=$(printf '%s/pg-all-text-%05d.part' "$OUT_DIR" "$part")
  tmp="${filename}.download"

  echo "Downloading bytes ${start}-${end} -> ${filename}"
  curl -L --fail --retry 5 --retry-delay 5 --connect-timeout 30 \
    --range "${start}-${end}" "$SOURCE_URL" -o "$tmp"

  actual=$(wc -c < "$tmp" | tr -d ' ')

  if (( actual > CHUNK_BYTES )); then
    rm -f "$tmp"
    echo "ERROR: server ignored byte-range request (received $actual bytes)."
    exit 3
  fi
  if (( actual == 0 )); then
    rm -f "$tmp"
    echo "No more bytes returned; archive appears complete."
    break
  fi

  mv "$tmp" "$filename"
  sha=$(sha256sum "$filename" | awk '{print $1}')
  real_end=$((start + actual - 1))
  printf '%s\t%05d\t%s\t%s\t%s\t%s\t%s\n' \
    "$SOURCE_URL" "$part" "$start" "$real_end" "$actual" "$sha" "$filename" >> "$MANIFEST"

  offset=$((real_end + 1))
  repo_added=$((repo_added + actual))

  cat > "$STATE_FILE" <<EOF
{
  "source_url": "$SOURCE_URL",
  "first_offset_in_this_repo": $START_OFFSET,
  "next_offset": $offset,
  "chunk_mib": $CHUNK_MIB,
  "target_gib": $TARGET_GIB,
  "last_global_part": $part,
  "bytes_stored_this_repo": $repo_added
}
EOF

  git add "$filename" "$MANIFEST" "$STATE_FILE"

  if (( (part - START_PART + 1) % PUSH_EVERY == 0 )); then
    git commit -m "Add Gutenberg text archive shards through part $(printf '%05d' "$part")" || true
    git push
  fi

  if (( actual < CHUNK_BYTES )); then
    echo "Reached end of Gutenberg archive."
    break
  fi

  part=$((part + 1))
done

git add "$MANIFEST" "$STATE_FILE" "$OUT_DIR" || true
git commit -m "Checkpoint Gutenberg archive at byte $offset" || true
git push

echo "Repository 2 load complete."
echo "Next offset: $offset"
