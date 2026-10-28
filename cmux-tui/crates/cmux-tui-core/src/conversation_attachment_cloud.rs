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
    Attachments, MAX_UPLOADS, PendingPiece, Piece, Sink, StoredAttachment, UploadDeclaration,
    declared_record, hex_digest, refused,
};
use crate::conversation_store::ConversationStore;

/// A signed cloud download URL is reused this long (the owner signs for 10 minutes).
const URL_REUSE: Duration = Duration::from_secs(8 * 60);
/// Signed URLs kept at once.
const MAX_URLS: usize = 1_024;

/// A cloud upload whose bytes are complete and match their hashes, taken
/// out of the store (its partial files are read with [`CloudUpload::bytes`]
/// after the store lock is released).
pub(crate) struct CloudUpload {
    pub conversation: String,
    /// The owner's upload plan (its intent answer).
    pub plan: serde_json::Value,
    pub record: StoredAttachment,
    pieces: Vec<PendingPiece>,
}

impl CloudUpload {
    /// The verified bytes of each piece. Every partial file is removed, also
    /// when a read fails.
    pub(crate) fn bytes(self) -> anyhow::Result<Vec<(Piece, Vec<u8>)>> {
        let mut out = Vec::with_capacity(self.pieces.len());
        let mut failure = None;
        for piece in self.pieces {
            let kind = piece.piece;
            match piece.sink {
                Sink::Memory(bytes) => out.push((kind, bytes)),
                Sink::File { path, file } => {
                    drop(file);
                    let mut bytes = Vec::new();
                    let read =
                        fs::File::open(&path).and_then(|mut file| file.read_to_end(&mut bytes));
                    let _ = fs::remove_file(&path);
                    match read {
                        Ok(_) if failure.is_none() => out.push((kind, bytes)),
                        Ok(_) => {}
                        Err(error) => failure = failure.or(Some(error)),
                    }
                }
            }
        }
        match failure {
            Some(error) => Err(error.into()),
            None => Ok(out),
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

#[cfg(all(test, target_os = "linux"))]
mod memory_tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[test]
    fn attachment_cloud_handoff_memory_is_independent_of_file_size() {
        const CHILD: &str = "CMUX_TEST_ATTACHMENT_MEMORY_CHILD";
        if let Ok(size) = std::env::var(CHILD) {
            let size: u64 = size.parse().unwrap();
            let path = std::env::temp_dir()
                .join(format!("cmux-attachment-memory-{}", super::super::new_upload_id().unwrap()));
            let file = fs::File::create(&path).unwrap();
            file.set_len(size).unwrap();
            let declaration = UploadDeclaration {
                sha256: "a".repeat(64),
                byte_count: size,
                mime_type: "application/octet-stream".into(),
                name: "sparse.bin".into(),
                width: None,
                height: None,
                duration_ms: None,
                poster: None,
                preview: None,
            };
            let (record, _) = declared_record(&declaration).unwrap();
            let upload = CloudUpload {
                conversation: "conv_memory".into(),
                plan: serde_json::Value::Null,
                record,
                pieces: vec![PendingPiece {
                    piece: Piece::Original,
                    hash: "a".repeat(64),
                    byte_count: size,
                    received: size,
                    hasher: Sha256::new(),
                    sink: Sink::File { path: path.clone(), file },
                }],
            };
            let high_water_kib = || -> u64 {
                fs::read_to_string("/proc/self/status")
                    .unwrap()
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("VmHWM:")
                            .and_then(|value| value.split_whitespace().next())
                            .map(|value| value.parse().unwrap())
                    })
                    .unwrap()
            };
            let before = high_water_kib();
            let pieces = upload.bytes().unwrap();
            std::hint::black_box(&pieces);
            let increase = high_water_kib().saturating_sub(before);
            drop(pieces);
            assert!(!path.exists(), "staged file must be removed after the request ends");
            assert!(
                increase < 16 * 1024,
                "{size}-byte attachment handoff allocated {increase} KiB; expected under 16 MiB"
            );
            return;
        }
        // Isolate VmHWM from other parallel tests. Sparse files make the fixture cheap;
        // the old read_to_end path still has to allocate and touch their entire contents.
        for size in [64_u64 << 20, 256_u64 << 20] {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "attachment_cloud_handoff_memory_is_independent_of_file_size",
                    "--nocapture",
                    "--test-threads=1",
                ])
                .env(CHILD, size.to_string())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
}
