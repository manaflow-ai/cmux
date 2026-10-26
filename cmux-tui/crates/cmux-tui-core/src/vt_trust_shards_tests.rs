use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::num::NonZeroUsize;

use super::*;

fn planner(cap: usize) -> ShardPlanner {
    ShardPlanner::new(NonZeroUsize::new(cap).expect("cap is nonzero"))
}

/// What the broker sees after applying the actions in order: each live
/// worker's lock and its mapped rings. Panics on an action a real broker
/// could not apply (map into a dead worker, unmap of an unmapped ring,
/// retire of a worker still mapping rings, a ring mapped twice).
#[derive(Default)]
struct Broker {
    workers: BTreeMap<WorkerSlot, (TrustClass, BTreeSet<RingSegment>)>,
    mapped_in: HashMap<RingSegment, WorkerSlot>,
}

impl Broker {
    fn apply(&mut self, actions: &[ShardAction]) {
        for &action in actions {
            match action {
                ShardAction::Spawn { slot, class } => {
                    // A respawn after a crash starts with no mapping.
                    if let Some((_, rings)) = self.workers.insert(slot, (class, BTreeSet::new())) {
                        for ring in rings {
                            self.mapped_in.remove(&ring);
                        }
                    }
                }
                ShardAction::Map { slot, ring } => {
                    let (_, rings) = self.workers.get_mut(&slot).expect("map into a live worker");
                    assert!(rings.insert(ring), "{ring:?} mapped twice in {slot:?}");
                    assert!(
                        self.mapped_in.insert(ring, slot).is_none(),
                        "{ring:?} mapped in two workers"
                    );
                }
                ShardAction::Unmap { slot, ring } => {
                    let (_, rings) = self.workers.get_mut(&slot).expect("unmap in a live worker");
                    assert!(rings.remove(&ring), "{ring:?} was not mapped in {slot:?}");
                    self.mapped_in.remove(&ring);
                }
                ShardAction::Retire { slot } => {
                    let (_, rings) = self.workers.remove(&slot).expect("retire a live worker");
                    assert!(rings.is_empty(), "{slot:?} retired while mapping {rings:?}");
                }
            }
        }
    }
}

/// The planner's view and the broker's agree, and no worker maps a ring
/// whose class differs from its lock.
fn assert_unmixed(
    planner: &ShardPlanner,
    broker: &Broker,
    classes: &HashMap<SurfaceId, TrustClass>,
) {
    let rows = planner.mapped_segments();
    assert_eq!(rows.len(), broker.workers.len());
    for row in &rows {
        let (lock, rings) = &broker.workers[&row.slot];
        assert_eq!(*lock, row.class);
        let listed: BTreeSet<RingSegment> = row.segments.iter().map(|s| s.ring).collect();
        assert_eq!(&listed, rings);
        for segment in &row.segments {
            assert_eq!(segment.class, row.class, "worker {:?} mixes classes", row.slot);
            assert_eq!(classes[&segment.ring.terminal], row.class);
        }
    }
    assert_eq!(mixed_workers(&rows), 0);
}

fn mixed_workers(rows: &[WorkerMappings]) -> usize {
    rows.iter().filter(|row| row.segments.iter().any(|s| s.class != row.class)).count()
}

fn place(
    planner: &mut ShardPlanner,
    broker: &mut Broker,
    classes: &mut HashMap<SurfaceId, TrustClass>,
    terminal: SurfaceId,
    class: TrustClass,
) {
    let actions = planner.place(terminal, class, 0).expect("place");
    broker.apply(&actions);
    classes.insert(terminal, class);
}

#[test]
fn eight_local_and_four_ssh_with_two_workers_mix_none_in_any_order() {
    let ssh = TrustClass::classify(TerminalHost::Ssh, false);
    let orders: [Vec<TrustClass>; 3] = [
        [vec![TrustClass::Local; 8], vec![ssh; 4]].concat(),
        [vec![ssh; 4], vec![TrustClass::Local; 8]].concat(),
        (0..12).map(|i| if i % 3 == 2 { ssh } else { TrustClass::Local }).collect(),
    ];
    for order in orders {
        let mut planner = planner(2);
        let mut broker = Broker::default();
        let mut classes = HashMap::new();
        for (id, class) in order.into_iter().enumerate() {
            place(&mut planner, &mut broker, &mut classes, id as SurfaceId, class);
            assert_unmixed(&planner, &broker, &classes);
        }
        // Two classes, cap 2: at most one spill.
        assert!(planner.worker_count() <= 3, "{} workers", planner.worker_count());
    }
}

