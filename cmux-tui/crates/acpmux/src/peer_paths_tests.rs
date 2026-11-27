use super::*;

const MS: Duration = Duration::from_millis(1);

#[test]
fn the_first_path_to_answer_carries_the_session() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    assert_eq!(paths.active(), None, "no path answered yet");
    assert!(paths.in_doubt(0));
    assert_eq!(paths.pong(Via::Ssh, 40 * MS, 1_000), Some(Some(Via::Ssh)));
    assert_eq!(paths.active(), Some(Via::Ssh));
    assert_eq!(paths.health(Via::Link, 1_000), Some(Health::Probing));
}

#[test]
fn the_lower_round_trip_wins_after_its_streak_not_on_one_sample() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Ssh, 40 * MS, 0);
    // The link answers faster, but one sample (and two) does not move the session.
    assert_eq!(paths.pong(Via::Link, 3 * MS, 100), None);
    assert_eq!(paths.pong(Via::Link, 3 * MS, 3_100), None);
    assert_eq!(paths.active(), Some(Via::Ssh));
    // The third answer in a row that beats ssh by the margin does.
    assert_eq!(paths.pong(Via::Link, 3 * MS, 6_100), Some(Some(Via::Link)));
    assert_eq!(paths.active(), Some(Via::Link));
    // ssh now slightly faster than its own past, still much slower: no flap back.
    assert_eq!(paths.pong(Via::Ssh, 30 * MS, 6_200), None);
    assert_eq!(paths.active(), Some(Via::Link));
}

#[test]
fn a_slower_challenger_never_takes_the_session() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Link, 3 * MS, 0);
    for n in 1..10 {
        assert_eq!(paths.pong(Via::Ssh, 40 * MS, n * 3_000), None);
        paths.pong(Via::Link, 3 * MS, n * 3_000);
    }
    assert_eq!(paths.active(), Some(Via::Link));
}

#[test]
fn a_silent_path_is_in_doubt_after_3_s_and_dead_after_6_5_s() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Link, 3 * MS, 0);
    paths.pong(Via::Ssh, 40 * MS, 0);
    assert_eq!(paths.health(Via::Link, 3_000), Some(Health::Alive));
    assert!(!paths.in_doubt(3_000));
    assert_eq!(paths.health(Via::Link, 3_001), Some(Health::Doubt));
    assert!(paths.in_doubt(3_001), "the active path is in doubt");
    // ssh keeps answering; the link stays silent.
    paths.pong(Via::Ssh, 40 * MS, 3_000);
    paths.pong(Via::Ssh, 40 * MS, 6_000);
    assert_eq!(paths.tick(6_500), None, "trusted for 6.5 s after its last pong");
    assert_eq!(paths.tick(6_501), Some(Some(Via::Ssh)), "then dead, and ssh carries");
    assert_eq!(paths.health(Via::Link, 6_501), Some(Health::Dead));
    assert!(!paths.in_doubt(6_501));
}

#[test]
fn a_failed_connection_is_dead_at_once_and_the_next_alive_path_carries() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Link, 3 * MS, 0);
    paths.pong(Via::Ssh, 40 * MS, 0);
    assert_eq!(paths.failed(Via::Link, 10), Some(Some(Via::Ssh)));
    assert_eq!(paths.failed(Via::Ssh, 20), Some(None), "no path left");
    assert_eq!(paths.active(), None);
}

#[test]
fn a_dead_path_is_probed_again_on_a_growing_backoff_and_comes_back_with_a_pong() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Ssh, 40 * MS, 0);
    assert!(paths.recovery_due(Via::Link, 0), "a path never tried is due");
    paths.failed(Via::Link, 1_000);
    assert!(!paths.recovery_due(Via::Link, 3_999));
    assert!(paths.recovery_due(Via::Link, 4_000), "3 s after it died");
    assert_eq!(paths.recover_at(Via::Link), Some(4_000 + 6_000), "then 6 s");
    assert!(!paths.recovery_due(Via::Link, 9_999));
    assert!(paths.recovery_due(Via::Link, 10_000));
    assert_eq!(paths.recover_at(Via::Link), Some(10_000 + 12_000), "then 12 s");
    assert_eq!(recovery_gap(30), 60_000, "capped at a minute");
    // Its pong ends the backoff and makes it alive again.
    paths.pong(Via::Link, 3 * MS, 11_000);
    assert_eq!(paths.health(Via::Link, 11_000), Some(Health::Alive));
    assert_eq!(paths.recover_at(Via::Link), None);
}

