//! Raw protocol handlers for local conversation attachments
//! (`local-attachments-v1`, conversation_attachments.rs): chunked uploads
//! by SHA-256, chunked reads and download links, on trusted local
//! connections and, with `ws-attachments-v1`, authenticated WebSocket
//! connections (the same clients as `ws-conversations-v1`). The actor is
//! always the connection's principal. Refusals carry `error_code`
//! `attachment_rejected` (or `conversation_rejected` for a participant or
//! conversation refusal) and the reason as the error text.

use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::conversation_store::attachments::{
    DerivedDeclaration, MAX_CHUNK_BYTES, Piece, UploadDeclaration,
};

/// Attachment uploads, reads and download links on an authenticated
/// WebSocket connection (a page that presented the daemon's credential or
/// an approved pairing), and `GET /attachments/<token>` on the listener
/// (attachment_http.rs, byte ranges for video).
pub const WS_ATTACHMENTS_CAPABILITY: &str = "ws-attachments-v1";

/// `conversation-attachment-upload`. `op` selects the step and the fields
/// it reads: `begin` (`conversation` and the declaration), `chunk`
/// (`upload`, `piece`, `offset`, `data`: base64, at most 4 MiB decoded),
/// `commit` and `cancel` (`upload`).
#[derive(Deserialize)]
pub(super) struct UploadParams {
    pub(super) op: String,
    #[serde(default)]
    pub(super) conversation: Option<String>,
    #[serde(default)]
    pub(super) sha256: Option<String>,
    #[serde(default)]
    pub(super) byte_count: Option<u64>,
    #[serde(default)]
    pub(super) mime_type: Option<String>,
    #[serde(default)]
    pub(super) name: Option<String>,
    #[serde(default)]
    pub(super) width: Option<u32>,
    #[serde(default)]
    pub(super) height: Option<u32>,
    #[serde(default)]
    pub(super) duration_ms: Option<u64>,
    /// A video's poster `{sha256, byte_count, mime_type}`.
    #[serde(default)]
    pub(super) poster: Option<Value>,
    /// An image's preview `{sha256, byte_count, mime_type}`.
    #[serde(default)]
    pub(super) preview: Option<Value>,
    #[serde(default)]
    pub(super) upload: Option<String>,
    /// `original`, `poster` or `preview`.
    #[serde(default)]
    pub(super) piece: Option<String>,
    #[serde(default)]
    pub(super) offset: Option<u64>,
    #[serde(default)]
    pub(super) data: Option<String>,
}

/// `conversation-attachment-read`: up to `length` (default and maximum
/// 4 MiB) bytes of one variant (`original`, `poster` or `preview`) from `offset`.
#[derive(Deserialize)]
pub(super) struct ReadParams {
    pub(super) conversation: String,
    pub(super) hash: String,
    #[serde(default)]
    pub(super) variant: Option<String>,
    #[serde(default)]
    pub(super) offset: Option<u64>,
    #[serde(default)]
    pub(super) length: Option<u64>,
}

pub(super) fn required<T>(value: Option<T>, field: &str) -> anyhow::Result<T> {
    value.ok_or_else(|| anyhow::anyhow!("bad request: {field} is required"))
}

pub(super) fn piece(value: Option<String>, field: &str) -> anyhow::Result<Piece> {
    match value.as_deref() {
        None | Some("original") => Ok(Piece::Original),
        Some("poster") => Ok(Piece::Poster),
        Some("preview") => Ok(Piece::Preview),
        Some(other) => {
            anyhow::bail!("bad request: {field} must be original, poster or preview, not {other:?}")
        }
    }
}

pub(super) fn derived(
    value: Option<Value>,
    field: &str,
) -> anyhow::Result<Option<DerivedDeclaration>> {
    value
        .filter(|value| !value.is_null())
        .map(|value| super::conversations::decode(value, field))
        .transpose()
}

/// `conversation-attachment-link`: a download link to one variant of a
/// record the caller may read (the same rule as `conversation-attachment-read`).
/// `name` (optional, checked like a part's name) is the file name the
/// download offers.
#[derive(Deserialize)]
pub(super) struct LinkParams {
    pub(super) conversation: String,
    pub(super) hash: String,
    #[serde(default)]
    pub(super) variant: Option<String>,
    #[serde(default)]
    pub(super) name: Option<String>,
}

/// The person's own clients: a Unix socket connection or an authenticated
/// WebSocket connection (never a relayed remote device).
fn require_owner_client(mux: &Mux, client: u64) -> anyhow::Result<()> {
    anyhow::ensure!(
        mux.control_clients.is_owner_client(client),
        "local attachments require a trusted local or authenticated WebSocket connection"
    );
    Ok(())
}

