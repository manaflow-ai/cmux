//! The fake store's rules, through [`AutoCloud`] as another crate's tests use it.

mod callers;
mod copy;
mod daemon;
mod devices;
mod handback;
mod held;
mod inbox;
mod journey;
mod lease;
mod owner;

use std::fmt::Debug;
use std::future::Future;
use std::ops::RangeInclusive;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use serde_json::json;

use super::FakeAutoCloud;
use crate::chunks::name_of;
use crate::cloud::{AutoCloud, CloudResult};
use crate::consts::MANIFEST_VERSION;
use crate::wire::{
    AssignmentKind, Cwd, ErrorCode, EventsAppend, Fence, Holder, InboxPost, InboxPosted,
    LeaseAnswer, LeaseRequest, MachineSetting, Manifest, PutRequest, SeqRecord, SessionView,
    SnapshotPost,
};

const CHAT: &str = "chat_1";
const VM: &str = "vm_1";
const TEAM: &str = "team_0123456789abcdef0123";

/// The answer of a request the store does not hold.
fn ready<T>(future: impl Future<Output = T>) -> T {
    let mut cx = Context::from_waker(Waker::noop());
    match pin!(future).poll(&mut cx) {
        Poll::Ready(answer) => answer,
        Poll::Pending => panic!("the store holds the request"),
    }
}

/// The `auto.*` code a call was refused with.
fn code<T: Debug>(result: CloudResult<T>) -> ErrorCode {
    let error = result.expect_err("refused");
    error.code().unwrap_or_else(|| panic!("no auto.* code: {error}"))
}

/// The status of a call that failed.
fn status<T: Debug>(result: CloudResult<T>) -> Option<u16> {
    result.expect_err("refused").status()
}

fn mac() -> Holder {
    Holder::device("mac")
}

fn vm() -> Holder {
    Holder::vm(VM)
}

fn machine_setting() -> MachineSetting {
    MachineSetting { team: TEAM.into(), machine: VM.into() }
}

fn put_request(device: &str) -> PutRequest {
    PutRequest {
        auto: true,
        title: "Fix the build".into(),
        harness: "claude".into(),
        device: device.into(),
        keep_in_cloud: None,
        repo: None,
    }
}

/// A store at time 0 with the Auto machine `VM` and the chat `CHAT`, held by the laptop `mac`
/// at epoch 1: the owner's handle and the machine's.
fn store() -> (FakeAutoCloud, FakeAutoCloud) {
    let owner = FakeAutoCloud::new();
    ready(owner.set_machine(&machine_setting())).expect("the Auto machine");
    ready(owner.put(CHAT, &put_request("mac"))).expect("the chat");
    let machine = owner.as_machine(VM);
    (owner, machine)
}

/// The same store once the laptop's lease ran out mid-work: the machine holds the chat at
/// epoch 2, has acked its takeover, and is at work.
fn taken_over() -> (FakeAutoCloud, FakeAutoCloud) {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(crate::consts::LEASE_MS);
    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    (owner, machine)
}

fn chat(cloud: &FakeAutoCloud) -> SessionView {
    cloud.peek(CHAT).expect("the chat")
}

/// A renewal as the holder.
fn renew(cloud: &FakeAutoCloud, holder: &Holder, epoch: u64, needs_run: bool) -> LeaseAnswer {
    let request = LeaseRequest { holder: holder.clone(), epoch, needs_run, standby: None };
    ready(cloud.lease(CHAT, &request)).expect("a lease answer")
}

/// A renewal as a laptop standing by.
fn stand_by(cloud: &FakeAutoCloud, holder: &Holder, epoch: u64) -> LeaseAnswer {
    let request =
        LeaseRequest { holder: holder.clone(), epoch, needs_run: false, standby: Some(true) };
    ready(cloud.lease(CHAT, &request)).expect("a lease answer")
}

fn record(seq: u64) -> SeqRecord {
    SeqRecord { seq, record: json!({ "n": seq }) }
}

/// `holder` appends the events numbered `seqs` at `epoch`.
fn append_as(
    cloud: &FakeAutoCloud,
    holder: &Holder,
    epoch: u64,
    seqs: RangeInclusive<u64>,
) -> CloudResult<u64> {
    let events = EventsAppend { holder: holder.clone(), epoch, events: seqs.map(record).collect() };
    ready(cloud.append_events(CHAT, &events))
}

/// A folder's manifest: one tar of the chunks `tar`, taken after event `last_seq`.
fn manifest(tar: &[String], last_seq: u64) -> Manifest {
    Manifest {
        v: MANIFEST_VERSION,
        at: 0,
        last_seq,
        harness: "claude".into(),
        harness_session_id: "h".into(),
        cwd: Cwd::Folder { tar: tar.to_vec() },
        queue: Vec::new(),
        draft: String::new(),
        open_turn: None,
    }
}

/// `holder` stores `folder` as the chat's snapshot at `epoch`: its one chunk, then a manifest
/// that says it was taken after event `last_seq`.
fn snapshot_as(
    cloud: &FakeAutoCloud,
    holder: &Holder,
    epoch: u64,
    folder: &[u8],
    last_seq: u64,
) -> CloudResult<u64> {
    let name = name_of(folder);
    ready(cloud.put_chunk(CHAT, &name, folder, &Fence::new(holder.clone(), epoch)))?;
    let post =
        SnapshotPost { holder: holder.clone(), epoch, manifest: manifest(&[name], last_seq) };
    ready(cloud.post_snapshot(CHAT, &post))
}

/// One of the owner's devices sends a message to the chat.
fn send(cloud: &FakeAutoCloud, id: &str, text: &str) -> InboxPosted {
    let message = InboxPost { id: id.into(), text: text.into() };
    ready(cloud.post_inbox(CHAT, &message)).expect("posted")
}

/// What the machine is asked to do, by kind.
fn kinds(machine: &FakeAutoCloud) -> Vec<AssignmentKind> {
    let assignments = ready(machine.assignments(0)).expect("assignments");
    assignments.iter().map(|assignment| assignment.kind).collect()
}
