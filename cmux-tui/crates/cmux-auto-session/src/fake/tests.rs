//! The fake store's rules, through [`AutoCloud`] as another crate's tests use it.

mod copy;
mod held;
mod inbox;
mod journey;
mod lease;
mod owner;

use std::fmt::Debug;
use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use super::FakeAutoCloud;
use crate::cloud::{AutoCloud, CloudResult};
use crate::wire::{
    ErrorCode, Fence, Holder, LeaseAnswer, LeaseRequest, MachineSetting, PutRequest, SessionView,
};

const CHAT: &str = "chat_1";
const VM: &str = "vm_1";

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

fn mac() -> Holder {
    Holder::device("mac")
}

fn vm() -> Holder {
    Holder::vm(VM)
}

fn machine_setting() -> MachineSetting {
    MachineSetting { team: "team_1".into(), machine: VM.into() }
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
/// epoch 2 and has acked its takeover.
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
