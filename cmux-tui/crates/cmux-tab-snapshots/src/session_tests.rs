use super::*;
use crate::hash::Mime;
use crate::producer::{FaviconInput, ImageInput, Observation};
use crate::row::Kind;
use crate::wire::{Resume, kind};

fn browser(id: &str, title: &str, favicon: &[u8], thumb: &[u8]) -> Observation {
    Observation {
        tab_id: id.to_owned(),
        title: title.to_owned(),
        kind: Kind::Browser,
        favicon: Some(FaviconInput { mime: Mime::Png, bytes: favicon.to_vec() }),
        thumb: Some(ImageInput {
            mime: Mime::Jpeg,
            bytes: thumb.to_vec(),
            width: 516,
            height: 344,
        }),
        screen: None,
        frame: None,
        captured_at_ms: 1000,
    }
}

fn producer() -> Producer {
    let mut p = Producer::new("e1", 0, 16, 8);
    p.observe(browser("a", "A", b"fav", b"ta"));
    p.observe(browser("b", "B", b"fav", b"tb"));
    p
}

fn drain(s: &mut Session, p: &Producer) -> Vec<Message> {
    std::iter::from_fn(|| s.next_frame(p)).map(|f| Message::decode(&f).unwrap()).collect()
}

fn blob_hashes(msgs: &[Message]) -> Vec<BlobHash> {
    msgs.iter()
        .filter_map(|m| match m {
            Message::Blob(b) => Some(b.hash),
            _ => None,
        })
        .collect()
}

fn h(bytes: &[u8]) -> BlobHash {
    BlobHash::of(bytes)
}

#[test]
fn waits_for_the_phone_then_sends_the_manifest() {
    let p = producer();
    let mut s = Session::new();
    assert!(s.next_frame(&p).is_none());
    s.on_message(Message::Viewport(Viewport::default())).unwrap();
    let out = drain(&mut s, &p);
    assert!(matches!(&out[..], [Message::Manifest(m)] if m.rev == 2 && m.rows.len() == 2));
    assert!(s.viewport().is_some());
}

#[test]
fn sends_wanted_blobs_in_order_once_and_skips_have() {
    let p = producer();
    let mut s = Session::new();
    s.on_message(Message::Have(vec![h(b"fav")])).unwrap();
    drain(&mut s, &p);
    s.on_message(Message::Want(vec![h(b"tb"), h(b"fav"), h(b"ta"), h(b"tb")])).unwrap();
    let out = drain(&mut s, &p);
    assert_eq!(blob_hashes(&out), vec![h(b"tb"), h(b"ta")]);
    s.on_message(Message::Want(vec![h(b"ta")])).unwrap();
    assert!(drain(&mut s, &p).is_empty());
    assert_eq!(s.stats().blobs, 2);
}

#[test]
fn a_new_want_replaces_the_queue() {
    let p = producer();
    let mut s = Session::new();
    s.open();
    drain(&mut s, &p);
    s.on_message(Message::Want(vec![h(b"ta"), h(b"tb"), h(b"fav")])).unwrap();
    let first = s.next_frame(&p).unwrap();
    assert_eq!(first.first(), Some(&kind::BLOB));
    s.on_message(Message::Want(vec![h(b"fav")])).unwrap();
    assert_eq!(blob_hashes(&drain(&mut s, &p)), vec![h(b"fav")]);
}

#[test]
fn a_want_for_a_gone_hash_is_skipped() {
    let p = producer();
    let mut s = Session::new();
    s.open();
    drain(&mut s, &p);
    s.on_message(Message::Want(vec![h(b"nope"), h(b"ta")])).unwrap();
    assert_eq!(blob_hashes(&drain(&mut s, &p)), vec![h(b"ta")]);
    assert_eq!(s.stats().skipped_gone, 1);
}