#[test]
fn a_class_with_no_worker_spills_one_past_the_cap() {
    let mut planner = planner(2);
    let mut broker = Broker::default();
    let mut classes = HashMap::new();
    for id in 0..6 {
        place(&mut planner, &mut broker, &mut classes, id, TrustClass::Local);
    }
    assert_eq!(planner.worker_count(), 2);

    let actions = planner.place(100, TrustClass::Remote, 0).expect("place remote");
    let spawned = WorkerSlot(2);
    assert_eq!(
        actions,
        vec![
            ShardAction::Spawn { slot: spawned, class: TrustClass::Remote },
            ShardAction::Map { slot: spawned, ring: RingSegment { terminal: 100, segment: 0 } },
        ]
    );
    broker.apply(&actions);
    classes.insert(100, TrustClass::Remote);

    // The next remote terminal shares the spill worker; no fourth worker.
    place(&mut planner, &mut broker, &mut classes, 101, TrustClass::Remote);
    assert_eq!(planner.slot_of(101), Some(spawned));
    assert_eq!(planner.worker_count(), 3);
    assert_unmixed(&planner, &broker, &classes);
}

#[test]
fn at_the_cap_a_terminal_goes_to_the_least_loaded_worker_of_its_class() {
    let mut planner = planner(3);
    let mut broker = Broker::default();
    let mut classes = HashMap::new();
    for id in 0..3 {
        place(&mut planner, &mut broker, &mut classes, id, TrustClass::Local);
    }
    place(&mut planner, &mut broker, &mut classes, 3, TrustClass::Local);
    place(&mut planner, &mut broker, &mut classes, 4, TrustClass::Local);
    assert_eq!(planner.slot_of(3), Some(WorkerSlot(0)));
    assert_eq!(planner.slot_of(4), Some(WorkerSlot(1)));
    broker.apply(&planner.remove(3).expect("remove"));
    place(&mut planner, &mut broker, &mut classes, 5, TrustClass::Local);
    assert_eq!(planner.slot_of(5), Some(WorkerSlot(0)));
}

#[test]
fn a_terminal_that_starts_ssh_moves_and_its_old_worker_unmaps_first() {
    let mut planner = planner(1);
    let mut broker = Broker::default();
    let mut classes = HashMap::new();
    place(&mut planner, &mut broker, &mut classes, 1, TrustClass::Local);
    place(&mut planner, &mut broker, &mut classes, 2, TrustClass::Local);

    let actions = planner.reclassify(2, TrustClass::Remote).expect("reclassify");
    let ring = RingSegment { terminal: 2, segment: 0 };
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap { slot: WorkerSlot(0), ring },
            ShardAction::Spawn { slot: WorkerSlot(1), class: TrustClass::Remote },
            ShardAction::Map { slot: WorkerSlot(1), ring },
        ]
    );
    broker.apply(&actions);
    classes.insert(2, TrustClass::Remote);
    assert_unmixed(&planner, &broker, &classes);

    // Same class again: nothing moves.
    assert_eq!(planner.reclassify(2, TrustClass::Remote), Ok(Vec::new()));
}

#[test]
fn moving_the_last_terminal_retires_its_worker_before_the_new_one_maps() {
    let mut planner = planner(2);
    let mut broker = Broker::default();
    let mut classes = HashMap::new();
    place(&mut planner, &mut broker, &mut classes, 1, TrustClass::Local);

    let actions = planner.reclassify(1, TrustClass::AgentFetched).expect("reclassify");
    let ring = RingSegment { terminal: 1, segment: 0 };
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap { slot: WorkerSlot(0), ring },
            ShardAction::Retire { slot: WorkerSlot(0) },
            ShardAction::Spawn { slot: WorkerSlot(1), class: TrustClass::AgentFetched },
            ShardAction::Map { slot: WorkerSlot(1), ring },
        ]
    );
    broker.apply(&actions);
    assert_eq!(planner.worker_count(), 1);
}

#[test]
fn a_lost_worker_respawns_in_its_slot_with_its_lock_and_rings() {
    let mut planner = planner(1);
    let mut broker = Broker::default();
    let mut classes = HashMap::new();
    for id in 0..16 {
        place(&mut planner, &mut broker, &mut classes, id, TrustClass::Remote);
    }
    let actions = planner.worker_lost(WorkerSlot(0)).expect("lost");
    assert_eq!(actions[0], ShardAction::Spawn { slot: WorkerSlot(0), class: TrustClass::Remote });
    assert_eq!(actions.len(), 17);
    broker.apply(&actions);
    assert_unmixed(&planner, &broker, &classes);
    assert_eq!(planner.worker_lost(WorkerSlot(9)), Err(ShardError::UnknownWorker(WorkerSlot(9))));
}

#[test]
fn a_fresh_holder_ring_replaces_the_mapping_in_the_same_worker() {
    let mut planner = planner(2);
    let mut broker = Broker::default();
    let mut classes = HashMap::new();
    place(&mut planner, &mut broker, &mut classes, 7, TrustClass::Local);
    let actions = planner.replace_segment(7, 3).expect("replace");
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap {
                slot: WorkerSlot(0),
                ring: RingSegment { terminal: 7, segment: 0 }
            },
            ShardAction::Map { slot: WorkerSlot(0), ring: RingSegment { terminal: 7, segment: 3 } },
        ]
    );
    broker.apply(&actions);
    assert_unmixed(&planner, &broker, &classes);
    assert_eq!(planner.replace_segment(7, 3), Ok(Vec::new()));
}