/// A path that answers one probe and drops again (a relay circuit cut every few seconds, a
/// tunnel the remote ends) kept its recovery backoff at the first step: each pong started it
/// over, so it was redialed every 3 s for as long as it flapped (about 1,200 dials an hour).
/// Its backoff now grows across the flaps, and starts over only once it stayed up a minute.
#[test]
fn a_flapping_path_keeps_its_recovery_backoff_until_it_stays_up() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Ssh, 40 * MS, 0);
    let mut now = 1_000;
    paths.failed(Via::Link, now);
    let mut gaps = Vec::new();
    for _ in 0..6 {
        let at = paths.recover_at(Via::Link).unwrap();
        gaps.push(at - now);
        now = at;
        assert!(paths.recovery_due(Via::Link, now));
        // The redial answers once, then the path drops again a moment later.
        paths.pong(Via::Link, 3 * MS, now + 100);
        now += 200;
        paths.failed(Via::Link, now);
    }
    assert_eq!(gaps[0], 3_000, "the first recovery probe still comes 3 s after it died");
    assert!(gaps.windows(2).all(|w| w[1] >= w[0]), "the gaps never start over: {gaps:?}");
    assert!(gaps[5] >= 60_000 - 200, "a flapping path backs off to the cap: {gaps:?}");

    // Up a minute: recovered. Its next drop starts the backoff over.
    let up = paths.recover_at(Via::Link).unwrap();
    assert!(paths.recovery_due(Via::Link, up));
    paths.pong(Via::Link, 3 * MS, up);
    for n in 1..=20 {
        paths.pong(Via::Link, 3 * MS, up + n * 3_000);
    }
    let dropped = up + 60_000;
    paths.failed(Via::Link, dropped);
    assert_eq!(paths.recover_at(Via::Link), Some(dropped + 3_000), "a stable path starts over");
}

/// Redials of a flapping path in an hour, before (the backoff started over on each pong) and
/// after: the count the PR quotes.
#[test]
fn a_path_flapping_for_an_hour_is_redialed_dozens_of_times_not_a_thousand() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Ssh, 40 * MS, 0);
    let hour = 3_600_000;
    let mut now = 0;
    paths.failed(Via::Link, now);
    let mut dials = 0;
    while let Some(at) = paths.recover_at(Via::Link) {
        if at >= hour {
            break;
        }
        now = at;
        assert!(paths.recovery_due(Via::Link, now));
        dials += 1;
        paths.pong(Via::Link, 3 * MS, now + 100);
        now += 200;
        paths.failed(Via::Link, now);
    }
    // Before: one dial per 3.2 s, about 1,125 an hour. Now: 3, 6, 12, 24, 48 s, then one a
    // minute.
    assert!(dials <= 70, "{dials} redials of a flapping path in an hour");
}

#[test]
fn a_cold_connect_dials_the_remembered_path_first() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link, Via::Hub]);
    // The hub relay streams only through the hub carrier, and then it is dialed first (relay
    // first), beside the path the rest of the order names.
    let then_hub = |mut order: Vec<Via>| {
        if Via::Hub.streams() {
            order.insert(0, Via::Hub);
        }
        order
    };
    assert_eq!(paths.dial_order(0), then_hub(vec![Via::Link, Via::Ssh]));
    paths.remember(Some(Via::Ssh));
    assert_eq!(paths.dial_order(0), then_hub(vec![Via::Ssh, Via::Link]));
    // A remembered path that is not one of these is ignored.
    paths.remember(Some(Via::Wireguard));
    assert_eq!(paths.dial_order(0), then_hub(vec![Via::Link, Via::Ssh]));
    // Measured beats remembered; a direct path that carries the session leads alone, the
    // relay after the rest.
    paths.remember(Some(Via::Ssh));
    paths.pong(Via::Link, 3 * MS, 0);
    let mut measured = vec![Via::Link, Via::Ssh];
    if Via::Hub.streams() {
        measured.push(Via::Hub);
    }
    assert_eq!(paths.dial_order(0), measured);
}

