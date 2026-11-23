//! A chat's whole way, with [`step`] deciding and a small daemon running its effects against
//! the fake store: to the Cloud when the laptop goes away, and home when it is back.

use std::collections::VecDeque;

use serde_json::{Value, json};

use super::*;
use crate::chunks::{Pack, assemble};
use crate::cloud::AutoCloudError;
use crate::consts::{LEASE_MS, MANIFEST_VERSION, RENEW_MS};
use crate::holder::{Change, Chat, Effect, Event, Side, State, Stop, step};
use crate::wire::{
    Cwd, EventsAppend, InboxAck, InboxPost, Manifest, SeqRecord, SnapshotPost, State as Shown,
};

/// What a daemon does with a chat's effects, as little of it as the store can tell apart.
struct Daemon {
    cloud: FakeAutoCloud,
    me: Holder,
    chat: Chat,
    /// The chat's folder and log as this machine has them.
    folder: Vec<u8>,
    log: Vec<Value>,
    /// Every effect it ran, by name.
    ran: Vec<&'static str>,
}

impl Daemon {
    fn laptop(cloud: &FakeAutoCloud, device: &str) -> Daemon {
        Daemon::new(cloud.as_owner(), Holder::device(device), Side::Laptop)
    }

    fn machine(cloud: &FakeAutoCloud, machine: &str) -> Daemon {
        Daemon::new(cloud.as_machine(machine), Holder::vm(machine), Side::Machine)
    }

    fn new(cloud: FakeAutoCloud, me: Holder, side: Side) -> Daemon {
        let chat = Chat::new(side, cloud.now());
        Daemon { cloud, me, chat, folder: Vec::new(), log: Vec::new(), ran: Vec::new() }
    }

