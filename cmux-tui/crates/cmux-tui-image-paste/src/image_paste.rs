//! Temporary image ownership for the authenticated terminal control channel.
//! Images of any size are accepted: bytes stream to a private file in bounded
//! chunks, and only the number of uploads is limited, never their size.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::image_paste_file::{ImagePasteFile, WallClock};
use crate::image_paste_storage::ImagePasteStorage;
use base64::Engine;

pub const CAPABILITY: &str = "terminal-image-paste-v1";
pub(crate) const MAX_CHUNK_BYTES: usize = 48 * 1024;
const MAX_ENTRIES: usize = 32;
pub(crate) const IMAGE_TTL: Duration = Duration::from_secs(600);
/// How long an upload may go without an accepted chunk before it expires.
/// Each chunk restarts it, so a large image on a slow link still finishes.
const UPLOAD_TTL: Duration = Duration::from_secs(120);
/// The most often a chunk rewrites the durable receipt's expiry. A refresh
/// writes `now + UPLOAD_TTL + IMAGE_TTL`, so the receipt outlasts the
/// in-memory upload deadline by IMAGE_TTL minus this (570 s): a sweep in any
/// daemon sharing the storage never finds a live upload expired.
const RECEIPT_REFRESH: Duration = Duration::from_secs(30);

#[derive(Clone, PartialEq, Eq)]
pub struct ImagePasteOwner {
    pub client: u64,
    pub surface: u64,
    pub terminal: String,
    pub workspace: String,
    pub lease: String,
}

struct Upload {
    owner: ImagePasteOwner,
    file: ImagePasteFile,
    mime: String,
    size: usize,
    received: usize,
    committed: bool,
    delivery_in_flight: bool,
    cleanup_pending: bool,
    deadline: Instant,
    /// When the durable receipt's expiry was last written, on `clock`.
    receipt_written: u64,
}

#[derive(Default)]
struct State {
    uploads: HashMap<(u64, String), Upload>,
    recovery: Option<crate::image_paste_recovery::ImagePasteRecovery>,
    next_recovery: Option<Instant>,
    worker_started: bool,
    stopped: bool,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

pub struct ImagePasteStore {
    shared: Arc<Shared>,
    /// The clock receipts are written in; recovery sweeps compare with it.
    clock: WallClock,
    /// The temporary directory holding the per-UID storage, when not the
    /// system one.
    temporary: Option<std::path::PathBuf>,
}

impl Default for ImagePasteStore {
    fn default() -> Self {
        Self::with_recovery(Some(crate::image_paste_recovery::ImagePasteRecovery::default()))
    }
}

impl ImagePasteStore {
    fn with_recovery(recovery: Option<crate::image_paste_recovery::ImagePasteRecovery>) -> Self {
        let store = Self {
            shared: Arc::new(Shared::default()),
            clock: WallClock::default(),
            temporary: None,
        };
        {
            let mut state = store.shared.state.lock().unwrap();
            state.recovery = recovery;
            if let Some(recovery) = &mut state.recovery {
                let delay = recovery.scan(&HashSet::new());
                state.next_recovery = Some(Instant::now() + delay);
                let _ = store.start_worker(&mut state);
            }
        }
        store
    }

    /// A daemon whose storage lives below `temporary`, read with `clock`, and
    /// which runs no recovery sweep of its own.
    #[cfg(test)]
    fn with_storage(temporary: &std::path::Path, clock: WallClock) -> Self {
        let mut store = Self::with_recovery(None);
        store.clock = clock;
        store.temporary = Some(temporary.to_owned());
        store
    }

    fn start_worker(&self, state: &mut State) -> anyhow::Result<()> {
        if !state.worker_started {
            let shared = self.shared.clone();
            std::thread::Builder::new()
                .name("image-paste-expiry".into())
                .spawn(move || {
                    let mut state = shared.state.lock().unwrap();
                    while !state.stopped {
                        Self::reap(&mut state, Instant::now());
                        if state.next_recovery.is_some_and(|deadline| deadline <= Instant::now()) {
                            let active: HashSet<_> = state
                                .uploads
                                .values()
                                .map(|upload| upload.file.directory().to_owned())
                                .collect();
                            if let Some(recovery) = &mut state.recovery {
                                let delay = recovery.scan(&active);
                                state.next_recovery = Some(Instant::now() + delay);
                            }
                        }
                        if let Some(deadline) = state
                            .uploads
                            .values()
                            .map(|upload| upload.deadline)
                            .chain(state.next_recovery)
                            .min()
                        {
                            let wait = deadline.saturating_duration_since(Instant::now());
                            state = shared.changed.wait_timeout(state, wait).unwrap().0;
                        } else {
                            state = shared.changed.wait(state).unwrap();
                        }
                    }
                })
                .map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
            state.worker_started = true;
        }
        Ok(())
    }

