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

#[test]
fn a_cold_connect_dials_the_remembered_path_first() {
    let mut paths = Paths::new(&[Via::Ssh, Via::Link, Via::Hub]);
    assert_eq!(paths.dial_order(0), vec![Via::Link, Via::Ssh], "the hub has no stream yet");
    paths.remember(Some(Via::Ssh));
    assert_eq!(paths.dial_order(0), vec![Via::Ssh, Via::Link]);
    // A remembered path that is not one of these is ignored.
    paths.remember(Some(Via::Wireguard));
    assert_eq!(paths.dial_order(0), vec![Via::Link, Via::Ssh]);
    // Measured beats remembered.
    paths.remember(Some(Via::Ssh));
    paths.pong(Via::Link, 3 * MS, 0);
    assert_eq!(paths.dial_order(0), vec![Via::Link, Via::Ssh]);
}

#[test]
fn the_hub_is_the_relayed_class_and_never_beats_a_direct_path() {
    let mut paths = Paths::new(&[Via::Hub, Via::Ssh]);
    paths.pong(Via::Hub, MS, 0);
    assert_eq!(paths.active(), Some(Via::Hub), "the relay carries while nothing else answers");
    assert_eq!(paths.pong(Via::Ssh, 80 * MS, 10), Some(Some(Via::Ssh)), "any direct path wins");
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