#[test]
fn the_hub_is_the_relayed_class_and_never_beats_a_direct_path() {
    let mut paths = Paths::new(&[Via::Hub, Via::Ssh]);
    paths.pong(Via::Hub, MS, 0);
    assert_eq!(paths.active(), Some(Via::Hub), "the relay carries while nothing else answers");
    if Via::Hub.streams() {
        // Relay first: a direct path takes the session only once proven and no slower.
        assert_eq!(paths.pong(Via::Ssh, 80 * MS, 10), None);
        assert_eq!(paths.pong(Via::Ssh, 80 * MS, 20), None, "slower than the relay");
        let mut paths = Paths::new(&[Via::Hub, Via::Ssh]);
        paths.pong(Via::Hub, 90 * MS, 0);
        paths.pong(Via::Ssh, 80 * MS, 10);
        assert_eq!(paths.pong(Via::Ssh, 80 * MS, 20), Some(Some(Via::Ssh)), "proven, faster");
    } else {
        assert_eq!(paths.pong(Via::Ssh, 80 * MS, 10), Some(Some(Via::Ssh)), "any direct path wins");
    }
}

#[test]
fn the_view_names_each_carrier_its_state_and_round_trip() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Link, 3 * MS, 0);
    let view = paths.view(100);
    let link = view.as_array().unwrap().iter().find(|p| p["via"] == "link").unwrap();
    assert_eq!(link["carrier"], "direct");
    assert_eq!(link["state"], "alive");
    assert_eq!(link["active"], true);
    assert_eq!(link["rttMs"].as_f64(), Some(3.0));
    let ssh = view.as_array().unwrap().iter().find(|p| p["via"] == "ssh").unwrap();
    assert_eq!(ssh["carrier"], "ssh");
    assert_eq!(ssh["state"], "probing");
    assert!(ssh["rttMs"].is_null());
}

/// The selector's `Suspect` (an alive path that went silent: `on_silence`) is doubt: the
/// selector still holds it (`chosen`) but names no current path, the moment to use every path.
#[test]
fn a_suspect_path_is_in_doubt_and_still_held() {
    let mut paths = Paths::new(&[Via::Link, Via::Ssh]);
    paths.pong(Via::Link, Duration::from_millis(5), 1_000);
    assert_eq!(paths.active(), Some(Via::Link));
    let id = paths.find(Via::Link).unwrap().id;
    paths.selector.on_silence(id).unwrap();
    assert_eq!(paths.health(Via::Link, 1_000), Some(Health::Doubt));
    assert_eq!(paths.selector.chosen(), Some(id));
    assert_eq!(paths.active(), None);
    assert!(paths.in_doubt(1_000));
}

/// The paths feed their link counters (`peer_path_stats.rs`): a link that opened on ssh after a
/// dead WireGuard path, the direct probes while on ssh, the move once WireGuard answers, and
/// each path's round trips, all on the caller's clock.
#[test]
fn the_paths_count_the_connect_the_upgrade_and_the_time_on_each_path() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Ssh]);
    paths.failed(Via::Wireguard, 1_250);
    paths.record_opened(&[Via::Wireguard, Via::Ssh], Via::Ssh, 1_000, 1_600);
    paths.serving(Some(Via::Ssh), 1_600);
    paths.pong(Via::Ssh, 40 * MS, 1_600);
    // A recovery probe of the dead WireGuard path fails, the next answers.
    paths.failed(Via::Wireguard, 4_250);
    paths.pong(Via::Wireguard, 4 * MS, 10_250);
    paths.serving(Some(Via::Wireguard), 11_600);
    let stats = paths.stats_view(21_600);
    assert_eq!(stats["since"], 1_000);
    assert_eq!(stats["firstByteMs"], 600);
    assert_eq!(stats["winner"], "ssh");
    assert_eq!(stats["waitedOnDirect"], 1);
    assert_eq!(stats["switches"], 1);
    assert_eq!(stats["onPathMs"]["ssh"], 10_000);
    assert_eq!(stats["onPathMs"]["wireguard"], 10_000);
    assert_eq!(stats["onCarrierMs"]["direct"], 10_000);
    assert_eq!(stats["rtt"]["ssh"]["p50Ms"].as_f64(), Some(40.0));
    assert_eq!(stats["rtt"]["wireguard"]["p95Ms"].as_f64(), Some(4.0));
    // The failure before the link was serving is no attempt; the probe on ssh is.
    assert_eq!(stats["directUpgrade"]["attempts"], 2);
    assert_eq!(stats["directUpgrade"]["failures"], 1);
    assert_eq!(stats["directUpgrade"]["upgrades"], 1);
}

