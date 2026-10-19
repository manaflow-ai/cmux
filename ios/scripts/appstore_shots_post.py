#!/usr/bin/env python3
"""Post-process fastlane snapshot captures into the exact App Store set.

Reads ios/fastlane/appstore-shots-plan.json, locates raw captures (as staged by
`appstore-shots.sh capture` under the work dir), applies each display type's
transform with ImageMagick, and stages `final/<DISPLAY_TYPE>/NN-<slug>.png` at
the exact ASC pixel sizes. `verify` re-checks the staged set against the plan.

Transforms:
  fit                  resize to the target size (captures from the matching
                       device class already share its aspect ratio)
  ipad_statusbar_crop  crop the top strip (status bar carries a scene-title
                       artifact on dev builds), center-crop back to the target
                       aspect, then resize
  framed               marketing composition: frame_assets background, bold
                       headline, rounded capture with a drop shadow
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FASTLANE = HERE.parent / "fastlane"
PLAN_PATH = FASTLANE / "appstore-shots-plan.json"
IPAD_STATUS_BAR_CROP = 64


def magick() -> str:
    for name in ("magick", "convert"):
        if shutil.which(name):
            return name
    sys.exit("ImageMagick not found (brew install imagemagick)")


def identify(path: Path) -> tuple[int, int]:
    # `identify` is its own binary on convert-only installs; `magick identify`
    # only exists on IMv7.
    cmd = ["identify"] if shutil.which("identify") else [magick(), "identify"]
    out = subprocess.check_output([*cmd, "-format", "%w %h", str(path)], text=True)
    w, h = out.split()
    return int(w), int(h)


def find_capture(
    captures_dir: Path,
    capture_class: str,
    source: str,
    locale: str,
    capture_source: str = "any",
) -> Path:
    """Locate `<Device Name>-<source>.png` for the device class (iphone/ipad),
    searching only the plan locale's directory when one exists so a
    multi-language capture cannot leak another locale into the staged set."""
    locale_dirs = [d for d in captures_dir.rglob(locale) if d.is_dir()]
    roots = locale_dirs or [captures_dir]
    hits = [
        p
        for root in roots
        for p in sorted(root.rglob(f"*-{source}.png"))
        if p.name.lower().startswith(capture_class)
    ]
    if capture_source == "real":
        # The real driver deliberately marks its files `Device Real-...` so a
        # real post cannot accidentally stage a same-named fixture capture.
        hits = [p for p in hits if " real-" in p.stem.lower()]
    elif capture_source == "fixture":
        hits = [p for p in hits if " real-" not in p.stem.lower()]
    if not hits:
        qualifier = f" ({capture_source} source)" if capture_source != "any" else ""
        capture_hint = (
            "run `appstore-shots.sh capture-real --udid <sim-udid>` first"
            if capture_source == "real"
            else "run `appstore-shots.sh capture` first"
        )
        sys.exit(
            f"missing capture for {capture_class}/{source}{qualifier} ({locale}) under {captures_dir} "
            f"({capture_hint})"
        )
    return hits[0]


def transform_fit(src: Path, dst: Path, size: tuple[int, int]) -> None:
    subprocess.run(
        [magick(), str(src), "-filter", "Lanczos", "-resize",
         f"{size[0]}x{size[1]}!", str(dst)],
        check=True,
    )


def transform_ipad_crop(src: Path, dst: Path, size: tuple[int, int]) -> None:
    w, h = identify(src)
    cropped_h = h - IPAD_STATUS_BAR_CROP
    target_w, target_h = size
    # Center-crop back to the target aspect after removing the status bar strip.
    aspect_w = min(w, int(cropped_h * target_w / target_h))
    subprocess.run(
        [magick(), str(src),
         "-crop", f"{w}x{cropped_h}+0+{IPAD_STATUS_BAR_CROP}", "+repage",
         "-gravity", "center", "-extent", f"{aspect_w}x{cropped_h}",
         "-filter", "Lanczos", "-resize", f"{target_w}x{target_h}!", str(dst)],
        check=True,
    )


def transform_framed(src: Path, dst: Path, size: tuple[int, int], headline: str) -> None:
    """Same composition family as frame_assets/compose_shots.py, at ASC size."""
    w, h = size
    bg = FASTLANE / "frame_assets" / "bg_portrait.jpg"
    if not bg.exists():
        sys.exit(f"missing background asset {bg}")
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        device_h = int(h * 0.74)
        src_w, src_h = identify(src)
        device_w = int(src_w * device_h / src_h)
        radius = int(device_h * 0.04)
        base = tmp_path / "base.png"
        screen = tmp_path / "screen.png"
        header = tmp_path / "header.png"
        subprocess.run(
            [magick(), str(bg), "-resize", f"{w}x{h}^", "-gravity", "center",
             "-extent", f"{w}x{h}", str(base)],
            check=True,
        )
        subprocess.run(
            [magick(), str(src), "-resize", f"{device_w}x{device_h}!",
             "(", "+clone", "-alpha", "transparent", "-background", "none",
             "-fill", "white",
             "-draw", f"roundrectangle 0,0,{device_w - 1},{device_h - 1},{radius},{radius}",
             ")", "-compose", "DstIn", "-composite", str(screen)],
            check=True,
        )
        subprocess.run(
            [magick(), "-background", "none", "-fill", "white",
             "-font", "Helvetica-Bold", "-pointsize", str(int(h * 0.033)),
             "-size", f"{int(w * 0.86)}x", "-gravity", "center",
             f"caption:{headline}", str(header)],
            check=True,
        )
        subprocess.run(
            [magick(), str(base),
             "(", str(screen), "-background", "black", "-shadow", "55x40+0+22", ")",
             "-gravity", "north",
             "-geometry", f"+0+{int(h * 0.155)}",
             "-compose", "over", "-composite",
             str(screen), "-gravity", "north",
             "-geometry", f"+0+{int(h * 0.16)}", "-composite",
             str(header), "-gravity", "north",
             "-geometry", f"+0+{int(h * 0.05)}", "-compose", "over", "-composite",
             str(dst)],
            check=True,
        )


def stage(plan: dict, work: Path, skip_lockshot: bool, capture_source: str) -> int:
    captures = work / "captures"
    final = work / "final"
    # Start from a clean tree so a rerun (or --skip-lockshot) can never leave a
    # stale file behind for verify/upload to accept.
    if final.exists():
        shutil.rmtree(final)
    locale = plan.get("locale", "en-US")
    failures = 0
    for display_type, spec in plan["display_types"].items():
        out_dir = final / display_type
        out_dir.mkdir(parents=True, exist_ok=True)
        size = tuple(spec["size"])
        for shot in spec["shots"]:
            dst = out_dir / f"{shot['position']:02d}-{shot['slug']}.png"
            source = shot["source"]
            if source.startswith("lockshot:"):
                lock_name = source.split(":", 1)[1]
                if capture_source == "real":
                    src = work / "lockshot" / f"{lock_name}-real.png"
                elif capture_source == "fixture":
                    src = work / "lockshot" / f"{lock_name}-fixture.png"
                else:
                    src = work / "lockshot" / f"{lock_name}.png"
                if not src.exists():
                    if skip_lockshot:
                        print(f"SKIP {display_type} #{shot['position']} ({source}): "
                              "lockshot capture missing", file=sys.stderr)
                        continue
                    source_hint = (
                        "run `appstore-shots.sh capture-real --udid <sim-udid>` first"
                        if capture_source == "real"
                        else "run `appstore-shots.sh lockshot` first"
                    )
                    print(f"MISSING {display_type} #{shot['position']}: {src} "
                          f"({source_hint}, or pass --skip-lockshot)",
                          file=sys.stderr)
                    failures += 1
                    continue
                transform_fit(src, dst, size)
            elif spec["transform"] == "fit":
                transform_fit(
                    find_capture(
                        captures, spec["capture_class"], source, locale, capture_source
                    ),
                    dst,
                    size,
                )
            elif spec["transform"] == "ipad_statusbar_crop":
                transform_ipad_crop(
                    find_capture(
                        captures, spec["capture_class"], source, locale, capture_source
                    ),
                    dst,
                    size,
                )
            elif spec["transform"] == "framed":
                transform_framed(
                    find_capture(
                        captures, spec["capture_class"], source, locale, capture_source
                    ),
                    dst, size, shot["headline"],
                )
            else:
                sys.exit(f"unknown transform {spec['transform']!r}")
            print(f"staged {dst.relative_to(work)}")
    return failures


def verify(plan: dict, work: Path) -> int:
    final = work / "final"
    failures = 0
    for display_type, spec in plan["display_types"].items():
        expected_size = tuple(spec["size"])
        shots = spec["shots"]
        if len(shots) > 10:
            print(f"FAIL {display_type}: {len(shots)} shots exceeds the ASC cap of 10")
            failures += 1
        for shot in shots:
            path = final / display_type / f"{shot['position']:02d}-{shot['slug']}.png"
            if not path.exists():
                print(f"FAIL {display_type}: missing {path.name}")
                failures += 1
                continue
            got = identify(path)
            status = "ok" if got == expected_size else "FAIL"
            if status == "FAIL":
                failures += 1
            print(f"{status:>4} {display_type}/{path.name} {got[0]}x{got[1]} "
                  f"(want {expected_size[0]}x{expected_size[1]})")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["stage", "verify"])
    parser.add_argument("--work", required=True, type=Path)
    parser.add_argument("--skip-lockshot", action="store_true",
                        help="stage without the lock-screen reply shot")
    parser.add_argument(
        "--capture-source",
        choices=("any", "real", "fixture"),
        default="any",
        help="choose real `Device Real-...` captures or preview fixtures",
    )
    args = parser.parse_args()

    plan = json.loads(PLAN_PATH.read_text())
    if args.command == "stage":
        failures = stage(plan, args.work, args.skip_lockshot, args.capture_source)
    else:
        failures = verify(plan, args.work)
    if failures:
        sys.exit(f"{failures} failure(s)")


if __name__ == "__main__":
    main()
