//! Property tests of the bind state machine and the retry rules.

use cmux_host::machine::{
    Action, DaemonState, HEALTHY_RUN_MS, Input, Lifecycle, Machine, Observation, StopReason,
};
use cmux_host::retry::{ArmError, MAX_BACKOFF_MS, RearmOutcome, rearm_bounded};
use proptest::prelude::*;

#[derive(Clone, Debug)]
enum Op {
    Observe(Option<u8>),
    SetBake(Option<u8>),
    DaemonExit(u64),
    StopDeadline,
    BackoffElapsed,
    RearmElapsed,
    Resume,
    AnnounceDone,
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => proptest::option::of(0u8..4).prop_map(Op::Observe),
        1 => proptest::option::of(0u8..4).prop_map(Op::SetBake),
        2 => (0u64..20_000).prop_map(Op::DaemonExit),
        1 => Just(Op::StopDeadline),
        1 => Just(Op::BackoffElapsed),
        1 => Just(Op::RearmElapsed),
        1 => Just(Op::Resume),
        1 => Just(Op::AnnounceDone),
    ]
}

fn id(n: u8) -> String {
    format!("vm-{n}")
}

/// The files the agent's actions write.
#[derive(Default)]
struct World {
    bound: Option<String>,
    bake: Option<String>,
    /// The metadata id the last observation returned.
    metadata: Option<String>,
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    #[test]
    fn bind_rules_hold_for_any_event_sequence(
        ops in proptest::collection::vec((op(), any::<bool>()), 1..80),
    ) {
        let mut m = Machine::new();
        let mut w = World::default();
        let mut last_reseed: Option<String> = None;
        // Completed binds (write-bound). A reseed whose bind was superseded
        // during the old host's stop may repeat; a bind never does.
        let mut binds: Vec<String> = Vec::new();
        let mut readies = 0usize;
        let mut observed = false;
        // Roles as the agent sees them: started, or stopped by a park, a
        // shutdown or a rebind.
        let mut roles_up = false;
        for (op, refuse) in ops {
            let stopping_before = matches!(m.daemon(), DaemonState::Stopping(_));
            let rebind_stop_before =
                matches!(m.daemon(), DaemonState::Stopping(StopReason::Bind(_)));
            let running_before = m.daemon() == &DaemonState::Running;
            let bound_before = w.bound.clone();
            let input = match &op {
                Op::Observe(n) => {
                    w.metadata = n.map(id);
                    Input::Observed(Observation {
                        instance_id: n.map(id),
                        bake_id: w.bake.clone(),
                        bound_id: w.bound.clone(),
                        clone_signal: false,
                    })
                }
                Op::SetBake(n) => {
                    w.bake = n.map(id);
                    continue;
                }
                Op::DaemonExit(lived_ms) => {
                    // The platform reports exits only of a live process.
                    if !matches!(m.daemon(), DaemonState::Running | DaemonState::Stopping(_)) {
                        continue;
                    }
                    Input::DaemonExited { lived_ms: *lived_ms }
                }
                Op::StopDeadline => Input::StopDeadline,
                Op::BackoffElapsed => Input::BackoffElapsed,
                Op::RearmElapsed => Input::RearmElapsed,
                Op::Resume => Input::ResumeSignal,
                Op::AnnounceDone => Input::AnnounceDone,
            };
            let raw = m.step(input);
            // P2-2: a timer or a crash never spawns by itself (an exit that
            // ends a stop may run the observation deferred during it).
            let crash = matches!(op, Op::DaemonExit(_)) && running_before;
            if crash || matches!(op, Op::BackoffElapsed | Op::StopDeadline) {
                prop_assert!(!raw.contains(&Action::SpawnDaemon), "{raw:?}");
            }
            // Answer like the agent: commits (or a failure), role parks and
            // rechecks, each before anything else.
            let mut actions = Vec::new();
            let mut pending = raw;
            loop {
                let mut next = None;
                for action in &pending {
                    match action {
                        Action::CommitBind(id) => {
                            next = Some(if refuse {
                                Input::BindFailed(id.clone())
                            } else {
                                Input::BindCommitted(id.clone())
                            });
                        }
                        Action::ParkRoles => next = Some(Input::RolesParked { ok: !refuse }),
                        Action::Recheck => {
                            next = Some(Input::Observed(Observation {
                                instance_id: w.metadata.clone(),
                                bake_id: w.bake.clone(),
                                bound_id: w.bound.clone(),
                                clone_signal: false,
                            }));
                        }
                        _ => {}
                    }
                }
                // The guarded group stops at a failure: drop the write.
                if refuse && pending.iter().any(|a| matches!(a, Action::CommitBind(_))) {
                    pending.retain(|a| !matches!(a, Action::WriteBound(_)));
                }
                actions.extend(pending);
                let Some(input) = next else { break };
                let answered = m.step(input.clone());
                if let Input::BindFailed(_) = input {
                    prop_assert!(!answered.contains(&Action::SpawnDaemon), "{answered:?}");
                    prop_assert_ne!(m.daemon(), &DaemonState::Running);
                }
                pending = answered;
            }
            readies += actions.iter().filter(|a| **a == Action::Ready).count();
            observed |= matches!(op, Op::Observe(_));
            // Re-review P2-b: READY once, on every path, from the first
            // observation on.
            prop_assert!(readies <= 1);
            if observed {
                prop_assert_eq!(readies, 1, "{:?}", actions);
            }
            let step_reseeds: Vec<&String> = actions
                .iter()
                .filter_map(|a| if let Action::Reseed(x) = a { Some(x) } else { None })
                .collect();
            prop_assert!(step_reseeds.len() <= 1, "{actions:?}");
            // Security review P2-2: no Resumed and no announce while a bind
            // waits for the old session host to exit.
            if matches!(op, Op::Resume) && rebind_stop_before {
                let resumed = actions.iter().any(|a| {
                    matches!(a, Action::Notify(Lifecycle::Resumed) | Action::Announce)
                });
                prop_assert!(!resumed, "{actions:?}");
            }
            for action in &actions {
                match action {
                    Action::StartRoles(_) => roles_up = true,
                    Action::ParkRoles | Action::ShutdownRoles => roles_up = false,
                    other if other.name() == "stop-roles" => roles_up = false,
                    Action::Notify(_) => {
                        prop_assert!(roles_up, "event to stopped roles: {actions:?}");
                    }
                    _ => {}
                }
                match action {
                    Action::Reseed(x) => {
                        // P2-2: roles never run while the identity changes.
                        prop_assert!(!roles_up, "roles run during a rebind: {actions:?}");
                        if matches!(op, Op::Observe(_)) {
                            prop_assert_ne!(Some(x), w.bake.as_ref(), "the bake id never binds");
                        }
                        prop_assert_ne!(Some(x), w.bound.as_ref(), "a bound id never rebinds");
                        last_reseed = Some(x.clone());
                    }
                    Action::WriteBound(x) => {
                        prop_assert_eq!(Some(x), last_reseed.as_ref(), "write-bound follows its own reseed");
                        w.bound = Some(x.clone());
                        binds.push(x.clone());
                    }
                    _ => {}
                }
            }
            // Empty metadata never binds.
            if let Op::Observe(None) = op {
                prop_assert!(!actions.iter().any(|a| matches!(a, Action::Reseed(_) | Action::WriteBound(_) | Action::DropRemoteIdentity)));
            }
            // A new id is detected in the very step that observes it.
            if let Op::Observe(Some(n)) = op {
                let x = id(n);
                let new_id = w.bake.as_deref() != Some(x.as_str()) && bound_before.as_deref() != Some(x.as_str());
                if new_id && !stopping_before {
                    if running_before {
                        prop_assert!(actions.contains(&Action::TerminateDaemon), "{actions:?}");
                    } else {
                        prop_assert_eq!(step_reseeds, vec![&x]);
                    }
                }
            }
            // Parked never spawns.
            if m.is_parked() {
                prop_assert!(!actions.contains(&Action::SpawnDaemon), "{actions:?}");
            }
            // Drop identity always comes before the spawn of the same bind.
            if let (Some(drop), Some(spawn)) = (
                actions.iter().position(|a| *a == Action::DropRemoteIdentity),
                actions.iter().position(|a| *a == Action::SpawnDaemon),
            ) {
                prop_assert!(drop < spawn);
            }
        }
        // Clone detected exactly once per new id: no id is bound twice in a
        // row.
        for pair in binds.windows(2) {
            prop_assert_ne!(&pair[0], &pair[1]);
        }
    }

