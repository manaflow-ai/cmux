//! The lease and a machine's assignments: renew, release, read the assignments, ack one. What
//! each decides is in `rules.rs`.

use super::record::view_of;
use super::rules;
use super::store::{Caller, Chat, Store, named, writer};
use crate::cloud::CloudResult;
use crate::consts::LEASE_MS;
use crate::wire::{Assignment, Fence, Holder, LeaseAnswer, LeaseRequest, SessionView};

/// The most assignments one read answers.
const ASSIGNMENTS_MAX: usize = 100;

impl Store {
    /// A renewal: the answer is a role beside the chat as it is now (`rules::renew`).
    pub fn lease(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &LeaseRequest,
    ) -> CloudResult<LeaseAnswer> {
        writer(&request.holder)?;
        self.admitted(caller, id, true)?;
        let (role, session) =
            self.apply(id, |chat, now| rules::renew(&chat.rec, caller, request, now))?;
        Ok(LeaseAnswer { session, role, lease_ms: LEASE_MS })
    }

    /// The holder gives the chat up (`rules::release`).
    pub fn release(
        &mut self,
        caller: &Caller,
        id: &str,
        fence: &Fence,
    ) -> CloudResult<SessionView> {
        writer(&fence.holder)?;
        self.admitted(caller, id, true)?;
        let machine = self.machine.clone();
        let (holder, epoch) = (&fence.holder, fence.epoch);
        let released = self.apply(id, |chat, now| {
            rules::release(&chat.rec, caller, holder, epoch, machine.as_ref(), now)
        });
        released.map(|((), view)| view)
    }

    /// What the calling machine has not acked, oldest chat first. Any of the owner's machines
    /// may ask; one that holds nothing is answered an empty list.
    pub fn assignments(&self, caller: &Caller) -> CloudResult<Vec<Assignment>> {
        let me = Holder::vm(self.machine_only(caller)?);
        let mut mine: Vec<&Chat> =
            self.chats.values().filter(|chat| chat.rec.holder == me).collect();
        // The chats come in id order, and the sort keeps that among chats made at one time.
        mine.sort_by_key(|chat| chat.rec.created_at);
        let assigned = mine.into_iter().filter_map(|chat| {
            let kind = chat.rec.assignment?;
            Some(Assignment { kind, session: view_of(&chat.rec, self.now) })
        });
        Ok(assigned.take(ASSIGNMENTS_MAX).collect())
    }

    /// The machine picked up what it was given (`rules::ack_assignment`).
    pub fn ack_assignment(
        &mut self,
        caller: &Caller,
        id: &str,
        fence: &Fence,
    ) -> CloudResult<SessionView> {
        named(id)?;
        self.machine_only(caller)?;
        writer(&fence.holder)?;
        self.admitted(caller, id, true)?;
        let (holder, epoch) = (&fence.holder, fence.epoch);
        let acked = self
            .apply(id, |chat, now| rules::ack_assignment(&chat.rec, caller, holder, epoch, now));
        acked.map(|((), view)| view)
    }
}
