//! Parser and in-memory applicator for Codex's native `apply_patch` grammar.
//!
//! The grammar and matching behavior track OpenAI Codex's MIT-licensed
//! `codex-rs/apply-patch` implementation at commit
//! 5865ec45e596e67c0a1279c82d3a02e50dcaef1b. Filesystem mutation remains in
//! cmux's transactional workspace patch path.

const BEGIN_PATCH_MARKER: &str = "*** Begin Patch";
const ENVIRONMENT_ID_MARKER: &str = "*** Environment ID: ";
const END_PATCH_MARKER: &str = "*** End Patch";
const ADD_FILE_MARKER: &str = "*** Add File: ";
const DELETE_FILE_MARKER: &str = "*** Delete File: ";
const UPDATE_FILE_MARKER: &str = "*** Update File: ";
const MOVE_TO_MARKER: &str = "*** Move to: ";
const EOF_MARKER: &str = "*** End of File";
const CHANGE_CONTEXT_MARKER: &str = "@@ ";
const EMPTY_CHANGE_CONTEXT_MARKER: &str = "@@";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Hunk {
    Add { path: String, contents: String },
    Delete { path: String },
    Update { path: String, move_path: Option<String>, chunks: Vec<UpdateFileChunk> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct UpdateFileChunk {
    change_context: Option<String>,
    old_lines: Vec<String>,
    new_lines: Vec<String>,
    is_end_of_file: bool,
}

pub(super) fn looks_like_patch(source: &str) -> bool {
    let trimmed = source.trim_start();
    trimmed.starts_with(BEGIN_PATCH_MARKER)
        || trimmed.starts_with("<<EOF\n")
        || trimmed.starts_with("<<'EOF'\n")
        || trimmed.starts_with("<<\"EOF\"\n")
}

pub(super) fn parse_patch(source: &str) -> Result<Vec<Hunk>, String> {
    let original_lines = source.trim().lines().collect::<Vec<_>>();
    let lines = patch_lines(&original_lines)?;
    // `patch_lines` returns at least the Begin and End marker lines.
    let [_, body @ .., _] = lines else {
        return Err("the last line of the patch must be '*** End Patch'".into());
    };
    let mut remaining = body;
    let mut line_number = 2;

    if let Some((first, rest)) = remaining.split_first()
        && let Some(environment_id) = first.trim_start().strip_prefix(ENVIRONMENT_ID_MARKER)
    {
        if environment_id.trim().is_empty() {
            return Err("apply_patch environment_id cannot be empty".into());
        }
        remaining = rest;
        line_number += 1;
    }

    let mut hunks = Vec::new();
    while !remaining.is_empty() {
        let (hunk, consumed) = parse_one_hunk(remaining, line_number)?;
        hunks.push(hunk);
        remaining = remaining.get(consumed..).unwrap_or_default();
        line_number += consumed;
    }
    if hunks.is_empty() {
        return Err("patch must contain at least one file hunk".into());
    }
    Ok(hunks)
}

fn patch_lines<'a>(original: &'a [&'a str]) -> Result<&'a [&'a str], String> {
    if valid_boundaries(original) {
        return Ok(original);
    }
    if let [first, inner @ .., last] = original
        && matches!(*first, "<<EOF" | "<<'EOF'" | "<<\"EOF\"")
        && last.ends_with("EOF")
        && original.len() >= 4
        && valid_boundaries(inner)
    {
        return Ok(inner);
    }
    match (original.first(), original.last()) {
        (Some(first), _) if first.trim() != BEGIN_PATCH_MARKER => {
            Err("the first line of the patch must be '*** Begin Patch'".into())
        }
        _ => Err("the last line of the patch must be '*** End Patch'".into()),
    }
}

fn valid_boundaries(lines: &[&str]) -> bool {
    lines.len() >= 2
        && lines.first().is_some_and(|line| line.trim() == BEGIN_PATCH_MARKER)
        && lines.last().is_some_and(|line| line.trim() == END_PATCH_MARKER)
}

fn parse_one_hunk(lines: &[&str], line_number: usize) -> Result<(Hunk, usize), String> {
    let Some((first, rest)) = lines.split_first() else {
        return Err(format!("invalid hunk at line {line_number}: missing hunk header"));
    };
    let first = first.trim();
    if let Some(path) = first.strip_prefix(ADD_FILE_MARKER) {
        let mut contents = String::new();
        let mut consumed = 1;
        for line in rest {
            let Some(line) = line.strip_prefix('+') else { break };
            contents.push_str(line);
            contents.push('\n');
            consumed += 1;
        }
        return Ok((Hunk::Add { path: path.into(), contents }, consumed));
    }
    if let Some(path) = first.strip_prefix(DELETE_FILE_MARKER) {
        return Ok((Hunk::Delete { path: path.into() }, 1));
    }
    if let Some(path) = first.strip_prefix(UPDATE_FILE_MARKER) {
        let mut remaining = rest;
        let mut consumed = 1;
        let mut move_path = None;
        if let Some((line, rest)) = remaining.split_first()
            && let Some(path) = line.strip_prefix(MOVE_TO_MARKER)
        {
            move_path = Some(path);
            remaining = rest;
            consumed += 1;
        }

        let mut chunks = Vec::new();
        while let Some((line, rest)) = remaining.split_first() {
            if line.trim().is_empty() {
                remaining = rest;
                consumed += 1;
                continue;
            }
            if line.starts_with('*') {
                break;
            }
            let (chunk, chunk_lines) =
                parse_update_chunk(remaining, line_number + consumed, chunks.is_empty())?;
            chunks.push(chunk);
            remaining = remaining.get(chunk_lines..).unwrap_or_default();
            consumed += chunk_lines;
        }
        if chunks.is_empty() {
            return Err(format!(
                "invalid hunk at line {line_number}: update file hunk for path '{path}' is empty"
            ));
        }
        return Ok((
            Hunk::Update { path: path.into(), move_path: move_path.map(str::to_owned), chunks },
            consumed,
        ));
    }
    Err(format!("invalid hunk at line {line_number}: '{first}' is not a valid hunk header"))
}

fn parse_update_chunk(
    lines: &[&str],
    line_number: usize,
    allow_missing_context: bool,
) -> Result<(UpdateFileChunk, usize), String> {
    let Some(&head) = lines.first() else {
        return Err(format!(
            "invalid hunk at line {}: update hunk does not contain any lines",
            line_number + 1
        ));
    };
    let (change_context, start) = if head == EMPTY_CHANGE_CONTEXT_MARKER {
        (None, 1)
    } else if let Some(context) = head.strip_prefix(CHANGE_CONTEXT_MARKER) {
        (Some(context.to_owned()), 1)
    } else if allow_missing_context {
        (None, 0)
    } else {
        return Err(format!(
            "invalid hunk at line {line_number}: expected @@ context marker, got '{head}'"
        ));
    };
    if start >= lines.len() {
        return Err(format!(
            "invalid hunk at line {}: update hunk does not contain any lines",
            line_number + 1
        ));
    }

    let mut chunk = UpdateFileChunk {
        change_context,
        old_lines: Vec::new(),
        new_lines: Vec::new(),
        is_end_of_file: false,
    };
    let mut parsed = 0;
    for line in lines.get(start..).unwrap_or_default() {
        if *line == EOF_MARKER {
            if parsed == 0 {
                return Err(format!(
                    "invalid hunk at line {}: update hunk does not contain any lines",
                    line_number + 1
                ));
            }
            chunk.is_end_of_file = true;
            parsed += 1;
            break;
        }
        let mut chars = line.chars();
        let marker = chars.next();
        let text = chars.as_str();
        match marker {
            None => {
                chunk.old_lines.push(String::new());
                chunk.new_lines.push(String::new());
            }
            Some(' ') => {
                chunk.old_lines.push(text.to_owned());
                chunk.new_lines.push(text.to_owned());
            }
            Some('+') => chunk.new_lines.push(text.to_owned()),
            Some('-') => chunk.old_lines.push(text.to_owned()),
            _ if parsed > 0 => break,
            _ => {
                return Err(format!(
                    "invalid hunk at line {}: every update line must start with ' ', '+', or '-'",
                    line_number + 1
                ));
            }
        }
        parsed += 1;
    }
    Ok((chunk, parsed + start))
}

pub(super) fn apply_update(
    original: &str,
    path: &str,
    chunks: &[UpdateFileChunk],
) -> Result<String, String> {
    let mut original_lines = original.split('\n').map(str::to_owned).collect::<Vec<_>>();
    if original_lines.last().is_some_and(String::is_empty) {
        original_lines.pop();
    }
    let replacements = compute_replacements(&original_lines, path, chunks)?;
    for (start, old_len, new_lines) in replacements.iter().rev() {
        // Each range was found inside the original lines; clamp so chunks that
        // overlap (an end-of-file chunk can) cannot index past the edited lines.
        let end = start.saturating_add(*old_len).min(original_lines.len());
        original_lines.splice((*start).min(end)..end, new_lines.iter().cloned());
    }
    if !original_lines.last().is_some_and(String::is_empty) {
        original_lines.push(String::new());
    }
    Ok(original_lines.join("\n"))
}

fn compute_replacements(
    original: &[String],
    path: &str,
    chunks: &[UpdateFileChunk],
) -> Result<Vec<(usize, usize, Vec<String>)>, String> {
    let mut replacements = Vec::new();
    let mut line_index = 0;
    for chunk in chunks {
        if let Some(context) = &chunk.change_context {
            line_index = seek_sequence(original, std::slice::from_ref(context), line_index, false)
                .map(|index| index + 1)
                .ok_or_else(|| format!("failed to find context '{context}' in {path}"))?;
        }
        if chunk.old_lines.is_empty() {
            let insertion = if original.last().is_some_and(String::is_empty) {
                original.len().saturating_sub(1)
            } else {
                original.len()
            };
            replacements.push((insertion, 0, chunk.new_lines.clone()));
            continue;
        }

        let mut pattern = chunk.old_lines.as_slice();
        let mut new_lines = chunk.new_lines.as_slice();
        let mut found = seek_sequence(original, pattern, line_index, chunk.is_end_of_file);
        if found.is_none()
            && let Some((last, without_last)) = pattern.split_last()
            && last.is_empty()
        {
            pattern = without_last;
            if let Some((last, without_last)) = new_lines.split_last()
                && last.is_empty()
            {
                new_lines = without_last;
            }
            found = seek_sequence(original, pattern, line_index, chunk.is_end_of_file);
        }
        let start = found.ok_or_else(|| {
            format!("failed to find expected lines in {path}:\n{}", chunk.old_lines.join("\n"))
        })?;
        replacements.push((start, pattern.len(), new_lines.to_vec()));
        line_index = start + pattern.len();
    }
    replacements.sort_by_key(|(start, _, _)| *start);
    Ok(replacements)
}

fn seek_sequence(lines: &[String], pattern: &[String], start: usize, eof: bool) -> Option<usize> {
    if pattern.is_empty() {
        return Some(start);
    }
    if pattern.len() > lines.len() {
        return None;
    }
    let search_start = if eof { lines.len() - pattern.len() } else { start };
    let end = lines.len().saturating_sub(pattern.len());
    if search_start > end {
        return None;
    }
    // Exact, then ignoring trailing whitespace, then ignoring surrounding
    // whitespace, then with Unicode punctuation normalized; each pass scans
    // every position before the next, looser one.
    let passes: [fn(&str, &str) -> bool; 4] = [
        |line, expected| line == expected,
        |line, expected| line.trim_end() == expected.trim_end(),
        |line, expected| line.trim() == expected.trim(),
        |line, expected| normalize_unicode(line) == normalize_unicode(expected),
    ];
    let matches_at = |index: usize, same: fn(&str, &str) -> bool| {
        lines.get(index..).is_some_and(|tail| {
            tail.len() >= pattern.len()
                && tail.iter().zip(pattern).all(|(line, expected)| same(line, expected))
        })
    };
    passes.into_iter().find_map(|same| (search_start..=end).find(|&index| matches_at(index, same)))
}

fn normalize_unicode(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|character| match character {
            '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2015}'
            | '\u{2212}' => '-',
            '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}' => '\'',
            '\u{201C}' | '\u{201D}' | '\u{201E}' | '\u{201F}' => '"',
            '\u{00A0}' | '\u{2002}' | '\u{2003}' | '\u{2004}' | '\u{2005}' | '\u{2006}'
            | '\u{2007}' | '\u{2008}' | '\u{2009}' | '\u{200A}' | '\u{202F}' | '\u{205F}'
            | '\u{3000}' => ' ',
            other => other,
        })
        .collect()
}