/// Relay first (a streaming hub relay): the relay leads the dial order and the remembered
/// path starts beside it; without the hub carrier the order is direct first, as before.
#[test]
fn relay_first_dials_the_relay_and_the_remembered_path_together() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Ssh, Via::Hub]);
    paths.remember(Some(Via::Wireguard));
    if Via::Hub.streams() {
        assert!(paths.relay_first());
        assert_eq!(paths.dial_order(0), [Via::Hub, Via::Wireguard, Via::Ssh]);
        assert_eq!(paths.dial_together(0), 2);
    } else {
        assert!(!paths.relay_first());
        assert_eq!(paths.dial_order(0), [Via::Wireguard, Via::Ssh]);
        assert_eq!(paths.dial_together(0), 1);
    }
    // A peer with no hub route keeps the direct-first order.
    let direct = Paths::new(&[Via::Wireguard, Via::Ssh]);
    assert!(!direct.relay_first());
    assert_eq!(direct.dial_together(0), 1);
}

/// Relay first: the link opened on the relay; the direct path takes it on its second probe
/// answer in a row, not its first.
#[cfg(feature = "hub-carrier")]
#[test]
fn relay_first_upgrades_to_direct_on_the_second_probe_answer() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Ssh, Via::Hub]);
    assert_eq!(paths.opened(Via::Hub, 0), Some(Some(Via::Hub)));
    assert_eq!(paths.pong(Via::Hub, 40 * MS, 10), None);
    assert_eq!(paths.pong(Via::Wireguard, 12 * MS, 20), None, "one answer is not proof");
    assert_eq!(paths.active(), Some(Via::Hub));
    assert_eq!(paths.pong(Via::Wireguard, 12 * MS, 3_020), Some(Some(Via::Wireguard)));
    assert_eq!(paths.active(), Some(Via::Wireguard));
}

/// Relay first: the path the link opened on holds it before any pong, so a direct probe that
/// answers first does not move a link the relay just opened, and a link a direct path opened
/// stays there when the relay's probe answers.
#[cfg(feature = "hub-carrier")]
#[test]
fn relay_first_the_opened_path_holds_the_link_until_probes_measure_the_rest() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Hub]);
    paths.opened(Via::Hub, 0);
    assert_eq!(paths.pong(Via::Wireguard, 5 * MS, 1), None);
    assert_eq!(paths.active(), Some(Via::Hub));

    let mut paths = Paths::new(&[Via::Wireguard, Via::Hub]);
    paths.opened(Via::Wireguard, 0);
    assert_eq!(paths.pong(Via::Hub, 40 * MS, 1), None);
    assert_eq!(paths.pong(Via::Wireguard, 10 * MS, 2), None);
    assert_eq!(paths.active(), Some(Via::Wireguard));
}

/// Relay first: a direct path slower than the relay never takes the session from it.
#[cfg(feature = "hub-carrier")]
#[test]
fn relay_first_a_direct_path_slower_than_the_relay_leaves_the_session_there() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Hub]);
    paths.opened(Via::Hub, 0);
    paths.pong(Via::Hub, 30 * MS, 1);
    for n in 1..10 {
        assert_eq!(paths.pong(Via::Wireguard, 90 * MS, n * 3_000), None);
        paths.pong(Via::Hub, 30 * MS, n * 3_000);
    }
    assert_eq!(paths.active(), Some(Via::Hub));
}

