//! The fake store: its chats, who may reach them, and the one way a rule's decision is
//! written (the real store's `session-do.ts`: `admitted`, `apply` and the alarm).

use std::collections::BTreeMap;
use std::task::Waker;

use serde_json::Value;

use super::check;
use super::record::{Record, view_of};
use super::rules::{Code, Decision, Refuse, Step, next_due, tick};
use crate::cloud::{AutoCloudError, CloudResult};
use crate::consts::SNAPSHOT_MAX_BYTES;
use crate::wire::{Delivery, ErrorCode, Holder, MachineSetting, Manifest, SessionView};

/// Chunks no snapshot named for this long are dropped when their chat is at its limit: an
/// upload that was given up.
const ABANDONED_MS: u64 = 24 * 3_600_000;

/// Who calls: the owner (a signed-in session or a person's install) or a machine (the VM
/// install bound to one of the owner's Cloud machines, by its machine id).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Caller {
    Owner,
    Machine(String),
}

/// One stored event: its record, and its size as JSON.
#[derive(Debug)]
pub(super) struct StoredEvent {
    pub record: Value,
    pub bytes: u64,
}

/// One stored chunk. `kept`: the chat's snapshot names it. The others wait for the manifest
/// that will.
#[derive(Debug)]
pub(super) struct Chunk {
    pub bytes: Vec<u8>,
    pub kept: bool,
    pub at: u64,
}

/// One inbox message. Its text goes once the holder acked it; its id stays a while, so a late
/// repeat of it is still known and answered what the first was.
#[derive(Debug)]
pub(super) struct Message {
    pub n: u64,
    pub id: String,
    pub text: Option<String>,
    pub state: Delivery,
    pub at: u64,
}

/// One chat: its record and its rows.
#[derive(Debug)]
pub(super) struct Chat {
    pub rec: Record,
    /// The events; seq is the index plus one.
    pub events: Vec<StoredEvent>,
    pub chunks: BTreeMap<String, Chunk>,
    /// The newest snapshot's manifest; its number is the record's `snapshot`.
    pub manifest: Option<Manifest>,
    pub inbox: Vec<Message>,
}

impl Chat {
    pub fn new(rec: Record) -> Chat {
        Chat { rec, events: Vec::new(), chunks: BTreeMap::new(), manifest: None, inbox: Vec::new() }
    }

    /// The chat closed: its events, snapshot and chunks go, and its messages' texts.
    pub fn drop_copy(&mut self) {
        self.events.clear();
        self.chunks.clear();
        self.manifest = None;
        for message in &mut self.inbox {
            message.text = None;
        }
    }

    /// Whether `size` more bytes fit beside the chunks waiting for their snapshot. At the
    /// limit, uploads that were given up make room first.
    pub fn room_for_chunk(&mut self, size: u64, max: u64, now: u64) -> bool {
        if self.waiting_bytes().saturating_add(size) <= max {
            return true;
        }
        let abandoned = now.saturating_sub(ABANDONED_MS);
        self.chunks.retain(|_, chunk| chunk.kept || chunk.at >= abandoned);
        self.waiting_bytes().saturating_add(size) <= max
    }

    fn waiting_bytes(&self) -> u64 {
        let waiting = self.chunks.values().filter(|chunk| !chunk.kept);
        waiting.fold(0u64, |sum, chunk| sum.saturating_add(size_of(&chunk.bytes)))
    }
}

/// A byte count as the store's sizes are kept.
pub(super) fn size_of(bytes: &[u8]) -> u64 {
    u64::try_from(bytes.len()).unwrap_or(u64::MAX)
}

/// A rule's refusal as the route answers it: with the chat as it is now. A code only `move`
/// and `give` use goes out as the raw code ([`AutoCloudError::move_refusal`] reads it).
fn refused(refuse: Refuse, session: SessionView) -> AutoCloudError {
    let code = match refuse.code {
        Code::Auto(code) => Some(code),
        Code::Move(_) => None,
    };
    AutoCloudError::Http {
        status: refuse.code.status(),
        code,
        raw_code: refuse.code.as_str().to_owned(),
        message: refuse.message,
        session: Some(Box::new(session)),
        last_seq: refuse.last_seq,
        missing: refuse.missing,
    }
}

pub(super) fn invalid(message: &str) -> AutoCloudError {
    AutoCloudError::http(400, "validation.invalid", message)
}

pub(super) fn not_found() -> AutoCloudError {
    AutoCloudError::http(404, "not_found", "not found")
}

/// A request body past its size limit: refused before any chat is read.
pub(super) fn body_too_large(max: usize) -> AutoCloudError {
    let message = format!("the request body is at most {max} bytes");
    AutoCloudError::refused(ErrorCode::TooLarge, message)
}

/// A chat's route starts at its id: one that does not read as a chat id is no route.
pub(super) fn named(id: &str) -> CloudResult<()> {
    if check::chat_id(id) { Ok(()) } else { Err(not_found()) }
}

/// The holder a write names is a laptop or a machine, with an id that reads as one.
pub(super) fn writer(holder: &Holder) -> CloudResult<()> {
    if check::writer(holder) {
        return Ok(());
    }
    Err(invalid("holder: device:<id> or vm:<machine>; epoch: the epoch the holder last saw"))
}

/// Everything one owner's store holds.
#[derive(Debug)]
pub(super) struct Store {
    pub now: u64,
    pub owner: String,
    pub machine: Option<MachineSetting>,
    pub chats: BTreeMap<String, Chat>,
    /// Every machine start the store asked for, by machine id.
    pub starts: Vec<String>,
    /// Every call that reached the store, by route name.
    pub calls: Vec<&'static str>,
    /// What one snapshot may name, what its chunks may take while they wait for it, and what a
    /// chat's events may take.
    pub chat_max: u64,
    /// The held requests to wake when something changes.
    pub wakers: Vec<Waker>,
}

