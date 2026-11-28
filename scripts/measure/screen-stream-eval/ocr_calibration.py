"""Writes the per-repeat OCR calibration for a viewer whose window shows the host's display scaled and offset.

usage: ocr_calibration.py SOURCE_SCENE READINESS HOST_IMAGE VIEWER_IMAGE HOST_MARKER VIEWER_MARKER OUT

Apple's Screen Sharing draws the host's display inside its own window, scaled and moved, so the host
screenshot and the viewer frame share no coordinates. screen-eval-ocr compares them only with a
`cmux.screen-ocr-calibration/1` file whose binding fields equal the run's. This builds that file:

- HOST_MARKER and VIEWER_MARKER are screen-eval-marker-locate's output on each image
  (`origin X,Y cell C at X,Y`), or empty when it found no marker.
- The source scene (`cmux.source-scene/1`) gives the marker's origin and cell size and the text's
  content rect, in the host display's points.
- The host screenshot is the whole display, so its pixels per point are its width over the display's.
  The viewer's come from the located marker's cell, then snap to the fit that shows the whole display
  in the window (by width or by the height below the title bar) when that fit agrees with the cell
  within its rounding.
- Both crops are the content rect mapped through each side's marker origin and scale.

`verified` is true only when the marker was found in both images, the host's cell agrees with its
screenshot's scale, the viewer shows the whole content rect, and the readiness receipt supplies every
binding field. Otherwise the file says why, and the crops still printed are for the record only.

Prints `HOST_CROP VIEWER_CROP` (each X,Y,W,H) and exits 0 when verified; exits 1 when not.
"""

import importlib.util
import json
import re
import sys
from pathlib import Path

SCHEMA = "cmux.screen-ocr-calibration/1"
MARKER = re.compile(r"^origin (-?\d+),(-?\d+) cell (\d+) at -?\d+,-?\d+$")

_spec = importlib.util.spec_from_file_location("same_pixels", Path(__file__).resolve().parent / "same_pixels.py")
same_pixels = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(same_pixels)


def observe_factor(size: tuple[int, int]) -> float:
    """marker-locate reports in observe's pixels: the image fitted into 3840x2160, never enlarged."""
    return min(3840 / size[0], 2160 / size[1], 1.0)


def parse_marker(text: str, size: tuple[int, int]) -> tuple[float, float, float] | None:
    """(origin x, origin y, cell) in the image's own pixels, or None when no marker was located."""
    match = MARKER.match(text.strip())
    if not match:
        return None
    factor = observe_factor(size)
    x, y, cell = (int(v) for v in match.groups())
    return x / factor, y / factor, cell / factor


def mapped(origin: tuple[float, float], scale: float, rect: list[float]) -> list[int]:
    x, y, w, h = rect
    left, top = round(origin[0] + x * scale), round(origin[1] + y * scale)
    right, bottom = round(origin[0] + (x + w) * scale), round(origin[1] + (y + h) * scale)
    return [left, top, right - left, bottom - top]


def inside(crop: list[int], size: tuple[int, int]) -> bool:
    x, y, w, h = crop
    return x >= 0 and y >= 0 and w > 0 and h > 0 and x + w <= size[0] and y + h <= size[1]


def clamp(crop: list[int], size: tuple[int, int]) -> list[int]:
    x, y = max(0, crop[0]), max(0, crop[1])
    right, bottom = min(size[0], crop[0] + crop[2]), min(size[1], crop[1] + crop[3])
    return [x, y, max(1, right - x), max(1, bottom - y)]


