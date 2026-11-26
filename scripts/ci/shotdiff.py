#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26", "pillow>=10"]
# ///
"""shotdiff: one screenshot comparator and golden store for every platform's screenshot checks.

A screenshot is compared with a golden by perceptual similarity (SSIM on luma, Gaussian window 11,
sigma 1.5) and by the share of pixels that moved past a channel tolerance, over the whole image and
per named region. A region can be ignored (a clock, a cursor), or held to its own bounds (a glass
material that a software renderer draws differently from a GPU). Goldens are content-addressed: a
manifest (committed, small) maps each surface name to the sha256 of its golden PNG plus its spec,
and the PNG bytes live in a store keyed by that hash (a directory, or an S3-compatible bucket
through the `aws` CLI). Named refs in the store map an input key (for example the hash of the
inputs that render a surface) to a golden hash, so a golden rendered once is reused until its
inputs change.

    shotdiff.py compare GOLDEN.png SHOT.png [--spec SPEC.json] [--diff-out DIFF.png] [--json]
    shotdiff.py check --manifest goldens.json --store DIR_OR_S3 --shots DIR [--report OUT.md]
                      [--json-out OUT.json] [--diff-dir DIR] [--warn-only]
    shotdiff.py bless --manifest goldens.json --store DIR_OR_S3 --shots DIR [SURFACE ...]
    shotdiff.py put --store DIR_OR_S3 FILE ...          # prints each file's sha256
    shotdiff.py get --store DIR_OR_S3 SHA256 OUT.png
    shotdiff.py ref set|get --store DIR_OR_S3 KEY [SHA256]

A surface is a path under --shots without the .png suffix (`iphone/settings-bottom`).

Spec (per surface in the manifest, or `defaults` for all; every key optional):
    {"ssim_min": 0.985, "pixel_tolerance": 16, "changed_max": 0.01,
     "regions": [{"name": "clock", "rect": [0, 0, 1.0, 0.05], "ignore": true},
                 {"name": "glass", "rect": [10, 200, 400, 120], "ssim_min": 0.9}]}
A rect is [x, y, w, h]; a value at most 1.0 written with a decimal point (0.5, 1.0) is a fraction of
the image's width or height, so one spec holds across resolutions; integers are pixels.

Exit status: 0 every surface within bounds, 1 a surface failed (or is missing), 2 a usage or read
error. --warn-only reports and exits 0.

Tests: python3 tests/test_shotdiff.py (needs numpy and Pillow; `uv run --with numpy --with pillow`).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import numpy as np
    from PIL import Image
except ImportError as _error:  # pragma: no cover - reported at use
    np = None  # type: ignore[assignment]
    Image = None  # type: ignore[assignment]
    _IMPORT_ERROR: ImportError | None = _error
else:
    _IMPORT_ERROR = None

# Defaults, chosen against the iOS gate's measured noise (scripts/ci/ios_gate_screen_diff.py: the
# largest unchanged still moved 0.18% of pixels at tolerance 16): a pixel moved when a channel moves
# by more than 16 of 255; a surface passes at most 1% moved pixels and SSIM at least 0.985.
# The mean SSIM of a whole phone screen hides a small change (a 500x40 bar on a 1179x2556 still
# moves it by under 0.01), so the worst TILE x TILE tile is held to tile_ssim_min as well.
# SSIM reads sub-visible dither on a flat background as lost structure (+-2 levels of noise on white
# scores about 0.97), so a pixel within noise_floor levels of its golden in every channel counts as
# equal before SSIM is taken.
DEFAULT_SPEC: dict[str, Any] = {"ssim_min": 0.985, "tile_ssim_min": 0.9, "tile": 32, "pixel_tolerance": 16,
                                "changed_max": 0.01, "noise_floor": 2, "regions": []}
SPEC_KEYS = set(DEFAULT_SPEC)
BOUND_KEYS = ("ssim_min", "tile_ssim_min", "pixel_tolerance", "changed_max")
REGION_KEYS = {"name", "rect", "ignore", *BOUND_KEYS}
SHA256 = re.compile(r"^[0-9a-f]{64}$")
REF_KEY = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")

SSIM_C1 = (0.01 * 255) ** 2
SSIM_C2 = (0.03 * 255) ** 2
GAUSS_RADIUS = 5
GAUSS_SIGMA = 1.5


class ShotdiffError(Exception):
    pass


def _need_libs() -> None:
    if _IMPORT_ERROR is not None:
        raise ShotdiffError(
            f"needs numpy and Pillow ({_IMPORT_ERROR}); run with `uv run scripts/ci/shotdiff.py` "
            "or `pip install numpy pillow`")


# --- Images ------------------------------------------------------------------

def load_rgba(source: bytes | Path) -> "np.ndarray":
    """An image as an HxWx4 uint8 array."""
    _need_libs()
    import io
    try:
        data = source.read_bytes() if isinstance(source, Path) else source
        with Image.open(io.BytesIO(data)) as image:
            return np.asarray(image.convert("RGBA"), dtype=np.uint8)
    except (OSError, ValueError) as error:
        raise ShotdiffError(f"cannot read image {source if isinstance(source, Path) else '(bytes)'}: {error}")


def _gauss_kernel() -> "np.ndarray":
    x = np.arange(-GAUSS_RADIUS, GAUSS_RADIUS + 1, dtype=np.float64)
    k = np.exp(-(x * x) / (2 * GAUSS_SIGMA * GAUSS_SIGMA))
    return k / k.sum()


def _blur(a: "np.ndarray", k: "np.ndarray") -> "np.ndarray":
    """Separable Gaussian blur with edge padding, same shape as `a`."""
    r = len(k) // 2
    p = np.pad(a, r, mode="edge")
    h, w = a.shape
    rows = np.zeros((h + 2 * r, w), dtype=np.float32)
    tmp = np.empty_like(rows)
    for i, weight in enumerate(k):
        np.multiply(p[:, i:i + w], np.float32(weight), out=tmp)
        rows += tmp
    out = np.zeros((h, w), dtype=np.float32)
    tmp = tmp[:h]
    for i, weight in enumerate(k):
        np.multiply(rows[i:i + h, :], np.float32(weight), out=tmp)
        out += tmp
    return out


def ssim_map(a: "np.ndarray", b: "np.ndarray") -> "np.ndarray":
    """Per-pixel SSIM of two luma arrays of one shape (Wang et al. 2004, Gaussian window)."""
    k = _gauss_kernel()
    mu_a, mu_b = _blur(a, k), _blur(b, k)
    aa, bb, ab = _blur(a * a, k), _blur(b * b, k), _blur(a * b, k)
    var_a = aa - mu_a * mu_a
    var_b = bb - mu_b * mu_b
    cov = ab - mu_a * mu_b
    num = (2 * mu_a * mu_b + SSIM_C1) * (2 * cov + SSIM_C2)
    den = (mu_a * mu_a + mu_b * mu_b + SSIM_C1) * (var_a + var_b + SSIM_C2)
    return num / den


# --- Specs -------------------------------------------------------------------

def merge_spec(*specs: dict[str, Any] | None) -> dict[str, Any]:
    out = dict(DEFAULT_SPEC)
    out["regions"] = []
    for spec in specs:
        if not spec:
            continue
        unknown = set(spec) - SPEC_KEYS
        if unknown:
            raise ShotdiffError(f"unknown spec keys {sorted(unknown)} (known: {sorted(SPEC_KEYS)})")
        for key, value in spec.items():
            if key == "regions":
                out["regions"] = list(out["regions"]) + list(value)
            else:
                out[key] = value
    for region in out["regions"]:
        unknown = set(region) - REGION_KEYS
        if unknown:
            raise ShotdiffError(f"unknown region keys {sorted(unknown)} in {region.get('name', region)}")
        if "rect" not in region or len(region["rect"]) != 4:
            raise ShotdiffError(f"region {region.get('name', region)} needs rect [x, y, w, h]")
    return out


def _span(value: float | int, size: int) -> int:
    if isinstance(value, float) and 0.0 <= value <= 1.0:
        return int(round(value * size))
    return int(value)


def region_box(rect: list[float | int], width: int, height: int) -> tuple[int, int, int, int]:
    """[x, y, w, h] (pixels, or fractions as floats <= 1.0) clipped to the image: (x0, y0, x1, y1)."""
    x, y, w, h = rect
    x0, y0 = _span(x, width), _span(y, height)
    x1, y1 = x0 + _span(w, width), y0 + _span(h, height)
    return max(0, x0), max(0, y0), min(width, x1), min(height, y1)


# --- Compare -----------------------------------------------------------------

@dataclass
class RegionResult:
    name: str
    ssim: float | None
    changed: float
    ok: bool
    ignored: bool = False
    reasons: list[str] = field(default_factory=list)


@dataclass
class Result:
    ok: bool
    identical: bool
    ssim: float | None
    changed: float
    box: tuple[int, int, int, int] | None  # x, y, w, h of moved pixels outside ignored regions
    size: tuple[int, int]
    reasons: list[str]
    regions: list[RegionResult]

    def to_json(self) -> dict[str, Any]:
        return {
            "ok": self.ok, "identical": self.identical, "ssim": self.ssim, "changed": self.changed,
            "box": list(self.box) if self.box else None, "size": list(self.size), "reasons": self.reasons,
            "regions": [vars(r) for r in self.regions],
        }


def worst_tile(smap: "np.ndarray", mask: "np.ndarray", tile: int) -> tuple[float | None, tuple[int, int, int, int] | None]:
    """The lowest mean SSIM over tile x tile tiles at least half inside `mask`, and that tile's x, y, w, h."""
    h, w = smap.shape
    th, tw = -(-h // tile), -(-w // tile)
    ph, pw = th * tile - h, tw * tile - w
    vals = np.pad(np.where(mask, smap, 0.0), ((0, ph), (0, pw)))
    cnt = np.pad(mask.astype(np.float64), ((0, ph), (0, pw)))
    sums = vals.reshape(th, tile, tw, tile).sum(axis=(1, 3))
    counts = cnt.reshape(th, tile, tw, tile).sum(axis=(1, 3))
    full = np.pad(np.ones_like(mask, dtype=np.float64), ((0, ph), (0, pw))).reshape(th, tile, tw, tile).sum(axis=(1, 3))
    usable = counts * 2 >= full
    if not usable.any():
        return None, None
    means = np.where(usable, sums / np.maximum(counts, 1), np.inf)
    ty, tx = np.unravel_index(int(np.argmin(means)), means.shape)
    x, y = int(tx) * tile, int(ty) * tile
    return float(means[ty, tx]), (x, y, min(tile, w - x), min(tile, h - y))


def _bounds(name: str, ssim: float | None, changed: float, spec: dict[str, Any],
            tile: tuple[float | None, Any] = (None, None)) -> list[str]:
    reasons = []
    if ssim is not None and ssim < spec["ssim_min"]:
        reasons.append(f"{name}: SSIM {ssim:.4f} < {spec['ssim_min']}")
    if tile[0] is not None and tile[0] < spec["tile_ssim_min"]:
        x, y, w, h = tile[1]
        reasons.append(f"{name}: tile at x{x} y{y} SSIM {tile[0]:.4f} < {spec['tile_ssim_min']}")
    if changed > spec["changed_max"]:
        reasons.append(f"{name}: {changed:.2%} pixels moved > {spec['changed_max']:.2%}")
    return reasons


def compare(golden: bytes | Path, shot: bytes | Path, spec: dict[str, Any] | None = None,
            diff_out: Path | None = None) -> Result:
    """Compare a shot with its golden; `diff_out` gets a picture of the difference when it fails."""
    spec = merge_spec(spec)
    try:
        g_bytes = golden.read_bytes() if isinstance(golden, Path) else golden
        s_bytes = shot.read_bytes() if isinstance(shot, Path) else shot
    except OSError as error:
        raise ShotdiffError(f"cannot read {error.filename}: {error.strerror}")
    g, s = load_rgba(g_bytes), load_rgba(s_bytes)
    height, width = s.shape[:2]
    if g.shape != s.shape:
        gh, gw = g.shape[:2]
        return Result(False, False, None, 1.0, None, (width, height),
                      [f"size {gw}x{gh} -> {width}x{height}"], [])
    g_rgb, s_rgb = _composite(g), _composite(s)
    if g_bytes == s_bytes or np.array_equal(g_rgb, s_rgb):
        regions = [RegionResult(r.get("name", f"region{i}"), 1.0, 0.0, True, bool(r.get("ignore")))
                   for i, r in enumerate(spec["regions"])]
        return Result(True, True, 1.0, 0.0, None, (width, height), [], regions)

    luma = np.array([0.299, 0.587, 0.114])
    delta = np.abs(g_rgb - s_rgb).max(axis=2)
    s_seen = np.where((delta <= spec["noise_floor"])[..., None], g_rgb, s_rgb)
    smap = ssim_map((g_rgb @ luma).astype(np.float32), (s_seen @ luma).astype(np.float32))

    keep = np.ones((height, width), dtype=bool)
    boxes = [region_box(r["rect"], width, height) for r in spec["regions"]]
    for region, (x0, y0, x1, y1) in zip(spec["regions"], boxes):
        if region.get("ignore"):
            keep[y0:y1, x0:x1] = False

    # Each region with its own bounds is judged by them; the image's bounds hold everywhere else.
    outside = keep.copy()
    regions: list[RegionResult] = []
    region_reasons: list[str] = []
    for i, (region, box) in enumerate(zip(spec["regions"], boxes)):
        name = region.get("name", f"region{i}")
        x0, y0, x1, y1 = box
        if region.get("ignore") or x1 <= x0 or y1 <= y0:
            regions.append(RegionResult(name, None, 0.0, True, bool(region.get("ignore"))))
            continue
        outside[y0:y1, x0:x1] = False
        rspec = {**spec, **{k: region[k] for k in BOUND_KEYS if k in region}}
        if "ssim_min" in region and "tile_ssim_min" not in region:
            rspec["tile_ssim_min"] = min(spec["tile_ssim_min"], region["ssim_min"])
        r_ssim, r_changed, r_tile = _measure(smap[y0:y1, x0:x1], delta[y0:y1, x0:x1],
                                             keep[y0:y1, x0:x1], rspec)
        if r_tile[1] is not None:
            tx, ty, tw, th = r_tile[1]
            r_tile = (r_tile[0], (tx + x0, ty + y0, tw, th))
        r_reasons = _bounds(name, r_ssim, r_changed, rspec, r_tile)
        regions.append(RegionResult(name, r_ssim, r_changed, not r_reasons, False, r_reasons))
        region_reasons += r_reasons
    o_ssim, o_changed, o_tile = _measure(smap, delta, outside, spec)
    reasons = _bounds("image", o_ssim, o_changed, spec, o_tile) + region_reasons

    moved = (delta > spec["pixel_tolerance"]) & keep
    kept = int(keep.sum())
    changed = float(moved.sum()) / kept if kept else 0.0
    ssim = float(smap[keep].mean()) if kept else None
    ys, xs = np.nonzero(moved)
    box_xywh = ((int(xs.min()), int(ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1))
                if len(xs) else (o_tile[1] if reasons and o_tile[1] else None))
    if diff_out is not None and reasons:
        write_diff(s_rgb, moved, smap, keep, diff_out)
    return Result(not reasons, False, ssim, changed, box_xywh, (width, height), reasons, regions)


def _composite(rgba: "np.ndarray") -> "np.ndarray":
    """RGB over white as float, so transparent pixels compare as what a viewer sees."""
    rgb = rgba[..., :3].astype(np.float64)
    alpha = rgba[..., 3:4].astype(np.float64) / 255.0
    return np.round(rgb * alpha + 255.0 * (1.0 - alpha))


def _measure(smap: "np.ndarray", delta: "np.ndarray", mask: "np.ndarray", spec: dict[str, Any]):
    n = int(mask.sum())
    if not n:
        return None, 0.0, (None, None)
    changed = float(((delta > spec["pixel_tolerance"]) & mask).sum()) / n
    return float(smap[mask].mean()), changed, worst_tile(smap, mask, int(spec["tile"]))


def write_diff(shot: "np.ndarray", moved: "np.ndarray", smap: "np.ndarray", keep: "np.ndarray", out: Path) -> None:
    """The shot dimmed, structural loss in yellow, moved pixels in red, ignored regions blue-tinted."""
    base = shot * 0.35 + 255 * 0.65 * 0.25
    loss = np.clip((1.0 - smap) * 4.0, 0.0, 1.0)[..., None]
    base = base * (1 - loss) + np.array([255.0, 210.0, 0.0]) * loss
    base[moved] = [230.0, 20.0, 20.0]
    base[~keep] = base[~keep] * 0.5 + np.array([40.0, 80.0, 200.0]) * 0.5
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").save(out)


# --- Store -------------------------------------------------------------------

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Store:
    """Content-addressed PNGs: objects/<aa>/<sha256>.png; refs/<key> holds a sha256."""

    def __init__(self, uri: str):
        self.uri = uri.rstrip("/")
        self.s3 = self.uri.startswith("s3://")
        if not self.s3:
            self.root = Path(self.uri)

    @staticmethod
    def object_key(digest: str) -> str:
        if not SHA256.match(digest):
            raise ShotdiffError(f"not a sha256: {digest!r}")
        return f"objects/{digest[:2]}/{digest}.png"

    def _aws(self, *args: str, data: bytes | None = None) -> bytes | None:
        cmd = ["aws", "s3"]
        endpoint = os.environ.get("SHOTDIFF_S3_ENDPOINT")
        if endpoint:
            cmd += ["--endpoint-url", endpoint]
        cmd += list(args)
        try:
            done = subprocess.run(cmd, input=data, capture_output=True, timeout=120)
        except FileNotFoundError:
            raise ShotdiffError("an s3:// store needs the aws CLI")
        except subprocess.TimeoutExpired:
            raise ShotdiffError(f"aws s3 {args[0]} past 120 s")
        if done.returncode != 0:
            message = done.stderr.decode(errors="replace").strip()
            if "404" in message or "Not Found" in message or "does not exist" in message:
                return None
            raise ShotdiffError(f"aws s3 {' '.join(args)}: {message}")
        return done.stdout

    def _read(self, key: str) -> bytes | None:
        if self.s3:
            return self._aws("cp", f"{self.uri}/{key}", "-")
        path = self.root / key
        return path.read_bytes() if path.is_file() else None

    def _write(self, key: str, data: bytes) -> None:
        if self.s3:
            self._aws("cp", "-", f"{self.uri}/{key}", data=data)
            return
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        tmp.write_bytes(data)
        os.replace(tmp, path)

    def put(self, data: bytes) -> str:
        digest = sha256_bytes(data)
        key = self.object_key(digest)
        if self.s3 or not (self.root / key).is_file():
            self._write(key, data)
        return digest

    def get(self, digest: str) -> bytes:
        data = self._read(self.object_key(digest))
        if data is None:
            raise ShotdiffError(f"golden {digest[:12]} is not in {self.uri}")
        if sha256_bytes(data) != digest:
            raise ShotdiffError(f"golden {digest[:12]} in {self.uri} does not match its hash")
        return data

    def ref_get(self, key: str) -> str | None:
        if not REF_KEY.match(key) or ".." in key:
            raise ShotdiffError(f"bad ref key {key!r}")
        data = self._read(f"refs/{key}")
        return data.decode().strip() if data else None

    def ref_set(self, key: str, digest: str) -> None:
        self.object_key(digest)
        if not REF_KEY.match(key) or ".." in key:
            raise ShotdiffError(f"bad ref key {key!r}")
        self._write(f"refs/{key}", (digest + "\n").encode())


# --- Manifest and check ------------------------------------------------------

def read_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "defaults": {}, "surfaces": {}}
    try:
        manifest = json.loads(path.read_text())
    except json.JSONDecodeError as error:
        raise ShotdiffError(f"{path}: {error}")
    manifest.setdefault("version", 1)
    manifest.setdefault("defaults", {})
    manifest.setdefault("surfaces", {})
    return manifest


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    manifest["surfaces"] = dict(sorted(manifest["surfaces"].items()))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n")


