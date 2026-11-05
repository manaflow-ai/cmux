#!/usr/bin/env python3
"""Offline grounding eval for the Computer Use fallback (HQ#7146 G3c).

Image-only: each sample is one screenshot plus one element description, and a
prediction is right when its point falls inside the target. No AX tree, no
history, thinking off, temperature 0, batch 1.

  prepare  --data DIR                   download ScreenSpot-Pro and OSWorld-G into DIR
  run      --data DIR --model ID --endpoint URL [--bench screenspot-pro,osworld-g]
           [--limit N] [--max-pixels N] [--out results.json]
  summarize RESULTS.json...             a Markdown table, one row per run

The endpoint is any OpenAI-compatible chat completions server: vLLM on a fleet
GPU (serve-vllm.sh) or mlx-vlm on Apple silicon (serve-mlx.sh). The model's
prompt and output parser come from its family in models.json.

Output schema `cmux.grounding-eval/1`:
  run:        at, host, model, hf, license, family, endpoint, server, max_pixels, limit
  benchmarks: NAME -> n, correct, accuracy, parse_failures, errors,
              by_group {GROUP: {n, accuracy}}, canvas {n, accuracy}
  latency_ms: p50, p95, mean, n (client wall time from request sent to answer read,
              batch 1, after one discarded warm-up request; image encoding excluded)
  memory_gb:  peak, source (mlx-vlm's per-request timings.peak_memory, or the GPU
              memory serve-vllm.sh samples, which is vLLM's up-front reservation)
A number that was not measured is null, never missing.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
import random
import re
import socket
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCHEMA = "cmux.grounding-eval/1"

SCREENSPOT_PRO = "likaixin/ScreenSpot-Pro"
OSWORLD_G = "MMInstruction/OSWorld-G"
HF = "https://huggingface.co"

# ScreenSpot-Pro groups whose apps draw their UI on a canvas (Blender,
# Photoshop, Premiere, AutoCAD, SolidWorks...): the AX tree there is thin,
# which is exactly when the helper falls back to grounding.
CANVAS_GROUPS = {"Creative", "CAD"}
# OSWorld-G: an icon with no text label, or a control drawn without one (the
# elements AX most often leaves unnamed).
CANVAS_GUI_TYPES = {"Image", "Slider", "Color Picker", "Grid"}


def osworld_canvas(types: list[str]) -> bool:
    return bool(CANVAS_GUI_TYPES.intersection(types)) or ("Icon" in types and "Label" not in types)

HOLO_SCHEMA = (
    "{'properties': {'x': {'description': 'X coordinate as integer in [0, 1000]', 'maximum': 1000, "
    "'minimum': 0, 'title': 'X', 'type': 'integer'}, 'y': {'description': 'Y coordinate as integer in "
    "[0, 1000]', 'maximum': 1000, 'minimum': 0, 'title': 'Y', 'type': 'integer'}}, 'required': ['x', 'y'], "
    "'title': 'VisualLocalizerOutput', 'type': 'object'}"
)
HOLO_JSON_SCHEMA = {
    "type": "object",
    "properties": {
        "x": {"type": "integer", "minimum": 0, "maximum": 1000},
        "y": {"type": "integer", "minimum": 0, "maximum": 1000},
    },
    "required": ["x", "y"],
}
OPENCUA_SYSTEM = (
    "You are a GUI agent. You are given a task and a screenshot of the screen. "
    "You need to perform a series of pyautogui actions to complete the task."
)
GTA1_SYSTEM = (
    "You are an expert UI element locator. Given a GUI image and a user's element description, provide the "
    "coordinates of the specified element as a single (x,y) point. The image resolution is height {height} "
    "and width {width}. For elements with area, return the center point.\n\nOutput the coordinate pair exactly:\n(x,y)"
)
VENUS_PROMPT = "Outline the position corresponding to the instruction: {}. The output should be only [x1,y1,x2,y2]."


# --- geometry -----------------------------------------------------------------------------------------------

def smart_resize(height: int, width: int, factor: int, min_pixels: int, max_pixels: int) -> tuple[int, int]:
    """Qwen2-VL's smart_resize: both sides a multiple of `factor`, area within [min, max], aspect kept."""
    if max(height, width) / min(height, width) > 200:
        raise ValueError(f"aspect ratio over 200: {width}x{height}")
    h = max(factor, round(height / factor) * factor)
    w = max(factor, round(width / factor) * factor)
    if h * w > max_pixels:
        beta = math.sqrt((height * width) / max_pixels)
        h = max(factor, math.floor(height / beta / factor) * factor)
        w = max(factor, math.floor(width / beta / factor) * factor)
    elif h * w < min_pixels:
        beta = math.sqrt(min_pixels / (height * width))
        h = math.ceil(height * beta / factor) * factor
        w = math.ceil(width * beta / factor) * factor
    return h, w


