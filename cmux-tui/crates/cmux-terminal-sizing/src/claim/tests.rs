use super::*;

mod invariants;

pub(super) const G: TerminalGridSize = TerminalGridSize::new(54, 42);
pub(super) const MAC: TerminalGridSize = TerminalGridSize::new(120, 40);

/// The claim with a clock: runs the effects, fires due timers in order, logs the wire.
struct Sim {
    s: SizeClaim,
    mode: Mode,
    now: u64,
    timers: Vec<(Timer, Generation, u64)>,
    wire: Vec<String>,
    /// Each change of `claims()`, as `TerminalSizeClaimer` tells the session.
    told: Vec<bool>,
}

impl Sim {
    fn new(mode: Mode) -> Self {
        let first = SizeClaim::open(mode);
        let mut sim = Sim {
            s: first.state,
            mode,
            now: 0,
            timers: Vec::new(),
            wire: Vec::new(),
            told: Vec::new(),
        };
        sim.apply(first.effects);
        sim
    }

    /// A shown, foreground page attached under `lease` with `grid` measured (one claim out).
    fn session(lease: Lease, grid: TerminalGridSize) -> Self {
        let mut sim = Sim::new(Mode::Fit);
        sim.ev(Event::PageShown).ev(Event::LinkUp { lease }).ev(Event::Measured { grid });
        sim
    }

    fn ev(&mut self, event: Event) -> &mut Self {
        let claimed = self.s.claim.claims();
        let next = step(self.s, self.mode, event).unwrap_or_else(|r| panic!("{event:?}: {r}"));
        self.s = next.state;
        self.apply(next.effects);
        if self.s.claim.claims() != claimed {
            self.told.push(!claimed);
        }
        self
    }

    fn apply(&mut self, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::SendResize { grid } => {
                    self.wire.push(format!("resize {}x{}", grid.cols, grid.rows));
                }
                Effect::SendRelease => self.wire.push("release".into()),
                Effect::RefreshLease { grid } => {
                    self.wire.push(format!("refresh {}x{}", grid.cols, grid.rows));
                }
                Effect::StartTimer { timer, after_ms, generation } => {
                    self.timers.retain(|t| t.0 != timer);
                    self.timers.push((timer, generation, self.now + after_ms));
                }
                Effect::CancelTimer { timer } => self.timers.retain(|t| t.0 != timer),
            }
        }
    }

    fn advance(&mut self, ms: u64) -> &mut Self {
        let until = self.now + ms;
        loop {
            let due = self.timers.iter().copied().filter(|t| t.2 <= until).min_by_key(|t| t.2);
            let Some((timer, generation, at)) = due else { break };
            self.timers.retain(|t| t.0 != timer);
            self.now = at;
            self.ev(Event::TimerFired { timer, generation });
        }
        self.now = until;
        self
    }

    fn running(&self, timer: Timer) -> bool {
        self.timers.iter().any(|t| t.0 == timer)
    }

    fn take(&mut self) -> Vec<String> {
        std::mem::take(&mut self.wire)
    }
}

fn shown() -> Sim {
    let mut sim = Sim::new(Mode::Fit);
    sim.ev(Event::PageShown);
    sim
}

// TerminalSizeClaimDebounceTests (TerminalSizeClaimTests.swift).

#[test]
fn leaving_the_page_releases_after_the_delay() {
    let mut claim = shown();
    claim.ev(Event::PageLeft);
    assert!(
        claim.told.is_empty(),
        "released at once: a quick switch back would resize the Mac twice"
    );
    assert!(claim.running(Timer::Release));
    claim.advance(RELEASE_DEBOUNCE_MS - 1);
    assert!(claim.told.is_empty());
    claim.advance(1);
    assert_eq!(claim.told, [false]);
    assert!(!claim.s.claim.claims());
}

