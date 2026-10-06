//! Attachments of the local conversation owner (`local-attachments-v1`,
//! plans/cmux-next/home-messaging.md section 10.1, the local counterpart of
//! the cloud owner's `attachments.ts`).
//!
//! Bytes are stored once by SHA-256 in `attachments/` next to
//! `conversations.sqlite3` (in memory for an in-memory session). What a
//! conversation may use is its own record of a hash (`attachment_record`):
//! written only after the uploaded bytes matched their declared hash and size,
//! with the uploaders who may send it before any message references it. A
//! message part naming a hash commits only when the record exists for its
//! author with the same type, size and derived image; the commit writes the
//! reference rows (`attachment_ref`) in the same transaction. Records nothing
//! references are swept after a grace period, and bytes no record names
//! are deleted with them. Uploads in flight are per connection and never
//! stored until their commit.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::Context;
use cmux_conversation::{
    AttachmentReject, DerivedImage, DerivedVariant, Part, Reject, validate_attachment_meta,
    validate_derived,
};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{ConversationStore, load_head, rejected};

/// The capability of the `conversation-attachment-*` commands.
pub(crate) const LOCAL_ATTACHMENTS_CAPABILITY: &str = "local-attachments-v1";
/// The bytes directory inside the session state directory.
pub(crate) const ATTACHMENTS_DIRECTORY: &str = "attachments";
/// Largest decoded chunk of an upload, and largest read: 4 MiB is about
/// 5.6 MiB of base64, well inside a 16 MiB request line.
pub(crate) const MAX_CHUNK_BYTES: usize = 4 * 1024 * 1024;
/// Uploads open at once across every connection.
const MAX_UPLOADS: usize = 32;
/// An upload not committed within this time is dropped.
const UPLOAD_TTL: Duration = Duration::from_secs(15 * 60);
/// A record no message references is collectable after this long.
const UNREFERENCED_GRACE_MS: u64 = 24 * 3_600_000;
/// Records swept per upload begin (bounded work on the request path).
const SWEEP_BATCH: i64 = 64;
/// Most bytes the store keeps across every conversation, uploads in flight
/// included (decimal, like the cloud owner's per-user stored-bytes quota).
/// When a new upload does not fit, the oldest records no message references
/// go first; when only referenced bytes are left the upload is refused with
/// `storage_full`.
pub(crate) const DEFAULT_STORAGE_CAP: u64 = 10_000_000_000;

/// An attachment command the owner refused. The control socket reports it
/// with `error_code` [`AttachmentRejected::CODE`] and the reason as the text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AttachmentRejected(pub &'static str);

impl AttachmentRejected {
    pub const CODE: &'static str = "attachment_rejected";
}

impl std::fmt::Display for AttachmentRejected {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0)
    }
}

impl std::error::Error for AttachmentRejected {}

fn refused(reason: &'static str) -> anyhow::Error {
    AttachmentRejected(reason).into()
}

fn refused_meta(reject: AttachmentReject) -> anyhow::Error {
    refused(reject.code())
}

/// Which bytes of an attachment: the file, or its derived image.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Piece {
    Original,
    Poster,
    Preview,
}

impl Piece {
    fn variant(self) -> Option<DerivedVariant> {
        match self {
            Self::Original => None,
            Self::Poster => Some(DerivedVariant::Poster),
            Self::Preview => Some(DerivedVariant::Preview),
        }
    }
}

/// A declared derived image of an upload (`{sha256, byte_count, mime_type}`).
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct DerivedDeclaration {
    pub sha256: String,
    pub byte_count: u64,
    pub mime_type: String,
}

impl DerivedDeclaration {
    fn image(&self) -> DerivedImage {
        DerivedImage {
            hash: self.sha256.clone(),
            mime_type: self.mime_type.clone(),
            byte_count: self.byte_count,
        }
    }
}

/// `conversation-attachment-upload` `begin`: the file the caller will send.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct UploadDeclaration {
    pub sha256: String,
    pub byte_count: u64,
    pub mime_type: String,
    pub name: String,
    #[serde(default)]
    pub width: Option<u32>,
    #[serde(default)]
    pub height: Option<u32>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub poster: Option<DerivedDeclaration>,
    #[serde(default)]
    pub preview: Option<DerivedDeclaration>,
}

