//! The three-way merge a memory file gets when this machine and another both changed it since the
//! version they last agreed on (the base), and the name the losing side is kept under when the
//! merge cannot settle it. No change is ever dropped: a clean merge keeps both sides' edits, and a
//! conflict keeps the other machine's file under its name and ours beside it.

use std::path::Path;

/// What a three-way merge gives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Merged {
    /// Both sides' changes, combined with nothing overlapping.
    Clean(Vec<u8>),
    /// The two sides changed the same lines (or the file is not text): keep both whole.
    Conflict,
}

/// Merge `ours` and `theirs`, both changed from `base`.
///
/// - Either side unchanged, or both the same: the other side.
/// - `.jsonl`: a line log every machine appends to. The result is theirs, then each of our lines
///   that neither theirs nor the base has (our appends), minus the lines one side removed.
/// - Other UTF-8 text: a line-based diff3 (`diffy`). When that overlaps but one side only added
///   lines and the other side has every line of it (one side appended, the other appended more
///   or edited elsewhere), the fuller side: nothing of either is lost. Else a conflict.
/// - Anything else (bytes that are not UTF-8): a conflict.
pub fn three_way(path: &str, base: &[u8], ours: &[u8], theirs: &[u8]) -> Merged {
    if ours == theirs || ours == base {
        return Merged::Clean(theirs.to_vec());
    }
    if theirs == base {
        return Merged::Clean(ours.to_vec());
    }
    let (Ok(b), Ok(o), Ok(t)) =
        (std::str::from_utf8(base), std::str::from_utf8(ours), std::str::from_utf8(theirs))
    else {
        return Merged::Conflict;
    };
    if path.ends_with(".jsonl") {
        return Merged::Clean(union_lines(b, o, t).into_bytes());
    }
    match diffy::merge(b, o, t) {
        Ok(text) => Merged::Clean(text.into_bytes()),
        Err(_) if holds_all_of(b, o, t) => Merged::Clean(theirs.to_vec()),
        Err(_) if holds_all_of(b, t, o) => Merged::Clean(ours.to_vec()),
        Err(_) => Merged::Conflict,
    }
}

/// `full` has every line of `part`, and `part` changed the base only by adding lines (each base
/// line `full` still has, `part` has too). Then `full` is `part`'s change and more.
fn holds_all_of(base: &str, part: &str, full: &str) -> bool {
    use std::collections::HashSet;
    let part_set: HashSet<&str> = part.lines().collect();
    let full_set: HashSet<&str> = full.lines().collect();
    part_set.is_subset(&full_set)
        && base.lines().all(|l| part_set.contains(l) || !full_set.contains(l))
}

/// Theirs, then our lines that are new since the base, with lines either side removed left out.
fn union_lines(base: &str, ours: &str, theirs: &str) -> String {
    use std::collections::HashSet;
    let base: HashSet<&str> = base.lines().collect();
    let ours_set: HashSet<&str> = ours.lines().collect();
    let theirs_set: HashSet<&str> = theirs.lines().collect();
    let mut out = String::new();
    for line in theirs.lines() {
        // A base line we removed stays removed.
        if base.contains(line) && !ours_set.contains(line) {
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    for line in ours.lines() {
        if !theirs_set.contains(line) && !base.contains(line) {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

/// The name our side of a conflict is kept under, beside the file: `NAME.conflict-HOST-UNIX.EXT`
/// (`notes/a.md` -> `notes/a.conflict-lane-1-1795569895.md`). `host` is cut to one plain name
/// part, so it never adds a folder to the path.
pub fn conflict_name(path: &str, host: &str, unix_seconds: u64) -> String {
    let host: String = host
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' })
        .take(64)
        .collect();
    let host = if host.is_empty() { "machine".to_owned() } else { host };
    let p = Path::new(path);
    let stem = p.file_stem().and_then(|v| v.to_str()).unwrap_or("memory");
    let ext = p.extension().and_then(|v| v.to_str()).map(|e| format!(".{e}")).unwrap_or_default();
    let name = format!("{stem}.conflict-{host}-{unix_seconds}{ext}");
    match p.parent().map(|p| p.to_string_lossy().into_owned()) {
        Some(parent) if !parent.is_empty() => format!("{parent}/{name}"),
        _ => name,
    }
}
