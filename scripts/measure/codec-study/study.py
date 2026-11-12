"""The codec study's library path and its report (README.md).

  study.py settings                          the library settings, one per line
  study.py encode RUNS OUT_DIR IMAGE...      one JSON line per image and setting (stdout)
  study.py prepare IN OUT [LONG_EDGE]        an opaque RGB copy (the corpus step where swiftc is absent)
  study.py pairs RECORDS OUT                 the OCR pairs (decoded frame vs its lossless original)
  study.py report DIR OUT_JSON OUT_MD        results.json and summary.md from DIR's JSON lines

Times are milliseconds: the median of RUNS runs after one warm-up run (at most 3 runs when the
warm-up took over a second), from RGB pixels in memory to the encoded bytes, and from the bytes back
to pixels. Libraries: libjpeg-turbo, libwebp and libpng through Pillow; libavif with aom, rav1e and
SVT-AV1 (dav1d decodes) through pillow-avif-plugin; libjxl through imagecodecs; mozjpeg's lossless
pass through mozjpeg-lossless-optimization. Versions are pinned in requirements.txt.
"""

from __future__ import annotations

import io
import json
import os
import statistics
import sys
import time
from pathlib import Path

THREADS = os.cpu_count() or 1


def lazy():
    """The codec modules, imported only by the verbs that encode."""
    import numpy
    from PIL import Image

    Image.init()
    # Pillow has its own AVIF plugin (aom and dav1d); pillow-avif-plugin replaces it on import,
    # bringing rav1e and SVT-AV1 too. Import it after Image.init(), so it is the one registered.
    import pillow_avif  # noqa: F401
    from pillow_avif import AvifImagePlugin

    AvifImagePlugin.DEFAULT_MAX_THREADS = THREADS  # dav1d decodes on every core, as the encoders do
    import imagecodecs
    import mozjpeg_lossless_optimization

    save = Image.SAVE.get("AVIF")
    if save is None or not save.__module__.startswith("pillow_avif"):
        raise SystemExit(f"study.py: the AVIF saver is {save and save.__module__}, not pillow-avif-plugin's")
    return numpy, Image, imagecodecs, mozjpeg_lossless_optimization


def pil_encode(Image, image, fmt, **params):
    buffer = io.BytesIO()
    image.save(buffer, format=fmt, **params)
    return buffer.getvalue()


def pil_decode(Image, data):
    image = Image.open(io.BytesIO(data))
    image.load()
    return image


def settings():
    """(id, codec, lib, encode(ctx, image, array) -> bytes, ext, note). JPEG XL takes the array."""
    out = []

    def add(sid, codec, lib, fn, ext, note):
        out.append((sid, codec, lib, fn, ext, note))

    for level in (1, 6):
        add(f"png-zlib{level}", "png", "libpng", lambda c, im, a, level=level: pil_encode(c.Image, im, "PNG", compress_level=level), "png",
            f"libpng, zlib level {level}")
    for quality, sub in ((75, 2), (85, 2), (85, 0), (92, 0)):
        tag = "420" if sub == 2 else "444"
        add(f"jpeg-turbo-q{quality}-{tag}", "jpeg", "libjpeg-turbo",
            lambda c, im, a, quality=quality, sub=sub: pil_encode(c.Image, im, "JPEG", quality=quality, subsampling=sub), "jpg",
            f"libjpeg-turbo q{quality} 4:{'2:0' if sub == 2 else '4:4'}")
    add("jpeg-turbo-q85-444-moz", "jpeg", "libjpeg-turbo+mozjpeg",
        lambda c, im, a: c.moz.optimize(pil_encode(c.Image, im, "JPEG", quality=85, subsampling=0)), "jpg",
        "libjpeg-turbo q85 4:4:4, then mozjpeg's lossless pass (progressive, optimized Huffman)")
    for quality, method in ((80, 4), (90, 4), (90, 1)):
        add(f"webp-q{quality}-m{method}", "webp", "libwebp",
            lambda c, im, a, quality=quality, method=method: pil_encode(c.Image, im, "WEBP", quality=quality, method=method), "webp",
            f"libwebp lossy q{quality} method {method} (lossy WebP is always 4:2:0)")
    # cwebp -z LEVEL is libwebp's lossless preset: (method, quality) per level.
    for level, (method, quality) in {0: (0, 0), 1: (1, 20), 3: (3, 30), 6: (4, 75)}.items():
        add(f"webp-ll-z{level}", "webp", "libwebp",
            lambda c, im, a, method=method, quality=quality: pil_encode(c.Image, im, "WEBP", lossless=True, method=method, quality=quality), "webp",
            f"libwebp lossless, cwebp -z {level} (method {method}, quality {quality})")
    for sid, codec_name, speed, quality, sub in (
        ("avif-aom-s6-q80-444", "aom", 6, 80, "4:4:4"),
        ("avif-aom-s9-q80-444", "aom", 9, 80, "4:4:4"),
        ("avif-aom-s9-q80-420", "aom", 9, 80, "4:2:0"),
        ("avif-aom-s9-q90-444", "aom", 9, 90, "4:4:4"),
        ("avif-rav1e-s10-q80-444", "rav1e", 10, 80, "4:4:4"),
        ("avif-svt-s10-q80-420", "svt", 10, 80, "4:2:0"),  # SVT-AV1 encodes 4:2:0 only
    ):
        add(sid, "avif", f"libavif+{codec_name}",
            lambda c, im, a, codec_name=codec_name, speed=speed, quality=quality, sub=sub: pil_encode(
                c.Image, im, "AVIF", codec=codec_name, speed=speed, quality=quality, subsampling=sub, max_threads=THREADS), "avif",
            f"libavif {codec_name} speed {speed} quality {quality} {sub}")
    for effort in (1, 2, 3):
        add(f"jxl-ll-e{effort}", "jxl", "libjxl",
            lambda c, im, a, effort=effort: bytes(c.ic.jpegxl_encode(a, lossless=True, effort=effort, numthreads=THREADS)), "jxl",
            f"libjxl lossless effort {effort}")
    for effort in (1, 2, 3, 7):
        add(f"jxl-d1-e{effort}", "jxl", "libjxl",
            lambda c, im, a, effort=effort: bytes(c.ic.jpegxl_encode(a, distance=1.0, effort=effort, numthreads=THREADS)), "jxl",
            f"libjxl distance 1.0 effort {effort}" + (" (the default effort)" if effort == 7 else ""))
    return out


