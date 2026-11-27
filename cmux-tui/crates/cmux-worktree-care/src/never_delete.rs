//! What care never deletes, whatever a family says. Three sources, merged:
//!
//! - the fleet's own list (glaeda-disk's `NEVER_DELETE`: the browser fleet,
//!   the release builder's warm trees, siso), built in;
//! - `/etc/cmux/care-never-delete`, for a machine's owner;
//! - `~/.cmux/care-never-delete`, the user's file: one glob per line,
//!   `#` starts a comment. A glob starting with `~/` is under the home
//!   folder; one with no `/` matches any entry with that name; `*` is any
//!   run of characters inside one path part, `**` any run of parts, `?` one
//!   character. A path is kept when it matches a glob, or lies inside a
//!   folder that does.
//!
//! A file that cannot be read keeps nothing extra but is reported by
//! [`NeverDelete::load`]'s second value, so a status can say so.

use std::path::{Path, PathBuf};

/// Home-relative folders glaeda-disk never deletes.
const FLEET_HOME: &[&str] =
    &["cmux-browser-fleet", "Library/Caches/cmux-release-support", "Library/Caches/siso"];
/// Names glaeda-disk never deletes (case-insensitive substrings).
const FLEET_NAMES: &[&str] =
    &["chromium", "cmux-browser", "siso", "depot_tools", "cmux-release-support", "vpython", "cipd"];

#[derive(Debug, Clone, Default)]
pub struct NeverDelete {
    globs: Vec<String>,
    problems: Vec<String>,
}

impl NeverDelete {
    /// The built-in list plus the machine's and the user's files. The
    /// second value says which files could not be read.
    pub fn load(home: &Path) -> (Self, Vec<String>) {
        let mut globs = Vec::new();
        for folder in FLEET_HOME {
            globs.push(format!("~/{folder}"));
        }
        let mut problems = Vec::new();
        let files = [PathBuf::from("/etc/cmux/care-never-delete"), user_file(home)];
        for file in files {
            match std::fs::read_to_string(&file) {
                Ok(text) => globs.extend(parse(&text)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => problems.push(format!("{}: {e}", file.display())),
            }
        }
        (Self { globs, problems: problems.clone() }, problems)
    }

    /// From glob lines, for a caller that has them already.
    pub fn from_globs(globs: impl IntoIterator<Item = String>) -> Self {
        Self { globs: globs.into_iter().collect(), problems: Vec::new() }
    }

    /// Why `path` must stay, if it must: the glob or name that holds it.
    pub fn holds(&self, home: &Path, path: &Path) -> Option<String> {
        if let Some(problem) = self.problems.first() {
            return Some(format!("could not read protection rules: {problem}"));
        }
        let text = path.to_string_lossy();
        if let Some(name) = text.rsplit('/').find(|part| !part.is_empty()) {
            let lower = text.to_ascii_lowercase();
            let _ = name;
            if let Some(hit) = FLEET_NAMES.iter().find(|n| {
                path.components()
                    .any(|c| c.as_os_str().to_string_lossy().to_ascii_lowercase().contains(*n))
                    && lower.contains(*n)
            }) {
                return Some(format!("its name has {hit}"));
            }
        }
        for glob in &self.globs {
            if matches_glob(glob, home, path) {
                return Some(glob.clone());
            }
        }
        None
    }

    /// A recursive deletion must preserve protected descendants too. An
    /// incomplete inspection keeps the candidate; links are never followed.
    pub fn holds_tree(&self, home: &Path, path: &Path) -> Option<String> {
        self.inspect_tree(
            home,
            path,
            100_000,
            std::time::Instant::now() + std::time::Duration::from_secs(1),
        )
    }

    fn inspect_tree(
        &self,
        home: &Path,
        path: &Path,
        mut remaining: usize,
        deadline: std::time::Instant,
    ) -> Option<String> {
        let mut inspect = || -> Result<Option<String>, String> {
            if let Some(why) = self.holds(home, path) {
                return Ok(Some(why));
            }
            if !std::fs::symlink_metadata(path).map_err(|e| e.to_string())?.is_dir() {
                return Ok(None);
            }
            let mut stack = vec![std::fs::read_dir(path).map_err(|e| e.to_string())?];
            while !stack.is_empty() {
                if remaining == 0 || std::time::Instant::now() >= deadline || stack.len() > 64 {
                    return Err("descendant inspection limit reached".into());
                }
                let Some(entry) = stack.last_mut().and_then(Iterator::next) else {
                    stack.pop();
                    continue;
                };
                remaining -= 1;
                let entry = entry.map_err(|e| e.to_string())?;
                if let Some(why) = self.holds(home, &entry.path()) {
                    return Ok(Some(why));
                }
                if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
                    stack.push(std::fs::read_dir(entry.path()).map_err(|e| e.to_string())?);
                }
            }
            Ok(None)
        };
        match inspect() {
            Ok(why) => why,
            Err(error) => Some(format!("cannot rule out protected descendants: {error}")),
        }
    }

    pub fn len(&self) -> usize {
        self.globs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.globs.is_empty()
    }
}

/// Nothing held but the built-in names; for tests and callers with no home.
pub static NONE: NeverDelete = NeverDelete { globs: Vec::new(), problems: Vec::new() };

pub fn user_file(home: &Path) -> PathBuf {
    home.join(".cmux/care-never-delete")
}

fn parse(text: &str) -> Vec<String> {
    text.lines()
        .map(|line| line.split('#').next().unwrap_or("").trim().to_string())
        .filter(|line| !line.is_empty())
        .collect()
}

