//! `git.files.search`: the files under a folder of a repository whose path
//! matches a query, best first, for @ mentions and the files palette.
//!
//! Candidates are the files git knows in the folder: tracked files that are
//! still in the working tree, and untracked files that no ignore rule hides.
//! git gives the names. The daemon itself looks if a name is there, through
//! real folders of the work tree only: a path that it cannot reach so is no
//! candidate (a path below a link, below a folder that cannot be opened, or
//! with too many folders above it).
//! The query matches as a case-insensitive subsequence of the path; the score
//! prefers matches in the file name, at word starts and in runs, and shorter
//! paths. `root` is the repository's top level, as in every git op; result
//! paths are relative to `search_root`, the folder searched, so an agent
//! working in that folder can use them as they are.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::run::run_git;
use super::work_tree_entry::{Kind, Tree};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, git_failed, parse};
use crate::resource::ResourceError;
use cmux_json::JsonSet as _;

const OPERATION: &str = "git.files.search";
/// The candidate listing stops here; a cut listing marks the reply truncated.
const MAX_LISTING_BYTES: usize = 32 * 1024 * 1024;
/// Longer paths are listed but never ranked: a quick-open never needs them,
/// and the scorer's table grows with the path.
const MAX_RANKED_PATH_CHARS: usize = 1024;
/// Score-table cells one search may fill: about a second of work. Past it
/// the remaining candidates go unranked and the reply is marked truncated.
const MAX_SCORED_CELLS: usize = 64 * 1024 * 1024;
pub(super) const DEFAULT_LIMIT: usize = 50;
pub(super) const MAX_LIMIT: usize = 200;

pub(super) fn search(
    repository: &Repository,
    directory: &Path,
    fields: &serde_json::Map<String, Value>,
) -> Result<Value, ResourceError> {
    let query: Vec<char> = fields
        .get("query")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect();
    let limit = fields
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(DEFAULT_LIMIT, |limit| usize::try_from(limit).unwrap_or(MAX_LIMIT))
        .clamp(1, MAX_LIMIT);
    let below = folder(repository, directory, OPERATION)?;
    let mut reply = json!({
        "root": repository.root.to_string_lossy(),
        "search_root": spelled(repository, &below),
        "results": [],
        "truncated": false,
        "total_matches": 0,
    });
    if query.is_empty() {
        return Ok(reply);
    }
    let (candidates, mut cut) = candidates(repository, directory, &below, OPERATION)?;
    let mut scorer = Scorer::new(&query, MAX_SCORED_CELLS);
    let mut ranked = Vec::new();
    for path in &candidates {
        match scorer.score(path) {
            Scored::Match(score, matches) => ranked.push(Ranked { path, score, matches }),
            Scored::NoMatch => {}
            Scored::OutOfBudget => {
                // The rest are unranked; say the results are partial.
                cut = true;
                break;
            }
        }
    }
    let total = ranked.len();
    ranked.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.path.len().cmp(&right.path.len()))
            .then_with(|| left.path.cmp(right.path))
    });
    // A submodule is listed as one path, but it is a folder: never a result.
    // Each candidate was reached through real folders. This second look asks
    // the same: a path below a folder that became a link after the look at
    // the candidates, or that cannot be reached now, is never a result.
    let mut folders = Folders::of(repository, &below);
    let results: Vec<Value> = ranked
        .iter()
        .filter(|entry| folders.file(entry.path))
        .take(limit)
        .map(|entry| {
            json!({"path": entry.path, "matches": utf16_offsets(entry.path, &entry.matches)})
        })
        .collect();
    reply.set("results", Value::Array(results));
    reply.set("truncated", json!(cut || total > limit));
    reply.set("total_matches", json!(u32::try_from(total).unwrap_or(u32::MAX)));
    Ok(reply)
}

struct Ranked<'a> {
    path: &'a str,
    score: i32,
    /// Character indexes into `path`.
    matches: Vec<usize>,
}

