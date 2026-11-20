//! Projected folders (RFD 0007, `docs/rfd/0007-projected-folders.md` in the HQ repo): a folder on
//! the person's Mac reaches a Cloud machine as a stat-only [`manifest::Manifest`], so the agent's
//! first turn starts in seconds however big the folder is. The machine mounts it ([`mount`],
//! Linux): every `stat`, listing and link is answered from the manifest, a file's bytes are fetched
//! from the Mac on first read ([`Fetch`], over [`link::Link`]) and kept in a cache on the
//! machine's disk, and everything the agent writes lands in an upper folder on the machine
//! ([`overlay`]), never on the Mac.

pub mod link;
pub mod manifest;
pub mod overlay;
pub mod wire;

#[cfg(target_os = "linux")]
pub mod mount;

/// Why a fetch of a file's bytes from the Mac failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FetchError {
    /// The file changed on the Mac since the manifest.
    Changed,
    /// The Mac could not read it.
    Failed,
    /// The Mac never shares it.
    Refused,
    /// No stream to the Mac (it is asleep or offline) within the wait.
    Away,
}

impl FetchError {
    /// The `errno` a read that failed this way answers with.
    #[must_use]
    pub fn errno(self) -> i32 {
        match self {
            // ESTALE, EIO, EACCES, EHOSTDOWN (Linux numbers; the mount is Linux only).
            Self::Changed => 116,
            Self::Failed => 5,
            Self::Refused => 13,
            Self::Away => 112,
        }
    }
}

/// Where a projection's file bytes come from.
pub trait Fetch: Send + Sync {
    /// `len` bytes of file `entry` at `offset` (fewer at its end).
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError>;
    /// The whole of each file in `entries`, in that order.
    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>>;
}
