//! cmux Remote's supervisor wire, `remote-host-v1` (docs/cmux-remote.md, IPC),
//! the same bytes the Swift host speaks (`CmuxRemoteWire/RemoteWire.swift`):
//! UTF-8 JSON, one object per line. A request is
//! `{"id":N,"method":M,"params":{...}}`; its answer
//! `{"id":N,"ok":true,"result":{...}}` or
//! `{"id":N,"ok":false,"error":{"code":C,"message":T}}`; a push
//! `{"type":"event","event":E,...}`.

use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt};

/// The supervisor protocol range this build speaks. A daemon and a host pick
/// the highest version both speak ([`negotiate`]); raise the maximum only with
/// a negotiated addition, so an adopted host of an older build keeps working.
pub const PROTOCOL_MIN: u64 = 1;
pub const PROTOCOL_MAX: u64 = 1;
/// The longest line either side accepts.
pub const MAX_LINE_BYTES: usize = 16 << 20;

/// The version both sides speak, or None when their ranges do not meet.
pub fn negotiate(peer_min: u64, peer_max: u64) -> Option<u64> {
    let chosen = peer_max.min(PROTOCOL_MAX);
    (chosen >= peer_min.max(PROTOCOL_MIN)).then_some(chosen)
}

pub fn answer(id: &Value, result: Value) -> Value {
    json!({"id": id, "ok": true, "result": result})
}

pub fn failure(id: &Value, code: &str, message: impl Into<String>) -> Value {
    json!({"id": id, "ok": false, "error": {"code": code, "message": message.into()}})
}

pub fn event(name: &str, fields: Map<String, Value>) -> Value {
    let mut all = fields;
    all.insert("type".into(), json!("event"));
    all.insert("event".into(), json!(name));
    Value::Object(all)
}

/// One line: the JSON text and `\n`.
pub fn encode(value: &Value) -> Vec<u8> {
    let mut line = serde_json::to_vec(value).unwrap_or_else(|_| b"{}".to_vec());
    line.push(b'\n');
    line
}

/// Reads one line of at most [`MAX_LINE_BYTES`]. `Ok(None)` at EOF; an error
/// for a longer line or a partial last line.
pub async fn read_line<R: AsyncBufRead + Unpin>(reader: &mut R) -> std::io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let count = (&mut *reader).take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line).await?;
    if count == 0 {
        return Ok(None);
    }
    if line.last() != Some(&b'\n') {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "line too long or truncated"));
    }
    line.pop();
    Ok(Some(line))
}

/// One JSON object line, or None at EOF; a line that is not an object is skipped.
pub async fn read_object<R: AsyncBufRead + Unpin>(reader: &mut R) -> std::io::Result<Option<Map<String, Value>>> {
    loop {
        let Some(line) = read_line(reader).await? else { return Ok(None) };
        if let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&line) {
            return Ok(Some(object));
        }
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) || !text.is_ascii() {
        return None;
    }
    (0..text.len()).step_by(2).map(|index| u8::from_str_radix(&text[index..index + 2], 16).ok()).collect()
}

/// Compares two secrets in time that does not depend on where they differ.
pub fn same_secret(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() || left.is_empty() {
        return false;
    }
    left.iter().zip(right).fold(0_u8, |difference, (a, b)| difference | (a ^ b)) == 0
}

/// 32 random bytes.
pub fn make_secret() -> std::io::Result<[u8; 32]> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| std::io::Error::other(format!("{error}")))?;
    Ok(bytes)
}

/// The SHA-256 of `bytes` as 64 lowercase hex digits.
pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    hex(&Sha256::digest(bytes))
}

/// The SHA-256 of a file's content as 64 lowercase hex digits.
pub fn sha256_file(path: &std::path::Path) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex(&hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn negotiation_picks_the_highest_common_version() {
        assert_eq!(negotiate(1, 1), Some(1));
        assert_eq!(negotiate(1, 9), Some(PROTOCOL_MAX));
        assert_eq!(negotiate(2, 9), None);
        assert_eq!(negotiate(0, 0), None);
    }

    #[test]
    fn hex_round_trips_and_rejects_odd_or_non_hex() {
        assert_eq!(unhex(&hex(&[0, 1, 254, 255])), Some(vec![0, 1, 254, 255]));
        assert_eq!(unhex("abc"), None);
        assert_eq!(unhex("zz"), None);
    }

    #[test]
    fn secrets_compare_by_value_and_length() {
        assert!(same_secret(b"abcd", b"abcd"));
        assert!(!same_secret(b"abcd", b"abce"));
        assert!(!same_secret(b"abc", b"abcd"));
        assert!(!same_secret(b"", b""));
    }

    #[tokio::test]
    async fn read_line_refuses_an_unterminated_line() {
        let mut reader = tokio::io::BufReader::new(&b"{\"a\":1}\n{\"b\""[..]);
        assert_eq!(read_line(&mut reader).await.unwrap(), Some(b"{\"a\":1}".to_vec()));
        assert!(read_line(&mut reader).await.is_err());
    }
}
