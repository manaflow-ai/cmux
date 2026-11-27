use cmux_presence::{
    AgentActivity, DEFAULT_LEASE_MS, Delta, Doing, FileTarget, Kind, Lease, Merge, Presence,
    PresenceId, Sharing, Status, TYPING_LEASE_MS,
};
use std::collections::HashMap;

const OWNER: &str = "local-daemon";

fn agent(n: usize) -> Presence {
    Presence::new(PresenceId(format!("agent-{n:04}").into()), Kind::Agent, "Agent", 1)
}

// Replayable packet schedules without a wall clock, runtime or random seed from the host.
struct Schedule(u64);

impl Schedule {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 32
    }

    fn shuffle<T>(&mut self, slice: &mut [T]) {
        for i in (1..slice.len()).rev() {
            slice.swap(i, self.next() as usize % (i + 1));
        }
    }
}

#[test]
fn seeded_snapshot_merge_is_commutative_and_idempotent() {
    for seed in 0..64 {
        let mut rng = Schedule(seed);
        let base = agent(0);
        let snapshots: Vec<_> = (2..48)
            .map(|epoch| Presence {
                epoch,
                name: format!("version-{epoch}").into(),
                ..base.clone()
            })
            .collect();
        let winner = snapshots.last().unwrap();
        let mut arrivals = snapshots.clone();
        arrivals.extend_from_slice(&snapshots);
        rng.shuffle(&mut arrivals);
        let mut lease = Lease::new(OWNER, base, 0);
        for incoming in arrivals {
            let held = lease.get(0).unwrap().epoch;
            let expected = if incoming.epoch > held { Merge::Applied } else { Merge::Stale };
            assert_eq!(lease.merge(OWNER, incoming, 0), expected, "seed {seed}");
        }
        assert_eq!(lease.get(0), Some(winner), "seed {seed}");
    }
}

#[test]
fn a_partial_delta_cannot_skip_a_base_or_renew_a_dead_lease() {
    let base = agent(7);
    let mut typing = base.clone();
    typing.epoch += 1;
    typing.doing = Doing::Typing;
    typing.lease_ms = TYPING_LEASE_MS;
    let mut moved = typing.clone();
    moved.epoch += 1;
    moved.location.chat = Some("second".into());
    let update = Delta::between(&base, &typing).unwrap();
    let gap = Delta::between(&typing, &moved).unwrap();
    let mut lease = Lease::new(OWNER, base.clone(), 3);
    assert_eq!(lease.apply("other", update.clone(), 10), Merge::WrongOwner);
    assert_eq!(lease.merge(OWNER, agent(8), 10), Merge::WrongId);
    assert_eq!(lease.apply(OWNER, gap.clone(), 10), Merge::NeedSnapshot);
    assert_eq!(lease.get(10), Some(&base));
    assert_eq!(lease.apply(OWNER, update.clone(), 100), Merge::Applied);
    assert_eq!(lease.apply(OWNER, update, 7000), Merge::Stale);
    assert_eq!(lease.deadline(), Some(8100));
    assert!(!lease.expire(8099));
    assert!(lease.get(8100).is_none());
    assert_eq!(lease.apply(OWNER, gap, 8100), Merge::NeedSnapshot);
    assert!(lease.expire(8100));
    assert!(!lease.expire(8100));
    assert_eq!(lease.deadline(), None);
    assert_eq!(lease.merge(OWNER, typing, 8101), Merge::Stale);
    assert_eq!(lease.merge(OWNER, moved.clone(), 8102), Merge::Applied);
    assert_eq!(lease.get(8102), Some(&moved));
}

#[test]
fn wire_delta_clears_fields_without_repeating_unchanged_data() {
    let mut a = agent(1);
    a.location.file = Some(FileTarget { path: "private.rs".into(), line: Some(9) });
    a.following = Some(PresenceId("other".into()));
    let mut b = a.clone();
    b.epoch += 1;
    b.location.file = None;
    b.following = None;
    let encoded = serde_json::to_value(Delta::between(&a, &b).unwrap()).unwrap();
    assert_eq!(encoded["changes"], serde_json::json!([{"file":null}, {"following":null}]));
    let mut replica = Lease::new(OWNER, a, 0);
    assert_eq!(replica.apply(OWNER, serde_json::from_value(encoded).unwrap(), 1), Merge::Applied);
    assert_eq!(replica.get(1), Some(&b));
    assert!(std::mem::size_of::<Presence>() < 200);
    assert!(serde_json::to_vec(&b).unwrap().len() < 200);
}

