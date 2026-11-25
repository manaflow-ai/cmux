use super::*;
use crate::hash::Mime;
use crate::row::{Kind, RowPatch};
use crate::wire::{BlobFrame, encode_blob};

fn row(id: &str, favicon: &[u8], thumb: &[u8]) -> Row {
    Row {
        tab_id: id.to_owned(),
        title: id.to_uppercase(),
        kind: Kind::Browser,
        favicon_hash: Some(BlobHash::of(favicon)),
        thumb_hash: Some(BlobHash::of(thumb)),
        thumb_mime: Mime::Jpeg,
        ..Row::default()
    }
}

fn manifest(rev: u64, rows: Vec<Row>) -> Message {
    Message::Manifest(Manifest { epoch: "e1".into(), rev, rows })
}

#[test]
fn missing_lists_favicons_first_once_each() {
    let mut m = Mirror::new();
    m.apply(manifest(
        1,
        vec![row("a", b"f1", b"ta"), row("b", b"f1", b"tb"), row("c", b"f2", b"tc")],
    ))
    .unwrap();
    let h = BlobHash::of;
    assert_eq!(m.missing(), vec![h(b"f1"), h(b"f2"), h(b"ta"), h(b"tb"), h(b"tc")]);
    m.apply_frame(&encode_blob(h(b"f1"), Mime::Png, b"f1")).unwrap();
    m.apply_frame(&encode_blob(h(b"ta"), Mime::Jpeg, b"ta")).unwrap();
    assert!(m.card_filled(0));
    assert!(!m.card_filled(1));
    assert!(!m.card_filled(9));
    assert_eq!(m.missing(), vec![h(b"f2"), h(b"tb"), h(b"tc")]);
}

#[test]
fn a_blob_with_the_wrong_hash_is_rejected() {
    let mut m = Mirror::new();
    let claimed = BlobHash::of(b"real");
    let err = m.apply(Message::Blob(BlobFrame {
        hash: claimed,
        mime: Mime::Png,
        bytes: b"fake".to_vec(),
    }));
    assert_eq!(err, Err(MirrorError::HashMismatch { claimed, actual: BlobHash::of(b"fake") }));
    assert!(!m.holds(&claimed));
}

#[test]
fn delta_applies_on_its_base_and_reports_a_gap_otherwise() {
    let mut m = Mirror::new();
    m.apply(manifest(5, vec![row("a", b"f", b"t"), row("b", b"f", b"t2")])).unwrap();
    let mut patch =
        RowPatch { tab_id: "a".into(), title: Some("New".into()), ..RowPatch::default() };
    patch.thumb_hash = Some(None);
    let delta = Delta {
        epoch: "e1".into(),
        rev: 7,
        base_rev: 5,
        changed: vec![patch, RowPatch::full(&row("c", b"f", b"t3"))],
        removed: vec!["b".into()],
        order: None,
    };
    assert_eq!(m.apply(Message::Delta(delta.clone())).unwrap(), Applied::Delta { rev: 7 });
    let ids: Vec<_> = m.rows().iter().map(|r| r.tab_id.as_str()).collect();
    assert_eq!(ids, vec!["a", "c"]);
    assert_eq!(m.rows()[0].title, "New");
    assert_eq!(m.rows()[0].thumb_hash, None);
    assert_eq!(m.rows()[1].title, "C");
    assert_eq!(
        m.apply(Message::Delta(delta)).unwrap(),
        Applied::Gap { mirror_rev: Some(7), base_rev: 5 }
    );
    assert_eq!(m.rev(), Some(7));
}

#[test]
fn held_set_exports_and_imports() {
    let mut m = Mirror::new();
    m.apply_frame(&encode_blob(BlobHash::of(b"x"), Mime::Png, b"x")).unwrap();
    let saved = m.export_held();
    let mut next = Mirror::new();
    next.import_held(saved.clone());
    assert!(next.holds(&BlobHash::of(b"x")));
    assert_eq!(next.link_up_frames(), vec![Message::Have(saved).encode()]);
    assert_eq!(Mirror::new().link_up_frames(), Vec::<Vec<u8>>::new());
    next.apply(manifest(3, vec![])).unwrap();
    let frames = next.link_up_frames();
    assert_eq!(frames.len(), 2);
    assert_eq!(frames[0][0], crate::wire::kind::HAVE);
    assert_eq!(
        Message::decode(&frames[1]).unwrap(),
        Message::Resume(Resume { epoch: "e1".into(), rev: 3 })
    );
}

#[test]
fn phone_to_mac_frames_are_refused() {
    let mut m = Mirror::new();
    let frame = Message::Want(vec![]).encode();
    assert_eq!(m.apply_frame(&frame), Err(MirrorError::WrongDirection(frame[0])));
}

#[test]
fn another_epoch_is_a_gap_for_a_delta_and_a_replacement_for_a_manifest() {
    let mut m = Mirror::new();
    m.apply(manifest(5, vec![row("a", b"f", b"t")])).unwrap();
    let foreign = Delta { epoch: "e2".into(), rev: 6, base_rev: 5, ..Delta::default() };
    assert_eq!(
        m.apply(Message::Delta(foreign)).unwrap(),
        Applied::Gap { mirror_rev: Some(5), base_rev: 5 }
    );
    assert_eq!((m.epoch(), m.rev()), ("e1", Some(5)));
    let resume = Message::decode(&m.resume_frame().unwrap()).unwrap();
    assert_eq!(resume, Message::Resume(Resume { epoch: "e1".into(), rev: 5 }));
    let replaced = Manifest { epoch: "e2".into(), rev: 2, rows: vec![row("b", b"f", b"t")] };
    assert_eq!(m.apply(Message::Manifest(replaced)).unwrap(), Applied::Manifest { rev: 2 });
    assert_eq!((m.epoch(), m.rev()), ("e2", Some(2)));
    assert_eq!(m.rows()[0].tab_id, "b");
}

#[test]
fn order_applies_after_changes_and_keeps_unlisted_tabs_after() {
    let mut m = Mirror::new();
    let rows = ["a", "b", "c", "d"].map(|id| row(id, b"f", id.as_bytes()));
    m.apply(manifest(1, rows.to_vec())).unwrap();
    let delta = Delta {
        epoch: "e1".into(),
        rev: 2,
        base_rev: 1,
        changed: vec![RowPatch::full(&row("e", b"f", b"e"))],
        removed: vec!["b".into()],
        // "zz" is unknown and ignored; "a" and "e" are not listed.
        order: Some(vec!["d".into(), "zz".into(), "c".into()]),
    };
    m.apply(Message::Delta(delta)).unwrap();
    let ids: Vec<_> = m.rows().iter().map(|r| r.tab_id.as_str()).collect();
    assert_eq!(ids, vec!["d", "c", "a", "e"]);
}
