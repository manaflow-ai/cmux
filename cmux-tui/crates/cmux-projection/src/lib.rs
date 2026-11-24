//! Projected folders (RFD 0007, `docs/rfd/0007-projected-folders.md` in the HQ repo): a folder on
//! the person's Mac reaches a Cloud machine as a stat-only [`manifest::Manifest`], so the agent's
//! first turn starts in seconds however big the folder is. The machine mounts it ([`mount`],
//! Linux): every `stat`, listing and link is answered from the manifest, a file's bytes are fetched
//! from the Mac on first read ([`Fetch`], over [`link::Link`]) and kept in a cache on the
//! machine's disk, and everything the agent writes lands in an upper folder on the machine
//! ([`overlay`]), never on the Mac.
//!
//! The same overlay projects a git commit on a lane VM ([`git`]): the manifest comes from the
//! commit's tree and the bytes from the host's own git object store, so a checkout costs one tree
//! listing and writes no files.

pub mod away;
pub mod git;
#[cfg(unix)]
pub mod git_swap;
pub mod layer;
pub mod link;
pub mod lower;
pub mod manifest;
#[cfg(unix)]
pub mod nfs;
#[cfg(unix)]
pub mod overlay;
pub mod peers;
#[cfg(unix)]
pub mod reap;
pub mod revision;
pub mod s3;
#[cfg(any(target_os = "linux", test))]
pub mod sparse;
#[cfg(unix)]
pub mod share;
#[cfg(unix)]
pub mod state;
pub mod store_fetch;
pub mod upload;
#[cfg(unix)]
pub mod upper;
pub mod way_back;
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
            Self::Changed => libc::ESTALE,
            Self::Failed => libc::EIO,
            Self::Refused => libc::EACCES,
            Self::Away => libc::EHOSTDOWN,
        }
    }
}

/// Where a projection's file bytes come from.
pub trait Fetch: Send + Sync {
    /// `len` bytes of file `entry` at `offset` (fewer at its end).
    fn read(&self, entry: u32, offset: u64, len: u32) -> Result<Vec<u8>, FetchError>;
    /// The whole of each file in `entries`, in that order.
    fn batch(&self, entries: &[u32]) -> Vec<Result<Vec<u8>, FetchError>>;
    /// Whether the overlay keeps what this source answers in its cache folder, and reads a
    /// folder's other small files ahead. A source already on the machine's disk, such as a git
    /// object store, says no: a second copy would only cost disk.
    fn cache(&self) -> bool {
        true
    }
}
