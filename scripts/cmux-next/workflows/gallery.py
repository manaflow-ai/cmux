"""Run one synthetic gallery play through the existing Playwright matrix runner.

The gallery owns captures and play assertions. This adapter adds no recorder, provider
connection or browser launcher: it selects one existing fixture and indexes its output.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import signal
import subprocess


def unavailable(reason: str, output: Path | None = None) -> dict:
    evidence = {}
    if output is not None:
        for key, name in (("report", "results.json"), ("index", "index.html"), ("log", "runner.log")):
            path = (output / name).resolve()
            if path.is_relative_to(output.resolve()) and path.is_file():
                evidence[key] = str(path.relative_to(output.parent.resolve()))
    return {"status": "unavailable", "state": {}, "assertions": [], "evidence": evidence,
            "metrics": {}, "event_refs": [], "reason": reason}


def normalize(result: dict, step: dict, context: dict, output: Path, exit_code: int) -> dict:
    """Use observed play outcomes; an image or an empty play is never a passing workflow."""
    play = result.get("play")
    if not isinstance(play, dict) or not isinstance(play.get("steps"), list) or not play["steps"]:
        return unavailable("gallery produced no executed play steps", output)
    observed = play["steps"]
    if any(not isinstance(row, dict) or row.get("status") not in ("pass", "warn", "fail") for row in observed):
        return unavailable("gallery produced an invalid play report", output)
    evidence = result.get("workflowEvidence")
    if not isinstance(evidence, dict) or not isinstance(evidence.get("final"), dict):
        return unavailable("gallery workflow evidence is missing", output)
    final = evidence["final"]
    def digest(value):
        if (not isinstance(value, dict)
                or not re.fullmatch(r"[a-f0-9]{64}", str(value.get("sha256", "")))
                or type(value.get("count")) is not int or value["count"] < 0):
            raise ValueError("invalid gallery accessibility digest")
        return {"sha256": value["sha256"], "count": value["count"]}

    def artifact(name: str) -> str:
        # Results come from the renderer; do not let a corrupt result link out of its bundle.
        path = (output / name).resolve()
        if not path.is_relative_to(output.resolve()) or not path.is_file():
            raise ValueError("gallery artifact missing or outside output directory")
        return str(path.relative_to(output.parent.resolve()))

    try:
        captures = {"final": {"screenshot": artifact(final["screenshot"]), "ax_digest": digest(final.get("axDigest"))}}
        captures.update(report=artifact("results.json"), index=artifact("index.html"))
        for phase in ("beforeSteps", "afterSteps"):
            items = evidence.get(phase)
            if not isinstance(items, list) or len(items) != len(observed):
                raise ValueError("missing per-step gallery captures")
            captures[phase] = []
            for index, item in enumerate(items):
                if not isinstance(item, dict) or type(item.get("index")) is not int or item["index"] != index:
                    raise ValueError("gallery capture belongs to another step")
                captures[phase].append({"index": index, "screenshot": artifact(item["screenshot"]),
                                        "ax_digest": digest(item.get("axDigest"))})
    except (KeyError, TypeError, ValueError):
        return unavailable("gallery capture evidence is incomplete", output)
    revision = result.get("revision") or {}
    assertions = [
        {"name": "gallery ready", "ok": result.get("ready") == "1"},
        {"name": "pinned source", "ok": revision.get("sha") == context["source_sha"]},
        {"name": "selected fixture", "ok": all(revision.get(key) == step["target"][key]
                                                  for key in ("entry", "variant"))},
        {"name": "play completed", "ok": play.get("status") in ("pass", "warn")},
        {"name": "runner completed", "ok": exit_code == 0},
    ]
    rows = []
    for index, row in enumerate(observed):
        assertions.append({"name": f"play step {index + 1}", "ok": row["status"] != "fail"})
        rows.append({"index": index, "action": row.get("action"), "status": row["status"],
                     "ax_sha256": captures["afterSteps"][index]["ax_digest"]["sha256"]})
    return {
        "status": "passed" if all(check["ok"] for check in assertions) else "failed",
        "state": {"entry": revision.get("entry"), "variant": revision.get("variant"),
                  "ready": result.get("ready"), "play_status": play.get("status"), "steps": rows,
                  "ax_sha256": captures["final"]["ax_digest"]["sha256"]},
        "assertions": assertions,
        "evidence": captures,
        "metrics": {"ready_ms": result.get("readyMs"), "timing_includes_evidence_capture": False,
                    "steps": [{key: row.get(key) for key in ("settleMs", "layoutShift", "longFrames", "frameSource")}
                              for row in observed]},
        "event_refs": [{"format": "gallery-play", "path": artifact("results.json"),
                        "case": result.get("id"), "step": index} for index in range(len(observed))],
        "first_failed_step": next((index for index, row in enumerate(observed) if row["status"] == "fail"), None),
    }


def run_step(step: dict, context: dict, out: Path) -> dict:
    if step.get("action") != "gallery.play":
        return unavailable("unsupported gallery action")
    # This preserves the matrix's fleet-only admission; never silently turn it on here.
    if os.environ.get("CMUX_GALLERY_IN_VM") != "1":
        return unavailable("gallery plays run on a fleet/CI worker with CMUX_GALLERY_IN_VM=1")
    target = step.get("target") or {}
    if set(target) != {"entry", "variant"} or any(not isinstance(v, str) or not v for v in target.values()):
        return unavailable("gallery target requires entry and variant")
    if step.get("args"):
        return unavailable("gallery.play takes no arguments; inputs belong to the synthetic fixture")
    if step.get("expect") != {"play": "passed"}:
        return unavailable("gallery.play requires expect: {play: passed}")
    gallery = Path(context.get("gallery_dir", "")).resolve()
    if not (gallery / "frame.html").is_file():
        return unavailable("gallery_dir must contain the pinned gallery build's frame.html")
    engine = context.get("engine", "chromium")
    if engine not in ("chromium", "webkit"):
        return unavailable("unsupported gallery engine")
    environment = context["environment"]
    # The existing matrix captures at 2x; its `scale` query parameter is UI zoom, not DPR.
    if environment["scale"] != 2:
        return unavailable("gallery matrix captures require environment.scale = 2")
    params = {**target, "frame": "component", **environment["viewport"],
              "locale": environment["locale"], "colorScheme": environment["theme"],
              "theme": "Apple System Colors Light" if environment["theme"] == "light" else "Apple System Colors",
              "density": environment.get("density", "comfortable"),
              "scale": 1,
              "reducedMotion": environment["reducedMotion"]}
    out.mkdir(parents=True, exist_ok=True)
    output = out / "gallery"
    # Refuse reuse so a failed invocation cannot pick up a prior passing result.
    output.mkdir()
    manifest = output / "matrix.json"
    manifest.write_text(json.dumps([{"id": step["id"], "path_or_url": "frame.html", "params": params}]) + "\n")
    repo = Path(__file__).resolve().parents[3]
    command = ["bun", str(repo / "scripts/gallery-matrix/runner.ts"), "--manifest", str(manifest.resolve()),
               "--gallery-dir", str(gallery), "--output-dir", str(output.resolve()), "--engines", engine]
    try:
        with (output / "runner.log").open("wb") as log:
            with subprocess.Popen(command, cwd=repo, env={**os.environ, "CMUX_GALLERY_WORKFLOW_EVIDENCE": "1"},
                                  stdout=log, stderr=subprocess.STDOUT, start_new_session=True) as run:
                try:
                    run.wait(timeout=150)
                except subprocess.TimeoutExpired:
                    # The group belongs to this invocation, including its Playwright children.
                    os.killpg(run.pid, signal.SIGTERM)
                    try:
                        run.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(run.pid, signal.SIGKILL)
                        run.wait()
                    raise
        results = json.loads((output / "results.json").read_text())
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return unavailable("gallery runner did not produce a report; inspect gallery/runner.log", output)
    if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict) or results[0].get("id") != step["id"]:
        return unavailable("gallery runner returned the wrong case", output)
    return normalize(results[0], step, context, output, run.returncode)
