#!/usr/bin/env zsh
set -euo pipefail
setopt NULL_GLOB

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 BUNDLE_DIR [TESSERACT_LANG]" >&2
  exit 2
fi

BUNDLE_DIR="$1"
LANG="${2:-chi_sim+eng}"
OUT="$BUNDLE_DIR/ocr.md"

if [ ! -d "$BUNDLE_DIR" ]; then
  echo "Bundle dir not found: $BUNDLE_DIR" >&2
  exit 1
fi

if ! command -v tesseract >/dev/null 2>&1; then
  echo "tesseract is not installed." >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/xhs-ocr.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

{
  echo "# OCR"
  echo
  echo "- Bundle: \`$BUNDLE_DIR\`"
  echo "- Language: \`$LANG\`"
  echo "- Generated: $(date +"%Y-%m-%dT%H:%M:%S%z")"
  echo
} > "$OUT"

found=0
for img in "$BUNDLE_DIR"/page-*.png "$BUNDLE_DIR"/scroll-*.png; do
  [ -f "$img" ] || continue
  found=1
  base="$(basename "$img" .png)"
  txt="$tmp_dir/$base"
  tesseract "$img" "$txt" -l "$LANG" --psm 6 >/dev/null 2>&1 || true
  {
    echo "## $base"
    echo
    if [ -s "$txt.txt" ]; then
      sed '/^[[:space:]]*$/N;/^\n$/D' "$txt.txt"
    else
      echo "(no OCR text detected)"
    fi
    echo
  } >> "$OUT"
done

if [ "$found" = "0" ]; then
  echo "No page-*.png or scroll-*.png files found in $BUNDLE_DIR." >&2
  exit 2
fi

page_count="$(find "$BUNDLE_DIR" -maxdepth 1 \( -name 'page-*.png' -o -name 'scroll-*.png' \) | wc -l | tr -d ' ')"

if [ -f "$BUNDLE_DIR/manifest.json" ]; then
  jq --arg ocr_file "$OUT" --arg ocr_completed_at "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
    '. + {ocr_file: $ocr_file, ocr_completed_at: $ocr_completed_at}' \
    "$BUNDLE_DIR/manifest.json" > "$BUNDLE_DIR/manifest.json.tmp"
  mv "$BUNDLE_DIR/manifest.json.tmp" "$BUNDLE_DIR/manifest.json"
else
  jq -n \
    --arg mode "unknown" \
    --arg status "complete" \
    --arg created_at "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
    --arg updated_at "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
    --arg output_dir "$BUNDLE_DIR" \
    --arg ocr_file "$OUT" \
    --arg ocr_completed_at "$(date +"%Y-%m-%dT%H:%M:%S%z")" \
    --argjson page_count "$page_count" \
    '{
      mode: $mode,
      status: $status,
      created_at: $created_at,
      updated_at: $updated_at,
      output_dir: $output_dir,
      page_count: $page_count,
      ocr_file: $ocr_file,
      ocr_completed_at: $ocr_completed_at
    }' > "$BUNDLE_DIR/manifest.json"
fi

echo "$OUT"
