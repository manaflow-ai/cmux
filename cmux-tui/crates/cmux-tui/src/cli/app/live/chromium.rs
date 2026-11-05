//! `cmux live start|stop|status --chromium`: the browser engine's live C++ loop.
//!
//! Lawrence, on the live-editing work: "this will be interesting for cmux-chromium fork as well".
//! The loop is `scripts/cmux-next/chromium-live.py` in the checkout: each saved file under
//! `.cmux-dev/chromium/` builds on a warm engine tree on `--build-host`, the new framework is
//! renamed into the running app, and only renderer processes restart, so open Chromium pages
//! reload on the build with the app, its windows and every session kept.

use cmux_process::Command as Process;
use std::path::{Path, PathBuf};

use super::{RustVerb, recorded_watch_tree, tool_path};

/// The script in a cmux checkout that runs the engine loop.
pub(super) const SCRIPT: &str = "scripts/cmux-next/chromium-live.py";

/// Runs `verb` with the checkout's [`SCRIPT`]; `args` are its `start` flags.
pub(super) fn run(verb: RustVerb, worktree: &Option<PathBuf>, args: &[String]) -> i32 {
    let messages = &crate::localization::catalog().app_control.live;
    let tree = match worktree {
        Some(worktree) => worktree.canonicalize().ok().filter(|tree| tree.join(SCRIPT).is_file()),
        None => Process::new("git")
            .args(["rev-parse", "--show-toplevel"])
            .output()
            .ok()
            .filter(|output| output.status.success())
            .map(|output| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
            .filter(|tree| tree.join(SCRIPT).is_file()),
    };
    // stop and status need no checkout: the loop's state folder names the one it watches.
    let script = match (&tree, verb) {
        (Some(tree), _) => tree.join(SCRIPT),
        (None, RustVerb::Start) => {
            eprintln!("{}", messages.chromium_no_checkout);
            return 2;
        }
        (None, _) => match recorded_script() {
            Some(script) => script,
            None => {
                println!("{}", messages.chromium_not_watching);
                return 0;
            }
        },
    };
    let mut process = Process::new("python3");
    process.arg(&script);
    match verb {
        RustVerb::Start => {
            process.arg("start");
            if let Some(tree) = &tree {
                process.args(["--worktree".as_ref(), tree.as_os_str()]);
            }
            process.args(args);
        }
        RustVerb::Stop => {
            process.arg("stop");
        }
        RustVerb::Status => {
            process.arg("status");
        }
    }
    if let Some(path) = tool_path(std::env::var_os("PATH"), std::env::var_os("HOME")) {
        process.env("PATH", path);
    }
    match process.status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            eprintln!("{}", messages.cannot_run.replace("{error}", &error.to_string()));
            1
        }
    }
}

/// `cmux live status`: the engine loop's last swap, when it ever ran (prints nothing otherwise).
pub(super) fn status_if_used(tree: &Path) {
    if tree.join(SCRIPT).is_file() {
        let _ = Process::new("python3")
            .arg(tree.join(SCRIPT))
            .args(["status", "--if-used"])
            .current_dir(tree)
            .status();
    }
}

/// The loop's state folder (`chromium-live.py state_dir`).
pub(super) fn state_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("CMUX_CHROMIUM_LIVE_STATE_DIR").filter(|dir| !dir.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    let home = PathBuf::from(std::env::var_os("HOME").filter(|home| !home.is_empty())?);
    Some(if cfg!(target_os = "macos") {
        home.join("Library/Caches/cmux-next/chromium-live")
    } else {
        std::env::var_os("XDG_CACHE_HOME")
            .filter(|dir| !dir.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".cache"))
            .join("cmux-next/chromium-live")
    })
}

/// The running loop's script, from the checkout its `watch.pid` names.
fn recorded_script() -> Option<PathBuf> {
    recorded_watch_tree(&state_dir()?.join("watch.pid"))
        .map(|tree| tree.join(SCRIPT))
        .filter(|script| script.is_file())
}
