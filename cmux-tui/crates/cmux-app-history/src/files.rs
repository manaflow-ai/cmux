//! The right sidebar's file explorer (`FileExplorerModel.swift`): the rows
//! the tree shows, each row's git state, the folders git's changes sit in, a
//! path under the root, and whether a privacy-protected folder may be read.
//! Paths are absolute strings as Foundation's `URL.path` spells them; the app
//! lists folders and sorts each folder's entries (Finder's collation) itself.

use std::collections::{BTreeSet, HashMap, HashSet};

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// The state of a folder with a changed item somewhere inside (`FileGitState.containsChanges`).
pub const CONTAINS_CHANGES: &str = "containsChanges";

/// `NSString.appendingPathComponent`: one slash between, repeated slashes and a trailing one dropped.
pub fn append_component(base: &str, component: &str) -> String {
    let joined = if base.is_empty() {
        component.to_string()
    } else if component.is_empty() {
        base.to_string()
    } else {
        format!("{base}/{component}")
    };
    normalize_slashes(&joined)
}

fn normalize_slashes(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for c in path.chars() {
        if c == '/' && out.ends_with('/') {
            continue;
        }
        out.push(c);
    }
    if out.len() > 1 && out.ends_with('/') {
        out.pop();
    }
    out
}

/// `NSString.deletingLastPathComponent`: "/a/b" → "/a", "/a" → "/", "/" → "/", "a" → "".
pub fn deleting_last_component(path: &str) -> String {
    let path = normalize_slashes(path);
    if path == "/" {
        return path;
    }
    match path.rfind('/') {
        Some(0) => "/".to_string(),
        Some(index) => path[..index].to_string(),
        None => String::new(),
    }
}

/// `url`'s path under the root ("Sources/App.swift"); the full path outside it or without a root.
pub fn relative_path(root: Option<&str>, path: &str) -> String {
    let Some(root) = root else { return path.to_string() };
    let base = if root.ends_with('/') { root.to_string() } else { format!("{root}/") };
    path.strip_prefix(&base).unwrap_or(path).to_string()
}

/// Whether the root may be read: it is not privacy-protected, or the person asked
/// to see it or a folder holding it.
pub fn may_read(protected: bool, folder: &str, asked: &[String]) -> bool {
    !protected
        || asked.iter().any(|asked| folder == asked || folder.starts_with(&format!("{asked}/")))
}

/// One `git status` entry: the path under the repository's top and its state.
#[derive(Debug, Clone, Deserialize)]
pub struct StatusEntry {
    pub path: String,
    pub state: String,
}

/// Git's states by absolute path, and the folders (absolute) with a changed item inside.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct GitTree {
    pub states: HashMap<String, String>,
    pub folders: BTreeSet<String>,
}

/// The repository's states under `top` (symlinks resolved): each path's state,
/// and every folder between it and the top.
pub fn git_tree(top: &str, entries: &[StatusEntry]) -> GitTree {
    let top_count = top.graphemes(true).count();
    let mut tree = GitTree::default();
    for entry in entries {
        let path = append_component(top, &entry.path);
        let mut parent = deleting_last_component(&path);
        tree.states.insert(path, entry.state.clone());
        while parent.graphemes(true).count() > top_count && tree.folders.insert(parent.clone()) {
            parent = deleting_last_component(&parent);
        }
    }
    tree
}

/// A folder's entry as listed; hidden ones are left out by the app, the order is the app's.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub path: String,
    pub name: String,
    #[serde(default)]
    pub is_folder: bool,
}

/// What the tree's rows are built from.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tree {
    pub root: String,
    /// The root with symlinks resolved, the prefix git's paths share.
    #[serde(default)]
    pub resolved_root: String,
    /// Each listed folder's entries, in display order.
    #[serde(default)]
    pub children: HashMap<String, Vec<Entry>>,
    #[serde(default)]
    pub expanded: HashSet<String>,
    #[serde(default)]
    pub states: HashMap<String, String>,
    #[serde(default)]
    pub folders: HashSet<String>,
}

/// One visible row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub path: String,
    pub name: String,
    pub depth: usize,
    pub is_folder: bool,
    pub is_expanded: bool,
    pub git: Option<String>,
}

impl Tree {
    /// The git state of the item at `path` (under the root).
    pub fn git_state(&self, path: &str, is_folder: bool) -> Option<String> {
        let resolved =
            append_component(&self.resolved_root, &relative_path(Some(&self.root), path));
        if let Some(state) = self.states.get(&resolved) {
            return Some(state.clone());
        }
        (is_folder && self.folders.contains(&resolved)).then(|| CONTAINS_CHANGES.to_string())
    }

    /// The visible rows, in display order: each expanded folder's entries under it, one level deeper.
    pub fn rows(&self) -> Vec<Row> {
        let mut out = Vec::new();
        self.add(&self.root, 0, &mut out, &mut HashSet::new());
        out
    }