/// Whether `glob` holds `path`: `path` or any folder above it matches.
fn matches_glob(glob: &str, home: &Path, path: &Path) -> bool {
    let absolute = if let Some(rest) = glob.strip_prefix("~/") {
        home.join(rest).to_string_lossy().into_owned()
    } else {
        glob.to_string()
    };
    let by_name = !absolute.contains('/');
    let mut current = Some(path);
    while let Some(candidate) = current {
        let subject = if by_name {
            candidate.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
        } else {
            candidate.to_string_lossy().into_owned()
        };
        if !subject.is_empty() && glob_match(&absolute, &subject) {
            return true;
        }
        current = candidate.parent();
    }
    false
}

/// `*` within a part, `**` across parts, `?` one character.
fn glob_match(glob: &str, text: &str) -> bool {
    let (g, t): (Vec<char>, Vec<char>) = (glob.chars().collect(), text.chars().collect());
    fn go(g: &[char], t: &[char]) -> bool {
        match g.split_first() {
            None => t.is_empty(),
            Some(('*', rest)) => {
                let (deep, rest) = match rest.split_first() {
                    Some(('*', after)) => (true, after),
                    _ => (false, rest),
                };
                (0..=t.len()).any(|n| {
                    let skipped = t.get(..n).unwrap_or(&[]);
                    (deep || !skipped.contains(&'/')) && go(rest, t.get(n..).unwrap_or(&[]))
                })
            }
            Some(('?', rest)) => {
                t.split_first().is_some_and(|(c, tail)| *c != '/' && go(rest, tail))
            }
            Some((c, rest)) => t.split_first().is_some_and(|(d, tail)| c == d && go(rest, tail)),
        }
    }
    go(&g, &t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::care_tests::scratch;

    #[test]
    fn globs_match_within_parts_and_across_them() {
        assert!(glob_match("/h/*/cache", "/h/a/cache"));
        assert!(!glob_match("/h/*/cache", "/h/a/b/cache"));
        assert!(glob_match("/h/**/cache", "/h/a/b/cache"));
        assert!(glob_match("/h/a?", "/h/ab"));
        assert!(!glob_match("/h/a?", "/h/a/"));
    }

    #[test]
    fn the_fleet_list_and_a_users_file_both_keep_things_with_a_reason() {
        let home = scratch("never");
        std::fs::create_dir_all(user_file(&home).parent().unwrap()).unwrap();
        std::fs::write(
            user_file(&home),
            "# mine\n~/keep/me  # trailing\nprecious-*\n/srv/**/golden\n",
        )
        .unwrap();
        let (never, problems) = NeverDelete::load(&home);
        assert!(problems.is_empty(), "{problems:?}");
        // Fleet entries.
        assert!(never.holds(&home, &home.join("cmux-browser-fleet/x")).is_some());
        assert!(never.holds(&home, &home.join("Library/Caches/siso")).is_some());
        assert!(never.holds(&home, &home.join("work/depot_tools/out")).is_some());
        // The user's: a folder and everything in it, a by-name glob, an absolute deep glob.
        let held = never.holds(&home, &home.join("keep/me/deep/file")).expect("held");
        assert!(held.contains("keep/me"), "{held}");
        assert!(never.holds(&home, &home.join("x/precious-data/a")).is_some());
        assert!(never.holds(&home, Path::new("/srv/a/b/golden/x")).is_some());
        // Others go on as before.
        assert!(never.holds(&home, &home.join(".npm/_cacache")).is_none());
        assert!(never.holds(&home, &home.join("keep/other")).is_none());
    }

    #[test]
    fn recursive_protection_is_bounded_and_fails_closed() {
        use std::time::{Duration, Instant};
        let home = scratch("never-tree");
        let tree = home.join("tree");
        std::fs::create_dir_all(tree.join("nested")).unwrap();
        std::fs::write(tree.join("nested/keep.txt"), "precious").unwrap();
        for glob in ["~/tree/nested/keep.txt", "keep.*", "~/tree/**/keep.txt"] {
            let never = NeverDelete::from_globs([glob.into()]);
            assert!(never.holds_tree(&home, &tree).is_some(), "{glob}");
        }
        assert!(NONE.holds_tree(&home, &tree).is_none());
        assert!(
            NONE.inspect_tree(&home, &tree, 0, Instant::now() + Duration::from_secs(1)).is_some()
        );
        assert!(NONE.inspect_tree(&home, &tree, 100, Instant::now()).is_some());
        assert!(NONE.holds_tree(&home, &home.join("missing")).is_some());
        std::fs::create_dir(tree.join("nested/depot_tools")).unwrap();
        assert!(NONE.holds_tree(&home, &tree).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn recursive_protection_does_not_follow_links_outside_the_tree() {
        let home = scratch("never-tree-link");
        let tree = home.join("tree");
        std::fs::create_dir(&tree).unwrap();
        std::fs::create_dir(home.join("outside")).unwrap();
        std::fs::write(home.join("outside/keep.txt"), "precious").unwrap();
        std::os::unix::fs::symlink(home.join("outside"), tree.join("link")).unwrap();
        let never = NeverDelete::from_globs(["keep.txt".into()]);
        assert!(never.holds_tree(&home, &tree).is_none());
    }

    #[test]
    fn an_unreadable_file_is_reported_not_fatal() {
        let home = scratch("never-bad");
        std::fs::create_dir_all(home.join(".cmux/care-never-delete")).unwrap();
        let (never, problems) = NeverDelete::load(&home);
        assert_eq!(problems.len(), 1);
        assert!(!never.is_empty());
        assert!(never.holds(&home, &home.join("anything")).is_some());
    }
}
