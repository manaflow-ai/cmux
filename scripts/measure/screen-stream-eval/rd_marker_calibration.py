"""Calibrates the rd ladder targets' OCR crops from the shared source marker in both actual images.

usage:
  rd_marker_calibration.py calibrate SOURCE_SCENE EXPECTED_NONCE HOST_PNG VIEWER_FRAME OUT_JSON VIEWER_CROP_PPM
  rd_marker_calibration.py receipt OCR_JSON CALIBRATION_JSON

With scene-marker=1 the source scene (scene.swift) draws the common marker above the text: a counter
row and eight rows carrying this repeat's 128-bit nonce, 20 cells each (cells 16..19 the guard light,
dark, light, dark), and the text below it in `content_rect_points`. The rd viewer frame (`cmux-rd bench
--snapshot`) is the host display decoded and, under the resolution ladder (`video.scaled`), scaled back
up to the stream size: the display fitted into 3840x2160, even. So host screenshot and viewer frame
need not share a size, and same_pixels.py cannot vouch for them; this does, per repeat:

- The scene is `cmux.source-scene/1` and its nonce is the one the harness chose for this repeat.
- Each image's pixels per point is its width over the display's; its height must agree, so neither
  image is cropped, letterboxed or stretched.
- The viewer frame is at the stream size of the host screenshot (a ladder rung not scaled back up, or
  any other size, refuses), and its marker cell is the 32 stream pixels scene.swift drew.
- At the cell centres the scene's geometry predicts, both images read every guard cell and the eight
  nonce rows decode to EXPECTED_NONCE: the decoded viewer frame shows this repeat's source, there.
- The content rect maps inside both images.

`calibrate` writes `cmux.rd-marker-calibration/1` to OUT_JSON (`verified`, crops, evidence or reason)
and, when verified, the viewer crop as a PPM to VIEWER_CROP_PPM and prints `HOST_CROP VIEWER_CROP`
(X,Y,W,H in each image's top-left pixels; the host one is for `sips`, which reads the PNG). Exits 1
when not verified. `receipt` rewrites screen-eval-ocr's JSON of the two crops with the `crops` receipt
and `comparison_ready`, true only for a verified calibration and a finite CER.
"""

import importlib.util
import json
import math
import struct
import sys
import zlib
from pathlib import Path

SCHEMA = "cmux.rd-marker-calibration/1"
COORDINATE_SPACE = ("top-left pixels of each actual image, each calibrated from the shared source marker "
                    "read at the scene's geometry with this repeat's nonce")
STREAM_CELL_PX = 32  # scene.swift: cell = 32 * display width / streamed width
DARK, LIGHT = 60, 190  # observe::read_marker's thresholds, as marker-locate uses them
GUARD = [True, False, True, False]

_spec = importlib.util.spec_from_file_location("same_pixels", Path(__file__).resolve().parent / "same_pixels.py")
same_pixels = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(same_pixels)


class Image:
    """Top rows (or all) of an 8-bit RGB(A)/gray PNG or a binary PPM, as RGB rows."""

    def __init__(self, width: int, height: int, rows: list[bytes]):
        self.width, self.height, self.rows = width, height, rows

    def luma(self, x: int, y: int) -> int | None:
        if not (0 <= x < self.width and 0 <= y < len(self.rows)):
            return None
        r, g, b = self.rows[y][3 * x:3 * x + 3]
        return (299 * r + 587 * g + 114 * b) // 1000


def read_ppm(data: bytes, max_rows: int | None = None) -> Image | None:
    if data[:2] != b"P6":
        return None
    fields: list[bytes] = []
    pos = 2
    while len(fields) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while end < len(data) and not data[end:end + 1].isspace():
            end += 1
        if end == pos:
            return None
        fields.append(data[pos:end])
        pos = end
    pos += 1
    if not all(f.isdigit() for f in fields) or int(fields[2]) != 255:
        return None
    w, h = int(fields[0]), int(fields[1])
    if len(data) - pos < 3 * w * h:
        return None
    n = h if max_rows is None else min(h, max_rows)
    return Image(w, h, [data[pos + 3 * w * y:pos + 3 * w * (y + 1)] for y in range(n)])