/// The searched folder, as a path from the work tree's top folder: git's
/// prefix for `directory`, so a symlinked path reads as git sees it. The top
/// folder itself is the empty path. The path has git's own bytes: a name
/// that is not UTF-8 stays the name that is on the disk.
pub(super) fn folder(
    repository: &Repository,
    directory: &Path,
    operation: &'static str,
) -> Result<PathBuf, ResourceError> {
    let output = run_git(
        directory,
        &repository.overrides,
        &["rev-parse", "--show-prefix"],
        MAX_SMALL_OUTPUT_BYTES,
    )
    .map_err(|failure| git_failed(operation, &failure))?;
    // git ends the prefix with one `/` and its line with one line break. A
    // folder's name can end with a line break too: no more is taken off.
    let prefix = output.stdout.as_slice();
    let prefix = prefix.strip_suffix(b"\n").unwrap_or(prefix);
    let prefix = prefix.strip_suffix(b"/").unwrap_or(prefix);
    Ok(path_of(prefix))
}

#[cfg(unix)]
fn path_of(bytes: &[u8]) -> PathBuf {
    use std::os::unix::ffi::OsStrExt as _;
    PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
}

/// A system that is not Unix has no path of bytes, and git gives UTF-8
/// there. Other bytes give a name that is not on the disk, and a path below
/// a name that is not there is no candidate.
#[cfg(not(unix))]
fn path_of(bytes: &[u8]) -> PathBuf {
    PathBuf::from(String::from_utf8_lossy(bytes).into_owned())
}

/// `below`, the result of [`folder`], in the repository's own spelling, for
/// a reply.
pub(super) fn spelled(repository: &Repository, below: &Path) -> String {
    let folder = if below.as_os_str().is_empty() {
        repository.root.clone()
    } else {
        repository.root.join(below)
    };
    folder.to_string_lossy().into_owned()
}

/// Looks at the paths that git lists under a folder of the work tree. Each
/// look goes through real folders only: each folder above a path is opened
/// through its parent, from the work tree's top folder, and a link is never
/// followed ([`super::work_tree_entry`]). The listed folder is one of these
/// folders, and so is each folder between it and the top folder.
pub(super) struct Folders {
    /// `None` when the work tree's top folder did not open: no look.
    tree: Option<Tree>,
    /// The listed folder, from the work tree's top folder.
    below: PathBuf,
}

impl Folders {
    /// For the paths that git lists under `below`, the result of [`folder`].
    pub(super) fn of(repository: &Repository, below: &Path) -> Self {
        Self { tree: Tree::open(&repository.root), below: below.to_path_buf() }
    }

    /// What `path`, relative to the listed folder, is in the work tree.
    /// `None` when nothing has its name, and when the daemon cannot reach
    /// the name through real folders: a folder above it is a link, is not
    /// there or cannot be opened, the path has too many folders, or there
    /// is no look at all. A path with no kind is no candidate and no result.
    pub(super) fn kind(&mut self, path: &str) -> Option<Kind> {
        self.tree.as_mut()?.entry(&self.below.join(path)).ok()?.kind()
    }

    /// True when `path`, relative to the listed folder, can be a search
    /// result: the daemon reaches it, and it is no real folder.
    fn file(&mut self, path: &str) -> bool {
        self.kind(path).is_some_and(|kind| kind != Kind::Folder)
    }
}

/// The files under `directory`, relative to it and sorted, and whether the
/// listing was cut. `below` is the result of [`folder`] for `directory`.
///
/// git gives the names: the paths of its index that it does not call
/// deleted, and the untracked names. git looks at a tracked path by its
/// name and so through a link, so the daemon looks itself
/// ([`Folders::kind`]): a candidate is a listed path that it reaches through
/// real folders and that has a name on the disk.
pub(super) fn candidates(
    repository: &Repository,
    directory: &Path,
    below: &Path,
    operation: &'static str,
) -> Result<(Vec<String>, bool), ResourceError> {
    // Run in the folder itself, so paths are relative to it and only files
    // under it are listed.
    let listing = ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."];
    let run = |arguments: &[&str]| {
        run_git(directory, &repository.overrides, arguments, MAX_LISTING_BYTES)
            .map_err(|failure| git_failed(operation, &failure))
    };
    let listed = run(&listing)?;
    let mut bytes = listed.stdout;
    if listed.truncated {
        // The last path may be cut mid-name.
        let end = bytes.iter().rposition(|byte| *byte == 0).map_or(0, |end| end + 1);
        bytes.truncate(end);
    }
    let deleted = run(&["ls-files", "-z", "--deleted", "--", "."])?;
    let deleted: HashSet<String> = parse::file_list(&deleted.stdout).into_iter().collect();
    let mut files = parse::file_list(&bytes);
    // Sorted, the paths of one folder follow each other: the look opens each
    // folder one time.
    files.sort_unstable();
    files.dedup();
    let mut folders = Folders::of(repository, below);
    files.retain(|path| {
        !deleted.contains(path) && !path.contains('\u{FFFD}') && folders.kind(path).is_some()
    });
    Ok((files, listed.truncated))
}