/// A conversation's record of one hash: what a part must match.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct StoredAttachment {
    pub hash: String,
    pub mime_type: String,
    pub byte_count: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poster: Option<DerivedImage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<DerivedImage>,
}

/// The reply to `begin`: no upload when the conversation already holds the
/// hash for this caller (`stored`), else the upload id and the pieces whose
/// bytes it needs, in order.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct BeginReply {
    pub upload: Option<String>,
    pub needs: Vec<Piece>,
    pub stored: Option<StoredAttachment>,
}

/// One read of stored bytes.
#[derive(Debug, Clone)]
pub(crate) struct ReadReply {
    /// The hash of the bytes read (the derived image's for a poster or preview).
    pub hash: String,
    pub mime_type: String,
    pub byte_count: u64,
    pub offset: u64,
    pub data: Vec<u8>,
    pub eof: bool,
}

/// Where stored bytes live.
#[derive(Debug)]
enum Blobs {
    Directory(PathBuf),
    Memory(HashMap<String, Vec<u8>>),
}

/// Bytes of one piece while they arrive.
#[derive(Debug)]
enum Sink {
    File { path: PathBuf, file: fs::File },
    Memory(Vec<u8>),
}

#[derive(Debug)]
struct PendingPiece {
    piece: Piece,
    hash: String,
    byte_count: u64,
    received: u64,
    hasher: Sha256,
    sink: Sink,
}

#[derive(Debug)]
struct Upload {
    client: u64,
    actor: String,
    conversation: String,
    record: StoredAttachment,
    pieces: Vec<PendingPiece>,
    deadline: Instant,
}

/// Bytes and uploads in flight, owned by the conversation store.
#[derive(Debug)]
pub(crate) struct Attachments {
    blobs: Blobs,
    uploads: HashMap<String, Upload>,
    /// Total bytes the store may hold (`DEFAULT_STORAGE_CAP`).
    storage_cap: u64,
}

impl Attachments {
    /// `attachments/` in `directory`, or memory without a directory.
    pub(crate) fn open(directory: Option<&Path>) -> anyhow::Result<Self> {
        let blobs = match directory {
            Some(directory) => {
                let root = directory.join(ATTACHMENTS_DIRECTORY);
                fs::create_dir_all(root.join(".partial"))
                    .with_context(|| format!("create {}", root.display()))?;
                crate::platform::restrict_directory(&root)?;
                // Partial files of an earlier run are never resumed.
                if let Ok(entries) = fs::read_dir(root.join(".partial")) {
                    for entry in entries.flatten() {
                        let _ = fs::remove_file(entry.path());
                    }
                }
                Blobs::Directory(root)
            }
            None => Blobs::Memory(HashMap::new()),
        };
        Ok(Self { blobs, uploads: HashMap::new(), storage_cap: DEFAULT_STORAGE_CAP })
    }

    fn has_blob(&self, hash: &str) -> bool {
        match &self.blobs {
            Blobs::Directory(root) => root.join(hash).is_file(),
            Blobs::Memory(map) => map.contains_key(hash),
        }
    }

    fn remove_blob(&mut self, hash: &str) {
        match &mut self.blobs {
            Blobs::Directory(root) => {
                let _ = fs::remove_file(root.join(hash));
            }
            Blobs::Memory(map) => {
                map.remove(hash);
            }
        }
    }

    fn read_blob(&self, hash: &str, offset: u64, length: usize) -> anyhow::Result<Vec<u8>> {
        match &self.blobs {
            Blobs::Directory(root) => {
                let mut file = fs::File::open(root.join(hash))
                    .map_err(|_| refused(Reject::UnknownAttachment.code()))?;
                file.seek(SeekFrom::Start(offset))?;
                let mut data = Vec::with_capacity(length);
                file.take(length as u64).read_to_end(&mut data)?;
                Ok(data)
            }
            Blobs::Memory(map) => {
                let bytes =
                    map.get(hash).ok_or_else(|| refused(Reject::UnknownAttachment.code()))?;
                let start = usize::try_from(offset).unwrap_or(usize::MAX).min(bytes.len());
                let end = start.saturating_add(length).min(bytes.len());
                Ok(bytes[start..end].to_vec())
            }
        }
    }

