//! A small daemon for the journeys: [`step`] decides, and this runs its effects against the
//! fake store, as little of each as the store can tell apart.

use std::collections::VecDeque;

use serde_json::{Value, json};

use super::*;
use crate::chunks::{Pack, assemble};
use crate::cloud::AutoCloudError;
use crate::holder::{Change, Chat, Effect, Event, Side, step};
use crate::wire::InboxAck;

pub(super) struct Daemon {
    pub(super) cloud: FakeAutoCloud,
    pub(super) me: Holder,
    pub(super) chat: Chat,
    /// The chat's folder and log as this machine has them.
    pub(super) folder: Vec<u8>,
    pub(super) log: Vec<Value>,
    /// The chat's agent has work here: a turn running or a prompt queued.
    pub(super) busy: bool,
    /// Every effect it ran, by name.
    ran: Vec<&'static str>,
}

impl Daemon {
    pub(super) fn laptop(cloud: &FakeAutoCloud, device: &str) -> Daemon {
        Daemon::new(cloud.as_owner(), Holder::device(device), Side::Laptop)
    }

    pub(super) fn machine(cloud: &FakeAutoCloud, machine: &str) -> Daemon {
        Daemon::new(cloud.as_machine(machine), Holder::vm(machine), Side::Machine)
    }

    fn new(cloud: FakeAutoCloud, me: Holder, side: Side) -> Daemon {
        let chat = Chat::new(side, cloud.now());
        let (folder, log, ran) = (Vec::new(), Vec::new(), Vec::new());
        Daemon { cloud, me, chat, folder, log, busy: false, ran }
    }

    /// Steps the chat with `event`, runs the effects, and steps it with what came of them.
    pub(super) fn send(&mut self, event: Event) {
        let mut events = VecDeque::from([event]);
        while let Some(event) = events.pop_front() {
            let (chat, effects) = step(self.chat, event, self.cloud.now());
            self.chat = chat;
            for effect in effects {
                self.ran.push(effect.kind());
                events.extend(self.run(effect));
            }
        }
    }

    /// The tick the last `ScheduleAt` asked for, if its time has come.
    pub(super) fn tick(&mut self) {
        if self.chat.wake_at().is_some_and(|at| self.cloud.now() >= at) {
            self.send(Event::Tick);
        }
    }

    /// A machine's daemon reads its assignments.
    pub(super) fn read_assignments(&mut self) {
        for assignment in ready(self.cloud.assignments(0)).expect("assignments") {
            self.send(Event::Assigned { kind: assignment.kind, epoch: assignment.session.epoch });
        }
    }

    pub(super) fn fence(&self, epoch: u64) -> Fence {
        Fence::new(self.me.clone(), epoch)
    }

    pub(super) fn ran(&self, effect: &str) -> bool {
        self.ran.contains(&effect)
    }

    fn run(&mut self, effect: Effect) -> Option<Event> {
        match effect {
            Effect::Register { request } => {
                let Holder::Device(device) = &self.me else { panic!("only a laptop registers") };
                let result = ready(self.cloud.put(CHAT, &put_request(device)));
                Some(Event::from_registration(request, &self.me, &result))
            }
            Effect::Renew { request, epoch, needs_run, standby } => {
                let standby = standby.then_some(true);
                let lease = LeaseRequest { holder: self.me.clone(), epoch, needs_run, standby };
                Some(Event::from_renewal(request, &self.me, &ready(self.cloud.lease(CHAT, &lease))))
            }
            Effect::Close => {
                let off = PutRequest { auto: false, ..put_request("mac") };
                ready(self.cloud.put(CHAT, &off))
                    .ok()
                    .map(|view| Event::Closed { epoch: view.epoch })
            }
            // The snapshot's upload sends the events first.
            Effect::UploadEvents { .. } => None,
            Effect::UploadSnapshot { epoch, copy } => Some(match self.upload(epoch) {
                Ok(snapshot) => Event::SnapshotStored { copy, snapshot },
                Err(error) => {
                    let too_large = error.code() == Some(ErrorCode::TooLarge);
                    Event::SnapshotFailed { copy, too_large }
                }
            }),
            Effect::DrainInbox => Some(self.drain()),
            Effect::Import { epoch, .. } => Some(match self.import() {
                Ok(snapshot) => Event::ImportDone { epoch, snapshot },
                Err(_) => Event::ImportFailed { epoch },
            }),
            Effect::AckAssignment { epoch } => {
                ready(self.cloud.ack_assignment(CHAT, &self.fence(epoch))).expect("acked");
                None
            }
            // No answer here carries a wish yet, so the holder asks for none of the last four.
            Effect::StopTree
            | Effect::ContinueTree
            | Effect::KillTree
            | Effect::WriteLeftoverPatch
            | Effect::ShowBlocked { .. }
            | Effect::ScheduleAt { .. }
            | Effect::StopTurn
            | Effect::Give { .. }
            | Effect::Stay
            | Effect::NotMoved { .. } => None,
        }
    }

