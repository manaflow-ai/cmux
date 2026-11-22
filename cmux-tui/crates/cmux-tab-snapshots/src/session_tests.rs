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
    let mut s = Session::without_push();
    assert!(s.next_frame(&p).is_none());
    s.on_message(Message::Viewport(Viewport::default())).unwrap();
    let out = drain(&mut s, &p);
    assert!(matches!(&out[..], [Message::Manifest(m)] if m.rev == 2 && m.rows.len() == 2));
    assert!(s.viewport().is_some());
}

#[test]
fn a_want_sends_each_named_hash_once_in_order_even_if_held_or_sent() {
    let p = producer();
    let mut s = Session::without_push();
    s.on_message(Message::Have(vec![h(b"fav")])).unwrap();
    drain(&mut s, &p);
    s.on_message(Message::Want(vec![h(b"tb"), h(b"fav"), h(b"ta"), h(b"tb")])).unwrap();
    let out = drain(&mut s, &p);
    // `fav` is in `have`, but a want names it: the phone evicted it.
    assert_eq!(blob_hashes(&out), vec![h(b"tb"), h(b"fav"), h(b"ta")]);
    assert!(drain(&mut s, &p).is_empty());
    // A later want for a hash already sent sends it again, once.
    s.on_message(Message::Want(vec![h(b"ta"), h(b"ta")])).unwrap();
    assert_eq!(blob_hashes(&drain(&mut s, &p)), vec![h(b"ta")]);
    assert_eq!(s.stats().blobs, 4);
    assert_eq!(s.stats().resent, 1);
}

#[test]
fn a_new_want_replaces_the_queue() {
    let p = producer();
    let mut s = Session::without_push();
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
    let mut s = Session::without_push();
    s.open();
    drain(&mut s, &p);
    s.on_message(Message::Want(vec![h(b"nope"), h(b"ta")])).unwrap();
    assert_eq!(blob_hashes(&drain(&mut s, &p)), vec![h(b"ta")]);
    assert_eq!(s.stats().skipped_gone, 1);
}

#[test]
fn changes_between_pulls_coalesce_into_one_delta_before_blobs() {
    let mut p = producer();
    let mut s = Session::without_push();
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
    let mut s = Session::without_push();
    s.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 2 })).unwrap();
    let out = drain(&mut s, &p);
    assert!(matches!(&out[..], [Message::Delta(d)] if d.base_rev == 2 && d.rev == 3));

    let mut same = Session::without_push();
    same.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 3 })).unwrap();
    let out = drain(&mut same, &p);
    assert!(matches!(&out[..], [Message::Delta(d)] if d.changed.is_empty() && d.rev == 3));

    let mut unknown = Session::without_push();
    unknown.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 99 })).unwrap();
    assert!(matches!(&drain(&mut unknown, &p)[..], [Message::Manifest(_)]));
}

#[test]
fn mac_to_phone_frames_are_refused() {
    let p = producer();
    let mut s = Session::without_push();
    let manifest = Message::Manifest(p.manifest()).encode();
    assert_eq!(s.on_frame(&manifest), Err(SessionError::WrongDirection(kind::MANIFEST)));
    assert!(matches!(s.on_frame(&[0xee]), Err(SessionError::Wire(WireError::UnknownKind(0xee)))));
    assert!(s.next_frame(&p).is_none());
}

fn terminal(id: &str, text: &str) -> Observation {
    Observation {
        tab_id: id.to_owned(),
        title: id.to_owned(),
        kind: Kind::Terminal,
        favicon: None,
        thumb: None,
        screen: Some(crate::producer::ScreenInput { text: text.to_owned(), cols: 80, rows: 24 }),
        frame: Some(ImageInput { mime: Mime::Png, bytes: b"frame".to_vec(), width: 1, height: 1 }),
        captured_at_ms: 1000,
    }
}

#[test]
fn push_is_the_default_in_row_order_and_skips_have() {
    let mut p = producer();
    p.observe(terminal("t", "$ ls"));
    let mut s = Session::new();
    s.on_message(Message::Have(vec![h(b"ta")])).unwrap();
    assert!(s.next_frame(&p).is_none(), "have alone does not open the session");
    s.on_message(Message::Viewport(Viewport::default())).unwrap();
    let out = drain(&mut s, &p);
    assert!(matches!(out.first(), Some(Message::Manifest(_))));
    // Per row: favicon, then thumbnail or screen. `ta` is held, the shared
    // favicon goes once, and the terminal's full frame is not pushed.
    assert_eq!(blob_hashes(&out), vec![h(b"fav"), h(b"tb"), h(b"$ ls")]);
    assert!(!blob_hashes(&out).contains(&h(b"frame")));
    // A change pushes only the new blob.
    p.observe(browser("a", "A", b"fav", b"ta2"));
    let out = drain(&mut s, &p);
    assert!(matches!(out.first(), Some(Message::Delta(_))));
    assert_eq!(blob_hashes(&out), vec![h(b"ta2")]);
    // The full frame goes only on want.
    s.on_message(Message::Want(vec![h(b"frame")])).unwrap();
    assert_eq!(blob_hashes(&drain(&mut s, &p)), vec![h(b"frame")]);
}

