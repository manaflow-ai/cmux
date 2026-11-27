//! The image paste spool of the cmux-tui daemon (`terminal-image-paste-v1`,
//! docs/cloud-image-paste.md): bounded temporary image files that an
//! authenticated terminal client uploads and pastes by path, their private
//! storage directory, ownership marks, and crash recovery of abandoned
//! files. Unix only. cmux-tui-core re-exports [`image_paste`] at its old
//! path (`crate::image_paste`).

#[cfg(unix)]
pub mod image_paste;
#[cfg(unix)]
mod image_paste_file;
#[cfg(unix)]
mod image_paste_ownership;
#[cfg(unix)]
mod image_paste_recovery;
#[cfg(unix)]
mod image_paste_storage;
