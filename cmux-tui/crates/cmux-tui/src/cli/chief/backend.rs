//! One client of Chief/Home chats for both conversation owners: the local
//! owner of the session daemon, and the cloud owners through the daemon's
//! cloud proxy (`cloud-conversations-v1`). Each operation is the call Home
//! itself makes; there is no second store (plans/cmux-next/chief-tui.md).
//!
//! Cloud events come as `cloud-conversation-*` subscribe events; `cloud_item`
//! turns each into the item shape of the local `conversation.events` stream,
//! so the chat view, the turn watcher and the scripts read one shape.

use std::io::Read as _;
use std::path::Path;
use std::sync::mpsc::Sender;

use serde_json::{Value, json};

use super::adapter::AGENT_MUX;
use super::link::{Link, LinkError, new_message_id};

/// Which owner a chat belongs to.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) enum Owner {
    #[default]
    Local,
    Cloud,
}

impl Owner {
    pub(super) fn name(self) -> &'static str {
        match self {
            Owner::Local => "local",
            Owner::Cloud => "cloud",
        }
    }
}

/// The largest attachment piece sent in one `chunk` (the owner takes 4 MiB).
const CHUNK: usize = 2 << 20;
/// The largest file `--attach` reads (the owners' limit).
const MAX_ATTACHMENT: u64 = 100_000_000;
/// The capability a cloud events connection echoes to get typing.
const CLOUD_TYPING: &str = "cloud-conversation-typing-v1";

/// A cloud lease the CLI sets on a daemon that the app does not lease.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct CloudLease {
    pub api_base_url: String,
    /// `None`: a tailnet (self-hosted) lease with no token.
    pub access_token: Option<String>,
}

/// A chat client on one daemon connection.
pub(super) struct ChatClient {
    pub link: Link,
    pub owner: Owner,
}

impl ChatClient {
    /// Sets `lease` on the daemon (`cloud-session-set`).
    pub(super) fn lease(&mut self, lease: &CloudLease) -> Result<(), LinkError> {
        let params = match &lease.access_token {
            Some(token) => json!({
                "api_base_url": lease.api_base_url,
                "access_token": token,
                // A token file carries no expiry: the cloud checks the token itself.
                "expires_at": 4_102_444_800_000_u64,
                "client_version": concat!("cmux-chief/", env!("CARGO_PKG_VERSION")),
            }),
            None => json!({
                "api_base_url": lease.api_base_url,
                "auth": "tailscale",
                "client_version": concat!("cmux-chief/", env!("CARGO_PKG_VERSION")),
            }),
        };
        self.link.command("cloud-session-set", params).map(|_| ())
    }

    /// The chats, as conversation summaries (cloud inbox entries carry the
    /// same `id`, `title` and `last_seq` keys after `inbox_summary`).
    pub(super) fn chats(&mut self) -> Result<Vec<Value>, LinkError> {
        match self.owner {
            Owner::Local => {
                let listed = self.link.call("conversation.list", json!({}), None)?;
                Ok(listed.as_array().cloned().unwrap_or_default())
            }
            Owner::Cloud => {
                let listed = self.link.command("cloud-inbox-list", json!({}))?;
                let entries = listed.get("entries").and_then(Value::as_array);
                Ok(entries.into_iter().flatten().map(inbox_summary).collect())
            }
        }
    }

    /// The summary and the last `tail` messages, oldest first.
    pub(super) fn snapshot(
        &mut self,
        conversation: &str,
        tail: usize,
    ) -> Result<(Value, Vec<Value>), LinkError> {
        let value = match self.owner {
            Owner::Local => self.link.call(
                "conversation.get",
                json!({"conversation": conversation, "tail": tail.min(500)}),
                None,
            )?,
            Owner::Cloud => self.link.command(
                "cloud-conversation-snapshot",
                json!({"conversation": conversation, "tail": tail.clamp(1, 50)}),
            )?,
        };
        let messages = value.get("messages").and_then(Value::as_array).cloned().unwrap_or_default();
        let messages = if tail == 0 { Vec::new() } else { messages };
        Ok((value.get("conversation").cloned().unwrap_or(Value::Null), messages))
    }

    /// Up to `limit` messages with seq below `before`, oldest first.
    pub(super) fn history(
        &mut self,
        conversation: &str,
        before: u64,
        limit: usize,
    ) -> Result<Vec<Value>, LinkError> {
        let params = json!({"conversation": conversation, "before_seq": before, "limit": limit.clamp(1, 200)});
        match self.owner {
            Owner::Local => {
                let value = self.link.call("conversation.history", params, None)?;
                Ok(value.as_array().cloned().unwrap_or_default())
            }
            Owner::Cloud => {
                let value = self.link.command("cloud-conversation-history", params)?;
                Ok(value.get("messages").and_then(Value::as_array).cloned().unwrap_or_default())
            }
        }
    }