def read_png(data: bytes, max_rows: int | None = None) -> Image | None:
    """Non-interlaced 8-bit PNG (gray, RGB, gray+alpha, RGBA); only the first max_rows unfiltered."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, ihdr, idat = 8, None, bytearray()
    while pos + 8 <= len(data):
        length, kind = struct.unpack("!I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            ihdr = struct.unpack("!IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        pos += 12 + length
    if ihdr is None:
        return None
    w, h, depth, color, _, _, interlace = ihdr
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color)
    if depth != 8 or channels is None or interlace != 0:
        return None
    stride = w * channels
    n = h if max_rows is None else min(h, max_rows)
    raw = zlib.decompressobj().decompress(bytes(idat), (stride + 1) * n)
    if len(raw) < (stride + 1) * n:
        return None
    rows, prev = [], bytearray(stride)
    for y in range(n):
        kind, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if kind == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif kind == 2:
            line = bytearray((a + b) & 255 for a, b in zip(line, prev))
        elif kind == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b, c = prev[i], prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif kind != 0:
            return None
        prev = line
        if channels == 3:
            rows.append(bytes(line))
        else:
            px = [line[i:i + channels] for i in range(0, stride, channels)]
            rows.append(bytes(v for p in px for v in ((p[0],) * 3 if channels <= 2 else p[:3])))
    return Image(w, h, rows)


def load(path: Path, max_rows: int | None = None) -> Image | None:
    try:
        data = path.read_bytes()
    except OSError:
        return None
    return read_png(data, max_rows) or read_ppm(data, max_rows)


def stream_size(host: tuple[int, int]) -> tuple[int, int]:
    """capture.rs `fit`: the display fitted into 3840x2160, keeping its aspect, never enlarged, even."""
    scale = min(3840 / host[0], 2160 / host[1], 1.0)
    return int(round(host[0] * scale)) & ~1, int(round(host[1] * scale)) & ~1


def read_rows(image: Image, origin: tuple[float, float], cell: float) -> tuple[list[int | None], str | None]:
    """The marker's nine words (counter, then the nonce) read at each cell's centre, or why not."""
    words: list[int | None] = []
    for row in range(9):
        word = 0
        y = int(origin[1] + (row + 0.5) * cell)
        for column in range(20):
            v = image.luma(int(origin[0] + (column + 0.5) * cell), y)
            bit = None if v is None else False if v <= DARK else True if v >= LIGHT else None
            if column >= 16 and bit != GUARD[column - 16]:
                return words, f"row {row} guard cell {column} reads {v} at y={y}"
            if column < 16:
                if bit is None:
                    return words, f"row {row} cell {column} reads {v} at y={y}: neither dark nor light"
                word |= int(bit) << column
        words.append(word)
    return words, None


def nonce_of(words: list[int]) -> str:
    return "".join(f"{w & 255:02x}{w >> 8:02x}" for w in words)


def mapped(origin: tuple[float, float], scale: float, rect: list[float]) -> list[int]:
    x, y, w, h = rect
    left, top = round(origin[0] + x * scale), round(origin[1] + y * scale)
    return [left, top, round(origin[0] + (x + w) * scale) - left, round(origin[1] + (y + h) * scale) - top]


def inside(crop: list[int], size: tuple[int, int]) -> bool:
    x, y, w, h = crop
    return x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= size[0] and y + h <= size[1]


def calibrate(scene: dict, expected_nonce: str, host_path: Path, viewer_path: Path) -> tuple[dict, Image | None]:
    out: dict = {"schema": SCHEMA, "verified": False, "expected_nonce": expected_nonce,
                 "source_nonce": scene.get("nonce"), "host_image": None, "viewer_image": None,
                 "host_crop": None, "viewer_crop": None,
                 "source_content_rect_points": scene.get("content_rect_points"),
                 "source_display_size_points": scene.get("display_size_points")}

    def refuse(reason: str) -> tuple[dict, None]:
        out["reason"] = reason
        return out, None

    if scene.get("schema") != "cmux.source-scene/1":
        return refuse("the source scene is not cmux.source-scene/1")
    if not (len(expected_nonce) == 32 and all(c in "0123456789abcdef" for c in expected_nonce)):
        return refuse("this repeat's nonce is not 32 lowercase hex characters")
    if scene.get("nonce") != expected_nonce:
        return refuse(f"the source scene's nonce {scene.get('nonce')!r} is not this repeat's {expected_nonce}")
    try:
        display_w, display_h = (float(v) for v in scene["display_size_points"])
        mark_x, mark_y = (float(v) for v in scene["marker_origin_points"])
        cell_points = float(scene["cell_size_points"])
        content = [float(v) for v in scene["content_rect_points"]]
        assert len(content) == 4 and display_w > 0 and display_h > 0 and cell_points > 0
    except (KeyError, TypeError, ValueError, AssertionError):
        return refuse("the source scene lacks display size, marker origin, cell size or content rect")

    host_size = same_pixels.image_size(host_path)
    viewer_size = same_pixels.image_size(viewer_path)
    if host_size is None or viewer_size is None:
        return refuse("the host screenshot or the viewer frame is not a readable PNG or PPM")
    out["host_image"] = {"width": host_size[0], "height": host_size[1]}
    out["viewer_image"] = {"width": viewer_size[0], "height": viewer_size[1]}

    scales = {}
    for side, (w, h) in (("host screenshot", host_size), ("viewer frame", viewer_size)):
        scale = w / display_w
        # One pixel of rounding (the stream's even size) either way, no more.
        if abs(h - display_h * scale) > 2:
            return refuse(f"the {side} {w}x{h} is not the {display_w:g}x{display_h:g} pt display's aspect")
        scales[side] = scale
    expected = stream_size(host_size)
    out["expected_viewer_stream_size"] = {"width": expected[0], "height": expected[1]}
    if viewer_size != expected:
        return refuse(f"the viewer frame {viewer_size[0]}x{viewer_size[1]} is not the stream size "
                      f"{expected[0]}x{expected[1]} of the host screenshot (a ladder rung not scaled back up?)")
    viewer_cell = cell_points * scales["viewer frame"]
    if abs(viewer_cell - STREAM_CELL_PX) > 1:
        return refuse(f"the viewer frame's marker cell is {viewer_cell:g} px, not the {STREAM_CELL_PX} stream "
                      "pixels the scene drew")

    marker_rows = lambda scale: int(math.ceil((mark_y + 9 * cell_points) * scale)) + 1
    read = {}
    for side, path in (("host screenshot", host_path), ("viewer frame", viewer_path)):
        scale = scales[side]
        image = load(path, marker_rows(scale))
        if image is None:
            return refuse(f"the {side} pixels are not a readable 8-bit PNG or PPM")
        origin = (mark_x * scale, mark_y * scale)
        words, why = read_rows(image, origin, cell_points * scale)
        if why:
            return refuse(f"no source marker at the scene's geometry in the {side}: {why}")
        observed = nonce_of(words[1:])
        if observed != expected_nonce:
            return refuse(f"the {side} shows nonce {observed}, not this repeat's {expected_nonce}")
        read[side] = (origin, scale, observed)

    # The marker read where the scene put it, so each image's display origin is its top-left pixel.
    host_crop = mapped((0.0, 0.0), scales["host screenshot"], content)
    viewer_crop = mapped((0.0, 0.0), scales["viewer frame"], content)
    for side, crop, size in (("host screenshot", host_crop, host_size), ("viewer frame", viewer_crop, viewer_size)):
        if not inside(crop, size):
            return refuse(f"the content rect maps to {crop}, outside the {side} {size[0]}x{size[1]}")
    viewer = load(viewer_path)
    if viewer is None or viewer.width != viewer_size[0] or len(viewer.rows) != viewer_size[1]:
        return refuse("the viewer frame pixels are not a readable PNG or PPM")
    out.update(host_crop=host_crop, viewer_crop=viewer_crop, verified=True,
               observed_host_nonce=read["host screenshot"][2], observed_viewer_nonce=read["viewer frame"][2],
               viewer_pixels_per_host_pixel=scales["viewer frame"] / scales["host screenshot"])
    out["evidence"] = (
        f"source marker read at the scene's geometry in both images with nonce {expected_nonce}: host "
        f"{host_size[0]}x{host_size[1]} at {scales['host screenshot']:g} px/pt, viewer {viewer_size[0]}x"
        f"{viewer_size[1]} (the stream size) at {scales['viewer frame']:g} px/pt, cell {viewer_cell:g} px; "
        f"content rect {content} pt mapped through each")
    return out, viewer


def crop_ppm(image: Image, crop: list[int]) -> bytes:
    x, y, w, h = crop
    return f"P6\n{w} {h}\n255\n".encode() + b"".join(row[3 * x:3 * (x + w)] for row in image.rows[y:y + h])


def receipt(ocr: dict, calibration: dict) -> dict:
    out = dict(ocr)
    cer = ocr.get("cer")
    reason = None
    if calibration.get("schema") != SCHEMA or calibration.get("verified") is not True:
        reason = "rd marker calibration not verified: " + str(calibration.get("reason", "missing"))
    elif type(cer) not in (int, float) or not math.isfinite(cer):
        reason = "OCR measured no CER"
    crops = {k: calibration.get(k) for k in ("host_image", "viewer_image", "host_crop", "viewer_crop",
                                            "viewer_pixels_per_host_pixel", "source_content_rect_points",
                                            "source_display_size_points")}
    crops.update(coordinate_space=COORDINATE_SPACE, current_source_nonce=calibration.get("expected_nonce"),
                 calibration=calibration, comparison_ready=reason is None)
    if reason:
        crops["reason"] = reason
        out["cer"] = None
    out["crops"] = crops
    out["comparison_ready"] = reason is None
    return out


def main(argv: list[str]) -> int:
    if len(argv) == 8 and argv[1] == "calibrate":
        scene_path, nonce, host, viewer, out_path, viewer_out = argv[2:]
        try:
            scene = json.loads(Path(scene_path).read_text())
        except (OSError, ValueError):
            scene = {}
        result, image = calibrate(scene if isinstance(scene, dict) else {}, nonce, Path(host), Path(viewer))
        Path(out_path).write_text(json.dumps(result, sort_keys=True))
        if not result["verified"] or image is None:
            print(f"rd_marker_calibration.py: not verified: {result['reason']}", file=sys.stderr)
            return 1
        Path(viewer_out).write_bytes(crop_ppm(image, result["viewer_crop"]))
        print(",".join(map(str, result["host_crop"])), ",".join(map(str, result["viewer_crop"])))
        return 0
    if len(argv) == 4 and argv[1] == "receipt":
        path = Path(argv[2])
        try:
            ocr = json.loads(path.read_text())
        except (OSError, ValueError):
            ocr = {"cer": None}
        try:
            calibration = json.loads(Path(argv[3]).read_text())
        except (OSError, ValueError):
            calibration = {}
        path.write_text(json.dumps(receipt(ocr if isinstance(ocr, dict) else {"cer": None},
                                           calibration if isinstance(calibration, dict) else {}), sort_keys=True))
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
