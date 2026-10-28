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
    matches!(bytes.get(index..), Some([b'/', b'/' | b'*', ..]))
}

pub(super) fn is_comment_start(bytes: &[u8], index: usize) -> bool {
    starts_comment(bytes, index)
}

/// `bytes[start..end]`, or `Malformed` at `start` when the span is not
/// inside `bytes`.
pub(super) fn span(bytes: &[u8], start: usize, end: usize) -> Result<&[u8], JsoncError> {
    bytes.get(start..end).ok_or(JsoncError::Malformed { offset: start })
}

/// Offset of the first newline at or after `from`; the end of the text when
/// there is none.
fn line_end(bytes: &[u8], from: usize) -> usize {
    let rest = bytes.get(from..).unwrap_or_default();
    from + rest.iter().position(|&byte| byte == b'\n').unwrap_or(rest.len())
}

fn is_blank(byte: u8) -> bool {
    byte == b' ' || byte == b'\t'
}

/// Offset just past the string literal that starts at `start`.
pub(super) fn string_end(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start + 1;
    while let Some(&byte) = bytes.get(index) {
        match byte {
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
    if matches!(bytes.get(start..), Some([b'/', b'/', ..])) {
        return Ok(line_end(bytes, start + 2));
    }
    let body = bytes.get(start + 2..).unwrap_or_default();
    body.windows(2)
        .position(|pair| pair == b"*/")
        .map(|at| start + 2 + at + 2)
        .ok_or(JsoncError::UnterminatedComment)
}

/// Offset of the first byte after whitespace and comments.
pub(super) fn skip_trivia(bytes: &[u8], start: usize) -> Result<usize, JsoncError> {
    let mut index = start;
    while let Some(&byte) = bytes.get(index) {
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
    let rest = bytes.get(start..).unwrap_or_default();
    let blanks = rest.iter().take_while(|&&byte| is_blank(byte)).count();
    match rest.get(blanks..) {
        Some([b'/', b'/', ..]) => line_end(bytes, start + blanks),
        _ => start,
    }
}

/// `bytes[..offset]`, or `Malformed` at `offset` when it is past the end.
fn prefix(bytes: &[u8], offset: usize) -> Result<&[u8], JsoncError> {
    bytes.get(..offset).ok_or(JsoncError::Malformed { offset })
}

/// The spaces and tabs that start the line containing `offset`; `Malformed`
/// when `offset` is past the end.
pub(super) fn line_indent(bytes: &[u8], offset: usize) -> Result<String, JsoncError> {
    let before = prefix(bytes, offset)?;
    let line_start =
        before.iter().rposition(|&byte| byte == b'\n').map_or(0, |newline| newline + 1);
    let line = span(bytes, line_start, bytes.len())?;
    Ok(line.iter().take_while(|&&byte| is_blank(byte)).map(|&byte| char::from(byte)).collect())
}

/// The start of `offset`'s line when only blanks precede it there, else
/// `offset`; `Malformed` when `offset` is past the end.
pub(super) fn line_start_if_blank(bytes: &[u8], offset: usize) -> Result<usize, JsoncError> {
    let before = prefix(bytes, offset)?;
    let blanks = before.iter().rev().take_while(|&&byte| is_blank(byte)).count();
    Ok(match before.iter().rev().nth(blanks) {
        None | Some(b'\n') => offset - blanks,
        Some(_) => offset,
    })
}

/// Just past the newline when only blanks follow `offset` on its line, the
/// end of the text when nothing follows, else `offset`.
pub(super) fn line_end_if_blank(bytes: &[u8], offset: usize) -> usize {
    let rest = bytes.get(offset..).unwrap_or_default();
    let blanks = rest.iter().take_while(|&&byte| matches!(byte, b' ' | b'\t' | b'\r')).count();
    match rest.get(blanks) {
        Some(b'\n') => offset + blanks + 1,
        None => offset + blanks,
        Some(_) => offset,
    }
}

#[cfg(test)]
mod tests {
    use super::{JsoncError, line_indent, line_start_if_blank};

    #[test]
    fn line_helpers_read_the_line_of_an_offset() {
        let bytes = b"{\n  \t\"a\": 1\n}";
        assert_eq!(line_indent(bytes, 5), Ok("  \t".to_string()));
        assert_eq!(line_start_if_blank(bytes, 5), Ok(2));
        assert_eq!(line_start_if_blank(bytes, 8), Ok(8));
        assert_eq!(line_start_if_blank(bytes, bytes.len()), Ok(bytes.len()));
    }

    #[test]
    fn line_helpers_refuse_an_offset_past_the_end() {
        let bytes = b"[\n  1\n]";
        let past = bytes.len() + 1;
        assert_eq!(line_indent(bytes, past), Err(JsoncError::Malformed { offset: past }));
        assert_eq!(line_start_if_blank(bytes, past), Err(JsoncError::Malformed { offset: past }));
    }
}
