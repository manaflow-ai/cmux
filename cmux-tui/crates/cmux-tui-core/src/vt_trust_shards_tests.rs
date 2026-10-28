use std::collections::{BTreeSet, HashMap};
use std::num::NonZeroUsize;

use super::*;

fn planner(cap: usize) -> ShardPlanner {
    ShardPlanner::new(NonZeroUsize::new(cap).expect("cap is nonzero"))
}

/// What the terminals' programs print, kept apart from the planner: each
/// terminal's sources so far and the segment its holder writes to, and for
/// every segment the classes of the bytes written into it. A terminal's
/// bytes have the least trusted class of every source it has had, so `ssh`
/// exiting leaves them remote; the holder opens a fresh segment when that
/// class changes, as the broker asks it to.
#[derive(Default)]
struct Origins {
    terminals: HashMap<SurfaceId, (TrustClass, u64)>,
    written: HashMap<RingSegment, BTreeSet<TrustClass>>,
}

impl Origins {
    fn open(&mut self, terminal: SurfaceId, class: TrustClass) {
        self.terminals.insert(terminal, (class, 0));
        self.written.entry(RingSegment { terminal, segment: 0 }).or_default().insert(class);
    }

    /// The source changed; the fresh segment the holder opened, if the
    /// bytes' class changed.
    fn source(&mut self, terminal: SurfaceId, source: TrustClass) -> Option<u64> {
        let (class, segment) = self.terminals.get_mut(&terminal).expect("open terminal");
        let next = class.least_trusted(source);
        let fresh = (next != *class).then(|| {
            *segment += 1;
            *segment
        });
        *class = next;
        let ring = RingSegment { terminal, segment: *segment };
        self.written.entry(ring).or_default().insert(next);
        fresh
    }

    /// The holder restarted and gave the terminal a fresh segment.
    fn fresh_segment(&mut self, terminal: SurfaceId) -> u64 {
        let (class, segment) = self.terminals.get_mut(&terminal).expect("open terminal");
        *segment += 1;
        self.written.entry(RingSegment { terminal, segment: *segment }).or_default().insert(*class);
        *segment
    }

    fn close(&mut self, terminal: SurfaceId) {
        self.terminals.remove(&terminal);
    }

    fn class_of(&self, ring: RingSegment) -> Option<TrustClass> {
        let classes = self.written.get(&ring)?;
        match classes.iter().collect::<Vec<_>>().as_slice() {
            [class] => Some(**class),
            _ => None,
        }
    }

    fn present(&self) -> BTreeSet<TrustClass> {
        self.terminals.values().map(|(class, _)| *class).collect()
    }
}

/// A session: the planner, the broker's record of what the workers map,
/// and where the bytes came from.
struct Session {
    planner: ShardPlanner,
    applied: AppliedMappings,
    origins: Origins,
}

impl Session {
    fn new(cap: usize) -> Self {
        Self {
            planner: planner(cap),
            applied: AppliedMappings::default(),
            origins: Origins::default(),
        }
    }

    fn apply(&mut self, actions: Vec<ShardAction>) -> Vec<ShardAction> {
        self.applied.apply_all(&actions).expect("the broker can apply the plan");
        actions
    }

    fn open(&mut self, terminal: SurfaceId, class: TrustClass) -> Vec<ShardAction> {
        let actions = self.planner.place(terminal, class, 0).expect("place");
        self.origins.open(terminal, class);
        self.apply(actions)
    }

    fn source(&mut self, terminal: SurfaceId, source: TrustClass) -> Vec<ShardAction> {
        let fresh = self.origins.source(terminal, source);
        assert_eq!(self.planner.needs_fresh_ring(terminal, source), Ok(fresh.is_some()));
        let actions = self.planner.reclassify(terminal, source, fresh).expect("reclassify");
        self.apply(actions)
    }

    fn close(&mut self, terminal: SurfaceId) {
        let actions = self.planner.remove(terminal).expect("remove");
        self.origins.close(terminal);
        self.apply(actions);
    }

    fn crash(&mut self, slot: WorkerSlot) {
        self.applied.worker_ended(slot);
        let actions = self.planner.worker_lost(slot).expect("lost");
        self.apply(actions);
    }

