#!/usr/bin/env python3
"""CCmuxAppFFI in CmuxNext's Linux shape (CMUX_SWIFTPM_TARGET_LINUX=1).

The Apple shape links CCmuxAppFFI as the pinned xcframework that scripts/cmux-next/build-app-ffi.sh
builds. Linux has no xcframework, so the Linux shape declares a system library (CCmuxAppFFILinux,
Packages/macOS/CmuxNext/LinuxAppFFI) over the crates' own headers, and the library is the same
crate built here for the host: libcmux_app_ffi.a.

  modulemap  write LinuxAppFFI/module.modulemap (gitignored) from build-app-ffi.sh's headers_in:
             the module CCmuxAppFFI and one module per header with the xcframework's names, so
             Swift imports do not change.
  build      write the module map, build the static library for the host and print the
             directory that holds it (pass it to swift build as -Xlinker -L DIR). It fails when
             rustc names a native library the module map does not link.

Environment: CMUX_APP_FFI_LINUX_OUT (default Packages/macOS/CmuxNext/.build/app-ffi-linux, inside
the .build CI already caches), CARGO (default cargo on PATH, then ~/.cargo/bin/cargo, else rustup
installed under CMUX_APP_FFI_RUST_HOME, default OUT/rust). With no `cc` (the swift container), clang
compiles and links.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD_SCRIPT = ROOT / "scripts/cmux-next/build-app-ffi.sh"
PACKAGE = ROOT / "Packages/macOS/CmuxNext"
MODULEMAP = PACKAGE / "LinuxAppFFI/module.modulemap"
CRATE = ROOT / "cmux-tui/crates/cmux-app-ffi"
LIB = "cmux_app_ffi"
# The system libraries a Rust staticlib needs on glibc Linux (rustc --print native-static-libs);
# `build` refuses a library outside this list, so the module map's links stay complete.
NATIVE_LIBS = ("gcc_s", "util", "rt", "pthread", "m", "dl", "c")


def headers_in() -> list[tuple[str, str]]:
    """(header path relative to cmux-tui/crates, module) for every entry of headers_in."""
    text = BUILD_SCRIPT.read_text(encoding="utf-8")
    block = re.search(r"^headers_in=\((.*?)\)\s*$", text, re.S | re.M)
    if not block:
        raise SystemExit(f"{BUILD_SCRIPT.relative_to(ROOT)}: no headers_in=( ... ) array")
    entries = re.findall(r'"\$crates/([^":]+):([A-Za-z0-9_]+)"', block.group(1))
    if not entries:
        raise SystemExit(f"{BUILD_SCRIPT.relative_to(ROOT)}: headers_in names no \"$crates/HEADER:MODULE\" entry")
    return entries


def render() -> str:
    crates = os.path.relpath(ROOT / "cmux-tui/crates", MODULEMAP.parent)
    links = "".join(f'    link "{name}"\n' for name in (LIB, *NATIVE_LIBS))
    out = [
        "module CCmuxAppFFI {",
        links.rstrip("\n"),
        "}",
    ]
    for header, module in headers_in():
        out += [f"module {module} {{", f'    header "{crates}/{header}"', links.rstrip("\n"), "    export *", "}"]
    return "\n".join(out) + "\n"


def modulemap() -> int:
    want = render()
    if MODULEMAP.exists() and MODULEMAP.read_text(encoding="utf-8") == want:
        return 0
    MODULEMAP.parent.mkdir(parents=True, exist_ok=True)
    MODULEMAP.write_text(want, encoding="utf-8")
    print(f"wrote {MODULEMAP.relative_to(ROOT)}", file=sys.stderr)
    return 0


RUSTUP_INIT = "https://static.rust-lang.org/rustup/dist/{triple}/rustup-init"


def bootstrap_rustup(env: dict[str, str]) -> str:
    """Install rustup with no toolchain under CMUX_APP_FFI_RUST_HOME (the swift container ships no Rust
    and no curl); cargo then installs the toolchain cmux-tui/rust-toolchain.toml pins on its first run."""
    import hashlib
    import platform
    import urllib.request

    home = Path(env["CMUX_APP_FFI_RUST_HOME"])
    env["RUSTUP_HOME"] = str(home / "rustup")
    env["CARGO_HOME"] = str(home / "cargo")
    found = home / "cargo/bin/cargo"
    if found.exists():
        return str(found)
    triple = {"x86_64": "x86_64-unknown-linux-gnu", "aarch64": "aarch64-unknown-linux-gnu"}.get(platform.machine())
    if not triple:
        raise SystemExit(f"app_ffi_linux.py build: no cargo, and no rustup-init for {platform.machine()}")
    url = RUSTUP_INIT.format(triple=triple)
    print(f"app_ffi_linux.py build: no cargo; installing rustup from {url}", file=sys.stderr)
    data = urllib.request.urlopen(url, timeout=120).read()
    want = urllib.request.urlopen(url + ".sha256", timeout=60).read().decode().split()[0]
    if hashlib.sha256(data).hexdigest() != want:
        raise SystemExit(f"app_ffi_linux.py build: rustup-init sha256 differs from {url}.sha256")
    home.mkdir(parents=True, exist_ok=True)
    init = home / "rustup-init"
    init.write_bytes(data)
    init.chmod(0o755)
    subprocess.run(
        [str(init), "-y", "--no-modify-path", "--profile", "minimal", "--default-toolchain", "none"],
        env=env, check=True, stdout=sys.stderr,
    )
    return str(found)


def cargo(env: dict[str, str]) -> str:
    found = env.get("CARGO") or shutil.which("cargo", path=env.get("PATH"))
    if not found and (Path.home() / ".cargo/bin/cargo").exists():
        found = str(Path.home() / ".cargo/bin/cargo")
    return found or bootstrap_rustup(env)


def c_toolchain(env: dict[str, str]) -> None:
    """The swift container ships clang but no `cc`, which rustc links build scripts with and the cc crate
    compiles C with (ring, zstd-sys, libsqlite3-sys): use clang for both when `cc` is missing."""
    path = env.get("PATH")
    if shutil.which("cc", path=path) or not shutil.which("clang", path=path):
        return
    env.setdefault("CC", "clang")
    env.setdefault("CXX", "clang++")
    env.setdefault("AR", "ar")
    for triple in ("X86_64_UNKNOWN_LINUX_GNU", "AARCH64_UNKNOWN_LINUX_GNU"):
        env.setdefault(f"CARGO_TARGET_{triple}_LINKER", "clang")


def build() -> int:
    modulemap()
    out = Path(os.environ.get("CMUX_APP_FFI_LINUX_OUT") or PACKAGE / ".build/app-ffi-linux").resolve()
    env = dict(os.environ)
    # Rust lives beside the build output by default, so CI's .build cache keeps the toolchain too.
    env.setdefault("CMUX_APP_FFI_RUST_HOME", str(out / "rust"))
    env["CARGO_TARGET_DIR"] = str(out / "cargo")
    c_toolchain(env)
    # Tests need the C ABIs, not the shipped optimization: no LTO and parallel codegen
    # instead of the app's fat LTO with one codegen unit (minutes per build).
    env.setdefault("CARGO_PROFILE_RELEASE_LTO", "off")
    env.setdefault("CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "16")
    command = [cargo(env), "rustc", "--lib", "--locked", "--release", "--", "--print", "native-static-libs"]
    result = subprocess.run(command, cwd=CRATE, env=env, stdout=sys.stderr, stderr=subprocess.PIPE, text=True)
    sys.stderr.write(result.stderr)
    if result.returncode:
        print(f"app_ffi_linux.py build: cargo exited {result.returncode}", file=sys.stderr)
        return result.returncode
    notes = re.findall(r"^note: native-static-libs: (.*)$", result.stderr, re.M)
    if notes:
        named = [flag[2:] for flag in notes[-1].split() if flag.startswith("-l")]
        missing = sorted(set(named) - set(NATIVE_LIBS))
        if missing:
            print(
                f"app_ffi_linux.py build: rustc needs {', '.join(missing)}, which the module map does not link; "
                "add them to NATIVE_LIBS and run modulemap",
                file=sys.stderr,
            )
            return 1
    built = out / "cargo/release" / f"lib{LIB}.a"
    if not built.is_file():
        print(f"app_ffi_linux.py build: cargo left no {built}", file=sys.stderr)
        return 1
    lib_dir = out / "lib"
    lib_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(built, lib_dir / built.name)
    print(lib_dir)
    return 0


def main(argv: list[str]) -> int:
    if argv == ["modulemap"]:
        return modulemap()
    if argv == ["build"]:
        return build()
    print("usage: app_ffi_linux.py modulemap | build", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
