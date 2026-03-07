#!/bin/bash
# optimize.sh — Build web-ready assets in place.
# Run from the site/ directory: ./optimize.sh
#
# Requirements: ImageMagick (magick), ffmpeg, shasum
#
# What it does:
#   1. Converts images to progressive JPEGs (quality 92, max 2200px)
#   2. Creates tiny blurred thumbnails (<name>.thumb.jpg) for progressive loading
#   3. Re-encodes videos with H.264 + faststart for browser playback
#   4. Skips unchanged files on reruns by storing ignored hash sidecars
#
# Safe to re-run. Add new files to assets/ and run again.

set -euo pipefail

SITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="$SITE_DIR/assets"
IMAGE_MAX_DIM=2200
IMAGE_QUALITY=92
THUMB_MAX_DIM=96
THUMB_QUALITY=38
VIDEO_MAX_WIDTH=1600
VIDEO_MAX_HEIGHT=900
VIDEO_CRF=25
VIDEO_PRESET=slow

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[optimize]${NC} $1"; }
warn() { echo -e "${YELLOW}[optimize]${NC} $1"; }

command -v magick >/dev/null 2>&1 || { echo "ImageMagick required. Install with: brew install imagemagick"; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg required. Install with: brew install ffmpeg"; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum required but not found"; exit 1; }

cd "$ASSETS_DIR"

file_size_bytes() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
}

file_size_mb() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f", bytes / 1048576 }'
}

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

state_file_for_base() {
  local base="$1"
  echo "${base}.asset.sha256"
}

is_current() {
  local base="$1"
  local source="$2"
  shift 2
  local state_file current_hash
  state_file="$(state_file_for_base "$base")"

  [[ -f "$source" && -f "$state_file" ]] || return 1

  current_hash="$(file_hash "$source")"
  [[ "$(cat "$state_file")" == "$current_hash" ]] || return 1

  for output in "$@"; do
    [[ -f "$output" ]] || return 1
  done

  return 0
}

write_state() {
  local base="$1"
  local source="$2"
  file_hash "$source" > "$(state_file_for_base "$base")"
}

render_jpeg() {
  local input="$1"
  local output="$2"
  local max_dim="$3"
  local quality="$4"

  magick "$input" \
    -auto-orient \
    -resize "${max_dim}x${max_dim}>" \
    -background white \
    -alpha remove \
    -alpha off \
    -colorspace sRGB \
    -sampling-factor 4:4:4 \
    -interlace Plane \
    -quality "$quality" \
    -strip \
    "$output"
}

optimize_image() {
  local src="$1"
  local ext lext base full_path thumb_path tmp_full tmp_thumb old_size new_size
  ext="${src##*.}"
  lext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
  base="${src%.*}"
  full_path="${base}.jpg"
  thumb_path="${base}.thumb.jpg"
  tmp_full="${full_path}.tmp"
  tmp_thumb="${thumb_path}.tmp"

  case "$lext" in
    jpg|jpeg|png|webp|tif|tiff|avif) ;;
    *)
      warn "Skipping unsupported image: ${src#./}"
      return
      ;;
  esac

  if [[ "$src" == "$full_path" ]] && is_current "$base" "$full_path" "$full_path" "$thumb_path"; then
    log "Skipping image: ${full_path#./}"
    return
  fi

  old_size=0
  if [[ -f "$src" ]]; then
    old_size="$(file_size_bytes "$src")"
  elif [[ -f "$full_path" ]]; then
    old_size="$(file_size_bytes "$full_path")"
  fi

  log "Optimizing image: ${src#./} -> ${full_path#./}"
  render_jpeg "$src" "$tmp_full" "$IMAGE_MAX_DIM" "$IMAGE_QUALITY"
  mv "$tmp_full" "$full_path"

  magick "$full_path" \
    -resize "${THUMB_MAX_DIM}x${THUMB_MAX_DIM}>" \
    -blur 0x4 \
    -colorspace sRGB \
    -sampling-factor 4:4:4 \
    -interlace Plane \
    -quality "$THUMB_QUALITY" \
    -strip \
    "$tmp_thumb"
  mv "$tmp_thumb" "$thumb_path"

  if [[ "$src" != "$full_path" && -f "$src" ]]; then
    rm "$src"
  fi

  write_state "$base" "$full_path"
  new_size="$(file_size_bytes "$full_path")"
  log "  -> $(file_size_mb "$new_size")MB (was $(file_size_mb "$old_size")MB)"
}

optimize_video() {
  local src="$1"
  local base tmp size_before size_after
  base="${src%.*}"
  tmp="${base}.tmp.mp4"

  if is_current "$base" "$src" "$src"; then
    log "Skipping video: ${src#./}"
    return
  fi

  size_before="$(file_size_bytes "$src")"
  log "Optimizing video: ${src#./}"

  ffmpeg -y -i "$src" \
    -c:v libx264 \
    -crf "$VIDEO_CRF" \
    -preset "$VIDEO_PRESET" \
    -movflags +faststart \
    -pix_fmt yuv420p \
    -vf "scale='min(${VIDEO_MAX_WIDTH},iw)':'min(${VIDEO_MAX_HEIGHT},ih)':force_original_aspect_ratio=decrease" \
    -an \
    "$tmp" >/dev/null 2>&1

  mv "$tmp" "$src"
  write_state "$base" "$src"
  size_after="$(file_size_bytes "$src")"
  log "  -> $(file_size_mb "$size_after")MB (was $(file_size_mb "$size_before")MB)"
}

find . -type f \
  \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.avif" \) \
  ! -name "*.thumb.jpg" \
  ! -name "*.asset.sha256" \
  -print0 | sort -z | while IFS= read -r -d '' file; do
    optimize_image "$file"
  done

find . -type f -iname "*.mp4" -print0 | sort -z | while IFS= read -r -d '' file; do
  optimize_video "$file"
done

echo ""
log "Done. Asset summary:"
du -sh "$ASSETS_DIR"