    fn new_sink(&self, upload: &str, piece: Piece) -> anyhow::Result<Sink> {
        Ok(match &self.blobs {
            Blobs::Directory(root) => {
                let path = root.join(".partial").join(format!("{upload}-{piece:?}"));
                let file = fs::OpenOptions::new().create_new(true).write(true).open(&path)?;
                crate::platform::restrict_file(&path)?;
                Sink::File { path, file }
            }
            Blobs::Memory(_) => Sink::Memory(Vec::new()),
        })
    }

    /// Moves a complete, verified piece into the blob store (a hash already
    /// stored keeps its bytes).
    fn store_piece(&mut self, piece: PendingPiece) -> anyhow::Result<()> {
        let exists = self.has_blob(&piece.hash);
        match (piece.sink, &mut self.blobs) {
            (Sink::File { path, file }, Blobs::Directory(root)) => {
                file.sync_all()?;
                drop(file);
                if exists {
                    let _ = fs::remove_file(&path);
                } else {
                    let target = root.join(&piece.hash);
                    fs::rename(&path, &target)?;
                    crate::platform::sync_directory(root)?;
                }
            }
            (Sink::Memory(bytes), Blobs::Memory(map)) => {
                map.entry(piece.hash).or_insert(bytes);
            }
            _ => anyhow::bail!("attachment sink does not match its store"),
        }
        Ok(())
    }

    fn drop_upload(upload: Upload) {
        for piece in upload.pieces {
            if let Sink::File { path, file } = piece.sink {
                drop(file);
                let _ = fs::remove_file(path);
            }
        }
    }

    fn expire_uploads(&mut self, now: Instant) {
        let expired: Vec<String> = self
            .uploads
            .iter()
            .filter(|(_, upload)| upload.deadline <= now)
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            if let Some(upload) = self.uploads.remove(&id) {
                Self::drop_upload(upload);
            }
        }
    }

    /// Ends the uploads of a closed connection.
    pub(crate) fn client_closed(&mut self, client: u64) {
        let ids: Vec<String> = self
            .uploads
            .iter()
            .filter(|(_, upload)| upload.client == client)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            if let Some(upload) = self.uploads.remove(&id) {
                Self::drop_upload(upload);
            }
        }
    }
}

/// The record and reference tables (additive: older binaries ignore them).
pub(crate) const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS attachment_record (
       conversation TEXT NOT NULL,
       hash TEXT NOT NULL,
       mime_type TEXT NOT NULL,
       byte_count INTEGER NOT NULL CHECK(byte_count > 0),
       derived_variant TEXT,
       derived_hash TEXT,
       derived_mime_type TEXT,
       derived_byte_count INTEGER,
       uploaders_json TEXT NOT NULL,
       created_at_ms INTEGER NOT NULL,
       PRIMARY KEY(conversation, hash)
     ) WITHOUT ROWID;
     CREATE INDEX IF NOT EXISTS attachment_record_by_hash ON attachment_record(hash);
     CREATE INDEX IF NOT EXISTS attachment_record_by_derived ON attachment_record(derived_hash);
     CREATE TABLE IF NOT EXISTS attachment_ref (
       conversation TEXT NOT NULL,
       hash TEXT NOT NULL,
       message_id TEXT NOT NULL,
       PRIMARY KEY(conversation, hash, message_id)
     ) WITHOUT ROWID;";

struct RecordRow {
    stored: StoredAttachment,
    uploaders: Vec<String>,
}

