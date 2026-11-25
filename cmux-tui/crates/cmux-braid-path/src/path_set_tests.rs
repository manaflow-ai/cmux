//! The path set on a paused clock: ids, primary and standby, the probe poll, failover time,
//! stats, renumbering and the last-good record.

use std::time::Duration;

use cmux_transport::{Medium, PathKind, PathState, SelectorConfig};
use tokio::time::Instant;

use super::{IdPolicy, PathSet, PathSetError};
use crate::LastGood;
use crate::probe::ProbeConfig;

const LAN: &str = "lan";
const WAN: &str = "wan";
const RELAY: &str = "relay";

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

fn three(now: Instant) -> PathSet<&'static str, u32> {
    let mut set = PathSet::new(SelectorConfig::default(), ProbeConfig::default());
    set.insert(LAN, PathKind::DirectLan, Medium::Lan, 1, now).unwrap();
    set.insert(WAN, PathKind::DirectWan, Medium::Routed, 2, now).unwrap();
    set.insert(RELAY, PathKind::DoRelay, Medium::Routed, 3, now).unwrap();
    set
}

/// One poll at the paused clock's now; the routes in `answering` answer `rtt` later. The
/// clock advances to that answer.
async fn round(set: &mut PathSet<&'static str, u32>, answering: &[&str], rtt: Duration) {
    let now = Instant::now();
    let due = set.poll(now);
    tokio::time::advance(rtt).await;
    for (id, probe) in due.pings {
        if answering.contains(set.route_of(id).unwrap()) {
            set.answer(id, probe, Instant::now());
        }
    }
}

#[tokio::test(start_paused = true)]
async fn a_route_is_one_path_and_ids_are_never_reused() {
    let now = Instant::now();
    let mut set = three(now);
    let lan = set.id_of(&LAN).unwrap();
    assert_eq!(
        set.insert(LAN, PathKind::DirectLan, Medium::Lan, 9, now),
        Err(PathSetError::DuplicateRoute(lan))
    );
    assert_eq!(set.get(&LAN).unwrap().meta, 1);
    set.remove(&LAN).unwrap();
    let again = set.insert(LAN, PathKind::DirectLan, Medium::Lan, 4, now).unwrap();
    assert_ne!(again, lan, "a late answer for the removed path must not revive the new one");
    assert_eq!(set.len(), 3);
}

#[tokio::test(start_paused = true)]
async fn nothing_is_primary_until_a_path_answers_then_lan_then_wan_as_standby() {
    let mut set = three(Instant::now());
    assert_eq!(set.primary(), None);
    assert_eq!(set.standby(), None);
    round(&mut set, &[LAN, WAN, RELAY], ms(2)).await;
    assert_eq!(set.primary(), Some(&LAN));
    assert_eq!(set.standby(), Some(&WAN), "a direct path stands by before a relay");
    let stats = set.get(&LAN).unwrap().stats();
    assert_eq!(stats.last_rtt_us, Some(2_000));
    assert_eq!(stats.answered, 1);
    assert_eq!(set.get(&LAN).unwrap().connect(), Some(ms(2)));
}

/// The failover number: the primary is cut at t=0; how long until datagrams go on every
/// path, and until the standby carries them alone.
#[tokio::test(start_paused = true)]
async fn a_cut_primary_fails_over_to_the_standby_within_two_silence_windows_and_three_probes() {
    let mut set = three(Instant::now());
    let started = Instant::now();
    while Instant::now() < started + Duration::from_secs(2) {
        round(&mut set, &[LAN, RELAY], ms(1)).await;
        tokio::time::advance(ms(9)).await;
    }
    assert_eq!(set.primary(), Some(&LAN));
    let cut = Instant::now();
    let lan = set.id_of(&LAN).unwrap();
    let (mut sprayed, mut relayed) = (None, None);
    while relayed.is_none() && Instant::now() < cut + Duration::from_secs(10) {
        // Datagrams keep going out on the path in use; nothing comes back on the LAN.
        if let Some(path) = set.by_id_mut(lan) {
            path.watch.sent(Instant::now());
        }
        round(&mut set, &[RELAY], ms(1)).await;
        if sprayed.is_none() && set.suspect() {
            sprayed = Some(Instant::now() - cut);
        }
        if set.primary() == Some(&RELAY) {
            relayed = Some(Instant::now() - cut);
        }
        tokio::time::advance(ms(9)).await;
    }
    let (sprayed, relayed) = (sprayed.expect("suspect"), relayed.expect("fails over"));
    assert!(sprayed <= ms(250), "suspect after {sprayed:?}");
    assert!(relayed <= Duration::from_secs(4), "relay after {relayed:?}");
    assert_eq!(set.view(lan).unwrap().state, PathState::Dead);
    let stats = set.get(&LAN).unwrap().stats();
    assert!(stats.lost >= 3 && stats.loss_pct > 30.0, "{stats:?}");
}

