//! Projected folders for cmux Cloud machines.
//!
//! Instead of copying a Mac folder to a Cloud machine before a chat starts, the machine mounts a
//! read-only projection of it built from a stat-only manifest, and puts an overlay's upper layer on
//! its own disk for writes. The first read of a file's bytes is a fault that the Mac answers.
//!
//! The pieces, from the Mac's side to the machine's:
//!
//! - [`manifest`]: the stat-only description of the folder, its versioned encoding, and the
//!   [`manifest::Builder`] the Mac fills from its own walk (this crate never walks a disk).
//! - [`source`]: the fault interface. A request names a path and the version the machine believes,
//!   never a manifest index, so the Mac can re-check both.
//! - [`cache`]: the machine's on-disk chunk cache, keyed by path and version.
//! - [`core`]: the read path, independent of FUSE: cache first, then the source, with shared
//!   fetches, directory batching, read-ahead and the rules for changed, gone, withheld and
//!   unreachable files.
//! - `fuse` (Linux only): the read-only FUSE filesystem over [`core`].
//! - [`upper`]: reads an overlay upper directory into the change set for the way back.
//! - [`helper`]: the mount helper (`cmux-tui projfs …`, or the small `cmux-projfs` binary):
//!   FUSE lower plus overlay on a Cloud machine, bytes fetched through the session daemon.

pub mod cache;
pub mod core;
#[cfg(target_os = "linux")]
pub mod fuse;
pub mod helper;
pub mod manifest;
pub mod source;
pub mod upper;

pub use crate::cache::{CHUNK, ChunkCache, ChunkKey};
pub use crate::core::{Config, Core, ReadError, Stats};
pub use crate::manifest::{
    Builder, Delta, Entry, Index, Kind, Manifest, ManifestError, Stat, Version,
};
pub use crate::source::{Got, Source, Want};