    fn rows(&self) -> Vec<WorkerMappings> {
        self.applied.mapped_segments(|ring| self.origins.class_of(ring))
    }

    /// No worker maps a segment holding bytes of a class other than its
    /// lock, and the planner agrees with what the workers map.
    fn assert_unmixed(&self) {
        for row in self.rows() {
            assert!(!row.mixed, "worker {:?} mixes classes: {row:?}", row.slot);
        }
        assert_eq!(self.applied.diverges_from(&self.planner), Vec::new());
    }
}

fn census_class(id: SurfaceId) -> TrustClass {
    if id.is_multiple_of(8) {
        TrustClass::Remote
    } else if id.is_multiple_of(29) {
        TrustClass::AgentFetched
    } else {
        TrustClass::Local
    }
}

/// Within a class, worker loads differ by at most one; across classes, no
/// worker carries more than the busiest worker of an even split over the cap.
fn assert_balanced(planner: &ShardPlanner, terminals: usize, cap: usize) {
    let even = terminals.div_ceil(cap);
    for class in [TrustClass::Local, TrustClass::Remote, TrustClass::AgentFetched] {
        let loads = planner.loads(class);
        let (Some(&min), Some(&max)) = (loads.iter().min(), loads.iter().max()) else {
            continue;
        };
        assert!(max - min <= 1, "{class:?} loads {loads:?}");
        assert!(max <= even, "{class:?} loads {loads:?}, even split {even}");
    }
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
        let mut session = Session::new(2);
        for (id, class) in order.into_iter().enumerate() {
            session.open(id as SurfaceId, class);
            session.assert_unmixed();
        }
        // Two classes, cap 2: at most one spill.
        assert!(session.planner.worker_count() <= 3, "{} workers", session.planner.worker_count());
        assert_balanced(&session.planner, 12, 2);
    }
}

#[test]
fn ssh_terminals_opened_first_do_not_leave_the_local_majority_on_one_worker() {
    let mut session = Session::new(4);
    for id in 0..4 {
        session.open(id, TrustClass::Remote);
    }
    assert_eq!(session.planner.loads(TrustClass::Remote), vec![1, 1, 1, 1]);
    for id in 4..172 {
        session.open(id, TrustClass::Local);
        session.assert_unmixed();
    }
    assert!(session.planner.worker_count() <= 5);
    let local = session.planner.loads(TrustClass::Local);
    assert!(local.len() >= 3, "local loads {local:?}");
    assert_balanced(&session.planner, 172, 4);
}

#[test]
fn the_census_heavy_shape_spreads_every_class() {
    for order in [
        (0..172).collect::<Vec<SurfaceId>>(),
        (0..172).rev().collect(),
        // Every remote and agent terminal first, then the local ones.
        (0..172)
            .filter(|&id| census_class(id) != TrustClass::Local)
            .chain((0..172).filter(|&id| census_class(id) == TrustClass::Local))
            .collect(),
    ] {
        let mut session = Session::new(4);
        for id in order {
            session.open(id, census_class(id));
            session.assert_unmixed();
        }
        // Three classes, cap 4: at most two spills.
        assert!(session.planner.worker_count() <= 6);
        assert!(session.planner.loads(TrustClass::Local).len() >= 3);
        assert_balanced(&session.planner, 172, 4);
    }
}

#[test]
fn a_class_with_no_worker_spills_one_past_the_cap() {
    let mut session = Session::new(2);
    for id in 0..6 {
        session.open(id, TrustClass::Local);
    }
    assert_eq!(session.planner.worker_count(), 2);

    let actions = session.open(100, TrustClass::Remote);
    let spawned = WorkerSlot(2);
    assert_eq!(
        actions,
        vec![
            ShardAction::Spawn { slot: spawned, class: TrustClass::Remote },
            ShardAction::Map { slot: spawned, ring: RingSegment { terminal: 100, segment: 0 } },
        ]
    );

    // The next remote terminal shares the spill worker; no fourth worker.
    session.open(101, TrustClass::Remote);
    assert_eq!(session.planner.slot_of(101), Some(spawned));
    assert_eq!(session.planner.worker_count(), 3);
    session.assert_unmixed();
}

