//! Attachments of cloud conversations through the daemon
//! (`cloud-attachments-v1`): the same three commands and steps as the local
//! owner's, so a page shows and sends files the same way for both owners.
//!
//! - `cloud-attachment-upload`: `begin` asks the cloud owner for an upload
//!   slot with the lease (the same declaration and rules); a hash the
//!   conversation already holds answers `stored` at once. `chunk` collects
//!   the bytes here; `commit` checks them, sends the poster or preview first,
//!   then the file (through the Worker, or a presigned PUT and the commit),
//!   and answers the owner's record.
//! - `cloud-attachment-read`: bytes of a variant through a signed URL the
//!   owner mints (kept for reuse, minted again when it stops answering).
//! - `cloud-attachment-link`: a local download link (`GET /attachments/<token>`,
//!   byte ranges) that reads the signed URL with the lease.
//!
//! The person's own clients only (the app, an authenticated page), like every
//! command that uses the lease.

use crate::panic_free::JsonFields;
use base64::Engine;
use serde_json::{Value, json};

use super::Mux;
use super::cloud_conversations::lease_user;
use super::conversation_attachments::{
    LinkParams, ReadParams, UploadParams, checked_name, derived, link_reply, piece, required,
};
use crate::cloud_conversations::{CloudConversations, CloudError};
use crate::conversation_store::attachments::{
    MAX_CHUNK_BYTES, Piece, UploadDeclaration, cloud::CloudUpload,
};

pub(super) use crate::cloud_conversations::CLOUD_ATTACHMENTS_CAPABILITY as CAPABILITY;

fn variant_name(piece: Piece) -> Option<&'static str> {
    match piece {
        Piece::Original => None,
        Piece::Poster => Some("poster"),
        Piece::Preview => Some("preview"),
    }
}

/// The lease person (`<audience>:<account>`) cloud reads act for: signed URLs
/// and links of one person never serve another (a sign-out and sign-in on the
/// same daemon).
pub(super) fn lease_identity(service: &CloudConversations) -> anyhow::Result<String> {
    // A self-hosted server's person, once `cloud-selfhost-info` named them.
    if let Some((origin, user)) = service.lease_selfhost() {
        return user
            .map(|user| format!("selfhost:{origin}:{user}"))
            .ok_or_else(|| CloudError::SignedOut.into());
    }
    service
        .lease_person()
        .map(|(account, audience)| format!("{audience}:{account}"))
        .ok_or_else(|| CloudError::SignedOut.into())
}

fn url_key(lease: &str, conversation: &str, hash: &str, piece: Piece) -> String {
    format!("{lease}|{conversation}:{hash}:{}", variant_name(piece).unwrap_or("original"))
}

/// A signed download URL of `piece` of `hash`: the kept one, or a new one
/// (`fresh`: the kept one stopped answering).
pub(super) fn signed_url(
    mux: &Mux,
    service: &CloudConversations,
    conversation: &str,
    hash: &str,
    piece: Piece,
    fresh: bool,
) -> anyhow::Result<String> {
    let key = url_key(&lease_identity(service)?, conversation, hash, piece);
    if fresh {
        mux.with_conversations(|store| {
            store.forget_cloud_url(&key);
            Ok(())
        })?;
    } else if let Some(url) = mux.with_conversations(|store| Ok(store.cloud_url(&key)))? {
        return Ok(url);
    }
    let url = service.attachment_url(conversation, hash, variant_name(piece))?;
    mux.with_conversations(|store| {
        store.remember_cloud_url(&key, &url);
        Ok(())
    })?;
    Ok(url)
}

/// One ranged read of a cloud attachment, minting a new URL once when the
/// kept one has ended.
pub(super) fn cloud_range(
    mux: &Mux,
    service: &CloudConversations,
    conversation: &str,
    hash: &str,
    piece: Piece,
    offset: u64,
    length: u64,
) -> anyhow::Result<crate::cloud_conversations::RangeReply> {
    let url = signed_url(mux, service, conversation, hash, piece, false)?;
    match service.attachment_range(&url, offset, length) {
        // A signed URL that stopped answering (expired, re-keyed): one new one.
        Err(CloudError::Rejected { code, .. }) if code == "attachment.url_expired" => {
            let url = signed_url(mux, service, conversation, hash, piece, true)?;
            match service.attachment_range(&url, offset, length) {
                Err(CloudError::Rejected { code, message, .. })
                    if code == "attachment.url_expired" =>
                {
                    Err(CloudError::Rejected {
                        code: "attachment.forbidden".into(),
                        message,
                        retryable: false,
                    }
                    .into())
                }
                other => Ok(other?),
            }
        }
        other => Ok(other?),
    }
}