    pub fn begin(
        &self,
        owner: ImagePasteOwner,
        id: &str,
        mime: &str,
        size: usize,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(valid_id(id), "image-invalid-request");
        anyhow::ensure!(size > 0, "image-size-limit");
        let extension = extension(mime).ok_or_else(|| anyhow::anyhow!("image-type-rejected"))?;
        let mut state = self.shared.state.lock().unwrap();
        Self::reap(&mut state, Instant::now());
        anyhow::ensure!(
            !state.uploads.contains_key(&(owner.client, id.to_owned())),
            "image-duplicate-upload"
        );
        let recovered = state.recovery.as_ref();
        anyhow::ensure!(
            recovered.is_none_or(|recovery| recovery.ready),
            "image-storage-unavailable"
        );
        let client_count =
            state.uploads.values().filter(|upload| upload.owner.client == owner.client).count();
        anyhow::ensure!(
            state
                .uploads
                .len()
                .saturating_add(recovered.map_or(0, |recovery| recovery.retained_count))
                < MAX_ENTRIES
                && client_count < 8,
            "image-capacity-limit"
        );
        let storage = match &self.temporary {
            Some(temporary) => ImagePasteStorage::at(temporary),
            None => ImagePasteStorage::open(),
        };
        let now = self.clock.now();
        let expires = Self::upload_expiry(now);
        let file = storage
            .and_then(|storage| ImagePasteFile::create_in(&storage, extension, expires))
            .map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
        self.start_worker(&mut state)?;
        state.uploads.insert(
            (owner.client, id.to_owned()),
            Upload {
                owner,
                file,
                mime: mime.to_owned(),
                size,
                received: 0,
                committed: false,
                delivery_in_flight: false,
                cleanup_pending: false,
                deadline: Instant::now() + UPLOAD_TTL,
                receipt_written: now,
            },
        );
        self.shared.changed.notify_one();
        Ok(())
    }

    pub fn append(
        &self,
        owner: &ImagePasteOwner,
        id: &str,
        offset: usize,
        encoded: &str,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(encoded.len() <= MAX_CHUNK_BYTES.div_ceil(3) * 4, "image-size-limit");
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| anyhow::anyhow!("image-invalid-request"))?;
        anyhow::ensure!(!bytes.is_empty() && bytes.len() <= MAX_CHUNK_BYTES, "image-size-limit");
        let mut state = self.shared.state.lock().unwrap();
        Self::reap(&mut state, Instant::now());
        let upload = Self::upload(&mut state, owner, id)?;
        anyhow::ensure!(!upload.committed && offset == upload.received, "image-invalid-offset");
        anyhow::ensure!(bytes.len() <= upload.size - upload.received, "image-size-limit");
        // The in-memory deadline below only guards this daemon. Every daemon
        // of the user sweeps the shared storage by the durable receipt, so it
        // must cover this upload too. Refresh it before accepting the bytes,
        // so a failure leaves the offset unchanged, and at most once per
        // RECEIPT_REFRESH, so a fast upload is not one fsync per chunk.
        let now = self.clock.now();
        if now >= upload.receipt_written.saturating_add(RECEIPT_REFRESH.as_secs()) {
            upload
                .file
                .set_expiry(Self::upload_expiry(now))
                .map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
            upload.receipt_written = now;
        }
        upload.file.append(&bytes).map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
        upload.received += bytes.len();
        upload.deadline = Instant::now() + UPLOAD_TTL;
        Ok(())
    }

    /// Publishes once, directly through the terminal owner's paste primitive.
    /// No remote path is accepted from or returned to the client.
    pub fn commit(
        &self,
        owner: &ImagePasteOwner,
        id: &str,
        paste: impl FnOnce(&str) -> std::io::Result<()>,
    ) -> anyhow::Result<()> {
        let mut state = self.shared.state.lock().unwrap();
        Self::reap(&mut state, Instant::now());
        let upload = Self::upload(&mut state, owner, id)?;
        anyhow::ensure!(!upload.committed, "image-already-pasted");
        anyhow::ensure!(upload.received == upload.size, "image-incomplete");
        let header =
            upload.file.header().map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
        anyhow::ensure!(matches_mime(&upload.mime, &header), "image-type-rejected");
        let path = upload.file.path().map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
        let path = path.to_str().ok_or_else(|| anyhow::anyhow!("image-storage-unavailable"))?;
        let quoted = format!("'{}'", path.replace('\'', "'\\''"));
        // A crash after this point leaves recovery to remove the image: give
        // the agent its full reading time from now, not from upload creation.
        upload
            .file
            .set_expiry(self.clock.now().saturating_add(IMAGE_TTL.as_secs()))
            .map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
        // Input delivery can fail after a partial write. Retain the readable file
        // until TTL and never automatically retry an ambiguous paste.
        upload.committed = true;
        upload.delivery_in_flight = true;
        upload.deadline = Instant::now() + IMAGE_TTL;
        self.shared.changed.notify_one();
        let key = (owner.client, id.to_owned());
        drop(state);

        // The PTY or host attachment may block while accepting the bracketed
        // paste. Do not hold the store mutex across that I/O.
        let result = paste(&quoted).map_err(|_| anyhow::anyhow!("image-paste-uncertain"));

        let mut state = self.shared.state.lock().unwrap();
        if let Some(upload) = state.uploads.get_mut(&key) {
            upload.delivery_in_flight = false;
            if upload.cleanup_pending {
                upload.deadline = Instant::now();
            }
        }
        // A terminal close may have requested cleanup while delivery was in
        // flight. Reap now that it is safe to unlink the owned file.
        Self::reap(&mut state, Instant::now());
        self.shared.changed.notify_one();
        result
    }