def find_shots(directory: Path) -> dict[str, Path]:
    if not directory.is_dir():
        raise ShotdiffError(f"--shots {directory} is not a directory")
    return {p.relative_to(directory).with_suffix("").as_posix(): p
            for p in sorted(directory.rglob("*.png")) if p.is_file()}


@dataclass
class Row:
    surface: str
    status: str  # same, within, failed, missing, new, error
    result: Result | None = None
    detail: str = ""


def _check_one(surface: str, entry: dict[str, Any], manifest: dict[str, Any], store: Store,
               shot: Path | None, diff_dir: Path | None) -> Row:
    if shot is None:
        return Row(surface, "missing", detail="no screenshot taken")
    try:
        spec = merge_spec(manifest.get("defaults"), entry.get("spec"))
        golden = store.get(entry["sha256"])
        out = diff_dir / f"{surface}.diff.png" if diff_dir else None
        result = compare(golden, shot, spec, out)
    except ShotdiffError as error:
        return Row(surface, "error", detail=str(error))
    return Row(surface, "same" if result.identical else ("within" if result.ok else "failed"), result)


def check(manifest: dict[str, Any], store: Store, shots: dict[str, Path], diff_dir: Path | None,
          jobs: int = 0) -> list[Row]:
    """Every manifest surface against its shot, then every shot with no golden. numpy drops the GIL in
    the blur, so threads overlap: a phone-size pair takes about 1 s on one core."""
    from concurrent.futures import ThreadPoolExecutor
    jobs = jobs or min(8, os.cpu_count() or 1)
    items = list(manifest["surfaces"].items())
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        rows = list(pool.map(lambda kv: _check_one(kv[0], kv[1], manifest, store, shots.get(kv[0]), diff_dir),
                             items))
    for surface in shots:
        if surface not in manifest["surfaces"]:
            rows.append(Row(surface, "new", detail="no golden; `shotdiff.py bless` adds it"))
    return rows


