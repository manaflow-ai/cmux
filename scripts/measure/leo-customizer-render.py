#!/usr/bin/env python3
"""leo-customizer-render.py --app APP --pid-file F --control-socket S --folder DIR --out DIR

Renders an extension folder (leo-workspace apps/leo-customizer, copied beside this script) in a running
side-instance copy of a cmux NEXT NIGHTLY: `cmux ext dev DIR --once --json`, then `cmux ext shot DIR --json
--out shot.png`. Keeps both answers in OUT. The side-instance plumbing is ext-rows-nightly.py's.
"""
import argparse
import importlib.util
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--pid-file", required=True)
    p.add_argument("--control-socket")
    p.add_argument("--folder", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    rows = load("ext_rows_nightly", ROOT / "scripts/measure/ext-rows-nightly.py")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    app = Path(a.app)
    cli = (app / rows.reload_nightly.hot.BIN / "cmux").resolve()
    control, daemon = rows.attach_copy(app, cli, Path(a.pid_file), a.control_socket)
    globals_ = ["--socket", daemon, "--app-socket", control]
    folder = out / "leo-customizer"
    shutil.copytree(a.folder, folder, dirs_exist_ok=True)
    receipt = {"app": str(app), "app_commit": rows.reload_nightly.hot.app_commit(app),
               "daemon_socket": daemon, "control_socket": control}
    receipt["dev"] = rows.cli_json(cli, globals_, ["ext", "dev", str(folder), "--once", "--json"], timeout=300)
    (out / "dev.json").write_text(json.dumps(receipt["dev"], indent=2))
    png = out / "shot.png"
    receipt["shot"] = rows.cli_json(cli, globals_, ["ext", "shot", str(folder), "--json", "--out", str(png)],
                                    timeout=300)
    (out / "shot.json").write_text(json.dumps(receipt["shot"], indent=2))
    receipt["scene"] = rows.scene_of(receipt["shot"].get("json") or {}) or rows.scene_of(
        receipt["dev"].get("json") or {})
    receipt["png"] = png.exists()
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2))
    print("LEO_CUSTOMIZER_RENDER " + json.dumps(receipt), flush=True)
    return 0 if png.exists() else 1


if __name__ == "__main__":
    sys.exit(main())