    /// The events the store lacks, then the folder as one tar: its chunks, then its manifest.
    fn upload(&self, epoch: u64) -> CloudResult<u64> {
        let stored = ready(self.cloud.get(CHAT))?.last_seq;
        let events = (1u64..)
            .zip(&self.log)
            .filter(|(seq, _)| *seq > stored)
            .map(|(seq, record)| SeqRecord { seq, record: record.clone() })
            .collect();
        let append = EventsAppend { holder: self.me.clone(), epoch, events };
        let last_seq = ready(self.cloud.append_events(CHAT, &append))?;

        let mut pack = Pack::new();
        let tar = pack
            .add(&self.folder)
            .map_err(|error| AutoCloudError::refused(ErrorCode::TooLarge, error.to_string()))?;
        for chunk in pack.chunks() {
            ready(self.cloud.put_chunk(CHAT, chunk.name, chunk.bytes, &self.fence(epoch)))?;
        }
        let manifest = manifest(&tar, last_seq);
        let post = SnapshotPost { holder: self.me.clone(), epoch, manifest };
        ready(self.cloud.post_snapshot(CHAT, &post))
    }

    /// The store's events and its newest snapshot become this machine's log and folder.
    fn import(&mut self) -> CloudResult<u64> {
        self.log.clear();
        loop {
            let page = ready(self.cloud.events(CHAT, self.log.len() as u64, None))?;
            if page.events.is_empty() {
                break;
            }
            self.log.extend(page.events.into_iter().map(|event| event.record));
        }
        match ready(self.cloud.snapshot(CHAT)) {
            Ok(answer) => {
                let Cwd::Folder { tar } = &answer.manifest.cwd else { panic!("a folder") };
                let chunk = |name: &str| ready(self.cloud.chunk(CHAT, name)).ok();
                self.folder = assemble(tar, chunk).expect("a whole folder");
                Ok(answer.snapshot)
            }
            Err(error) if error.code() == Some(ErrorCode::NoSnapshot) => Ok(0),
            Err(error) => Err(error),
        }
    }

    /// Reads the messages the holder has not acked, gives them to the chat (they are prompts,
    /// so the chat has work) and acks them. Answers the chat's work as it is now.
    fn drain(&mut self) -> Event {
        let session = ready(self.cloud.get(CHAT));
        let unread = session.as_ref().map(|session| session.inbox_acked).ok();
        let messages = unread.and_then(|after| ready(self.cloud.inbox(CHAT, after)).ok());
        let messages = messages.unwrap_or_default();
        if let (Ok(session), Some(through)) = (session, messages.last().map(|last| last.n)) {
            self.log.extend(messages.into_iter().map(|message| json!({ "user": message.text })));
            let ack = InboxAck { holder: self.me.clone(), epoch: session.epoch, through };
            ready(self.cloud.ack_inbox(CHAT, &ack)).expect("acked");
            self.busy = true;
        }
        Event::Changed { change: Change::QueueChanged, needs_run: self.busy }
    }
}
