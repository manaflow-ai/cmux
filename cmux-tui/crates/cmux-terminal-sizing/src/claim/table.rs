//! The table's samples, and [`table`]: every phase against every event as data.

#[cfg(test)]
use super::{
    CLAIM_ANSWER_WINDOW_MS, Effect, LEASE_REFRESH_V1_MS, LEASE_REFRESH_V2_MS, MODES,
    RECLAIM_WAIT_MS, RELEASE_DEBOUNCE_MS, RESIZE_SETTLE_MS, Refusal, step,
};
use super::{Claim, Event, Generation, Lease, Pending, SizeClaim, Timer};
use crate::TerminalGridSize;

/// The generation the table's sample states run their timers under.
pub const SAMPLE: Generation = Generation(7);

/// One claim per phase, in [`Claim::KINDS`] order, in a context that phase can be in.
pub fn sample_states() -> [SizeClaim; 6] {
    let grid = TerminalGridSize::new(50, 20);
    let g = SAMPLE;
    let claimed = |claim| SizeClaim {
        claim,
        page_shown: true,
        foreground: true,
        link: Some(Lease::V2),
        grid: Some(grid),
        settling: Some(Pending { grid: TerminalGridSize::new(60, 20), timer: g }),
        host: Some(grid),
        release_timer: None,
        lease_timer: Some(g),
        issued: g,
    };
    let released = SizeClaim {
        page_shown: false,
        lease_timer: None,
        host: Some(TerminalGridSize::new(120, 40)),
        ..claimed(Claim::Released)
    };
    let unsent = SizeClaim { link: None, lease_timer: None, host: None, ..claimed(Claim::Unsent) };
    [
        released,
        unsent,
        SizeClaim {
            host: Some(TerminalGridSize::new(120, 40)),
            ..claimed(Claim::AwaitingAnswer { grid, asked: g })
        },
        claimed(Claim::Claimed { grid }),
        SizeClaim {
            host: Some(TerminalGridSize::new(120, 40)),
            ..claimed(Claim::Reclaiming { grid, asked: g })
        },
        SizeClaim {
            host: Some(TerminalGridSize::new(120, 40)),
            ..claimed(Claim::HostKeeps { grid })
        },
    ]
}

/// One event per kind, in [`Event::KINDS`] order; timers carry `generation`.
pub fn sample_events(generation: Generation) -> [Event; 15] {
    let fired = |timer| Event::TimerFired { timer, generation };
    [
        Event::PageShown,
        Event::PageLeft,
        Event::Foreground,
        Event::Background,
        Event::Measured { grid: TerminalGridSize::new(70, 30) },
        Event::HostGrid { grid: TerminalGridSize::new(100, 30) },
        fired(Timer::Release),
        fired(Timer::Settle),
        fired(Timer::Answer),
        fired(Timer::Reclaim),
        fired(Timer::Lease),
        Event::LinkUp { lease: Lease::V2 },
        Event::LinkDown,
        Event::ModeChanged,
        Event::Stop,
    ]
}

/// The whole table as data: every phase against every event under each mode, each a transition
/// (the phase it moves to and its effects' kinds) or a named refusal. Test-only: the crate
/// depends on serde alone (every host links it), and the table is rendered by its test.
#[cfg(test)]
pub fn table() -> serde_json::Value {
    use serde_json::json;
    let mut rows = Vec::new();
    for mode in MODES {
        for state in sample_states() {
            for event in sample_events(SAMPLE) {
                rows.push(match step(state, mode, event) {
                    Ok(next) => json!({
                        "mode": mode.as_str(),
                        "from": state.claim.kind(),
                        "event": event.kind(),
                        "to": next.state.claim.kind(),
                        "effects": next.effects.iter().map(Effect::kind).collect::<Vec<_>>(),
                    }),
                    Err(refusal) => json!({
                        "mode": mode.as_str(),
                        "from": state.claim.kind(),
                        "event": event.kind(),
                        "refusal": refusal.as_str(),
                    }),
                });
            }
        }
    }
    json!({
        "version": 1,
        "source": "cmux-tui/crates/cmux-terminal-sizing/src/claim.rs",
        "contract": "cmux-next-ios/PROTOCOL.md, Terminal size claims",
        "context": "Each phase's sample: shown, foreground, linked under size-lease-v2 with the phone's 50x20 measured, 60x20 settling and the lease timer running where it claims; released is the page left with no timers; unsent has no link; awaiting_answer, reclaiming and host_keeps see the Mac at 120x40. measured is 70x30, host_grid is 100x30.",
        "stale": "A timer whose kind is not running is refused not_armed; one running under another generation is refused stale_generation. A refusal leaves the claim unchanged.",
        "timers_ms": {
            "release": RELEASE_DEBOUNCE_MS,
            "settle": RESIZE_SETTLE_MS,
            "answer": CLAIM_ANSWER_WINDOW_MS,
            "reclaim": RECLAIM_WAIT_MS,
            "lease_v1": LEASE_REFRESH_V1_MS,
            "lease_v2": LEASE_REFRESH_V2_MS,
        },
        "states": Claim::KINDS,
        "events": Event::KINDS,
        "refusals": Refusal::ALL.map(Refusal::as_str),
        "transitions": rows,
    })
}