    /// The thread of `root`: the root, then its replies.
    pub(super) fn thread(&mut self, conversation: &str, root: &str) -> Result<Value, LinkError> {
        let cmd = match self.owner {
            Owner::Local => "conversation-thread",
            Owner::Cloud => "cloud-conversation-thread",
        };
        self.link.command(cmd, json!({"conversation": conversation, "root": root, "limit": 200}))
    }

    /// Applies one op (`conversation-op` / `cloud-conversation-op`) under
    /// `key`; the owner's result (`rev`, `seq`, `change`).
    pub(super) fn op(
        &mut self,
        conversation: &str,
        key: &str,
        op: Value,
    ) -> Result<Value, LinkError> {
        let cmd = match self.owner {
            Owner::Local => "conversation-op",
            Owner::Cloud => "cloud-conversation-op",
        };
        // No `origin`: the cloud owner records `cli`, never the app's `user`.
        self.link
            .command(cmd, json!({"conversation": conversation, "idempotency_key": key, "op": op}))
    }

    /// Sends `parts` as the person (a reply to `reply_to`, in the thread of
    /// `thread_root`, when given); the new message.
    pub(super) fn send(
        &mut self,
        conversation: &str,
        parts: Vec<Value>,
        reply_to: Option<Value>,
        thread_root: Option<&str>,
    ) -> Result<Value, LinkError> {
        let key = new_message_id();
        let mut op = json!({"kind": "message.send", "client_msg_id": key, "parts": parts});
        if let Some(fields) = op.as_object_mut() {
            if let Some(reply_to) = reply_to {
                fields.insert("reply_to".into(), reply_to);
            }
            if let Some(root) = thread_root {
                fields.insert("thread_root".into(), json!(root));
            }
        }
        let result = self.op(conversation, &key, op)?;
        Ok(sent_message(&result))
    }

    /// Uploads the file at `path` into `conversation`; the `attachment` part
    /// that names it.
    pub(super) fn upload(&mut self, conversation: &str, path: &Path) -> Result<Value, String> {
        let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if !meta.is_file() {
            return Err(format!("{} is not a file", path.display()));
        }
        if meta.len() > MAX_ATTACHMENT {
            return Err(format!("{} is larger than 100 MB", path.display()));
        }
        let mut bytes = Vec::with_capacity(meta.len() as usize);
        std::fs::File::open(path)
            .and_then(|mut file| file.read_to_end(&mut bytes))
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file").to_owned();
        let mut mime = mime_type(&name);
        // Clients send UTF-8 text of any name as text/plain (cmux-conversation GENERIC_FILE_TYPE).
        if mime == "application/octet-stream" && std::str::from_utf8(&bytes).is_ok() {
            mime = "text/plain";
        }
        let hash = sha256_hex(&bytes);
        let cmd = match self.owner {
            Owner::Local => "conversation-attachment-upload",
            Owner::Cloud => "cloud-attachment-upload",
        };
        let refused = |e: LinkError| e.to_string();
        let begun = self
            .link
            .command(
                cmd,
                json!({"op": "begin", "conversation": conversation, "sha256": hash,
                       "byte_count": bytes.len(), "mime_type": mime, "name": name}),
            )
            .map_err(refused)?;
        if let Some(upload) = begun.get("upload").and_then(Value::as_str) {
            let mut offset = 0usize;
            for piece in bytes.chunks(CHUNK) {
                use base64::Engine as _;
                let data = base64::engine::general_purpose::STANDARD.encode(piece);
                self.link
                    .command(
                        cmd,
                        json!({"op": "chunk", "upload": upload, "piece": "original",
                               "offset": offset, "data": data}),
                    )
                    .map_err(refused)?;
                offset += piece.len();
            }
            self.link.command(cmd, json!({"op": "commit", "upload": upload})).map_err(refused)?;
        }
        Ok(json!({"type": "attachment", "hash": hash, "name": name, "mime_type": mime,
                  "byte_count": bytes.len()}))
    }

    /// Turns this connection into `conversation`'s event stream: the items
    /// of `conversation.events` (a snapshot of the last `tail` messages
    /// first), forwarded to `sink` until the stream ends. The handle ends
    /// the stream when dropped.
    pub(super) fn into_events(
        self,
        conversation: &str,
        tail: usize,
        sink: Sender<super::Input>,
    ) -> Result<super::link::EventsHandle, LinkError> {
        match self.owner {
            Owner::Local => self.link.into_events(conversation, tail, sink),
            Owner::Cloud => self.link.into_cloud_events(conversation, tail, sink),
        }
    }
}

/// The message an op's result carries (`change.message`, or the cloud
/// owner's `value.message`).
pub(super) fn sent_message(result: &Value) -> Value {
    result
        .pointer("/change/message")
        .or_else(|| result.pointer("/value/message"))
        .or_else(|| result.pointer("/value/change/message"))
        .cloned()
        .unwrap_or(Value::Null)
}