/// `cloud-attachment-upload`, one step per call.
pub(super) fn put(mux: &Mux, client: u64, params: UploadParams) -> anyhow::Result<Value> {
    let service = lease_user(mux, client)?;
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
            // The same rules as the local owner, and room for one more upload,
            // before the owner is asked for a slot (a slot takes its quota).
            crate::conversation_store::attachments::declared_record(&declaration)?;
            mux.with_conversations(|store| store.cloud_upload_room())?;
            let mut intent = json!({
                "sha256": declaration.sha256,
                "byte_count": declaration.byte_count,
                "mime_type": declaration.mime_type.to_lowercase(),
                "name": declaration.name,
            });
            for (field, value) in [
                ("width", declaration.width.map(u64::from)),
                ("height", declaration.height.map(u64::from)),
                ("duration_ms", declaration.duration_ms),
            ] {
                if let Some(value) = value {
                    intent.insert(field, json!(value));
                }
            }
            for (field, image) in
                [("poster", &declaration.poster), ("preview", &declaration.preview)]
            {
                if let Some(image) = image {
                    intent.insert(
                        field,
                        json!({"sha256": image.sha256, "byte_count": image.byte_count,
                                           "mime_type": image.mime_type.to_lowercase()}),
                    );
                }
            }
            let plan = service.attachment_intent(&conversation, &intent)?;
            if plan.get("state").and_then(Value::as_str) == Some("exists") {
                return Ok(
                    json!({"upload": null, "needs": [], "stored": plan.field("attachment")}),
                );
            }
            let actor = mux.conversation_principal(client);
            let (upload, needs) = mux.with_conversations(|store| {
                store.cloud_upload_begin(client, &actor, &conversation, &declaration, plan)
            })?;
            Ok(json!({"upload": upload, "needs": needs, "stored": null}))
        }
        "chunk" => {
            let upload = required(params.upload, "upload")?;
            let piece = piece(params.piece, "piece")?;
            let offset = required(params.offset, "offset")?;
            let data = required(params.data, "data")?;
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
            let taken = mux.with_conversations(|store| store.cloud_upload_take(client, &upload))?;
            // The files are opened after the store lock is released.
            Ok(json!({"stored": send_upload(service, taken)?}))
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

/// The plan's `headers` object as header pairs: only the ones an upload
/// slot or a presigned object PUT needs (strings only).
fn plan_headers(value: &Value) -> Vec<(String, String)> {
    let allowed = |name: &str| {
        let name = name.to_ascii_lowercase();
        matches!(name.as_str(), "content-type" | "content-length" | "if-none-match")
            || name.starts_with("x-amz-")
    };
    value
        .as_object()
        .map(|headers| {
            headers
                .iter()
                .filter(|(name, _)| allowed(name))
                .filter_map(|(name, value)| Some((name.clone(), value.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// Sends a verified upload to the cloud owner: the derived image first (the
/// owner refuses the file until it has it), then the file. Answers the
/// owner's record of the hash.
fn send_upload(service: &CloudConversations, upload: CloudUpload) -> anyhow::Result<Value> {
    let conversation = upload.conversation.clone();
    let plan = upload.plan.clone();
    let record = upload.record.clone();
    // The partial files stay until both PUTs are done.
    let (pieces, _partial) = upload.bodies()?;
    let mut original = None;
    for (piece, body) in pieces {
        match variant_name(piece) {
            None => original = Some(body),
            Some(variant) => {
                let slot = plan.field(&format!("{variant}_upload"));
                let url = slot
                    .field("upload_url")
                    .as_str()
                    .ok_or_else(|| CloudError::Unavailable(format!("no {variant} upload slot")))?;
                service.attachment_put(url, &plan_headers(slot.field("headers")), body, true)?;
            }
        }
    }
    let body = original.ok_or_else(|| anyhow::anyhow!("an upload without its file"))?;
    let url = plan
        .field("upload_url")
        .as_str()
        .ok_or_else(|| CloudError::Unavailable("no upload slot".into()))?;
    let presigned = plan.field("mode") == "presigned";
    // A Worker slot is on the lease's origin; only a presigned object URL may be elsewhere.
    let answer =
        service.attachment_put(url, &plan_headers(plan.field("headers")), body, !presigned)?;
    let committed = if presigned {
        let slot = plan
            .field("slot")
            .as_str()
            .ok_or_else(|| CloudError::Unavailable("a presigned slot without its id".into()))?;
        service.attachment_commit(&conversation, slot)?
    } else {
        answer
    };
    // The owner's record (the first upload of a hash wins its derived image).
    Ok(match committed.get("attachment") {
        Some(attachment) if attachment.is_object() => attachment.clone(),
        _ => serde_json::to_value(record)?,
    })
}

/// `cloud-attachment-read`: up to `length` (default and at most 4 MiB) bytes
/// of one variant from `offset`.
pub(super) fn read(mux: &Mux, client: u64, params: ReadParams) -> anyhow::Result<Value> {
    let service = lease_user(mux, client)?;
    let ReadParams { conversation, hash, variant, offset, length } = params;
    let piece = piece(variant, "variant")?;
    let offset = offset.unwrap_or(0);
    let length = length.unwrap_or(MAX_CHUNK_BYTES as u64).min(MAX_CHUNK_BYTES as u64);
    let reply = cloud_range(mux, service, &conversation, &hash, piece, offset, length)?;
    let total = reply.total.unwrap_or(offset + reply.body.len() as u64);
    Ok(json!({
        "hash": hash,
        "mime_type": reply.content_type.as_deref().map(|value| value.split(';').next().unwrap_or("").trim().to_string()).unwrap_or_default(),
        "byte_count": total,
        "offset": offset,
        "data": base64::engine::general_purpose::STANDARD.encode(&reply.body),
        "eof": offset + reply.body.len() as u64 >= total,
    }))
}

/// `cloud-attachment-link`: a local download link of a cloud attachment.
/// The owner signs a URL first (its access check); the link reads through it.
pub(super) fn link(mux: &Mux, client: u64, params: LinkParams) -> anyhow::Result<Value> {
    let service = lease_user(mux, client)?;
    let LinkParams { conversation, hash, variant, name } = params;
    let piece = piece(variant, "variant")?;
    let name = checked_name(name)?;
    signed_url(mux, service, &conversation, &hash, piece, false)?;
    let actor = mux.conversation_principal(client);
    let lease = lease_identity(service)?;
    let token = mux.with_conversations(|store| {
        store.attachment_cloud_link(&actor, &conversation, &hash, piece, name, lease)
    })?;
    Ok(link_reply(&token))
}