fn load_record(
    connection: &Connection,
    conversation: &str,
    hash: &str,
) -> anyhow::Result<Option<RecordRow>> {
    type Row = (String, i64, Option<String>, Option<String>, Option<String>, Option<i64>, String);
    let row: Option<Row> = connection
        .query_row(
            "SELECT mime_type, byte_count, derived_variant, derived_hash, derived_mime_type,
                    derived_byte_count, uploaders_json
             FROM attachment_record WHERE conversation = ?1 AND hash = ?2",
            params![conversation, hash],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .optional()?;
    let Some((
        mime_type,
        byte_count,
        variant,
        derived_hash,
        derived_mime,
        derived_bytes,
        uploaders,
    )) = row
    else {
        return Ok(None);
    };
    let derived = match (derived_hash, derived_mime, derived_bytes) {
        (Some(hash), Some(mime_type), Some(byte_count)) => Some(DerivedImage {
            hash,
            mime_type,
            byte_count: u64::try_from(byte_count).context("attachment record is corrupt")?,
        }),
        _ => None,
    };
    let (poster, preview) = match variant.as_deref() {
        Some("poster") => (derived, None),
        Some("preview") => (None, derived),
        _ => (None, None),
    };
    Ok(Some(RecordRow {
        stored: StoredAttachment {
            hash: hash.to_string(),
            mime_type,
            byte_count: u64::try_from(byte_count).context("attachment record is corrupt")?,
            poster,
            preview,
        },
        uploaders: serde_json::from_str(&uploaders).context("attachment uploaders are corrupt")?,
    }))
}

fn referenced(connection: &Connection, conversation: &str, hash: &str) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM attachment_ref WHERE conversation = ?1 AND hash = ?2 LIMIT 1",
            params![conversation, hash],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// The record of `hash` only when `actor` may use it: an uploader of it in
/// this conversation, or a message here references it. Anything else is
/// `None`, so callers cannot tell an unsent upload of someone else from no
/// upload at all.
fn usable_record(
    connection: &Connection,
    conversation: &str,
    hash: &str,
    actor: &str,
) -> anyhow::Result<Option<StoredAttachment>> {
    let Some(row) = load_record(connection, conversation, hash)? else {
        return Ok(None);
    };
    if row.uploaders.iter().any(|uploader| uploader == actor)
        || referenced(connection, conversation, hash)?
    {
        Ok(Some(row.stored))
    } else {
        Ok(None)
    }
}

/// The owner's check of a part list for `actor` (the cloud `checkAttachments`):
/// each attachment's hash is usable by the author, and its type, size and
/// claimed poster or preview equal the record's.
pub(crate) fn check_parts(
    transaction: &Transaction<'_>,
    conversation: &str,
    actor: &str,
    parts: &[Part],
) -> anyhow::Result<()> {
    for part in parts {
        let Part::Attachment { hash, mime_type, byte_count, poster, preview, .. } = part else {
            continue;
        };
        let record = usable_record(transaction, conversation, hash, actor)?
            .ok_or_else(|| rejected(Reject::UnknownAttachment))?;
        let derived_matches = |claimed: &Option<DerivedImage>, kept: &Option<DerivedImage>| {
            claimed.as_ref().is_none_or(|claimed| kept.as_ref() == Some(claimed))
        };
        if &record.mime_type != mime_type
            || record.byte_count != *byte_count
            || !derived_matches(poster, &record.poster)
            || !derived_matches(preview, &record.preview)
        {
            return Err(rejected(Reject::AttachmentMismatch));
        }
    }
    Ok(())
}

/// Reference rows for a committed message (send, edit) of `parts`, in the
/// message's own transaction. A retract (no parts) removes them.
pub(crate) fn write_refs(
    transaction: &Transaction<'_>,
    conversation: &str,
    message_id: &str,
    parts: &[Part],
) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM attachment_ref WHERE conversation = ?1 AND message_id = ?2",
        params![conversation, message_id],
    )?;
    for part in parts {
        if let Part::Attachment { hash, .. } = part {
            transaction.execute(
                "INSERT OR IGNORE INTO attachment_ref(conversation, hash, message_id)
                 VALUES(?1, ?2, ?3)",
                params![conversation, hash, message_id],
            )?;
        }
    }
    Ok(())
}

fn require_participant(
    connection: &Connection,
    conversation: &str,
    actor: &str,
) -> anyhow::Result<()> {
    let head = load_head(connection, conversation)?
        .ok_or_else(|| rejected(Reject::UnknownConversation))?;
    if head.participant(actor).is_none() {
        return Err(rejected(Reject::NotParticipant));
    }
    Ok(())
}