/// What scoring one path found.
pub(super) enum Scored {
    /// The score and the matched character indexes, ascending.
    Match(i32, Vec<usize>),
    NoMatch,
    /// The search's work budget is spent; this path was not scored.
    OutOfBudget,
}

/// Scores paths against one query, reusing its tables across paths and
/// stopping when a whole search has filled its budget of table cells.
pub(super) struct Scorer {
    wanted: Vec<char>,
    original: Vec<char>,
    lower: Vec<char>,
    /// Row-major `wanted.len()` x columns: the best score of query[..=i]
    /// with query[i] at path[j].
    scores: Vec<i32>,
    /// Where query[i - 1] sat on that best alignment.
    from: Vec<usize>,
    cells_left: usize,
}

const MATCH: i32 = 16;
const BOUNDARY: i32 = 8;
const AFTER_SLASH: i32 = 10;
const CONSECUTIVE: i32 = 8;
const IN_NAME: i32 = 6;
const GAP_START: i32 = 3;
const GAP_EXTEND: i32 = 1;
const NONE: i32 = i32::MIN / 2;

impl Scorer {
    pub(super) fn new(query: &[char], budget: usize) -> Self {
        Self {
            wanted: query.iter().map(|character| fold(*character)).collect(),
            original: Vec::new(),
            lower: Vec::new(),
            scores: Vec::new(),
            from: Vec::new(),
            cells_left: budget,
        }
    }

    /// The best alignment of the query in `path`, or `NoMatch` when `path`
    /// does not contain every query character in order (case-insensitively).
    pub(super) fn score(&mut self, path: &str) -> Scored {
        let rows = self.wanted.len();
        self.original.clear();
        self.original.extend(path.chars());
        let columns = self.original.len();
        if rows == 0 || columns > MAX_RANKED_PATH_CHARS || rows > columns {
            return Scored::NoMatch;
        }
        self.lower.clear();
        self.lower.extend(self.original.iter().map(|character| fold(*character)));
        // Cheap rejection before the table.
        let mut next = 0;
        for character in &self.lower {
            if next < rows && *character == self.wanted[next] {
                next += 1;
            }
        }
        if next < rows {
            return Scored::NoMatch;
        }
        let cells = rows * columns;
        if cells > self.cells_left {
            return Scored::OutOfBudget;
        }
        self.cells_left -= cells;
        self.scores.clear();
        self.scores.resize(cells, NONE);
        self.from.clear();
        self.from.resize(cells, usize::MAX);
        let (original, lower, wanted) = (&self.original, &self.lower, &self.wanted);
        let (scores, from) = (&mut self.scores, &mut self.from);
        let name_start =
            original.iter().rposition(|character| *character == '/').map_or(0, |at| at + 1);
        let bonus = |at: usize| -> i32 {
            let mut bonus = MATCH;
            if at >= name_start {
                bonus += IN_NAME;
            }
            bonus += match at.checked_sub(1).map(|before| original[before]) {
                None | Some('/') => AFTER_SLASH,
                Some('_' | '-' | '.' | ' ') => BOUNDARY,
                Some(before) if before.is_lowercase() && original[at].is_uppercase() => BOUNDARY,
                Some(before) if !before.is_alphanumeric() => BOUNDARY,
                _ => 0,
            };
            bonus
        };
        let at = |row: usize, column: usize| row * columns + column;
        for (j, character) in lower.iter().enumerate() {
            if *character == wanted[0] {
                scores[at(0, j)] = bonus(j);
            }
        }
        for i in 1..rows {
            // The best previous-row score that leaves a gap before column j,
            // with its gap penalty already taken, and its column.
            let mut gap_best = NONE;
            let mut gap_from = usize::MAX;
            for j in 1..columns {
                if j >= 2 && scores[at(i - 1, j - 2)] > NONE {
                    let opened = scores[at(i - 1, j - 2)] - GAP_START;
                    let extended = gap_best - GAP_EXTEND;
                    if opened >= extended {
                        gap_best = opened;
                        gap_from = j - 2;
                    } else {
                        gap_best = extended;
                    }
                } else if gap_best > NONE {
                    gap_best -= GAP_EXTEND;
                }
                if lower[j] != wanted[i] {
                    continue;
                }
                let diagonal = scores[at(i - 1, j - 1)];
                let run = if diagonal > NONE { diagonal + CONSECUTIVE } else { NONE };
                let (best, previous) =
                    if run >= gap_best { (run, j - 1) } else { (gap_best, gap_from) };
                if best > NONE {
                    scores[at(i, j)] = best + bonus(j);
                    from[at(i, j)] = previous;
                }
            }
        }
        let last = rows - 1;
        let Some((mut column, best)) = (0..columns)
            .map(|j| (j, scores[at(last, j)]))
            .filter(|(_, score)| *score > NONE)
            .max_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(&left.0)))
        else {
            return Scored::NoMatch;
        };
        let mut matches = vec![0; rows];
        for i in (0..rows).rev() {
            matches[i] = column;
            if i > 0 {
                column = from[at(i, column)];
            }
        }
        Scored::Match(best, matches)
    }
}

