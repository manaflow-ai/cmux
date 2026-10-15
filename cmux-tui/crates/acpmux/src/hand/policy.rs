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

/// Actions that run a program. A `mac` hand never runs them.
const EXEC_ACTIONS: &[&str] = &["exec"];

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

/// The decision for `action` on `paths` (already resolved).
pub fn decide(cfg: &HandConfig, action: &str, paths: &[PathBuf]) -> Decision {
    if cfg.profile == Profile::Mac && EXEC_ACTIONS.contains(&action) {
        return Decision::Deny("exec is off on a mac hand".into());
    }
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
            let covered = |p: &PathBuf| {
                cfg.allow.iter().any(|rule| {
                    inside(p, &rule.path) && rule.actions.iter().any(|a| a == "*" || a == action)
                })
            };
            if !paths.is_empty() && paths.iter().all(covered) {
                Decision::Allow
            } else {
                Decision::Ask
            }
        }
    }
}
