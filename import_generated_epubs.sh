#!/usr/bin/env bash
set -euo pipefail

# Importa EPUBs sem imagens da coleção generated do Project Gutenberg.
# Seleciona por tamanho antes de transferir e faz commits/pushes em lotes seguros.

RSYNC_SOURCE="${RSYNC_SOURCE:-gutenberg.pglaf.org::gutenberg-epub}"
TARGET_GIB="${TARGET_GIB:-3}"
MAX_FILE_MIB="${MAX_FILE_MIB:-90}"
PUSH_BATCH_MIB="${PUSH_BATCH_MIB:-700}"
STATE_FILE="${STATE_FILE:-epub-continuation-state.json}"
INDEX_FILE="${INDEX_FILE:-epub-index.tsv}"
SKIPPED_FILE="${SKIPPED_FILE:-epub-skipped-large.tsv}"
OUT_DIR="${OUT_DIR:-generated_epubs}"

TARGET_BYTES=$((TARGET_GIB * 1024 * 1024 * 1024))
MAX_FILE_BYTES=$((MAX_FILE_MIB * 1024 * 1024))
PUSH_BATCH_BYTES=$((PUSH_BATCH_MIB * 1024 * 1024))

command -v rsync >/dev/null 2>&1 || { echo 'rsync is required'; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required'; exit 1; }
command -v git >/dev/null 2>&1 || { echo 'git is required'; exit 1; }

mkdir -p "$OUT_DIR"

LAST_PATH=""
if [[ -f "$STATE_FILE" ]]; then
  LAST_PATH=$(python3 - <<PY
import json
try:
    with open('$STATE_FILE', encoding='utf-8') as f:
        print(json.load(f).get('last_path', ''))
except Exception:
    print('')
PY
)
fi

echo "Listing generated EPUB collection from $RSYNC_SOURCE ..."
# rsync list format: perms size date time path. Generated ebook filenames are space-free.
rsync -r --list-only --timeout=600 "$RSYNC_SOURCE" \
  | awk 'NF >= 5 {size=$2; path=$NF; if (path ~ /\/pg[0-9]+\.epub$/) print size "\t" path}' \
  | sort -k2,2 > /tmp/all-noimage-epubs.tsv

python3 - "$LAST_PATH" "$TARGET_BYTES" "$MAX_FILE_BYTES" <<'PY'
import sys, json
last_path = sys.argv[1]
target = int(sys.argv[2])
max_file = int(sys.argv[3])
selected=[]; skipped=[]; total=0
with open('/tmp/all-noimage-epubs.tsv', encoding='utf-8') as f:
    for line in f:
        line=line.rstrip('\n')
        if not line: continue
        size_s, path = line.split('\t',1)
        size=int(size_s)
        if last_path and path <= last_path:
            continue
        if size > max_file:
            skipped.append((size,path))
            continue
        if selected and total + size > target:
            break
        selected.append((size,path)); total += size
with open('/tmp/selected-epubs.txt','w',encoding='utf-8') as f:
    for _,p in selected: f.write(p+'\n')
with open('/tmp/selected-epubs.tsv','w',encoding='utf-8') as f:
    for s,p in selected: f.write(f'{s}\t{p}\n')
with open('/tmp/skipped-large.tsv','w',encoding='utf-8') as f:
    for s,p in skipped: f.write(f'{s}\t{p}\n')
print(json.dumps({'count':len(selected),'bytes':total,'first':selected[0][1] if selected else '', 'last':selected[-1][1] if selected else ''}))
PY

if [[ ! -s /tmp/selected-epubs.txt ]]; then
  echo "No additional EPUB files selected; collection may be complete."
  exit 0
fi

mkdir -p "$OUT_DIR"
echo "Downloading selected EPUB files..."
rsync -avR --timeout=600 --files-from=/tmp/selected-epubs.txt "$RSYNC_SOURCE" "$OUT_DIR/"

if [[ ! -f "$INDEX_FILE" ]]; then
  printf 'bytes\tpath\n' > "$INDEX_FILE"
fi
cat /tmp/selected-epubs.tsv >> "$INDEX_FILE"

if [[ ! -f "$SKIPPED_FILE" ]]; then
  printf 'bytes\tpath\n' > "$SKIPPED_FILE"
fi
cat /tmp/skipped-large.tsv >> "$SKIPPED_FILE"

last_path=$(tail -n1 /tmp/selected-epubs.tsv | cut -f2-)
selected_bytes=$(awk -F'\t' '{s+=$1} END {printf "%.0f",s}' /tmp/selected-epubs.tsv)
selected_count=$(wc -l < /tmp/selected-epubs.tsv | tr -d ' ')

cat > "$STATE_FILE" <<EOF
{
  "collection": "generated epub.noimages",
  "rsync_source": "$RSYNC_SOURCE",
  "last_path": "$last_path",
  "bytes_stored_this_run": $selected_bytes,
  "files_stored_this_run": $selected_count,
  "target_gib": $TARGET_GIB,
  "max_file_mib": $MAX_FILE_MIB
}
EOF

# Commit/push in batches <= PUSH_BATCH_MIB.
batch_bytes=0
batch_count=0
commit_no=1
while IFS=$'\t' read -r size path; do
  [[ -z "${path:-}" ]] && continue
  git add "$OUT_DIR/$path"
  batch_bytes=$((batch_bytes + size))
  batch_count=$((batch_count + 1))
  if (( batch_bytes >= PUSH_BATCH_BYTES )); then
    git add "$INDEX_FILE" "$SKIPPED_FILE" "$STATE_FILE"
    git commit -m "Add generated EPUB batch ${commit_no} (${batch_count} files)"
    git push
    commit_no=$((commit_no + 1)); batch_bytes=0; batch_count=0
  fi
done < /tmp/selected-epubs.tsv

if (( batch_count > 0 )); then
  git add "$INDEX_FILE" "$SKIPPED_FILE" "$STATE_FILE"
  git commit -m "Add generated EPUB batch ${commit_no} (${batch_count} files)"
  git push
fi

echo "Imported $selected_count EPUB files / $selected_bytes bytes."
echo "Continuation path: $last_path"
