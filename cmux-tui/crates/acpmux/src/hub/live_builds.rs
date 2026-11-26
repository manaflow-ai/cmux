//! The build-done trigger from `cmux live` into turn frames (cmuxterm-hq
//! `docs/rfd/0152-real-time-ui-morphing.md`, "Frames follow each hot swap through the build
//! trigger").
//!
//! A `cmux live` loop swaps a build in long after the edit that started it: the Rust daemon loop
//! (`scripts/cmux-next/rust-live.py`) compiles for tens of seconds, the Chromium loop
//! (`chromium-live.py`) for a minute. The edit's frame (`turn_frames.rs`, 1.5 s after the edit) shows
//! the old build. So each loop, once a swap lands, writes one small JSON file, the beacon
//! (`scripts/cmux-next/live_build_beacon.py`): `{"at": epoch ms, "surface": "rust", "tree": PATH}`.
//! While a turn runs, this daemon looks at the beacon's modification time every [`POLL`]; a new
//! beacon asks a `build` frame of each running turn that worked in that tree
//! ([`super::turn_frames::built`]).
//!
//! Cost: one `stat` per [`POLL`] while at least one turn is live, none otherwise (an idle daemon
//! never wakes, `tests/daemon_idle.rs`). No watch: a watch would run for the daemon's life to catch
//! a file written a few times an hour, and on macOS FSEvents would need a run loop thread.
//!
//! The path is the same on both sides without a handshake (the loops do not know which acpmux
//! serves the app): `$CMUX_LIVE_BUILD_BEACON`, else `~/Library/Caches/cmux-next/live-build-done.json`
//! on macOS and `${XDG_CACHE_HOME:-~/.cache}/cmux-next/live-build-done.json` elsewhere.

use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime};

/// How often a live turn looks at the beacon.
pub(crate) const POLL: Duration = Duration::from_millis(500);
/// A beacon older than this when first seen is an old swap (a copied home, a clock jump): no frame.
pub(crate) const FRESH: Duration = Duration::from_secs(60);

static WATCHING: AtomicBool = AtomicBool::new(false);

/// Where the `cmux live` loops write the beacon.
pub(crate) fn beacon_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_LIVE_BUILD_BEACON").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME").filter(|v| !v.is_empty()).map(PathBuf::from);
    let cache = if cfg!(target_os = "macos") {
        home?.join("Library/Caches")
    } else {
        std::env::var_os("XDG_CACHE_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| home.map(|h| h.join(".cache")))?
    };
    Some(cache.join("cmux-next/live-build-done.json"))
}

/// One swap a loop landed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Built {
    pub surface: String,
    pub tree: String,
    /// Epoch ms.
    pub at: u64,
}

/// The beacon's text as a swap, or none when it is not one.
pub(crate) fn parse(text: &str) -> Option<Built> {
    let value: Value = serde_json::from_str(text.trim()).ok()?;
    let tree = value.get("tree")?.as_str()?.trim().to_owned();
    if tree.is_empty() {
        return None;
    }
    let surface = value.get("surface").and_then(Value::as_str).unwrap_or("build").to_owned();
    let at = value.get("at").and_then(Value::as_u64)?;
    Some(Built { surface, tree, at })
}

fn epoch_ms(time: SystemTime) -> u64 {
    time.duration_since(SystemTime::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// What the beacon at `path` holds when it changed since `seen` (its last modification time):
/// a fresh swap, or none. Updates `seen`.
pub(crate) fn changed(path: &std::path::Path, seen: &mut Option<SystemTime>) -> Option<Built> {
    let modified = std::fs::metadata(path).and_then(|m| m.modified()).ok()?;
    if *seen == Some(modified) {
        return None;
    }
    *seen = Some(modified);
    let text = std::fs::read_to_string(path).ok()?;
    let built = parse(&text)?;
    let now = epoch_ms(SystemTime::now());
    (now.saturating_sub(built.at) <= FRESH.as_millis() as u64).then_some(built)
}

/// A turn began: look at the beacon until no turn is live. One loop per daemon.
pub(super) fn watch() {
    let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
    let Some(path) = beacon_path() else { return };
    if WATCHING.swap(true, Ordering::SeqCst) {
        return;
    }
    runtime.spawn(async move {
        loop {
            follow(&path).await;
            WATCHING.store(false, Ordering::SeqCst);
            // A turn that began between the last look and the store found the flag set: take over.
            if !super::turn_frames::any_live() || WATCHING.swap(true, Ordering::SeqCst) {
                return;
            }
        }
    });
}

/// Looks at the beacon at `path` every [`POLL`] while a turn is live; each fresh swap asks its
/// frames. A beacon written before this began is not a turn's.
pub(crate) async fn follow(path: &std::path::Path) {
    let mut seen = std::fs::metadata(path).and_then(|m| m.modified()).ok();
    loop {
        tokio::time::sleep(POLL).await;
        if !super::turn_frames::any_live() {
            return;
        }
        let probe = path.to_owned();
        let was = seen;
        let Ok((built, now_seen)) = tokio::task::spawn_blocking(move || {
            let mut was = was;
            (changed(&probe, &mut was), was)
        })
        .await
        else {
            continue;
        };
        seen = now_seen;
        if let Some(built) = built {
            super::turn_frames::built(&built.tree);
        }
    }
}

#[cfg(test)]
#[path = "live_builds_tests.rs"]
mod tests;