def calibrate(scene: dict, readiness: dict | None, host: tuple[int, int] | None, viewer: tuple[int, int] | None,
              host_marker: str, viewer_marker: str) -> dict:
    """The calibration file's object: binding fields, crops, verified and evidence (or reason)."""
    observer = (readiness or {}).get("observer") or {}
    out = {
        "schema": SCHEMA,
        "host_image": {"width": host[0], "height": host[1]} if host else None,
        "viewer_image": {"width": viewer[0], "height": viewer[1]} if viewer else None,
        "source_content_rect_points": scene.get("content_rect_points"),
        "source_display_size_points": scene.get("display_size_points"),
        "requested_host": (readiness or {}).get("requested_host"),
        "quality_profile": (readiness or {}).get("quality_profile"),
        "pid": observer.get("pid"),
        "window": observer.get("window"),
        "window_geometry_points": observer.get("window_geometry_points"),
        "host_crop": None,
        "viewer_crop": None,
        "verified": False,
    }

    def refuse(reason: str) -> dict:
        out["verified"] = False
        out["reason"] = reason
        return out

    if scene.get("schema") != "cmux.source-scene/1":
        return refuse("the source scene is not cmux.source-scene/1")
    try:
        display_w, display_h = (float(v) for v in scene["display_size_points"])
        mark_x, mark_y = (float(v) for v in scene["marker_origin_points"])
        cell_points = float(scene["cell_size_points"])
        content = [float(v) for v in scene["content_rect_points"]]
        assert len(content) == 4 and display_w > 0 and display_h > 0 and cell_points > 0
    except (KeyError, TypeError, ValueError, AssertionError):
        return refuse("the source scene lacks display size, marker origin, cell size or content rect")
    if host is None or viewer is None:
        return refuse("the host screenshot or the viewer frame is not a readable PNG or PPM")

    host_found, viewer_found = parse_marker(host_marker, host), parse_marker(viewer_marker, viewer)

    # Host: its screenshot is the whole display, so the scale is exact; the marker must agree.
    host_scale = host[0] / display_w
    if host_found:
        # marker-locate's cell is whole pixels: within one pixel of the true cell.
        tolerance = 1.0 / cell_points
        if abs(host_found[2] / cell_points - host_scale) > tolerance:
            return refuse(f"host marker cell {host_found[2]:g} px disagrees with the screenshot's "
                          f"{host_scale:g} px per point")
        host_origin = (host_found[0] - mark_x * host_scale, host_found[1] - mark_y * host_scale)
        out["host_crop"] = clamp(mapped(host_origin, host_scale, content), host)

    # Viewer: the cell's scale, snapped to a whole-display fit that agrees with it.
    if viewer_found:
        cell_scale = viewer_found[2] / cell_points
        tolerance = 1.0 / cell_points
        left = viewer_found[0] - mark_x * cell_scale
        top = viewer_found[1] - mark_y * cell_scale
        fits = {"width": (viewer[0] - 2 * max(0.0, left)) / display_w, "height below the title bar": (viewer[1] - max(0.0, top)) / display_h}
        method, viewer_scale = "marker cell", cell_scale
        for name, fit in sorted(fits.items(), key=lambda item: abs(item[1] - cell_scale)):
            if abs(fit - cell_scale) <= tolerance:
                method, viewer_scale = f"fit by {name}", fit
                break
        viewer_origin = (viewer_found[0] - mark_x * viewer_scale, viewer_found[1] - mark_y * viewer_scale)
        viewer_crop = mapped(viewer_origin, viewer_scale, content)
        out["viewer_crop"] = clamp(viewer_crop, viewer)

    if not host_found or not viewer_found:
        missing = " and ".join(side for side, found in (("host screenshot", host_found), ("viewer frame", viewer_found)) if not found)
        return refuse(f"no source marker located in the {missing}")
    if not inside(viewer_crop, viewer):
        return refuse(f"the viewer frame does not show the whole content rect: mapped {viewer_crop} in "
                      f"{viewer[0]}x{viewer[1]}")
    unbound = [key for key in ("requested_host", "quality_profile", "pid", "window", "window_geometry_points")
               if out[key] is None]
    if unbound:
        return refuse(f"the readiness receipt lacks {', '.join(unbound)}")

    out["verified"] = True
    out["evidence"] = (
        f"source marker located in both images (nonce {scene.get('nonce')}): host origin "
        f"{host_found[0]:g},{host_found[1]:g} cell {host_found[2]:g} px at {host_scale:g} px/pt from the "
        f"screenshot width; viewer origin {viewer_found[0]:g},{viewer_found[1]:g} cell {viewer_found[2]:g} px "
        f"at {viewer_scale:.4f} px/pt ({method}); content rect {content} pt mapped through each"
    )
    return out


def main(argv: list[str]) -> int:
    if len(argv) != 8:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    scene_path, readiness_path, host_path, viewer_path, host_marker, viewer_marker, out_path = argv[1:]

    def load(path: str) -> dict | None:
        try:
            value = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    result = calibrate(load(scene_path) or {}, load(readiness_path), same_pixels.image_size(Path(host_path)),
                       same_pixels.image_size(Path(viewer_path)), host_marker, viewer_marker)
    Path(out_path).write_text(json.dumps(result, sort_keys=True))
    if not result["verified"]:
        print(f"ocr_calibration.py: not verified: {result['reason']}", file=sys.stderr)
        return 1
    print(",".join(map(str, result["host_crop"])), ",".join(map(str, result["viewer_crop"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
