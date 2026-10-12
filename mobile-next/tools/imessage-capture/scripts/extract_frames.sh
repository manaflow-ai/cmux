#!/bin/bash
# Extract a 60 fps PNG sequence and a contact sheet from a recording window.
# Usage: extract_frames.sh <video.mp4> <start_s> <end_s> <out_dir> [sheet_cols]
set -eu
V="$1"; A="$2"; B="$3"; OUT="$4"; COLS="${5:-10}"
mkdir -p "$OUT/frames"
ffmpeg -v error -y -i "$V" -vf "trim=start=$A:end=$B,setpts=PTS-STARTPTS,fps=60" "$OUT/frames/f%04d.png"
python3 "$(dirname "$0")/contact.py" "$OUT/frames" "$OUT/contact.png" "$COLS"
