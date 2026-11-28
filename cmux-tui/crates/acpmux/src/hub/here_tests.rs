use super::*;

fn owner() -> Who {
    Who { id: "owner".into(), name: "Leo".into() }
}

fn beat(device: &str, seq: u64, activity: HereActivity) -> HereBeatParams {
    HereBeatParams {
        device: device.into(),
        device_kind: HereDeviceKind::Mac,
        seq,
        activity,
        idle_ms: 0,
        scopes: vec!["chat-1".into()],
        leave: false,
        meta: None,
    }
}

#[test]
fn a_person_on_two_devices_is_one_member_and_agents_join_after_people() {
    let t = HereTable::default();
    assert!(t.beat(&owner(), beat("mac", 1, HereActivity::Present), 1_000).unwrap());
    let mut phone = beat("phone", 1, HereActivity::Away);
    phone.device_kind = HereDeviceKind::Phone;
    t.beat(&owner(), phone, 1_000).unwrap();
    let agents = vec![Agent { session: "s1".into(), name: "fix the build".into() }];
    let r = t.here(None, agents, 2_000);
    assert_eq!(r.here.len(), 2);
    assert_eq!(r.here[0].id, "owner");
    assert_eq!(r.here[0].status, HereStatus::Active);
    assert_eq!(r.here[0].devices.len(), 2);
    assert_eq!(r.here[1].kind, HereKind::Agent);
    assert!(r.here[1].working);
}

#[test]
fn a_beat_lapses_and_leave_drops_it_now() {
    let t = HereTable::default();
    t.beat(&owner(), beat("mac", 1, HereActivity::Present), 1_000).unwrap();
    assert!(t.here(None, vec![], 40_000).here.is_empty(), "a 30 s beat lapses");
    t.beat(&owner(), beat("mac", 2, HereActivity::Present), 50_000).unwrap();
    let mut bye = beat("mac", 3, HereActivity::Present);
    bye.leave = true;
    assert!(t.beat(&owner(), bye, 50_001).unwrap());
    assert!(t.here(None, vec![], 50_002).here.is_empty());
}

#[test]
fn scope_filters_people_and_agents() {
    let t = HereTable::default();
    t.beat(&owner(), beat("mac", 1, HereActivity::Working), 1_000).unwrap();
    let agents = || {
        vec![
            Agent { session: "chat-1".into(), name: "a".into() },
            Agent { session: "chat-2".into(), name: "b".into() },
        ]
    };
    let r = t.here(Some("chat-2"), agents(), 1_001);
    assert_eq!(r.here.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["chat-2"]);
    let r = t.here(Some("chat-1"), agents(), 1_001);
    assert_eq!(r.here.len(), 2);
}

#[test]
fn the_table_is_bounded_and_refuses_bad_input() {
    let t = HereTable::default();
    for i in 0..MAX_DEVICES {
        t.beat(&owner(), beat(&format!("d{i}"), 1, HereActivity::Present), 1_000).unwrap();
    }
    let e = t.beat(&owner(), beat("one-more", 1, HereActivity::Present), 1_000).unwrap_err();
    assert!(format!("{e:?}").contains("here.full"));
    // A device already here still beats.
    t.beat(&owner(), beat("d0", 2, HereActivity::Present), 1_001).unwrap();
    assert!(t.beat(&owner(), beat("a\nb", 1, HereActivity::Present), 1_000).is_err());
    let mut many = beat("d1", 3, HereActivity::Present);
    many.scopes = (0..17).map(|i| i.to_string()).collect();
    assert!(t.beat(&owner(), many, 1_000).is_err());
}

fn peer(
    name: &str,
    connected: bool,
    acknowledged: bool,
    edits: u64,
) -> crate::protocol::here::HereSyncPeer {
    crate::protocol::here::HereSyncPeer {
        peer: name.into(),
        connected,
        acknowledged,
        unacknowledged_edits: edits,
    }
}

/// RFD 0140's status icon: one reduction, here, for every client (the Swift sidebar draws only this).
#[test]
fn summary_reduces_sync_and_presence_once() {
    use crate::protocol::here::HereSyncState::*;
    let t = HereTable::default();
    t.beat(&owner(), beat("mac", 1, HereActivity::Present), 1_000).unwrap();
    t.beat(
        &Who { id: "a1".into(), name: "Ana".into() },
        beat("mac2", 1, HereActivity::Present),
        1_000,
    )
    .unwrap();
    let r = t.here(None, vec![Agent { session: "s1".into(), name: "fix".into() }], 2_000);
    let of = |sync: &[_]| HereSummary::of(&r.here, sync, OWNER_ID);
    // Presence: the owner is not counted; the other person and the agent are.
    let s = of(&[]);
    assert_eq!((s.sync, s.pending_edits, s.others, s.agents), (Alone, 0, 1, 1));
    // A connected peer behind: syncing, counting its edits.
    assert_eq!(of(&[peer("vm", true, false, 3)]).sync, Syncing);
    assert_eq!(of(&[peer("vm", true, false, 3)]).pending_edits, 3);
    // Unacknowledged with zero edits is still not synced.
    assert_eq!(of(&[peer("vm", true, false, 0)]).sync, Syncing);
    assert_eq!(of(&[peer("vm", true, true, 0)]).sync, Synced);
    // A sleeping phone with queued edits does not mark a Mac with a live VM offline.
    let mixed = of(&[peer("vm", true, true, 0), peer("phone", false, false, 7)]);
    assert_eq!((mixed.sync, mixed.pending_edits), (Synced, 0));
    // Every peer down with edits queued: offline, counting the most any peer misses.
    let off = of(&[peer("vm", false, false, 2), peer("phone", false, false, 5)]);
    assert_eq!((off.sync, off.pending_edits), (Offline, 5));
    // Every peer down with nothing queued is not an alarm.
    assert_eq!(of(&[peer("vm", false, true, 0)]).sync, Synced);
}
