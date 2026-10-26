//! The uploads of a closed connection, handed out of the store so their
//! partial files are removed after the store lock is released.

use super::{Attachments, Sink, Upload};

/// Uploads taken out of the store when their connection closed. Removing
/// their partial files is file I/O, so it runs after the store lock is
/// released, through [`Self::remove_partial_files`].
#[must_use = "the partial files stay on disk until remove_partial_files runs"]
#[derive(Debug)]
pub(crate) struct ClosedUploads(Vec<Upload>);

impl ClosedUploads {
    pub(super) fn new(uploads: Vec<Upload>) -> Self {
        Self(uploads)
    }

    /// Removes the uploads' partial files, noted as `fs_write` at the caller
    /// when there is a file to remove.
    #[track_caller]
    pub(crate) fn remove_partial_files(self) {
        let has_files = self
            .0
            .iter()
            .flat_map(|upload| &upload.pieces)
            .any(|piece| matches!(piece.sink, Sink::File { .. }));
        if has_files {
            crate::request_path::note(crate::request_path::BlockingKind::FsWrite);
        }
        for upload in self.0 {
            Attachments::drop_upload(upload);
        }
    }
}

#[cfg(test)]
#[path = "conversation_attachment_close_tests.rs"]
mod tests;
