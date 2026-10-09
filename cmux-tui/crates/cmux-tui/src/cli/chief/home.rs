//! The Chief's home, resolved as the cmux-next app resolves it
//! (CmuxNextApp/Home/ChiefHome.swift), so the CLI and Home open one
//! conversation owner, one brain and one memory. The home holds the brain's
//! memory and lock (`optchat/`, `state/host.lock`), the conversation
//! owner's state (`tui/`, its own session daemon) and the acpmux daemon of
//! the Chief's turns (`acpmux/`).

use std::path::{Component, Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ChiefHome {
    pub root: PathBuf,
    /// A test or preflight home, never the person's Chief.
    pub isolated: bool,
}

impl ChiefHome {
    /// First match wins: `explicit` (`--chief-home`), `CMUX_CHIEF_HOME`,
    /// `CMUX_NEXT_CHIEF_HOME` (or `CMUX_NEXT_MUX_HOME`), an isolated launch
    /// (`CMUX_NEXT_CHIEF_ISOLATED=1` and the app's other isolation markers)
    /// at `~/.cmux/chief/isolated/<CMUX_TAG or untagged>`, else
    /// `~/.cmux/chief/<CMUX_NEXT_CHIEF_ACCOUNT or default>`.
    pub(super) fn resolve(
        explicit: Option<&Path>,
        env: impl Fn(&str) -> Option<String>,
        user_home: &Path,
        cwd: &Path,
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
        let base = user_home.join(".cmux/chief");
        let isolated = value("CMUX_NEXT_CHIEF_ISOLATED").as_deref() == Some("1")
            || value("CMUX_NEXT_NO_ACTIVATE").as_deref() == Some("1")
            || value("CMUX_NEXT_SHOWCASE").as_deref() == Some("1")
            || value("CMUX_NEXT_TEST_WINDOW_FRAME").is_some()
            || value("CMUX_NEXT_TEST_WINDOW_SCREEN").is_some();
        if isolated {
            let tag = value("CMUX_TAG").and_then(|t| component(&t)).unwrap_or("untagged".into());
            return Self { root: standardized(&base.join("isolated").join(tag)), isolated: true };
        }
        let account = value("CMUX_NEXT_CHIEF_ACCOUNT")
            .and_then(|a| component(&a))
            .unwrap_or("default".into());
        Self { root: standardized(&base.join(account)), isolated: false }
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

    pub(super) fn token_file(&self) -> PathBuf {
        self.root.join("agent-token")
    }

    pub(super) fn host_log(&self) -> PathBuf {
        self.root.join("host.log")
    }

    pub(super) fn acpmux_home(&self) -> PathBuf {
        self.root.join("acpmux")
    }

    /// acpmux's own socket rule: `<home>/acpmux.sock`, or
    /// `/tmp/acpmux-<uid>/<fnv1a64(home)>.sock` when that is 96 bytes or more.
    pub(super) fn acpmux_socket(&self, uid: u32) -> PathBuf {
        let home = self.acpmux_home();
        let preferred = home.join("acpmux.sock");
        if preferred.to_string_lossy().len() < 96 {
            return preferred;
        }
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in home.to_string_lossy().as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        PathBuf::from(format!("/tmp/acpmux-{uid}/{hash:016x}.sock"))
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
