//! Download links of local attachments (`ws-attachments-v1`): the local
//! counterpart of the cloud owner's signed download URL
//! (home-messaging.md section 10.1, `POST /v1/home/attachments/url`).
//!
//! `conversation-attachment-link` gives a participant a short-lived random
//! token for one variant of one record; the daemon's listener answers
//! `GET /attachments/<token>` (with byte ranges, so a browser's video player
//! can seek). The token names nothing (no conversation, hash or file name),
//! lives only in memory (a restart ends every link), and every request
//! checks the participant and the record again, as the cloud owner does on
//! every signed GET.

use std::time::{Duration, Instant};

use super::{Attachments, Piece, ReadReply};
use crate::conversation_store::ConversationStore;

/// How long a link answers (the cloud owner's `downloadTtlMs`).
pub(crate) const LINK_TTL: Duration = Duration::from_secs(10 * 60);
/// Links kept at once; the oldest goes first when a new one does not fit.
const MAX_LINKS: usize = 4_096;

/// What one link reads, and for whom.
#[derive(Debug, Clone)]
pub(crate) struct Link {
    pub actor: String,
    pub conversation: String,
    pub hash: String,
    pub piece: Piece,
    /// The display name for `Content-Disposition` (checked by the caller).
    pub name: Option<String>,
    /// A cloud conversation's attachment: read through the cloud owner's
    /// signed URL with the lease, never from this store.
    pub cloud: bool,
    /// The cloud lease person the link was made for (`<audience>:<account>`);
    /// a link of another person's lease reads nothing.
    pub lease: String,
    expires: Instant,
}

impl Attachments {
    fn drop_expired_links(&mut self, now: Instant) {
        self.links.retain(|_, link| link.expires > now);
    }
}

fn new_token() -> anyhow::Result<String> {
    let mut random = [0_u8; 32];
    getrandom::fill(&mut random).map_err(|_| anyhow::anyhow!("link token randomness"))?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// A token is 64 lowercase hex digits; anything else is never looked up.
pub(crate) fn valid_token(token: &str) -> bool {
    token.len() == 64 && token.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

impl ConversationStore {
    /// A new link to `piece` of `hash` for `actor`, who must be a participant
    /// that may read the record now (the same rule as
    /// `conversation-attachment-read`). Returns the token.
    pub(crate) fn attachment_link(
        &mut self,
        actor: &str,
        conversation: &str,
        hash: &str,
        piece: Piece,
        name: Option<String>,
    ) -> anyhow::Result<String> {
        // A zero-length read runs every check (participant, record, variant).
        self.attachment_read(actor, conversation, hash, piece, 0, 0)?;
        self.insert_link(actor, conversation, hash, piece, name, String::new())
    }

    /// A link to a cloud conversation's attachment; the caller already had the
    /// cloud owner sign a URL for it (the owner's access check).
    pub(crate) fn attachment_cloud_link(
        &mut self,
        actor: &str,
        conversation: &str,
        hash: &str,
        piece: Piece,
        name: Option<String>,
        lease: String,
    ) -> anyhow::Result<String> {
        self.insert_link(actor, conversation, hash, piece, name, lease)
    }

    fn insert_link(
        &mut self,
        actor: &str,
        conversation: &str,
        hash: &str,
        piece: Piece,
        name: Option<String>,
        lease: String,
    ) -> anyhow::Result<String> {
        let cloud = !lease.is_empty();
        let now = Instant::now();
        if self.attachments.links.len() >= MAX_LINKS {
            self.attachments.drop_expired_links(now);
        }
        let links = &mut self.attachments.links;
        while links.len() >= MAX_LINKS {
            let oldest = links.iter().min_by_key(|(_, link)| link.expires).map(|(t, _)| t.clone());
            let Some(oldest) = oldest else { break };
            links.remove(&oldest);
        }
        let token = new_token()?;
        links.insert(
            token.clone(),
            Link {
                actor: actor.to_owned(),
                conversation: conversation.to_owned(),
                hash: hash.to_owned(),
                piece,
                name,
                cloud,
                lease,
                expires: now + LINK_TTL,
            },
        );
        Ok(token)
    }

    /// The live link of `token`, or None (unknown or expired).
    pub(crate) fn attachment_link_target(&mut self, token: &str) -> Option<Link> {
        if !valid_token(token) {
            return None;
        }
        let now = Instant::now();
        match self.attachments.links.get(token) {
            Some(link) if link.expires > now => Some(link.clone()),
            Some(_) => {
                self.attachments.links.remove(token);
                None
            }
            None => None,
        }
    }

    /// One read through a link: the participant and record are checked
    /// again on every request (a member who left, or a record that was
    /// swept, reads nothing).
    pub(crate) fn attachment_link_read(
        &self,
        link: &Link,
        offset: u64,
        length: usize,
    ) -> anyhow::Result<ReadReply> {
        self.attachment_read(
            &link.actor,
            &link.conversation,
            &link.hash,
            link.piece,
            offset,
            length,
        )
    }
}