#[test]
fn projection_applies_the_owners_scope_before_serialization() {
    let mut local = agent(2);
    local.location.file = Some(FileTarget { path: "secret.rs".into(), line: Some(10) });
    local.location.chat = Some("room".into());
    local.following = Some(PresenceId("other".into()));
    local.doing = AgentActivity::Editing.into();
    assert!(local.shared(Sharing::default()).is_none());
    let live = Sharing { live: true, ..Sharing::default() };
    let coarse = local.shared(live).unwrap();
    assert_eq!(coarse.location.chat, local.location.chat);
    assert!(coarse.location.file.is_none());
    let files = Sharing { share_agent_files: true, ..live };
    assert_eq!(local.shared(files).unwrap(), local);
    assert!(local.shared(Sharing { private_chat: true, ..files }).is_none());
    local.status = Status::Quiet;
    local.doing = Doing::Typing;
    local.lease_ms = TYPING_LEASE_MS;
    let quiet = local.shared(files).unwrap();
    assert_eq!(quiet.doing, Doing::Idle);
    assert_eq!(quiet.lease_ms, DEFAULT_LEASE_MS);
    assert_eq!(quiet.location.as_ref(), &Default::default());
    assert_eq!(quiet.following, None);
}

#[test]
fn seeded_fleet_drops_reorders_duplicates_expires_and_resyncs() {
    // Two changes a second. Delay some until the following tick, disconnect the whole fleet,
    // and recover with one owner snapshot per id at the next heartbeat.
    let mut reference_bytes = None;
    for count in [10, 1000] {
        for seed in [41, 141] {
            let mut rng = Schedule(seed);
            let mut owners: Vec<_> = (0..count).map(agent).collect();
            let mut remote: HashMap<_, _> = owners
                .iter()
                .enumerate()
                .map(|(i, p)| (i, Lease::new(OWNER, p.clone(), 0)))
                .collect();
            let mut delayed = Vec::new();
            let mut bytes = 0;
            let mut applied = 0;
            let mut gaps = 0;
            for tick in 1..=80 {
                let mut packets = std::mem::take(&mut delayed);
                for (i, p) in owners.iter_mut().enumerate() {
                    let old = p.clone();
                    p.epoch += 1;
                    p.doing = if tick % 2 == 0 { Doing::Reading } else { Doing::Running };
                    let d = Delta::between(&old, p).unwrap();
                    bytes += serde_json::to_vec(&d).unwrap().len();
                    if (11..=75).contains(&tick) {
                        continue;
                    }
                    match rng.next() % 5 {
                        0 => {}
                        1 => delayed.push((i, d)),
                        2 => {
                            packets.push((i, d.clone()));
                            packets.push((i, d));
                        }
                        _ => packets.push((i, d)),
                    }
                }
                rng.shuffle(&mut packets);
                let now = tick * 500;
                for (i, d) in packets {
                    let replica = remote.get_mut(&i).unwrap();
                    match replica.apply(OWNER, d, now) {
                        Merge::Applied => {
                            applied += 1;
                            let accepted = replica.get(now).unwrap();
                            assert!(accepted.epoch <= owners[i].epoch);
                            let expected = if accepted.epoch % 2 == 0 {
                                Doing::Running
                            } else {
                                Doing::Reading
                            };
                            assert_eq!(accepted.doing, expected);
                        }
                        Merge::Stale => {}
                        Merge::NeedSnapshot => {
                            gaps += 1;
                        }
                        other => panic!("unexpected {other:?}"),
                    }
                }
                if tick == 75 {
                    assert!(remote.values_mut().all(|r| r.expire(now)));
                    assert!(remote.values().all(|r| r.get(now).is_none()));
                    assert!(owners.iter().all(|p| p.epoch == tick + 1));
                }
                if tick == 76 || tick == 80 {
                    for (i, p) in owners.iter().enumerate() {
                        let r = remote.get_mut(&i).unwrap();
                        let _ = r.merge(OWNER, p.clone(), now);
                        assert_eq!(r.get(now), Some(p));
                    }
                }
            }
            assert!(applied > 0 && gaps > 0);
            eprintln!(
                "seed={seed} entries={count} changes={} wire_bytes={bytes} applied={applied} gaps={gaps}",
                80 * count
            );
            // Ids have the same encoded width throughout both fleets.
            assert_eq!(bytes % count, 0);
            assert_eq!(*reference_bytes.get_or_insert(bytes / count), bytes / count);
        }
    }
}
