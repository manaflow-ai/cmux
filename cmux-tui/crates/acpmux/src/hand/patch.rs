//! `fs.patch`: apply a unified diff (one or more files) all or nothing.
//!
//! Each hunk's old lines must match the file exactly. The hunk header's line
//! number is a hint: the hunk is looked for there first, then at the nearest
//! offset where it matches, and it fails when it matches nowhere. Nothing is
//! written until every file applied in memory.

use super::HandError;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub struct FilePatch {
    /// None for a created file (`--- /dev/null`).
    pub old: Option<String>,
    /// None for a deleted file (`+++ /dev/null`).
    pub new: Option<String>,
    pub hunks: Vec<Hunk>,
    /// "\\ No newline at end of file" after an old-side (removed or context) last line.
    pub old_no_eol: bool,
    /// The same after a new-side (added or context) last line: the result ends without a newline.
    pub new_no_eol: bool,
}

#[derive(Debug)]
pub struct Hunk {
    pub old_start: usize,
    /// (' ' | '-' | '+', text without the newline)
    pub lines: Vec<(char, String)>,
}

fn strip_prefix(p: &str) -> Option<String> {
    let p = p.split('\t').next().unwrap_or(p).trim();
    if p == "/dev/null" {
        return None;
    }
    Some(p.strip_prefix("a/").or_else(|| p.strip_prefix("b/")).unwrap_or(p).to_owned())
}

pub fn parse(diff: &str) -> Result<Vec<FilePatch>, HandError> {
    let bad = |m: String| HandError::new("fs.patch.parse", m);
    let mut files: Vec<FilePatch> = Vec::new();
    let mut lines = diff.lines().peekable();
    while let Some(line) = lines.next() {
        if let Some(old) = line.strip_prefix("--- ") {
            let next = lines.next().ok_or_else(|| bad("--- without +++".into()))?;
            let new = next
                .strip_prefix("+++ ")
                .ok_or_else(|| bad(format!("expected +++ after --- {old}")))?;
            files.push(FilePatch {
                old: strip_prefix(old),
                new: strip_prefix(new),
                hunks: Vec::new(),
                old_no_eol: false,
                new_no_eol: false,
            });
        } else if let Some(h) = line.strip_prefix("@@ ") {
            let file = files.last_mut().ok_or_else(|| bad("hunk before any file header".into()))?;
            // "-a,b +c,d": the body is exactly b old and d new lines, so a
            // removed line that reads "-- x" is not taken for a file header.
            let mut ranges = h.split_whitespace();
            let range = |r: Option<&str>, sign: char| -> Option<(usize, usize)> {
                let r = r?.strip_prefix(sign)?;
                let mut it = r.split(',');
                let start = it.next()?.parse().ok()?;
                let count = it.next().map_or(Some(1), |c| c.parse().ok())?;
                Some((start, count))
            };
            let (old_start, mut old_left) =
                range(ranges.next(), '-').ok_or_else(|| bad(format!("bad hunk header @@ {h}")))?;
            let (_, mut new_left) =
                range(ranges.next(), '+').ok_or_else(|| bad(format!("bad hunk header @@ {h}")))?;
            let mut hunk = Hunk { old_start, lines: Vec::new() };
            while old_left > 0 || new_left > 0 {
                let l = lines.next().ok_or_else(|| bad(format!("hunk @@ {h} ends early")))?;
                if l.starts_with('\\') {
                    // "\ No newline at end of file": about the line before it.
                    let prev = hunk.lines.last().map(|(t, _)| *t);
                    file.old_no_eol |= matches!(prev, Some('-' | ' '));
                    file.new_no_eol |= matches!(prev, Some('+' | ' '));
                    continue;
                }
                let mut chars = l.chars();
                let (tag, rest) = match chars.next() {
                    Some(c @ (' ' | '-' | '+')) => (c, chars.as_str()),
                    None => (' ', ""),
                    Some(_) => return Err(bad(format!("bad hunk line {l:?}"))),
                };
                match tag {
                    '-' => {
                        old_left = old_left
                            .checked_sub(1)
                            .ok_or_else(|| bad(format!("hunk @@ {h}: too many old lines")))?
                    }
                    '+' => {
                        new_left = new_left
                            .checked_sub(1)
                            .ok_or_else(|| bad(format!("hunk @@ {h}: too many new lines")))?
                    }
                    _ => {
                        old_left = old_left
                            .checked_sub(1)
                            .ok_or_else(|| bad(format!("hunk @@ {h}: too many old lines")))?;
                        new_left = new_left
                            .checked_sub(1)
                            .ok_or_else(|| bad(format!("hunk @@ {h}: too many new lines")))?;
                    }
                }
                hunk.lines.push((tag, rest.to_owned()));
            }
            while lines.peek().is_some_and(|l| l.starts_with('\\')) {
                lines.next();
                let prev = hunk.lines.last().map(|(t, _)| *t);
                file.old_no_eol |= matches!(prev, Some('-' | ' '));
                file.new_no_eol |= matches!(prev, Some('+' | ' '));
            }
            file.hunks.push(hunk);
        }
    }
    if files.is_empty() {
        return Err(bad("no file headers (--- / +++) in the patch".into()));
    }
    Ok(files)
}

