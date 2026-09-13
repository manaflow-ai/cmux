//! Bounded temporary image ownership for the authenticated terminal control channel.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::image_paste_file::ImagePasteFile;
use base64::Engine;

pub(crate) const CAPABILITY: &str = "terminal-image-paste-v1";
pub(crate) const MAX_IMAGE_BYTES: usize = 20 * 1024 * 1024;
pub(crate) const MAX_CHUNK_BYTES: usize = 48 * 1024;
const MAX_RETAINED_BYTES: usize = 128 * 1024 * 1024;
const MAX_ENTRIES: usize = 32;
pub(crate) const IMAGE_TTL: Duration = Duration::from_secs(600);
const UPLOAD_TTL: Duration = Duration::from_secs(120);

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct ImagePasteOwner {
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
    deadline: Instant,
}

#[derive(Default)]
struct State {
    uploads: HashMap<(u64, String), Upload>,
    recovered: Vec<(Instant, ImagePasteFile)>,
    worker_started: bool,
    stopped: bool,
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

pub(crate) struct ImagePasteStore {
    shared: Arc<Shared>,
}

impl Default for ImagePasteStore {
    fn default() -> Self {
        Self::from_recovered(ImagePasteFile::recover())
    }
}

impl ImagePasteStore {
    fn from_recovered(recovered: Vec<(Instant, ImagePasteFile)>) -> Self {
        let store = Self { shared: Arc::new(Shared::default()) };
        {
            let mut state = store.shared.state.lock().unwrap();
            state.recovered = recovered;
            Self::reap(&mut state, Instant::now());
            if !state.recovered.is_empty() {
                let _ = store.start_worker(&mut state);
            }
        }
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
                        if let Some(deadline) = state
                            .uploads
                            .values()
                            .map(|upload| upload.deadline)
                            .chain(state.recovered.iter().map(|(deadline, _)| *deadline))
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

    pub(crate) fn begin(
        &self,
        owner: ImagePasteOwner,
        id: &str,
        mime: &str,
        size: usize,
    ) -> anyhow::Result<()> {
        anyhow::ensure!(valid_id(id), "image-invalid-request");
        anyhow::ensure!((1..=MAX_IMAGE_BYTES).contains(&size), "image-size-limit");
        let extension = extension(mime).ok_or_else(|| anyhow::anyhow!("image-type-rejected"))?;
        let mut state = self.shared.state.lock().unwrap();
        Self::reap(&mut state, Instant::now());
        anyhow::ensure!(
            !state.uploads.contains_key(&(owner.client, id.to_owned())),
            "image-duplicate-upload"
        );
        let reserved: usize = state
            .uploads
            .values()
            .map(|upload| upload.size)
            .chain(state.recovered.iter().map(|(_, file)| file.size()))
            .sum();
        let client_count =
            state.uploads.values().filter(|upload| upload.owner.client == owner.client).count();
        anyhow::ensure!(
            state.uploads.len() + state.recovered.len() < MAX_ENTRIES
                && client_count < 8
                && reserved + size <= MAX_RETAINED_BYTES,
            "image-capacity-limit"
        );
        let file = ImagePasteFile::create(extension)
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
                deadline: Instant::now() + UPLOAD_TTL,
            },
        );
        self.shared.changed.notify_one();
        Ok(())
    }

    pub(crate) fn append(
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
        upload.file.append(&bytes).map_err(|_| anyhow::anyhow!("image-storage-unavailable"))?;
        upload.received += bytes.len();
        Ok(())
    }

    /// Publishes once, directly through the terminal owner's paste primitive.
    /// No remote path is accepted from or returned to the client.
    pub(crate) fn commit(
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
        // Input delivery can fail after a partial write. Retain the readable file
        // until TTL and never automatically retry an ambiguous paste.
        upload.committed = true;
        upload.deadline = Instant::now() + IMAGE_TTL;
        self.shared.changed.notify_one();
        paste(&quoted).map_err(|_| anyhow::anyhow!("image-paste-uncertain"))
    }

    pub(crate) fn cancel(&self, owner: &ImagePasteOwner, id: &str) -> anyhow::Result<()> {
        let mut state = self.shared.state.lock().unwrap();
        if let Some(upload) = state.uploads.get(&(owner.client, id.to_owned())) {
            anyhow::ensure!(&upload.owner == owner, "image-owner-mismatch");
            anyhow::ensure!(!upload.committed, "image-already-pasted");
        }
        state.uploads.remove(&(owner.client, id.to_owned()));
        self.shared.changed.notify_one();
        Ok(())
    }

    pub(crate) fn disconnect(&self, client: u64) {
        // A completed attachment may still be read by the agent after reconnect.
        // Unpublished bytes go away immediately; published files retain their TTL.
        self.shared
            .state
            .lock()
            .unwrap()
            .uploads
            .retain(|_, upload| upload.owner.client != client || upload.committed);
        self.shared.changed.notify_one();
    }

    pub(crate) fn close_surface(&self, surface: u64) {
        self.shared
            .state
            .lock()
            .unwrap()
            .uploads
            .retain(|_, upload| upload.owner.surface != surface);
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
        Ok(upload)
    }

    fn reap(state: &mut State, now: Instant) {
        state.uploads.retain(|_, upload| upload.deadline > now);
        state.recovered.retain_mut(|(deadline, file)| {
            if *deadline <= now {
                file.expire();
                false
            } else {
                true
            }
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