    #[test]
    fn crash_loops_back_off_to_the_cap(lives in proptest::collection::vec(0u64..HEALTHY_RUN_MS, 1..40)) {
        let mut m = Machine::new();
        m.step(Input::Observed(Observation::default()));
        let mut delays = Vec::new();
        let mut immediate_in_a_row = 0;
        for lived_ms in lives {
            let actions = m.step(Input::DaemonExited { lived_ms });
            match actions.as_slice() {
                [Action::Recheck] => {
                    immediate_in_a_row += 1;
                    prop_assert!(immediate_in_a_row <= 1, "only the first fast exit restarts at once");
                    let spawn = m.step(Input::Observed(Observation::default()));
                    prop_assert_eq!(spawn, vec![Action::SpawnDaemon]);
                }
                [Action::ArmBackoff(ms)] => {
                    delays.push(*ms);
                    prop_assert_eq!(m.step(Input::BackoffElapsed), vec![Action::Recheck]);
                    let spawn = m.step(Input::Observed(Observation::default()));
                    prop_assert_eq!(spawn, vec![Action::SpawnDaemon]);
                }
                other => prop_assert!(false, "unexpected {:?}", other),
            }
        }
        for pair in delays.windows(2) {
            prop_assert!(pair[0] <= pair[1]);
        }
        prop_assert!(delays.iter().all(|d| *d > 0 && *d <= MAX_BACKOFF_MS));
    }

    #[test]
    fn ecanceled_storms_terminate(storm in 0u32..500, max in 1u32..100) {
        let mut left = storm;
        let mut drains = 0u32;
        let mut calls = 0u32;
        let outcome = rearm_bounded(
            max,
            || {
                calls += 1;
                if left == 0 { Ok(()) } else { left -= 1; Err(ArmError::Cancelled) }
            },
            || drains += 1,
        );
        prop_assert!(calls <= max);
        if storm < max {
            prop_assert_eq!(outcome, RearmOutcome::Armed { attempts: storm + 1 });
            prop_assert_eq!(drains, storm);
        } else {
            prop_assert_eq!(outcome, RearmOutcome::GaveUp { attempts: max, last: ArmError::Cancelled });
            prop_assert_eq!(drains, max);
        }
    }
}