fn find(haystack: &[String], needle: &[String], hint: usize) -> Option<usize> {
    if needle.is_empty() {
        return Some(hint.min(haystack.len()));
    }
    let fits = |at: usize| haystack.get(at..at + needle.len()) == Some(needle);
    let max = haystack.len();
    for d in 0..=max {
        if hint >= d && fits(hint - d) {
            return Some(hint - d);
        }
        if fits(hint + d) {
            return Some(hint + d);
        }
    }
    None
}

/// The new text of one file. `text` is None for a file that does not exist.
pub fn apply_one(
    text: Option<&str>,
    fp: &FilePatch,
    name: &str,
) -> Result<Option<String>, HandError> {
    if fp.old.is_none() && text.is_some() {
        return Err(HandError::new(
            "fs.patch.exists",
            format!("{name}: the patch creates a file that already exists"),
        ));
    }
    if fp.new.is_none() {
        // A delete must match the file it removes.
        let src = text.unwrap_or("");
        let removed: Vec<&str> = fp
            .hunks
            .iter()
            .flat_map(|h| h.lines.iter())
            .filter(|(t, _)| *t != '+')
            .map(|(_, l)| l.as_str())
            .collect();
        if src.lines().collect::<Vec<_>>() != removed {
            return Err(HandError::new(
                "fs.patch.no_match",
                format!("{name}: the delete does not match the file"),
            ));
        }
        return Ok(None);
    }
    let src = text.unwrap_or("");
    let trailing_newline = if fp.new_no_eol {
        false
    } else if fp.old_no_eol {
        true
    } else {
        src.is_empty() || src.ends_with('\n')
    };
    let mut lines: Vec<String> = src.lines().map(str::to_owned).collect();
    let mut shift: isize = 0;
    for (i, h) in fp.hunks.iter().enumerate() {
        let old: Vec<String> =
            h.lines.iter().filter(|(t, _)| *t != '+').map(|(_, s)| s.clone()).collect();
        let new: Vec<String> =
            h.lines.iter().filter(|(t, _)| *t != '-').map(|(_, s)| s.clone()).collect();
        let hint = ((h.old_start.max(1) - 1) as isize + shift).max(0) as usize;
        let at = find(&lines, &old, hint).ok_or_else(|| {
            HandError::new("fs.patch.no_match", format!("{name}: hunk {i} does not match the file"))
        })?;
        lines.splice(at..at + old.len(), new.iter().cloned());
        shift += new.len() as isize - old.len() as isize;
    }
    let mut out = lines.join("\n");
    if trailing_newline && !out.is_empty() {
        out.push('\n');
    }
    Ok(Some(out))
}

/// The old and new path of one file patch, made absolute against `cwd`.
pub fn file_paths(f: &FilePatch, cwd: &Path) -> (Option<PathBuf>, Option<PathBuf>) {
    let abs = |p: &str| if Path::new(p).is_absolute() { PathBuf::from(p) } else { cwd.join(p) };
    (f.old.as_deref().map(abs), f.new.as_deref().map(abs))
}
