#!/bin/bash
# optimize.sh — Build web-ready assets in place.
# Run from the site/ directory: ./optimize.sh
#
# Requirements: ImageMagick (magick), ffmpeg, shasum
#
# What it does:
#   1. Converts images to progressive JPEGs (quality 92, max 2200px)
#   2. Creates crisp intermediate JPEGs (<name>.small.jpg) for quick display
#      The hero poster gets a smaller baseline preview to avoid partial-image flashes
#   3. Creates tiny blurred thumbnails (<name>.thumb.jpg) for progressive loading
#   4. Rebuilds videos for browser playback
#      The hero clip keeps a higher-resolution re-encode profile,
#      compatible section clips preserve their original H.264 video stream,
#      and used site videos keep their audio tracks
#   5. Skips unchanged files on reruns by storing ignored hash sidecars
#
# Safe to re-run. Add new files to assets/ and run again.

set -euo pipefail

SITE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="$SITE_DIR/assets"
IMAGE_MAX_DIM=2200
IMAGE_QUALITY=92
SMALL_MAX_DIM=1200
SMALL_QUALITY=86
HERO_PREVIEW_MAX_DIM=900
HERO_PREVIEW_QUALITY=82
THUMB_MAX_DIM=96
THUMB_QUALITY=38
VIDEO_MAX_WIDTH=1600
VIDEO_MAX_HEIGHT=900
VIDEO_CRF=23
VIDEO_PRESET=slow
VIDEO_AUDIO_BITRATE=160k
HERO_VIDEO_MAX_WIDTH=1920
HERO_VIDEO_MAX_HEIGHT=1080
HERO_VIDEO_CRF=23
TICHY_VIDEO_MAX_WIDTH=1280
TICHY_VIDEO_MAX_HEIGHT=720
TICHY_VIDEO_CRF=23

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
  local ext lext base full_path small_path thumb_path
  local tmp_full tmp_small tmp_thumb old_size new_size
  local small_max_dim small_quality small_interlace
  ext="${src##*.}"
  lext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
  base="${src%.*}"
  full_path="${base}.jpg"
  small_path="${base}.small.jpg"
  thumb_path="${base}.thumb.jpg"
  tmp_full="${full_path}.tmp"
  tmp_small="${small_path}.tmp"
  tmp_thumb="${thumb_path}.tmp"
  small_max_dim="$SMALL_MAX_DIM"
  small_quality="$SMALL_QUALITY"
  small_interlace="Plane"

  case "$lext" in
    jpg|jpeg|png|webp|tif|tiff|avif) ;;
    *)
      warn "Skipping unsupported image: ${src#./}"
      return
      ;;
  esac

  if [[ "$src" == "$full_path" ]] && is_current "$base" "$full_path" "$full_path" "$small_path" "$thumb_path"; then
    log "Skipping image: ${full_path#./}"
    return
  fi

  if [[ "$base" == "./img6/hero_poster" ]]; then
    small_max_dim="$HERO_PREVIEW_MAX_DIM"
    small_quality="$HERO_PREVIEW_QUALITY"
    small_interlace="None"
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
    -resize "${small_max_dim}x${small_max_dim}>" \
    -colorspace sRGB \
    -sampling-factor 4:4:4 \
    -interlace "$small_interlace" \
    -quality "$small_quality" \
    -strip \
    "$tmp_small"
  mv "$tmp_small" "$small_path"

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
  local base tmp size_before size_after video_max_width video_max_height video_crf
  local codec_name pix_fmt width height
  base="${src%.*}"
  tmp="${base}.tmp.mp4"
  video_max_width="$VIDEO_MAX_WIDTH"
  video_max_height="$VIDEO_MAX_HEIGHT"
  video_crf="$VIDEO_CRF"

  if is_current "$base" "$src" "$src"; then
    log "Skipping video: ${src#./}"
    return
  fi

  if [[ "$base" == "./img6/video_2" ]]; then
    video_max_width="$HERO_VIDEO_MAX_WIDTH"
    video_max_height="$HERO_VIDEO_MAX_HEIGHT"
    video_crf="$HERO_VIDEO_CRF"
  elif [[ "$base" == "./img6/tichy_dig_video" ]]; then
    video_max_width="$TICHY_VIDEO_MAX_WIDTH"
    video_max_height="$TICHY_VIDEO_MAX_HEIGHT"
    video_crf="$TICHY_VIDEO_CRF"
  fi

  size_before="$(file_size_bytes "$src")"
  log "Optimizing video: ${src#./}"

  codec_name="$(
    ffprobe -v error \
      -select_streams v:0 \
      -show_entries stream=codec_name \
      -of default=noprint_wrappers=1:nokey=1 \
      "$src"
  )"
  pix_fmt="$(
    ffprobe -v error \
      -select_streams v:0 \
      -show_entries stream=pix_fmt \
      -of default=noprint_wrappers=1:nokey=1 \
      "$src"
  )"
  width="$(
    ffprobe -v error \
      -select_streams v:0 \
      -show_entries stream=width \
      -of default=noprint_wrappers=1:nokey=1 \
      "$src"
  )"
  height="$(
    ffprobe -v error \
      -select_streams v:0 \
      -show_entries stream=height \
      -of default=noprint_wrappers=1:nokey=1 \
      "$src"
  )"

  if [[ "$base" != "./img6/video_2" ]] \
    && [[ "$base" != "./img6/tichy_dig_video" ]] \
    && [[ "$codec_name" == "h264" ]] \
    && [[ "$pix_fmt" == "yuv420p" ]] \
    && (( width <= video_max_width )) \
    && (( height <= video_max_height )); then
    ffmpeg -nostdin -y -i "$src" \
      -map 0:v:0 \
      -map '0:a?' \
      -c:v copy \
      -c:a copy \
      -movflags +faststart \
      "$tmp" >/dev/null 2>&1
  else
    ffmpeg -nostdin -y -i "$src" \
      -map 0:v:0 \
      -map '0:a?' \
      -c:v libx264 \
      -crf "$video_crf" \
      -preset "$VIDEO_PRESET" \
      -movflags +faststart \
      -pix_fmt yuv420p \
      -vf "scale='min(${video_max_width},iw)':'min(${video_max_height},ih)':force_original_aspect_ratio=decrease" \
      -c:a aac \
      -b:a "$VIDEO_AUDIO_BITRATE" \
      "$tmp" >/dev/null 2>&1
  fi

  mv "$tmp" "$src"
  write_state "$base" "$src"
  size_after="$(file_size_bytes "$src")"
  log "  -> $(file_size_mb "$size_after")MB (was $(file_size_mb "$size_before")MB)"
}

while IFS= read -r -d '' file; do
  optimize_image "$file"
done < <(
  find . -type f \
    \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.avif" \) \
    ! -path "*/reference/*" \
    ! -name "*.small.jpg" \
    ! -name "*.thumb.jpg" \
    ! -name "*.asset.sha256" \
    -print0 | sort -z
)

while IFS= read -r -d '' file; do
  optimize_video "$file"
done < <(
  find . -type f -iname "*.mp4" ! -path "*/reference/*" -print0 | sort -z
)

echo ""
log "Done. Asset summary:"
du -sh "$ASSETS_DIR"