/// A cloud inbox entry as a conversation summary: `id`, `title`, `last_seq`
/// and `unread`, the entry kept under `inbox`.
pub(super) fn inbox_summary(entry: &Value) -> Value {
    let id = entry.get("conversation").or_else(|| entry.get("id")).cloned().unwrap_or(Value::Null);
    json!({
        "id": id,
        "owner": "cloud",
        "title": entry.get("title").cloned().unwrap_or(json!("")),
        "last_seq": entry.get("last_seq").cloned().unwrap_or(json!(0)),
        "unread": entry.get("unread").cloned().unwrap_or(json!(0)),
        "participants": entry.get("participants").cloned().unwrap_or(json!([])),
        "inbox": entry,
    })
}

/// The Chief of a chat: `agent_mux` when it takes part, else its first agent
/// participant, else `agent_mux`.
pub(super) fn chief_of(summary: &Value) -> String {
    // A cloud inbox entry names no participants; a DM with a Chief names its peer.
    if let Some(peer) = summary.pointer("/inbox/dm_peer").and_then(Value::as_str)
        && peer.starts_with("agent_")
    {
        return peer.to_owned();
    }
    let participants = summary.get("participants").and_then(Value::as_array);
    let agents: Vec<&str> = participants
        .into_iter()
        .flatten()
        .filter(|p| {
            p.get("kind").and_then(Value::as_str) == Some("agent")
                || p.get("id").and_then(Value::as_str).is_some_and(|id| id.starts_with("agent_"))
        })
        .filter_map(|p| p.get("id").and_then(Value::as_str))
        .collect();
    if agents.contains(&AGENT_MUX) {
        return AGENT_MUX.into();
    }
    agents.first().map_or_else(|| AGENT_MUX.into(), |id| (*id).to_owned())
}

/// The unread count of a local summary for `user_local`: messages after its
/// read cursor.
pub(super) fn unread(summary: &Value) -> u64 {
    if let Some(n) = summary.get("unread").and_then(Value::as_u64) {
        return n;
    }
    let last = summary.get("last_seq").and_then(Value::as_u64).unwrap_or(0);
    let cursor = summary.pointer("/read_cursors/user_local").and_then(Value::as_u64).unwrap_or(0);
    last.saturating_sub(cursor)
}

/// The `conversation.events` item of one cloud subscribe event of
/// `conversation`, or None (another conversation, another event).
pub(super) fn cloud_item(event: &Value, conversation: &str) -> Option<Value> {
    if event.get("conversation").and_then(Value::as_str) != Some(conversation) {
        return None;
    }
    match event.get("event")?.as_str()? {
        "cloud-conversation-changed" => {
            let change = event.get("change")?;
            let rev = event.get("rev").cloned().unwrap_or(Value::Null);
            match change.get("kind")?.as_str()? {
                "message" => Some(json!({"type": "message", "conversation": conversation,
                    "rev": rev, "message": change.get("message")?})),
                "message-updated" => Some(json!({"type": "message_updated",
                    "conversation": conversation, "rev": rev, "message": change.get("message")?})),
                "read-cursor" => Some(json!({"type": "read_cursor", "conversation": conversation,
                    "participant": change.get("participant")?, "seq": change.get("seq")?})),
                "conversation" => {
                    Some(json!({"type": "conversation", "conversation": conversation,
                    "summary": change.get("conversation")?}))
                }
                _ => None,
            }
        }
        "cloud-conversation-resynced" => Some(json!({"type": "snapshot",
            "conversation": event.get("summary")?, "messages": event.get("messages")?,
            "typing": []})),
        "cloud-conversation-typing" => Some(json!({"type": "typing", "conversation": conversation,
            "participant": event.get("participant")?, "on": event.get("on")?})),
        _ => None,
    }
}

/// The snapshot item of a `cloud-conversation-snapshot` result.
pub(super) fn cloud_snapshot_item(result: &Value) -> Value {
    json!({"type": "snapshot", "conversation": result.get("conversation").cloned().unwrap_or(Value::Null),
           "messages": result.get("messages").cloned().unwrap_or(json!([])), "typing": []})
}

/// The `set-client-info` capabilities a cloud events connection echoes.
pub(super) fn cloud_event_capabilities() -> Value {
    json!([CLOUD_TYPING])
}

/// The MIME type of a file name, by extension (the owners' allow list
/// decides; an unknown type goes as `application/octet-stream`).
pub(super) fn mime_type(name: &str) -> &'static str {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "pdf" => "application/pdf",
        "txt" | "log" => "text/plain",
        "md" => "text/markdown",
        "json" => "application/json",
        "csv" => "text/csv",
        "aac" => "audio/aac",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "m4a" => "audio/mp4",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "zip" => "application/zip",
        _ => "application/octet-stream",
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    let digest = sha2::Sha256::digest(bytes);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}
