//! The web ABI check `cmux live start` makes before it runs the checkout's web-overlay.sh, the same
//! one the script makes (its `abi_preflight`). Every running cmux NEXT build reloads every page on
//! any change to `web-dev.json`, so pointing an app at web code for another web ABI blanks it: the
//! app refuses that code (WebDevOverride.refusal) or its pages call host ops it lacks. The check runs
//! here too because the script is the checkout's own, and an older checkout's has no check.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// The web ABI file of a cmux NEXT .app (its bundled pages, WebDevOverride.bundledABI).
pub(super) const APP_ABI: &str =
    "Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json";
/// The web ABI file of a checkout's web UI, which its dev server serves.
pub(super) const TREE_ABI: &str = "webviews/src/web-abi.json";

/// A target app whose web ABI is not the checkout's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Mismatch {
    pub tree_abi: i64,
    pub app: PathBuf,
    pub app_abi: i64,
}

/// The `abi` in a web-abi.json, None when the file or the key is missing.
pub(super) fn read_abi(file: &Path) -> Option<i64> {
    let text = std::fs::read_to_string(file).ok()?;
    serde_json::from_str::<serde_json::Value>(&text).ok()?.get("abi")?.as_i64()
}

/// The apps the dev server is for: `CMUX_WEB_OVERLAY_APP` (`app`), else the installed NEXT builds.
pub(super) fn target_apps(app: Option<OsString>) -> Vec<PathBuf> {
    match app.filter(|app| !app.is_empty()) {
        Some(app) => vec![PathBuf::from(app)],
        None => vec![
            PathBuf::from("/Applications/cmux NIGHTLY.app"),
            PathBuf::from("/Applications/cmux NEXT.app"),
        ],
    }
}

/// The first of `apps` whose web ABI is not `tree`'s. A checkout or an app with no web-abi.json is
/// not checked, as the app checks nothing then.
pub(super) fn mismatch(tree: &Path, apps: &[PathBuf]) -> Option<Mismatch> {
    let tree_abi = read_abi(&tree.join(TREE_ABI))?;
    apps.iter().find_map(|app| {
        let app_abi = read_abi(&app.join(APP_ABI))?;
        (app_abi != tree_abi).then(|| Mismatch { tree_abi, app: app.clone(), app_abi })
    })
}