#[test]
fn coming_back_inside_the_delay_keeps_the_claim_without_a_change() {
    let mut claim = shown();
    claim.ev(Event::PageLeft).advance(300).ev(Event::PageShown);
    assert!(claim.told.is_empty());
    assert!(!claim.running(Timer::Release));
    claim.advance(2_000);
    assert!(claim.told.is_empty());
    assert!(claim.s.claim.claims());
}

#[test]
fn the_background_releases_at_once() {
    let mut claim = shown();
    claim.ev(Event::Background);
    assert_eq!(claim.told, [false]);
    assert!(!claim.running(Timer::Release));
}

#[test]
fn background_then_foreground_releases_then_claims_at_once() {
    let mut claim = shown();
    claim.advance(1_000).ev(Event::Background).advance(39_000).ev(Event::Foreground);
    claim.advance(1_000).ev(Event::Background).advance(1_000).ev(Event::Foreground);
    assert_eq!(claim.told, [false, true, false, true]);
    assert!(claim.s.claim.claims());
}

#[test]
fn a_background_during_a_pending_release_releases_at_once() {
    let mut claim = shown();
    claim.ev(Event::PageLeft).advance(100).ev(Event::Background);
    assert_eq!(claim.told, [false]);
}

#[test]
fn a_sheet_over_the_page_releases_and_its_dismissal_claims_again() {
    // `covered` is PageLeft here: the caller folds a sheet of the page's own into it.
    let mut claim = shown();
    claim.ev(Event::PageLeft).advance(1_000);
    assert_eq!(claim.told, [false]);
    claim.advance(4_000).ev(Event::PageShown);
    assert_eq!(claim.told, [false, true]);
}

#[test]
fn the_foreground_claims_at_once_when_the_page_is_shown() {
    let mut claim = shown();
    claim.ev(Event::Background).advance(1).ev(Event::Foreground);
    assert_eq!(claim.told, [false, true]);
}

#[test]
fn a_page_never_shown_releases_after_the_delay() {
    let mut claim = Sim::new(Mode::Fit);
    assert!(claim.told.is_empty());
    claim.advance(RELEASE_DEBOUNCE_MS);
    assert_eq!(claim.told, [false]);
}

// TerminalSizeClaimerTests (TerminalSizeClaimTests.swift).

#[test]
fn the_claimer_tells_the_session_after_the_delay() {
    let mut claim = Sim::new(Mode::Fit);
    claim.ev(Event::PageShown).ev(Event::PageLeft);
    assert!(claim.told.is_empty());
    claim.advance(RELEASE_DEBOUNCE_MS);
    assert_eq!(claim.told, [false]);
    claim.ev(Event::PageShown);
    assert_eq!(claim.told, [false, true]);
    claim.ev(Event::Background);
    assert_eq!(claim.told, [false, true, false]);
    claim.ev(Event::Foreground);
    assert_eq!(claim.told, [false, true, false, true]);
}

#[test]
fn a_claimer_whose_page_never_shows_releases() {
    let mut claim = Sim::new(Mode::Fit);
    claim.advance(5_000);
    assert_eq!(claim.told, [false]);
}

#[test]
fn a_quick_switch_back_sends_nothing() {
    let mut claim = Sim::new(Mode::Fit);
    claim.ev(Event::PageShown);
    for _ in 0..5 {
        claim.ev(Event::PageLeft).ev(Event::PageShown);
    }
    claim.advance(2_000);
    assert!(claim.told.is_empty());
}

// TerminalGridSizingTests and TerminalResizeSettleTests (TerminalGridSizingTests.swift).

#[test]
fn showing_and_closing_the_keyboard_sends_no_resize() {
    // The keyboard moves nothing here: the measured grid is the keyboard-down one.
    let portrait = TerminalGridSize::new(53, 37);
    let mut page = Sim::session(Lease::None, portrait);
    assert_eq!(page.take(), ["resize 53x37"]);
    for _ in 0..4 {
        page.ev(Event::Measured { grid: portrait });
    }
    assert!(page.s.settling.is_none());
    page.advance(RESIZE_SETTLE_MS * 4);
    assert!(page.take().is_empty());
}

