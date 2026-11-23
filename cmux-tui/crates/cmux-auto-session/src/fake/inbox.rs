//! The inbox: a device sends, the holder reads and acks.

use super::store::{Caller, Store, invalid, not_found, refused};
use crate::cloud::CloudResult;
use crate::wire::{
    Delivery, ErrorCode, Fence, Holder, InboxAck, InboxMessage, InboxPost, InboxPosted, SessionView,
};

impl Store {
    /// Takes one message. An id the inbox has already stores nothing new. A parked chat goes to
    /// the Auto machine (`settle`); a machine that runs the chat gets a `deliver` assignment
    /// and a start, unless an assignment already waits for it.
    pub fn post_inbox(
        &mut self,
        caller: &Caller,
        id: &str,
        message: &InboxPost,
    ) -> CloudResult<InboxPosted> {
        self.owner_only(caller)?;
        if message.id.is_empty() {
            return Err(invalid("a message id is required"));
        }
        let chat = self.chats.get(id).ok_or_else(not_found)?;
        chat.open()?;
        let stored =
            chat.inbox.iter().find(|stored| stored.id == message.id).map(|stored| stored.n);
        let n = match stored {
            Some(n) => n,
            None => {
                let n = chat.inbox_len().saturating_add(1);
                let told = match &chat.holder {
                    Holder::Vm(machine) if chat.assignment.is_none() => Some(machine.clone()),
                    Holder::Vm(_) | Holder::Device(_) | Holder::Parked => None,
                };
                self.change(id, |chat, now| {
                    let (id, text) = (message.id.clone(), message.text.clone());
                    chat.inbox.push(InboxMessage { n, id, text, at: now });
                    if told.is_some() {
                        chat.deliver();
                    }
                    Ok(())
                })?;
                self.starts.extend(told);
                n
            }
        };
        let chat = self.chats.get(id).ok_or_else(not_found)?;
        // Where the message is now: taken, on its way to a machine, or waiting for a laptop's
        // next renewal (or for an Auto machine to exist).
        let state = if chat.inbox_acked >= n {
            Delivery::Delivered
        } else if chat.holder.is_vm() {
            Delivery::Resuming
        } else {
            Delivery::Queued
        };
        Ok(InboxPosted { state, session: self.view(chat) })
    }

    /// The messages after number `after`, for the chat's holder: the owner while a laptop
    /// holds it, the machine while it does.
    pub fn inbox(&self, caller: &Caller, id: &str, after: u64) -> CloudResult<Vec<InboxMessage>> {
        let chat = self.read(caller, id)?;
        chat.open()?;
        let holds = match (caller, &chat.holder) {
            (Caller::Owner, Holder::Device(_)) => true,
            (Caller::Machine(machine), Holder::Vm(named)) => machine == named,
            (Caller::Owner | Caller::Machine(_), _) => false,
        };
        if !holds {
            return Err(refused(ErrorCode::NotHolder, "only the chat's holder reads its inbox"));
        }
        Ok(chat.inbox.iter().filter(|message| message.n > after).cloned().collect())
    }

    /// The holder took every message up to `through`.
    pub fn ack_inbox(
        &mut self,
        caller: &Caller,
        id: &str,
        ack: &InboxAck,
    ) -> CloudResult<SessionView> {
        self.write(caller, id, &Fence::new(ack.holder.clone(), ack.epoch))?;
        let chat = self.chats.get(id).ok_or_else(not_found)?;
        if ack.through > chat.inbox_len() {
            return Err(invalid("through is past the newest message"));
        }
        self.change(id, |chat, _| {
            chat.inbox_acked = chat.inbox_acked.max(ack.through);
            Ok(())
        })
    }
}