#[test]
fn a_want_moves_its_hashes_ahead_of_the_push_and_none_goes_twice() {
    let mut p = Producer::new("e1", 0, 16, 8);
    for id in ["a", "b", "c", "d"] {
        p.observe(browser(id, id, format!("f{id}").as_bytes(), format!("t{id}").as_bytes()));
    }
    let mut s = Session::new();
    s.open();
    let first: Vec<Message> = std::iter::from_fn(|| s.next_frame(&p))
        .take(2)
        .map(|f| Message::decode(&f).unwrap())
        .collect();
    assert!(matches!(first[0], Message::Manifest(_)));
    assert_eq!(blob_hashes(&first), vec![h(b"fa")]);
    // The phone scrolled to d: want its blobs first.
    s.on_message(Message::Want(vec![h(b"td"), h(b"fd")])).unwrap();
    let rest = drain(&mut s, &p);
    let sent = blob_hashes(&rest);
    assert_eq!(&sent[..2], &[h(b"td"), h(b"fd")]);
    assert_eq!(&sent[2..], &[h(b"ta"), h(b"fb"), h(b"tb"), h(b"fc"), h(b"tc")]);
    assert_eq!(s.stats().resent, 0);
}

#[test]
fn without_push_nothing_moves_before_want() {
    let p = producer();
    let mut s = Session::without_push();
    s.open();
    assert!(matches!(&drain(&mut s, &p)[..], [Message::Manifest(_)]));
}

#[test]
fn a_resume_from_another_or_no_epoch_gets_a_manifest() {
    let p = producer();
    let mut other = Session::without_push();
    other.on_message(Message::Resume(Resume { epoch: "old-run".into(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut other, &p)[..], [Message::Manifest(m)] if m.epoch == "e1"));

    let mut none = Session::without_push();
    none.on_message(Message::Resume(Resume { epoch: String::new(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut none, &p)[..], [Message::Manifest(_)]));

    let mut same = Session::without_push();
    same.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut same, &p)[..], [Message::Delta(d)] if d.epoch == "e1"));
}

#[test]
fn a_new_epoch_sends_a_manifest_to_an_open_and_a_resuming_phone() {
    let mut p = producer();
    let mut open = Session::without_push();
    open.on_message(Message::Viewport(Viewport::default())).unwrap();
    assert!(matches!(&drain(&mut open, &p)[..], [Message::Manifest(m)] if m.epoch == "e1"));
    let old_rev = p.rev();

    p.new_epoch("e2");
    p.observe(browser("a", "New A", b"fav", b"new"));
    let out = drain(&mut open, &p);
    assert!(
        matches!(&out[..], [Message::Manifest(m)] if m.epoch == "e2" && m.rows.len() == 1 && m.rows[0].title == "New A"),
        "{out:?}"
    );

    let mut back = Session::without_push();
    back.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: old_rev })).unwrap();
    let out = drain(&mut back, &p);
    assert!(
        matches!(&out[..], [Message::Manifest(m)] if m.epoch == "e2" && m.rows.len() == 1),
        "{out:?}"
    );
}

fn only(id: &'static str) -> RowFilter {
    RowFilter::new(move |tab| tab == id)
}

#[test]
fn a_filter_hides_rows_and_their_blobs_from_manifest_delta_and_want() {
    let mut p = Producer::new("e1", 0, 16, 8);
    p.observe(browser("a", "A", b"fa", b"ta"));
    p.observe(browser("b", "B", b"fb", b"tb"));
    let mut s = Session::new();
    s.set_row_filter(Some(only("a")));
    s.on_message(Message::Want(vec![h(b"tb")])).unwrap();
    let out = drain(&mut s, &p);
    let Message::Manifest(m) = &out[0] else { panic!("{out:?}") };
    assert_eq!(m.rows.iter().map(|r| r.tab_id.as_str()).collect::<Vec<_>>(), ["a"]);
    assert_eq!(blob_hashes(&out), [h(b"fa"), h(b"ta")]);
    assert_eq!(s.stats().skipped_hidden, 1);

    p.observe(browser("b", "B2", b"fb", b"tb2"));
    p.observe(browser("a", "A2", b"fa", b"ta"));
    p.set_order(&["b", "a"]);
    let out = drain(&mut s, &p);
    let Message::Delta(d) = &out[0] else { panic!("{out:?}") };
    assert_eq!(d.changed.iter().map(|c| c.tab_id.as_str()).collect::<Vec<_>>(), ["a"]);
    assert_eq!(d.order.as_deref(), Some(&["a".to_owned()][..]));
    assert!(blob_hashes(&out).is_empty());

    // A closed tab is listed as removed even if hidden.
    p.remove("b");
    let out = drain(&mut s, &p);
    assert!(matches!(&out[..], [Message::Delta(d)] if d.removed == ["b"]));
}

#[test]
fn a_new_filter_sends_a_manifest_and_a_resume_under_a_hiding_filter_too() {
    let p = producer();
    let mut s = Session::without_push();
    s.on_message(Message::Viewport(Viewport::default())).unwrap();
    drain(&mut s, &p);
    s.set_row_filter(Some(only("b")));
    let out = drain(&mut s, &p);
    assert!(
        matches!(&out[..], [Message::Manifest(m)] if m.rows.len() == 1 && m.rows[0].tab_id == "b")
    );

    let mut s = Session::without_push();
    s.set_row_filter(Some(only("b")));
    s.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut s, &p)[..], [Message::Manifest(_)]));

    let mut s = Session::without_push();
    s.set_row_filter(Some(RowFilter::new(|_| true)));
    s.on_message(Message::Resume(Resume { epoch: "e1".into(), rev: 2 })).unwrap();
    assert!(matches!(&drain(&mut s, &p)[..], [Message::Delta(_)]));
}
