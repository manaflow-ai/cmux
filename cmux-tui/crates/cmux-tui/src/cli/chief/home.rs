//! The Chief's home, resolved as the cmux-next app resolves it
//! (CmuxNextHomeEngine/ChiefHome.swift), so the CLI and Home open one
//! conversation owner, one brain and one memory. The home holds the brain's
//! memory and lock (`optchat/`, `state/host.lock`), the conversation
//! owner's state (`tui/`, its own session daemon) and the acpmux daemon of
//! the Chief's turns (`acpmux/`).
//!
//! One Chief per build (2026-10-14): the CLI resolves the home of the app it
//! belongs to, by bundle id (`CMUX_BUNDLE_ID` in the app's terminals, else
//! the bundle around this executable). Every build but NIGHTLY has
//! `~/.cmux/chief/<bundle id>[.<account>]`; NIGHTLY (`com.cmuxterm.app.nightly`
//! only, and a CLI outside any app) keeps the shared home of older builds,
//! `~/.cmux/chief/<account>`. The app's terminals and its brain also get the
//! exact home as `CMUX_CHIEF_HOME`, which wins.

use std::path::{Component, Path, PathBuf};

/// The one build that keeps the shared home, `~/.cmux/chief/<account>`.
const NIGHTLY_BUNDLE_ID: &str = "com.cmuxterm.app.nightly";