#[tokio::test(start_paused = true)]
async fn when_the_primary_loses_its_standing_every_other_path_is_probed_at_once() {
    let mut set = three(Instant::now());
    // A slow LAN (400 ms): it turns suspect by a lost probe, not by silence.
    let started = Instant::now();
    while Instant::now() < started + Duration::from_secs(2) {
        round(&mut set, &[LAN, WAN, RELAY], ms(400)).await;
    }
    assert_eq!(set.primary(), Some(&LAN));
    let mut probed_others = None;
    // Its next probe is due at its 5 s turn and lost a second later.
    for _ in 0..1000 {
        tokio::time::advance(ms(10)).await;
        let due = set.poll(Instant::now());
        if set.suspect() {
            // The poll that found it asks to be called again now, and that poll probes them.
            assert_eq!(due.next, Some(Instant::now()));
            let due = set.poll(Instant::now());
            let others = due.pings.iter().filter(|(id, _)| set.route_of(*id) != Some(&LAN)).count();
            probed_others = Some(others);
            break;
        }
    }
    assert_eq!(probed_others, Some(2), "both others probed at the instant the LAN turned suspect");
}

#[tokio::test(start_paused = true)]
async fn poll_where_skips_resting_paths() {
    let mut set = three(Instant::now());
    let due = set.poll_where(Instant::now(), |path, _, _| *path.route() == RELAY);
    assert_eq!(due.pings.len(), 2);
    assert!(due.pings.iter().all(|(id, _)| set.route_of(*id) != Some(&RELAY)));
}

#[tokio::test(start_paused = true)]
async fn renumbering_starts_every_path_over_on_fresh_ids() {
    let now = Instant::now();
    let mut set = PathSet::<u16, ()>::new(SelectorConfig::default(), ProbeConfig::default())
        .with_ids(IdPolicy { first: 0, renumber_at: Some(8) });
    for port in 0..4 {
        set.insert(port, PathKind::DirectWan, Medium::Routed, (), now).unwrap();
    }
    for port in 4..40 {
        set.remove(&(port - 4));
        set.insert(port, PathKind::DirectWan, Medium::Routed, (), now).unwrap();
        assert!(set.next_id() <= 8);
    }
    assert_eq!(set.len(), 4);
    let ids: Vec<u16> = set.iter().map(|path| path.id().0).collect();
    assert!(ids.iter().all(|id| *id < 8), "{ids:?}");
}

#[tokio::test(start_paused = true)]
async fn wrapping_ids_start_again_at_the_first() {
    let now = Instant::now();
    let mut set = PathSet::<u32, ()>::new(SelectorConfig::default(), ProbeConfig::default())
        .with_ids(IdPolicy { first: 16, renumber_at: None });
    let first = set.insert(0, PathKind::DirectWan, Medium::Routed, (), now).unwrap();
    assert_eq!(first.0, 16);
}

#[tokio::test(start_paused = true)]
async fn the_primary_is_remembered_with_its_connect_time() {
    let mut set = three(Instant::now());
    let memory = LastGood::new(Duration::from_secs(60));
    assert!(!set.remember(&memory, "peer"), "nothing to remember before an answer");
    round(&mut set, &[WAN], ms(30)).await;
    assert!(set.remember(&memory, "peer"));
    let remembered = memory.get(&"peer").unwrap();
    assert_eq!((remembered.target, remembered.connect), (WAN, ms(30)));
}

#[tokio::test(start_paused = true)]
async fn a_network_change_hands_the_choice_back_until_paths_answer_again() {
    let mut set = three(Instant::now());
    round(&mut set, &[LAN], ms(2)).await;
    assert_eq!(set.primary(), Some(&LAN));
    set.on_network_change(true);
    assert_eq!(set.primary(), None);
    round(&mut set, &[LAN], ms(2)).await;
    assert_eq!(set.primary(), Some(&LAN));
}

#[tokio::test(start_paused = true)]
async fn reclassify_reports_only_changed_media() {
    let mut set = three(Instant::now());
    let changed = set.reclassify(|route, _| {
        if *route == WAN {
            Medium::Link
        } else if *route == LAN {
            Medium::Lan
        } else {
            Medium::Routed
        }
    });
    assert_eq!(changed, vec![set.id_of(&WAN).unwrap()]);
}
