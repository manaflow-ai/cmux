//! Where a classified save goes: the fastest layer that takes it into the
//! running app, or `needs-build` with the reason none does.
//!
//! | verdict | layer | what the router does |
//! | --- | --- | --- |
//! | `web-live` | `web` | observes: the checkout's Vite dev server (`cmux live start`) Fast Refreshes it |
//! | `daemon` (cmux-tui crates) | `daemon` | hands off to the rust-live loop (`cmux live start --rust`), reports its receipt |
//! | `daemon` (`crates/acpmux`) | `acpmux` | the same loop; acpmux restarts and its sessions resume |
//! | an app FFI input | `needs-build` | the warm swap (`hot-apply.py`'s ffi part) takes only a published release |
//! | `swift-live` | `swift` | observes: the app's live code loop (`cmux live start --swift`) patches it |
//! | `rebuild`, `strings`, `ios-only` | `needs-build` | the verdict's reasons |
//! | `no-app` | none | nothing in the app changes |

use super::rules::{Kind, Verdict};

/// What runs for the watched checkout right now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Live {
    /// The web dev server serves this checkout (web-overlay's `dev-server.tree`).
    pub web: bool,
    /// rust-live's watcher is alive and watches this checkout (`watch.pid`).
    pub rust: bool,
    /// Live mode (Swift live code) is on for this checkout (live-mode's `tree`).
    pub swift: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Layer {
    Web,
    Daemon,
    Acpmux,
    Swift,
    NeedsBuild,
}

impl Layer {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Web => "web",
            Self::Daemon => "daemon",
            Self::Acpmux => "acpmux",
            Self::Swift => "swift",
            Self::NeedsBuild => "needs-build",
        }
    }
}

/// How the router hands a layer its save.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// The layer watches the checkout itself; `swap.done` goes out now.
    Observed,
    /// rust-live builds and swaps it; `swap.done` goes out from its receipt.
    HandOff,
    /// No layer can take it: `swap.done` now, with the reason.
    Report,
}

/// One `swap.done` the save makes (or, for a hand-off, will make).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dispatch {
    pub layer: Layer,
    pub action: Action,
    pub paths: Vec<String>,
    pub state_kept: bool,
    pub error: Option<String>,
    pub reason: Option<String>,
}

/// One saved file, classified.
#[derive(Clone, Debug)]
pub struct Saved {
    pub path: String,
    pub verdict: Verdict,
    /// The app FFI archive is built from it.
    pub ffi: bool,
}

pub const FFI_REASON: &str = "the app links this Rust (an app FFI input): its warm swap \
     (hot-apply.py's ffi part) takes only a published cmux-app-ffi release of a merged commit, \
     not a working tree";
pub const NO_WEB: &str =
    "no web dev server for this checkout: cmux live start --worktree <checkout>";
pub const NO_RUST: &str =
    "rust-live is not watching this checkout: cmux live start --rust --worktree <checkout>";
pub const NO_SWIFT: &str =
    "live code is off for this checkout: cmux live start --swift --worktree <checkout>";

fn acpmux_path(path: &str) -> bool {
    path.starts_with("cmux-tui/crates/acpmux/")
}

/// The dispatches for one burst of saves, in a stable order: one per layer,
/// and one `needs-build` per distinct reason.
pub fn route(saved: &[Saved], live: Live) -> Vec<Dispatch> {
    let mut web = Vec::new();
    let mut rust = Vec::new();
    let mut swift = Vec::new();
    // reason -> paths, in first-seen order
    let mut builds: Vec<(String, Vec<String>)> = Vec::new();
    let mut needs = |reason: String, path: &str| match builds.iter_mut().find(|(r, _)| *r == reason)
    {
        Some((_, paths)) => paths.push(path.to_string()),
        None => builds.push((reason, vec![path.to_string()])),
    };
    for file in saved {
        let path = file.path.as_str();
        match file.verdict.kind {
            Kind::NoApp => {}
            Kind::WebLive => web.push(path.to_string()),
            Kind::Daemon => {
                rust.push(path.to_string());
                if file.ffi {
                    needs(FFI_REASON.to_string(), path);
                }
            }
            Kind::SwiftLive => swift.push(path.to_string()),
            Kind::Rebuild => {
                let reason = if file.verdict.reasons.is_empty() {
                    "a new app build".to_string()
                } else {
                    file.verdict.reasons.join(", ")
                };
                needs(reason, path);
            }
            Kind::Strings => needs(
                "string catalog: the web pages and Swift's source strings take it with no build \
                 (cmux app try); Swift's translations wait for the next build"
                    .to_string(),
                path,
            ),
            Kind::IosOnly => needs("iOS only: the Mac app does not change".to_string(), path),
        }
    }
    let mut out = Vec::new();
    if !web.is_empty() {
        out.push(observed(Layer::Web, web, live.web, NO_WEB));
    }
    if !rust.is_empty() {
        let layer = if rust.iter().all(|p| acpmux_path(p)) { Layer::Acpmux } else { Layer::Daemon };
        out.push(if live.rust {
            Dispatch {
                layer,
                action: Action::HandOff,
                paths: rust,
                state_kept: true,
                error: None,
                reason: None,
            }
        } else {
            Dispatch {
                layer,
                action: Action::Report,
                paths: rust,
                state_kept: false,
                error: Some(NO_RUST.to_string()),
                reason: None,
            }
        });
    }
    if !swift.is_empty() {
        out.push(observed(Layer::Swift, swift, live.swift, NO_SWIFT));
    }
    for (reason, paths) in builds {
        out.push(Dispatch {
            layer: Layer::NeedsBuild,
            action: Action::Report,
            paths,
            state_kept: false,
            error: None,
            reason: Some(reason),
        });
    }
    out
}

fn observed(layer: Layer, paths: Vec<String>, running: bool, missing: &str) -> Dispatch {
    Dispatch {
        layer,
        action: if running { Action::Observed } else { Action::Report },
        paths,
        state_kept: running,
        error: (!running).then(|| missing.to_string()),
        reason: None,
    }
}
