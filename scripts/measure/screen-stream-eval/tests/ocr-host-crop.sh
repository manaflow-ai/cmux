#!/usr/bin/env bash
# Mac only. The host baseline's crop: the rd ladder's OCR reads the host screenshot cut to the
# scene's content rect. 11-28 ssqc-1141 (efb651f9, cmux20, macOS 27): host OCR vs the drawn text
# read 42 % (rd-ladder) and 100 % (rd-ladder-1000), and screen-eval-ocr reported the host image it
# read as 1920x1080, not the 1920x762 crop: `sips --cropOffset Y X --cropToHeightWidth H W` had
# not cut it. This puts the 13 pt fixture under a white band (the marker's place), so the content
# rect is [0,BAND,1920,1080] and the fixture's truth is the crop's, and reads it both ways:
#   before: the sips crop the eval used, then OCR of its output;
#   after:  screen-eval-ocr --cut-host/--cut-viewer on the decoded pixels.
# It also cuts a 1920x1080 image at the real run's rect [0,318,1920,762] with sips, for the size sips
# gives there. Fails unless the after path reads the crop's size and <= 2 % against the truth.
#
#   scripts/measure/screen-stream-eval/tests/ocr-host-crop.sh
set -euo pipefail
root=$(git rev-parse --show-toplevel)
eval_dir="$root/scripts/measure/screen-stream-eval"
fixture="$eval_dir/tests/fixtures/host-13pt-1x"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
limit=0.02 band=318

swiftc -O -o "$work/ocr" "$eval_dir/ocr.swift"

# The padded scene and a 1920x1080 frame, as RGB PNGs (rd_marker_calibration.py reads the fixture).
python3 -I - "$eval_dir" "$fixture.png" "$band" "$work" <<'PY'
import importlib.util, struct, sys, zlib
from pathlib import Path
spec = importlib.util.spec_from_file_location("cal", Path(sys.argv[1]) / "rd_marker_calibration.py")
cal = importlib.util.module_from_spec(spec); spec.loader.exec_module(cal)
image, band, work = cal.load(Path(sys.argv[2])), int(sys.argv[3]), Path(sys.argv[4])
def png(path, rows, width):
    def chunk(kind, body):
        return struct.pack("!I", len(body)) + kind + body + struct.pack("!I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + r for r in rows)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", width, len(rows), 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
white = b"\xff" * (3 * image.width)
png(work / "padded.png", [white] * band + list(image.rows), image.width)
png(work / "frame.png", [white] * band + list(image.rows[:image.height - band]), image.width)
PY

size() { python3 -I -c 'import struct, sys; print("%dx%d" % struct.unpack("!II", open(sys.argv[1], "rb").read(24)[16:24]))' "$1"; }
field() { python3 -I -c 'import json, sys; o = json.load(sys.stdin); print(json.dumps(o.get(sys.argv[1])))' "$1"; }
w=1920 h=1080

sips --cropOffset 318 0 --cropToHeightWidth 762 1920 "$work/frame.png" --out "$work/frame-sips.png" >/dev/null
echo "sips on 1920x1080 at the run's rect [0,318,1920,762]: $(size "$work/frame-sips.png") (want 1920x762)"

sips --cropOffset "$band" 0 --cropToHeightWidth "$h" "$w" "$work/padded.png" --out "$work/padded-sips.png" >/dev/null
before=$("$work/ocr" "$work/padded-sips.png" "$work/padded-sips.png" "$fixture.txt")
echo "before (sips crop, then OCR): image $(size "$work/padded-sips.png"), host_cer_vs_truth $(field host_cer_vs_truth <<<"$before"), host_chars $(field host_chars <<<"$before") of $(field truth_chars <<<"$before")"

after=$("$work/ocr" "$work/padded.png" "$work/padded.png" "$fixture.txt" --cut-host "0,$band,$w,$h" --cut-viewer "0,$band,$w,$h")
read_size=$(field host_ocr_image <<<"$after")
got=$(field host_cer_vs_truth <<<"$after")
echo "after (screen-eval-ocr --cut-host): read $read_size, host_cer_vs_truth $got, host_chars $(field host_chars <<<"$after") of $(field truth_chars <<<"$after")"

[[ "$read_size" == "{\"height\": $h, \"width\": $w}" ]] || { echo "FAIL: OCR read $read_size, not the ${w}x$h crop" >&2; exit 1; }
if python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$got" "$limit"; then
  echo "PASS: host OCR of the cut content rect vs drawn 13 pt text $got <= $limit"
else
  echo "FAIL: host OCR of the cut content rect vs drawn 13 pt text $got > $limit" >&2
  exit 1
fi