def render(rows: list[Row], title: str = "Screenshots vs goldens") -> str:
    count = {s: sum(1 for r in rows if r.status == s) for s in ("same", "within", "failed", "missing", "new", "error")}
    lines = [f"### {title}", "",
             f"{count['same']} identical, {count['within']} within bounds, {count['failed']} failed, "
             f"{count['missing']} missing, {count['new']} new, {count['error']} unreadable.", ""]
    shown = [r for r in rows if r.status not in ("same",)]
    if shown:
        lines += ["| surface | result | SSIM | moved | where | why |", "|---|---|---|---|---|---|"]
        for r in shown:
            res = r.result
            ssim = f"{res.ssim:.4f}" if res and res.ssim is not None else "-"
            moved = f"{res.changed:.2%}" if res else "-"
            where = "x{} y{} {}x{}".format(*res.box) if res and res.box else "-"
            why = "; ".join(res.reasons) if res and res.reasons else r.detail
            lines.append(f"| `{r.surface}` | {r.status} | {ssim} | {moved} | {where} | {why or '-'} |")
        lines.append("")
    return "\n".join(lines) + "\n"


def failed(rows: list[Row]) -> bool:
    return any(r.status in ("failed", "missing", "error") for r in rows)


# --- CLI ---------------------------------------------------------------------

