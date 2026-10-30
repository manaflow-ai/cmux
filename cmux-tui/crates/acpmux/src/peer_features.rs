//! Part of `Peer` (`peer.rs`). What the peer said at its last handshake it serves (its
//! `initialize` reply's `_meta.acpmux.features`), read before a request that needs it is
//! forwarded (`server/peer_forward.rs`).

use super::Peer;
use std::sync::atomic::Ordering;

impl Peer {
    pub fn supports_trust_gate(&self) -> bool {
        self.trust_gate.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it takes `_acpmux/file_put`.
    pub fn supports_file_put(&self) -> bool {
        self.file_put.load(Ordering::SeqCst)
    }

    /// Whether the peer takes uploads in chunks (`file_put_begin`/`_chunk`/`_finish`/`_cancel`).
    pub fn supports_file_put_chunks(&self) -> bool {
        self.file_put_chunks.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it serves the media reader.
    pub fn supports_media_read(&self) -> bool {
        self.media_read.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it serves subagent transcripts.
    pub fn supports_subagent_transcript(&self) -> bool {
        self.subagent_transcript.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it saves a message's attachments.
    pub fn supports_send_attach(&self) -> bool {
        self.send_attach.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it reads uploaded files a message names.
    pub fn supports_prompt_uploads(&self) -> bool {
        self.prompt_uploads.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it answers upload status and checks a
    /// finish's `sha256` (`hub/file_uploads.rs`).
    pub fn supports_upload_resume(&self) -> bool {
        self.upload_resume.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that it answers `_acpmux/session/auth`.
    pub fn supports_session_auth(&self) -> bool {
        self.session_auth.load(Ordering::SeqCst)
    }

    /// Whether the peer said at its last handshake that its `session/resume` replays no
    /// history (`server/requests/session_open.rs`); an older one replays it, as for a load.
    pub fn supports_session_resume(&self) -> bool {
        self.session_resume.load(Ordering::SeqCst)
    }
}
