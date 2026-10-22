//! Byte-level lexing helpers of the JSONC editor (Swift `JSONC` private helpers).

use super::JsoncError;

pub(super) const BOM: [u8; 3] = [0xEF, 0xBB, 0xBF];

pub(super) fn body_start(bytes: &[u8]) -> usize {
    if bytes.starts_with(&BOM) { 3 } else { 0 }
}

pub(super) fn is_delimiter(byte: u8) -> bool {
    matches!(byte, b',' | b'}' | b']' | b'/' | b' ' | b'\t' | b'\n' | b'\r')
}

fn starts_comment(bytes: &[u8], index: usize) -> bool {
    bytes.get(index) == Some(&b'/')
        && matches!(bytes.get(index.saturating_add(1)), Some(b'/' | b'*'))
}

pub(super) fn is_comment_start(bytes: &[u8], index: usize) -> bool {
    starts_comment(bytes, index)
}

/// Offset just past the string literal that starts at `start`.
pub(super) fn string_end(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start.saturating_add(1);
    while let Some(&byte) = bytes.get(index) {
        match byte {
            b'\\' => index = index.saturating_add(2),
            b'"' => return Ok(index.saturating_add(1)),
            _ => index = index.saturating_add(1),
        }
    }
    Err(JsoncError::UnterminatedString)
}

/// Offset just past the comment that starts at `start` (a line comment ends
/// before its newline).
pub(super) fn comment_end(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start.saturating_add(2);
    if bytes.get(start.saturating_add(1)) == Some(&b'/') {
        while bytes.get(index).is_some_and(|&byte| byte != b'\n') {
            index = index.saturating_add(1);
        }
        return Ok(index.min(bytes.len()));
    }
    while let Some(pair) = bytes.get(index..index.saturating_add(2)) {
        if pair == b"*/" {
            return Ok(index.saturating_add(2));
        }
        index = index.saturating_add(1);
    }
    Err(JsoncError::UnterminatedComment)
}

/// Offset of the first byte after whitespace and comments.
pub(super) fn skip_trivia(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start;
    while let Some(&byte) = bytes.get(index) {
        if matches!(byte, b' ' | b'\t' | b'\n' | b'\r') {
            index = index.saturating_add(1);
        } else if starts_comment(bytes, index) {
            index = comment_end(bytes, index)?;
        } else {
            break;
        }
    }
    Ok(index)
}

/// End of spaces and a line comment that follow `start` on the same line;
/// `start` itself when no comment follows.
pub(super) fn same_line_trivia_end(bytes: &[u8], start: usize) -> usize {
    let mut index = start;
    while let Some(&byte) = bytes.get(index) {
        if byte == b' ' || byte == b'\t' {
            index = index.saturating_add(1);
        } else if byte == b'/' && bytes.get(index.saturating_add(1)) == Some(&b'/') {
            while bytes.get(index).is_some_and(|&byte| byte != b'\n') {
                index = index.saturating_add(1);
            }
            return index;
        } else {
            break;
        }
    }
    start
}

/// The spaces and tabs that start the line containing `offset`.
pub(super) fn line_indent(bytes: &[u8], offset: usize) -> String {
    let mut line_start = offset.min(bytes.len());
    while let Some(previous) = line_start.checked_sub(1)
        && bytes.get(previous).is_some_and(|&byte| byte != b'\n')
    {
        line_start = previous;
    }
    let rest = bytes.get(line_start..).unwrap_or_default();
    let width = rest.iter().take_while(|&&byte| byte == b' ' || byte == b'\t').count();
    String::from_utf8_lossy(rest.get(..width).unwrap_or_default()).into_owned()
}

/// The start of `offset`'s line when only blanks precede it there, else `offset`.
pub(super) fn line_start_if_blank(bytes: &[u8], offset: usize) -> usize {
    let mut index = offset;
    while let Some(previous) = index.checked_sub(1)
        && matches!(bytes.get(previous), Some(b' ' | b'\t'))
    {
        index = previous;
    }
    match index.checked_sub(1) {
        None => index,
        Some(previous) if bytes.get(previous) == Some(&b'\n') => index,
        Some(_) => offset,
    }
}

/// Just past the newline when only blanks follow `offset` on its line, the
/// end of the text when nothing follows, else `offset`.
pub(super) fn line_end_if_blank(bytes: &[u8], offset: usize) -> usize {
    let mut index = offset;
    while matches!(bytes.get(index), Some(b' ' | b'\t' | b'\r')) {
        index = index.saturating_add(1);
    }
    if bytes.get(index) == Some(&b'\n') {
        return index.saturating_add(1);
    }
    if index == bytes.len() { index } else { offset }
}
