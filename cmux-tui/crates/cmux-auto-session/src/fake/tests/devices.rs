//! A laptop's holder is its install's (security review of cmux#52931, item 1): another install
//! of the owner cannot write as `device:<id>` once a first one named it in the chat, and an
//! install that never holds a chat (a phone, a browser session) makes no holder write.

use super::*;
use crate::cloud::AutoCloudError;
use crate::wire::{InboxAck, InboxPost};

/// The status and the code (as the store wrote it) of a refused call.
fn refused<T: Debug>(result: CloudResult<T>) -> (u16, String) {
    match result.expect_err("refused") {
        AutoCloudError::Http { status, raw_code, .. } => (status, raw_code),
        other => panic!("no answer: {other}"),
    }
}

fn wrong() -> (u16, String) {
    (403, "auto.wrong_device".to_owned())
}

fn no_laptop() -> (u16, String) {
    (403, "auto.not_a_laptop".to_owned())
}

#[test]
fn today_s_laptop_does_every_holder_write_as_its_own_device() {
    let (owner, _) = store();
    assert_eq!(renew(&owner, &mac(), 1, true).epoch, 1);
    assert_eq!(append_as(&owner, &mac(), 1, 1..=1), Ok(1));
    assert!(snapshot_as(&owner, &mac(), 1, b"folder", 1).is_ok());
    let ack = InboxAck { holder: mac(), epoch: 1, through: 0 };
    assert!(ready(owner.ack_inbox(CHAT, &ack)).is_ok());
    assert!(ready(owner.release(CHAT, &Fence::new(mac(), 1))).is_ok());
    // A second handle of the same install (the daemon's other connection) is the same laptop.
    assert!(ready(owner.as_owner().put(CHAT, &put_request("mac"))).is_ok());
}

#[test]
fn another_install_cannot_write_as_a_laptop_it_is_not() {
    let (owner, _) = store();
    let other = owner.as_install("install_2");
    let lease = LeaseRequest { holder: mac(), epoch: 1, needs_run: false, standby: None };
    assert_eq!(refused(ready(other.lease(CHAT, &lease))), wrong());
    assert_eq!(refused(append_as(&other, &mac(), 1, 1..=1)), wrong());
    assert_eq!(refused(snapshot_as(&other, &mac(), 1, b"x", 0)), wrong());
    let ack = InboxAck { holder: mac(), epoch: 1, through: 0 };
    assert_eq!(refused(ready(other.ack_inbox(CHAT, &ack))), wrong());
    assert_eq!(refused(ready(other.release(CHAT, &Fence::new(mac(), 1)))), wrong());
    assert_eq!(refused(ready(other.put(CHAT, &put_request("mac")))), wrong());
    assert_eq!((chat(&owner).holder, chat(&owner).epoch, chat(&owner).last_seq), (mac(), 1, 0));
    // As its own device it stands by, and the first laptop goes on.
    assert_eq!(stand_by(&other, &Holder::device("mac2"), 1).role, crate::wire::Role::Standby);
    assert_eq!(renew(&owner, &mac(), 1, false).role, crate::wire::Role::Holder);
}

#[test]
fn a_phone_reads_and_sends_but_holds_nothing() {
    let (owner, _) = store();
    let phone = owner.as_phone();
    let lease = LeaseRequest { holder: mac(), epoch: 1, needs_run: false, standby: None };
    assert_eq!(refused(ready(phone.lease(CHAT, &lease))), no_laptop());
    let standby = LeaseRequest {
        holder: Holder::device("phone"),
        epoch: 1,
        needs_run: false,
        standby: Some(true),
    };
    assert_eq!(refused(ready(phone.lease(CHAT, &standby))), no_laptop());
    assert_eq!(refused(append_as(&phone, &mac(), 1, 1..=1)), no_laptop());
    assert_eq!(refused(snapshot_as(&phone, &mac(), 1, b"x", 0)), no_laptop());
    let ack = InboxAck { holder: mac(), epoch: 1, through: 0 };
    assert_eq!(refused(ready(phone.ack_inbox(CHAT, &ack))), no_laptop());
    assert_eq!(refused(ready(phone.release(CHAT, &Fence::new(mac(), 1)))), no_laptop());
    assert_eq!(refused(ready(phone.put(CHAT, &put_request("phone")))), no_laptop());
    assert_eq!(refused(ready(phone.put("chat_2", &put_request("phone")))), no_laptop());
    // What a phone does: list, read, wait, send a message, keep the chat in the Cloud.
    assert!(ready(phone.list(None, None)).is_ok());
    assert_eq!(ready(phone.get(CHAT)).map(|session| session.holder), Ok(mac()));
    assert!(ready(phone.wait(CHAT, u64::MAX, 0)).is_ok());
    let message = InboxPost { id: "m1".into(), text: "hello".into() };
    assert!(ready(phone.post_inbox(CHAT, &message)).is_ok());
    assert!(ready(phone.keep(CHAT, false)).is_ok());
}