    /// Steps the chat with `event`, runs the effects, and steps it with what came of them.
    fn send(&mut self, event: Event) {
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
    fn tick(&mut self) {
        if self.chat.wake_at().is_some_and(|at| self.cloud.now() >= at) {
            self.send(Event::Tick);
        }
    }

    /// A machine's daemon reads its assignments.
    fn read_assignments(&mut self) {
        for assignment in ready(self.cloud.assignments(0)).expect("assignments") {
            self.send(Event::Assigned { kind: assignment.kind, epoch: assignment.session.epoch });
        }
    }

    fn fence(&self, epoch: u64) -> Fence {
        Fence::new(self.me.clone(), epoch)
    }

    fn ran(&self, effect: &str) -> bool {
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
                Some(Event::from_renewal(request, &ready(self.cloud.lease(CHAT, &lease))))
            }
            Effect::Release { epoch } => {
                match ready(self.cloud.release(CHAT, &self.fence(epoch))) {
                    Ok(_) => Some(Event::Released),
                    Err(error) => error.code().map(|_| Event::Released),
                }
            }
            Effect::Close => {
                let off = PutRequest { auto: false, ..put_request("mac") };
                ready(self.cloud.put(CHAT, &off)).ok().map(|_| Event::Closed)
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
            Effect::DrainInbox => {
                self.drain();
                None
            }
            Effect::Import { epoch, .. } => Some(match self.import() {
                Ok(snapshot) => Event::ImportDone { epoch, snapshot },
                Err(_) => Event::ImportFailed { epoch },
            }),
            Effect::AckAssignment { epoch } => {
                ready(self.cloud.ack_assignment(CHAT, &self.fence(epoch))).expect("acked");
                None
            }
            Effect::StopTree
            | Effect::ContinueTree
            | Effect::KillTree
            | Effect::WriteLeftoverPatch
            | Effect::ShowBlocked { .. }
            | Effect::ScheduleAt { .. } => None,
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
        let manifest = Manifest {
            v: MANIFEST_VERSION,
            at: self.cloud.now(),
            last_seq,
            harness: "claude".into(),
            harness_session_id: "h".into(),
            cwd: Cwd::Folder { tar },
            queue: Vec::new(),
            draft: String::new(),
            open_turn: None,
        };
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

    /// Reads the messages the holder has not acked, gives them to the chat, and acks them.
    fn drain(&mut self) {
        let Ok(session) = ready(self.cloud.get(CHAT)) else { return };
        let Ok(messages) = ready(self.cloud.inbox(CHAT, session.inbox_acked)) else { return };
        let Some(through) = messages.last().map(|message| message.n) else { return };
        self.log.extend(messages.into_iter().map(|message| json!({ "user": message.text })));
        let ack = InboxAck { holder: self.me.clone(), epoch: session.epoch, through };
        ready(self.cloud.ack_inbox(CHAT, &ack)).expect("acked");
    }
}

#[test]
fn a_chat_goes_to_the_cloud_and_comes_home() {
    let cloud = FakeAutoCloud::new();
    ready(cloud.set_machine(&machine_setting())).expect("the Auto machine");

    // Auto on: the laptop registers and sends its first copy.
    let mut mac = Daemon::laptop(&cloud, "mac");
    mac.folder = b"as the laptop left it".to_vec();
    mac.log = vec![json!({ "user": "fix the build" })];
    mac.send(Event::AutoOn);
    assert_eq!(mac.chat.state, State::Holding { epoch: 1 });
    let session = chat(&cloud);
    assert_eq!((session.snapshot, session.last_seq, session.needs_run), (1, 1, false));

    // A turn starts: the store learns the chat has work.
    mac.send(Event::Changed { change: Change::TurnStarted, needs_run: true });
    assert!(chat(&cloud).needs_run);

    // The lid closes mid-turn. Nothing runs on the laptop, and its lease runs out.
    cloud.advance(LEASE_MS);
    let session = chat(&cloud);
    assert_eq!((session.holder.clone(), session.epoch), (vm(), 2));
    assert_eq!(cloud.machine_starts(), [VM]);

    // The machine starts, reads its assignment and imports the chat.
    let mut machine = Daemon::machine(&cloud, VM);
    machine.read_assignments();
    assert_eq!(machine.chat.state, State::Serving { epoch: 2 });
    assert_eq!((machine.folder.as_slice(), machine.log.len()), (mac.folder.as_slice(), 1));
    assert_eq!(chat(&cloud).state, Shown::Cloud);

    // It goes on with the turn.
    machine.send(Event::Changed { change: Change::TurnStarted, needs_run: true });
    machine.folder = b"as the machine left it".to_vec();
    machine.log.push(json!({ "assistant": "the build is fixed" }));

    // The lid opens. The laptop stops its tree, asks, and learns a machine has the chat.
    cloud.advance(60_000);
    mac.send(Event::Wake);
    assert_eq!(mac.chat.state, State::Standby { epoch: 2 });
    assert!(mac.ran("stop_tree") && mac.ran("kill_tree") && mac.ran("write_leftover_patch"));
    assert!(!mac.ran("continue_tree") && !mac.chat.may_run());
    let session = chat(&cloud);
    assert_eq!(session.standby, [mac.me.clone()]);
    assert_eq!(session.state, Shown::ComingBack);

    // The turn ends on the machine with nothing queued: one last copy, then the release.
    machine.send(Event::Changed { change: Change::TurnEnded, needs_run: false });
    assert_eq!(machine.chat.state, State::Away);
    assert!(machine.ran("release") && machine.ran("kill_tree"));
    let session = chat(&cloud);
    assert_eq!((session.holder.clone(), session.epoch), (mac.me.clone(), 3));
    assert_eq!((session.state, session.last_seq), (Shown::Local, 2));

    // The laptop's next standby renewal answers "holder": it imports the copy and goes on.
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(mac.chat.state, State::Holding { epoch: 3 });
    assert!(mac.ran("import") && mac.chat.may_run());
    assert_eq!((mac.folder.as_slice(), mac.log.len()), (machine.folder.as_slice(), 2));

    // What the machine still has is fenced off.
    let stale = ready(machine.cloud.release(CHAT, &machine.fence(2)));
    assert_eq!(code(stale), ErrorCode::StaleEpoch);
}

#[test]
fn a_laptop_with_no_network_stops_and_goes_on_when_it_is_back() {
    let cloud = FakeAutoCloud::new();
    ready(cloud.set_machine(&machine_setting())).expect("the Auto machine");
    let mut mac = Daemon::laptop(&cloud, "mac");
    mac.send(Event::AutoOn);
    assert_eq!(mac.chat.state, State::Holding { epoch: 1 });

    // The network goes. The laptop keeps running, so it stops the chat by itself before the
    // store's lease runs out.
    mac.cloud.set_offline(true);
    for _ in 0..3 {
        cloud.advance(RENEW_MS);
        mac.tick();
    }
    assert_eq!(mac.chat.state, State::Holding { epoch: 1 });
    assert_eq!(chat(&cloud).holder, mac.me);
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(mac.chat.state, State::Stopped { epoch: 1, why: Stop::Offline });
    assert!(mac.ran("stop_tree") && !mac.chat.may_run());
    assert_eq!(chat(&cloud).holder, mac.me);

    // The idle chat is parked. A message for it would start the machine; none comes.
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(chat(&cloud).holder, Holder::Parked);

    // The network is back: the store answers "holder" at a new epoch, and the tree goes on.
    mac.cloud.set_offline(false);
    cloud.advance(RENEW_MS);
    mac.tick();
    assert_eq!(mac.chat.state, State::Holding { epoch: 3 });
    assert!(mac.ran("continue_tree") && !mac.ran("kill_tree") && mac.chat.may_run());
    assert_eq!(chat(&cloud).epoch, 3);

    // A message now waits for the laptop's next renewal, which drains it.
    let message = InboxPost { id: "m1".into(), text: "one more thing".into() };
    ready(cloud.post_inbox(CHAT, &message)).expect("posted");
    cloud.advance(RENEW_MS);
    mac.tick();
    assert!(mac.ran("drain_inbox"));
    assert!(!chat(&cloud).inbox_pending());
    assert_eq!(mac.log.last(), Some(&json!({ "user": "one more thing" })));
}