#[test]
fn at_the_cap_a_terminal_goes_to_the_least_loaded_worker_of_its_class() {
    let mut session = Session::new(3);
    for id in 0..5 {
        session.open(id, TrustClass::Local);
    }
    assert_eq!(session.planner.slot_of(3), Some(WorkerSlot(0)));
    assert_eq!(session.planner.slot_of(4), Some(WorkerSlot(1)));
    session.close(3);
    session.open(5, TrustClass::Local);
    assert_eq!(session.planner.slot_of(5), Some(WorkerSlot(0)));
}

#[test]
fn a_busy_class_takes_a_worker_from_a_light_one_and_its_rings_move_first() {
    let mut session = Session::new(2);
    session.open(0, TrustClass::Remote);
    session.open(1, TrustClass::Remote);
    session.open(2, TrustClass::Local);
    session.open(3, TrustClass::Local);
    // Local 3 on one worker against remote 1 + 1: retire the least loaded
    // remote worker (the lowest slot on a tie).
    let actions = session.open(4, TrustClass::Local);
    let moved = RingSegment { terminal: 0, segment: 0 };
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap { slot: WorkerSlot(0), ring: moved },
            ShardAction::Map { slot: WorkerSlot(1), ring: moved },
            ShardAction::Retire { slot: WorkerSlot(0) },
            ShardAction::Spawn { slot: WorkerSlot(3), class: TrustClass::Local },
            ShardAction::Map { slot: WorkerSlot(3), ring: RingSegment { terminal: 4, segment: 0 } },
        ]
    );
    assert_eq!(session.planner.slot_of(0), Some(WorkerSlot(1)));
    session.assert_unmixed();
}

#[test]
fn a_terminal_that_starts_ssh_moves_with_a_fresh_ring_and_its_old_worker_unmaps_first() {
    let mut session = Session::new(1);
    session.open(1, TrustClass::Local);
    session.open(2, TrustClass::Local);

    // The old segment holds local bytes: the remote worker never gets it.
    assert_eq!(
        session.planner.reclassify(2, TrustClass::Remote, None),
        Err(ShardError::FreshRingRequired(2))
    );
    assert_eq!(
        session.planner.reclassify(2, TrustClass::Remote, Some(0)),
        Err(ShardError::SegmentReused { terminal: 2, segment: 0 })
    );
    let actions = session.source(2, TrustClass::Remote);
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap {
                slot: WorkerSlot(0),
                ring: RingSegment { terminal: 2, segment: 0 }
            },
            ShardAction::Spawn { slot: WorkerSlot(1), class: TrustClass::Remote },
            ShardAction::Map { slot: WorkerSlot(1), ring: RingSegment { terminal: 2, segment: 1 } },
        ]
    );
    session.assert_unmixed();

    // Same class again: nothing moves.
    assert_eq!(session.source(2, TrustClass::Remote), Vec::new());
}

#[test]
fn ssh_exiting_does_not_put_the_remote_segment_into_a_local_worker() {
    let mut session = Session::new(2);
    session.open(1, TrustClass::Local);
    session.open(2, TrustClass::Remote);
    let remote_worker = session.planner.slot_of(2);

    // The shell is local again, but its segment holds what the remote host
    // printed; the terminal stays remote.
    assert_eq!(session.source(2, TrustClass::Local), Vec::new());
    assert_eq!(session.planner.reclassify(2, TrustClass::Local, Some(7)), Ok(Vec::new()));
    assert_eq!(session.planner.class_of(2), Some(TrustClass::Remote));
    assert_eq!(session.planner.slot_of(2), remote_worker);
    let ring = RingSegment { terminal: 2, segment: 0 };
    for row in session.rows() {
        let maps = row.segments.iter().any(|segment| segment.ring == ring);
        assert_eq!(maps, row.class == TrustClass::Remote, "{row:?}");
    }
    session.assert_unmixed();
}