class Ctx:
    def __init__(self):
        self.numpy, self.Image, self.ic, self.moz = lazy()


def decode(ctx, codec, data):
    """The bytes back to an RGB array."""
    if codec == "jxl":
        return ctx.ic.jpegxl_decode(data, numthreads=THREADS)
    return ctx.numpy.asarray(pil_decode(ctx.Image, data).convert("RGB"))


def timed(runs, fn):
    start = time.perf_counter_ns()
    result = fn()
    warmup = (time.perf_counter_ns() - start) / 1e6
    count = min(runs, 3) if warmup > 1000 else runs
    samples = []
    for _ in range(count):
        t0 = time.perf_counter_ns()
        result = fn()
        samples.append((time.perf_counter_ns() - t0) / 1e6)
    return statistics.median(samples), count, result


def versions(ctx):
    import PIL
    import pillow_avif

    out = {"python": sys.version.split()[0], "pillow": PIL.__version__, "pillow_avif_plugin": getattr(pillow_avif, "__version__", "?"),
           "imagecodecs": ctx.ic.__version__, "threads": THREADS}
    try:
        out["avif_codecs"] = pillow_avif._avif.codec_versions()
    except Exception as error:  # an older plugin
        out["avif_codecs"] = f"unknown ({error})"
    for name in ("jpegxl", "webp", "jpeg8", "png"):
        fn = getattr(ctx.ic, f"{name}_version", None)
        if fn:
            out[f"imagecodecs_{name}"] = fn()
    from PIL import features

    out["pillow_features"] = {name: features.version(name) for name in ("jpg", "webp", "zlib", "avif") if features.check(name)}
    return out


def encode(runs, out_dir, images, only=None):
    ctx = Ctx()
    print(json.dumps({"versions": versions(ctx)}), flush=True)
    chosen = [s for s in settings() if not only or any(token in s[0] for token in only.split(","))]
    for path in images:
        image = ctx.Image.open(path).convert("RGB")
        array = ctx.numpy.ascontiguousarray(ctx.numpy.asarray(image))
        # OUT_DIR/<size folder>/<image>: the native and 1366 copies of an image share its name.
        folder = Path(out_dir) / Path(path).parent.name / Path(path).stem
        folder.mkdir(parents=True, exist_ok=True)
        for sid, codec, lib, fn, ext, note in chosen:
            record = {"image": path, "setting": sid, "codec": codec, "lib": lib, "note": note, "width": image.width, "height": image.height}
            try:
                encode_ms, count, data = timed(runs, lambda: fn(ctx, image, array))
                decode_ms, _, pixels = timed(runs, lambda: decode(ctx, codec, data))
            except Exception as error:
                record["error"] = f"{type(error).__name__}: {error}"
                print(json.dumps(record), flush=True)
                continue
            encoded = folder / f"{sid}.{ext}"
            encoded.write_bytes(data)
            decoded = folder / f"{sid}.decoded.png"
            ctx.Image.fromarray(ctx.numpy.asarray(pixels)[..., :3]).save(decoded, compress_level=1)
            record.update({"bytes": len(data), "encode_ms": encode_ms, "decode_ms": decode_ms, "runs": count, "encoded": str(encoded),
                           "decoded": str(decoded), "decoder": "dav1d" if codec == "avif" else lib.split("+")[0]})
            if codec == "jpeg":
                record["subsampling"] = jpeg_subsampling(data)
            print(json.dumps(record), flush=True)


