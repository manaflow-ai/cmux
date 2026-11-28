use super::*;

fn beat(
    member: &str,
    kind: Kind,
    device: &str,
    dk: DeviceKind,
    seq: u64,
    activity: Activity,
) -> Beat {
    Beat {
        member: Member { id: member.to_owned(), name: member.to_owned(), kind },
        device: device.to_owned(),
        device_kind: dk,
        seq,
        activity,
        idle_ms: 0,
        scopes: vec!["chat:1".to_owned()],
    }
}

#[test]
fn a_member_on_two_devices_is_one_entry_with_the_best_status() {
    let mut p = Presence::default();
    let mut mac = beat("person:leo", Kind::Person, "mac", DeviceKind::Mac, 1, Activity::Away);
    mac.idle_ms = 0;
    p.beat(mac, 0);
    p.beat(beat("person:leo", Kind::Person, "phone", DeviceKind::Phone, 1, Activity::Present), 0);
    let here = p.here(None, 1_000);
    assert_eq!(here.len(), 1);
    assert_eq!(here[0].status, Status::Active);
    assert_eq!(here[0].devices.len(), 2);
    assert_eq!(here[0].devices[0].device_kind, DeviceKind::Phone);
}

#[test]
fn a_duplicate_or_older_beat_is_ignored() {
    let mut p = Presence::default();
    assert!(p.beat(beat("a", Kind::Agent, "vm", DeviceKind::Vm, 5, Activity::Working), 0));
    assert!(!p.beat(beat("a", Kind::Agent, "vm", DeviceKind::Vm, 5, Activity::Working), 1));
    assert!(!p.beat(beat("a", Kind::Agent, "vm", DeviceKind::Vm, 4, Activity::Present), 2));
    assert!(p.here(None, 3)[0].working);
}

#[test]
fn a_fresher_beat_with_nothing_new_is_not_a_change() {
    let mut p = Presence::default();
    p.beat(beat("a", Kind::Person, "mac", DeviceKind::Mac, 1, Activity::Present), 0);
    assert!(!p.beat(beat("a", Kind::Person, "mac", DeviceKind::Mac, 2, Activity::Present), 10_000));
    assert!(p.beat(beat("a", Kind::Person, "mac", DeviceKind::Mac, 3, Activity::Working), 20_000));
}

#[test]
fn silence_past_the_ttl_is_gone_and_idle_follows_input_age() {
    let mut p = Presence::default();
    let mut b = beat("a", Kind::Person, "mac", DeviceKind::Mac, 1, Activity::Present);
    b.idle_ms = 119_000;
    p.beat(b, 0);
    assert_eq!(p.here(None, 0)[0].status, Status::Active);
    assert_eq!(p.here(None, 2_000)[0].status, Status::Idle);
    assert!(p.here(None, 30_000).is_empty());
    assert_eq!(p.expire(30_000), vec!["a".to_owned()]);
}

#[test]
fn here_filters_by_scope_and_orders_people_before_agents() {
    let mut p = Presence::default();
    p.beat(beat("agent:x", Kind::Agent, "vm", DeviceKind::Vm, 1, Activity::Working), 0);
    p.beat(beat("person:b", Kind::Person, "mac", DeviceKind::Mac, 1, Activity::Present), 0);
    let mut elsewhere =
        beat("person:c", Kind::Person, "mac2", DeviceKind::Mac, 1, Activity::Present);
    elsewhere.scopes = vec!["chat:2".to_owned()];
    p.beat(elsewhere, 0);
    let ids: Vec<_> = p.here(Some("chat:1"), 0).into_iter().map(|h| h.member.id).collect();
    assert_eq!(ids, vec!["person:b", "agent:x"]);
    assert_eq!(p.here(None, 0).len(), 3);
}

#[test]
fn leave_needs_a_newer_seq_so_a_late_beat_cannot_resurrect() {
    let mut p = Presence::default();
    p.beat(beat("a", Kind::Person, "mac", DeviceKind::Mac, 3, Activity::Present), 0);
    assert!(!p.leave("a", "mac", 3));
    assert!(p.leave("a", "mac", 4));
    assert!(p.here(None, 0).is_empty());
}

#[test]
fn live_beats_age_their_idle_time() {
    let mut p = Presence::default();
    p.beat(beat("a", Kind::Person, "mac", DeviceKind::Mac, 1, Activity::Present), 1_000);
    assert_eq!(p.live_beats(6_000)[0].idle_ms, 5_000);
}
