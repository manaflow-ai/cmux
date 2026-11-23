//! The fake store's records and the rules every route shares: the view, who may call, the
//! fence, the lease alarm and the takeover.

use std::collections::BTreeMap;
use std::task::Waker;

use serde_json::Value;

use crate::cloud::{AutoCloudError, CloudResult};
use crate::consts::{LEASE_MS, SNAPSHOT_MAX_BYTES};
use crate::wire::{
    AssignmentKind, Blocked, ErrorCode, Fence, Holder, InboxMessage, MachineSetting, Manifest,
    Repo, SessionView, State,
};

/// Who calls: the design's owner (a signed-in session or a person's install) or machine (a VM
/// install, by its machine id).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Caller {
    Owner,
    Machine(String),
}

/// One chat as the store keeps it.
#[derive(Clone, Debug)]
pub(super) struct Chat {
    pub id: String,
    pub title: String,
    pub harness: String,
    pub auto: bool,
    pub keep_in_cloud: bool,
    pub holder: Holder,
    pub epoch: u64,
    pub blocked: Option<Blocked>,
    pub needs_run: bool,
    /// The laptops standing by, each with when its listing runs out.
    pub standby: BTreeMap<Holder, u64>,
    pub repo: Option<Repo>,
    pub version: u64,
    pub created_at: u64,
    pub updated_at: u64,
    pub lease_expires_at: u64,
    /// What the machine holder is asked to do; it stays until the machine acks it.
    pub assignment: Option<AssignmentKind>,
    /// The newest inbox message when a `deliver` assignment was made.
    pub deliver_through: u64,
    /// The machine holder acked its takeover or create.
    pub acked: bool,
    /// The events; seq is the index plus one.
    pub events: Vec<Value>,
    pub chunks: BTreeMap<String, Vec<u8>>,
    pub snapshot: u64,
    pub manifest: Option<Manifest>,
    pub inbox: Vec<InboxMessage>,
    pub inbox_acked: u64,
}

impl Chat {
    pub fn new(id: &str, holder: Holder, now: u64) -> Chat {
        Chat {
            id: id.to_owned(),
            title: String::new(),
            harness: String::new(),
            auto: true,
            keep_in_cloud: false,
            holder,
            epoch: 1,
            blocked: None,
            needs_run: false,
            standby: BTreeMap::new(),
            repo: None,
            version: 1,
            created_at: now,
            updated_at: now,
            lease_expires_at: now.saturating_add(LEASE_MS),
            assignment: None,
            deliver_through: 0,
            acked: false,
            events: Vec::new(),
            chunks: BTreeMap::new(),
            snapshot: 0,
            manifest: None,
            inbox: Vec::new(),
            inbox_acked: 0,
        }
    }

    pub fn last_seq(&self) -> u64 {
        self.events.len() as u64
    }

    pub fn inbox_len(&self) -> u64 {
        self.inbox.len() as u64
    }

    pub fn inbox_pending(&self) -> bool {
        self.inbox_len() > self.inbox_acked
    }

    /// The chat has work that somebody must run.
    fn has_work(&self) -> bool {
        self.needs_run || self.inbox_pending()
    }

    /// A laptop stands by and the chat is not kept in the Cloud.
    fn handback_due(&self) -> bool {
        self.holder.is_vm() && !self.keep_in_cloud && !self.standby.is_empty()
    }

    /// What a client shows.
    fn state(&self) -> State {
        match &self.holder {
            Holder::Device(_) => State::Local,
            Holder::Parked => State::Parked,
            Holder::Vm(_) if !self.acked => State::Resuming,
            Holder::Vm(_) if self.handback_due() => State::ComingBack,
            Holder::Vm(_) => State::Cloud,
        }
    }

    /// The view changed.
    pub fn touch(&mut self, now: u64) {
        self.version = self.version.saturating_add(1);
        self.updated_at = now;
    }

    /// The holder changes: the epoch grows by one, and what belonged to the old holder goes.
    pub fn hand_to(&mut self, holder: Holder, now: u64) {
        self.standby.remove(&holder);
        self.lease_expires_at = if holder.is_parked() { 0 } else { now.saturating_add(LEASE_MS) };
        self.holder = holder;
        self.epoch = self.epoch.saturating_add(1);
        self.needs_run = false;
        self.blocked = None;
        self.assignment = None;
        self.acked = false;
    }

    /// The Auto machine becomes the holder, with an assignment to import the chat.
    fn hand_to_machine(&mut self, machine: &str, now: u64) {
        self.hand_to(Holder::vm(machine), now);
        self.assignment = Some(AssignmentKind::Takeover);
    }

