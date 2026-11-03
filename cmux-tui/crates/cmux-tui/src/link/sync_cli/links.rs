//! Symlinks of a synced folder. One whose target stays inside the folder is
//! kept as a symlink both ways: a push makes it on the machine
//! (`fs-symlink-v1`'s `fs.symlink`), a pull makes it here, and the record
//! keeps its text ([`super::Linked`]). One that points outside the folder,
//! at nothing, or into a repository folder stays where it is and is named
//! with why.
//!
//! The text is kept as written when it is relative and, read from the
//! link's folder, never climbs above the top; an absolute one (or one that
//! climbs out and back in) whose target is inside is rewritten relative
//! from the link's folder, so it names the same place on the machine. On a
//! pull the machine is not trusted: only a relative text that stays inside
//! by its own words comes back, and nothing here ever writes through a
//! symlink ([`super::place`]).

use std::path::Path;

use super::names;
use super::skips::Why;

/// What a push does with the symlink at a path of this Mac's folder.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Local {
    /// Kept, with this text.
    Keep(String),
    Skip(Why),
}

/// The symlink at `path` (`relative` in the folder `top`, canonical).
pub(super) fn local(top: &Path, relative: &str, path: &Path) -> std::io::Result<Local> {
    let text = std::fs::read_link(path)?;
    let Some(text) = text.to_str() else { return Ok(Local::Skip(Why::NameNotUtf8)) };
    let Ok(canonical) = std::fs::canonicalize(path) else {
        return Ok(Local::Skip(Why::SymlinkBroken));
    };
    let Some(below) = canonical.strip_prefix(top).ok().and_then(Path::to_str) else {
        return Ok(Local::Skip(Why::SymlinkOutside));
    };
    if below.split('/').any(names::is_dotgit) {
        return Ok(Local::Skip(Why::SymlinkIntoRepository));
    }
    let parent = parent_of(relative);
    if !text.starts_with('/') && resolve(parent, text).is_some() {
        return Ok(Local::Keep(text.to_string()));
    }
    Ok(Local::Keep(relative_from(parent, below)))
}

/// The folder part of `relative` (empty at the top).
pub(super) fn parent_of(relative: &str) -> &str {
    relative.rsplit_once('/').map_or("", |(parent, _)| parent)
}

/// Where the link text `text` in the folder `parent` (relative to the top)
/// points, relative to the top, read by its words alone: None when it is
/// absolute, empty, climbs above the top, has a control character or
/// passes through a repository folder under any spelling.
pub(super) fn resolve(parent: &str, text: &str) -> Option<String> {
    if text.is_empty() || text.starts_with('/') || text.chars().any(char::is_control) {
        return None;
    }
    let mut parts: Vec<&str> = parent.split('/').filter(|part| !part.is_empty()).collect();
    for part in text.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            name => {
                if names::is_dotgit(name) {
                    return None;
                }
                parts.push(name);
            }
        }
    }
    Some(parts.join("/"))
}

/// Why a machine's link text that [`resolve`] refuses stays there.
pub(super) fn refused(text: &str) -> Why {
    if text.split('/').any(names::is_dotgit) {
        Why::SymlinkIntoRepository
    } else {
        Why::SymlinkOutside
    }
}

/// A relative link text from the folder `parent` to `target` (both
/// relative to the top).
fn relative_from(parent: &str, target: &str) -> String {
    let from: Vec<&str> = parent.split('/').filter(|part| !part.is_empty()).collect();
    let to: Vec<&str> = target.split('/').filter(|part| !part.is_empty()).collect();
    let common = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts: Vec<&str> = vec![".."; from.len() - common];
    parts.extend(&to[common..]);
    if parts.is_empty() { ".".to_string() } else { parts.join("/") }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_text_is_inside_only_by_its_own_words() {
        assert_eq!(resolve("", "src").as_deref(), Some("src"));
        assert_eq!(resolve("a/b", "../c/./d").as_deref(), Some("a/c/d"));
        assert_eq!(resolve("a", "..").as_deref(), Some(""));
        assert_eq!(resolve("a", "../.."), None);
        assert_eq!(resolve("", "/etc/passwd"), None);
        assert_eq!(resolve("", ""), None);
        assert_eq!(resolve("", ".git/hooks"), None);
        assert_eq!(resolve("", "x/.GIT"), None);
        assert_eq!(resolve("", "a\nb"), None);
    }

    #[test]
    fn a_target_is_named_relative_from_the_links_folder() {
        assert_eq!(relative_from("", "src/a"), "src/a");
        assert_eq!(relative_from("a/b", "a/c"), "../c");
        assert_eq!(relative_from("a/b", ""), "../..");
        assert_eq!(relative_from("", ""), ".");
    }

    #[test]
    fn a_push_keeps_inside_links_and_names_the_rest() {
        let top = tempfile::tempdir().unwrap();
        let top = std::fs::canonicalize(top.path()).unwrap();
        std::fs::create_dir_all(top.join("src/deep")).unwrap();
        std::fs::create_dir_all(top.join(".git")).unwrap();
        std::fs::write(top.join("src/a.txt"), "a").unwrap();
        let link = |name: &str, target: &Path| {
            std::os::unix::fs::symlink(target, top.join(name)).unwrap();
            local(&top, name, &top.join(name)).unwrap()
        };
        assert_eq!(link("rel", Path::new("src/a.txt")), Local::Keep("src/a.txt".into()));
        assert_eq!(link("abs", &top.join("src/deep")), Local::Keep("src/deep".into()));
        assert_eq!(link("src/up", Path::new("../src/a.txt")), Local::Keep("../src/a.txt".into()));
        assert_eq!(link("out", Path::new("/etc")), Local::Skip(Why::SymlinkOutside));
        assert_eq!(link("climb", Path::new("../..")), Local::Skip(Why::SymlinkOutside));
        assert_eq!(link("gone", Path::new("nothing")), Local::Skip(Why::SymlinkBroken));
        assert_eq!(link("hooks", Path::new(".git")), Local::Skip(Why::SymlinkIntoRepository));
    }
}
