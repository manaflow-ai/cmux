//! The lease and a machine's assignments: renew, release, read the assignments, ack one.

use super::store::{Caller, Store, not_found};
use crate::cloud::CloudResult;
use crate::consts::LEASE_MS;
use crate::wire::{
    Assignment, AssignmentKind, Fence, Holder, LeaseAnswer, LeaseRequest, Role, SessionView,
};

impl Store {
    /// A renewal. The chat's holder is `holder` whatever epoch it names, and learns the current
    /// one from the answer. A laptop that renews a parked chat without `standby` takes it. A
    /// laptop that renews with `standby` is listed for a lease's length. Anyone else is `lost`.
    pub fn lease(
        &mut self,
        caller: &Caller,
        id: &str,
        request: &LeaseRequest,
    ) -> CloudResult<LeaseAnswer> {
        self.may_be(caller, &request.holder)?;
        let now = self.now;
        let chat = self.chats.get_mut(id).ok_or_else(not_found)?;
        chat.open()?;
        let standby = request.standby == Some(true);
        let before = (chat.epoch, chat.needs_run, chat.standby.len());
        let role = if chat.holder == request.holder {
            chat.needs_run = request.needs_run;
            chat.lease_expires_at = now.saturating_add(LEASE_MS);
            Role::Holder
        } else if chat.holder.is_parked() && request.holder.is_device() && !standby {
            chat.hand_to(request.holder.clone(), now);
            chat.needs_run = request.needs_run;
            Role::Holder
        } else if standby && request.holder.is_device() {
            chat.standby.insert(request.holder.clone(), now.saturating_add(LEASE_MS));
            Role::Standby
        } else {
            Role::Lost
        };
        // A renewal that only moves the lease's end is no change to wait for.
        if before != (chat.epoch, chat.needs_run, chat.standby.len()) {
            chat.touch(now);
            self.wake();
        }
        Ok(LeaseAnswer { session: self.answer(id)?, role, lease_ms: LEASE_MS })
    }

    /// The holder gives the chat up. It goes to the laptop standing by that renewed last,
    /// unless a machine releases a chat kept in the Cloud; with none it is parked. A parked
    /// chat with messages waiting goes back to the Auto machine.
    pub fn release(
        &mut self,
        caller: &Caller,
        id: &str,
        fence: &Fence,
    ) -> CloudResult<SessionView> {
        self.write(caller, id, fence)?;
        self.change(id, |chat, now| {
            let kept = chat.keep_in_cloud && chat.holder.is_vm();
            let home = chat.standby.iter().max_by_key(|(_, until)| **until);
            let next = match home {
                Some((laptop, _)) if !kept => laptop.clone(),
                Some(_) | None => Holder::Parked,
            };
            chat.hand_to(next, now);
            Ok(())
        })
    }

    /// What the calling machine is asked to do, oldest chat first.
    pub fn assignments(&self, caller: &Caller) -> CloudResult<Vec<Assignment>> {
        let me = Holder::vm(self.machine_only(caller)?);
        let mine = self.order.iter().filter_map(|id| self.chats.get(id));
        Ok(mine
            .filter(|chat| chat.auto && chat.holder == me)
            .filter_map(|chat| {
                chat.assignment.map(|kind| Assignment { kind, session: self.view(chat) })
            })
            .collect())
    }

    /// The machine did what it was asked. Messages that came since make a `deliver`.
    pub fn ack_assignment(
        &mut self,
        caller: &Caller,
        id: &str,
        fence: &Fence,
    ) -> CloudResult<SessionView> {
        self.machine_only(caller)?;
        self.write(caller, id, fence)?;
        self.change(id, |chat, _| {
            // Which messages the machine may not have been told of: after an import, any; after
            // a delivery, those newer than the ones it was made for.
            let untold = match chat.assignment.take() {
                Some(AssignmentKind::Takeover | AssignmentKind::Create) => {
                    chat.acked = true;
                    true
                }
                Some(AssignmentKind::Deliver) => chat.inbox_len() > chat.deliver_through,
                None => false,
            };
            if untold && chat.inbox_pending() {
                chat.deliver();
            }
            Ok(())
        })
    }
}