/// `conversation-attachment-upload`, one step per call.
pub(super) fn put(mux: &Mux, client: u64, params: UploadParams) -> anyhow::Result<Value> {
    require_owner_client(mux, client)?;
    let actor = mux.conversation_principal(client);
    match params.op.as_str() {
        "begin" => {
            let conversation = required(params.conversation, "conversation")?;
            let declaration = UploadDeclaration {
                sha256: required(params.sha256, "sha256")?,
                byte_count: required(params.byte_count, "byte_count")?,
                mime_type: required(params.mime_type, "mime_type")?,
                name: required(params.name, "name")?,
                width: params.width,
                height: params.height,
                duration_ms: params.duration_ms,
                poster: derived(params.poster, "poster")?,
                preview: derived(params.preview, "preview")?,
            };
            let reply = mux.with_conversations(|store| {
                store.attachment_begin(client, &actor, &conversation, &declaration)
            })?;
            Ok(serde_json::to_value(reply)?)
        }
        "chunk" => {
            let upload = required(params.upload, "upload")?;
            let piece = piece(params.piece, "piece")?;
            let offset = required(params.offset, "offset")?;
            let data = required(params.data, "data")?;
            // Bound the decode by the encoded size before allocating.
            anyhow::ensure!(
                data.len() <= MAX_CHUNK_BYTES.div_ceil(3) * 4,
                crate::conversation_store::attachments::AttachmentRejected("chunk_too_large")
            );
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(data.as_bytes())
                .map_err(|_| anyhow::anyhow!("bad request: data must be base64"))?;
            let received = mux.with_conversations(|store| {
                store.attachment_chunk(client, &upload, piece, offset, &bytes)
            })?;
            Ok(json!({"received": received}))
        }
        "commit" => {
            let upload = required(params.upload, "upload")?;
            let stored =
                mux.with_conversations(|store| store.attachment_commit(client, &upload))?;
            Ok(json!({"stored": stored}))
        }
        "cancel" => {
            let upload = required(params.upload, "upload")?;
            mux.with_conversations(|store| store.attachment_cancel(client, &upload))?;
            Ok(json!({}))
        }
        other => {
            anyhow::bail!("bad request: op must be begin, chunk, commit or cancel, not {other:?}")
        }
    }
}

pub(super) fn read(mux: &Mux, client: u64, params: ReadParams) -> anyhow::Result<Value> {
    require_owner_client(mux, client)?;
    let actor = mux.conversation_principal(client);
    let ReadParams { conversation, hash, variant, offset, length } = params;
    let variant = piece(variant, "variant")?;
    let offset = offset.unwrap_or(0);
    let length =
        length.map_or(MAX_CHUNK_BYTES, |length| usize::try_from(length).unwrap_or(usize::MAX));
    let reply = mux.with_conversations(|store| {
        store.attachment_read(&actor, &conversation, &hash, variant, offset, length)
    })?;
    Ok(json!({
        "hash": reply.hash,
        "mime_type": reply.mime_type,
        "byte_count": reply.byte_count,
        "offset": reply.offset,
        "data": base64::engine::general_purpose::STANDARD.encode(&reply.data),
        "eof": reply.eof,
    }))
}

/// A link's offered file name: the upload rules for a name. Any extension
/// (the download goes with an attachment disposition, `nosniff`, and a
/// listed type or `application/octet-stream`, so nothing renders or runs).
pub(super) fn checked_name(name: Option<String>) -> anyhow::Result<Option<String>> {
    match name {
        None => Ok(None),
        Some(name) if cmux_conversation::valid_attachment_name(&name) => Ok(Some(name)),
        Some(_) => {
            Err(crate::conversation_store::attachments::AttachmentRejected("validation_invalid")
                .into())
        }
    }
}

/// The JSON a link answers with.
pub(super) fn link_reply(token: &str) -> Value {
    let ttl = crate::conversation_store::attachments::links::LINK_TTL;
    json!({
        "path": format!("/attachments/{token}"),
        "expires_in_ms": u64::try_from(ttl.as_millis()).unwrap_or(u64::MAX),
    })
}

/// `conversation-attachment-link`: `{path, expires_in_ms}`. `path` is
/// `/attachments/<token>` on this daemon's WebSocket listener (HTTP `GET` or
/// `HEAD`, byte ranges); the token ends after `expires_in_ms` or a restart.
pub(super) fn link(mux: &Mux, client: u64, params: LinkParams) -> anyhow::Result<Value> {
    require_owner_client(mux, client)?;
    let actor = mux.conversation_principal(client);
    let LinkParams { conversation, hash, variant, name } = params;
    let variant = piece(variant, "variant")?;
    let name = checked_name(name)?;
    let token = mux.with_conversations(|store| {
        store.attachment_link(&actor, &conversation, &hash, variant, name)
    })?;
    Ok(link_reply(&token))
}
