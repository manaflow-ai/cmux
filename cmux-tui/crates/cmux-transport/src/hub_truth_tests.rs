use super::*;
use crate::hub::{HUB_HEADER_LEN, HubHeader, HubTo, open, seal};

const SESSION: [u8; 16] = [0x5e; 16];

fn key() -> HubKey {
    HubKey::derive(&[7; 32], &SESSION)
}

fn frame(source: HubRole, epoch: u64, seq: u64) -> Vec<u8> {
    let header =
        HubHeader { session: SESSION, pos: HubPos::new(epoch, seq), source, to: HubTo::Viewers };
    seal(&key(), &header, format!("{epoch}:{seq}").as_bytes()).unwrap()
}

fn tracker() -> TruthTracker {
    TruthTracker::new(SESSION, TruthConfig::default())
}

fn delivered(events: &[TruthEvent]) -> Vec<HubPos> {
    events
        .iter()
        .filter_map(|e| match e {
            TruthEvent::Deliver { pos, .. } => Some(*pos),
            _ => None,
        })
        .collect()
}

#[test]
fn delivers_in_order_once_whichever_source_carried_it() {
    let mut t = tracker();
    let mut shown = Vec::new();
    for (source, seq) in [
        (HubRole::Mac, 1),
        (HubRole::Vm, 1),
        (HubRole::Vm, 2),
        (HubRole::Mac, 2),
        (HubRole::Mac, 3),
    ] {
        match t.on_payload(&key(), &frame(source, 1, seq)) {
            Ok(events) => shown.extend(delivered(&events)),
            Err(reject) => assert_eq!(reject, TruthReject::Duplicate),
        }
    }
    assert_eq!(shown, vec![HubPos::new(1, 1), HubPos::new(1, 2), HubPos::new(1, 3)]);
    assert_eq!(t.stats.duplicates, 2);
    assert_eq!(t.head(HubRole::Mac), Some(HubPos::new(1, 3)));
    assert_eq!(t.head(HubRole::Vm), Some(HubPos::new(1, 2)));
}

#[test]
fn a_header_that_disagrees_with_the_sealed_triple_is_rejected() {
    // A relay that edits the header breaks the seal; a source (or a bug) that
    // sealed a different triple than it labeled is caught by the comparison.
    let mut t = tracker();
    let payload = frame(HubRole::Mac, 1, 7);
    let mut opened = open(&key(), &payload).unwrap();
    opened.header.pos = HubPos::new(1, 8);
    assert_eq!(t.on_opened(opened.clone()), Err(TruthReject::HeaderMismatch));
    opened.header.pos = HubPos::new(1, 7);
    opened.header.source = HubRole::Vm;
    assert_eq!(t.on_opened(opened), Err(TruthReject::HeaderMismatch));
    assert_eq!(t.stats.mismatches, 2);
    assert_eq!(t.delivered(), None);
    // Edited on the wire: the seal itself fails.
    let mut edited = payload;
    edited[HUB_HEADER_LEN - 3] ^= 1;
    assert!(matches!(t.on_payload(&key(), &edited), Err(TruthReject::Open(_))));
}

#[test]
fn another_sessions_frame_is_refused() {
    let mut t = TruthTracker::new([1; 16], TruthConfig::default());
    assert_eq!(t.on_payload(&key(), &frame(HubRole::Mac, 1, 1)), Err(TruthReject::WrongSession));
}

#[test]
fn a_jump_inside_an_epoch_asks_the_source_that_is_ahead() {
    let mut t = tracker();
    t.on_payload(&key(), &frame(HubRole::Mac, 1, 1)).unwrap();
    t.report_head(HubRole::Vm, HubPos::new(1, 9));
    let events = t.on_payload(&key(), &frame(HubRole::Mac, 1, 4)).unwrap();
    assert!(events.contains(&TruthEvent::Gap { epoch: 1, from: 2, to: 3, ask: HubRole::Vm }));
    assert_eq!(delivered(&events), vec![HubPos::new(1, 4)]);
    // A new epoch starts fresh: no gap.
    let events = t.on_payload(&key(), &frame(HubRole::Vm, 2, 0)).unwrap();
    assert!(!events.iter().any(|e| matches!(e, TruthEvent::Gap { .. })));
}

#[test]
fn a_stale_pick_is_flagged_once_and_names_the_source_to_ask() {
    let mut t = tracker();
    // The VM reports over its direct link that it is at 20; the relay keeps
    // delivering the Mac's copy from 10.
    t.report_head(HubRole::Vm, HubPos::new(1, 20));
    let events = t.on_payload(&key(), &frame(HubRole::Mac, 1, 10)).unwrap();
    assert!(events.contains(&TruthEvent::StalePick {
        source: HubRole::Mac,
        delivered: HubPos::new(1, 10),
        ahead: HubRole::Vm,
        head: HubPos::new(1, 20),
    }));
    // Same lag: not flagged again.
    let events = t.on_payload(&key(), &frame(HubRole::Mac, 1, 11)).unwrap();
    assert!(!events.iter().any(|e| matches!(e, TruthEvent::StalePick { .. })));
    // Within tolerance (frames racing a head report): not a stale pick.
    let mut t = tracker();
    t.report_head(HubRole::Vm, HubPos::new(1, 13));
    let events = t.on_payload(&key(), &frame(HubRole::Mac, 1, 10)).unwrap();
    assert!(!events.iter().any(|e| matches!(e, TruthEvent::StalePick { .. })));
    assert_eq!(t.stats.stale_picks, 0);
}

#[test]
fn a_head_report_never_moves_backwards() {
    let mut t = tracker();
    t.report_head(HubRole::Mac, HubPos::new(2, 1));
    t.report_head(HubRole::Mac, HubPos::new(1, 99));
    assert_eq!(t.head(HubRole::Mac), Some(HubPos::new(2, 1)));
}
