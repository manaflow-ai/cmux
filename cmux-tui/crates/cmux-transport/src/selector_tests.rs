use super::*;

const LAN: PathId = PathId(0);
const LINK: PathId = PathId(1);
const RELAY: PathId = PathId(2);

fn answer(selector: &mut Selector, id: PathId, rtt_us: u64) -> Option<Switch> {
    selector.on_probe(id, ProbeOutcome::Answered { rtt_us }).unwrap()
}

fn lose(selector: &mut Selector, id: PathId) -> Option<Switch> {
    selector.on_probe(id, ProbeOutcome::Lost).unwrap()
}

/// Wired LAN, a Thunderbolt Bridge and a relay to the same peer.
fn three_paths() -> Selector {
    let mut selector = Selector::new(SelectorConfig::default());
    selector.add_path_on(LAN, PathKind::DirectLan, Medium::Lan).unwrap();
    selector.add_path_on(LINK, PathKind::DirectLan, Medium::Link).unwrap();
    selector.add_path(RELAY, PathKind::DoRelay).unwrap();
    selector
}

#[test]
fn a_thunderbolt_path_wins_at_once_though_the_rtt_margin_never_would() {
    let mut selector = three_paths();
    answer(&mut selector, LAN, 500);
    assert_eq!(selector.current(), Some(LAN));
    // 0.3 ms vs 0.5 ms is far inside the 3 ms hysteresis margin.
    let switch = answer(&mut selector, LINK, 300);
    assert_eq!(switch, Some(Switch { from: Some(LAN), to: Some(LINK) }));
    assert_eq!(selector.current(), Some(LINK));
}

#[test]
fn a_slower_lan_answer_never_unseats_the_link() {
    let mut selector = three_paths();
    answer(&mut selector, LINK, 900);
    for _ in 0..10 {
        assert_eq!(answer(&mut selector, LAN, 100), None);
    }
    assert_eq!(selector.current(), Some(LINK));
}

#[test]
fn a_lan_path_still_beats_the_relay_at_once() {
    let mut selector = three_paths();
    answer(&mut selector, RELAY, 40_000);
    assert_eq!(selector.current(), Some(RELAY));
    answer(&mut selector, LAN, 60_000);
    assert_eq!(selector.current(), Some(LAN), "class first, whatever the RTT");
}

#[test]
fn a_silent_current_path_sprays_until_it_answers() {
    let mut selector = three_paths();
    answer(&mut selector, RELAY, 40_000);
    answer(&mut selector, LINK, 300);
    assert_eq!(selector.current(), Some(LINK));
    let switch = selector.on_silence(LINK).unwrap();
    assert_eq!(switch, Some(Switch { from: Some(LINK), to: None }), "every path at once");
    assert_eq!(selector.chosen(), Some(LINK));
    let switch = answer(&mut selector, LINK, 300);
    assert_eq!(switch, Some(Switch { from: None, to: Some(LINK) }));
}

#[test]
fn a_dropped_fast_path_sprays_then_falls_back_when_it_dies() {
    let mut selector = three_paths();
    answer(&mut selector, RELAY, 40_000);
    answer(&mut selector, LINK, 300);
    assert_eq!(lose(&mut selector, LINK), Some(Switch { from: Some(LINK), to: None }));
    assert_eq!(lose(&mut selector, LINK), None, "still suspect: still every path");
    let switch = lose(&mut selector, LINK);
    assert_eq!(switch, Some(Switch { from: None, to: Some(RELAY) }));
    assert_eq!(selector.path(LINK).unwrap().state, PathState::Dead);
    // It comes back: the link wins again at once.
    assert_eq!(
        answer(&mut selector, LINK, 300),
        Some(Switch { from: Some(RELAY), to: Some(LINK) })
    );
}

#[test]
fn a_suspect_with_nothing_else_alive_keeps_spraying() {
    let mut selector = three_paths();
    answer(&mut selector, LAN, 500);
    selector.on_silence(LAN).unwrap();
    assert_eq!(selector.current(), None);
    assert_eq!(selector.chosen(), Some(LAN));
    assert_eq!(lose(&mut selector, LAN), None, "still suspect, nothing visible changed");
    lose(&mut selector, LAN);
    let died = lose(&mut selector, LAN);
    assert_eq!(died, Some(Switch { from: None, to: None }), "the held path's death is reported");
    assert_eq!(selector.chosen(), None);
}

#[test]
fn silence_on_a_path_that_is_not_alive_changes_nothing() {
    let mut selector = three_paths();
    assert_eq!(selector.on_silence(LAN).unwrap(), None);
    assert_eq!(selector.path(LAN).unwrap().state, PathState::Probing);
}

fn relay_first() -> Selector {
    let mut selector =
        Selector::new(SelectorConfig { upgrade_streak: 2, ..SelectorConfig::default() });
    selector.add_path(LAN, PathKind::DirectLan).unwrap();
    selector.add_path(RELAY, PathKind::DoRelay).unwrap();
    selector
}

#[test]
fn relay_first_a_direct_path_takes_the_relay_after_its_streak_and_doubles_it_per_drop() {
    let mut selector = relay_first();
    assert_eq!(selector.on_opened(RELAY).unwrap(), Some(Switch { from: None, to: Some(RELAY) }));
    answer(&mut selector, RELAY, 40_000);
    assert_eq!(answer(&mut selector, LAN, 10_000), None);
    assert_eq!(
        answer(&mut selector, LAN, 10_000),
        Some(Switch { from: Some(RELAY), to: Some(LAN) })
    );
    assert_eq!(lose(&mut selector, LAN), Some(Switch { from: Some(LAN), to: None }));
    lose(&mut selector, LAN);
    assert_eq!(lose(&mut selector, LAN), Some(Switch { from: None, to: Some(RELAY) }));
    for _ in 0..3 {
        assert_eq!(answer(&mut selector, LAN, 10_000), None, "needs 4 now");
    }
    assert_eq!(answer(&mut selector, LAN, 10_000).and_then(|s| s.to), Some(LAN));
}

#[test]
fn relay_first_the_first_path_to_answer_carries_and_a_dead_relay_strands_nothing() {
    let mut selector = relay_first();
    assert_eq!(answer(&mut selector, LAN, 10_000).and_then(|s| s.to), Some(LAN));
    let mut selector = relay_first();
    answer(&mut selector, RELAY, 40_000);
    answer(&mut selector, LAN, 10_000);
    assert_eq!(selector.current(), Some(RELAY));
    for _ in 0..3 {
        lose(&mut selector, RELAY);
    }
    assert_eq!(selector.current(), Some(LAN), "the unproven direct path beats nothing");
}

#[test]
fn default_config_is_unchanged_by_relay_first() {
    let mut selector = three_paths();
    answer(&mut selector, RELAY, 40_000);
    assert_eq!(answer(&mut selector, LAN, 60_000).and_then(|s| s.to), Some(LAN));
}

#[test]
fn rtt_hysteresis_still_decides_between_paths_of_one_medium() {
    let mut selector = Selector::new(SelectorConfig::default());
    selector.add_path_on(LAN, PathKind::DirectLan, Medium::Lan).unwrap();
    selector.add_path_on(LINK, PathKind::DirectLan, Medium::Lan).unwrap();
    answer(&mut selector, LAN, 20_000);
    answer(&mut selector, LINK, 2_000);
    assert_eq!(selector.current(), Some(LAN), "one answer is not a streak");
    answer(&mut selector, LINK, 2_000);
    answer(&mut selector, LINK, 2_000);
    assert_eq!(selector.current(), Some(LINK));
}