impl Store {
    pub fn new() -> Store {
        Store {
            now: 0,
            owner: "owner".to_owned(),
            machine: None,
            chats: BTreeMap::new(),
            starts: Vec::new(),
            calls: Vec::new(),
            chat_max: SNAPSHOT_MAX_BYTES,
            wakers: Vec::new(),
        }
    }

    /// Held requests look again.
    pub fn wake(&mut self) {
        for waker in self.wakers.drain(..) {
            waker.wake();
        }
    }

    /// The route is the owner's.
    pub fn owner_only(&self, caller: &Caller) -> CloudResult<()> {
        match caller {
            Caller::Owner => Ok(()),
            Caller::Machine(_) => {
                Err(AutoCloudError::http(403, "auth.forbidden", "a Cloud machine cannot do this"))
            }
        }
    }

    /// The route is a machine's: the caller's machine id.
    pub fn machine_only<'a>(&self, caller: &'a Caller) -> CloudResult<&'a str> {
        match caller {
            Caller::Machine(machine) => Ok(machine.as_str()),
            Caller::Owner => Err(AutoCloudError::http(
                401,
                "auth.unauthenticated",
                "the Auto machine's VM install is required",
            )),
        }
    }

    /// The chat, when `by` may reach it. The owner reaches every chat. A machine reaches a
    /// chat it holds; for a write, also one it held last, so it is told `auto.stale_epoch`
    /// rather than that the chat is gone. Any other chat is 404 to it.
    pub fn admitted(&self, by: &Caller, id: &str, write: bool) -> CloudResult<&Chat> {
        let chat = self.chats.get(id).ok_or_else(not_found)?;
        let reaches = match by {
            Caller::Owner => true,
            Caller::Machine(machine) => {
                let holds = matches!(&chat.rec.holder, Holder::Vm(held) if held == machine);
                holds || (write && chat.rec.machine.as_ref() == Some(machine))
            }
        };
        if reaches { Ok(chat) } else { Err(not_found()) }
    }

    /// The chat `id` as it is now.
    pub fn view(&self, id: &str) -> Option<SessionView> {
        self.chats.get(id).map(|chat| view_of(&chat.rec, self.now))
    }

    /// One decision and its write. `decide` reads the chat and answers the record to write, an
    /// answer with no write, or a refusal; it changes the chat's rows (events, chunks, inbox)
    /// itself. A write a viewer can see (`loud`) takes the next version and wakes the held
    /// requests; a quiet one moves no version. A refusal goes out with the chat as it is.
    pub fn apply<T>(
        &mut self,
        id: &str,
        decide: impl FnOnce(&mut Chat, u64) -> Decision<T>,
    ) -> CloudResult<(T, SessionView)> {
        let now = self.now;
        let chat = self.chats.get_mut(id).ok_or_else(not_found)?;
        let before = (chat.rec.assignment, chat.rec.epoch);
        let woken = chat.rec.wish.as_ref().and_then(|wish| wish.wake.clone());
        let Step { out, rec, loud } = match decide(&mut *chat, now) {
            Ok(step) => step,
            Err(refuse) => return Err(refused(refuse, view_of(&chat.rec, now))),
        };
        let Some(rec) = rec else { return Ok((out, view_of(&chat.rec, now))) };
        if !loud {
            chat.rec = rec;
            return Ok((out, view_of(&chat.rec, now)));
        }
        chat.rec = Record { version: chat.rec.version.saturating_add(1), updated_at: now, ..rec };
        let view = view_of(&chat.rec, now);
        // An assignment the machine has not seen (another kind, or another epoch) starts it.
        let after = (chat.rec.assignment, chat.rec.epoch);
        if let (Some(_), Some(machine)) = (chat.rec.assignment, &chat.rec.machine)
            && after != before
        {
            self.starts.push(machine.clone());
        }
        // A wish to move the chat starts the machine it waits on: the Auto machine the chat
        // goes to, or the machine that holds it and may be paused.
        let wake = chat.rec.wish.as_ref().and_then(|wish| wish.wake.clone());
        if let Some(machine) = wake
            && woken.as_ref() != Some(&machine)
        {
            self.starts.push(machine);
        }
        self.wake();
        Ok((out, view))
    }

    /// A new chat. One made with an assignment starts its machine.
    pub fn insert(&mut self, chat: Chat) -> SessionView {
        let view = view_of(&chat.rec, self.now);
        if let (Some(_), Some(machine)) = (chat.rec.assignment, &chat.rec.machine) {
            self.starts.push(machine.clone());
        }
        self.chats.insert(chat.rec.id.clone(), chat);
        self.wake();
        view
    }

    /// The alarm, at the store's `now`: for every chat with something due, a laptop's lease
    /// that ran out and standbys that stopped renewing (`rules::tick`).
    pub fn alarm(&mut self) {
        let now = self.now;
        let due = |chat: &Chat| next_due(&chat.rec).is_some_and(|at| at <= now);
        let ids: Vec<String> =
            self.chats.iter().filter(|(_, chat)| due(chat)).map(|(id, _)| id.clone()).collect();
        if ids.is_empty() {
            return;
        }
        let machine = self.machine.clone();
        for id in ids {
            // A tick refuses nothing, and the chat is there: there is no error to pass on.
            let _ticked = self.apply(&id, |chat, now| {
                Ok(match tick(&chat.rec, machine.as_ref(), now) {
                    Some(next) => Step::loud((), next),
                    None => Step::same(()),
                })
            });
        }
    }
}
