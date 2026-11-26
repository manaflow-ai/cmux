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
    let mut remaining = &lines[1..lines.len() - 1];
    let mut line_number = 2;

    if let Some(first) = remaining.first()
        && let Some(environment_id) = first.trim_start().strip_prefix(ENVIRONMENT_ID_MARKER)
    {
        if environment_id.trim().is_empty() {
            return Err("apply_patch environment_id cannot be empty".into());
        }
        remaining = &remaining[1..];
        line_number += 1;
    }

    let mut hunks = Vec::new();
    while !remaining.is_empty() {
        let (hunk, consumed) = parse_one_hunk(remaining, line_number)?;
        hunks.push(hunk);
        remaining = &remaining[consumed..];
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
    if let [first, .., last] = original
        && matches!(*first, "<<EOF" | "<<'EOF'" | "<<\"EOF\"")
        && last.ends_with("EOF")
        && original.len() >= 4
    {
        let inner = &original[1..original.len() - 1];
        if valid_boundaries(inner) {
            return Ok(inner);
        }
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
    let first = lines[0].trim();
    if let Some(path) = first.strip_prefix(ADD_FILE_MARKER) {
        let mut contents = String::new();
        let mut consumed = 1;
        for line in &lines[1..] {
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
        let mut remaining = &lines[1..];
        let mut consumed = 1;
        let move_path = remaining.first().and_then(|line| line.strip_prefix(MOVE_TO_MARKER));
        if move_path.is_some() {
            remaining = &remaining[1..];
            consumed += 1;
        }

        let mut chunks = Vec::new();
        while !remaining.is_empty() {
            if remaining[0].trim().is_empty() {
                remaining = &remaining[1..];
                consumed += 1;
                continue;
            }
            if remaining[0].starts_with('*') {
                break;
            }
            let (chunk, chunk_lines) =
                parse_update_chunk(remaining, line_number + consumed, chunks.is_empty())?;
            chunks.push(chunk);
            remaining = &remaining[chunk_lines..];
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
    let (change_context, start) = if lines[0] == EMPTY_CHANGE_CONTEXT_MARKER {
        (None, 1)
    } else if let Some(context) = lines[0].strip_prefix(CHANGE_CONTEXT_MARKER) {
        (Some(context.to_owned()), 1)
    } else if allow_missing_context {
        (None, 0)
    } else {
        return Err(format!(
            "invalid hunk at line {line_number}: expected @@ context marker, got '{}'",
            lines[0]
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
    for line in &lines[start..] {
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
        match line.chars().next() {
            None => {
                chunk.old_lines.push(String::new());
                chunk.new_lines.push(String::new());
            }
            Some(' ') => {
                chunk.old_lines.push(line[1..].to_owned());
                chunk.new_lines.push(line[1..].to_owned());
            }
            Some('+') => chunk.new_lines.push(line[1..].to_owned()),
            Some('-') => chunk.old_lines.push(line[1..].to_owned()),
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
        original_lines.splice(*start..*start + *old_len, new_lines.iter().cloned());
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
        if found.is_none() && pattern.last().is_some_and(String::is_empty) {
            pattern = &pattern[..pattern.len() - 1];
            if new_lines.last().is_some_and(String::is_empty) {
                new_lines = &new_lines[..new_lines.len() - 1];
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
    for index in search_start..=end {
        if lines[index..index + pattern.len()] == *pattern {
            return Some(index);
        }
    }
    for index in search_start..=end {
        if pattern
            .iter()
            .enumerate()
            .all(|(offset, expected)| lines[index + offset].trim_end() == expected.trim_end())
        {
            return Some(index);
        }
    }
    for index in search_start..=end {
        if pattern
            .iter()
            .enumerate()
            .all(|(offset, expected)| lines[index + offset].trim() == expected.trim())
        {
            return Some(index);
        }
    }
    (search_start..=end).find(|&index| {
        pattern.iter().enumerate().all(|(offset, expected)| {
            normalize_unicode(&lines[index + offset]) == normalize_unicode(expected)
        })
    })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_environment_id_and_all_file_actions() {
        let patch = concat!(
            "*** Begin Patch\n",
            "*** Environment ID: remote-1\n",
            "*** Add File: added.txt\n",
            "+added\n",
            "*** Delete File: deleted.txt\n",
            "*** Update File: old.txt\n",
            "*** Move to: new.txt\n",
            "@@\n",
            "-old\n",
            "+new\n",
            "*** End Patch\n",
        );
        assert_eq!(parse_patch(patch).unwrap().len(), 3);
    }

    #[test]
    fn update_matches_codex_whitespace_tolerance() {
        let hunks = parse_patch(concat!(
            "*** Begin Patch\n",
            "*** Update File: value.txt\n",
            "@@\n",
            "-  old\n",
            "+new\n",
            "*** End Patch\n",
        ))
        .unwrap();
        let Hunk::Update { chunks, .. } = &hunks[0] else { panic!() };
        assert_eq!(apply_update("old   \n", "value.txt", chunks).unwrap(), "new\n");
    }
}
