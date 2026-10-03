//! `git.files.search`: the files under a folder of a repository whose path
//! matches a query, best first, for @ mentions and the files palette.
//!
//! Candidates are the files git knows in the folder: tracked files that are
//! still in the working tree, and untracked files that no ignore rule hides.
//! The query matches as a case-insensitive subsequence of the path; the score
//! prefers matches in the file name, at word starts and in runs, and shorter
//! paths. `root` is the repository's top level, as in every git op; result
//! paths are relative to `search_root`, the folder searched, so an agent
//! working in that folder can use them as they are.

use std::collections::HashSet;
use std::path::Path;

use serde_json::{Value, json};

use super::run::run_git;
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, git_failed, parse};
use crate::resource::ResourceError;

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
    let search_root = folder(repository, directory)?;
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
    let (candidates, mut cut) = candidates(repository, directory)?;
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
    let search_folder = Path::new(&search_root);
    let results: Vec<Value> = ranked
        .iter()
        .filter(|entry| !search_folder.join(entry.path).is_dir())
        .take(limit)
        .map(|entry| {
            json!({"path": entry.path, "matches": utf16_offsets(entry.path, &entry.matches)})
        })
        .collect();
    reply["results"] = Value::Array(results);
    reply["truncated"] = json!(cut || total > limit);
    reply["total_matches"] = json!(u32::try_from(total).unwrap_or(u32::MAX));
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
fn folder(repository: &Repository, directory: &Path) -> Result<String, ResourceError> {
    let output = run_git(
        directory,
        &repository.overrides,
        &["rev-parse", "--show-prefix"],
        MAX_SMALL_OUTPUT_BYTES,
    )
    .map_err(|failure| git_failed(OPERATION, &failure))?;
    let prefix = String::from_utf8_lossy(&output.stdout).trim_end_matches(['\n', '/']).to_string();
    let folder =
        if prefix.is_empty() { repository.root.clone() } else { repository.root.join(prefix) };
    Ok(folder.to_string_lossy().into_owned())
}

/// The files under `directory`, relative to it and sorted, and whether the
/// listing was cut.
fn candidates(
    repository: &Repository,
    directory: &Path,
) -> Result<(Vec<String>, bool), ResourceError> {
    // Run in the folder itself, so paths are relative to it and only files
    // under it are listed.
    let listing = ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."];
    let run = |arguments: &[&str]| {
        run_git(directory, &repository.overrides, arguments, MAX_LISTING_BYTES)
            .map_err(|failure| git_failed(OPERATION, &failure))
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
    let mut files: Vec<String> = parse::file_list(&bytes)
        .into_iter()
        .filter(|path| !deleted.contains(path) && !path.contains('\u{FFFD}'))
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

/// One path's score with a fresh scorer; for tests.
#[cfg(test)]
pub(super) fn score(path: &str, query: &[char]) -> Option<(i32, Vec<usize>)> {
    match Scorer::new(query, usize::MAX).score(path) {
        Scored::Match(score, matches) => Some((score, matches)),
        Scored::NoMatch | Scored::OutOfBudget => None,
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