/// The builds with a Chief home of their own (ChiefHome.hasOwnHome): every
/// bundle but NIGHTLY's, so two identities that run at the same time
/// (NIGHTLY and cmux NEXT's `com.cmuxterm.app.nightly.cmux-next`, RC,
/// release) never share one Chief.
fn has_own_home(bundle_id: &str) -> bool {
    !bundle_id.trim().is_empty() && bundle_id != NIGHTLY_BUNDLE_ID
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct ChiefHome {
    pub root: PathBuf,
    /// A test or preflight home, never the person's Chief.
    pub isolated: bool,
}

impl ChiefHome {
    /// [`Self::resolve_for`] for the app this CLI belongs to: the bundle id
    /// an app terminal names in `env` (`CMUX_BUNDLE_ID`), else the bundle
    /// around this executable (a brain's turn that has only
    /// `CMUX_SOCKET_PATH`, a shell outside the app).
    pub(super) fn resolve(
        explicit: Option<&Path>,
        env: impl Fn(&str) -> Option<String>,
        user_home: &Path,
        cwd: &Path,
    ) -> Self {
        let exe = std::env::current_exe().ok();
        // In another app's terminal, that app's Chief variables are not this
        // build's (per-build isolation S4): the own bundle's home.
        let other_app = crate::app_identity::in_other_apps_terminal(&env, exe.as_deref());
        let env = move |key: &str| {
            if other_app && crate::app_identity::OTHER_APP_STATE_KEYS.contains(&key) {
                None
            } else {
                env(key)
            }
        };
        let bundle = crate::app_identity::AppIdentity::detect(&env, exe.as_deref())
            .and_then(|identity| identity.bundle_id)
            .or_else(|| {
                crate::app_identity::AppIdentity::detect(|_| None, exe.as_deref())
                    .and_then(|identity| identity.bundle_id)
            });
        Self::resolve_for(explicit, env, user_home, cwd, bundle.as_deref())
    }

    /// First match wins: `explicit` (`--chief-home`), `CMUX_CHIEF_HOME`,
    /// `CMUX_NEXT_CHIEF_HOME` (or `CMUX_NEXT_MUX_HOME`); then under
    /// `CMUX_NEXT_CHIEF_ROOT` (isolation markers ignored) or `~/.cmux/chief`:
    /// an isolated launch (`CMUX_NEXT_CHIEF_ISOLATED=1` and the app's other
    /// isolation markers) at `isolated/<CMUX_TAG or untagged>`, else the
    /// build's home: `<bundle id>[.<account>]` for every build but NIGHTLY,
    /// `<account>` for NIGHTLY and outside any app. A DEV bundle
    /// may name another build in `CMUX_NEXT_CHIEF_BUILD_ID` (tests only).
    pub(super) fn resolve_for(
        explicit: Option<&Path>,
        env: impl Fn(&str) -> Option<String>,
        user_home: &Path,
        cwd: &Path,
        bundle_id: Option<&str>,
    ) -> Self {
        let value = |key: &str| env(key).filter(|v| !v.is_empty());
        let given = explicit.map(Path::to_path_buf).or_else(|| {
            ["CMUX_CHIEF_HOME", "CMUX_NEXT_CHIEF_HOME", "CMUX_NEXT_MUX_HOME"]
                .iter()
                .find_map(|key| value(key))
                .map(PathBuf::from)
        });
        if let Some(path) = given {
            let absolute = if path.is_absolute() { path } else { cwd.join(path) };
            // An explicit home is the caller's; the default Chief is never it.
            return Self { root: standardized(&absolute), isolated: true };
        }
        let root_override = value("CMUX_NEXT_CHIEF_ROOT").map(|p| standardized(&cwd.join(p)));
        let base = root_override.clone().unwrap_or_else(|| user_home.join(".cmux/chief"));
        let isolated = root_override.is_none()
            && (value("CMUX_NEXT_CHIEF_ISOLATED").as_deref() == Some("1")
                || value("CMUX_NEXT_NO_ACTIVATE").as_deref() == Some("1")
                || value("CMUX_NEXT_SHOWCASE").as_deref() == Some("1")
                || value("CMUX_NEXT_TEST_WINDOW_FRAME").is_some()
                || value("CMUX_NEXT_TEST_WINDOW_SCREEN").is_some());
        if isolated {
            let tag = value("CMUX_TAG").and_then(|t| component(&t)).unwrap_or("untagged".into());
            return Self { root: standardized(&base.join("isolated").join(tag)), isolated: true };
        }
        let account = value("CMUX_NEXT_CHIEF_ACCOUNT")
            .and_then(|a| component(&a))
            .unwrap_or("default".into());
        let build = bundle_id
            .filter(|id| crate::app_identity::is_debug_bundle(id))
            .and_then(|_| value("CMUX_NEXT_CHIEF_BUILD_ID"))
            .or_else(|| bundle_id.map(str::to_owned));
        let name = match build.as_deref().filter(|id| has_own_home(id)).and_then(component) {
            None => account,
            Some(id) if account == "default" => id,
            Some(id) => format!("{id}.{account}"),
        };
        Self { root: standardized(&base.join(name)), isolated: false }
    }

    /// `cmux-chief-<FNV-1a 32 of the root path>`, the app's session name.
    pub(super) fn session(&self) -> String {
        let mut hash: u32 = 0x811c_9dc5;
        for byte in self.root.to_string_lossy().as_bytes() {
            hash ^= u32::from(*byte);
            hash = hash.wrapping_mul(0x0100_0193);
        }
        format!("cmux-chief-{hash:08x}")
    }

    /// The owner's socket: under the per-user Darwin temp directory on
    /// macOS (where the app starts it), else the default runtime directory.
    pub(super) fn socket(&self) -> anyhow::Result<PathBuf> {
        #[cfg(target_os = "macos")]
        {
            let base = crate::app_identity::darwin_user_temp_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"));
            cmux_tui_core::server::try_default_socket_path_in_base(&self.session(), &base)
        }
        #[cfg(not(target_os = "macos"))]
        {
            cmux_tui_core::server::try_default_socket_path(&self.session())
        }
    }

    pub(super) fn state_dir(&self) -> PathBuf {
        self.root.join("tui")
    }

    pub(super) fn host_lock(&self) -> PathBuf {
        self.root.join("state/host.lock")
    }

    /// Written by `cmux chief shutdown`: while it is there the app
    /// (ChiefBrainWatch) starts no brain on its own; the next `cmux chief`
    /// or Home ask takes it away.
    pub(super) fn shutdown_marker(&self) -> PathBuf {
        self.root.join("state/shutdown")
    }

    pub(super) fn token_file(&self) -> PathBuf {
        self.root.join("agent-token")
    }

    pub(super) fn host_log(&self) -> PathBuf {
        self.root.join("host.log")
    }

    pub(super) fn acpmux_home(&self) -> PathBuf {
        self.root.join("acpmux")
    }

    /// acpmux's own socket rule for this home (cmux-agent-pane-policy
    /// `environment::default_socket_path`).
    pub(super) fn acpmux_socket(&self, uid: u32) -> PathBuf {
        cmux_agent_pane_policy::environment::default_socket_path(&self.acpmux_home(), uid).into()
    }
}

/// Foundation's `standardizedFileURL.path`: `.` and `..` removed lexically,
/// no trailing slash, links left as they are.
fn standardized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// A path component: runs of anything outside `[A-Za-z0-9._]` become one
/// `-`, trimmed of `-` and `.`; None when nothing is left.
fn component(raw: &str) -> Option<String> {
    let mut out = String::new();
    for c in raw.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '_' {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches(|c| c == '-' || c == '.');
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}
