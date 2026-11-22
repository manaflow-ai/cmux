//! How the cmux macOS app starts and keeps its cmux-tui daemon: the rules of
//! the app's launch code (CmuxNextDaemon `Launch/`), in Rust, asked over the
//! app FFI (`include/cmux_daemon_launch.h`, Swift module
//! `CCmuxDaemonLaunchFFI`, linked through cmux-app-ffi).
//!
//! The app keeps only what needs its platform: running a process, the
//! Keychain and code signature, timers and tasks, `UserDefaults`. Every
//! decision those calls take is here:
//!
//! - [`handoff`]: which running owner is another build than the bundled
//!   binary (`build_id`, then the stamped commit), the build stamp a binary
//!   reports, and when a handoff for a capability, an install key, an update
//!   or an incompatible owner runs;
//! - [`ensure`]: the `server ensure` and `server status` command lines and
//!   environments, the timeouts, the answer (or the typed refusal), the reap
//!   grace probe, the Chief owner's environment, the diagnostic knobs, the
//!   session and tag names and the binary's resolution;
//! - [`failure`]: a full disk, a stuck owner, and how one ensure's outcome
//!   moves the restart gate ([`failure::note_outcome`]);
//! - [`watch`]: the unresponsive-owner watch's state machine (the app runs
//!   its timer and the replace task);
//! - [`terminal_env`], [`login_env`], [`shell_integration`]: the allowlisted
//!   login environment, the per-terminal and daemon environments, `TERM`,
//!   Ghostty's shell integration and the bundled `cmux` layer;
//! - [`legacy`]: the one-time adopt of the old shared channel session and the
//!   launch snapshot lookup in a state directory;
//! - [`cloud_link`]: the `cmux-tui link` command lines and environment;
//! - [`install_key`]: the install key's stored form and its hello proof
//!   (cmux-local-auth, the bytes the daemon checks);
//! - [`lines`]: a child's stderr cut into lines.
//!
//! [`ops::call`] is the one JSON entry point; `tests/cases/*.json` are the
//! golden vectors the Swift tests encoded before the move.

pub mod cloud_link;
pub mod ensure;
pub mod failure;
pub mod ffi;
pub mod fs;
pub mod handoff;
pub mod install_key;
pub mod legacy;
pub mod lines;
pub mod login_env;
pub mod ops;
pub mod shell_integration;
pub mod terminal_env;
pub mod watch;

/// An environment: variable name to value.
pub type Env = std::collections::BTreeMap<String, String>;

/// The last path component, as `NSString.lastPathComponent` reads it (a
/// trailing `/` is ignored; `/` alone is `/`).
pub(crate) fn last_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

/// The path without its last component, as `NSString.deletingLastPathComponent`
/// reads it (`/a/b` is `/a`, `/a` is `/`, `a` is empty).
pub(crate) fn parent_path(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some(("", _)) => "/".to_string(),
        Some((parent, _)) => parent.to_string(),
        None if path.starts_with('/') => "/".to_string(),
        None => String::new(),
    }
}

/// `base` joined with `component` as `URL.appendingPathComponent` gives its
/// `path` (one `/` between them, no trailing `/`).
pub(crate) fn join(base: &str, component: &str) -> String {
    let base = base.trim_end_matches('/');
    let component = component.trim_matches('/');
    if component.is_empty() {
        return if base.is_empty() { "/".into() } else { base.into() };
    }
    format!("{base}/{component}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_read_as_foundation_reads_them() {
        assert_eq!(last_component("/bin/zsh"), "zsh");
        assert_eq!(last_component("zsh"), "zsh");
        assert_eq!(last_component("/usr/bin/"), "bin");
        assert_eq!(last_component("/"), "/");
        assert_eq!(parent_path("/a/b/ghostty"), "/a/b");
        assert_eq!(parent_path("/ghostty"), "/");
        assert_eq!(parent_path("ghostty"), "");
        assert_eq!(join("/s/", "a/b/"), "/s/a/b");
    }
}