def jpeg_subsampling(data: bytes) -> str:
    """4:4:4, 4:2:2 or 4:2:0, from the first SOF segment's luma sampling factors."""
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            return "?"
        marker, length = data[i + 1], int.from_bytes(data[i + 2:i + 4], "big")
        if marker in (0xC0, 0xC1, 0xC2) and i + 11 < len(data):
            if data[i + 9] == 1:
                return "gray"
            factors = data[i + 11]
            h, v = factors >> 4, factors & 15
            return {(1, 1): "4:4:4", (2, 1): "4:2:2", (2, 2): "4:2:0"}.get((h, v), f"{h}x{v}")
        i += 2 + length
    return "?"


def prepare(src, dst, long_edge=None):
    from PIL import Image

    image = Image.open(src)
    if image.mode in ("RGBA", "LA", "P"):
        image = image.convert("RGBA")
        background = Image.new("RGBA", image.size, (255, 255, 255, 255))
        image = Image.alpha_composite(background, image)
    image = image.convert("RGB")
    if long_edge:
        long = max(image.size)
        if long <= long_edge:
            raise SystemExit(3)
        scale = long_edge / long
        image = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.LANCZOS)
    image.save(dst, compress_level=6)


def read_lines(path):
    out = []
    if not Path(path).exists():
        return out
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def pairs(records_path, out_path):
    lines = []
    for record in read_lines(records_path):
        if "decoded" in record:
            lines.append(json.dumps({"id": f"{record['image']}|{record['setting']}", "ref": record["image"], "cand": record["decoded"]}))
    Path(out_path).write_text("\n".join(lines) + "\n")


def size_class(record):
    return "1366" if "/1366/" in record["image"] else "native"


def kind(image_path):
    stem = Path(image_path).stem
    if stem.startswith("synthetic-"):
        return stem.split("-")[1]
    return "repo"


