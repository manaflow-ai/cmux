//! Parsers for git's machine output: `diff --name-status -z`, `diff --numstat
//! -z`, a unified patch split per file, and `status --porcelain=v2 --branch`
//! headers.

use std::collections::HashMap;

/// One changed file from `git diff --name-status -z`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NameStatus {
    pub path: String,
    pub previous_path: Option<String>,
    pub status: &'static str,
}

/// Added and deleted line counts from `git diff --numstat -z`; `None` for a
/// binary file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineCounts {
    pub additions: u64,
    pub deletions: u64,
}

pub fn name_status(bytes: &[u8]) -> Vec<NameStatus> {
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
pub fn numstat(bytes: &[u8]) -> HashMap<String, Option<LineCounts>> {
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
pub fn patches(bytes: &[u8]) -> Vec<(String, String)> {
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

/// Each file's git blob identity from the `index` and mode lines in a patch.
/// This survives the hunk-only patch shape sent to agent panes and also covers
/// binary sections, which have no `@@` body.
pub fn blob_fingerprints(bytes: &[u8]) -> Vec<(String, String)> {
    let text = String::from_utf8_lossy(bytes);
    let mut fingerprints = Vec::new();
    let mut section: Vec<&str> = Vec::new();
    for line in text.split_inclusive('\n') {
        if is_section_start(line) && !section.is_empty() {
            insert_blob_fingerprint(&mut fingerprints, &section);
            section.clear();
        }
        section.push(line);
    }
    if !section.is_empty() {
        insert_blob_fingerprint(&mut fingerprints, &section);
    }
    fingerprints
}

fn insert_blob_fingerprint(out: &mut Vec<(String, String)>, section: &[&str]) {
    let index = section.iter().find(|line| line.starts_with("index ")).map(|line| line.trim_end());
    let Some(index) = index else { return };
    let modes: Vec<&str> = section
        .iter()
        .copied()
        .filter(|line| {
            line.starts_with("old mode ")
                || line.starts_with("new mode ")
                || line.starts_with("new file mode ")
                || line.starts_with("deleted file mode ")
        })
        .map(str::trim_end)
        .collect();
    let path = section
        .iter()
        .find_map(|line| header_path(line, "+++ ", "b/"))
        .or_else(|| section.iter().find_map(|line| header_path(line, "--- ", "a/")))
        .or_else(|| section.iter().find_map(|line| binary_path(line)))
        .or_else(|| section.iter().find_map(|line| git_header_path(line)));
    let Some(path) = path else { return };
    let mut input = index.to_string();
    for mode in modes {
        input.push('\n');
        input.push_str(mode);
    }
    out.push((path, format!("blob:{}", fnv1a(&input))));
}

fn binary_path(line: &str) -> Option<String> {
    let rest = line.strip_prefix("Binary files ")?.trim_end();
    let (old, new) = rest.rsplit_once(" and ")?;
    let new = new.strip_suffix(" differ")?.trim();
    let _ = old;
    new.strip_prefix("b/").map(str::to_string)
}

/// Binary diffs have no `---`/`+++` headers. Decode the two paths from the
/// `diff --git` header instead; Git quotes each path as one shell-like token.
fn git_header_path(line: &str) -> Option<String> {
    let rest = line.strip_prefix("diff --git ")?.trim_end();
    let (old, remainder) = git_path_token(rest)?;
    let (new, _) = git_path_token(remainder.trim_start())?;
    let _ = old;
    new.strip_prefix("b/").map(str::to_string)
}

fn git_path_token(input: &str) -> Option<(String, &str)> {
    if input.starts_with('"') {
        let mut escaped = false;
        for (index, byte) in input.bytes().enumerate().skip(1) {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                let (quoted, rest) = input.split_at_checked(index + 1)?;
                return Some((unquote(quoted)?, rest));
            }
        }
        None
    } else {
        let end = input.find(' ').unwrap_or(input.len());
        let (token, rest) = input.split_at_checked(end)?;
        Some((token.to_string(), rest))
    }
}

fn fnv1a(text: &str) -> String {
    let mut hash: u32 = 0x811c9dc5;
    for byte in text.encode_utf16() {
        hash ^= byte as u32;
        hash = hash.wrapping_mul(0x01000193);
    }
    format!("{hash:08x}")
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
pub fn truncate_patch(patch: &mut String, limit: usize) -> bool {
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
pub struct BranchHeaders {
    pub head: Option<String>,
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
}

pub fn branch_headers(bytes: &[u8]) -> BranchHeaders {
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
pub fn file_list(bytes: &[u8]) -> Vec<String> {
    tokens(bytes).filter(|path| !path.is_empty() && !path.ends_with('/')).collect()
}

fn tokens(bytes: &[u8]) -> impl Iterator<Item = String> + '_ {
    bytes.split(|byte| *byte == 0).map(|token| String::from_utf8_lossy(token).into_owned())
}

#[cfg(test)]
mod tests {
    use super::blob_fingerprints;

    #[test]
    fn blob_fingerprints_cover_hunk_and_binary_sections() {
        let patch = concat!(
            "diff --git a/src/a.txt b/src/a.txt\n",
            "index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644\n",
            "--- a/src/a.txt\n+++ b/src/a.txt\n",
            "@@ -1 +1 @@\n-old\n+new\n",
            "diff --git a/assets/logo.png b/assets/logo.png\n",
            "index aaaaaaa..bbbbbbb 100644\n",
            "Binary files a/assets/logo.png and b/assets/logo.png differ\n",
        );
        let values = blob_fingerprints(patch.as_bytes());
        assert_eq!(values.len(), 2);
        assert_eq!(values[0].0, "src/a.txt");
        assert_eq!(values[1].0, "assets/logo.png");
        assert_eq!(values[0].1, "blob:8df14ed8");
        assert!(values.iter().all(|(_, fingerprint)| fingerprint.starts_with("blob:")));
        assert_ne!(values[0].1, values[1].1);
    }
}
