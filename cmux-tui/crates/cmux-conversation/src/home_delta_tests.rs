use super::*;
use crate::HomeKind;

fn row(id: &str, unread: u64) -> HomeRow {
    HomeRow {
        id: id.to_owned(),
        owner: "local",
        kind: HomeKind::Direct,
        name: id.to_owned(),
        unread,
        activity_at: "2026-11-20T00:00:00.000Z".into(),
        preview: None,
        last_author: None,
        chief: None,
        chief_state: None,
        pinned: false,
        pin_position: None,
        marked_unread: false,
        muted: false,
    }
}

fn rows(count: usize) -> Vec<HomeRow> {
    (0..count).map(|index| row(&format!("conv_{index}"), 0)).collect()
}

#[test]
fn since_zero_and_unknown_revisions_are_full() {
    let mut log = HomeChangeLog::new(1000);
    log.observe(&rows(3));
    assert_eq!(log.since(0), HomeDelta::Full);
    assert_eq!(log.since(log.revision() + 1), HomeDelta::Full, "a later run's revision");
    assert_eq!(log.since(5), HomeDelta::Full, "an earlier run's revision");
}

#[test]
fn unchanged_rows_record_nothing() {
    let mut log = HomeChangeLog::new(1000);
    let list = rows(10);
    log.observe(&list);
    let revision = log.revision();
    log.observe(&list);
    assert_eq!(log.revision(), revision);
    assert_eq!(log.since(revision), HomeDelta::Since { changed: vec![], removed: vec![] });
}

#[test]
fn one_change_is_one_row() {
    let mut log = HomeChangeLog::new(1000);
    let mut list = rows(10);
    log.observe(&list);
    let revision = log.revision();
    list[4].unread = 3;
    log.observe(&list);
    assert_eq!(log.revision(), revision + 1);
    assert_eq!(
        log.since(revision),
        HomeDelta::Since { changed: vec!["conv_4".into()], removed: vec![] }
    );
}

#[test]
fn removal_is_named() {
    let mut log = HomeChangeLog::new(1000);
    let mut list = rows(5);
    log.observe(&list);
    let revision = log.revision();
    list.remove(2);
    log.observe(&list);
    assert_eq!(
        log.since(revision),
        HomeDelta::Since { changed: vec![], removed: vec!["conv_2".into()] }
    );
    // A row that changed and then left is only removed.
    let revision = log.revision();
    list[0].unread = 9;
    log.observe(&list);
    list.remove(0);
    log.observe(&list);
    assert_eq!(
        log.since(revision),
        HomeDelta::Since { changed: vec![], removed: vec!["conv_0".into()] }
    );
}

#[test]
fn gap_past_the_ring_is_full() {
    let mut log = HomeChangeLog::with_capacity(1000, 4);
    let mut list = rows(10);
    log.observe(&list);
    let revision = log.revision();
    for (index, item) in list.iter_mut().enumerate().take(5) {
        item.unread = index as u64 + 1;
    }
    log.observe(&list);
    assert_eq!(log.since(revision), HomeDelta::Full, "5 changes, ring of 4");
    assert!(matches!(log.since(revision + 1), HomeDelta::Since { .. }), "4 back is covered");
}

/// One change in a 5,000-row list: the delta names one row and the read
/// walks one ring entry, whatever the list's length.
#[test]
fn one_change_at_5000_rows_reads_one_row() {
    let mut log = HomeChangeLog::new(1000);
    let mut list = rows(5_000);
    log.observe(&list);
    let revision = log.revision();
    list[4_321].unread = 1;
    log.observe(&list);
    assert_eq!(log.revision() - revision, 1, "one O(1) record");
    let HomeDelta::Since { changed, removed } = log.since(revision) else {
        panic!("covered gap");
    };
    assert_eq!(changed, vec!["conv_4321".to_owned()]);
    assert!(removed.is_empty());
}