def point_in_target(x: float, y: float, target: dict) -> bool:
    if target["kind"] == "box":
        x1, y1, x2, y2 = target["box"]
        return x1 <= x <= x2 and y1 <= y <= y2
    return point_in_polygon(x, y, target["points"])


def point_in_polygon(x: float, y: float, points: list[tuple[float, float]]) -> bool:
    inside = False
    n = len(points)
    for i in range(n):
        x1, y1 = points[i]
        x2, y2 = points[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            cross = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < cross:
                inside = not inside
    return inside


# --- prompts and parsers ---------------------------------------------------------------------------------------

_NUMBER = r"-?\d+(?:\.\d+)?"


def strip_thinking(text: str) -> str:
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).replace("</think>", "").strip()


def build_messages(family: str, instruction: str, image_url: str, width: int, height: int) -> list[dict]:
    image = {"type": "image_url", "image_url": {"url": image_url}}
    if family == "holo":
        prompt = (
            "Localize an element on the GUI image according to the provided target and output a click position.\n"
            f" * You must output a valid JSON following the format: {HOLO_SCHEMA}\n"
            f" Your target is:\n{instruction}"
        )
        return [{"role": "user", "content": [image, {"type": "text", "text": prompt}]}]
    if family == "opencua":
        return [{"role": "system", "content": OPENCUA_SYSTEM},
                {"role": "user", "content": [image, {"type": "text", "text": instruction}]}]
    if family == "gta1":
        return [{"role": "system", "content": GTA1_SYSTEM.format(height=height, width=width)},
                {"role": "user", "content": [image, {"type": "text", "text": instruction}]}]
    if family == "venus":
        return [{"role": "user", "content": [image, {"type": "text", "text": VENUS_PROMPT.format(instruction)}]}]
    raise ValueError(f"unknown family {family}")


def parse_point(family: str, text: str, width: int, height: int) -> tuple[float, float] | None:
    """The predicted point in the coordinates of the image that was sent (width x height), or None."""
    text = strip_thinking(text)
    if family == "holo":
        x = re.search(rf'["\']?x["\']?\s*:\s*({_NUMBER})', text)
        y = re.search(rf'["\']?y["\']?\s*:\s*({_NUMBER})', text)
        if not (x and y):
            return None
        return float(x.group(1)) / 1000 * width, float(y.group(1)) / 1000 * height
    if family == "opencua":
        m = re.search(rf"x\s*=\s*({_NUMBER})\s*,\s*y\s*=\s*({_NUMBER})", text)
        if not m:
            return None
        return float(m.group(1)), float(m.group(2))
    if family == "gta1":
        m = re.search(rf"\(\s*({_NUMBER})\s*,\s*({_NUMBER})\s*\)", text)
        if not m:
            return None
        return float(m.group(1)), float(m.group(2))
    if family == "venus":
        nums = [float(v) for v in re.findall(_NUMBER, text)]
        if len(nums) >= 4:
            return (nums[0] + nums[2]) / 2, (nums[1] + nums[3]) / 2
        if len(nums) == 2:
            return nums[0], nums[1]
        return None
    raise ValueError(f"unknown family {family}")


