#!/usr/bin/env python3
"""The arena's guest-side setup (README.md), run by cu-driver-eval.sh arena=run in the bench VM's
login session: builds the arena's own apps, assembles every engine the way its PR or release runs
it, and writes WORK/arms.json (what arena.py launches per arm) and WORK/grant.txt (each executable
that needs Accessibility, event posting and screen capture, one per line).

  prepare.py --work WORK --engines ENGINES --arms a,b [--driver LABEL=BINARY]... [--skills DIR]

ENGINES is build-engines.sh's output, copied into the guest. Arms: cmux-cua, cua-driver-0.38.0,
cu-fast, cu-rewrite, chief-desktop. Each --driver is one cu-driver-eval.sh fetched (cmux-cua-X.Y.Z,
cua-driver-0.38.0); --skills is where the Cua Driver release's skills were unpacked. An arm that
cannot be assembled is written with "unavailable" and the reason, and the run goes on without it.

Python 3.9 standard library only (the VM's Command Line Tools Python).
"""

import argparse
import json
import os
import plistlib
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE.parent))

ARENA_PLIST = {
    "CFBundleName": "Arena", "CFBundleDisplayName": "Arena", "CFBundleIdentifier": "com.cmux.arena",
    "CFBundleExecutable": "Arena", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1", "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True,
}
# scripts/cmux-next/build-cu-engine.sh at cmux#36993's head.
CU_ENGINE_PLIST = {
    "CFBundleName": "cmux CU Engine", "CFBundleDisplayName": "cmux CU Engine",
    "CFBundleIdentifier": "com.cmuxterm.cu.engine.dev", "CFBundleExecutable": "cmux-cu-service",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1", "CFBundleVersion": "0.1",
    "LSMinimumSystemVersion": "14.0", "LSUIElement": True, "LSBackgroundOnly": True,
    "NSAccessibilityUsageDescription": "cmux Computer Use reads and operates the apps an agent is asked to use.",
    "NSScreenCaptureUsageDescription": "cmux Computer Use takes screenshots of the windows an agent is asked to use.",
}


def run(*argv, check=True):
    done = subprocess.run([str(a) for a in argv], capture_output=True, text=True)
    if check and done.returncode != 0:
        raise RuntimeError(f"{Path(str(argv[0])).name} exited {done.returncode}: {(done.stderr or done.stdout).strip()[:300]}")
    return done


def sign(path, deep=False):
    run("codesign", "--force", *(["--deep"] if deep else []), "--sign", "-", path)


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


class Unavailable(Exception):
    pass


