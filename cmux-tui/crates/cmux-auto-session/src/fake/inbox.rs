//! The inbox: a device sends, the holder reads and acks (the real store's `inbox.ts` and the
//! routes that use it).

use super::check;
use super::record::{MAX_INBOX_PENDING, Record};
use super::rules::{self, Refuse, Step};
use super::store::{Caller, Message, Store, invalid, named, writer};
use crate::cloud::CloudResult;
use crate::wire::{ErrorCode, InboxAck, InboxMessage, InboxPost, InboxPosted, SessionView};

/// Acked messages keep their id this long (counted in messages), so a late repeat of one is
/// still known.
const KEEP_ACKED: u64 = 256;
/// The most one read answers; cut once the texts pass the size (the first always fits).
const PAGE_MAX: usize = 64;
const PAGE_MAX_BYTES: usize = 1 << 20;

impl Store {
    /// Takes one message from any of the owner's devices. An id the inbox has already stores
    /// nothing new and answers what the first answered. Who gets a new one is
    /// `rules::deliver`.
    pub fn post_inbox(
        &mut self,
        caller: &Caller,
        id: &str,
        message: &InboxPost,
    ) -> CloudResult<InboxPosted> {
        named(id)?;
        self.owner_only(caller)?;
        if !check::message_id(&message.id) {
            return Err(invalid("id: the message's id (letters, digits, _ . : -, at most 128)"));
        }
        if !check::text(&message.text) {
            return Err(invalid("text: the message (at most 262144 characters)"));
        }
        let machine = self.machine.clone();
        let (state, session) = self.apply(id, |chat, now| {
            if !chat.rec.auto {
                return Err(Refuse::new(ErrorCode::Closed, "Auto is off for this chat"));
            }
            if let Some(sent) = chat.inbox.iter().find(|sent| sent.id == message.id) {
                return Ok(Step::same(sent.state));
            }
            if chat.rec.inbox.saturating_sub(chat.rec.inbox_acked) >= MAX_INBOX_PENDING {
                let full = "too many messages are waiting for this chat";
                return Err(Refuse::new(ErrorCode::TooLarge, full));
            }
            let counted = Record { inbox: chat.rec.inbox.saturating_add(1), ..chat.rec.clone() };
            let (rec, state) = rules::deliver(counted, machine.as_ref(), now);
            chat.inbox.push(Message {
                n: rec.inbox,
                id: message.id.clone(),
                text: Some(message.text.clone()),
                state,
                at: now,
            });
            Ok(Step::loud(state, rec))
        })?;
        Ok(InboxPosted { state, session })
    }

    /// The messages after number `after` that the holder has not acked, in order.
    pub fn inbox(&self, caller: &Caller, id: &str, after: u64) -> CloudResult<Vec<InboxMessage>> {
        let chat = self.admitted(caller, id, false)?;
        let after = after.max(chat.rec.inbox_acked);
        let mut messages: Vec<InboxMessage> = Vec::new();
        let mut bytes = 0usize;
        for message in chat.inbox.iter().filter(|message| message.n > after) {
            let Some(text) = &message.text else { continue };
            bytes = bytes.saturating_add(text.len());
            if messages.len() >= PAGE_MAX || (!messages.is_empty() && bytes > PAGE_MAX_BYTES) {
                break;
            }
            let (n, id, text) = (message.n, message.id.clone(), text.clone());
            messages.push(InboxMessage { n, id, text, at: message.at });
        }
        Ok(messages)
    }

    /// The holder took every message through `through`: their text goes, their ids stay a
    /// while for repeats. An ack past the newest message is one of the newest.
    pub fn ack_inbox(
        &mut self,
        caller: &Caller,
        id: &str,
        ack: &InboxAck,
    ) -> CloudResult<SessionView> {
        writer(&ack.holder)?;
        self.admitted(caller, id, true)?;
        let acked = self.apply(id, |chat, _| {
            rules::fence(&chat.rec, caller, &ack.holder, ack.epoch)?;
            let through = ack.through.min(chat.rec.inbox);
            if through <= chat.rec.inbox_acked {
                return Ok(Step::same(()));
            }
            let forgotten = through.saturating_sub(KEEP_ACKED);
            chat.inbox.retain(|message| message.n > forgotten);
            for message in chat.inbox.iter_mut().filter(|message| message.n <= through) {
                message.text = None;
            }
            Ok(Step::loud((), Record { inbox_acked: through, ..chat.rec.clone() }))
        });
        acked.map(|((), view)| view)
    }
}
