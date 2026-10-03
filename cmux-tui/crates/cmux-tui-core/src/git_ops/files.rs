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
    let (candidates, cut) = candidates(repository, directory)?;
    let mut ranked: Vec<Ranked> = candidates
        .iter()
        .filter_map(|path| {
            score(path, &query).map(|(score, matches)| Ranked { path, score, matches })
        })
        .collect();
    let total = ranked.len();
    ranked.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.path.len().cmp(&right.path.len()))
            .then_with(|| left.path.cmp(right.path))
    });
    ranked.truncate(limit);
    reply["results"] = ranked
        .iter()
        .map(|entry| json!({"path": entry.path, "matches": utf16_offsets(entry.path, &entry.matches)}))
        .collect();
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

/// The best alignment of `query` in `path`: its score and the matched
/// character indexes, or `None` when `path` does not contain every query
/// character in order (case-insensitively).
pub(super) fn score(path: &str, query: &[char]) -> Option<(i32, Vec<usize>)> {
    const MATCH: i32 = 16;
    const BOUNDARY: i32 = 8;
    const AFTER_SLASH: i32 = 10;
    const CONSECUTIVE: i32 = 8;
    const IN_NAME: i32 = 6;
    const GAP_START: i32 = 3;
    const GAP_EXTEND: i32 = 1;
    const NONE: i32 = i32::MIN / 2;

    let original: Vec<char> = path.chars().collect();
    if query.is_empty() || original.len() > MAX_RANKED_PATH_CHARS || query.len() > original.len() {
        return None;
    }
    let lower: Vec<char> = original.iter().map(|character| fold(*character)).collect();
    let wanted: Vec<char> = query.iter().map(|character| fold(*character)).collect();
    // Cheap rejection before the table.
    let mut next = 0;
    for character in &lower {
        if next < wanted.len() && *character == wanted[next] {
            next += 1;
        }
    }
    if next < wanted.len() {
        return None;
    }
    let name_start =
        original.iter().rposition(|character| *character == '/').map_or(0, |at| at + 1);
    let bonus = |at: usize| -> i32 {
        let mut bonus = MATCH;
        if at >= name_start {
            bonus += IN_NAME;
        }
        bonus += match at.checked_sub(1).map(|before| original[before]) {
            None => AFTER_SLASH,
            Some('/') => AFTER_SLASH,
            Some('_' | '-' | '.' | ' ') => BOUNDARY,
            Some(before) if before.is_lowercase() && original[at].is_uppercase() => BOUNDARY,
            Some(before) if !before.is_alphanumeric() => BOUNDARY,
            _ => 0,
        };
        bonus
    };

    let columns = original.len();
    // scores[i][j]: the best score of query[..=i] with query[i] at path[j].
    // from[i][j]: where query[i - 1] sat on that best alignment.
    let mut scores = vec![vec![NONE; columns]; wanted.len()];
    let mut from = vec![vec![usize::MAX; columns]; wanted.len()];
    for (j, character) in lower.iter().enumerate() {
        if *character == wanted[0] {
            scores[0][j] = bonus(j);
        }
    }
    for i in 1..wanted.len() {
        // The best previous-row score that leaves a gap before column j, with
        // its gap penalty already taken, and its column.
        let mut gap_best = NONE;
        let mut gap_from = usize::MAX;
        for j in 1..columns {
            if j >= 2 && scores[i - 1][j - 2] > NONE {
                let opened = scores[i - 1][j - 2] - GAP_START;
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
            let run =
                if scores[i - 1][j - 1] > NONE { scores[i - 1][j - 1] + CONSECUTIVE } else { NONE };
            let (best, previous) =
                if run >= gap_best { (run, j - 1) } else { (gap_best, gap_from) };
            if best > NONE {
                scores[i][j] = best + bonus(j);
                from[i][j] = previous;
            }
        }
    }
    let last = wanted.len() - 1;
    let (mut column, best) = scores[last]
        .iter()
        .enumerate()
        .filter(|(_, score)| **score > NONE)
        .max_by(|left, right| left.1.cmp(right.1).then_with(|| right.0.cmp(&left.0)))
        .map(|(column, score)| (column, *score))?;
    let mut matches = vec![0; wanted.len()];
    for i in (0..wanted.len()).rev() {
        matches[i] = column;
        if i > 0 {
            column = from[i][column];
        }
    }
    Some((best, matches))
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
