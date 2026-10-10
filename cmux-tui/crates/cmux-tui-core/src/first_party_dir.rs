//! Where the daemon finds the first-party app packages (cx-0uo1, cx-e0cs).
//!
//! The one copy ships inside the cmux app bundle, in CmuxNextApps'
//! resources (`scripts/cmux-next/sync-app-runtime.sh`). The daemon binary
//! lives in the same bundle (`<App>.app/Contents/Resources/bin/cmux-tui`), so
//! it resolves that directory from the real path of its own executable: a
//! daemon started by the app, the CLI or the TUI finds the same packages.
//!
//! `CMUX_APPS_FIRST_PARTY_DIR` stays accepted, but only when its real path is
//! inside that same bundle; any other value is ignored with a log line (a
//! same-uid environment must not point the daemon at a foreign first-party
//! set). The variable is read once at startup and removed from the process
//! environment before any thread starts, so no shell, agent or server the
//! daemon spawns inherits it.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The override variable (set by the app for the daemon it starts).
pub const ENV: &str = "CMUX_APPS_FIRST_PARTY_DIR";

/// The first-party directory inside an app bundle, relative to the bundle.
const IN_BUNDLE: &str =
    "Contents/Resources/CmuxNext_CmuxNextApps.bundle/Contents/Resources/AppPlatform/first-party";

static TAKEN: OnceLock<Option<PathBuf>> = OnceLock::new();

/// Reads [`ENV`] into this process's once-only setting and removes it from
/// the process environment.
///
/// # Safety
///
/// The caller must call this while no other thread exists: removing an
/// environment variable is unsound while another thread can read it.
pub unsafe fn take_from_process_env() {
    let value = std::env::var_os(ENV).filter(|v| !v.is_empty()).map(PathBuf::from);
    let _ = TAKEN.set(value);
    // SAFETY: forwarded from this function's own contract (see # Safety).
    unsafe { std::env::remove_var(ENV) };
}

/// The app bundle (`…/<App>.app`) that holds `exe` at
/// `Contents/Resources/bin/<binary>`, by real path; `None` elsewhere.
pub fn bundle_of(exe: &Path) -> Option<PathBuf> {
    let exe = std::fs::canonicalize(exe).ok()?;
    let bin = exe.parent()?;
    let resources = bin.parent()?;
    let contents = resources.parent()?;
    let bundle = contents.parent()?;
    let named = |p: &Path, name: &str| p.file_name().is_some_and(|n| n == name);
    (named(bin, "bin")
        && named(resources, "Resources")
        && named(contents, "Contents")
        && bundle.extension().is_some_and(|e| e == "app"))
    .then(|| bundle.to_path_buf())
}

/// The first-party directory for a daemon at `exe` with override `taken`:
/// the override when its real path is inside `exe`'s bundle, else the
/// bundle's own directory, else (no bundle: a standalone install)
/// `apps/first-party` next to the binary, which an override cannot move.
pub fn resolve(exe: Option<&Path>, taken: Option<&Path>) -> Option<PathBuf> {
    let bundle = exe.and_then(bundle_of);
    if let Some(dir) = taken {
        match (bundle.as_deref(), std::fs::canonicalize(dir)) {
            (Some(bundle), Ok(real)) if real.starts_with(bundle) => return Some(real),
            _ => eprintln!(
                "cmux-tui: {ENV}={} ignored: not inside this daemon's app bundle",
                dir.display()
            ),
        }
    }
    if let Some(bundle) = bundle {
        return Some(bundle.join(IN_BUNDLE));
    }
    exe.and_then(Path::parent).map(|d| d.join("apps").join("first-party"))
}

/// This process's first-party directory ([`resolve`] with its own
/// executable and the override taken at startup).
pub fn current() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok();
    let taken = TAKEN.get().cloned().flatten();
    resolve(exe.as_deref(), taken.as_deref())
}
