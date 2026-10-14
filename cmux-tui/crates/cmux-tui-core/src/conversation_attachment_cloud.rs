//! Uploads of cloud conversations' attachments through the daemon
//! (`cloud-attachments-v1`). The page sends the bytes in the same steps as a
//! local upload (`begin`, `chunk`, `commit`); the daemon keeps them in an
//! upload of its own (the same sinks, hashing and per-connection lifetime),
//! and at commit hands the verified bytes to the caller, which sends them to
//! the cloud owner. Nothing of a cloud upload becomes a local record, and
//! cloud downloads go through short-lived signed URLs kept here for reuse.

use std::fs;
use std::io::Read;
use std::time::{Duration, Instant};

use super::{
    Attachments, MAX_UPLOADS, Piece, Sink, StoredAttachment, UploadDeclaration, declared_record,
    hex_digest, refused,
};
use crate::conversation_store::ConversationStore;

/// A signed cloud download URL is reused this long (the owner signs for 10 minutes).
const URL_REUSE: Duration = Duration::from_secs(8 * 60);
/// Signed URLs kept at once.
const MAX_URLS: usize = 1_024;

/// A cloud upload whose bytes are complete and match their hashes.
pub(crate) struct CloudUpload {
    pub conversation: String,
    /// The owner's upload plan (its intent answer).
    pub plan: serde_json::Value,
    pub record: StoredAttachment,
    pub pieces: Vec<(Piece, Vec<u8>)>,
}

impl Attachments {
    fn read_piece(sink: Sink) -> anyhow::Result<Vec<u8>> {
        match sink {
            Sink::Memory(bytes) => Ok(bytes),
            Sink::File { path, file } => {
                file.sync_all()?;
                drop(file);
                let mut bytes = Vec::new();
                let read = fs::File::open(&path).and_then(|mut file| file.read_to_end(&mut bytes));
                let _ = fs::remove_file(&path);
                read?;
                Ok(bytes)
            }
        }
    }
}

impl ConversationStore {
    /// `begin` of a cloud upload, after the owner answered its intent with a
    /// slot (`plan`). Returns the upload id and the pieces it needs.
    pub(crate) fn cloud_upload_begin(
        &mut self,
        client: u64,
        actor: &str,
        conversation: &str,
        declaration: &UploadDeclaration,
        plan: serde_json::Value,
    ) -> anyhow::Result<(String, Vec<Piece>)> {
        let (record, pieces) = declared_record(declaration)?;
        self.attachments.expire_uploads(Instant::now());
        if self.attachments.uploads.len() >= MAX_UPLOADS {
            return Err(refused("too_many_uploads"));
        }
        let needs = pieces.iter().map(|(piece, _, _)| *piece).collect();
        let id = self.open_upload(client, actor, conversation, record, pieces, Some(plan))?;
        Ok((id, needs))
    }

    /// `commit` of a cloud upload: removes it and returns its verified bytes
    /// (refused like a local commit when incomplete or not matching).
    pub(crate) fn cloud_upload_take(
        &mut self,
        client: u64,
        upload: &str,
    ) -> anyhow::Result<CloudUpload> {
        let found = match self.attachments.uploads.remove(upload) {
            Some(found) if found.client == client && found.cloud.is_some() => found,
            Some(other) => {
                self.attachments.uploads.insert(upload.to_string(), other);
                return Err(refused("unknown_upload"));
            }
            None => return Err(refused("unknown_upload")),
        };
        let complete = found.pieces.iter().all(|piece| piece.received == piece.byte_count);
        let matches =
            found.pieces.iter().all(|piece| hex_digest(piece.hasher.clone()) == piece.hash);
        if !complete || !matches {
            let reason = if complete { "hash_mismatch" } else { "incomplete" };
            Attachments::drop_upload(found);
            return Err(refused(reason));
        }
        let mut pieces = Vec::with_capacity(found.pieces.len());
        for piece in found.pieces {
            let kind = piece.piece;
            pieces.push((kind, Attachments::read_piece(piece.sink)?));
        }
        Ok(CloudUpload {
            conversation: found.conversation,
            plan: found.cloud.unwrap_or_default(),
            record: found.record,
            pieces,
        })
    }

    /// A signed cloud download URL still worth reusing for this key.
    pub(crate) fn cloud_url(&mut self, key: &str) -> Option<String> {
        let now = Instant::now();
        match self.attachments.cloud_urls.get(key) {
            Some((url, until)) if *until > now => Some(url.clone()),
            Some(_) => {
                self.attachments.cloud_urls.remove(key);
                None
            }
            None => None,
        }
    }

    pub(crate) fn remember_cloud_url(&mut self, key: &str, url: &str) {
        let urls = &mut self.attachments.cloud_urls;
        if urls.len() >= MAX_URLS {
            let now = Instant::now();
            urls.retain(|_, (_, until)| *until > now);
            if urls.len() >= MAX_URLS {
                urls.clear();
            }
        }
        urls.insert(key.to_string(), (url.to_string(), Instant::now() + URL_REUSE));
    }

    pub(crate) fn forget_cloud_url(&mut self, key: &str) {
        self.attachments.cloud_urls.remove(key);
    }
}
