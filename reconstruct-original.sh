#!/usr/bin/env bash
set -euo pipefail

EXPECTED_SIZE=11278856242
EXPECTED_SHA256=504191cf3ecfb111da66416952682a5fd23959f9fcea20066a81a7ca9a9fdb94
ROOT_DIR="${1:-rebuild}"
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"
: > txt-files.tar.zip

download_part() {
  local repo="$1"
  local n="$2"
  local expected="$3"
  local part url actual
  part=$(printf 'pg-all-text-%05d.part' "$n")
  url="https://raw.githubusercontent.com/gcnb-ltda/${repo}/main/archive_parts/${part}"
  echo "Downloading ${part} from ${repo}"
  rm -f part.tmp
  curl -L --fail --retry 8 --retry-delay 3 --connect-timeout 30 --max-time 900 \
    -A 'GCNB-Gutenberg-Rebuilder/1.0' "$url" -o part.tmp
  actual=$(stat -c %s part.tmp)
  if [ "$actual" -ne "$expected" ]; then
    echo "ERROR: ${part} size ${actual}, expected ${expected}" >&2
    exit 1
  fi
  cat part.tmp >> txt-files.tar.zip
  rm -f part.tmp
}

for n in $(seq 1 91); do
  download_part project-gutenberg-bulk-downloader "$n" 94371840
done
for n in $(seq 92 119); do
  download_part project-gutenberg-bulk-downloader-2 "$n" 94371840
done
download_part project-gutenberg-bulk-downloader-2 120 48607282

actual=$(stat -c %s txt-files.tar.zip)
[ "$actual" -eq "$EXPECTED_SIZE" ] || { echo "ERROR: reconstructed size ${actual}, expected ${EXPECTED_SIZE}" >&2; exit 1; }

actual_sha=$(sha256sum txt-files.tar.zip | awk '{print $1}')
[ "$actual_sha" = "$EXPECTED_SHA256" ] || { echo "ERROR: SHA256 ${actual_sha}, expected ${EXPECTED_SHA256}" >&2; exit 1; }

echo "ZIP size and SHA256 verified."
unzip -t txt-files.tar.zip

mkdir -p extracted
count=$(unzip -Z1 txt-files.tar.zip | wc -l)
member=$(unzip -Z1 txt-files.tar.zip | head -1)
if [ "$count" -eq 1 ] && [[ "$member" == *.tar ]]; then
  unzip -p txt-files.tar.zip "$member" | tar -xf - -C extracted
else
  unzip -q txt-files.tar.zip -d extracted
fi

echo "Reconstruction complete."
echo "bytes=$(stat -c %s txt-files.tar.zip)"
echo "sha256=$(sha256sum txt-files.tar.zip | awk '{print $1}')"
echo "extracted_files=$(find extracted -type f | wc -l)"
du -sh extracted
