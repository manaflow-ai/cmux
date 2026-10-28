//! Uploads of cloud conversations' attachments through the daemon
//! (`cloud-attachments-v1`). The page sends the bytes in the same steps as a
//! local upload (`begin`, `chunk`, `commit`); the daemon keeps them in an
//! upload of its own (the same sinks, hashing and per-connection lifetime),
//! and at commit hands the verified bytes to the caller, which sends them to
//! the cloud owner. Nothing of a cloud upload becomes a local record, and
//! cloud downloads go through short-lived signed URLs kept here for reuse.

use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::{
    Attachments, MAX_UPLOADS, PendingPiece, Piece, Sink, StoredAttachment, UploadDeclaration,
    declared_record, hex_digest, refused,
};
use crate::cloud_conversations::PutBody;
use crate::conversation_store::ConversationStore;

/// A signed cloud download URL is reused this long (the owner signs for 10 minutes).
const URL_REUSE: Duration = Duration::from_secs(8 * 60);
/// Signed URLs kept at once.
const MAX_URLS: usize = 1_024;

/// A cloud upload whose bytes are complete and match their hashes, taken
/// out of the store (its partial files are opened with
/// [`CloudUpload::bodies`] after the store lock is released).
pub(crate) struct CloudUpload {
    pub conversation: String,
    /// The owner's upload plan (its intent answer).
    pub plan: serde_json::Value,
    pub record: StoredAttachment,
    pieces: Vec<PendingPiece>,
}

/// The partial files of a taken cloud upload, removed when this drops (after
/// their bodies were sent, or when one could not be opened).
pub(crate) struct PartialFiles(Vec<PathBuf>);

impl Drop for PartialFiles {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = fs::remove_file(path);
        }
    }
}

impl CloudUpload {
    /// Each piece as an upload body. A partial file is opened for streaming,
    /// never read whole, so an original of any size stays on disk.
    pub(crate) fn bodies(self) -> anyhow::Result<(Vec<(Piece, PutBody)>, PartialFiles)> {
        let mut out = Vec::with_capacity(self.pieces.len());
        let mut partial = PartialFiles(Vec::new());
        let mut failure = None;
        for piece in self.pieces {
            let kind = piece.piece;
            match piece.sink {
                Sink::Memory(bytes) => out.push((kind, PutBody::Bytes(bytes))),
                Sink::File { path, file } => {
                    drop(file);
                    let opened = fs::File::open(&path);
                    partial.0.push(path);
                    match opened {
                        Ok(file) => out.push((kind, PutBody::File { file, len: piece.byte_count })),
                        Err(error) => failure = failure.or(Some(error)),
                    }
                }
            }
        }
        match failure {
            Some(error) => Err(error.into()),
            None => Ok((out, partial)),
        }
    }
}

impl ConversationStore {
    /// `begin` of a cloud upload, after the owner answered its intent with a
    /// slot (`plan`). Returns the upload id and the pieces it needs.
    /// Whether one more upload fits (asked before the owner is asked for a
    /// slot, so a refused begin never takes the owner's quota).
    pub(crate) fn cloud_upload_room(&mut self) -> anyhow::Result<()> {
        self.attachments.expire_uploads(Instant::now());
        if self.attachments.uploads.len() >= MAX_UPLOADS {
            return Err(refused("too_many_uploads"));
        }
        Ok(())
    }

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
        Ok(CloudUpload {
            conversation: found.conversation,
            plan: found.cloud.unwrap_or_default(),
            record: found.record,
            pieces: found.pieces,
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
