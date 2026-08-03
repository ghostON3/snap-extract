#!/usr/bin/env bash
# record-demo.sh — record a snap-extract demo and produce a README-ready GIF.
#
#   contrib/demo/record-demo.sh                 # pick a region, record 20s
#   contrib/demo/record-demo.sh --seconds 30
#   contrib/demo/record-demo.sh --full          # whole screen (large on 4K)
#
# Writes assets/demo.mp4 (the master) and assets/demo.gif (for the README).
#
# What to perform while it records:
#   1. Have an editor sidebar or a `tree` listing visible.
#   2. Press your leader key, then the project key.
#   3. Drag a rectangle over the file names.
#   4. Paste into a text field so the result is visible.
#
# Keep it under ~20 seconds. A README GIF nobody watches to the end is a
# README GIF that failed.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTDIR="$REPO/assets"
SECONDS_TO_RECORD=20
FPS=15
WIDTH=900
REGION=""
FULL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) SECONDS_TO_RECORD="$2"; shift 2 ;;
    --fps)     FPS="$2"; shift 2 ;;
    --width)   WIDTH="$2"; shift 2 ;;
    --full)    FULL=1; shift ;;
    --outdir)  OUTDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for tool in wf-recorder ffmpeg; do
  command -v "$tool" &>/dev/null || { echo "missing: $tool" >&2; exit 2; }
done

mkdir -p "$OUTDIR"
MP4="$OUTDIR/demo.mp4"
GIF="$OUTDIR/demo.gif"

if [[ $FULL -eq 0 ]]; then
  command -v slurp &>/dev/null || { echo "missing: slurp (or pass --full)" >&2; exit 2; }
  echo "Select the region to RECORD (include wherever your notifications appear)."
  REGION="$(slurp)" || { echo "cancelled"; exit 1; }
fi

echo
echo "Recording ${SECONDS_TO_RECORD}s. Perform the demo now."
for i in 3 2 1; do printf '\r  starting in %d... ' "$i"; sleep 1; done
printf '\r  recording          \n'

# -y overwrite, no audio. wf-recorder exits on SIGINT, so a timed kill gives a
# clean file without the user having to find a terminal mid-demo.
if [[ -n "$REGION" ]]; then
  wf-recorder -g "$REGION" -f "$MP4" --overwrite &
else
  wf-recorder -f "$MP4" --overwrite &
fi
REC_PID=$!
sleep "$SECONDS_TO_RECORD"
kill -INT "$REC_PID" 2>/dev/null || true
wait "$REC_PID" 2>/dev/null || true

[[ -s "$MP4" ]] || { echo "recording produced nothing" >&2; exit 3; }
echo "wrote $MP4 ($(du -h "$MP4" | cut -f1))"

# Two-pass palette: one shared palette for the whole clip, then dithered
# mapping. A single-pass GIF from a screen recording bands badly on the
# subtle greys of an editor UI.
echo "converting to GIF (${WIDTH}px, ${FPS}fps)..."
PALETTE="$(mktemp --suffix=.png)"
ffmpeg -loglevel error -y -i "$MP4" \
  -vf "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff" \
  "$PALETTE"
ffmpeg -loglevel error -y -i "$MP4" -i "$PALETTE" \
  -lavfi "fps=${FPS},scale=${WIDTH}:-1:flags=lanczos[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  "$GIF"
rm -f "$PALETTE"

gif_bytes="$(stat -c%s "$GIF")"
echo "wrote $GIF ($(du -h "$GIF" | cut -f1))"

# GitHub renders GIFs inline but they are downloaded in full on every page
# view. Past ~10 MB that is rude; past 25 MB it will not upload at all.
if [[ $gif_bytes -gt 10485760 ]]; then
  echo
  echo "  ! That GIF is over 10 MB. Re-run with --width 700 --fps 12,"
  echo "    or record a shorter clip."
fi

echo
echo "Embed in README.md with:"
echo "    ![snap-extract demo](assets/demo.gif)"