def request_body(model: dict, served: str, messages: list[dict], structured: bool) -> dict:
    body = {"model": served, "messages": messages, "temperature": 0.0, "max_tokens": 128,
            # Holo2 reads `thinking`, Holo3.1 and Holo4 read `enable_thinking`; templates ignore the other.
            "chat_template_kwargs": {"enable_thinking": False, "thinking": False}}
    if structured and model["family"] == "holo":
        body["structured_outputs"] = {"json": HOLO_JSON_SCHEMA}
    return body


# --- datasets ---------------------------------------------------------------------------------------------------

def fetch(url: str, dest: Path) -> None:
    if dest.exists() and dest.stat().st_size > 0:
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=120) as response, open(tmp, "wb") as out:
                while chunk := response.read(1 << 20):
                    out.write(chunk)
            tmp.replace(dest)
            return
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            if attempt == 4:
                raise RuntimeError(f"{url}: {error}") from error
            time.sleep(2 ** attempt)


def prepare(data: Path) -> None:
    ssp = data / "screenspot-pro"
    with urllib.request.urlopen(f"{HF}/api/datasets/{SCREENSPOT_PRO}/tree/main/annotations", timeout=60) as r:
        files = [entry["path"] for entry in json.load(r) if entry["path"].endswith(".json")]
    images: set[str] = set()
    for path in files:
        fetch(f"{HF}/datasets/{SCREENSPOT_PRO}/resolve/main/{path}", ssp / path)
        images.update(row["img_filename"] for row in json.loads((ssp / path).read_text()))
    for i, name in enumerate(sorted(images)):
        fetch(f"{HF}/datasets/{SCREENSPOT_PRO}/resolve/main/images/{urllib.parse.quote(name)}", ssp / "images" / name)
        if i % 100 == 0:
            print(f"screenspot-pro images {i}/{len(images)}", file=sys.stderr)
    owg = data / "osworld-g"
    fetch(f"{HF}/datasets/{OSWORLD_G}/resolve/main/data/test-00000-of-00001.parquet", owg / "test.parquet")
    import pyarrow.parquet as pq  # only `prepare` needs pyarrow

    table = pq.read_table(owg / "test.parquet")
    rows = table.to_pylist()
    (owg / "images").mkdir(parents=True, exist_ok=True)
    annotations = []
    for row in rows:
        path = owg / "images" / row["image_path"]
        if not path.exists():
            path.write_bytes(row["image"]["bytes"])
        annotations.append({k: row[k] for k in ("id", "image_path", "image_size", "instruction", "box_type",
                                                 "box_coordinates", "GUI_types")})
    (owg / "annotations.json").write_text(json.dumps(annotations))
    print(f"prepared {data}: screenspot-pro {len(images)} images, osworld-g {len(rows)} samples", file=sys.stderr)


def load_samples(data: Path, bench: str) -> list[dict]:
    samples = []
    if bench == "screenspot-pro":
        root = data / "screenspot-pro"
        for path in sorted((root / "annotations").glob("*.json")):
            for row in json.loads(path.read_text()):
                samples.append({
                    "id": row["id"], "image": str(root / "images" / row["img_filename"]),
                    "instruction": row["instruction"],
                    "target": {"kind": "box", "box": row["bbox"]},
                    "groups": [row["group"], f"{row['group']}/{row['ui_type']}", f"ui/{row['ui_type']}"],
                    "canvas": row["group"] in CANVAS_GROUPS,
                })
    elif bench == "osworld-g":
        root = data / "osworld-g"
        for row in json.loads((root / "annotations.json").read_text()):
            coords = row["box_coordinates"]
            if row["box_type"] == "bbox":
                x, y, w, h = coords
                target = {"kind": "box", "box": [x, y, x + w, y + h]}
            elif len(coords) == 4:
                target = {"kind": "box", "box": coords}
            else:
                target = {"kind": "polygon", "points": list(zip(coords[0::2], coords[1::2]))}
            samples.append({
                "id": row["id"], "image": str(root / "images" / row["image_path"]),
                "instruction": row["instruction"], "target": target,
                "groups": list(row["GUI_types"]),
                "canvas": osworld_canvas(row["GUI_types"]),
            })
    else:
        raise ValueError(f"unknown benchmark {bench}")
    return samples