def pct(values, q):
    values = sorted(values)
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def report(folder, out_json, out_md):
    folder = Path(folder)
    machine = json.loads((folder / "machine.json").read_text()) if (folder / "machine.json").exists() else {}
    records, lib_versions, errors = [], {}, []
    for name in ("library.jsonl", "imageio.jsonl"):
        for record in read_lines(folder / name):
            if "versions" in record:
                lib_versions = record["versions"]
            elif "error" in record:
                errors.append(record)
            else:
                records.append(record)
    imageio_decode = {r["file"]: r for r in read_lines(folder / "imageio-decode.jsonl")}
    ocr = {r["id"]: r for r in read_lines(folder / "ocr.jsonl")}
    types = json.loads((folder / "imageio-types.json").read_text()) if (folder / "imageio-types.json").exists() else {}
    for record in records:
        decode = imageio_decode.get(record.get("encoded"), {})
        if "imageio_decode_ms" in decode:
            record["imageio_decode_ms"] = decode["imageio_decode_ms"]
        o = ocr.get(f"{record['image']}|{record['setting']}", {})
        if "cer" in o:
            record["cer"] = o["cer"]
            record["ref_chars"] = o.get("ref_chars")
        if record["codec"] == "jpeg" and not record.get("subsampling") and Path(record.get("encoded", "")).exists():
            record["subsampling"] = jpeg_subsampling(Path(record["encoded"]).read_bytes())
        record["size"] = size_class(record)
        record["kind"] = kind(record["image"])
    # Bytes against PNG (zlib 6) of the same image: the lossless baseline every row compares with.
    baseline = {r["image"]: r["bytes"] for r in records if r["setting"] == "png-zlib6"}
    for record in records:
        if record["image"] in baseline:
            record["vs_png"] = record["bytes"] / baseline[record["image"]]

    rows = []
    groups = {}
    for record in records:
        groups.setdefault((record["size"], record["setting"]), []).append(record)
    for (size, setting), group in sorted(groups.items()):
        cers = [r["cer"] for r in group if "cer" in r]
        io_dec = [r["imageio_decode_ms"] for r in group if "imageio_decode_ms" in r]
        ratios = [r["vs_png"] for r in group if "vs_png" in r]
        mpx = statistics.median(r["width"] * r["height"] / 1e6 for r in group)
        rows.append({
            "size": size, "setting": setting, "codec": group[0]["codec"], "lib": group[0]["lib"], "note": group[0]["note"],
            "images": len(group), "median_mpx": round(mpx, 2),
            "encode_ms": round(statistics.median(r["encode_ms"] for r in group), 2),
            "decode_ms": round(statistics.median(r["decode_ms"] for r in group), 2),
            "imageio_decode_ms": round(statistics.median(io_dec), 2) if io_dec else None,
            "bytes": int(statistics.median(r["bytes"] for r in group)),
            "vs_png": round(statistics.median(ratios), 3) if ratios else None,
            "cer_mean": round(statistics.mean(cers), 4) if cers else None,
            "cer_p90": round(pct(cers, 0.9), 4) if cers else None,
            "cer_max": round(max(cers), 4) if cers else None,
            "cer_text_mean": round(statistics.mean(r["cer"] for r in group if "cer" in r and r["kind"] in ("terminal", "code", "chat")), 4)
            if any("cer" in r and r["kind"] in ("terminal", "code", "chat") for r in group) else None,
            "subsampling": sorted({r["subsampling"] for r in group if r.get("subsampling")}) or None,
        })
    results = {"schema": "cmux.codec-study/1", "machine": machine, "versions": lib_versions, "imageio_types": types,
               "rows": rows, "records": records, "errors": errors}
    Path(out_json).write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")

    def fmt(value, digits=1):
        if value is None:
            return "-"
        return f"{value:.{digits}f}" if isinstance(value, float) else str(value)

    md = ["# Still-frame codec study", ""]
    if machine:
        system = f"macOS {machine['macos']}" if machine.get("macos") else machine.get("os", "?")
        md.append(f"{machine.get('cpu', '?')}, {system}, {machine.get('host_kind', '')} at {machine.get('rev', '?')[:12]}, "
                  f"{machine.get('runs', '?')} runs per number (median), {machine.get('at', '')}.")
        md.append("")
    md.append("Encode and decode in ms (median over images), bytes median, `vs PNG` is the median of bytes / PNG zlib-6 bytes of "
              "the same image, CER is Vision OCR character error rate of the decoded frame against OCR of the lossless original "
              "(mean over images; text: terminal, code and chat scenes only).")
    for size in ("native", "1366"):
        part = [r for r in rows if r["size"] == size]
        if not part:
            continue
        md += ["", f"## {'Native Retina' if size == 'native' else '1366 px long edge (what computer use sends a model)'} "
                   f"({part[0]['images']} images, median {part[0]['median_mpx']} Mpx)", "",
               "| setting | encode ms | decode ms | ImageIO decode ms | KB | vs PNG | CER mean | CER text | CER max | note |",
               "|---|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
        for r in sorted(part, key=lambda r: (r["codec"], r["setting"])):
            note = r["note"] + (f" ({', '.join(r['subsampling'])})" if r["subsampling"] else "")
            md.append(f"| {r['setting']} | {fmt(r['encode_ms'])} | {fmt(r['decode_ms'])} | {fmt(r['imageio_decode_ms'])} | "
                      f"{r['bytes'] / 1024:.0f} | {fmt(r['vs_png'], 3)} | {fmt(r['cer_mean'], 4)} | {fmt(r['cer_text_mean'], 4)} | "
                      f"{fmt(r['cer_max'], 4)} | {note} |")
    if errors:
        md += ["", "## Settings that did not run", ""]
        seen = set()
        for e in errors:
            key = (e["setting"], e["error"])
            if key not in seen:
                seen.add(key)
                md.append(f"- {e['setting']}: {e['error']}")
    if types:
        md += ["", f"ImageIO encodes: {', '.join(types.get('encode', []))}.", "",
               f"ImageIO settings run: {', '.join(types.get('settings', []))}."]
    if lib_versions:
        md += ["", f"Libraries: `{json.dumps(lib_versions, sort_keys=True)}`"]
    Path(out_md).write_text("\n".join(md) + "\n")


def main(argv):
    if len(argv) >= 2 and argv[1] == "settings":
        for s in settings():
            print(s[0])
    elif len(argv) >= 5 and argv[1] == "encode":
        only = os.environ.get("CODEC_STUDY_ONLY") or None
        encode(int(argv[2]), argv[3], argv[4:], only)
    elif len(argv) in (4, 5) and argv[1] == "prepare":
        prepare(argv[2], argv[3], int(argv[4]) if len(argv) == 5 else None)
    elif len(argv) == 4 and argv[1] == "pairs":
        pairs(argv[2], argv[3])
    elif len(argv) == 5 and argv[1] == "report":
        report(argv[2], argv[3], argv[4])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