#[test]
fn changes_between_pulls_coalesce_into_one_delta_before_blobs() {
    let mut p = producer();
    let mut s = Session::new();
    s.open();
    drain(&mut s, &p);
    s.on_message(Message::Want(vec![h(b"ta")])).unwrap();
    p.observe(browser("a", "A2", b"fav", b"ta"));
    p.observe(browser("b", "B2", b"fav", b"tb"));
    p.remove("b");
    let out = drain(&mut s, &p);
    let [Message::Delta(d), Message::Blob(_)] = &out[..] else { panic!("{out:?}") };
    assert_eq!((d.base_rev, d.rev), (2, 5));
    assert_eq!(d.changed.len(), 1);
    assert_eq!(d.removed, vec!["b".to_owned()]);
    assert!(drain(&mut s, &p).is_empty());
}

#[test]
fn resume_gets_a_delta_or_a_manifest() {
    let mut p = producer();
    p.observe(browser("a", "A2", b"fav", b"ta"));
    let mut s = Session::new();
    s.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 2 })).unwrap();
    let out = drain(&mut s, &p);
    assert!(matches!(&out[..], [Message::Delta(d)] if d.base_rev == 2 && d.rev == 3));

    let mut same = Session::new();
    same.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 3 })).unwrap();
    let out = drain(&mut same, &p);
    assert!(matches!(&out[..], [Message::Delta(d)] if d.changed.is_empty() && d.rev == 3));

    let mut unknown = Session::new();
    unknown.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 99 })).unwrap();
    assert!(matches!(&drain(&mut unknown, &p)[..], [Message::Manifest(_)]));
}

#[test]
fn mac_to_phone_frames_are_refused() {
    let p = producer();
    let mut s = Session::new();
    let manifest = Message::Manifest(p.manifest()).encode();
    assert_eq!(s.on_frame(&manifest), Err(SessionError::WrongDirection(kind::MANIFEST)));
    assert!(matches!(s.on_frame(&[0xee]), Err(SessionError::Wire(WireError::UnknownKind(0xee)))));
    assert!(s.next_frame(&p).is_none());
}

#[test]
fn push_before_want_queues_missing_blobs_favicons_first() {
    let mut p = producer();
    let mut s = Session::push_before_want();
    s.on_message(Message::Have(vec![h(b"ta")])).unwrap();
    assert!(s.next_frame(&p).is_none(), "have alone does not open the session");
    s.on_message(Message::Viewport(Viewport::default())).unwrap();
    let out = drain(&mut s, &p);
    assert!(matches!(out.first(), Some(Message::Manifest(_))));
    assert_eq!(blob_hashes(&out), vec![h(b"fav"), h(b"tb")]);
    p.observe(browser("a", "A", b"fav", b"ta2"));
    let out = drain(&mut s, &p);
    assert!(matches!(out.first(), Some(Message::Delta(_))));
    assert_eq!(blob_hashes(&out), vec![h(b"ta2")]);
    // A want still replaces what the session queued.
    p.observe(browser("b", "B", b"fav2", b"tb2"));
    let first = s.next_frame(&p).unwrap();
    assert_eq!(first.first(), Some(&kind::DELTA));
    s.on_message(Message::Want(vec![h(b"tb2")])).unwrap();
    assert_eq!(blob_hashes(&drain(&mut s, &p)), vec![h(b"tb2")]);
}

#[test]
fn a_resume_from_another_or_no_epoch_gets_a_manifest() {
    let p = producer();
    let mut other = Session::new();
    other.on_message(Message::Resume(Resume { epoch: "old-run".into(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut other, &p)[..], [Message::Manifest(m)] if m.epoch == "e1"));

    let mut none = Session::new();
    none.on_message(Message::Resume(Resume { epoch: String::new(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut none, &p)[..], [Message::Manifest(_)]));

    let mut same = Session::new();
    same.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut same, &p)[..], [Message::Delta(d)] if d.epoch == "e1"));
}
