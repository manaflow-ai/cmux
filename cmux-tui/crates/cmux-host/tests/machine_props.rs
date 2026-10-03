//! Property tests of the bind state machine and the retry rules.

use cmux_host::machine::{Action, DaemonState, HEALTHY_RUN_MS, Input, Machine, Observation};
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
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    #[test]
    fn bind_rules_hold_for_any_event_sequence(ops in proptest::collection::vec(op(), 1..80)) {
        let mut m = Machine::new();
        let mut w = World::default();
        let mut last_reseed: Option<String> = None;
        let mut reseeds: Vec<String> = Vec::new();
        for op in ops {
            let stopping_before = matches!(m.daemon(), DaemonState::Stopping(_));
            let bound_before = w.bound.clone();
            let input = match &op {
                Op::Observe(n) => Input::Observed(Observation {
                    instance_id: n.map(id),
                    bake_id: w.bake.clone(),
                    bound_id: w.bound.clone(),
                }),
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
            let actions = m.step(input);
            let step_reseeds: Vec<&String> = actions
                .iter()
                .filter_map(|a| if let Action::Reseed(x) = a { Some(x) } else { None })
                .collect();
            prop_assert!(step_reseeds.len() <= 1, "{actions:?}");
            for action in &actions {
                match action {
                    Action::Reseed(x) => {
                        if matches!(op, Op::Observe(_)) {
                            prop_assert_ne!(Some(x), w.bake.as_ref(), "the bake id never binds");
                        }
                        prop_assert_ne!(Some(x), w.bound.as_ref(), "a bound id never rebinds");
                        last_reseed = Some(x.clone());
                        reseeds.push(x.clone());
                    }
                    Action::WriteBound(x) => {
                        prop_assert_eq!(Some(x), last_reseed.as_ref(), "write-bound follows its own reseed");
                        w.bound = Some(x.clone());
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
                if !stopping_before && w.bake.as_deref() != Some(x.as_str()) && bound_before.as_deref() != Some(x.as_str()) {
                    prop_assert_eq!(step_reseeds, vec![&x]);
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
        // Clone detected exactly once per new id: no id is reseeded twice
        // in a row.
        for pair in reseeds.windows(2) {
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
                [Action::SpawnDaemon] => {
                    immediate_in_a_row += 1;
                    prop_assert!(immediate_in_a_row <= 1, "only the first fast exit restarts at once");
                }
                [Action::ArmBackoff(ms)] => {
                    delays.push(*ms);
                    prop_assert_eq!(m.step(Input::BackoffElapsed), vec![Action::SpawnDaemon]);
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