fn new_upload_id() -> anyhow::Result<String> {
    let mut random = [0_u8; 16];
    getrandom::fill(&mut random).map_err(|_| anyhow::anyhow!("upload id randomness"))?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn hex_digest(hasher: Sha256) -> String {
    hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
}

impl ConversationStore {
    /// `begin`: validates the declared file for `actor`, a participant of
    /// `conversation`. A hash the conversation already holds adds the
    /// caller as an uploader and needs no bytes.
    pub(crate) fn attachment_begin(
        &mut self,
        client: u64,
        actor: &str,
        conversation: &str,
        declaration: &UploadDeclaration,
    ) -> anyhow::Result<BeginReply> {
        require_participant(&self.connection, conversation, actor)?;
        let mime_type = declaration.mime_type.to_lowercase();
        let class = validate_attachment_meta(
            &declaration.sha256,
            &mime_type,
            declaration.byte_count,
            &declaration.name,
            declaration.width,
            declaration.height,
            declaration.duration_ms,
        )
        .map_err(refused_meta)?;
        let mut derived = None;
        for (declared, variant) in [
            (&declaration.poster, DerivedVariant::Poster),
            (&declaration.preview, DerivedVariant::Preview),
        ] {
            if let Some(declared) = declared {
                let mut image = declared.image();
                image.mime_type = image.mime_type.to_lowercase();
                validate_derived(&image, class, variant).map_err(refused_meta)?;
                derived = Some((variant, image));
            }
        }
        let now = Instant::now();
        self.attachments.expire_uploads(now);
        self.sweep_unreferenced()?;
        if let Some(row) = load_record(&self.connection, conversation, &declaration.sha256)? {
            self.add_uploader(conversation, &declaration.sha256, row.uploaders, actor)?;
            return Ok(BeginReply { upload: None, needs: Vec::new(), stored: Some(row.stored) });
        }
        if self.attachments.uploads.len() >= MAX_UPLOADS {
            return Err(refused("too_many_uploads"));
        }
        let needed = declaration.byte_count
            + derived
                .as_ref()
                .map_or(0, |(_, image): &(DerivedVariant, DerivedImage)| image.byte_count);
        self.make_room(needed)?;
        let id = new_upload_id()?;
        let mut record = StoredAttachment {
            hash: declaration.sha256.clone(),
            mime_type,
            byte_count: declaration.byte_count,
            poster: None,
            preview: None,
        };
        let mut pieces =
            vec![(Piece::Original, declaration.sha256.clone(), declaration.byte_count)];
        if let Some((variant, image)) = derived {
            let piece = match variant {
                DerivedVariant::Poster => Piece::Poster,
                DerivedVariant::Preview => Piece::Preview,
            };
            pieces.push((piece, image.hash.clone(), image.byte_count));
            match variant {
                DerivedVariant::Poster => record.poster = Some(image),
                DerivedVariant::Preview => record.preview = Some(image),
            }
        }
        let mut pending = Vec::with_capacity(pieces.len());
        for (piece, hash, byte_count) in pieces {
            let sink = self.attachments.new_sink(&id, piece)?;
            pending.push(PendingPiece {
                piece,
                hash,
                byte_count,
                received: 0,
                hasher: Sha256::new(),
                sink,
            });
        }
        let needs = pending.iter().map(|piece| piece.piece).collect();
        self.attachments.uploads.insert(
            id.clone(),
            Upload {
                client,
                actor: actor.to_string(),
                conversation: conversation.to_string(),
                record,
                pieces: pending,
                deadline: now + UPLOAD_TTL,
            },
        );
        Ok(BeginReply { upload: Some(id), needs, stored: None })
    }

    /// `chunk`: the next bytes of one piece, at exactly the received offset.
    pub(crate) fn attachment_chunk(
        &mut self,
        client: u64,
        upload: &str,
        piece: Piece,
        offset: u64,
        data: &[u8],
    ) -> anyhow::Result<u64> {
        if data.len() > MAX_CHUNK_BYTES {
            return Err(refused("chunk_too_large"));
        }
        let upload = self
            .attachments
            .uploads
            .get_mut(upload)
            .filter(|upload| upload.client == client)
            .ok_or_else(|| refused("unknown_upload"))?;
        let pending = upload
            .pieces
            .iter_mut()
            .find(|pending| pending.piece == piece)
            .ok_or_else(|| refused("unknown_piece"))?;
        if offset != pending.received {
            return Err(refused("bad_offset"));
        }
        let received = pending.received + data.len() as u64;
        if received > pending.byte_count {
            return Err(refused("too_large"));
        }
        match &mut pending.sink {
            Sink::File { file, .. } => file.write_all(data)?,
            Sink::Memory(bytes) => bytes.extend_from_slice(data),
        }
        pending.hasher.update(data);
        pending.received = received;
        Ok(received)
    }

    /// `commit`: every piece complete and matching its hash, then the
    /// record (the first record of a hash wins; a later one only adds the
    /// uploader and answers the kept record).
    pub(crate) fn attachment_commit(
        &mut self,
        client: u64,
        upload: &str,
    ) -> anyhow::Result<StoredAttachment> {
        let owned = self.attachments.uploads.get(upload).is_some_and(|u| u.client == client);
        if !owned {
            return Err(refused("unknown_upload"));
        }
        let upload = self.attachments.uploads.remove(upload).expect("checked above");
        let complete = upload.pieces.iter().all(|piece| piece.received == piece.byte_count);
        let matches =
            upload.pieces.iter().all(|piece| hex_digest(piece.hasher.clone()) == piece.hash);
        if !complete || !matches {
            let reason = if complete { "hash_mismatch" } else { "incomplete" };
            Attachments::drop_upload(upload);
            return Err(refused(reason));
        }
        let Upload { actor, conversation, record, pieces, .. } = upload;
        if let Some(row) = load_record(&self.connection, &conversation, &record.hash)? {
            for piece in pieces {
                Attachments::drop_upload_piece(piece);
            }
            self.add_uploader(&conversation, &record.hash, row.uploaders, &actor)?;
            return Ok(row.stored);
        }
        for piece in pieces {
            self.attachments.store_piece(piece)?;
        }
        let (variant, derived) = match (&record.poster, &record.preview) {
            (Some(poster), _) => (Some("poster"), Some(poster)),
            (None, Some(preview)) => (Some("preview"), Some(preview)),
            (None, None) => (None, None),
        };
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        self.connection.execute(
            "INSERT INTO attachment_record(conversation, hash, mime_type, byte_count,
                 derived_variant, derived_hash, derived_mime_type, derived_byte_count,
                 uploaders_json, created_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                conversation,
                record.hash,
                record.mime_type,
                i64::try_from(record.byte_count)?,
                variant,
                derived.map(|image| image.hash.clone()),
                derived.map(|image| image.mime_type.clone()),
                derived.map(|image| i64::try_from(image.byte_count)).transpose()?,
                serde_json::to_string(&[actor])?,
                i64::try_from(now_ms)?,
            ],
        )?;
        Ok(record)
    }

    /// `cancel`: drops the caller's upload and its partial bytes.
    pub(crate) fn attachment_cancel(&mut self, client: u64, upload: &str) -> anyhow::Result<()> {
        let owned = self.attachments.uploads.get(upload).is_some_and(|u| u.client == client);
        if owned && let Some(upload) = self.attachments.uploads.remove(upload) {
            Attachments::drop_upload(upload);
        }
        Ok(())
    }

    /// Up to `length` bytes of `variant` of `hash` from `offset`, for a
    /// participant that may use the record.
    pub(crate) fn attachment_read(
        &self,
        actor: &str,
        conversation: &str,
        hash: &str,
        piece: Piece,
        offset: u64,
        length: usize,
    ) -> anyhow::Result<ReadReply> {
        require_participant(&self.connection, conversation, actor)?;
        let record = usable_record(&self.connection, conversation, hash, actor)?
            .ok_or_else(|| refused(Reject::UnknownAttachment.code()))?;
        let (hash, mime_type, byte_count) = match piece.variant() {
            None => (record.hash, record.mime_type, record.byte_count),
            Some(variant) => {
                let image = match variant {
                    DerivedVariant::Poster => record.poster,
                    DerivedVariant::Preview => record.preview,
                };
                let image = image.ok_or_else(|| {
                    refused(match variant {
                        DerivedVariant::Poster => "no_poster",
                        DerivedVariant::Preview => "no_preview",
                    })
                })?;
                (image.hash, image.mime_type, image.byte_count)
            }
        };
        if offset > byte_count {
            return Err(refused("bad_offset"));
        }
        let length = length.min(MAX_CHUNK_BYTES);
        let data = self.attachments.read_blob(&hash, offset, length)?;
        let eof = offset + data.len() as u64 >= byte_count;
        Ok(ReadReply { hash, mime_type, byte_count, offset, data, eof })
    }

    /// Ends the uploads of a closed connection.
    pub(crate) fn attachments_client_closed(&mut self, client: u64) {
        self.attachments.client_closed(client);
    }

    fn add_uploader(
        &self,
        conversation: &str,
        hash: &str,
        mut uploaders: Vec<String>,
        actor: &str,
    ) -> anyhow::Result<()> {
        if uploaders.iter().any(|uploader| uploader == actor) {
            return Ok(());
        }
        uploaders.push(actor.to_string());
        self.connection.execute(
            "UPDATE attachment_record SET uploaders_json = ?3 WHERE conversation = ?1 AND hash = ?2",
            params![conversation, hash, serde_json::to_string(&uploaders)?],
        )?;
        Ok(())
    }

    /// Drops records nothing references after the grace period, then the
    /// bytes no record names any more. Bounded per call.
    fn sweep_unreferenced(&mut self) -> anyhow::Result<()> {
        let cutoff =
            crate::workspace_registry::unix_epoch_ms()?.saturating_sub(UNREFERENCED_GRACE_MS);
        let mut statement = self.connection.prepare(
            "SELECT conversation, hash, derived_hash FROM attachment_record AS record
             WHERE created_at_ms < ?1 AND NOT EXISTS (
               SELECT 1 FROM attachment_ref AS ref
               WHERE ref.conversation = record.conversation AND ref.hash = record.hash)
             LIMIT ?2",
        )?;
        let stale = statement
            .query_map(params![i64::try_from(cutoff)?, SWEEP_BATCH], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        for (conversation, hash, derived) in stale {
            self.drop_record(&conversation, &hash, derived)?;
        }
        Ok(())
    }

    /// Deletes one record, then the bytes no record names any more.
    fn drop_record(
        &mut self,
        conversation: &str,
        hash: &str,
        derived: Option<String>,
    ) -> anyhow::Result<()> {
        self.connection.execute(
            "DELETE FROM attachment_record WHERE conversation = ?1 AND hash = ?2",
            params![conversation, hash],
        )?;
        for blob in std::iter::once(hash.to_string()).chain(derived) {
            let named: bool = self.connection.query_row(
                "SELECT EXISTS(SELECT 1 FROM attachment_record WHERE hash = ?1)
                     OR EXISTS(SELECT 1 FROM attachment_record WHERE derived_hash = ?1)",
                params![blob],
                |row| row.get(0),
            )?;
            if !named {
                self.attachments.remove_blob(&blob);
            }
        }
        Ok(())
    }

    /// Bytes the records name (each hash once) plus the uploads in flight.
    fn used_bytes(&self) -> anyhow::Result<u64> {
        let stored: i64 = self.connection.query_row(
            "SELECT COALESCE(SUM(n), 0) FROM (
               SELECT hash AS h, MAX(byte_count) AS n FROM attachment_record GROUP BY hash
               UNION
               SELECT derived_hash, MAX(derived_byte_count) FROM attachment_record
               WHERE derived_hash IS NOT NULL GROUP BY derived_hash)",
            [],
            |row| row.get(0),
        )?;
        let in_flight: u64 = self
            .attachments
            .uploads
            .values()
            .flat_map(|upload| upload.pieces.iter().map(|piece| piece.byte_count))
            .sum();
        Ok(u64::try_from(stored).unwrap_or(0) + in_flight)
    }

    /// Room for `needed` more bytes under the cap: evicts the oldest records
    /// no message references (an upload never sent), one at a time, and
    /// refuses with `storage_full` when only referenced bytes are left.
    fn make_room(&mut self, needed: u64) -> anyhow::Result<()> {
        while self.used_bytes()?.saturating_add(needed) > self.attachments.storage_cap {
            let oldest: Option<(String, String, Option<String>)> = self
                .connection
                .query_row(
                    "SELECT conversation, hash, derived_hash FROM attachment_record AS record
                     WHERE NOT EXISTS (
                       SELECT 1 FROM attachment_ref AS ref
                       WHERE ref.conversation = record.conversation AND ref.hash = record.hash)
                     ORDER BY created_at_ms, conversation, hash LIMIT 1",
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;
            let Some((conversation, hash, derived)) = oldest else {
                return Err(refused("storage_full"));
            };
            self.drop_record(&conversation, &hash, derived)?;
        }
        Ok(())
    }

    /// Sets the store's total byte cap (tests).
    #[cfg(test)]
    pub(crate) fn set_attachment_storage_cap(&mut self, cap: u64) {
        self.attachments.storage_cap = cap;
    }
}

impl Attachments {
    fn drop_upload_piece(piece: PendingPiece) {
        if let Sink::File { path, file } = piece.sink {
            drop(file);
            let _ = fs::remove_file(path);
        }
    }
}

#[cfg(test)]
#[path = "conversation_attachments_tests.rs"]
mod tests;
