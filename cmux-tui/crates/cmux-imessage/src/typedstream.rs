//! Text out of `message.attributedBody`.
//!
//! Since macOS Ventura most messages keep `message.text` empty and store the text only in
//! `attributedBody`, an `NSAttributedString` archived with `NSArchiver` (the legacy "typedstream"
//! format). The string is the first object after the `NSString` class name: a `+` (C string type
//! tag), then a typedstream integer length, then that many UTF-8 bytes. Typedstream integers are a
//! single signed byte, or `0x81` followed by a little-endian `i16`, or `0x82` followed by a
//! little-endian `i32`.

const CLASS_NAME: &[u8] = b"NSString";
/// How far past the class name the `+` tag may sit (class version and reference bytes).
const TAG_WINDOW: usize = 16;

/// The plain text of an `attributedBody` blob, or `None` when it holds no string this decoder
/// can read. Never panics on malformed input.
pub fn decode_attributed_body(blob: &[u8]) -> Option<String> {
    let class_at = find(blob, CLASS_NAME)?;
    let after_class = class_at + CLASS_NAME.len();
    let window_end = blob.len().min(after_class + TAG_WINDOW);
    let tag_offset = blob.get(after_class..window_end)?.iter().position(|&b| b == b'+')?;
    let mut cursor = after_class + tag_offset + 1;
    let length = read_integer(blob, &mut cursor)?;
    let length = usize::try_from(length).ok()?;
    let end = cursor.checked_add(length)?;
    let bytes = blob.get(cursor..end)?;
    let text = String::from_utf8_lossy(bytes).into_owned();
    if text.is_empty() { None } else { Some(text) }
}

fn read_integer(blob: &[u8], cursor: &mut usize) -> Option<i64> {
    let head = *blob.get(*cursor)?;
    *cursor += 1;
    match head {
        0x81 => {
            let bytes: [u8; 2] = blob.get(*cursor..*cursor + 2)?.try_into().ok()?;
            *cursor += 2;
            Some(i64::from(u16::from_le_bytes(bytes)))
        }
        0x82 => {
            let bytes: [u8; 4] = blob.get(*cursor..*cursor + 4)?.try_into().ok()?;
            *cursor += 4;
            Some(i64::from(u32::from_le_bytes(bytes)))
        }
        byte => Some(i64::from(byte as i8)).filter(|value| *value >= 0),
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}