#[test]
fn the_debug_list_flags_a_ring_the_broker_mapped_into_the_wrong_worker() {
    let mut session = Session::new(2);
    session.open(1, TrustClass::Local);
    session.open(2, TrustClass::Remote);
    // A broker bug: the remote terminal's ring also lands in the local worker.
    let wrong =
        ShardAction::Map { slot: WorkerSlot(0), ring: RingSegment { terminal: 2, segment: 0 } };
    assert_eq!(
        session.applied.apply(wrong),
        Err(MappingError::AlreadyMapped {
            ring: RingSegment { terminal: 2, segment: 0 },
            slot: WorkerSlot(1)
        })
    );
    session
        .applied
        .apply(ShardAction::Unmap {
            slot: WorkerSlot(1),
            ring: RingSegment { terminal: 2, segment: 0 },
        })
        .expect("unmap");
    session.applied.apply(wrong).expect("map");
    let rows = session.rows();
    assert!(rows[0].mixed, "{rows:?}");
    assert!(!rows[1].mixed);
    assert_eq!(
        session.applied.diverges_from(&session.planner),
        vec![Divergence::Ring {
            ring: RingSegment { terminal: 2, segment: 0 },
            planned: Some(WorkerSlot(1)),
            applied: Some(WorkerSlot(0)),
        }]
    );
}

#[test]
fn moving_the_last_terminal_retires_its_worker_before_the_new_one_maps() {
    let mut session = Session::new(2);
    session.open(1, TrustClass::Local);

    let actions = session.source(1, TrustClass::AgentFetched);
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap {
                slot: WorkerSlot(0),
                ring: RingSegment { terminal: 1, segment: 0 }
            },
            ShardAction::Retire { slot: WorkerSlot(0) },
            ShardAction::Spawn { slot: WorkerSlot(1), class: TrustClass::AgentFetched },
            ShardAction::Map { slot: WorkerSlot(1), ring: RingSegment { terminal: 1, segment: 1 } },
        ]
    );
    assert_eq!(session.planner.worker_count(), 1);
}

#[test]
fn a_lost_worker_respawns_in_its_slot_with_its_lock_and_rings() {
    let mut session = Session::new(1);
    for id in 0..16 {
        session.open(id, TrustClass::Remote);
    }
    assert_eq!(
        session
            .applied
            .apply(ShardAction::Spawn { slot: WorkerSlot(0), class: TrustClass::Remote }),
        Err(MappingError::WorkerLive(WorkerSlot(0)))
    );
    session.applied.worker_ended(WorkerSlot(0));
    let actions = session.planner.worker_lost(WorkerSlot(0)).expect("lost");
    assert_eq!(actions[0], ShardAction::Spawn { slot: WorkerSlot(0), class: TrustClass::Remote });
    assert_eq!(actions.len(), 17);
    session.apply(actions);
    session.assert_unmixed();
    assert_eq!(
        session.planner.worker_lost(WorkerSlot(9)),
        Err(ShardError::UnknownWorker(WorkerSlot(9)))
    );
}

#[test]
fn a_fresh_holder_ring_replaces_the_mapping_in_the_same_worker() {
    let mut session = Session::new(2);
    session.open(7, TrustClass::Local);
    let segment = session.origins.fresh_segment(7);
    let actions = session.planner.replace_segment(7, segment).expect("replace");
    assert_eq!(
        actions,
        vec![
            ShardAction::Unmap {
                slot: WorkerSlot(0),
                ring: RingSegment { terminal: 7, segment: 0 }
            },
            ShardAction::Map { slot: WorkerSlot(0), ring: RingSegment { terminal: 7, segment: 1 } },
        ]
    );
    session.apply(actions);
    session.assert_unmixed();
    assert_eq!(session.planner.replace_segment(7, 1), Ok(Vec::new()));
}

#[test]
fn unknown_and_duplicate_terminals_are_typed_errors() {
    let mut planner = planner(2);
    planner.place(1, TrustClass::Local, 0).expect("place");
    assert_eq!(planner.place(1, TrustClass::Remote, 0), Err(ShardError::AlreadyPlaced(1)));
    assert_eq!(planner.remove(2), Err(ShardError::UnknownTerminal(2)));
    assert_eq!(planner.reclassify(2, TrustClass::Local, None), Err(ShardError::UnknownTerminal(2)));
    assert_eq!(planner.needs_fresh_ring(2, TrustClass::Local), Err(ShardError::UnknownTerminal(2)));
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
    assert_eq!(TrustClass::Remote.least_trusted(TrustClass::Local), TrustClass::Remote);
    assert_eq!(
        TrustClass::Remote.least_trusted(TrustClass::AgentFetched),
        TrustClass::AgentFetched
    );
}

