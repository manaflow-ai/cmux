//! JSONC to JSON, the dialect cmux-next.json is written in. Shared by the Mac's settings readers
//! (cmux-tui-util) and the phone host (cmux-mobile-host), so both read one file the same way.
//!
//! Every read is `get`, never an index or a slice: the crate's panic ratchet baseline is 0.

/// JSONC to JSON: drops `//` and `/* */` comments, then trailing commas,
/// outside strings (the dialect the app's `JSONC` parser reads).
pub fn strip_jsonc(text: &str) -> String {
    drop_trailing_commas(&drop_comments(text))
}

/// Copies `bytes[start..end]` (clamped) onto `output`. Only ASCII bytes
/// (comment markers, commas) are ever left out, so each kept run starts and
/// ends on a character boundary and `from_utf8_lossy` copies it unchanged.
fn keep(output: &mut String, bytes: &[u8], start: usize, end: usize) {
    if let Some(run) = bytes.get(start..end.min(bytes.len())) {
        output.push_str(&String::from_utf8_lossy(run));
    }
}

/// The index just past the string whose body starts at `index` (after its opening quote).
fn skip_string(bytes: &[u8], mut index: usize) -> usize {
    while let Some(&byte) = bytes.get(index) {
        match byte {
            b'\\' => index += 2,
            b'"' => return index + 1,
            _ => index += 1,
        }
    }
    index
}

/// The text without comments; strings are copied unchanged.
fn drop_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start) = (0, 0);
    while let Some(&byte) = bytes.get(index) {
        match (byte, bytes.get(index + 1)) {
            (b'"', _) => index = skip_string(bytes, index + 1),
            (b'/', Some(b'/')) => {
                keep(&mut output, bytes, start, index);
                while bytes.get(index).is_some_and(|byte| *byte != b'\n') {
                    index += 1;
                }
                start = index;
            }
            (b'/', Some(b'*')) => {
                keep(&mut output, bytes, start, index);
                index += 2;
                while index < bytes.len()
                    && !(bytes.get(index) == Some(&b'*') && bytes.get(index + 1) == Some(&b'/'))
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
                start = index;
            }
            _ => index += 1,
        }
    }
    keep(&mut output, bytes, start, bytes.len());
    output
}

/// Removes a comma whose next non-space byte closes an object or array.
fn drop_trailing_commas(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start) = (0, 0);
    while let Some(&byte) = bytes.get(index) {
        if byte == b'"' {
            index = skip_string(bytes, index + 1);
            continue;
        }
        if byte == b','
            && matches!(
                bytes
                    .get(index + 1..)
                    .unwrap_or_default()
                    .iter()
                    .find(|byte| !byte.is_ascii_whitespace()),
                Some(b'}' | b']')
            )
        {
            keep(&mut output, bytes, start, index);
            start = index + 1;
        }
        index += 1;
    }
    keep(&mut output, bytes, start, bytes.len());
    output
}

#[cfg(test)]
mod tests {
    use super::strip_jsonc;

    #[test]
    fn comments_and_trailing_commas_go_strings_stay() {
        let text = "{\n  // note é\n  \"a\": \"x // y, }\", /* b */ \"b\": [1, 2,],\n}";
        assert_eq!(strip_jsonc(text), "{\n  \n  \"a\": \"x // y, }\",  \"b\": [1, 2]\n}");
        assert_eq!(strip_jsonc("\"é\\\"\" // tail"), "\"é\\\"\" ");
        assert_eq!(strip_jsonc("[1 /* open"), "[1 ");
        assert_eq!(strip_jsonc("\"unterminated \\"), "\"unterminated \\");
        assert_eq!(strip_jsonc(""), "");
    }
}