/// Relay first: a direct path that degrades gives the session back to the relay, by failing
/// (loss) or by the relay beating its round trip on three answers; the session never
/// waits on the direct path to come back.
#[cfg(feature = "hub-carrier")]
#[test]
fn relay_first_a_degraded_direct_path_falls_back_to_the_relay() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Hub]);
    paths.opened(Via::Hub, 0);
    paths.pong(Via::Hub, 40 * MS, 1);
    paths.pong(Via::Wireguard, 10 * MS, 2);
    assert_eq!(paths.pong(Via::Wireguard, 10 * MS, 3_002), Some(Some(Via::Wireguard)));
    // Its round trip grows past the relay's (a lossy path retransmitting).
    for n in 1..=8 {
        paths.pong(Via::Wireguard, 400 * MS, 3_002 + n * 3_000);
    }
    let mut moved = None;
    for n in 1..=3 {
        moved = paths.pong(Via::Hub, 40 * MS, 3_003 + 24_000 + n * 3_000).or(moved);
    }
    assert_eq!(moved, Some(Some(Via::Hub)), "the relay beat it three times: it carries again");
    // A direct path that fails outright hands over at once.
    let mut paths = Paths::new(&[Via::Wireguard, Via::Hub]);
    paths.opened(Via::Hub, 0);
    paths.pong(Via::Hub, 40 * MS, 1);
    paths.pong(Via::Wireguard, 10 * MS, 2);
    paths.pong(Via::Wireguard, 10 * MS, 3_002);
    assert_eq!(paths.active(), Some(Via::Wireguard));
    assert_eq!(paths.failed(Via::Wireguard, 3_100), Some(Some(Via::Hub)));
}

/// Relay first: a flapping direct path does not thrash the session. Each time it was dropped
/// back to the relay it needs twice the answers in a row to take it again (2, 4, 8).
#[cfg(feature = "hub-carrier")]
#[test]
fn relay_first_a_flapping_direct_path_does_not_thrash() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Hub]);
    paths.opened(Via::Hub, 0);
    paths.pong(Via::Hub, 40 * MS, 1);
    let mut now = 10;
    let mut switches = 0;
    for needed in [2u64, 4, 8] {
        for n in 1..=needed {
            now += 3_000;
            paths.pong(Via::Hub, 40 * MS, now);
            let moved = paths.pong(Via::Wireguard, 10 * MS, now);
            if n < needed {
                assert_eq!(moved, None, "took the session after {n} of {needed} answers");
            } else {
                assert_eq!(moved, Some(Some(Via::Wireguard)), "{needed} answers in a row");
                switches += 1;
            }
        }
        // It drops again.
        now += 100;
        assert_eq!(paths.failed(Via::Wireguard, now), Some(Some(Via::Hub)));
        switches += 1;
    }
    // A path that flaps every probe: one answer, one loss, for a minute; it never carries.
    for _ in 0..20 {
        now += 3_000;
        paths.pong(Via::Hub, 40 * MS, now);
        assert_eq!(paths.pong(Via::Wireguard, 10 * MS, now), None);
        now += 100;
        paths.failed(Via::Wireguard, now);
    }
    assert_eq!(paths.active(), Some(Via::Hub));
    assert_eq!(switches, 6, "three upgrades and three falls back, no more");
}

/// Relay first: once a direct path took the session, the link that moves to it dials that
/// path alone first, so the relay (faster to open) never wins it back in the race; when the
/// direct path fails, the relay leads again.
#[cfg(feature = "hub-carrier")]
#[test]
fn relay_first_a_link_moving_to_direct_dials_direct_first_and_alone() {
    let mut paths = Paths::new(&[Via::Wireguard, Via::Ssh, Via::Hub]);
    paths.opened(Via::Hub, 0);
    paths.pong(Via::Hub, 40 * MS, 1);
    paths.pong(Via::Wireguard, 10 * MS, 2);
    paths.pong(Via::Wireguard, 10 * MS, 3_002);
    assert_eq!(paths.active(), Some(Via::Wireguard));
    assert_eq!(paths.dial_order(3_002)[0], Via::Wireguard);
    assert_eq!(paths.dial_together(3_002), 1);
    paths.failed(Via::Wireguard, 3_100);
    assert_eq!(paths.dial_order(3_100)[0], Via::Hub);
    assert_eq!(paths.dial_together(3_100), 2);
}