fn fold(character: char) -> char {
    character.to_lowercase().next().unwrap_or(character)
}

/// Character indexes as UTF-16 offsets, the way the page indexes a string.
fn utf16_offsets(path: &str, matches: &[usize]) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(matches.len());
    let mut wanted = matches.iter().peekable();
    let mut offset = 0;
    for (index, character) in path.chars().enumerate() {
        while wanted.peek() == Some(&&index) {
            offsets.push(offset);
            wanted.next();
        }
        offset += character.len_utf16();
    }
    offsets
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;

    use super::*;

    /// A work tree with the file `below.txt` in the folder `real`, and the
    /// link `dir` to that folder.
    fn tree_with_a_link() -> PathBuf {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let root = std::env::temp_dir().join(format!("cmux-files-second-look-{hex}"));
        fs::create_dir_all(root.join("real")).unwrap();
        fs::write(root.join("real/below.txt"), "below").unwrap();
        std::os::unix::fs::symlink("real", root.join("dir")).unwrap();
        root
    }

    /// The second look of a search, with no candidate filter before it: the
    /// state of a folder that became a link after the look at the candidates.
    #[test]
    fn the_second_look_of_a_search_gives_no_path_below_a_link() {
        let root = tree_with_a_link();
        let mut folders = Folders { tree: Tree::open(&root), below: PathBuf::new() };
        assert!(folders.tree.is_some(), "the work tree opens");
        assert!(folders.file("real/below.txt"), "a file below a real folder");
        assert!(!folders.file("dir/below.txt"), "a path below a link");
        assert!(folders.file("dir"), "the link itself is a leaf");
        assert!(!folders.file("real"), "a real folder is no file");
        fs::remove_dir_all(root).unwrap();
    }

    /// The second look gives no path that it cannot look at: a folder above
    /// the path is not there, nothing has the path's name, or the work tree
    /// did not open.
    #[test]
    fn the_second_look_of_a_search_gives_no_path_that_it_cannot_reach() {
        let root = tree_with_a_link();
        let mut folders = Folders { tree: Tree::open(&root), below: PathBuf::new() };
        assert!(folders.tree.is_some(), "the work tree opens");
        let below_nothing = folders.file("none/below.txt");
        let no_name = folders.file("real/none.txt");
        let mut no_tree = Folders { tree: None, below: PathBuf::new() };
        let no_work_tree = no_tree.file("real/below.txt");
        fs::remove_dir_all(root).unwrap();
        assert!(!below_nothing, "a path below a folder that is not there");
        assert!(!no_name, "a name that is not there");
        assert!(!no_work_tree, "a work tree that did not open");
    }
}
