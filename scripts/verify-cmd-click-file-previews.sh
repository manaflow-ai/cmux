#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fixture_dir="${1:-${TMPDIR:-/tmp}/cmux-file-preview-fixtures}"

mkdir -p "$fixture_dir"

python3 - "$fixture_dir" <<'PY'
from __future__ import annotations

import csv
import json
import math
import os
import struct
import sys
import wave
import zlib
from pathlib import Path


out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)


def write_text(name: str, content: str) -> None:
    (out / name).write_text(content, encoding="utf-8")


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_png(path: Path) -> None:
    width = 240
    height = 140
    rows: list[bytes] = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            r = int(45 + (x / width) * 170)
            g = int(80 + (y / height) * 120)
            b = 220 if (x // 20 + y // 20) % 2 == 0 else 120
            row.extend((r, g, b))
        rows.append(bytes(row))
    raw = b"".join(rows)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(raw, level=9))
        + png_chunk(b"IEND", b"")
    )
    path.write_bytes(data)


def write_pdf(path: Path) -> None:
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        ),
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    stream = (
        b"BT\n"
        b"/F1 24 Tf\n"
        b"72 720 Td\n"
        b"(cmux file preview PDF) Tj\n"
        b"/F1 12 Tf\n"
        b"0 -36 Td\n"
        b"(Cmd-click this path in cmux. It should open in a split.) Tj\n"
        b"ET\n"
    )
    objects.append(
        b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n" + stream + b"endstream"
    )

    pdf = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, obj in enumerate(objects, start=1):
        offsets.append(len(pdf))
        pdf.extend(f"{index} 0 obj\n".encode("ascii"))
        pdf.extend(obj)
        pdf.extend(b"\nendobj\n")

    xref_offset = len(pdf)
    pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    pdf.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        pdf.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    pdf.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            f"startxref\n{xref_offset}\n%%EOF\n"
        ).encode("ascii")
    )
    path.write_bytes(bytes(pdf))


def write_wav(path: Path) -> None:
    sample_rate = 44_100
    duration_seconds = 2.0
    frequency = 440.0
    frames = int(sample_rate * duration_seconds)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        for i in range(frames):
            fade_in = min(1.0, i / (sample_rate * 0.08))
            fade_out = min(1.0, (frames - i) / (sample_rate * 0.08))
            envelope = min(fade_in, fade_out)
            sample = int(32767 * 0.25 * envelope * math.sin(2 * math.pi * frequency * i / sample_rate))
            wav.writeframesraw(struct.pack("<h", sample))


write_text(
    "README file preview.md",
    "# cmux file preview fixture\n\nCmd-click this Markdown path. With Markdown routing on, it opens in the rendered viewer.\n",
)
write_text(
    "Plain Text Fixture.txt",
    "This is a plain text fixture for cmux cmd-click file preview routing.\n",
)
write_text(
    "Code Fixture.swift",
    'import Foundation\n\nprint("cmux file preview")\n',
)
write_text(
    "Data Fixture.json",
    json.dumps({"feature": "cmd-click file previews", "enabledByDefault": True}, indent=2) + "\n",
)
with (out / "Table Fixture.csv").open("w", newline="", encoding="utf-8") as file:
    writer = csv.writer(file)
    writer.writerow(["type", "expected preview"])
    writer.writerow(["png", "image"])
    writer.writerow(["pdf", "pdf"])
    writer.writerow(["wav", "media"])
    writer.writerow(["mp4", "media"])

write_png(out / "Generated PNG Fixture.png")
write_pdf(out / "Generated PDF Fixture.pdf")
write_wav(out / "Generated Audio Fixture.wav")
PY

copy_fixture() {
  local source="$1"
  local name="$2"
  if [[ -f "$source" ]]; then
    cp -f "$source" "$fixture_dir/$name"
  else
    printf 'warning: missing fixture source: %s\n' "$source" >&2
  fi
}

copy_fixture "$repo_root/web/public/blog/cmd-shift-u.mp4" "CMUX Sample Video.mp4"
copy_fixture "$repo_root/vendor/bonsplit/www/public/demo-compressed.mov" "Bonsplit Sample Video.mov"
copy_fixture "$repo_root/web/public/avatars/schrockn.jpg" "Sample JPEG Fixture.jpg"

printf 'cmux cmd-click file preview fixtures\n'
printf 'Directory: %s\n\n' "$fixture_dir"
printf 'Run this inside the tagged cmux build, then Cmd-click each path below.\n'
printf 'Expected: supported files open in a cmux split. After Cmd Shift P -> Disable Cmd-click File Previews, the same paths should fall back to the external opener.\n\n'

paths=()
for file in \
  "Generated PNG Fixture.png" \
  "Sample JPEG Fixture.jpg" \
  "Generated PDF Fixture.pdf" \
  "README file preview.md" \
  "Plain Text Fixture.txt" \
  "Code Fixture.swift" \
  "Data Fixture.json" \
  "Table Fixture.csv" \
  "Generated Audio Fixture.wav" \
  "CMUX Sample Video.mp4" \
  "Bonsplit Sample Video.mov"; do
  path="$fixture_dir/$file"
  if [[ -f "$path" ]]; then
    paths+=("$path")
    printf '%s\n' "$path"
  fi
done

if command -v swift >/dev/null 2>&1 && ((${#paths[@]} > 0)); then
  printf '\nmacOS external app detection:\n'
  swift - "${paths[@]}" <<'SWIFT'
import AppKit
import Foundation

func appName(_ applicationURL: URL) -> String {
    let bundle = Bundle(url: applicationURL)
    let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
    var name = bundleName ?? FileManager.default.displayName(atPath: applicationURL.path)
    if name.lowercased().hasSuffix(".app") {
        name = String(name.dropLast(4))
    }
    return name.isEmpty ? applicationURL.deletingPathExtension().lastPathComponent : name
}

for argument in CommandLine.arguments.dropFirst() {
    let fileURL = URL(fileURLWithPath: argument)
    let defaultName = NSWorkspace.shared.urlForApplication(toOpen: fileURL).map(appName) ?? "none"
    let candidateNames = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        .prefix(5)
        .map(appName)
    let candidates = candidateNames.isEmpty ? "none" : candidateNames.joined(separator: ", ")
    print("\(fileURL.lastPathComponent): default=\(defaultName); openWith=\(candidates)")
}
SWIFT
fi

printf '\nfile:// URL route checks:\n'
for file in "Generated PNG Fixture.png" "Generated PDF Fixture.pdf" "CMUX Sample Video.mp4"; do
  path="$fixture_dir/$file"
  if [[ -f "$path" ]]; then
    python3 - "$path" <<'PY'
from pathlib import Path
from urllib.parse import quote
import sys

path = Path(sys.argv[1]).resolve()
print("file://" + quote(str(path)))
PY
  fi
done
