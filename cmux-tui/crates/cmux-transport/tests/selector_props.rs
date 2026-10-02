//! Property tests for the path selector (plans/cmux-next/transport.md 15).

use cmux_transport::{PathClass, PathId, PathKind, PathState, ProbeOutcome, Selector, SelectorConfig};
use proptest::prelude::*;

#[derive(Debug, Clone)]
enum Event {
    Answer { path: u16, rtt_us: u64 },
    Lose { path: u16 },
    NetworkChange,
    Remove { path: u16 },
}

const PATHS: u16 = 5;

fn kind_of(id: u16) -> PathKind {
    PathKind::ALL[usize::from(id) % PathKind::ALL.len()]
}

fn event() -> impl Strategy<Value = Event> {
    prop_oneof![
        6 => (0..PATHS, 500u64..200_000).prop_map(|(path, rtt_us)| Event::Answer { path, rtt_us }),
        3 => (0..PATHS).prop_map(|path| Event::Lose { path }),
        1 => Just(Event::NetworkChange),
        1 => (0..PATHS).prop_map(|path| Event::Remove { path }),
    ]
}

fn selector_with_all_paths(config: SelectorConfig) -> Selector {
    let mut selector = Selector::new(config);
    for id in 0..PATHS {
        selector.add_path(PathId(id), kind_of(id)).expect("fresh ids");
    }
    selector
}

/// The invariants every state must satisfy.
fn check_invariants(selector: &Selector) {
    let alive: Vec<_> = selector.paths().filter(|path| path.state == PathState::Alive).collect();
    match selector.current() {
        None => assert!(alive.is_empty(), "an alive path exists but nothing is selected"),
        Some(current) => {
            let view = selector.path(current).expect("current path exists");
            assert_eq!(view.state, PathState::Alive, "current path {current:?} is not alive");
            if alive.iter().any(|path| path.kind.class() == PathClass::Direct) {
                assert_eq!(view.kind.class(), PathClass::Direct, "a relay is used while a direct path is alive");
            }
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2_000))]

    /// I1-I3: the current path is always alive, something is selected
    /// whenever anything is alive, and direct beats relays.
    #[test]
    fn invariants_hold_after_every_event(events in proptest::collection::vec(event(), 0..200)) {
        let mut selector = selector_with_all_paths(SelectorConfig::default());
        let mut removed = std::collections::BTreeSet::new();
        for event in events {
            match event {
                Event::Answer { path, rtt_us } if !removed.contains(&path) => {
                    selector.on_probe(PathId(path), ProbeOutcome::Answered { rtt_us }).expect("known path");
                }
                Event::Lose { path } if !removed.contains(&path) => {
                    selector.on_probe(PathId(path), ProbeOutcome::Lost).expect("known path");
                }
                Event::NetworkChange => {
                    selector.on_network_change();
                }
                Event::Remove { path } if removed.insert(path) => {
                    selector.remove_path(PathId(path)).expect("known path");
                }
                _ => {}
            }
            check_invariants(&selector);
        }
    }

    /// I4 (no flapping): two same-class paths whose answers always stay
    /// inside the hysteresis margin of each other never switch after the
    /// first selection.
    #[test]
    fn jitter_inside_the_margin_never_switches(
        base in 5_000u64..100_000,
        samples in proptest::collection::vec((any::<bool>(), 0u64..1_000), 1..300),
    ) {
        let config = SelectorConfig::default();
        let mut selector = Selector::new(config);
        selector.add_path(PathId(0), PathKind::ViaCloudRegion).expect("fresh");
        selector.add_path(PathId(1), PathKind::DoRelay).expect("fresh");
        selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: base }).expect("known");
        selector.on_probe(PathId(1), ProbeOutcome::Answered { rtt_us: base }).expect("known");
        let first = selector.current();
        prop_assert!(first.is_some());
        // Jitter below 1 ms keeps every smoothed RTT within 1 ms of the
        // others, below the 3 ms minimum margin.
        for (which, jitter) in samples {
            let path = PathId(u16::from(which));
            selector.on_probe(path, ProbeOutcome::Answered { rtt_us: base + jitter }).expect("known");
            prop_assert_eq!(selector.current(), first);
        }
    }

    /// I5 (convergence): when one same-class path is steadily faster by more
    /// than the margin, the selector moves to it within a bounded number of
    /// answers.
    #[test]
    fn a_steadily_faster_path_wins(slow in 20_000u64..200_000, gain_percent in 20u64..80) {
        let fast = slow - slow * gain_percent / 100;
        let mut selector = Selector::new(SelectorConfig::default());
        selector.add_path(PathId(0), PathKind::DoRelay).expect("fresh");
        selector.add_path(PathId(1), PathKind::ViaCloudRegion).expect("fresh");
        selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: slow }).expect("known");
        prop_assert_eq!(selector.current(), Some(PathId(0)));
        for _ in 0..20 {
            selector.on_probe(PathId(1), ProbeOutcome::Answered { rtt_us: fast }).expect("known");
            selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: slow }).expect("known");
        }
        prop_assert_eq!(selector.current(), Some(PathId(1)));
    }
}

#[test]
fn direct_path_wins_at_once_over_a_faster_relay() {
    let mut selector = Selector::new(SelectorConfig::default());
    selector.add_path(PathId(0), PathKind::DoRelay).expect("fresh");
    selector.add_path(PathId(1), PathKind::DirectWan).expect("fresh");
    selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: 10_000 }).expect("known");
    let switch = selector.on_probe(PathId(1), ProbeOutcome::Answered { rtt_us: 40_000 }).expect("known");
    assert_eq!(switch.map(|switch| switch.to), Some(Some(PathId(1))));
}

#[test]
fn network_change_keeps_the_relay_and_reprobes_direct() {
    let mut selector = Selector::new(SelectorConfig::default());
    selector.add_path(PathId(0), PathKind::DirectLan).expect("fresh");
    selector.add_path(PathId(1), PathKind::DoRelay).expect("fresh");
    selector.on_probe(PathId(1), ProbeOutcome::Answered { rtt_us: 30_000 }).expect("known");
    selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: 2_000 }).expect("known");
    assert_eq!(selector.current(), Some(PathId(0)));
    selector.on_network_change();
    assert_eq!(selector.current(), Some(PathId(1)));
    assert_eq!(selector.path(PathId(0)).map(|path| path.state), Some(PathState::Probing));
    selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: 3_000 }).expect("known");
    assert_eq!(selector.current(), Some(PathId(0)));
}

#[test]
fn losing_every_path_returns_to_spraying() {
    let mut selector = Selector::new(SelectorConfig::default());
    selector.add_path(PathId(0), PathKind::DoRelay).expect("fresh");
    selector.on_probe(PathId(0), ProbeOutcome::Answered { rtt_us: 30_000 }).expect("known");
    for _ in 0..2 {
        selector.on_probe(PathId(0), ProbeOutcome::Lost).expect("known");
        assert_eq!(selector.current(), Some(PathId(0)), "two losses keep the path");
    }
    let switch = selector.on_probe(PathId(0), ProbeOutcome::Lost).expect("known");
    assert_eq!(switch.map(|switch| switch.to), Some(None));
    assert_eq!(selector.path(PathId(0)).map(|path| path.state), Some(PathState::Dead));
}