#[test]
fn unknown_and_duplicate_terminals_are_typed_errors() {
    let mut planner = planner(2);
    planner.place(1, TrustClass::Local, 0).expect("place");
    assert_eq!(planner.place(1, TrustClass::Remote, 0), Err(ShardError::AlreadyPlaced(1)));
    assert_eq!(planner.remove(2), Err(ShardError::UnknownTerminal(2)));
    assert_eq!(planner.reclassify(2, TrustClass::Local), Err(ShardError::UnknownTerminal(2)));
    assert_eq!(planner.replace_segment(2, 1), Err(ShardError::UnknownTerminal(2)));
}

#[test]
fn ssh_remote_and_cloud_share_one_class_and_agent_content_wins() {
    for host in [TerminalHost::Ssh, TerminalHost::RemoteDaemon, TerminalHost::Cloud] {
        assert_eq!(TrustClass::classify(host, false), TrustClass::Remote);
        assert_eq!(TrustClass::classify(host, true), TrustClass::AgentFetched);
    }
    assert_eq!(TrustClass::classify(TerminalHost::Local, false), TrustClass::Local);
    assert_eq!(TrustClass::classify(TerminalHost::Local, true), TrustClass::AgentFetched);
}

#[test]
fn the_debug_list_names_each_rings_class() {
    let mut planner = planner(1);
    planner.place(1, TrustClass::Local, 0).expect("place");
    planner.place(2, TrustClass::AgentFetched, 4).expect("place");
    let json = serde_json::to_value(planner.mapped_segments()).expect("json");
    assert_eq!(
        json,
        serde_json::json!([
            {"slot": 0, "class": "local", "segments": [{"terminal": 1, "segment": 0, "class": "local"}]},
            {"slot": 1, "class": "agent_fetched",
             "segments": [{"terminal": 2, "segment": 4, "class": "agent_fetched"}]},
        ])
    );
}

/// The census heavy session's shape (172 terminals, cap 4), driven through
/// random opens, closes, class changes, fresh rings and worker crashes.
#[test]
fn a_random_heavy_mixed_session_never_mixes_a_worker() {
    const CLASSES: [TrustClass; 3] =
        [TrustClass::Local, TrustClass::Remote, TrustClass::AgentFetched];
    let mut seed: u64 = 0x9e37_79b9_7f4a_7c15;
    let mut next = move |bound: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % bound
    };
    let mut planner = planner(4);
    let mut broker = Broker::default();
    let mut classes: HashMap<SurfaceId, TrustClass> = HashMap::new();
    let mut segments: HashMap<SurfaceId, u64> = HashMap::new();
    for id in 0..172 {
        let class = CLASSES[if id % 8 == 0 {
            1
        } else if id % 29 == 0 {
            2
        } else {
            0
        }];
        place(&mut planner, &mut broker, &mut classes, id, class);
    }
    assert!(planner.worker_count() <= 4 + 2);
    assert_unmixed(&planner, &broker, &classes);

    let mut next_id = 172;
    for _ in 0..5_000 {
        let live: Vec<SurfaceId> = {
            let mut ids: Vec<_> = classes.keys().copied().collect();
            ids.sort_unstable();
            ids
        };
        let pick = |n: u64| live.get(n as usize % live.len().max(1)).copied();
        match next(5) {
            0 => {
                let class = CLASSES[next(3) as usize];
                place(&mut planner, &mut broker, &mut classes, next_id, class);
                next_id += 1;
            }
            1 => {
                if let Some(id) = pick(next(1 << 16)) {
                    broker.apply(&planner.remove(id).expect("remove"));
                    classes.remove(&id);
                }
            }
            2 => {
                if let Some(id) = pick(next(1 << 16)) {
                    let class = CLASSES[next(3) as usize];
                    broker.apply(&planner.reclassify(id, class).expect("reclassify"));
                    classes.insert(id, class);
                }
            }
            3 => {
                if let Some(id) = pick(next(1 << 16)) {
                    let segment = segments.entry(id).or_default();
                    *segment += 1;
                    broker.apply(&planner.replace_segment(id, *segment).expect("replace"));
                }
            }
            _ => {
                let slots: Vec<WorkerSlot> = broker.workers.keys().copied().collect();
                if let Some(&slot) = slots.get(next(slots.len().max(1) as u64) as usize) {
                    broker.apply(&planner.worker_lost(slot).expect("lost"));
                }
            }
        }
        assert_unmixed(&planner, &broker, &classes);
        let present: BTreeSet<TrustClass> = classes.values().copied().collect();
        // A spawn at the cap only gives a class its first worker, so the
        // spill is at most one worker per class past the first.
        assert!(planner.worker_count() <= 4 + present.len().saturating_sub(1));
    }
}
