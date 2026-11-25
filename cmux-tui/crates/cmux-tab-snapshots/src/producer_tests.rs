use super::*;
use crate::hash::BlobHash;

pub(crate) fn browser(id: &str, title: &str, favicon: &[u8], thumb: &[u8]) -> Observation {
    Observation {
        tab_id: id.to_owned(),
        tab_key: String::new(),
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

#[test]
fn same_content_is_no_new_rev() {
    let mut p = Producer::new("e1", 100, 8, 4);
    assert!(p.observe(browser("a", "A", b"fav", b"thumb")));
    assert_eq!(p.rev(), 101);
    let mut again = browser("a", "A", b"fav", b"thumb");
    again.captured_at_ms = 2000;
    assert!(!p.observe(again));
    assert_eq!(p.rev(), 101);
    assert_eq!(p.rows()[0].captured_at_ms, 1000);
    assert_eq!(p.store().stats().dedupe_hits, 0);
    assert_eq!(p.delta_since(101).unwrap().changed, vec![]);
}

#[test]
fn a_change_carries_only_changed_fields() {
    let mut p = Producer::new("e1", 0, 8, 4);
    p.observe(browser("a", "A", b"fav", b"thumb"));
    p.observe(browser("a", "A", b"fav", b"thumb2"));
    let d = p.delta_since(1).unwrap();
    assert_eq!((d.rev, d.base_rev), (2, 1));
    let patch = &d.changed[0];
    assert_eq!(patch.thumb_hash, Some(Some(BlobHash::of(b"thumb2"))));
    assert_eq!(patch.title, None);
    assert_eq!(patch.favicon_hash, None);
    assert_eq!(patch.captured_at_ms, None);
}

#[test]
fn shared_favicon_is_stored_once() {
    let mut p = Producer::new("e1", 0, 8, 0);
    p.observe(browser("a", "A", b"fav", b"t1"));
    p.observe(browser("b", "B", b"fav", b"t2"));
    let stats = p.store().stats();
    assert_eq!(stats.blobs, 3);
    assert_eq!(stats.dedupe_hits, 1);
    p.remove("a");
    assert!(p.store().contains(&BlobHash::of(b"fav")));
    assert!(!p.store().contains(&BlobHash::of(b"t1")));
}

#[test]
fn flipping_back_keeps_the_old_blob() {
    let mut p = Producer::new("e1", 0, 8, 2);
    p.observe(browser("a", "A", b"fav", b"one"));
    p.observe(browser("a", "A", b"fav", b"two"));
    assert!(p.store().contains(&BlobHash::of(b"one")));
    p.observe(browser("a", "A", b"fav", b"one"));
    assert_eq!(p.store().stats().dedupe_hits, 1);
}

#[test]
fn delta_since_merges_and_handles_removal() {
    let mut p = Producer::new("e1", 0, 16, 4);
    p.observe(browser("a", "A", b"f", b"1"));
    p.observe(browser("b", "B", b"f", b"2"));
    let base = p.rev();
    p.observe(browser("a", "A2", b"f", b"1"));
    p.observe(browser("a", "A3", b"f", b"3"));
    p.remove("b");
    p.observe(browser("c", "C", b"f", b"4"));
    p.remove("c");
    p.observe(browser("c", "C2", b"f", b"5"));
    let d = p.delta_since(base).unwrap();
    assert_eq!(d.removed, vec!["b".to_owned()]);
    assert_eq!(d.changed.len(), 2);
    assert_eq!(d.changed[0].tab_id, "a");
    assert_eq!(d.changed[0].title.as_deref(), Some("A3"));
    assert_eq!(d.changed[0].thumb_hash, Some(Some(BlobHash::of(b"3"))));
    assert_eq!(d.changed[1].tab_id, "c");
    assert_eq!(d.changed[1].title.as_deref(), Some("C2"));
}

#[test]
fn resume_is_bounded_by_history() {
    let mut p = Producer::new("e1", 50, 2, 4);
    for i in 0..5u8 {
        p.observe(browser("a", &format!("T{i}"), b"f", &[i]));
    }
    assert_eq!(p.rev(), 55);
    assert!(p.delta_since(52).is_none());
    assert!(p.delta_since(53).is_some());
    assert!(p.delta_since(56).is_none());
    assert!(p.delta_since(10).is_none());
    let mut none = Producer::new("e1", 0, 0, 0);
    none.observe(browser("a", "A", b"f", b"t"));
    assert!(none.delta_since(0).is_none());
    assert!(none.delta_since(1).is_some());
}

#[test]
fn removing_an_unknown_tab_changes_nothing() {
    let mut p = Producer::new("e1", 0, 4, 4);
    assert!(!p.remove("nope"));
    assert_eq!(p.rev(), 0);
}

#[test]
fn set_order_bumps_rev_only_on_change_and_rides_in_the_delta() {
    let mut p = Producer::new("e1", 0, 16, 4);
    for id in ["a", "b", "c"] {
        p.observe(browser(id, id, b"f", id.as_bytes()));
    }
    let base = p.rev();
    assert!(!p.set_order(&["a", "b", "c"]));
    assert!(!p.set_order(&["a"]));
    assert_eq!(p.rev(), base);
    assert_eq!(p.delta_since(base).unwrap().order, None);
    assert!(p.set_order(&["c", "nope", "a"]));
    assert_eq!(p.rev(), base + 1);
    let ids: Vec<_> = p.rows().iter().map(|r| r.tab_id.as_str()).collect();
    assert_eq!(ids, vec!["c", "a", "b"]);
    // A later append shows in the order the delta carries.
    p.observe(browser("d", "d", b"f", b"d"));
    let d = p.delta_since(base).unwrap();
    assert_eq!(d.order, Some(vec!["c".into(), "a".into(), "b".into(), "d".into()]));
    // A delta from after the reorder carries no order.
    assert_eq!(p.delta_since(base + 1).unwrap().order, None);
}

#[test]
fn a_new_epoch_drops_every_row_and_every_delta_before_it() {
    let mut p = Producer::new("e1", 0, 16, 0);
    p.observe(browser("7", "Old", b"fav", b"thumb"));
    p.observe(browser("8", "Old 2", b"fav", b"thumb2"));
    let old_rev = p.rev();
    p.new_epoch("e2");
    assert_eq!(p.epoch(), "e2");
    assert!(p.rows().is_empty());
    assert_eq!(p.store().stats().blobs, 0, "the old rows' blobs are released");
    assert!(p.rev() > old_rev, "no rev of the old epoch is one of the new");
    assert!(p.delta_since(old_rev).is_none());
    assert!(p.delta_since(0).is_none());
    let m = p.manifest();
    assert_eq!((m.epoch.as_str(), m.rows.len()), ("e2", 0));
    // The same id in the new run is a new tab, not a change of the old one.
    assert!(p.observe(browser("7", "New", b"fav", b"other")));
    let d = p.delta_since(old_rev + 1).unwrap();
    assert_eq!(d.epoch, "e2");
    assert_eq!(d.changed.len(), 1);
    assert_eq!(d.changed[0].title.as_deref(), Some("New"));
}