#[test]
fn a_rotation_sends_exactly_one_debounced_resize() {
    let mut page = Sim::session(Lease::None, TerminalGridSize::new(53, 37));
    page.take();
    let landscape = TerminalGridSize::new(104, 18);
    for pass in [TerminalGridSize::new(80, 28), landscape, landscape] {
        page.ev(Event::Measured { grid: pass });
    }
    assert!(page.take().is_empty(), "each measured change restarts the wait; nothing is sent");
    page.advance(RESIZE_SETTLE_MS);
    assert_eq!(page.take(), ["resize 104x18"]);
    page.ev(Event::Measured { grid: landscape }).advance(RESIZE_SETTLE_MS);
    assert!(page.take().is_empty());
}

#[test]
fn the_first_size_goes_at_once() {
    let mut page = Sim::session(Lease::None, TerminalGridSize::new(53, 42));
    assert_eq!(page.take(), ["resize 53x42"]);
}

#[test]
fn a_size_that_reverts_within_the_settle_is_never_sent() {
    let mut page = Sim::session(Lease::None, TerminalGridSize::new(53, 42));
    page.take();
    page.ev(Event::Measured { grid: TerminalGridSize::new(53, 39) });
    assert!(page.running(Timer::Settle));
    page.ev(Event::Measured { grid: TerminalGridSize::new(53, 42) });
    assert!(!page.running(Timer::Settle));
    page.advance(RESIZE_SETTLE_MS);
    assert!(page.take().is_empty());
}

#[test]
fn a_size_that_holds_is_sent_once() {
    let mut page = Sim::session(Lease::None, TerminalGridSize::new(53, 42));
    page.take();
    let held = TerminalGridSize::new(53, 24);
    page.ev(Event::Measured { grid: held }).ev(Event::Measured { grid: held });
    page.advance(RESIZE_SETTLE_MS);
    assert_eq!(page.take(), ["resize 53x24"]);
    page.ev(Event::Measured { grid: held }).advance(RESIZE_SETTLE_MS);
    assert!(page.take().is_empty());
}

// DaemonTerminalSizeClaimTests ("hidden" is the session told not to claim: Background).

#[test]
fn a_hidden_terminal_releases_its_size() {
    let mut session = Sim::session(Lease::None, G);
    session.ev(Event::Background).ev(Event::Background);
    assert_eq!(session.take(), ["resize 54x42", "release"]);
}

#[test]
fn a_hidden_terminal_sends_no_size_and_claims_it_when_shown() {
    let mut session = Sim::session(Lease::None, G);
    session.ev(Event::Background);
    session.ev(Event::Measured { grid: TerminalGridSize::new(60, 40) }).advance(RESIZE_SETTLE_MS);
    assert_eq!(session.take(), ["resize 54x42", "release"]);
    session.ev(Event::Foreground);
    assert_eq!(session.take(), ["resize 60x40"]);
}

#[test]
fn a_terminal_shown_again_claims_the_same_size_again() {
    let mut session = Sim::session(Lease::None, G);
    session.ev(Event::Background).ev(Event::Foreground);
    assert_eq!(session.take(), ["resize 54x42", "release", "resize 54x42"]);
}

#[test]
fn stopping_releases_the_size_before_the_channel_closes() {
    let mut session = Sim::session(Lease::V1, G);
    session.ev(Event::Stop);
    assert_eq!(session.take(), ["resize 54x42", "release"]);
    assert!(session.timers.is_empty());
    assert_eq!(session.s.link, None);
}

#[test]
fn a_hidden_terminal_reattaches_without_a_size() {
    let mut session = Sim::session(Lease::None, G);
    session.ev(Event::Background).ev(Event::LinkDown).ev(Event::LinkUp { lease: Lease::None });
    assert_eq!(
        session.take(),
        ["resize 54x42", "release"],
        "a hidden terminal's reattach claimed a size"
    );
}