    fn add(&self, folder: &str, depth: usize, out: &mut Vec<Row>, open: &mut HashSet<String>) {
        for entry in self.children.get(folder).map(Vec::as_slice).unwrap_or_default() {
            let expanded = entry.is_folder && self.expanded.contains(&entry.path);
            out.push(Row {
                path: entry.path.clone(),
                name: entry.name.clone(),
                depth,
                is_folder: entry.is_folder,
                is_expanded: expanded,
                git: self.git_state(&entry.path, entry.is_folder),
            });
            // A folder listed inside itself (a cycle in the facts) is shown once, not walked again.
            if expanded && open.insert(entry.path.clone()) {
                self.add(&entry.path, depth + 1, out, open);
                open.remove(&entry.path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(path: &str, folder: bool) -> Entry {
        Entry {
            path: path.into(),
            name: path.rsplit('/').next().unwrap_or(path).into(),
            is_folder: folder,
        }
    }

    fn status(path: &str, state: &str) -> StatusEntry {
        StatusEntry { path: path.into(), state: state.into() }
    }

    #[test]
    fn path_components_follow_nsstring() {
        assert_eq!(append_component("/tmp", "a.txt"), "/tmp/a.txt");
        assert_eq!(append_component("/tmp/", "a.txt"), "/tmp/a.txt");
        assert_eq!(append_component("/", "a.txt"), "/a.txt");
        assert_eq!(append_component("", "a.txt"), "a.txt");
        assert_eq!(append_component("/tmp", ""), "/tmp");
        assert_eq!(append_component("/tmp", "dir/"), "/tmp/dir");
        assert_eq!(deleting_last_component("/tmp/a/b.txt"), "/tmp/a");
        assert_eq!(deleting_last_component("/tmp/lock/"), "/tmp");
        assert_eq!(deleting_last_component("/tmp"), "/");
        assert_eq!(deleting_last_component("/"), "/");
        assert_eq!(deleting_last_component("a.txt"), "");
    }

    #[test]
    fn relative_path_under_and_outside_the_root() {
        assert_eq!(relative_path(Some("/r"), "/r/Sources/App.swift"), "Sources/App.swift");
        assert_eq!(relative_path(Some("/r/"), "/r/a"), "a");
        assert_eq!(relative_path(Some("/r"), "/rx/a"), "/rx/a");
        assert_eq!(relative_path(Some("/r"), "/r"), "/r");
        assert_eq!(relative_path(None, "/r/a"), "/r/a");
    }

    #[test]
    fn a_protected_folder_reads_only_once_asked() {
        let asked = vec!["/Users/me/Downloads".to_string()];
        assert!(may_read(false, "/Users/me/Desktop", &[]));
        assert!(!may_read(true, "/Users/me/Desktop", &asked));
        assert!(may_read(true, "/Users/me/Downloads", &asked));
        assert!(may_read(true, "/Users/me/Downloads/x", &asked));
        assert!(!may_read(true, "/Users/me/DownloadsX", &asked));
    }

    #[test]
    fn git_tree_marks_every_folder_up_to_the_top() {
        let tree = git_tree(
            "/repo",
            &[
                status("a/b/c.txt", "modified"),
                status("a/d.txt", "added"),
                status("top.txt", "untracked"),
            ],
        );
        assert_eq!(tree.states.get("/repo/a/b/c.txt").map(String::as_str), Some("modified"));
        assert_eq!(tree.states.get("/repo/top.txt").map(String::as_str), Some("untracked"));
        assert_eq!(tree.folders.iter().cloned().collect::<Vec<_>>(), vec!["/repo/a", "/repo/a/b"]);
        assert_eq!(git_tree("/repo", &[]), GitTree::default());
    }

    fn sample() -> Tree {
        let mut children = HashMap::new();
        children.insert(
            "/r".to_string(),
            vec![entry("/r/src", true), entry("/r/docs", true), entry("/r/README", false)],
        );
        children.insert(
            "/r/src".to_string(),
            vec![entry("/r/src/lib", true), entry("/r/src/main.rs", false)],
        );
        children.insert("/r/src/lib".to_string(), vec![entry("/r/src/lib/x.rs", false)]);
        Tree {
            root: "/r".into(),
            resolved_root: "/private/r".into(),
            children,
            expanded: ["/r/src".to_string()].into(),
            states: [
                ("/private/r/src/main.rs".to_string(), "modified".to_string()),
                ("/private/r/docs".to_string(), "untracked".to_string()),
            ]
            .into(),
            folders: ["/private/r/src".to_string()].into(),
        }
    }

    #[test]
    fn rows_flatten_expanded_folders_with_git_states() {
        let rows = sample().rows();
        let shown: Vec<(&str, usize, bool, Option<&str>)> = rows
            .iter()
            .map(|row| (row.path.as_str(), row.depth, row.is_expanded, row.git.as_deref()))
            .collect();
        assert_eq!(
            shown,
            vec![
                ("/r/src", 0, true, Some(CONTAINS_CHANGES)),
                ("/r/src/lib", 1, false, None),
                ("/r/src/main.rs", 1, false, Some("modified")),
                ("/r/docs", 0, false, Some("untracked")),
                ("/r/README", 0, false, None),
            ]
        );
        assert_eq!(rows[0].name, "src");
    }

    #[test]
    fn a_file_is_never_contains_changes_and_an_unlisted_folder_shows_nothing() {
        let mut tree = sample();
        tree.folders.insert("/private/r/README".into());
        tree.expanded.insert("/r/docs".into());
        let rows = tree.rows();
        let readme = rows.iter().find(|row| row.path == "/r/README").map(|row| row.git.clone());
        assert_eq!(readme, Some(None));
        // docs is expanded but not listed: no rows under it.
        let docs = rows.iter().position(|row| row.path == "/r/docs").unwrap_or_default();
        assert_eq!(rows[docs + 1].path, "/r/README");
        assert!(Tree::default().rows().is_empty());
    }

    #[test]
    fn a_folder_listed_inside_itself_is_walked_once() {
        let mut children = HashMap::new();
        children.insert("/r".to_string(), vec![entry("/r/a", true)]);
        children.insert("/r/a".to_string(), vec![entry("/r/a", true)]);
        let tree = Tree {
            root: "/r".into(),
            children,
            expanded: ["/r/a".to_string()].into(),
            ..Tree::default()
        };
        assert_eq!(tree.rows().len(), 2);
    }
}
