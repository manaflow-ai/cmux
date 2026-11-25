//! Hands a projected folder's away notice (`crate::projection::away_notice`, RFD 0007 "The Mac
//! goes away") to every acpmux chat on this machine working in that folder: a live local chat
//! whose folder is the mount point or below it. Each gets it once, as a `warn` notice from
//! `cmux` steered into a running turn (the agent is mid-turn, hitting the failed reads), under a
//! prompt id unique to the episode.

use std::ops::ControlFlow;
use std::path::Path;
use std::sync::{Arc, Weak};
use std::time::Duration;

use acpmux_client::wire::{ListFilter, ListView};
use serde_json::json;

use super::agent_session_attach::agent_session_link::list_source::{self, Opened};
use crate::mux::Mux;
use crate::mux::agent_message_pump::Handover;

/// How long finding the folder's chats may take.
const LIST_WITHIN: Duration = Duration::from_secs(5);
/// The most chats one notice goes to.
const MAX_CHATS: usize = 16;

/// Sends every projection's away notices to the chats working in its folder (first call wins).
pub(super) fn install(mux: &Arc<Mux>) {
    let mux: Weak<Mux> = Arc::downgrade(mux);
    crate::projection::tell_away_with(move |at, prompt_id, title, text| {
        if let Some(mux) = mux.upgrade() {
            tell(&mux, at, prompt_id, title, text);
        }
    });
}

/// Whether a chat in `folder` works in the projection mounted at `at`.
pub(crate) fn works_in(folder: &str, at: &Path) -> bool {
    Path::new(folder).starts_with(at)
}

fn tell(mux: &Mux, at: &Path, prompt_id: &str, title: &str, text: &str) {
    let Some(socket) = mux.control_clients.agent_sessions.socket() else { return };
    let mut source = match list_source::open(&socket, LIST_WITHIN) {
        Ok(Opened::List(source)) => source,
        Ok(Opened::V1) | Err(_) => {
            eprintln!("cmux-tui: projection away notice: acpmux's chat list cannot be read");
            return;
        }
    };
    let mut chats = Vec::new();
    let local = ListFilter { origin: Some("local".into()), ..ListFilter::default() };
    let walked = source.walk(ListView::Live, Some(local), |rows| {
        for row in rows {
            if !row.archived && row.folder.as_deref().is_some_and(|folder| works_in(folder, at)) {
                chats.push(row.chat_id);
            }
        }
        if chats.len() >= MAX_CHATS { ControlFlow::Break(()) } else { ControlFlow::Continue(()) }
    });
    if walked.is_err() {
        eprintln!("cmux-tui: projection away notice: acpmux's chat list ended early");
    }
    chats.truncate(MAX_CHATS);
    let notice =
        json!({"sender": crate::projection::AWAY_SENDER, "severity": "warn", "title": title});
    for chat in chats {
        let id = format!("{prompt_id}-{chat}");
        let meta = json!({"steer": true, "promptId": id, "resend": true, "notice": notice});
        match mux.acp_prompt(&chat, &id, text.to_owned(), meta) {
            Handover::Delivered => {}
            Handover::Unreachable => eprintln!("cmux-tui: projection away notice: no chat {chat}"),
            Handover::Failed(why) | Handover::Unsettled(why) => {
                eprintln!("cmux-tui: projection away notice to {chat}: {why}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_chat_works_in_the_projection_at_its_mount_point_or_below() {
        let at = Path::new("/home/u/work/chat");
        assert!(works_in("/home/u/work/chat", at));
        assert!(works_in("/home/u/work/chat/src", at));
        assert!(!works_in("/home/u/work/chat2", at));
        assert!(!works_in("/home/u/work", at));
    }
}