#[test]
fn a_terminal_hidden_during_its_attach_releases_the_size_the_attach_carried() {
    let mut session = Sim::new(Mode::Fit);
    session.ev(Event::PageShown).ev(Event::Measured { grid: G });
    assert!(session.take().is_empty(), "no link: the size waits for the attach");
    session.ev(Event::LinkUp { lease: Lease::None });
    assert_eq!(session.take(), ["resize 54x42"], "the attach carried the size");
    session.ev(Event::Background);
    assert_eq!(session.take(), ["release"]);
}

#[test]
fn the_channel_opts_into_the_size_lease() {
    let session = Sim::session(Lease::V1, G);
    let lease = session.timers.iter().find(|t| t.0 == Timer::Lease).map(|t| t.2);
    assert_eq!(lease, Some(LEASE_REFRESH_V1_MS));
}

#[test]
fn a_shown_terminal_refreshes_its_size_lease_and_a_hidden_one_does_not() {
    let mut session = Sim::session(Lease::V1, G);
    session.ev(Event::HostGrid { grid: G }).advance(LEASE_REFRESH_V1_MS * 2);
    assert_eq!(session.take(), ["resize 54x42", "refresh 54x42", "refresh 54x42"]);
    session.ev(Event::Background);
    assert_eq!(session.take(), ["release"]);
    session.advance(LEASE_REFRESH_V1_MS * 4);
    assert!(session.take().is_empty(), "a hidden terminal refreshed its size");
}

#[test]
fn a_daemon_without_the_lease_gets_no_refresh() {
    let mut session = Sim::session(Lease::None, G);
    session.advance(LEASE_REFRESH_V1_MS * 4);
    assert_eq!(session.take(), ["resize 54x42"]);
}

// DaemonTerminalReclaimHoldTests: the claim side of the two that make one.

#[test]
fn a_claim_the_mac_overrules_shows_the_held_grid_after_the_wait() {
    let phone = TerminalGridSize::new(50, 20);
    let mut session = Sim::session(Lease::None, phone);
    session
        .ev(Event::HostGrid { grid: phone })
        .ev(Event::Background)
        .ev(Event::HostGrid { grid: MAC });
    session.ev(Event::Foreground);
    assert!(
        matches!(session.s.claim, Claim::AwaitingAnswer { .. }),
        "held while the claim may still be answered"
    );
    session.advance(CLAIM_ANSWER_WINDOW_MS);
    assert_eq!(session.s.claim, Claim::HostKeeps { grid: phone });
    assert_eq!(session.take(), ["resize 50x20", "release", "resize 50x20"]);
}

#[test]
fn a_page_that_is_shown_never_holds_the_macs_grid() {
    // No link: nothing claims the Mac's grid back, so the page shows it.
    let mut session = Sim::new(Mode::Fit);
    session.ev(Event::PageShown).ev(Event::Measured { grid: TerminalGridSize::new(50, 20) });
    session
        .ev(Event::HostGrid { grid: TerminalGridSize::new(50, 20) })
        .ev(Event::HostGrid { grid: MAC });
    assert_eq!(session.s.claim, Claim::Unsent);
    assert!(session.take().is_empty());
}

// DaemonTerminalShownGridTests.

fn attached_at_phone_grid() -> Sim {
    let phone = TerminalGridSize::new(50, 20);
    let mut session = Sim::session(Lease::None, phone);
    session
        .ev(Event::HostGrid { grid: TerminalGridSize::new(80, 24) })
        .ev(Event::HostGrid { grid: phone });
    assert_eq!(session.s.claim, Claim::Claimed { grid: phone });
    session.take();
    session
}

#[test]
fn a_shown_page_holds_a_grid_it_did_not_ask_for_and_claims_its_own_again() {
    let mut session = attached_at_phone_grid();
    session.ev(Event::HostGrid { grid: MAC });
    assert_eq!(session.take(), ["resize 50x20"]);
    session.ev(Event::HostGrid { grid: TerminalGridSize::new(50, 20) });
    assert_eq!(session.s.claim, Claim::Claimed { grid: TerminalGridSize::new(50, 20) });
    assert!(!session.running(Timer::Reclaim));
}