def build_apps(work, grants):
    app = work / "Arena.app"
    shutil.rmtree(app, ignore_errors=True)
    (app / "Contents" / "MacOS").mkdir(parents=True)
    (work / "bin").mkdir(exist_ok=True)
    builds = [("arena_app", app / "Contents" / "MacOS" / "Arena")]
    builds += [(name, work / "bin" / name.replace("_", "-")) for name in ("arena_probe", "arena_desktop")]
    # Every file is compiled before any failure is raised, so one run reports every compile error.
    errors = []
    for name, out in builds:
        done = run("swiftc", "-O", "-o", out, HERE / f"{name}.swift", check=False)
        if done.returncode != 0:
            errors.append(f"{name}.swift: " + "\n".join(
                line for line in (done.stderr or done.stdout).splitlines() if "error:" in line)[:2000])
    if errors:
        raise RuntimeError("swiftc failed:\n" + "\n".join(errors))
    with open(app / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump(ARENA_PLIST, f)
    sign(app)
    grants.extend(str(out) for _, out in builds[1:])


def arm_cmux_cua(work, drivers, grants, **_):
    import input_ab  # the A/B's own copy of how cmux starts the helper
    binary = next((b for label, b in drivers.items() if label.startswith("cmux-cua")), None)
    if not binary or not os.access(binary, os.X_OK):
        raise Unavailable("cu-driver-eval.sh fetched no cmux-cua")
    grants.append(binary)
    state = work / "cmux-cua"
    state.mkdir(exist_ok=True)
    state.chmod(0o700)  # its serve refuses a runtime directory others can read ("unsafe permissions")
    sock, token = str(state / "cua.sock"), secrets.token_hex(16)
    # Its daemon with ComputerUseHelperDaemon's environment, its MCP server with agent_tools.rs's.
    return {
        "daemon": {"argv": input_ab.serve_argv(binary, sock), "ready_socket": sock,
                   "env": {"CMUX_CUA_EXTERNAL_PERMISSION_FLOW": "1", "CMUX_CUA_PERMISSIONS_GATE": "0",
                           "CMUX_CUA_RESPONSIBILITY_DISCLAIMED": "1", "CMUX_CUA_TELEMETRY_ENABLED": "false",
                           "CMUX_CUA_UPDATE_CHECK": "false", "CMUX_CUA_CURSOR_LABEL": "cmux", "CMUX_CUA_STATE_DIR": str(state),
                           "CMUX_CUA_SOCKET_AUTH_TOKEN": token, "CMUX_CUA_SOCKET_HOST_AUTH_TOKEN": secrets.token_hex(16)}},
        "mcp": {"command": binary, "args": ["mcp", "--socket", sock],
                "env": {"CMUX_CUA_MCP_FORCE_PROXY": "1", "CMUX_CUA_TELEMETRY_ENABLED": "false", "CMUX_CUA_UPDATE_CHECK": "false",
                        "CMUX_CUA_CURSOR_GRADIENT": "#12c7f5,#2d8cff,#6c5cff", "CMUX_CUA_CURSOR_BLOOM": "#2d8cff",
                        "CMUX_CUA_CURSOR_LABEL": "cmux", "CMUX_CUA_SOCKET_AUTH_TOKEN": token}},
        "procs": ["cmux-cua"], "skill": str(ROOT / "skills" / "cmux-cua" / "SKILL.md"),
        "version": Path(binary).parents[2].name,
        "about": "feat-cmux-next's shipped Computer Use: the cmux-cua helper at cmux's pin, with cmux's cmux-cua skill",
    }


def arm_cua_driver(name, drivers, grants, skills, **_):
    binary = drivers.get(name)
    if not binary or not os.access(binary, os.X_OK):
        raise Unavailable(f"cu-driver-eval.sh fetched no {name}")
    grants.append(binary)
    skill = None
    if skills and Path(skills).is_dir():
        found = sorted(Path(skills).rglob("SKILL.md"), key=lambda p: (len(p.parts), str(p)))
        skill = str(found[0]) if found else None
    return {"mcp": {"command": binary, "args": ["mcp", "--direct"], "env": {}}, "procs": ["cua-driver"], "skill": skill,
            "about": f"upstream Cua Driver {name.removeprefix('cua-driver-')} release, mcp --direct, its own skill"}


def arm_cu_fast(work, engines, grants, **_):
    built = engines / "cu-fast"
    if (built / "unavailable").exists():
        raise Unavailable(read(built / "unavailable"))
    if not (built / "cmux-cu-service").is_file():
        raise Unavailable("no cmux-cu-service was built")
    # Signed here, ad hoc: the engine's socket admits only a client that passes the app's own designated
    # requirement, and the `mcp` pump is that same signed executable.
    app = work / "cu-fast" / "cmux CU Engine.app"
    shutil.rmtree(app, ignore_errors=True)
    (app / "Contents" / "MacOS").mkdir(parents=True)
    shutil.copy2(built / "cmux-cu-service", app / "Contents" / "MacOS" / "cmux-cu-service")
    with open(app / "Contents" / "Info.plist", "wb") as f:
        plistlib.dump(CU_ENGINE_PLIST, f)
    sign(app)
    grants.append(str(app / "Contents" / "MacOS" / "cmux-cu-service"))
    return {"mcp": {"command": str(app / "Contents" / "MacOS" / "cmux-cu-service"), "args": ["mcp", "--app", str(app)], "env": {}},
            "procs": ["cmux-cu-service"], "skill": None, "sha": read(built / "sha"),
            "about": "cmux#36993 standalone engine (cmux CU Engine.app over its socket), built at the PR head"}


def arm_cu_rewrite(work, engines, grants, **_):
    built = engines / "cu-rewrite"
    if (built / "unavailable").exists():
        raise Unavailable(read(built / "unavailable"))
    if not (built / "cmux-remote.zip").is_file() or not (built / "acpmux").is_file():
        raise Unavailable("no cmux Remote or acpmux was built")
    dest = work / "cu-rewrite"
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    run("ditto", "-x", "-k", built / "cmux-remote.zip", dest)
    apps = sorted(dest.glob("*.app"))
    if not apps:
        raise Unavailable("the cmux Remote zip holds no app")
    app = apps[0]
    if run("codesign", "-v", app, check=False).returncode != 0:
        sign(app, deep=True)
    acpmux = dest / "acpmux"
    shutil.copy2(built / "acpmux", acpmux)
    acpmux.chmod(0o755)
    sign(acpmux)
    grants += [str(app / "Contents" / "MacOS" / "cmux-remote"), str(acpmux)]
    state = dest / "state"
    sock = str(state / "daemon.sock")
    skill = built / "SKILL.md"
    return {"daemon": {"argv": ["/usr/bin/python3", "-I", str(HERE / "cu_rewrite_host.py"), "--remote", str(app),
                                "--socket", sock, "--state", str(state)], "ready_socket": sock, "env": {}},
            "mcp": {"command": str(acpmux), "args": ["computer-use-mcp"],
                    "env": {"CMUX_TUI_SOCKET": sock, "ACPMUX_COMPUTER_USE_LABEL": "the arena"}},
            "procs": ["cmux-remote"], "skill": str(skill) if skill.is_file() else None, "sha": read(built / "sha"),
            "about": "cmux#37003 Rust engine in its cmux Remote worker, through acpmux computer-use-mcp, built at the PR head"}


def arm_chief_desktop(work, engines, **_):
    built = engines / "chief-desktop"
    if (built / "unavailable").exists():
        raise Unavailable(read(built / "unavailable"))
    skill = None
    text = read(built / "SKILL.md")
    if text:
        # The PR's own guidance, with the tool named as this server names it.
        text = text.replace("cloud_computer_control", "(no control tool here)").replace("cloud_computer", "computer")
        (work / "skills").mkdir(exist_ok=True)
        skill = work / "skills" / "chief-desktop.md"
        skill.write_text(text + "\n")
    return {"mcp": {"command": "/usr/bin/python3", "args": ["-I", str(HERE / "chief_computer_mcp.py"), "--desktop",
                                                            str(work / "bin" / "arena-desktop")], "env": {}},
            "mcp_procs": ["Python", "python3", "arena-desktop"], "procs": [], "skill": str(skill) if skill else None,
            "sha": read(built / "sha"),
            "about": "cmux#36515 cloud_computer surface (pixels only: a screenshot op, desktop-wide input), emulated on this Mac"}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--engines", type=Path, required=True)
    p.add_argument("--arms", required=True)
    p.add_argument("--driver", action="append", default=[])
    p.add_argument("--skills", default="")
    a = p.parse_args()
    work = a.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    drivers = dict(d.split("=", 1) for d in a.driver)
    grants = [c for c in ("/opt/homebrew/bin/claude", "/opt/homebrew/bin/codex") if os.access(c, os.X_OK)]
    print("ARENA-PREPARE apps", flush=True)
    build_apps(work, grants)
    arms = {}
    for name in [n for n in a.arms.split(",") if n]:
        print(f"ARENA-PREPARE {name}", flush=True)
        ctx = dict(work=work, engines=a.engines, drivers=drivers, grants=grants, skills=a.skills)
        try:
            if name == "cmux-cua":
                arms[name] = arm_cmux_cua(**ctx)
            elif name.startswith("cua-driver-"):
                arms[name] = arm_cua_driver(name, **ctx)
            elif name == "cu-fast":
                arms[name] = arm_cu_fast(**ctx)
            elif name == "cu-rewrite":
                arms[name] = arm_cu_rewrite(**ctx)
            elif name == "chief-desktop":
                arms[name] = arm_chief_desktop(**ctx)
            else:
                raise Unavailable(f"no arm named {name}")
        except (Unavailable, RuntimeError, OSError) as why:
            arms[name] = {"unavailable": str(why)[:300]}
            print(f"ARENA-PREPARE {name}: unavailable: {why}", flush=True)
    (work / "arms.json").write_text(json.dumps(arms, indent=2) + "\n")
    (work / "grant.txt").write_text("".join(g + "\n" for g in grants))
    print("ARENA-PREPARE arms: " + ", ".join(f"{k}{' (unavailable)' if v.get('unavailable') else ''}" for k, v in arms.items()), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
