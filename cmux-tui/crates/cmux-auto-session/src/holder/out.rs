//! A step's result while it is being built: the chat so far and the effects so far.

use super::{Change, Chat, Effect, Sent, State};
use crate::consts::{RENEW_MS, STREAM_COPY_MS};

pub(super) struct Out {
    pub chat: Chat,
    pub effects: Vec<Effect>,
}

impl Out {
    pub fn new(chat: Chat) -> Out {
        Out { chat, effects: Vec::new() }
    }

    pub fn push(&mut self, effect: Effect) {
        self.effects.push(effect);
    }

    pub fn to(&mut self, state: State) {
        self.chat.state = state;
    }

    /// A new request number, awaited from `now`. The next one is due a renewal period later.
    fn request(&mut self, now: u64) -> u64 {
        self.chat.requests = self.chat.requests.saturating_add(1);
        self.chat.awaiting = Some(Sent { request: self.chat.requests, at: now });
        self.tick_in_a_period(now);
        self.chat.requests
    }

    /// Register the chat with the store.
    pub fn register(&mut self, now: u64) {
        let request = self.request(now);
        self.push(Effect::Register { request });
    }

    /// Renew as what the chat's state is now: the holder, or a laptop standing by. It replaces
    /// a renewal still waiting for its answer.
    pub fn renew(&mut self, now: u64) {
        let Some(epoch) = self.chat.epoch() else { return };
        let standby = matches!(self.chat.state, State::Standby { .. });
        let needs_run = self.chat.reports_needs_run();
        self.chat.told_needs_run = needs_run;
        let request = self.request(now);
        self.push(Effect::Renew { request, epoch, needs_run, standby });
    }

    /// Renew at once when the store's `needsRun` is no longer true, so a lease that runs out
    /// right after is decided on what the chat does now.
    pub fn renew_if_work_changed(&mut self, now: u64) {
        if self.chat.reports_needs_run() != self.chat.told_needs_run {
            self.renew(now);
        }
    }

    /// Send the events and a snapshot of the chat as it is now. Answers the copy's number.
    pub fn copy(&mut self, now: u64) -> u64 {
        let Some(epoch) = self.chat.epoch() else { return self.chat.copies };
        self.chat.copies = self.chat.copies.saturating_add(1);
        self.chat.copied_at = now;
        let copy = self.chat.copies;
        self.push(Effect::UploadEvents { epoch });
        self.push(Effect::UploadSnapshot { epoch, copy });
        copy
    }

    /// The chat's work changed while this machine runs it: record it, copy what the design says
    /// to copy, and tell the store when `needsRun` changed.
    pub fn work_changed(&mut self, change: Change, needs_run: bool, now: u64) {
        self.chat.needs_run = needs_run;
        let copy = match change {
            Change::TurnStarted => false,
            Change::Streaming => now >= self.chat.copied_at.saturating_add(STREAM_COPY_MS),
            Change::ToolEnded | Change::TurnEnded | Change::QueueChanged => true,
        };
        if copy {
            self.copy(now);
        }
        self.renew_if_work_changed(now);
    }

    /// The next tick is one renewal period from `now`.
    pub fn tick_in_a_period(&mut self, now: u64) {
        self.chat.renew_at = Some(now.saturating_add(RENEW_MS));
    }

    /// Nothing is scheduled and no answer is awaited.
    pub fn rest(&mut self) {
        self.chat.renew_at = None;
        self.chat.awaiting = None;
    }

    /// The next renewal, or the next try of what failed, is due.
    pub fn due(&self, now: u64) -> bool {
        self.chat.renew_at.is_some_and(|at| now >= at)
    }

    /// When the request an answer is for was sent, if it is the one awaited; it is awaited no
    /// longer. None for any other answer, which is ignored.
    pub fn answered(&mut self, request: u64) -> Option<u64> {
        match self.chat.awaiting {
            Some(sent) if sent.request == request => {
                self.chat.awaiting = None;
                Some(sent.at)
            }
            Some(_) | None => None,
        }
    }
}
