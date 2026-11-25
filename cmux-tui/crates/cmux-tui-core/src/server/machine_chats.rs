//! This machine's chats, for the chat reaper (`crate::projection::reap_once`): every local row of
//! the v2 list's `all` view (what `acpmux ls --all` walks), with the folder it runs in and its
//! archive bit. A daemon without the v2 list, or a read that fails or runs past `within`, is a
//! list not read ([`Chats::unread`]): the reaper frees nothing by it.

use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::time::Duration;

use acpmux_client::wire::{ListFilter, ListView};
use cmux_projection::reap::{Chat, Chats};

use super::agent_session_attach::agent_session_link::list_source::{self, Opened};

/// The chats of the acpmux at `socket`, read whole within `within`, or [`Chats::unread`].
#[must_use]
pub fn machine_chats(socket: &Path, within: Duration) -> Chats {
    let Ok(Opened::List(mut source)) = list_source::open(socket, within) else {
        return Chats::unread();
    };
    let mut rows = Vec::new();
    let local = ListFilter { origin: Some("local".into()), ..ListFilter::default() };
    let read = source.walk(ListView::All, Some(local), |page| {
        rows.extend(page.into_iter().map(|row| Chat {
            id: row.chat_id,
            folder: row.folder.map(PathBuf::from),
            archived: row.archived,
        }));
        ControlFlow::Continue(())
    });
    Chats { rows, complete: read.is_ok() }
}
