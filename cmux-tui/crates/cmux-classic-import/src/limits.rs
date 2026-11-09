//! The ceilings a classic session must stay under before anything is built
//! from it, so a corrupt or hostile file cannot take unbounded memory.
//!
//! Classic reads its own session with no cap. A heavy quit save (classic
//! keeps 400,000 characters of scrollback per terminal, up to 12 windows of
//! 128 workspaces) passes 64 MB at about 150 full terminals, so the file cap
//! sits far above what classic writes in practice.

use std::io::Read;
use std::path::Path;

use serde_json::{Map, Value};

use crate::decode::Error;

pub const MAX_SNAPSHOT_BYTES: usize = 512 * 1024 * 1024;
pub const MAX_WINDOWS: usize = 64;
pub const MAX_WORKSPACES: usize = 1_000;
pub const MAX_PANELS_PER_WORKSPACE: usize = 256;
const MAX_TOTAL_PANELS: usize = 4_096;
const MAX_LAYOUT_DEPTH: usize = 64;
const MAX_LAYOUT_NODES: usize = 8_192;
const MAX_JSON_NODES: usize = 100_000;
const MAX_ENCODED_JSON_TOKENS: usize = 200_000;
const MAX_JSON_DEPTH: usize = 128;
const MAX_METADATA_STRING_BYTES: usize = 64 * 1024;
const MAX_ENCODED_STRING_BYTES: usize = 4 * 1024 * 1024;
const MAX_TOTAL_ENCODED_STRING_BYTES: usize = 160 * 1024 * 1024;
pub const MAX_SCROLLBACK_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_TOTAL_SCROLLBACK_BYTES: usize = 128 * 1024 * 1024;

/// What one decode has spent so far.
#[derive(Default)]
pub struct Budget {
    panels: usize,
    layout_nodes: usize,
    json_nodes: usize,
    scrollback_bytes: usize,
}

/// `value`'s array when every element is an object; none otherwise (a
/// mixed array counts as absent, as classic's own reader takes it).
pub fn objects(value: Option<&Value>) -> Option<Vec<&Map<String, Value>>> {
    value?.as_array()?.iter().map(Value::as_object).collect()
}

/// `value`'s array when every element is a string.
pub fn strings(value: Option<&Value>) -> Option<Vec<&str>> {
    value?.as_array()?.iter().map(Value::as_str).collect()
}

fn too_complex<T>() -> Result<T, Error> {
    Err(Error::TooComplex)
}

/// The panel and layout ceilings of one workspace.
pub fn validate_workspace(
    workspace: &Map<String, Value>,
    budget: &mut Budget,
) -> Result<(), Error> {
    let panels = objects(workspace.get("panels")).unwrap_or_default();
    if panels.len() > MAX_PANELS_PER_WORKSPACE {
        return too_complex();
    }
    budget.panels += panels.len();
    if budget.panels > MAX_TOTAL_PANELS {
        return too_complex();
    }
    let Some(root) = workspace.get("layout").and_then(Value::as_object) else { return Ok(()) };
    let mut layouts = vec![(root, 0usize)];
    while let Some((value, depth)) = layouts.pop() {
        if depth > MAX_LAYOUT_DEPTH {
            return too_complex();
        }
        budget.layout_nodes += 1;
        if budget.layout_nodes > MAX_LAYOUT_NODES {
            return too_complex();
        }
        if value.get("type").and_then(Value::as_str) == Some("split") {
            let split = value.get("split").and_then(Value::as_object).unwrap_or(value);
            for side in ["first", "second"] {
                if let Some(side) = split.get(side).and_then(Value::as_object) {
                    layouts.push((side, depth + 1));
                }
            }
        } else {
            let pane = value.get("pane").and_then(Value::as_object).unwrap_or(value);
            let ids = strings(pane.get("panelIds")).or_else(|| strings(pane.get("panel_ids")));
            if ids.is_some_and(|ids| ids.len() > MAX_PANELS_PER_WORKSPACE) {
                return too_complex();
            }
        }
    }
    Ok(())
}

/// Bounds every decoded node and string, including metadata the import
/// does not read.
pub fn validate_json(root: &Value, budget: &mut Budget) -> Result<(), Error> {
    let mut pending: Vec<(&Value, Option<&str>)> = vec![(root, None)];
    while let Some((value, key)) = pending.pop() {
        budget.json_nodes += 1;
        if budget.json_nodes > MAX_JSON_NODES {
            return too_complex();
        }
        match value {
            Value::String(text) => {
                if key == Some("scrollback") {
                    if text.len() > MAX_SCROLLBACK_BYTES {
                        return too_complex();
                    }
                    budget.scrollback_bytes += text.len();
                    if budget.scrollback_bytes > MAX_TOTAL_SCROLLBACK_BYTES {
                        return too_complex();
                    }
                } else if text.len() > MAX_METADATA_STRING_BYTES {
                    return too_complex();
                }
            }
            Value::Object(object) => {
                if budget.json_nodes + pending.len() + object.len() > MAX_JSON_NODES {
                    return too_complex();
                }
                for (name, value) in object {
                    if name.len() > MAX_METADATA_STRING_BYTES {
                        return too_complex();
                    }
                    pending.push((value, Some(name)));
                }
            }
            Value::Array(array) => {
                if budget.json_nodes + pending.len() + array.len() > MAX_JSON_NODES {
                    return too_complex();
                }
                pending.extend(array.iter().map(|value| (value, key)));
            }
            _ => {}
        }
    }
    Ok(())
}

