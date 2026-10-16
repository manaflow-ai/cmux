//! The hand's own decision for each request, made on this machine.
//!
//! The Cloud checks who may call a hand; the hand checks what that call may
//! touch. A path is resolved (symlinks followed for the part that exists)
//! before it is compared with a root, so `root/link -> /etc` is outside.

use super::config::{HandConfig, Profile};
use std::path::{Component, Path, PathBuf};

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    /// Runs only after the owner approves this one request (`mac` profile).
    Ask,
    Deny(String),
}

/// Words of a program run that are clearly destructive on a person's Mac:
/// these are refused on the hand itself, whatever the Cloud's classifier says.
fn destructive_exec(argv: &[String], home: Option<&Path>) -> Option<String> {
    let line = argv.join(" ");
    let words: Vec<&str> = line
        .split(|c: char| c.is_whitespace() || c == ';' || c == '&' || c == '|')
        .filter(|w| !w.is_empty())
        .collect();
    let home = home.map(|h| h.to_string_lossy().trim_end_matches('/').to_owned());
    let is_root_target = |w: &str| {
        let w = w.trim_matches(|c| c == '"' || c == '\'');
        matches!(
            w,
            "/" | "/*"
                | "~"
                | "~/"
                | "~/*"
                | "$HOME"
                | "$HOME/"
                | "$HOME/*"
                | "${HOME}"
                | "${HOME}/"
                | "/Users"
                | "/System"
                | "/Applications"
                | "/Library"
                | "/usr"
                | "/bin"
                | "/etc"
        ) || home
            .as_deref()
            .is_some_and(|h| w == h || w == format!("{h}/") || w == format!("{h}/*"))
    };
    for (i, w) in words.iter().enumerate() {
        let base = w.rsplit('/').next().unwrap_or(w);
        match base {
            "rm" | "srm" => {
                let rest = &words[i + 1..];
                let recursive = rest.iter().any(|a| {
                    a.starts_with('-')
                        && !a.starts_with("--")
                        && (a.contains('r') || a.contains('R'))
                        || *a == "--recursive"
                });
                if recursive && rest.iter().any(|a| is_root_target(a)) {
                    return Some(format!("{line:.120}: removes the home folder or the disk"));
                }
            }
            "mkfs" | "newfs_apfs" | "newfs_hfs" | "fdisk" | "gpt" => {
                return Some(format!("{base} formats a disk"));
            }
            "diskutil"
                if words[i + 1..].iter().any(|a| {
                    a.starts_with("erase")
                        || a.starts_with("zero")
                        || *a == "secureErase"
                        || *a == "partitionDisk"
                        || a.starts_with("reformat")
                }) =>
            {
                return Some("diskutil erases or repartitions a disk".into());
            }
            "dd" if words[i + 1..].iter().any(|a| a.starts_with("of=/dev/")) => {
                return Some("dd writes to a raw disk".into());
            }
            _ if base.starts_with(":(){") => return Some("a fork bomb".into()),
            _ => {}
        }
    }
    None
}

/// Paths a write may never touch on a person's Mac (raw disks, the system volume).
fn destructive_path(action: &str, p: &Path) -> Option<String> {
    let writes = matches!(action, "fs.write" | "fs.edit" | "fs.patch");
    let s = p.to_string_lossy();
    if writes && (s.starts_with("/dev/") || s.starts_with("/System/") || s == "/System") {
        return Some(format!("{s}: a disk device or the system volume"));
    }
    None
}

/// `path` made absolute against `cwd` and resolved the way the OS will open
/// it: one component at a time, each existing component replaced by its
/// canonical form (symlinks followed) before a later `..` applies, so
/// `root/link/../x` with `link -> /etc/ssh` resolves to `/etc/x`. Components
/// that do not exist yet are kept as written.
pub fn resolve(path: &str, cwd: Option<&Path>) -> Result<PathBuf, String> {
    if path.is_empty() {
        return Err("empty path".into());
    }
    let p = Path::new(path);
    let joined = if p.is_absolute() {
        p.to_path_buf()
    } else {
        match cwd {
            Some(c) => c.join(p),
            None => return Err(format!("{path}: a relative path needs cwd")),
        }
    };
    let mut cur = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::Prefix(_) | Component::RootDir => cur.push(c.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                cur.pop();
            }
            Component::Normal(name) => {
                let next = cur.join(name);
                cur = if std::fs::symlink_metadata(&next).is_ok() {
                    std::fs::canonicalize(&next).map_err(|e| format!("{}: {e}", next.display()))?
                } else {
                    next
                };
            }
        }
    }
    Ok(cur)
}

fn inside(path: &Path, root: &Path) -> bool {
    let root = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    path.starts_with(&root)
}

/// The decision for `action` on `paths` (already resolved). `verdict` is the
/// Cloud classifier's (`allow`, `ask`; a `deny` never reaches the hand), and
/// `argv` the program of an `exec`.
pub fn decide(
    cfg: &HandConfig,
    action: &str,
    paths: &[PathBuf],
    verdict: Option<&str>,
    argv: Option<&[String]>,
) -> Decision {
    for p in paths {
        if !cfg.roots.iter().any(|r| inside(p, r)) {
            return Decision::Deny(format!(
                "{} is outside the hand's approved folders",
                p.display()
            ));
        }
    }
    match cfg.profile {
        Profile::Sandbox => Decision::Allow,
        Profile::Mac => {
            // The hand's own hard denies first: a host that says allow cannot skip them.
            if let Some(why) = argv.and_then(|a| destructive_exec(a, dirs::home_dir().as_deref())) {
                return Decision::Deny(why);
            }
            if let Some(why) = paths.iter().find_map(|p| destructive_path(action, p)) {
                return Decision::Deny(why);
            }
            // A local allow rule, or the classifier's allow, runs at once; anything else
            // (ask, no verdict, an unknown one) waits for the owner.
            let covered = |p: &PathBuf| {
                cfg.allow.iter().any(|rule| {
                    inside(p, &rule.path) && rule.actions.iter().any(|a| a == "*" || a == action)
                })
            };
            if verdict == Some("allow") || (!paths.is_empty() && paths.iter().all(covered)) {
                Decision::Allow
            } else {
                Decision::Ask
            }
        }
    }
}