    /// The machine holder is asked to take the inbox's messages.
    pub fn deliver(&mut self) {
        self.assignment = Some(AssignmentKind::Deliver);
        self.deliver_through = self.inbox_len();
    }

    /// Nobody runs the chat, and it has work no machine can take.
    fn park_blocked(&mut self, now: u64) {
        let needs_run = self.needs_run;
        if !self.holder.is_parked() {
            self.hand_to(Holder::Parked, now);
        }
        // Kept, so the work goes to the Auto machine once there is one.
        self.needs_run = needs_run;
        self.blocked = Some(Blocked::NoMachine);
    }

    /// The write's holder and epoch are the current ones, and the chat is open.
    pub fn fenced(&self, fence: &Fence) -> CloudResult<()> {
        self.open()?;
        if self.holder == fence.holder && self.epoch == fence.epoch {
            return Ok(());
        }
        let message = format!(
            "the chat is held by {} at epoch {}, not by {} at epoch {}",
            self.holder, self.epoch, fence.holder, fence.epoch
        );
        Err(refused(ErrorCode::StaleEpoch, message))
    }

    /// Auto is on for the chat.
    pub fn open(&self) -> CloudResult<()> {
        if self.auto {
            Ok(())
        } else {
            Err(refused(ErrorCode::Closed, "Auto is off for this chat"))
        }
    }
}

pub(super) fn refused(code: ErrorCode, message: impl Into<String>) -> AutoCloudError {
    AutoCloudError::refused(code, message)
}

pub(super) fn invalid(message: &str) -> AutoCloudError {
    AutoCloudError::http(400, "validation.invalid", message)
}

pub(super) fn not_found() -> AutoCloudError {
    AutoCloudError::http(404, "not_found", "not found")
}

/// Everything one owner's store holds.
#[derive(Debug)]
pub(super) struct Store {
    pub now: u64,
    pub team: String,
    pub owner: String,
    pub machine: Option<MachineSetting>,
    /// The chats, by id, and their ids in the order they were made.
    pub chats: BTreeMap<String, Chat>,
    pub order: Vec<String>,
    /// Every machine start the store asked for, by machine id.
    pub starts: Vec<String>,
    /// Every call that reached the store, by route name.
    pub calls: Vec<&'static str>,
    pub snapshot_max: u64,
    pub made: u64,
    /// The held requests to wake when something changes.
    pub wakers: Vec<Waker>,
}

impl Store {
    pub fn new() -> Store {
        Store {
            now: 0,
            team: "team".to_owned(),
            owner: "owner".to_owned(),
            machine: None,
            chats: BTreeMap::new(),
            order: Vec::new(),
            starts: Vec::new(),
            calls: Vec::new(),
            snapshot_max: SNAPSHOT_MAX_BYTES,
            made: 0,
            wakers: Vec::new(),
        }
    }

    /// Held requests look again.
    pub fn wake(&mut self) {
        for waker in self.wakers.drain(..) {
            waker.wake();
        }
    }

    /// The view every route answers.
    pub fn view(&self, chat: &Chat) -> SessionView {
        SessionView {
            id: chat.id.clone(),
            title: chat.title.clone(),
            harness: chat.harness.clone(),
            team: self.team.clone(),
            owner: self.owner.clone(),
            auto: chat.auto,
            keep_in_cloud: chat.keep_in_cloud,
            holder: chat.holder.clone(),
            epoch: chat.epoch,
            state: chat.state(),
            blocked: chat.blocked,
            needs_run: chat.needs_run,
            standby: chat.standby.keys().cloned().collect(),
            last_seq: chat.last_seq(),
            snapshot: chat.snapshot,
            inbox: chat.inbox_len(),
            inbox_acked: chat.inbox_acked,
            repo: chat.repo.clone(),
            version: chat.version,
            created_at: chat.created_at,
            updated_at: chat.updated_at,
            lease_expires_at: chat.lease_expires_at,
        }
    }

    /// The view of the chat `id`.
    pub fn answer(&self, id: &str) -> CloudResult<SessionView> {
        self.chats.get(id).map(|chat| self.view(chat)).ok_or_else(not_found)
    }

    /// A chat by id, for a caller that may read it: the owner, or the owner's Auto machine.
    pub fn read(&self, caller: &Caller, id: &str) -> CloudResult<&Chat> {
        self.allowed(caller)?;
        self.chats.get(id).ok_or_else(not_found)
    }