/// Rejects large token graphs before the parser builds anything. Classic
/// writes UTF-8 JSON; NUL-bearing input (UTF-16) is not taken here.
pub fn validate_encoded(bytes: &[u8], maximum: usize) -> Result<(), Error> {
    if bytes.len() > maximum {
        return Err(Error::TooLarge { actual: bytes.len(), maximum });
    }
    let is_separator = |byte: u8| matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | b',' | b':');
    let (mut index, mut depth, mut tokens, mut string_bytes) = (0usize, 0usize, 0usize, 0usize);
    while let Some(&byte) = bytes.get(index) {
        match byte {
            0 => return Err(Error::NotASnapshot),
            b'"' => {
                tokens += 1;
                if tokens > MAX_ENCODED_JSON_TOKENS {
                    return too_complex();
                }
                index += 1;
                let (mut encoded, mut closed) = (0usize, false);
                while let Some(&byte) = bytes.get(index) {
                    match byte {
                        b'"' => {
                            index += 1;
                            closed = true;
                            break;
                        }
                        b'\\' => {
                            if index + 1 >= bytes.len() {
                                return Err(Error::NotASnapshot);
                            }
                            encoded += 2;
                            index += 2;
                        }
                        0 => return Err(Error::NotASnapshot),
                        _ => {
                            encoded += 1;
                            index += 1;
                        }
                    }
                    if encoded > MAX_ENCODED_STRING_BYTES {
                        return too_complex();
                    }
                }
                if !closed {
                    return Err(Error::NotASnapshot);
                }
                if encoded > MAX_TOTAL_ENCODED_STRING_BYTES - string_bytes {
                    return too_complex();
                }
                string_bytes += encoded;
            }
            b'{' | b'[' => {
                tokens += 1;
                depth += 1;
                if tokens > MAX_ENCODED_JSON_TOKENS || depth > MAX_JSON_DEPTH {
                    return too_complex();
                }
                index += 1;
            }
            b'}' | b']' => {
                depth = depth.saturating_sub(1);
                index += 1;
            }
            byte if is_separator(byte) => index += 1,
            _ => {
                tokens += 1;
                if tokens > MAX_ENCODED_JSON_TOKENS {
                    return too_complex();
                }
                let mut token_bytes = 0usize;
                while let Some(&byte) = bytes.get(index) {
                    if is_separator(byte) || matches!(byte, b'{' | b'}' | b'[' | b']') {
                        break;
                    }
                    if byte == 0 {
                        return Err(Error::NotASnapshot);
                    }
                    token_bytes += 1;
                    index += 1;
                    if token_bytes > MAX_METADATA_STRING_BYTES {
                        return too_complex();
                    }
                }
            }
        }
    }
    Ok(())
}

/// Reads one file that may be changing through one descriptor, never holding
/// more than `maximum` bytes plus the one that proves it was exceeded. None
/// when there is no file.
pub fn read_capped(path: &Path, maximum: usize) -> Result<Option<Vec<u8>>, Error> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(Error::Io(error.to_string())),
    };
    let mut data = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|error| Error::Io(error.to_string()))?;
    if data.len() > maximum {
        return Err(Error::TooLarge { actual: data.len(), maximum });
    }
    Ok(Some(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_byte_scan_refuses_nul_unclosed_strings_and_deep_nesting() {
        assert_eq!(validate_encoded(b"{\"a\":1}", 100), Ok(()));
        assert_eq!(validate_encoded(b"{\"a\0\":1}", 100), Err(Error::NotASnapshot));
        assert_eq!(validate_encoded(b"{\"a", 100), Err(Error::NotASnapshot));
        assert_eq!(validate_encoded(b"{\"a\\", 100), Err(Error::NotASnapshot));
        assert_eq!(validate_encoded(&b"["[..].repeat(129), 1000), Err(Error::TooComplex));
        assert_eq!(validate_encoded(&b"["[..].repeat(128), 1000), Ok(()));
        assert_eq!(validate_encoded(b"{}", 1), Err(Error::TooLarge { actual: 2, maximum: 1 }));
    }

    #[test]
    fn a_capped_read_stops_one_byte_past_its_limit() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("f.json");
        std::fs::write(&file, b"0123456789").unwrap();
        assert_eq!(read_capped(&file, 10).unwrap().unwrap().len(), 10);
        assert_eq!(read_capped(&file, 4), Err(Error::TooLarge { actual: 5, maximum: 4 }));
        assert_eq!(read_capped(&dir.path().join("none"), 4), Ok(None));
    }
}