#[test]
fn the_debug_list_names_each_rings_class() {
    let mut session = Session::new(1);
    session.open(1, TrustClass::Local);
    session.open(2, TrustClass::AgentFetched);
    let json = serde_json::to_value(session.rows()).expect("json");
    assert_eq!(
        json,
        serde_json::json!([
            {"slot": 0, "class": "local", "mixed": false,
             "segments": [{"terminal": 1, "segment": 0, "class": "local"}]},
            {"slot": 1, "class": "agent_fetched", "mixed": false,
             "segments": [{"terminal": 2, "segment": 0, "class": "agent_fetched"}]},
        ])
    );
}

/// The census heavy session's shape (172 terminals, cap 4), driven through
/// random opens, closes, source changes, fresh rings and worker crashes.
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
    let mut session = Session::new(4);
    for id in 0..172 {
        session.open(id, census_class(id));
    }
    assert!(session.planner.worker_count() <= 4 + 2);
    session.assert_unmixed();

    let mut next_id = 172;
    for _ in 0..5_000 {
        let live: Vec<SurfaceId> = {
            let mut ids: Vec<_> = session.origins.terminals.keys().copied().collect();
            ids.sort_unstable();
            ids
        };
        let pick = |n: u64| live.get(n as usize % live.len().max(1)).copied();
        match next(5) {
            0 => {
                let class = CLASSES[next(3) as usize];
                session.open(next_id, class);
                next_id += 1;
            }
            1 => {
                if let Some(id) = pick(next(1 << 16)) {
                    session.close(id);
                }
            }
            2 => {
                if let Some(id) = pick(next(1 << 16)) {
                    session.source(id, CLASSES[next(3) as usize]);
                }
            }
            3 => {
                if let Some(id) = pick(next(1 << 16)) {
                    let segment = session.origins.fresh_segment(id);
                    let actions = session.planner.replace_segment(id, segment).expect("replace");
                    session.apply(actions);
                }
            }
            _ => {
                let slots: Vec<WorkerSlot> = session.rows().iter().map(|row| row.slot).collect();
                if let Some(&slot) = slots.get(next(slots.len().max(1) as u64) as usize) {
                    session.crash(slot);
                }
            }
        }
        session.assert_unmixed();
        for (&id, &(class, _)) in &session.origins.terminals {
            assert_eq!(session.planner.class_of(id), Some(class));
        }
        let present = session.origins.present();
        assert!(session.planner.worker_count() <= 4 + present.len().saturating_sub(1));
    }
}

/// The broker names terminals by its own key (`VtTerminalKey`), not by
/// surface id: the planner takes any key.
#[test]
fn the_broker_key_places_the_same_way() {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
    struct BrokerKey(u64);

    let mut planner: ShardPlanner<BrokerKey> =
        ShardPlanner::new(NonZeroUsize::new(2).expect("cap is nonzero"));
    let mut applied = AppliedMappings::default();
    for id in 0..12 {
        let class = if id < 8 { TrustClass::Local } else { TrustClass::Remote };
        applied.apply_all(&planner.place(BrokerKey(id), class, 0).expect("place")).expect("apply");
    }
    let class_of = |ring: RingSegment<BrokerKey>| {
        Some(if ring.terminal.0 < 8 { TrustClass::Local } else { TrustClass::Remote })
    };
    let rows = applied.mapped_segments(class_of);
    assert!(rows.iter().all(|row| !row.mixed));
    assert_eq!(rows.len(), 3);
    assert_eq!(applied.diverges_from(&planner), Vec::new());
    assert_eq!(planner.remove(BrokerKey(99)), Err(ShardError::UnknownTerminal(BrokerKey(99))));
    assert_eq!(
        ShardError::UnknownTerminal(BrokerKey(99)).to_string(),
        "terminal BrokerKey(99) has no VT worker"
    );
}
