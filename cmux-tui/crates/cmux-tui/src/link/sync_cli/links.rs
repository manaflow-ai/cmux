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

use std::collections::VecDeque;
use std::path::Path;

use super::Linked;
use super::names;
use super::skips::Why;

/// Most symlinks one check follows (Linux's `MAXSYMLINKS`).
const MAX_HOPS: usize = 40;
/// Most steps one check takes over every branch it follows.
const MAX_STEPS: usize = 4096;

/// What a push does with the symlink at a path of this Mac's folder.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Local {
    /// Kept: the text the machine gets, and this Mac's own when it differs.
    Keep(Linked),
    Skip(Why),
}

/// The symlink at `path` (`relative` in the folder `top`, canonical). A copy
/// reads the text through its folder's descriptor instead ([`local_with`]).
#[cfg(test)]
pub(super) fn local(top: &Path, relative: &str, path: &Path) -> std::io::Result<Local> {
    let text = std::fs::read_link(path)?;
    let Some(text) = text.to_str() else { return Ok(Local::Skip(Why::NameNotUtf8)) };
    local_with(top, relative, path, text)
}

/// [`local`] for the symlink whose text `text` was read already (through the
/// descriptor of the folder holding it).
pub(super) fn local_with(
    top: &Path,
    relative: &str,
    path: &Path,
    text: &str,
) -> std::io::Result<Local> {
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
        return Ok(Local::Keep(Linked { target: text.to_string(), here: None }));
    }
    Ok(Local::Keep(Linked { target: relative_from(parent, below), here: Some(text.to_string()) }))
}

/// Whether the link text `text` in the folder `parent` stays inside the top
/// when every symlink on its way is followed: `links_at(path)` names the
/// texts of the symlinks at `path` (relative to the top) on either side,
/// and each one met is followed (all of them, when the sides differ). An
/// absolute text, a climb above the top, a repository folder, too many hops
/// or too many steps is outside. A path with no symlink counts as a folder.
pub(super) fn reaches_inside(
    parent: &str,
    text: &str,
    links_at: &dyn Fn(&str) -> Vec<String>,
) -> bool {
    let stack: Vec<String> =
        parent.split('/').filter(|part| !part.is_empty()).map(str::to_string).collect();
    let mut steps = 0;
    walk(stack, parts_of(text), 0, links_at, &mut steps)
}

fn parts_of(text: &str) -> Option<VecDeque<String>> {
    if text.is_empty() || text.starts_with('/') || text.chars().any(char::is_control) {
        return None;
    }
    Some(text.split('/').map(str::to_string).collect())
}

fn walk(
    mut stack: Vec<String>,
    pending: Option<VecDeque<String>>,
    hops: usize,
    links_at: &dyn Fn(&str) -> Vec<String>,
    steps: &mut usize,
) -> bool {
    let Some(mut pending) = pending else { return false };
    while let Some(part) = pending.pop_front() {
        *steps += 1;
        if *steps > MAX_STEPS {
            return false;
        }
        match part.as_str() {
            "" | "." => continue,
            ".." => {
                if stack.pop().is_none() {
                    return false;
                }
                continue;
            }
            name if names::is_dotgit(name) => return false,
            _ => {}
        }
        let mut here = stack.clone();
        here.push(part);
        let texts = links_at(&here.join("/"));
        if texts.is_empty() {
            stack = here;
            continue;
        }
        if hops >= MAX_HOPS {
            return false;
        }
        return texts.iter().all(|text| {
            let spliced = parts_of(text).map(|mut parts| {
                parts.extend(pending.iter().cloned());
                parts
            });
            walk(stack.clone(), spliced, hops + 1, links_at, steps)
        });
    }
    true
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
    parts.extend(to.get(common..).unwrap_or_default());
    if parts.is_empty() { ".".to_string() } else { parts.join("/") }
}

#[cfg(test)]
mod tests;
