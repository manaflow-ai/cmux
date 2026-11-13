//! `git.files.search`: the files under a folder of a repository whose path
//! matches a query, best first, for @ mentions and the files palette.
//!
//! Candidates are the files git knows in the folder: tracked files that are
//! still in the working tree, and untracked files that no ignore rule hides.
//! A path below a link is not in the working tree and is no candidate.
//! The query matches as a case-insensitive subsequence of the path; the score
//! prefers matches in the file name, at word starts and in runs, and shorter
//! paths. `root` is the repository's top level, as in every git op; result
//! paths are relative to `search_root`, the folder searched, so an agent
//! working in that folder can use them as they are.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::run::run_git;
use super::work_tree_entry::{Kind, NoEntry, Tree};
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
    let search_root = folder(repository, directory, OPERATION)?;
    let mut reply = json!({
        "root": repository.root.to_string_lossy(),
        "search_root": search_root,
        "results": [],
        "truncated": false,
        "total_matches": 0,
    });
    if query.is_empty() {
        return Ok(reply);
    }
    let (candidates, mut cut) = candidates(repository, directory, &search_root, OPERATION)?;
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
    // A path below a link is no candidate; a folder that became a link after
    // that look is found here, and a path below it is never a result either.
    let mut folders = Folders::of(repository, &search_root);
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

/// The searched folder in the repository's own spelling: the top level joined
/// with git's prefix for `directory`, so a symlinked path reads as git sees it.
pub(super) fn folder(
    repository: &Repository,
    directory: &Path,
    operation: &'static str,
) -> Result<String, ResourceError> {
    let output = run_git(
        directory,
        &repository.overrides,
        &["rev-parse", "--show-prefix"],
        MAX_SMALL_OUTPUT_BYTES,
    )
    .map_err(|failure| git_failed(operation, &failure))?;
    let prefix = String::from_utf8_lossy(&output.stdout).trim_end_matches(['\n', '/']).to_string();
    let folder =
        if prefix.is_empty() { repository.root.clone() } else { repository.root.join(prefix) };
    Ok(folder.to_string_lossy().into_owned())
}

/// Says of a path that git lists under a folder of the work tree if it is a
/// real folder (a submodule). A link is never one, whatever its target is,
/// and a path below a link is not one: each folder above the path is opened
/// through its parent ([`super::work_tree_entry`]).
pub(super) struct Folders {
    tree: Option<Tree>,
    /// The listed folder, from the work tree's top folder.
    below: PathBuf,
    /// The folder of the last path that [`Self::below_a_link`] looked at,
    /// and its answer.
    last: Option<(String, bool)>,
}

impl Folders {
    /// For the paths that git lists under `listed`, the result of [`folder`].
    pub(super) fn of(repository: &Repository, listed: &str) -> Self {
        let (tree, below) = match Path::new(listed).strip_prefix(&repository.root) {
            Ok(below) => (Tree::open(&repository.root), below.to_path_buf()),
            Err(_) => (None, PathBuf::new()),
        };
        Self { tree, below, last: None }
    }

    /// True when a folder above `path`, relative to the listed folder, is a
    /// link: the path is not in the work tree. The listed folder is one of
    /// these folders, and so is each folder between it and the work tree's
    /// top folder. The paths of one folder follow each other in a listing,
    /// so the last answer serves them.
    fn below_a_link(&mut self, path: &str) -> bool {
        let folder = path.rsplit_once('/').map_or("", |(folder, _)| folder);
        if folder.is_empty() && self.below.as_os_str().is_empty() {
            // A name in the work tree's top folder has no folder above it.
            return false;
        }
        let known = self.last.as_ref().filter(|(last, _)| last.as_str() == folder);
        if let Some((_, answer)) = known {
            return *answer;
        }
        let answer = match self.tree.as_mut() {
            Some(tree) => matches!(tree.entry(&self.below.join(path)), Err(NoEntry::Link)),
            None => false,
        };
        self.last = Some((folder.to_owned(), answer));
        answer
    }

    /// What `path`, relative to the listed folder, is in the work tree.
    /// `None` when nothing has its name, or when a folder above it is not a
    /// real folder.
    pub(super) fn kind(&mut self, path: &str) -> Option<Kind> {
        self.tree.as_mut()?.entry(&self.below.join(path)).ok()?.kind()
    }

    /// True when `path`, relative to the listed folder, can be a search
    /// result: it is no real folder, and no folder above it is a link.
    fn file(&mut self, path: &str) -> bool {
        let Some(tree) = self.tree.as_mut() else { return true };
        match tree.entry(&self.below.join(path)) {
            Ok(entry) => entry.kind() != Some(Kind::Folder),
            Err(NoEntry::Link) => false,
            Err(NoEntry::NotFolder | NoEntry::Nothing) => true,
        }
    }
}

/// The files under `directory`, relative to it and sorted, and whether the
/// listing was cut. `under` is the result of [`folder`] for `directory`.
///
/// git looks at a tracked path by its name, so it lists a path below a link
/// when the link's target has that name. Such a path is not in the work tree
/// and is no candidate, whatever is behind the link.
pub(super) fn candidates(
    repository: &Repository,
    directory: &Path,
    under: &str,
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
    let mut folders = Folders::of(repository, under);
    let mut files: Vec<String> = parse::file_list(&bytes)
        .into_iter()
        .filter(|path| !deleted.contains(path) && !path.contains('\u{FFFD}'))
        .filter(|path| !folders.below_a_link(path))
        .collect();
    files.sort_unstable();
    files.dedup();
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
        let mut folders = Folders { tree: Tree::open(&root), below: PathBuf::new(), last: None };
        assert!(folders.tree.is_some(), "the work tree opens");
        assert!(folders.file("real/below.txt"), "a file below a real folder");
        assert!(!folders.file("dir/below.txt"), "a path below a link");
        assert!(folders.file("dir"), "the link itself is a leaf");
        assert!(!folders.file("real"), "a real folder is no file");
        fs::remove_dir_all(root).unwrap();
    }
}
