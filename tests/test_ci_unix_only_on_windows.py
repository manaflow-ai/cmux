#!/usr/bin/env python3
"""scripts/ci/unix_only_on_windows.py names the unix-only uses cargo check --target x86_64-pc-windows-gnu
refuses (the 46 errors of job 139597585051, by kind) and stays quiet on the same code behind cfg(unix)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("uow", ROOT / "scripts/ci/unix_only_on_windows.py")
uow = importlib.util.module_from_spec(SPEC)
sys.modules["uow"] = uow  # dataclasses look the module up while the class is built
SPEC.loader.exec_module(uow)

WORKSPACE = """
[workspace]
members = ["crates/*"]
[workspace.dependencies]
unixonly = { path = "crates/unixonly" }
gated = { path = "crates/gated" }
"""

APP_MANIFEST = """
[package]
name = "app"
version = "0.1.0"
[features]
default = []
extra = ["dep:optdep"]
[dependencies]
libc = "0.2"
unixonly.workspace = true
gated.workspace = true
optdep = { version = "1", optional = true }
[target.'cfg(unix)'.dependencies]
felt = { path = "../felt" }
"""

FILES = {
    "Cargo.toml": WORKSPACE,
    "crates/app/Cargo.toml": APP_MANIFEST,
    # A crate whose root is `#![cfg(unix)]`: empty on Windows (cmux-cloud-api).
    "crates/unixonly/Cargo.toml": '[package]\nname = "unixonly"\nversion = "0.1.0"\n',
    "crates/unixonly/src/lib.rs": "//! Unix only.\n#![cfg(unix)]\npub mod sessions {}\n",
    # A crate with a linux-only item, a fallback arm for another, and a feature-gated module.
    "crates/gated/Cargo.toml": '[package]\nname = "gated"\nversion = "0.1.0"\n[features]\nhttp = []\n',
    "crates/gated/src/lib.rs": textwrap.dedent("""
        #[cfg(target_os = "linux")]
        pub fn linux_only() {}
        #[cfg(unix)]
        pub fn this_device() {}
        #[cfg(not(unix))]
        pub fn this_device() {}
        #[cfg(feature = "http")]
        pub mod backend;
        pub fn everywhere() {}
    """),
    "crates/felt/Cargo.toml": '[package]\nname = "felt"\nversion = "0.1.0"\n',
    "crates/felt/src/lib.rs": "pub fn f() {}\n",
}


def scan(lib: str, extra: dict[str, str] | None = None) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        files = dict(FILES)
        files["crates/app/src/lib.rs"] = textwrap.dedent(lib)
        files.update(extra or {})
        for rel, text in files.items():
            path = Path(tmp, rel)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            rc = uow.main(["--root", tmp, "--crate", "crates/app"])
        lines = out.getvalue().splitlines()
        assert (rc == 1) == bool(lines), (rc, lines)
        return [ln.split(": ", 1)[1] for ln in lines]


class Finds(unittest.TestCase):
    def test_std_os_unix_and_fd(self):
        self.assertEqual(
            scan("use std::os::unix::fs::PermissionsExt;\nuse std::os::fd::AsRawFd;\nuse std::os::{unix::net, raw};\n"),
            ["`std::os::unix` is unix-only", "`std::os::fd` is unix-only", "`std::os::unix` is unix-only"],
        )

    def test_unix_sockets_by_net_path(self):
        found = scan("""
            async fn f() { tokio::net::UnixStream::connect("x").await.ok(); }
            use tokio::net::{TcpStream, UnixListener};
            // A crate's own Windows stand-in named UnixStream is not std's or tokio's.
            fn g(_: crate::router_socket::UnixStream) {}
        """)
        self.assertEqual(found, ["`net::UnixStream` is unix-only", "`net::UnixListener` is unix-only"])

    def test_libc_items_windows_lacks(self):
        found = scan("""
            fn a() -> libc::c_int { 0 }
            fn b(pid: libc::pid_t) { unsafe { libc::kill(pid, libc::SIGKILL); } }
            use libc::{c_void, winsize};
        """)
        self.assertEqual(found, [
            # One line's findings sort by text.
            "`libc::SIGKILL` is not in libc for windows-gnu",
            "`libc::kill` is not in libc for windows-gnu",
            "`libc::pid_t` is not in libc for windows-gnu",
            "`libc::winsize` is not in libc for windows-gnu",
        ])

    def test_dependencies_windows_does_not_get(self):
        found = scan("""
            use unixonly::sessions;
            fn f() { felt::f(); optdep::go(); }
            fn g() { gated::linux_only(); gated::backend::x(); gated::this_device(); gated::everywhere(); }
        """)
        self.assertEqual(len(found), 5, found)
        self.assertIn("crate `unixonly` is not built for Windows", found[0])
        self.assertIn("crate `felt` is not built for Windows (listed only under [target.'cfg(unix)'.dependencies])", found[1])
        self.assertIn("crate `optdep` is not built for Windows (an optional dependency", found[2])
        # this_device has a live arm and everywhere has no cfg: only these two are off.
        self.assertTrue(found[3].startswith("`gated::backend` is off on Windows (crates/gated/src/lib.rs:"), found[3])
        self.assertTrue(found[4].startswith("`gated::linux_only` is off on Windows"), found[4])

    def test_test_code_counts(self):
        # The Windows check runs `-p acpmux --all-targets`: cfg(test) modules and tests/ compile too.
        found = scan(
            "#[cfg(test)]\nmod tests;\n",
            {
                "crates/app/src/tests.rs": "use std::os::unix::fs::MetadataExt;\n",
                "crates/app/tests/it.rs": "fn f() { unsafe { libc::getuid(); } }\n",
            },
        )
        self.assertEqual(found, ["`std::os::unix` is unix-only", "`libc::getuid` is not in libc for windows-gnu"])

    def test_bench_without_main_on_windows(self):
        # turn_overhead at 037a5240: a `#![cfg(unix)]` harness = false bench has no main (E0601).
        found = scan("", {
            "crates/app/Cargo.toml": APP_MANIFEST + '[[bench]]\nname = "turn"\nharness = false\n',
            "crates/app/benches/turn.rs": "#![cfg(unix)]\nfn main() {}\n",
            "crates/app/benches/fine.rs": "#![cfg(unix)]\n#[test]\nfn t() {}\n",
            # The fix turn_overhead took: no main is needed where the file is empty.
            "crates/app/examples/no_main.rs": "#![cfg_attr(not(unix), no_main)]\n#![cfg(unix)]\nfn main() {}\n",
            "crates/app/examples/ok.rs": "#[cfg(unix)]\nfn main() {}\n#[cfg(not(unix))]\nfn main() {}\n",
        })
        self.assertEqual(len(found), 1, found)
        self.assertTrue(found[0].startswith("no `main` on Windows"), found)

    def test_cfg_bang_does_not_hide_code(self):
        self.assertEqual(scan("fn f() { if cfg!(unix) { let _ = libc::getuid(); } }\n"),
                         ["`libc::getuid` is not in libc for windows-gnu"])

    def test_github_annotations(self):
        with tempfile.TemporaryDirectory() as tmp:
            for rel, text in {**FILES, "crates/app/src/lib.rs": "use std::os::fd::RawFd;\n"}.items():
                Path(tmp, rel).parent.mkdir(parents=True, exist_ok=True)
                Path(tmp, rel).write_text(text)
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(uow.main(["--root", tmp, "--crate", "crates/app", "--github"]), 1)
            self.assertTrue(out.getvalue().startswith("::error file=crates/app/src/lib.rs,line=1,"), out.getvalue())


class Quiet(unittest.TestCase):
    def test_items_behind_cfg_unix(self):
        self.assertEqual(scan("""
            #[cfg(unix)]
            use std::os::unix::fs::PermissionsExt;
            #[cfg(unix)]
            fn kill(pid: libc::pid_t) {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
            #[cfg(not(windows))]
            impl Foo {
                fn f() { felt::f(); }
            }
            #[cfg(all(unix, not(target_os = "macos")))]
            struct S { fd: std::os::fd::OwnedFd }
            fn g() {
                #[cfg(unix)]
                let _p = std::os::unix::fs::PermissionsExt::from_mode(0o700);
                #[cfg(unix)]
                {
                    let _ = tokio::net::UnixStream::connect("x");
                }
                let _v = vec![
                    #[cfg(unix)]
                    libc::SIGTERM,
                    0,
                ];
                match 1 {
                    #[cfg(unix)]
                    1 => { unixonly::sessions::x(); }
                    _ => {}
                }
                gated::this_device();
            }
            struct T {
                #[cfg(unix)]
                fd: std::os::fd::RawFd,
                n: u8,
            }
            #[cfg(feature = "extra")]
            fn h() { optdep::go(); }
        """), [])

    def test_module_files_behind_cfg_unix(self):
        self.assertEqual(scan(
            """
            #[cfg(unix)]
            mod pty;
            #[cfg(all(test, unix))]
            mod unix_tests;
            #[cfg(test)]
            #[cfg(target_os = "linux")]
            #[path = "linux_tests.rs"]
            mod linux_only_tests;
            mod outer {
                #[cfg(unix)]
                pub mod inner;
            }
            mod inner_file;
            """,
            {
                "crates/app/src/pty.rs": "use std::os::fd::OwnedFd;\nfn f() { unsafe { libc::openpty(); } }\n",
                "crates/app/src/unix_tests.rs": "use std::os::unix::fs::MetadataExt;\n",
                "crates/app/src/linux_tests.rs": "fn f() { unsafe { libc::getrusage(); } }\n",
                "crates/app/src/outer/inner.rs": "use std::os::unix::net::UnixStream;\n",
                "crates/app/src/inner_file.rs": "//! use std::os::unix::fs;\n#![cfg(unix)]\nuse std::os::unix::fs;\n",
            },
        ), [])

    def test_comments_and_strings(self):
        self.assertEqual(scan(r'''
            // std::os::unix::fs, libc::kill
            /* tokio::net::UnixStream */
            /// See `libc::openpty`.
            const S: &str = "std::os::fd::OwnedFd libc::pid_t";
            const R: &str = r#"felt::f() "quoted" libc::fork"#;
            const C: char = '"';
            fn f<'a>(x: &'a str) -> &'a str { x }
        '''), [])

    def test_windows_arm(self):
        self.assertEqual(scan("""
            #[cfg(windows)]
            fn f() -> libc::c_int { 0 }
            #[cfg(any(windows, target_os = "linux"))]
            fn g() -> libc::c_void { todo!() }
        """), [])


class Speed(unittest.TestCase):
    def test_real_acpmux_under_budget(self):
        # The gate's budget: it reads all of acpmux (about 2,700 files, 45 MB) in seconds.
        import time
        crate = ROOT / "cmux-tui/crates/acpmux"
        if not (crate / "Cargo.toml").exists():
            self.skipTest("no acpmux in this checkout")
        start = time.monotonic()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            uow.main(["--root", str(ROOT)])
        self.assertLess(time.monotonic() - start, 20.0)


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main()
