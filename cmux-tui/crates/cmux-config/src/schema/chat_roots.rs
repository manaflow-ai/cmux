//! `agents.chats.roots` (Swift `ChatRootValidator`): an absolute folder that
//! is not `/`, not the home folder, not on another or network volume, and
//! not inside a folder macOS guards with a privacy prompt. Symbolic links
//! are followed with readlink only; no folder contents are ever read. The
//! guarded folders come from the one list every layer reads,
//! cmux-tui/crates/acpmux/data/protected-folders.json.

use std::path::Path;
use std::sync::OnceLock;

use serde::Deserialize;

const PROTECTED: &str = include_str!("../../../acpmux/data/protected-folders.json");
const MAX_LINKS: usize = 40;

#[derive(Deserialize)]
struct Entry {
    path: String,
}

#[derive(Deserialize)]
struct Protected {
    #[serde(rename = "inHome")]
    in_home: Vec<Entry>,
    roots: Vec<Entry>,
}

fn protected() -> &'static Protected {
    static LIST: OnceLock<Protected> = OnceLock::new();
    LIST.get_or_init(|| {
        serde_json::from_str(PROTECTED)
            .unwrap_or(Protected { in_home: Vec::new(), roots: Vec::new() })
    })
}

/// Whether `path` may be a chat root for a user whose home is `home`.
pub fn chat_root_is_valid(path: &str, home: &str) -> bool {
    chat_root_is_valid_with(path, home, &|candidate| {
        std::fs::read_link(candidate).ok().map(|target| target.to_string_lossy().into_owned())
    })
}

fn chat_root_is_valid_with(
    path: &str,
    home: &str,
    read_link: &dyn Fn(&str) -> Option<String>,
) -> bool {
    if !path.starts_with('/') || path.contains('\0') {
        return false;
    }
    let homes = [fold(home), fold(&resolve(home, read_link).unwrap_or_else(|| home.to_owned()))];
    // The spelling first: resolving a protected descendant would read it.
    if guarded(path, true, &homes) {
        return false;
    }
    let mut parts: Vec<String> = split(path);
    let mut resolved: Vec<String> = Vec::new();
    let mut links = 0;
    while !parts.is_empty() {
        let part = parts.remove(0);
        if part == "." {
            continue;
        }
        if part == ".." {
            resolved.pop();
            continue;
        }
        let candidate =
            format!("/{}", [resolved.as_slice(), std::slice::from_ref(&part)].concat().join("/"));
        if guarded(&candidate, parts.is_empty(), &homes) {
            return false;
        }
        if let Some(target) = read_link(&candidate) {
            links += 1;
            if links > MAX_LINKS {
                return false;
            }
            if target.starts_with('/') {
                resolved.clear();
            }
            let mut next = split(&target);
            next.extend(parts);
            parts = next;
        } else {
            resolved.push(part);
        }
    }
    !guarded(&format!("/{}", resolved.join("/")), true, &homes)
}

fn split(path: &str) -> Vec<String> {
    path.split('/').filter(|part| !part.is_empty()).map(str::to_owned).collect()
}

fn fold(path: &str) -> String {
    path.to_lowercase().trim_matches('/').to_owned()
}

fn guarded(path: &str, last: bool, homes: &[String]) -> bool {
    let folded = fold(path);
    if last && (folded.is_empty() || homes.contains(&folded)) {
        return true;
    }
    let under = |root: &str| folded == root || folded.starts_with(&format!("{root}/"));
    let list = protected();
    if list.roots.iter().any(|entry| under(&fold(&entry.path))) {
        return true;
    }
    homes.iter().any(|home| {
        list.in_home.iter().any(|entry| under(&format!("{home}/{}", entry.path.to_lowercase())))
    })
}

/// The home path with its own symbolic links resolved (never a child of a
/// protected folder).
fn resolve(home: &str, read_link: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    if !Path::new(home).is_absolute() {
        return None;
    }
    let mut parts = split(home);
    let mut resolved: Vec<String> = Vec::new();
    let mut links = 0;
    while !parts.is_empty() {
        let part = parts.remove(0);
        if part == "." {
            continue;
        }
        if part == ".." {
            resolved.pop();
            continue;
        }
        let candidate =
            format!("/{}", [resolved.as_slice(), std::slice::from_ref(&part)].concat().join("/"));
        if let Some(target) = read_link(&candidate) {
            links += 1;
            if links > MAX_LINKS {
                return None;
            }
            if target.starts_with('/') {
                resolved.clear();
            }
            let mut next = split(&target);
            next.extend(parts);
            parts = next;
        } else {
            resolved.push(part);
        }
    }
    Some(format!("/{}", resolved.join("/")))
}