    /// The durable expiry of an upload whose receipt is written at `now`:
    /// its whole transfer window, then the reading time after a commit there.
    /// The receipt is refreshed while chunks arrive, so it never falls behind
    /// the in-memory deadline by more than RECEIPT_REFRESH.
    fn upload_expiry(now: u64) -> u64 {
        now.saturating_add((UPLOAD_TTL + IMAGE_TTL).as_secs())
    }

    pub fn cancel(&self, owner: &ImagePasteOwner, id: &str) -> anyhow::Result<()> {
        let mut state = self.shared.state.lock().unwrap();
        if let Some(upload) = state.uploads.get_mut(&(owner.client, id.to_owned())) {
            anyhow::ensure!(&upload.owner == owner, "image-owner-mismatch");
            anyhow::ensure!(!upload.committed, "image-already-pasted");
            upload.cleanup_pending = true;
            upload.deadline = Instant::now();
        }
        Self::reap(&mut state, Instant::now());
        self.shared.changed.notify_one();
        Ok(())
    }

    pub fn disconnect(&self, client: u64) {
        let mut state = self.shared.state.lock().unwrap();
        for upload in state
            .uploads
            .values_mut()
            .filter(|upload| upload.owner.client == client && !upload.committed)
        {
            upload.cleanup_pending = true;
            upload.deadline = Instant::now();
        }
        Self::reap(&mut state, Instant::now());
        self.shared.changed.notify_one();
    }

    pub fn close_terminal(&self, terminal: &str) {
        let mut state = self.shared.state.lock().unwrap();
        for upload in state.uploads.values_mut().filter(|upload| upload.owner.terminal == terminal)
        {
            upload.cleanup_pending = true;
            upload.deadline = Instant::now();
        }
        Self::reap(&mut state, Instant::now());
        self.shared.changed.notify_one();
    }

    fn upload<'a>(
        state: &'a mut State,
        owner: &ImagePasteOwner,
        id: &str,
    ) -> anyhow::Result<&'a mut Upload> {
        let upload = state
            .uploads
            .get_mut(&(owner.client, id.to_owned()))
            .ok_or_else(|| anyhow::anyhow!("image-upload-expired"))?;
        anyhow::ensure!(&upload.owner == owner, "image-owner-mismatch");
        anyhow::ensure!(!upload.cleanup_pending, "image-upload-expired");
        Ok(upload)
    }

    fn reap(state: &mut State, now: Instant) {
        state.uploads.retain(|_, upload| {
            if upload.deadline > now {
                return true;
            }
            upload.cleanup_pending = true;
            if upload.delivery_in_flight {
                // Keep the file and reservation until the terminal write
                // returns. Removing it here could race the reader or cause a
                // partial paste to reference a vanished path.
                upload.deadline = now + Duration::from_secs(1);
                return true;
            }
            if upload.file.remove_owned() {
                return false;
            }
            // A failed deletion still occupies disk. Keep the full reservation
            // charged and prohibit append/commit until cleanup succeeds.
            upload.deadline = now + Duration::from_secs(1);
            true
        });
    }
}

impl Drop for ImagePasteStore {
    fn drop(&mut self) {
        let mut state = self.shared.state.lock().unwrap();
        state.uploads.clear();
        state.stopped = true;
        self.shared.changed.notify_one();
    }
}

fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn extension(mime: &str) -> Option<&'static str> {
    match mime {
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/gif" => Some("gif"),
        "image/webp" => Some("webp"),
        _ => None,
    }
}

pub(crate) fn matches_mime(mime: &str, bytes: &[u8]) -> bool {
    match mime {
        "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg" => bytes.starts_with(b"\xff\xd8\xff"),
        "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        "image/webp" => bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"),
        _ => false,
    }
}

#[cfg(test)]
#[path = "image_paste_tests.rs"]
mod tests;
