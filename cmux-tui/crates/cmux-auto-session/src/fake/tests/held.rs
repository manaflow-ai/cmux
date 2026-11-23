//! The held requests (`wait`, `assignments`) and a caller with no network.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::Wake;

use super::*;
use crate::consts::{LEASE_MS, WAIT_MAX_MS};
use crate::wire::{AssignmentKind, InboxPost};

/// Counts how often a held request was woken.
#[derive(Default)]
struct Woken(AtomicUsize);

impl Wake for Woken {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

impl Woken {
    fn times(&self) -> usize {
        self.0.load(Ordering::SeqCst)
    }
}

#[test]
fn wait_is_held_until_the_chat_changes() {
    let (owner, _machine) = store();
    let version = chat(&owner).version;
    // The chat is already past an older version: no wait.
    assert_eq!(ready(owner.wait(CHAT, 0, 25_000)).map(|session| session.version), Ok(version));

    let woken = Arc::new(Woken::default());
    let waker = Waker::from(Arc::clone(&woken));
    let mut cx = Context::from_waker(&waker);
    let mut held = Box::pin(owner.wait(CHAT, version, 25_000));
    assert!(held.as_mut().poll(&mut cx).is_pending());

    // A renewal that only moves the lease's end is no change.
    renew(&owner, &mac(), 1, false);
    assert!(held.as_mut().poll(&mut cx).is_pending());
    assert_eq!(woken.times(), 0);

    let message = InboxPost { id: "m1".into(), text: "hello".into() };
    ready(owner.post_inbox(CHAT, &message)).expect("posted");
    assert!(woken.times() >= 1);
    let Poll::Ready(Ok(session)) = held.as_mut().poll(&mut cx) else {
        panic!("the chat changed, so the wait answers");
    };
    assert!(session.version > version);
    assert_eq!(session.inbox, 1);
}

#[test]
fn wait_answers_at_its_deadline_which_is_at_most_25_seconds() {
    let (owner, _machine) = store();
    let version = chat(&owner).version;
    let mut cx = Context::from_waker(Waker::noop());
    let mut held = Box::pin(owner.wait(CHAT, version, 10 * WAIT_MAX_MS));
    assert!(held.as_mut().poll(&mut cx).is_pending());
    owner.advance(WAIT_MAX_MS - 1);
    assert!(held.as_mut().poll(&mut cx).is_pending());
    owner.advance(1);
    let Poll::Ready(Ok(session)) = held.as_mut().poll(&mut cx) else {
        panic!("the deadline came, so the wait answers");
    };
    assert_eq!(session.version, version);

    // A timeout of 0 never holds.
    assert_eq!(ready(owner.wait(CHAT, version, 0)).map(|session| session.version), Ok(version));
    assert_eq!(
        ready(owner.wait("no_such_chat", 0, 1_000)).expect_err("unknown").status(),
        Some(404)
    );
}

#[test]
fn assignments_are_held_until_there_is_one() {
    let (owner, machine) = store();
    renew(&owner, &mac(), 1, true);
    owner.advance(LEASE_MS - 10_000);

    let woken = Arc::new(Woken::default());
    let waker = Waker::from(Arc::clone(&woken));
    let mut cx = Context::from_waker(&waker);
    let mut held = Box::pin(machine.assignments(25_000));
    assert!(held.as_mut().poll(&mut cx).is_pending());

    // The laptop's lease runs out: the takeover answers the held request.
    owner.advance(10_000);
    assert!(woken.times() >= 1);
    let Poll::Ready(Ok(assignments)) = held.as_mut().poll(&mut cx) else {
        panic!("there is an assignment, so the request answers");
    };
    let kinds: Vec<AssignmentKind> = assignments.iter().map(|a| a.kind).collect();
    assert_eq!(kinds, [AssignmentKind::Takeover]);

    // With nothing to do, the request answers empty at its deadline.
    ready(machine.ack_assignment(CHAT, &Fence::new(vm(), 2))).expect("acked");
    let mut held = Box::pin(machine.assignments(5_000));
    assert!(held.as_mut().poll(&mut cx).is_pending());
    owner.advance(5_000);
    assert_eq!(held.as_mut().poll(&mut cx), Poll::Ready(Ok(Vec::new())));
}

#[test]
fn an_offline_caller_gets_no_answer() {
    let (owner, machine) = store();
    let version = chat(&owner).version;
    let mut cx = Context::from_waker(Waker::noop());
    let mut held = Box::pin(owner.wait(CHAT, version, 25_000));
    assert!(held.as_mut().poll(&mut cx).is_pending());

    owner.set_offline(true);
    let error = ready(owner.get(CHAT)).expect_err("offline");
    assert!(error.is_transport() && error.retryable());
    let lease = LeaseRequest { holder: mac(), epoch: 1, needs_run: true, standby: None };
    assert!(ready(owner.lease(CHAT, &lease)).expect_err("offline").is_transport());
    // A held request ends too.
    let Poll::Ready(Err(dropped)) = held.as_mut().poll(&mut cx) else {
        panic!("the network went, so the wait fails");
    };
    assert!(dropped.is_transport());

    // Another caller has its own network, and the store never saw the laptop's calls.
    assert!(ready(machine.get(CHAT)).is_ok());
    assert_eq!(owner.calls(), ["set_machine", "put", "wait", "get"]);

    // The store goes on without the laptop: its lease runs out.
    owner.advance(LEASE_MS);
    owner.set_offline(false);
    let answer = renew(&owner, &mac(), 1, false);
    assert_eq!((answer.session.holder.clone(), answer.session.epoch), (mac(), 3));
}
