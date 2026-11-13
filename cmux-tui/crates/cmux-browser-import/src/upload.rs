//! Files the app sends from a folder macOS protects (Safari's, an app container's), kept in the
//! daemon's memory and never written to disk: a copy on disk would be open to any process of the
//! same user, while the folder itself is not. A protocol message is at most 4 MiB, and Safari's
//! `History.db` is often tens of megabytes, so the app sends each file in chunks
//! (`upload.append`), names the upload in the reads, then drops it (`upload.drop`).
//!
//! An upload holds at most [`MAX_UPLOAD_BYTES`], all of them together [`MAX_TOTAL_BYTES`]; past
//! either the upload is dropped and the append answers `tooLarge`. One left idle for
//! [`IDLE`] (the app quit mid-import) is dropped at the next call.

use crate::model::ReadError;
use crate::place::Files;
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// The most one upload holds: a large Safari history, with room to spare.
pub const MAX_UPLOAD_BYTES: usize = 256 << 20;
/// The most every upload together holds.
pub const MAX_TOTAL_BYTES: usize = 512 << 20;
/// An upload not used for this long is dropped.
pub const IDLE: Duration = Duration::from_secs(300);

struct Upload {
    files: Arc<Files>,
    used: Instant,
}

/// The uploads of one daemon, by the id the app chose.
pub struct Uploads {
    held: Mutex<HashMap<String, Upload>>,
    max_upload: usize,
    max_total: usize,
}

impl Default for Uploads {
    fn default() -> Self {
        Self::with_caps(MAX_UPLOAD_BYTES, MAX_TOTAL_BYTES)
    }
}

/// The daemon's uploads.
pub static SHARED: LazyLock<Uploads> = LazyLock::new(Uploads::default);

/// An upload id: 1 to 64 letters, digits and `-` (the app sends a UUID).
pub fn valid_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

impl Uploads {
    /// Uploads of at most `max_upload` bytes each and `max_total` together.
    pub fn with_caps(max_upload: usize, max_total: usize) -> Self {
        Self { held: Mutex::default(), max_upload, max_total }
    }

    fn held(&self) -> std::sync::MutexGuard<'_, HashMap<String, Upload>> {
        self.held.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Drops the uploads idle since before `now - IDLE`.
    pub fn prune(&self, now: Instant) {
        self.held().retain(|_, upload| now.saturating_duration_since(upload.used) < IDLE);
    }

    /// Appends `bytes` to the file `key` of upload `id` (made when new). Over a cap the upload
    /// is dropped and the answer is `tooLarge`.
    pub fn append(
        &self,
        id: &str,
        key: String,
        bytes: &[u8],
        now: Instant,
    ) -> Result<(), ReadError> {
        let mut held = self.held();
        let total = held.values().map(|u| u.files.bytes()).fold(0, usize::saturating_add);
        let upload = held
            .entry(id.to_owned())
            .or_insert_with(|| Upload { files: Arc::new(Files::new()), used: now });
        let size = upload.files.bytes().saturating_add(bytes.len());
        if size > self.max_upload || total.saturating_add(bytes.len()) > self.max_total {
            held.remove(id);
            return Err(ReadError::TooLarge(format!(
                "the files sent from a protected folder are over the daemon's cap: {} bytes for \
                 one import read, {} for all of them; nothing was read",
                self.max_upload, self.max_total
            )));
        }
        upload.used = now;
        Arc::make_mut(&mut upload.files).append(key, bytes);
        Ok(())
    }

    /// The files of upload `id`, which stays until dropped or idle.
    pub fn files(&self, id: &str, now: Instant) -> Result<Arc<Files>, ReadError> {
        let mut held = self.held();
        let upload = held.get_mut(id).ok_or_else(|| {
            ReadError::Read(format!("upload {id} is not held (dropped, or idle for {IDLE:?})"))
        })?;
        upload.used = now;
        Ok(Arc::clone(&upload.files))
    }

    /// Forgets upload `id`.
    pub fn drop_upload(&self, id: &str) {
        self.held().remove(id);
    }

    /// How many uploads are held.
    pub fn len(&self) -> usize {
        self.held().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}
