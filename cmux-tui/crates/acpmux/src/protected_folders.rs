//! LAUNCH-NO-TCC-PROMPTS: the folders an agent is never started in unless a
//! person asked for that folder. An agent starts with its cwd in the folder and
//! may read it at once; on macOS a read inside a guarded location raises a
//! privacy prompt attributed to cmux, and an agent in the home folder or `/`
//! walks into all of them. Warming (`_acpmux/warm`) and the session pool
//! (`_acpmux/prewarm` and the per-cwd entries) refuse these folders. A
//! session a person creates names its folder and is not limited here.

use std::path::{Path, PathBuf};

/// The one protected-folder list for every layer (data/protected-folders.json):
/// Swift and TypeScript get generated copies (scripts/cmux-next/gen-protected-folders.py).
const PROTECTED_FOLDERS_JSON: &str = include_str!("../data/protected-folders.json");

#[derive(serde::Deserialize)]
struct ProtectedEntry {
    path: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProtectedList {
    /// The locations macOS guards, relative to the home folder.
    in_home: Vec<ProtectedEntry>,
    /// Guarded locations outside the home folder: other and network volumes.
    roots: Vec<ProtectedEntry>,
}

/// The parsed list; `None` only if the embedded file is invalid (the unit
/// tests parse it), and then every folder is refused (fail closed).
fn protected_list() -> Option<&'static ProtectedList> {
    static LIST: std::sync::OnceLock<Option<ProtectedList>> = std::sync::OnceLock::new();
    LIST.get_or_init(|| match serde_json::from_str(PROTECTED_FOLDERS_JSON) {
        Ok(list) => Some(list),
        Err(e) => {
            tracing::error!("data/protected-folders.json: {e}");
            None
        }
    })
    .as_ref()
}

/// Why an agent may not be started in `cwd` unasked, or `None` when it may.
/// The folder is checked as spelled and with its symlinks resolved.
pub fn unasked_refusal(cwd: &Path) -> Option<String> {
    refusal_in(cwd, dirs::home_dir().as_deref())
}

/// `unasked_refusal` for the user whose home folder is `home`.
pub fn refusal_in(cwd: &Path, home: Option<&Path>) -> Option<String> {
    if !cwd.is_absolute() {
        return Some(format!("{} is not an absolute folder", cwd.display()));
    }
    // The home folder may itself be reached through a symlink (`/var` on macOS).
    let homes: Vec<PathBuf> = home
        .into_iter()
        .flat_map(|h| [Some(h.to_path_buf()), std::fs::canonicalize(h).ok()])
        .flatten()
        .collect();
    let refused = |reason: &str| {
        Some(format!(
            "{} is {reason}; an agent starts there only when a person picks it",
            cwd.display()
        ))
    };
    // The spelling first: resolving a guarded path already reads inside it.
    if let Some(reason) = guarded(cwd, &homes) {
        return refused(reason);
    }
    let resolved = std::fs::canonicalize(cwd).ok()?;
    guarded(&resolved, &homes).and_then(refused)
}

/// The folder for agents acpmux starts with no person asking (the model
/// probes at daemon start): `<acpmux home>/unattended`, owned by acpmux and
/// empty of the person's files. Never the home folder: an agent scans its
/// folder at start. When the acpmux home itself is guarded, a folder in the
/// per-user temp dir. Created if missing.
pub fn unattended_cwd() -> PathBuf {
    unattended_cwd_in(&crate::config::home(), dirs::home_dir().as_deref())
}

/// `unattended_cwd` for an acpmux home and a user home folder.
pub fn unattended_cwd_in(acpmux_home: &Path, home: Option<&Path>) -> PathBuf {
    let own = acpmux_home.join("unattended");
    let dir = if refusal_in(&own, home).is_none() {
        own
    } else {
        std::env::temp_dir().join("acpmux-unattended")
    };
    if let Err(e) = std::fs::create_dir_all(&dir) {
        tracing::warn!(dir = %dir.display(), "unattended agent folder: {e}");
    }
    dir
}

fn guarded(path: &Path, homes: &[PathBuf]) -> Option<&'static str> {
    let folded = fold(path);
    if folded == "/" {
        return Some("the root folder");
    }
    let under = |root: &str| {
        let root = root.to_lowercase();
        folded == root || folded.starts_with(&format!("{root}/"))
    };
    let Some(list) = protected_list() else {
        return Some("unknown: the protected-folder list is invalid");
    };
    if list.roots.iter().any(|root| under(&root.path)) {
        return Some("on another or a network volume");
    }
    for home in homes {
        let home = fold(home);
        if folded == home {
            return Some("the home folder");
        }
        if list.in_home.iter().any(|relative| under(&format!("{home}/{}", relative.path))) {
            return Some("in a privacy-protected folder");
        }
    }
    None
}

/// The path lowercased (the Mac's disk ignores case) without a trailing `/`.
fn fold(path: &Path) -> String {
    let text = path.to_string_lossy().to_lowercase();
    let trimmed = text.trim_end_matches('/');
    if trimmed.is_empty() { "/".to_owned() } else { trimmed.to_owned() }
}
