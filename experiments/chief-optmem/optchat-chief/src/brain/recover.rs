//! Restart after a host that stopped during a turn. The pending turn says,
//! per batch of logged items, where the batch starts in the log and whether
//! every item reached it; the log's length tells how many did when the save
//! after the appends was lost. Each logged item's bookkeeping is finished
//! (cursor for a human message, `Reported` for a child's report), so nothing
//! is logged twice; items that never reached the log are caught up again.

use optchat_host::OptChat;

use super::{reply_entry, reply_key};
use crate::state::{ChildStatus, HostState, Item};
use crate::turn::Orphan;

/// The notice a human gets when the turn that took their message stopped.
const INTERRUPTED: &str = "(interrupted: the Chief stopped during this turn. Your message is in its memory; send it again for an answer.)";

/// Finishes the pending turn's bookkeeping in `state` and clears it.
/// Returns the names of acpmux turn sessions to remove whose id was never
/// saved; a session whose id is known becomes an orphan instead, so what it
/// did after the last fold still reaches the log (section 7).
pub(super) fn recover(chat: &OptChat, state: &mut HostState, acpmux: bool) -> Vec<String> {
    let Some(turn) = state.turn.take() else {
        return Vec::new();
    };
    let messages = chat.status().messages;
    let opening = turn.opening();
    let mut batches: Vec<(u64, Vec<Item>, bool)> = Vec::new();
    match turn.first_id {
        // Once the key is set, every opening item is logged.
        Some(first) => batches.push((first, opening, !turn.key.is_empty())),
        // A pre-`first_id` host: it set the key only after logging.
        None => batches.push((0, opening, true)),
    }
    for batch in &turn.mid {
        batches.push((batch.at, batch.items.clone(), batch.done));
    }
    let mut human = false;
    let mut opening_logged = false;
    for (k, (at, items, done)) in batches.iter().enumerate() {
        let logged = if *done {
            items.len()
        } else {
            (messages.saturating_sub(*at) as usize).min(items.len())
        };
        if k == 0 {
            opening_logged = logged > 0;
        }
        for item in &items[..logged] {
            // A logged image keeps its description pending until the note is
            // written (the save after the describe may have been lost).
            for image in &item.images {
                if !state.undescribed.contains(image) {
                    state.undescribed.push(image.clone());
                }
            }
            if let Some(seq) = item.seq {
                human = true;
                state.logged_seq = state.logged_seq.max(seq);
            }
            if let Some(child) = &item.child
                && let Some(record) = state.children.get_mut(&child.session_id)
            {
                record.status = ChildStatus::Reported;
                record.floor = child.floor;
            }
        }
    }
    let key = if !turn.key.is_empty() {
        Some(turn.key.clone())
    } else if opening_logged {
        turn.first_id.map(|first| reply_key(chat, first))
    } else {
        None
    };
    // Messages in the log stay there, unanswered (section 7); a human whose
    // message it was hears why, once. Messages that never reached the log
    // are caught up again from the cursor and answered normally.
    if human && let (Some(conversation), Some(key)) = (turn.conversation.clone(), key) {
        state
            .outbox
            .push(reply_entry(conversation, &key, INTERRUPTED));
    }
    if !acpmux {
        return Vec::new();
    }
    match turn.session_id {
        Some(session) => {
            state.orphans.push(Orphan {
                session,
                after: turn.after,
            });
            Vec::new()
        }
        None => vec![turn.session],
    }
}