# --- running ----------------------------------------------------------------------------------------------------

def encode_image(path: str, model: dict, max_pixels: int | None) -> tuple[str, int, int, int, int]:
    """The image resized the way the model's processor would, as a PNG data URL, with sent and original sizes."""
    from PIL import Image

    with Image.open(path) as image:
        image = image.convert("RGB")
        width, height = image.size
        # Never above the server's own bound, or the server resizes again and absolute answers drift.
        bound = min(max_pixels, model["max_pixels"]) if max_pixels else model["max_pixels"]
        h, w = smart_resize(height, width, model["factor"], model["min_pixels"], bound)
        if (w, h) != (width, height):
            image = image.resize((w, h), Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        image.save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode(), w, h, width, height


def blank_image(width: int, height: int) -> str:
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", (width, height), (128, 128, 128)).save(buffer, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode()


def post(endpoint: str, body: dict, timeout: float) -> dict:
    request = urllib.request.Request(endpoint.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def served_models(endpoint: str) -> list[str]:
    with urllib.request.urlopen(endpoint.rstrip("/") + "/models", timeout=30) as response:
        return [entry["id"] for entry in json.load(response)["data"]]


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    k = (len(ordered) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def score(records: list[dict]) -> dict:
    def acc(rows: list[dict]) -> dict:
        n = len(rows)
        correct = sum(1 for r in rows if r["correct"])
        return {"n": n, "accuracy": round(correct / n, 4) if n else None}

    groups: dict[str, list[dict]] = {}
    for r in records:
        for g in r["groups"]:
            groups.setdefault(g, []).append(r)
    summary = acc(records)
    summary.update({
        "correct": sum(1 for r in records if r["correct"]),
        "parse_failures": sum(1 for r in records if r["point"] is None and r["error"] is None),
        "truncated": sum(1 for r in records if r.get("finish") == "length"),
        "errors": sum(1 for r in records if r["error"] is not None),
        "by_group": {g: acc(rows) for g, rows in sorted(groups.items())},
        "canvas": acc([r for r in records if r["canvas"]]),
    })
    return summary


def run(args: argparse.Namespace) -> int:
    models = {m["id"]: m for m in json.loads((HERE / "models.json").read_text())["models"]}
    if args.model not in models:
        print(f"unknown model {args.model}; one of {', '.join(models)}", file=sys.stderr)
        return 2
    model = models[args.model]
    listed = served_models(args.endpoint)
    served = args.served_name or listed[0]
    # vLLM lists exactly its --served-model-name; mlx-vlm may list other cached models, so only vLLM is held to it.
    if args.server == "vllm" and args.served_name and args.served_name not in listed:
        # Another server on this port: never measure the wrong model.
        print(f"{args.endpoint} serves {listed}, not {args.served_name}", file=sys.stderr)
        return 1
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    samples_path = out.with_suffix(".samples.jsonl")
    done: dict[str, dict] = {}
    if samples_path.exists() and args.resume:
        for line in samples_path.read_text().splitlines():
            record = json.loads(line)
            if record.get("error") is None:  # an error (a dead server) is asked again
                done[f"{record['bench']}:{record['id']}"] = record
    benchmarks: dict[str, dict] = {}
    latencies: list[float] = []
    peaks: list[float] = []
    warmed = False
    failed_in_a_row = 0
    with open(samples_path, "a" if args.resume else "w") as log:
        for bench in args.bench.split(","):
            samples = load_samples(Path(args.data), bench)
            if args.limit:
                # Every Nth sample, so a short run still covers every app and group.
                step = max(1, len(samples) // args.limit)
                samples = samples[::step][: args.limit]
            # A fixed shuffle, so one screenshot's questions are not asked back to back
            # (servers cache a repeated image's features, which a live screenshot never gets).
            random.Random(7146).shuffle(samples)
            records = []
            for i, sample in enumerate(samples):
                key = f"{bench}:{sample['id']}"
                if key in done:
                    records.append(done[key])
                    if done[key].get("latency_ms") is not None:
                        latencies.append(done[key]["latency_ms"])
                    if done[key].get("peak_gb"):
                        peaks.append(done[key]["peak_gb"])
                    continue
                url, w, h, width, height = encode_image(sample["image"], model, args.max_pixels)
                body = request_body(model, served, build_messages(model["family"], sample["instruction"], url, w, h),
                                    args.structured)
                if not warmed:
                    # One discarded request on a blank image of the same size: graph capture and kernel
                    # compiles stay out of the latency, and no measured image is in a server cache.
                    warm = request_body(model, served, build_messages(model["family"], sample["instruction"],
                                                                      blank_image(w, h), w, h), args.structured)
                    try:
                        post(args.endpoint, warm, args.timeout)
                    except (urllib.error.URLError, TimeoutError, ConnectionError, ValueError):
                        pass
                    warmed = True
                record = {"bench": bench, "id": sample["id"], "groups": sample["groups"], "canvas": sample["canvas"],
                          "sent": [w, h], "size": [width, height], "point": None, "correct": False,
                          "latency_ms": None, "peak_gb": None, "output": None, "finish": None, "error": None}
                started = time.perf_counter()
                try:
                    response = post(args.endpoint, body, args.timeout)
                    record["latency_ms"] = round((time.perf_counter() - started) * 1000, 1)
                    choice = response["choices"][0]
                    text = choice["message"].get("content") or ""
                    record["output"] = text[:400]
                    record["finish"] = choice.get("finish_reason")
                    timings = response.get("timings") or {}
                    peak = timings.get("peak_memory") or timings.get("peak_memory_gb")
                    if peak:
                        record["peak_gb"] = float(peak)
                        peaks.append(float(peak))
                    point = parse_point(model["family"], text, w, h)
                    if point is not None:
                        x, y = point[0] * width / w, point[1] * height / h
                        record["point"] = [round(x, 1), round(y, 1)]
                        record["correct"] = point_in_target(x, y, sample["target"])
                except (urllib.error.URLError, TimeoutError, ConnectionError, KeyError, IndexError, ValueError) as error:
                    record["error"] = str(error)[:300]
                if record["latency_ms"] is not None:
                    latencies.append(record["latency_ms"])
                log.write(json.dumps(record) + "\n")
                log.flush()
                records.append(record)
                failed_in_a_row = failed_in_a_row + 1 if record["error"] else 0
                if failed_in_a_row >= 10:
                    print(f"10 requests in a row failed (last: {record['error']}); stopping. "
                          "Rerun with --resume once the server is back.", file=sys.stderr)
                    out.unlink(missing_ok=True)  # never leave an earlier run's result to be summarized
                    return 1
                if i % 50 == 0:
                    right = sum(1 for r in records if r["correct"])
                    print(f"{bench} {i + 1}/{len(samples)} acc={right / len(records):.3f}", file=sys.stderr)
            benchmarks[bench] = score(records)
    gpu_peak = None
    if args.gpu_peak_file and Path(args.gpu_peak_file).exists():
        text = Path(args.gpu_peak_file).read_text().strip()
        gpu_peak = float(text) if text else None
    result = {
        "schema": SCHEMA,
        "run": {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "host": socket.gethostname(),
                "model": model["id"], "hf": model["hf"], "license": model["license"], "family": model["family"],
                "endpoint": args.endpoint, "server": args.server, "served_name": served,
                "max_pixels": args.max_pixels or model["max_pixels"], "limit": args.limit,
                "structured": bool(args.structured and model["family"] == "holo"),
                "rev": os.environ.get("GROUNDING_EVAL_REV")},
        "benchmarks": benchmarks,
        "latency_ms": {"p50": percentile(latencies, 0.5), "p95": percentile(latencies, 0.95),
                       "mean": round(statistics.fmean(latencies), 1) if latencies else None, "n": len(latencies)},
        "memory_gb": {"peak": max(peaks) if peaks else gpu_peak,
                      "source": "mlx-vlm timings" if peaks else ("nvidia-smi reservation" if gpu_peak else None)},
    }
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("latency_ms", "memory_gb")}))
    for bench, summary in benchmarks.items():
        print(f"GROUNDING-EVAL model={model['id']} bench={bench} acc={summary['accuracy']} "
              f"canvas={summary['canvas']['accuracy']} n={summary['n']} parse_failures={summary['parse_failures']} "
              f"truncated={summary['truncated']} errors={summary['errors']}")
    return 0


def summarize(paths: list[str]) -> str:
    rows = ["| Model | Licence | Server | ScreenSpot-Pro | SSP canvas | OSWorld-G | OSW-G canvas | n | Unparsed | Errors "
            "| p50 ms | p95 ms | Memory GB |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]

    def pct(value: float | None) -> str:
        return "-" if value is None else f"{value * 100:.1f}%"

    def num(value: float | None) -> str:
        return "-" if value is None else f"{value:.0f}" if value >= 10 else f"{value:.1f}"

    for path in paths:
        result = json.loads(Path(path).read_text())
        bench = result["benchmarks"]
        ssp, owg = bench.get("screenspot-pro", {}), bench.get("osworld-g", {})
        runs = [b for b in (ssp, owg) if b]
        server = result["run"].get("server") or "-"
        if result["run"].get("structured"):
            server += " (structured)"
        memory = num(result["memory_gb"]["peak"])
        if (result["memory_gb"].get("source") or "").endswith("reservation"):
            memory += " (reserved)"
        rows.append(" | ".join([
            f"| {result['run']['model']}", result["run"]["license"], server,
            pct(ssp.get("accuracy")), pct((ssp.get("canvas") or {}).get("accuracy")),
            pct(owg.get("accuracy")), pct((owg.get("canvas") or {}).get("accuracy")),
            str(sum(b["n"] for b in runs)), str(sum(b["parse_failures"] for b in runs)),
            str(sum(b["errors"] for b in runs)),
            num(result["latency_ms"]["p50"]), num(result["latency_ms"]["p95"]),
            memory + " |",
        ]))
    return "\n".join(rows)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--data", required=True)
    r = sub.add_parser("run")
    r.add_argument("--data", required=True)
    r.add_argument("--model", required=True)
    r.add_argument("--endpoint", required=True, help="OpenAI-compatible base URL, e.g. http://127.0.0.1:8000/v1")
    r.add_argument("--served-name", help="the server's model name (default: the first of /v1/models)")
    r.add_argument("--server", help="vllm or mlx, recorded in the result")
    r.add_argument("--bench", default="screenspot-pro,osworld-g")
    r.add_argument("--limit", type=int, default=0, help="at most N samples per benchmark, spread evenly")
    r.add_argument("--max-pixels", type=int, default=0, help="override the model's max_pixels")
    r.add_argument("--structured", action="store_true", help="vLLM structured outputs for Holo's JSON")
    r.add_argument("--timeout", type=float, default=300)
    r.add_argument("--resume", action="store_true", help="keep the samples already in OUT.samples.jsonl")
    r.add_argument("--gpu-peak-file", help="a file holding the GPU peak GiB serve-vllm.sh sampled")
    r.add_argument("--out", default="results.json")
    s = sub.add_parser("summarize")
    s.add_argument("results", nargs="+")
    args = parser.parse_args(argv)
    if args.command == "prepare":
        prepare(Path(args.data))
        return 0
    if args.command == "run":
        return run(args)
    print(summarize(args.results))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
