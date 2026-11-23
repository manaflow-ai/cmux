//! Every phase against every event, and seeded random walks, on the invariants: (a) under
//! KeepHostSize nothing claims, (b) a duplicate measured grid never re-sends, (c) the background
//! ends in an immediate release, (d) a release only follows a claim, (e) a stale timer or
//! answer changes nothing. And the committed table is current.

use std::path::PathBuf;

use super::super::*;
use super::{G, MAC};

fn resizes(effects: &[Effect]) -> usize {
    effects.iter().filter(|e| matches!(e, Effect::SendResize { .. })).count()
}

fn check(before: &SizeClaim, mode: Mode, event: Event, result: &Result<Step, Refusal>) {
    let ctx = || format!("{} under {mode:?} on {event:?}", before.claim.kind());
    // (e) A timer fires only under the generation it runs under.
    if let Event::TimerFired { timer, generation } = event {
        let current = before.armed(timer) == Some(generation);
        assert_eq!(result.is_ok(), current, "{}: {result:?}", ctx());
    }
    let next = match result {
        Ok(next) => next,
        Err(Refusal::EmptyGrid) => {
            assert!(matches!(event, Event::Measured { grid } if grid.cols == 0 || grid.rows == 0));
            return;
        }
        Err(_) => return,
    };
    let fx = &next.effects;
    // (a) Under KeepHostSize nothing claims.
    if mode == Mode::KeepHostSize {
        assert_eq!(resizes(fx), 0, "{}: {fx:?}", ctx());
    }
    // (b) A duplicate measured grid never re-sends nor restarts the settle.
    if let Event::Measured { grid } = event
        && (before.grid == Some(grid) || before.settling.map(|p| p.grid) == Some(grid))
    {
        assert_eq!(resizes(fx), 0, "{}", ctx());
        assert!(
            !fx.iter().any(|e| matches!(e, Effect::StartTimer { timer: Timer::Settle, .. })),
            "{}",
            ctx()
        );
    }
    // (c) The background ends in an immediate release.
    if event == Event::Background {
        assert_eq!(next.state.claim, Claim::Released, "{}", ctx());
        assert_eq!(next.state.release_timer, None, "{}", ctx());
        assert_eq!(fx.contains(&Effect::SendRelease), before.claim.at_mac().is_some(), "{}", ctx());
    }
    // (d) A release only follows a claim, once.
    let releases = fx.iter().filter(|e| **e == Effect::SendRelease).count();
    assert!(releases <= usize::from(before.claim.at_mac().is_some()), "{}: {fx:?}", ctx());
    // (e) The Mac's grid where nothing is claimed, or another one inside the window, changes nothing.
    if let Event::HostGrid { grid } = event {
        let stale = match before.claim {
            Claim::Released | Claim::Unsent => true,
            Claim::AwaitingAnswer { grid: asked, .. } => asked != grid,
            Claim::Claimed { .. } | Claim::Reclaiming { .. } | Claim::HostKeeps { .. } => false,
        };
        if stale {
            assert!(fx.is_empty(), "{}: {fx:?}", ctx());
            assert_eq!(next.state.claim, before.claim, "{}", ctx());
        }
    }
    // Timers start under fresh generations, and what runs is what the state says runs.
    for effect in fx {
        if let Effect::StartTimer { generation, .. } = effect {
            assert!(*generation > before.issued && *generation <= next.state.issued, "{}", ctx());
        }
    }
    for timer in Timer::ALL {
        if let Some(armed) = next.state.armed(timer) {
            assert!(armed <= next.state.issued, "{}", ctx());
        }
    }
    if next.state.claim == Claim::Released {
        assert_eq!(next.state.lease_timer, None, "{}", ctx());
    }
}

#[test]
fn every_state_against_every_event_is_decided() {
    let mut decided = 0;
    for mode in MODES {
        for state in sample_states() {
            for generation in [Generation(SAMPLE.0 - 1), SAMPLE, Generation(SAMPLE.0 + 1)] {
                for event in sample_events(generation) {
                    let result = step(state, mode, event);
                    check(&state, mode, event, &result);
                    if result.is_ok() {
                        decided += 1;
                    }
                }
            }
        }
    }
    assert!(decided > 0);
    let table = table();
    let rows = table["transitions"].as_array().map(Vec::len);
    assert_eq!(rows, Some(MODES.len() * Claim::KINDS.len() * Event::KINDS.len()));
}

