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

    /// Whether the peer said at its last handshake that it pages a chat's native history.
    pub fn supports_native_history(&self) -> bool {
        self.native_history.load(Ordering::SeqCst)
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

    /// Whether the peer said at its last handshake that its prompt acceptances name the message
    /// they kept (`capabilities::SESSION_MESSAGES`).
    pub fn supports_session_messages(&self) -> bool {
        self.session_messages.load(Ordering::SeqCst)
    }

    /// Integration-test stand-in for a peer from before `session-messages-v1`: until the next
    /// handshake, as though it had not listed it.
    #[doc(hidden)]
    pub fn forget_session_messages_for_tests(&self) {
        self.session_messages.store(false, Ordering::SeqCst);
    }

    /// The link is up and its handshake finished: a caller's request may go out on it, as
    /// `request_on` checks.
    pub fn ready(&self) -> bool {
        self.connected.load(Ordering::SeqCst) && !self.admitting.load(Ordering::SeqCst)
    }

    /// The link on which the peer said at its handshake that its `session/resume` replays no
    /// history (`server/requests/session_open.rs`), while that link is still the current one.
    /// A resume goes on that link alone (`request_on`): a reconnect to an older build, which
    /// replays the chat as for a load, fails it as not sent rather than taking it.
    pub fn session_resume_link(&self) -> Option<u64> {
        let listed = self.session_resume_link.load(Ordering::SeqCst).checked_sub(1)?;
        (listed == self.link_epoch()).then_some(listed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Codex review of #27795: a peer that listed `sessionResume` on a link that has since
    /// ended has not said it of the next one, which may be an older build.
    #[tokio::test]
    async fn a_resume_link_is_only_the_current_link_that_listed_it() {
        let (tx, _notices) = tokio::sync::mpsc::channel(4);
        let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
        assert_eq!(peer.session_resume_link(), None);
        let link = peer.link_epoch();
        peer.session_resume_link.store(link + 1, Ordering::SeqCst);
        assert_eq!(peer.session_resume_link(), Some(link));
        peer.link_ended();
        assert_eq!(peer.session_resume_link(), None);
        // A peer that is not up is not ready, whatever it listed.
        assert!(!peer.ready());
    }
}
