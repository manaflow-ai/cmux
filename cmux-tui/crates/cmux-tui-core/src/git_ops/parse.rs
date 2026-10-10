//! Parsers for git's machine output: `diff --name-status -z`, `diff --numstat
//! -z`, a unified patch split per file, and `status --porcelain=v2 --branch`
//! headers.

use std::collections::HashMap;

/// One changed file from `git diff --name-status -z`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct NameStatus {
    pub path: String,
    pub previous_path: Option<String>,
    pub status: &'static str,
}

/// Added and deleted line counts from `git diff --numstat -z`; `None` for a
/// binary file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct LineCounts {
    pub additions: u64,
    pub deletions: u64,
}

pub(super) fn name_status(bytes: &[u8]) -> Vec<NameStatus> {
    let mut tokens = tokens(bytes);
    let mut files = Vec::new();
    while let Some(code) = tokens.next() {
        if code.is_empty() {
            continue;
        }
        // Renames and copies name the old path, then the new one.
        let paired = code.starts_with('R') || code.starts_with('C');
        let Some(first) = tokens.next() else { break };
        let (previous_path, path) = if paired {
            let Some(second) = tokens.next() else { break };
            (Some(first), second)
        } else {
            (None, first)
        };
        let (status, previous_path) = match code.as_bytes()[0] {
            b'A' => ("added", None),
            b'D' => ("deleted", None),
            b'R' => ("renamed", previous_path),
            // A copy is a new file; its source is unchanged.
            b'C' => ("added", None),
            _ => ("modified", None),
        };
        files.push(NameStatus { path, previous_path, status });
    }
    files
}

/// Counts by the file's (new) path.
pub(super) fn numstat(bytes: &[u8]) -> HashMap<String, Option<LineCounts>> {
    let mut tokens = tokens(bytes);
    let mut counts = HashMap::new();
    while let Some(token) = tokens.next() {
        if token.is_empty() {
            continue;
        }
        let mut fields = token.splitn(3, '\t');
        let (Some(additions), Some(deletions), Some(path)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        // A rename leaves the path empty and names old, then new, next.
        let path = if path.is_empty() {
            let _old = tokens.next();
            match tokens.next() {
                Some(new) => new,
                None => break,
            }
        } else {
            path.to_string()
        };
        let lines = match (additions.parse(), deletions.parse()) {
            (Ok(additions), Ok(deletions)) => Some(LineCounts { additions, deletions }),
            _ => None,
        };
        counts.insert(path, lines);
    }
    counts
}

/// Each file's patch from its first `@@` line, in output order, with the path
/// its `+++` (or, for a deletion, `---`) line names. A file without hunks
/// (binary, mode-only or an exact rename) has no entry. The diff must use the
/// `a/` and `b/` prefixes.
pub(super) fn patches(bytes: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(bytes);
    let mut patches = Vec::new();
    let mut section: Vec<&str> = Vec::new();
    for line in text.split_inclusive('\n') {
        if is_section_start(line) && !section.is_empty() {
            insert_section(&mut patches, &section);
            section.clear();
        }
        section.push(line);
    }
    if !section.is_empty() {
        insert_section(&mut patches, &section);
    }
    patches
}

fn is_section_start(line: &str) -> bool {
    line.starts_with("diff --git ") || line.starts_with("diff --cc ")
}

fn insert_section(patches: &mut Vec<(String, String)>, section: &[&str]) {
    let Some(first_hunk) = section.iter().position(|line| line.starts_with("@@")) else {
        return;
    };
    let header = &section[..first_hunk];
    let path = header
        .iter()
        .find_map(|line| header_path(line, "+++ ", "b/"))
        .or_else(|| header.iter().find_map(|line| header_path(line, "--- ", "a/")));
    if let Some(path) = path {
        patches.push((path, section[first_hunk..].concat()));
    }
}

/// The path in a `--- a/x` or `+++ b/x` line, unquoted; `None` for
/// `/dev/null`.
fn header_path(line: &str, marker: &str, prefix: &str) -> Option<String> {
    let rest = line.strip_prefix(marker)?.trim_end_matches(['\n', '\r']);
    let name = if rest.starts_with('"') {
        unquote(rest)?
    } else {
        // git ends an unquoted name with a tab when it contains a space.
        rest.strip_suffix('\t').unwrap_or(rest).to_string()
    };
    name.strip_prefix(prefix).map(str::to_string)
}

/// Undoes git's C-style quoting of a path.
fn unquote(quoted: &str) -> Option<String> {
    let inner = quoted.strip_prefix('"')?;
    let mut bytes = Vec::new();
    let mut chars = inner.bytes();
    while let Some(byte) = chars.next() {
        match byte {
            b'"' => return String::from_utf8(bytes).ok(),
            b'\\' => {
                let escaped = chars.next()?;
                let value = match escaped {
                    b'n' => b'\n',
                    b't' => b'\t',
                    b'r' => b'\r',
                    b'a' => 0x07,
                    b'b' => 0x08,
                    b'f' => 0x0c,
                    b'v' => 0x0b,
                    b'0'..=b'7' => {
                        let second = chars.next()?;
                        let third = chars.next()?;
                        let digits = [escaped, second, third];
                        u8::from_str_radix(std::str::from_utf8(&digits).ok()?, 8).ok()?
                    }
                    other => other,
                };
                bytes.push(value);
            }
            other => bytes.push(other),
        }
    }
    None
}

/// Cuts a patch to at most `limit` bytes at a line end (or, for a single
/// long line, a character boundary). Returns whether it was cut.
pub(super) fn truncate_patch(patch: &mut String, limit: usize) -> bool {
    if patch.len() <= limit {
        return false;
    }
    let end = match patch.as_bytes()[..limit].iter().rposition(|byte| *byte == b'\n') {
        Some(newline) => newline + 1,
        None => {
            let mut end = limit;
            while !patch.is_char_boundary(end) {
                end -= 1;
            }
            end
        }
    };
    patch.truncate(end);
    true
}

/// The branch headers of `git status --porcelain=v2 --branch -z`.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct BranchHeaders {
    pub head: Option<String>,
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
}

pub(super) fn branch_headers(bytes: &[u8]) -> BranchHeaders {
    let mut headers = BranchHeaders::default();
    for token in tokens(bytes) {
        let Some(header) = token.strip_prefix("# branch.") else { continue };
        let Some((key, value)) = header.split_once(' ') else { continue };
        match key {
            "oid" if value != "(initial)" => headers.head = Some(value.to_string()),
            "head" if value != "(detached)" => headers.branch = Some(value.to_string()),
            "upstream" => headers.upstream = Some(value.to_string()),
            "ab" => {
                for count in value.split(' ') {
                    if let Some(ahead) = count.strip_prefix('+') {
                        headers.ahead = ahead.parse().unwrap_or(0);
                    } else if let Some(behind) = count.strip_prefix('-') {
                        headers.behind = behind.parse().unwrap_or(0);
                    }
                }
            }
            _ => {}
        }
    }
    headers
}

/// NUL-separated paths from `git ls-files -z`, without nested repositories
/// (which git lists as a folder, ending in `/`).
pub(super) fn file_list(bytes: &[u8]) -> Vec<String> {
    tokens(bytes).filter(|path| !path.is_empty() && !path.ends_with('/')).collect()
}

fn tokens(bytes: &[u8]) -> impl Iterator<Item = String> + '_ {
    bytes.split(|byte| *byte == 0).map(|token| String::from_utf8_lossy(token).into_owned())
}