def _load_spec(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ShotdiffError(f"--spec {path}: {error}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="shotdiff", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("compare", help="compare one shot with one golden")
    p.add_argument("golden", type=Path)
    p.add_argument("shot", type=Path)
    p.add_argument("--spec")
    p.add_argument("--diff-out", type=Path)
    p.add_argument("--json", action="store_true")

    for name in ("check", "bless"):
        p = sub.add_parser(name, help="compare a directory of shots with the manifest" if name == "check"
                           else "store shots as goldens and record them in the manifest")
        p.add_argument("--manifest", type=Path, required=True)
        p.add_argument("--store", required=True)
        p.add_argument("--shots", type=Path, required=True)
        if name == "check":
            p.add_argument("--report", type=Path, help="append the markdown table (e.g. $GITHUB_STEP_SUMMARY)")
            p.add_argument("--json-out", type=Path)
            p.add_argument("--diff-dir", type=Path)
            p.add_argument("--warn-only", action="store_true")
            p.add_argument("--title", default="Screenshots vs goldens")
            p.add_argument("--jobs", type=int, default=0, help="parallel compares (default: cores, at most 8)")
        else:
            p.add_argument("surfaces", nargs="*", help="only these (default: every shot)")

    p = sub.add_parser("put")
    p.add_argument("--store", required=True)
    p.add_argument("files", nargs="+", type=Path)
    p = sub.add_parser("get")
    p.add_argument("--store", required=True)
    p.add_argument("sha256")
    p.add_argument("out", type=Path)
    p = sub.add_parser("ref")
    p.add_argument("action", choices=("get", "set"))
    p.add_argument("--store", required=True)
    p.add_argument("key")
    p.add_argument("sha256", nargs="?")

    args = parser.parse_args(argv)
    try:
        return _run(args)
    except ShotdiffError as error:
        print(f"shotdiff: {error}", file=sys.stderr)
        return 2


def _run(args: argparse.Namespace) -> int:
    if args.cmd == "compare":
        result = compare(args.golden, args.shot, _load_spec(args.spec), args.diff_out)
        if args.json:
            print(json.dumps(result.to_json(), indent=2))
        else:
            ssim = f"{result.ssim:.4f}" if result.ssim is not None else "-"
            print(f"{'ok' if result.ok else 'FAIL'}: SSIM {ssim}, {result.changed:.2%} moved"
                  + (f"; {'; '.join(result.reasons)}" if result.reasons else ""))
        return 0 if result.ok else 1

    store = Store(args.store)
    if args.cmd == "put":
        for path in args.files:
            print(f"{store.put(path.read_bytes())}  {path}")
        return 0
    if args.cmd == "get":
        args.out.write_bytes(store.get(args.sha256))
        return 0
    if args.cmd == "ref":
        if args.action == "get":
            digest = store.ref_get(args.key)
            if digest is None:
                return 1
            print(digest)
            return 0
        if not args.sha256:
            raise ShotdiffError("ref set needs KEY SHA256")
        store.ref_set(args.key, args.sha256)
        return 0

    manifest = read_manifest(args.manifest)
    shots = find_shots(args.shots)
    if args.cmd == "bless":
        chosen = args.surfaces or list(shots)
        for surface in chosen:
            if surface not in shots:
                raise ShotdiffError(f"no shot for {surface} under {args.shots}")
            digest = store.put(shots[surface].read_bytes())
            entry = manifest["surfaces"].setdefault(surface, {})
            entry["sha256"] = digest
            print(f"{digest[:12]}  {surface}")
        write_manifest(args.manifest, manifest)
        return 0

    rows = check(manifest, store, shots, args.diff_dir, args.jobs)
    text = render(rows, args.title)
    if args.report:
        with args.report.open("a") as out:
            out.write(text)
    else:
        sys.stdout.write(text)
    if args.json_out:
        args.json_out.write_text(json.dumps([{"surface": r.surface, "status": r.status, "detail": r.detail,
                                              "result": r.result.to_json() if r.result else None} for r in rows],
                                            indent=2) + "\n")
    if failed(rows):
        if args.warn_only:
            print(f"::warning::shotdiff: {sum(1 for r in rows if r.status in ('failed', 'missing', 'error'))} "
                  "surface(s) outside their goldens' bounds")
            return 0
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
