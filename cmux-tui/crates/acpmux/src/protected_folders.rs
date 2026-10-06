//! LAUNCH-NO-TCC-PROMPTS: the folders an agent is never started in unless a
//! person asked for that folder. An agent starts with its cwd in the folder and
//! may read it at once; on macOS a read inside a guarded location raises a
//! privacy prompt attributed to cmux, and an agent in the home folder or `/`
//! walks into all of them. Warming (`_acpmux/warm`) and the session pool
//! (`_acpmux/prewarm` and the per-cwd entries) refuse these folders. A
//! session a person creates names its folder and is not limited here.

use std::path::{Path, PathBuf};

/// The locations macOS guards, relative to the home folder.
const GUARDED_IN_HOME: &[&str] = &[
    "Desktop",
    "Documents",
    "Downloads",
    "Pictures",
    "Music",
    "Movies",
    "Library/Mobile Documents",
    "Library/CloudStorage",
    "Library/Containers",
    "Library/Group Containers",
    "Library/Mail",
    "Library/Messages",
    "Library/Safari",
    "Library/Calendars",
];

/// Guarded locations outside the home folder: other and network volumes.
const GUARDED_ROOTS: &[&str] = &["/Volumes", "/Network", "/net"];

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
    let resolved = std::fs::canonicalize(cwd).ok();
    // The home folder may itself be reached through a symlink (`/var` on macOS).
    let homes: Vec<PathBuf> = home
        .into_iter()
        .flat_map(|h| [Some(h.to_path_buf()), std::fs::canonicalize(h).ok()])
        .flatten()
        .collect();
    for path in std::iter::once(cwd.to_path_buf()).chain(resolved) {
        if let Some(reason) = guarded(&path, &homes) {
            return Some(format!(
                "{} is {reason}; an agent starts there only when a person picks it",
                cwd.display()
            ));
        }
    }
    None
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
    if GUARDED_ROOTS.iter().any(|root| under(root)) {
        return Some("on another or a network volume");
    }
    for home in homes {
        let home = fold(home);
        if folded == home {
            return Some("the home folder");
        }
        if GUARDED_IN_HOME.iter().any(|relative| under(&format!("{home}/{relative}"))) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_home_root_and_guarded_folders_as_spelled() {
        let home = Path::new("/Users/me");
        for cwd in [
            "/",
            "/Users/me",
            "/Users/me/",
            "/Users/me/Desktop",
            "/Users/me/documents/app",
            "/Users/me/Downloads/x",
            "/Users/me/Pictures/x",
            "/Users/me/Music",
            "/Users/me/Movies/x",
            "/Users/me/Library/Mobile Documents/com~apple~CloudDocs",
            "/Users/me/Library/CloudStorage/Dropbox",
            "/Users/me/Library/Containers/com.apple.Notes",
            "/Users/me/Library/Group Containers/g",
            "/Users/me/Library/Mail",
            "/Users/me/Library/Messages",
            "/Users/me/Library/Safari",
            "/Users/me/Library/Calendars",
            "/Volumes/External/x",
            "/Network/Servers/x",
        ] {
            assert!(refusal_in(Path::new(cwd), Some(home)).is_some(), "{cwd} must be refused");
        }
        for cwd in [
            "/Users/me/code/app",
            "/Users/me/Desktopish",
            "/opt/work",
            "/Users/me/Library/Application Support/x",
        ] {
            assert_eq!(refusal_in(Path::new(cwd), Some(home)), None, "{cwd} must be allowed");
        }
        assert!(refusal_in(Path::new("relative"), Some(home)).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_a_symlink_into_a_guarded_folder() {
        let home = std::env::temp_dir().join(format!("acpmux-guarded-{}", uuid::Uuid::now_v7()));
        let documents = home.join("Documents/app");
        std::fs::create_dir_all(&documents).unwrap();
        let code = home.join("code");
        std::fs::create_dir_all(&code).unwrap();
        let link = code.join("linked");
        std::os::unix::fs::symlink(&documents, &link).unwrap();
        assert!(refusal_in(&link, Some(&home)).is_some());
        assert_eq!(refusal_in(&code, Some(&home)), None);
        let _ = std::fs::remove_dir_all(&home);
    }
}