#[test]
fn a_grid_the_mac_keeps_shows_after_the_wait_and_its_later_changes_show_at_once() {
    let mut session = attached_at_phone_grid();
    session.ev(Event::HostGrid { grid: MAC }).advance(RECLAIM_WAIT_MS);
    assert_eq!(session.s.claim, Claim::HostKeeps { grid: TerminalGridSize::new(50, 20) });
    session.take();
    session.ev(Event::HostGrid { grid: TerminalGridSize::new(100, 30) });
    assert!(session.take().is_empty(), "the Mac's later changes are not claimed against");
}

#[test]
fn the_release_goes_out_while_a_resize_waits_for_its_answer() {
    let mut session = Sim::session(Lease::None, G);
    assert!(matches!(session.s.claim, Claim::AwaitingAnswer { .. }));
    session.ev(Event::Background);
    assert_eq!(session.take(), ["resize 54x42", "release"]);
    assert!(session.timers.is_empty());
}

#[test]
fn an_attachs_own_replay_of_the_macs_grid_sends_no_second_claim() {
    let mut session = Sim::new(Mode::Fit);
    session
        .ev(Event::PageShown)
        .ev(Event::Measured { grid: G })
        .ev(Event::LinkUp { lease: Lease::None });
    session.ev(Event::HostGrid { grid: TerminalGridSize::new(80, 24) });
    assert_eq!(session.take(), ["resize 54x42"], "a claim went out for the attach's own replay");
}

#[test]
fn shown_and_hidden_again_in_one_turn_sends_no_claim() {
    // Adapted: every claim here is followed by its release; folding a claim and its release
    // queued in one turn into nothing is the effect runner's outbox (the Swift's coalescing).
    let mut session = Sim::session(Lease::None, G);
    session.ev(Event::Background).ev(Event::Foreground).ev(Event::Background);
    session.ev(Event::Measured { grid: TerminalGridSize::new(60, 40) }).advance(RESIZE_SETTLE_MS);
    session.ev(Event::Foreground);
    let wire = session.take();
    assert_eq!(wire, ["resize 54x42", "release", "resize 54x42", "release", "resize 60x40"]);
    let claims: Vec<_> = wire.iter().filter(|w| w.starts_with("resize")).collect();
    assert_eq!(claims.last().map(|w| w.as_str()), Some("resize 60x40"));
}

#[test]
fn the_channel_lists_the_short_lease_and_refreshes_on_its_interval() {
    let mut session = Sim::session(Lease::V2, G);
    session.ev(Event::HostGrid { grid: G }).advance(LEASE_REFRESH_V2_MS * 2);
    assert_eq!(session.take(), ["resize 54x42", "refresh 54x42", "refresh 54x42"]);
}

#[test]
fn a_lease_refresh_does_not_wait_behind_an_unanswered_request() {
    let mut session = Sim::session(Lease::V2, G);
    session.advance(LEASE_REFRESH_V2_MS * 2);
    assert_eq!(session.take(), ["resize 54x42", "refresh 54x42", "refresh 54x42"]);
}

#[test]
fn keep_host_size_never_claims() {
    let mut session = Sim::new(Mode::KeepHostSize);
    session
        .ev(Event::PageShown)
        .ev(Event::LinkUp { lease: Lease::V2 })
        .ev(Event::Measured { grid: G });
    session.ev(Event::HostGrid { grid: MAC }).advance(LEASE_REFRESH_V2_MS * 3);
    assert!(session.take().is_empty());
    assert_eq!(session.s.claim, Claim::Released);
}

#[test]
fn switching_to_keep_host_size_releases_at_once() {
    let mut session = Sim::session(Lease::V2, G);
    session.mode = Mode::KeepHostSize;
    session.ev(Event::ModeChanged);
    assert_eq!(session.take(), ["resize 54x42", "release"]);
    assert!(session.timers.is_empty());
}