    /// The chat changed by `change`, then its view. The view's version grows. A `change` that
    /// refuses must leave the chat as it was.
    pub fn change(
        &mut self,
        id: &str,
        change: impl FnOnce(&mut Chat, u64) -> CloudResult<()>,
    ) -> CloudResult<SessionView> {
        let now = self.now;
        let chat = self.chats.get_mut(id).ok_or_else(not_found)?;
        change(chat, now)?;
        chat.touch(now);
        self.settle(id);
        self.wake();
        self.answer(id)
    }

    /// The route is the owner's.
    pub fn owner_only(&self, caller: &Caller) -> CloudResult<()> {
        match caller {
            Caller::Owner => Ok(()),
            Caller::Machine(_) => {
                Err(AutoCloudError::http(403, "auth.forbidden", "the route is the owner's"))
            }
        }
    }

    /// The route is a machine's: the caller's machine id.
    pub fn machine_only<'a>(&self, caller: &'a Caller) -> CloudResult<&'a str> {
        self.allowed(caller)?;
        match caller {
            Caller::Machine(machine) => Ok(machine.as_str()),
            Caller::Owner => {
                Err(AutoCloudError::http(403, "auth.forbidden", "the route is a machine's"))
            }
        }
    }

    /// A machine caller is the owner's Auto machine.
    pub fn allowed(&self, caller: &Caller) -> CloudResult<()> {
        match caller {
            Caller::Owner => Ok(()),
            Caller::Machine(machine) => {
                let bound = self.machine.as_ref().is_some_and(|auto| auto.machine == *machine);
                if bound {
                    Ok(())
                } else {
                    Err(AutoCloudError::http(
                        401,
                        "auth.unauthenticated",
                        "the VM install is not bound to the Auto machine",
                    ))
                }
            }
        }
    }

    /// The caller may write as `holder`: the owner as one of its laptops, a machine as itself.
    pub fn may_be(&self, caller: &Caller, holder: &Holder) -> CloudResult<()> {
        self.allowed(caller)?;
        let ok = match (caller, holder) {
            (Caller::Owner, Holder::Device(_)) => true,
            (Caller::Machine(machine), Holder::Vm(named)) => machine == named,
            (Caller::Owner | Caller::Machine(_), _) => false,
        };
        if ok {
            Ok(())
        } else {
            Err(refused(ErrorCode::NotHolder, "the caller is not that holder"))
        }
    }

    /// A holder's write: the caller may be that holder, and the fence is current.
    pub fn write(&self, caller: &Caller, id: &str, fence: &Fence) -> CloudResult<()> {
        self.may_be(caller, &fence.holder)?;
        self.chats.get(id).ok_or_else(not_found)?.fenced(fence)
    }

    /// A parked chat with work gets the Auto machine as its holder, with a `takeover`
    /// assignment, and the machine is started. With no Auto machine it stays parked, blocked
    /// `no_machine`. Answers whether the chat changed.
    pub fn settle(&mut self, id: &str) -> bool {
        let now = self.now;
        let Some(chat) = self.chats.get_mut(id) else { return false };
        if !chat.auto || !chat.holder.is_parked() || !chat.has_work() {
            return false;
        }
        match &self.machine {
            Some(auto) => {
                chat.hand_to_machine(&auto.machine, now);
                self.starts.push(auto.machine.clone());
                true
            }
            None if chat.blocked.is_none() => {
                chat.park_blocked(now);
                true
            }
            None => false,
        }
    }

    /// The lease alarm, at the store's `now`. A laptop holder whose lease ran out loses the
    /// chat: to the Auto machine when the chat needs to run or has messages waiting (blocked
    /// `no_machine` without one), else it is parked. A standby laptop that stopped renewing is
    /// no longer listed. A machine's lease does not run out.
    pub fn alarm(&mut self) {
        let now = self.now;
        let Store { chats, machine, starts, .. } = self;
        let mut changed = false;
        for chat in chats.values_mut() {
            let listed = chat.standby.len();
            chat.standby.retain(|_, until| *until > now);
            let lapsed = chat.auto && chat.holder.is_device() && chat.lease_expires_at <= now;
            if lapsed {
                match machine.as_ref() {
                    Some(auto) if chat.has_work() => {
                        chat.hand_to_machine(&auto.machine, now);
                        starts.push(auto.machine.clone());
                    }
                    None if chat.has_work() => chat.park_blocked(now),
                    Some(_) | None => chat.hand_to(Holder::Parked, now),
                }
            }
            if lapsed || listed != chat.standby.len() {
                chat.touch(now);
                changed = true;
            }
        }
        if changed {
            self.wake();
        }
    }
}
