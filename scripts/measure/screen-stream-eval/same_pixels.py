"""Marks an OCR result comparable when host and viewer are the same display in the same pixels.

usage: same_pixels.py OCR_JSON HOST_IMAGE VIEWER_IMAGE [X,Y,W,H]

The rd targets' viewer frame is the host's display decoded at the host's size (the resolution
ladder's smaller pictures are scaled back up), and rfb-viewer's frame is the host's framebuffer.
Their host screenshot and viewer frame share one coordinate space, so they need no cross-Mac
calibration (cmux.screen-ocr-calibration/1, which Apple's Screen Sharing window does need): only
proof that both images have the same size, and the crop both were cut to (the whole image when
none). ocr.swift's result is rewritten in place with a `crops` receipt and `comparison_ready`;
sizes that differ, an unreadable image or a missing CER leave it not ready, with the reason.
"""

import json
import math
import struct
import sys
from pathlib import Path

COORDINATE_SPACE = "same pixels, sizes verified equal: the viewer frame is the host display at the host's size"


def image_size(path: Path) -> tuple[int, int] | None:
    """Width and height of a PNG or a binary PPM (P6), or None."""
    try:
        head = path.read_bytes()[:64]
    except OSError:
        return None
    if head[:8] == b"\x89PNG\r\n\x1a\n" and len(head) >= 24:
        return struct.unpack("!II", head[16:24])
    if head[:2] == b"P6":
        fields: list[bytes] = []
        for line in head[2:].split(b"\n"):
            fields += line.split(b"#", 1)[0].split()
            if len(fields) >= 2:
                break
        if len(fields) >= 2 and fields[0].isdigit() and fields[1].isdigit():
            return int(fields[0]), int(fields[1])
    return None


def receipt(ocr: dict, host: tuple[int, int] | None, viewer: tuple[int, int] | None,
            crop: list[int] | None) -> dict:
    """`ocr` with a same-pixel crops receipt and comparison_ready set."""
    out = dict(ocr)
    cer = ocr.get("cer")
    reason = None
    if host is None or viewer is None:
        reason = "the host screenshot or the viewer frame is not a readable PNG or PPM"
    elif host != viewer:
        reason = f"host {host[0]}x{host[1]} and viewer {viewer[0]}x{viewer[1]} differ: not the same pixels"
    elif type(cer) not in (int, float) or not math.isfinite(cer):
        reason = "OCR measured no CER"
    crops = {
        "coordinate_space": COORDINATE_SPACE,
        "host_image": {"width": host[0], "height": host[1]} if host else None,
        "viewer_image": {"width": viewer[0], "height": viewer[1]} if viewer else None,
        "host_crop": crop or ([0, 0, host[0], host[1]] if host else None),
        "viewer_crop": crop or ([0, 0, viewer[0], viewer[1]] if viewer else None),
        "viewer_pixels_per_host_pixel": [1.0, 1.0] if reason is None else None,
        "comparison_ready": reason is None,
    }
    if reason is not None:
        crops["reason"] = reason
    out["crops"] = crops
    out["comparison_ready"] = reason is None
    return out


def main(argv: list[str]) -> int:
    if len(argv) not in (4, 5):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    path = Path(argv[1])
    crop = None
    if len(argv) == 5:
        parts = argv[4].split(",")
        if len(parts) != 4 or not all(p.isdigit() for p in parts):
            print("same_pixels.py: crop is X,Y,W,H in pixels", file=sys.stderr)
            return 2
        crop = [int(p) for p in parts]
    try:
        ocr = json.loads(path.read_text())
    except (OSError, ValueError):
        ocr = {"cer": None}
    if not isinstance(ocr, dict):
        ocr = {"cer": None}
    path.write_text(json.dumps(receipt(ocr, image_size(Path(argv[2])), image_size(Path(argv[3])), crop),
                               sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
