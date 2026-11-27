//! The carrier side: the mobile handshake and one bounded, cancel-safe line
//! read from the machine daemon.

use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

/// The daemon holds a Unix client that declares this to the phone floor.
pub const CLOUD_MOBILE_CHAT: &str = "cloud-mobile-chat-v1";
pub const CONVERSATION_TABS: &str = "conversation-tabs-v1";
pub const AGENT_SESSION_TABS: &str = "agent-session-tabs-v1";
/// The longest line the daemon may send on the carrier.
pub const MAX_NATIVE_LINE: usize = 8 * 1024 * 1024;

/// Why the carrier failed: a stable code (`unavailable`, `forbidden`,
/// `bad_request`) and a message for people.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fault {
    pub code: &'static str,
    pub message: String,
}

impl Fault {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

impl std::fmt::Display for Fault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for Fault {}

/// Identify the machine's supported policy before marking this connection
/// mobile: an old daemon may accept unknown client capabilities without
/// enforcing them, so one that does not list [`CLOUD_MOBILE_CHAT`] is refused
/// before `set-client-info` is sent.
pub async fn handshake<R, W>(read: &mut R, write: &mut W) -> Result<(), Fault>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    for request in [
        json!({"cmd":"identify","id":"cloud-mobile-identify"}),
        json!({"cmd":"set-client-info","id":"cloud-mobile-host",
            "kind":"ios","device_kind":"iphone",
            "capabilities":[CLOUD_MOBILE_CHAT,CONVERSATION_TABS,AGENT_SESSION_TABS]}),
    ] {
        let closed = |_| Fault::new("unavailable", "Cloud carrier closed");
        write.write_all(request.to_string().as_bytes()).await.map_err(closed)?;
        write.write_all(b"\n").await.map_err(closed)?;
        let bytes = read_line(read, &mut Vec::new()).await?;
        let response: Value = serde_json::from_slice(&bytes).map_err(|_| {
            Fault::new("unavailable", "Cloud carrier returned an invalid handshake")
        })?;
        if response.get("id") != request.get("id")
            || response.get("ok").and_then(Value::as_bool) != Some(true)
        {
            return Err(Fault::new("forbidden", "Cloud carrier refused mobile chat handshake"));
        }
        if request.get("cmd").and_then(Value::as_str) == Some("identify")
            && !response
                .pointer("/data/capabilities")
                .and_then(Value::as_array)
                .is_some_and(|caps| caps.iter().any(|cap| cap == CLOUD_MOBILE_CHAT))
        {
            return Err(Fault::new(
                "forbidden",
                "Cloud machine does not support phone prompt restrictions",
            ));
        }
    }
    Ok(())
}

/// One line from `reader`, at most [`MAX_NATIVE_LINE`] bytes, without its
/// newline. The bytes read so far stay in `line`: if a `select!` cancels this
/// read, the next call resumes from the same partial line.
pub async fn read_line<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    line: &mut Vec<u8>,
) -> Result<Vec<u8>, Fault> {
    loop {
        let chunk = reader
            .fill_buf()
            .await
            .map_err(|_| Fault::new("unavailable", "Cloud carrier closed"))?;
        if chunk.is_empty() {
            return Err(Fault::new("unavailable", "Cloud carrier closed"));
        }
        let newline = chunk.iter().position(|byte| *byte == b'\n');
        let take = newline.unwrap_or(chunk.len());
        if line.len().saturating_add(take) > MAX_NATIVE_LINE {
            return Err(Fault::new("bad_request", "Cloud carrier line is too large"));
        }
        line.extend_from_slice(chunk.get(..take).unwrap_or(chunk));
        reader.consume(take + usize::from(newline.is_some()));
        if newline.is_some() {
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            return Ok(std::mem::take(line));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::BufReader;

    #[tokio::test]
    async fn handshake_refuses_old_daemons_before_sending_mobile_commands() {
        for (caps, allowed) in [
            (json!([]), false),
            (json!([AGENT_SESSION_TABS]), false),
            (json!([CLOUD_MOBILE_CHAT]), true),
        ] {
            let replies = format!(
                "{}\n{}\n",
                json!({"id":"cloud-mobile-identify","ok":true,"data":{"capabilities":caps}}),
                json!({"id":"cloud-mobile-host","ok":true})
            );
            let mut read = std::io::Cursor::new(replies.into_bytes());
            let mut write = Vec::new();
            assert_eq!(handshake(&mut read, &mut write).await.is_ok(), allowed);
            let commands: Vec<Value> = String::from_utf8(write)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            assert_eq!(commands[0]["cmd"], "identify");
            assert_eq!(commands.len(), if allowed { 2 } else { 1 });
            if allowed {
                assert_eq!(commands[1]["capabilities"][0], CLOUD_MOBILE_CHAT);
            }
        }
    }

    #[tokio::test]
    async fn read_line_keeps_partial_data_when_cancelled() {
        let (mut writer, reader) = tokio::io::duplex(64);
        writer.write_all(b"{\"id\":1").await.unwrap();
        let mut reader = BufReader::new(reader);
        let mut partial = Vec::new();
        assert!(
            tokio::time::timeout(Duration::from_millis(5), read_line(&mut reader, &mut partial))
                .await
                .is_err()
        );
        assert_eq!(partial, br#"{"id":1"#);
        writer.write_all(b"}\n").await.unwrap();
        assert_eq!(read_line(&mut reader, &mut partial).await.unwrap(), br#"{"id":1}"#);
    }

    #[tokio::test]
    async fn read_line_rejects_oversize_before_newline() {
        let (mut writer, reader) = tokio::io::duplex(MAX_NATIVE_LINE + 16);
        writer.write_all(&vec![b'x'; MAX_NATIVE_LINE + 1]).await.unwrap();
        let mut reader = BufReader::new(reader);
        let mut partial = Vec::new();
        assert_eq!(read_line(&mut reader, &mut partial).await.unwrap_err().code, "bad_request");
    }
}
