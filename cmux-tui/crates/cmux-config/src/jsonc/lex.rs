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
    bytes[index] == b'/' && index + 1 < bytes.len() && matches!(bytes[index + 1], b'/' | b'*')
}

pub(super) fn is_comment_start(bytes: &[u8], index: usize) -> bool {
    starts_comment(bytes, index)
}

/// Offset just past the string literal that starts at `start`.
pub(super) fn string_end(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start + 1;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => index += 2,
            b'"' => return Ok(index + 1),
            _ => index += 1,
        }
    }
    Err(JsoncError::UnterminatedString)
}

/// Offset just past the comment that starts at `start` (a line comment ends
/// before its newline).
pub(super) fn comment_end(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    if bytes[start + 1] == b'/' {
        let mut index = start + 2;
        while index < bytes.len() && bytes[index] != b'\n' {
            index += 1;
        }
        return Ok(index);
    }
    let mut index = start + 2;
    while index + 1 < bytes.len() {
        if bytes[index] == b'*' && bytes[index + 1] == b'/' {
            return Ok(index + 2);
        }
        index += 1;
    }
    Err(JsoncError::UnterminatedComment)
}

/// Offset of the first byte after whitespace and comments.
pub(super) fn skip_trivia(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start;
    while index < bytes.len() {
        let byte = bytes[index];
        if matches!(byte, b' ' | b'\t' | b'\n' | b'\r') {
            index += 1;
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
    while index < bytes.len() {
        let byte = bytes[index];
        if byte == b' ' || byte == b'\t' {
            index += 1;
        } else if byte == b'/' && index + 1 < bytes.len() && bytes[index + 1] == b'/' {
            while index < bytes.len() && bytes[index] != b'\n' {
                index += 1;
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
    let mut line_start = offset;
    while line_start > 0 && bytes[line_start - 1] != b'\n' {
        line_start -= 1;
    }
    let mut end = line_start;
    while end < bytes.len() && (bytes[end] == b' ' || bytes[end] == b'\t') {
        end += 1;
    }
    String::from_utf8_lossy(&bytes[line_start..end]).into_owned()
}

/// The start of `offset`'s line when only blanks precede it there, else `offset`.
pub(super) fn line_start_if_blank(bytes: &[u8], offset: usize) -> usize {
    let mut index = offset;
    while index > 0 && (bytes[index - 1] == b' ' || bytes[index - 1] == b'\t') {
        index -= 1;
    }
    if index == 0 || bytes[index - 1] == b'\n' { index } else { offset }
}

/// Just past the newline when only blanks follow `offset` on its line, the
/// end of the text when nothing follows, else `offset`.
pub(super) fn line_end_if_blank(bytes: &[u8], offset: usize) -> usize {
    let mut index = offset;
    while index < bytes.len() && matches!(bytes[index], b' ' | b'\t' | b'\r') {
        index += 1;
    }
    if index < bytes.len() && bytes[index] == b'\n' {
        return index + 1;
    }
    if index == bytes.len() { index } else { offset }
}