#[test]
fn every_phase_and_event_has_a_sample() {
    let states: Vec<_> = sample_states().iter().map(|s| s.claim.kind()).collect();
    assert_eq!(states, Claim::KINDS);
    let events: Vec<_> = sample_events(SAMPLE).iter().map(Event::kind).collect();
    assert_eq!(events, Event::KINDS);
}

#[test]
fn an_empty_grid_is_refused() {
    let state = SizeClaim::open(Mode::Fit).state;
    let empty = Event::Measured { grid: TerminalGridSize::new(0, 20) };
    assert_eq!(step(state, Mode::Fit, empty), Err(Refusal::EmptyGrid));
}

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn random_event(rng: &mut Rng, state: &SizeClaim) -> Event {
    const GRIDS: [TerminalGridSize; 4] =
        [G, TerminalGridSize::new(60, 40), TerminalGridSize::new(50, 20), MAC];
    let grid = GRIDS[rng.below(GRIDS.len())];
    match rng.below(14) {
        0 => Event::PageShown,
        1 => Event::PageLeft,
        2 => Event::Foreground,
        3 => Event::Background,
        4 if rng.below(20) == 0 => Event::Measured { grid: TerminalGridSize::new(0, 0) },
        4 | 5 => Event::Measured { grid },
        6 | 7 => Event::HostGrid { grid },
        8..=10 => {
            let timer = Timer::ALL[rng.below(Timer::ALL.len())];
            let armed = state.armed(timer).unwrap_or(state.issued);
            let generation = match rng.below(4) {
                0 => Generation(armed.0.saturating_sub(1)),
                1 => state.issued,
                2 => Generation(state.issued.0 + 1),
                _ => armed,
            };
            Event::TimerFired { timer, generation }
        }
        11 => Event::LinkUp { lease: [Lease::None, Lease::V1, Lease::V2][rng.below(3)] },
        12 => Event::LinkDown,
        _ if rng.below(2) == 0 => Event::ModeChanged,
        _ => Event::Stop,
    }
}

#[test]
fn random_walks_keep_the_invariants() {
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    for _ in 0..4_000 {
        let mut mode = MODES[rng.below(MODES.len())];
        let mut state = SizeClaim::open(mode).state;
        // The Mac holds a size from this phone: set by a claim, cleared by a release or a new link.
        let mut held = false;
        for _ in 0..12 {
            let event = random_event(&mut rng, &state);
            if event == Event::ModeChanged {
                mode = if mode == Mode::Fit { Mode::KeepHostSize } else { Mode::Fit };
            }
            let result = step(state, mode, event);
            check(&state, mode, event, &result);
            let Ok(next) = result else { continue };
            if matches!(event, Event::LinkUp { .. } | Event::LinkDown) {
                held = false;
            }
            for effect in &next.effects {
                match effect {
                    Effect::SendResize { .. } => held = true,
                    Effect::SendRelease => {
                        assert!(held, "a release with no claim before it: {event:?}");
                        held = false;
                    }
                    Effect::RefreshLease { .. } => {
                        assert!(held, "a refresh with no claim: {event:?}");
                    }
                    Effect::StartTimer { .. } | Effect::CancelTimer { .. } => {}
                }
            }
            assert_eq!(
                held,
                next.state.claim.at_mac().is_some(),
                "{event:?} -> {:?}",
                next.state.claim
            );
            if mode == Mode::KeepHostSize {
                assert_eq!(next.state.claim, Claim::Released, "{event:?} under KeepHostSize");
            }
            state = next.state;
        }
    }
}

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/terminal-size-claim/table.json")
}

fn rendered() -> String {
    let mut text = serde_json::to_string_pretty(&table()).unwrap_or_default();
    text.push('\n');
    text
}

#[test]
fn committed_table_is_current() {
    let path = table_path();
    if std::env::var_os("CMUX_UPDATE_TERMINAL_SIZE_CLAIM_TABLE").is_some() {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).expect("create the table's folder");
        }
        std::fs::write(&path, rendered()).expect("write the table");
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default();
    assert!(
        committed == rendered(),
        "{} is stale: CMUX_UPDATE_TERMINAL_SIZE_CLAIM_TABLE=1 cargo test -p cmux-terminal-sizing claim",
        path.display()
    );
}
