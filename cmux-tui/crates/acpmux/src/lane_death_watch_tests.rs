use super::*;
use serde_json::json;

const NOW: u64 = 1_800_000_000_000;
const MIN: u64 = 60_000;

#[test]
fn dead_reads_like_lane_deaths() {
    let gone = json!({"status": "disconnected", "updatedAt": NOW - MIN});
    assert_eq!(dead_why(&gone, NOW, GRACE_MS).unwrap().why, "its agent stopped");
    assert!(dead_why(&json!({"status": "failed"}), NOW, GRACE_MS).is_some());
    assert!(dead_why(&json!({"status": "closed", "stuckSince": 1}), NOW, GRACE_MS).is_none());
    assert!(dead_why(&json!({"status": "idle"}), NOW, GRACE_MS).is_none());
    // Unreachable and stuck wait out the grace; seconds read as seconds.
    let away = |ago| json!({"status": "unreachable", "lastSeen": NOW - ago});
    assert!(dead_why(&away(5 * MIN), NOW, GRACE_MS).is_none());
    let d = dead_why(&away(11 * MIN), NOW, GRACE_MS).unwrap();
    assert!(d.host_down);
    let stuck = json!({"status": "running", "stuckSince": (NOW - 12 * MIN) / 1000});
    assert_eq!(dead_why(&stuck, NOW, GRACE_MS).unwrap().why, "it is stuck");
    assert!(dead_why(&json!({"status": "unreachable"}), NOW, GRACE_MS).is_none());
}

#[test]
fn parent_is_the_first_tag_then_parent_id() {
    let row = json!({"tags": {"spawnedBy": {"value": "coord"}, "lane.reportsTo": "x"}});
    assert_eq!(parent_of(&row).as_deref(), Some("coord"));
    let row = json!({"tags": {"mux.parent": " ", "lane.reportsTo": "lead"}});
    assert_eq!(parent_of(&row).as_deref(), Some("lead"));
    assert_eq!(parent_of(&json!({"parentId": "p1"})).as_deref(), Some("p1"));
    assert_eq!(parent_of(&json!({"tags": {}})), None);
}

#[test]
fn a_death_is_told_once_and_again_after_it_lived() {
    let dead = json!({"name": "lane-a", "status": "disconnected", "updatedAt": NOW - MIN,
                      "tags": {"spawnedBy": "coord"}});
    let alive = json!({"name": "lane-a", "status": "idle", "tags": {"spawnedBy": "coord"}});
    let mut w = Watch::default();
    let n = w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |p| p == "coord", |_| false);
    assert_eq!(n.len(), 1);
    assert_eq!(n[0].route, Route::Restart { number: 1 });
    assert!(n[0].text(NOW).contains("`acpmux session restart vm-1/lane-a`"));
    // Not sent: told again next pass. Sent: quiet.
    assert_eq!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |_| true, |_| false).len(), 1);
    w.told(&n[0]);
    assert!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |_| true, |_| false).is_empty());
    // Alive, then dead again: a new death.
    assert!(w.pass([("k", "vm-1", &alive)], NOW, GRACE_MS, |_| true, |_| false).is_empty());
    assert_eq!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |_| true, |_| false).len(), 1);
}

#[test]
fn the_third_death_in_an_hour_hands_over_instead_of_restarting() {
    let dead = |at: u64| {
        json!({"name": "lane-a", "status": "disconnected",
        "updatedAt": at, "tags": {"spawnedBy": "coord"}})
    };
    let alive = json!({"name": "lane-a", "status": "idle", "tags": {"spawnedBy": "coord"}});
    // Three deaths 20 min apart; each lives again in between.
    let run = |w: &mut Watch| {
        let mut out = Vec::new();
        for i in 0..3u64 {
            let at = NOW + i * 20 * MIN;
            let n = w.pass([("k", "vm-1", &dead(at))], at + MIN, GRACE_MS, |_| true, |_| false);
            w.told(&n[0]);
            out.push((n[0].deaths, n[0].route.clone()));
            // The same death read on later passes is not a second one.
            assert!(
                w.pass([("k", "vm-1", &dead(at))], at + 2 * MIN, GRACE_MS, |_| true, |_| false)
                    .is_empty()
            );
            assert!(
                w.pass([("k", "vm-1", &alive)], at + 3 * MIN, GRACE_MS, |_| true, |_| false)
                    .is_empty()
            );
        }
        out
    };
    let on = run(&mut Watch::new(MAX_DEATHS));
    assert_eq!(on[0], (1, Route::Restart { number: 1 }));
    assert_eq!(on[1], (2, Route::Restart { number: 1 }));
    let (deaths, last) = &on[2];
    assert_eq!(*deaths, 3);
    let Route::Handoff { why, after } = last else { panic!("{last:?}") };
    assert_eq!(*after, crate::death_route::Ending::Intensity);
    assert!(why.contains("died 3 times in 60 min"), "{why}");
    assert!(step_line(last, "vm-1/lane-a").starts_with("hand its work over: it died 3"));
    // Off (the default): counted the same, restarted as before.
    let off = run(&mut Watch::new(0));
    assert_eq!(off[2], (3, Route::Restart { number: 1 }));
}

#[test]
fn deaths_past_the_window_are_forgotten() {
    let dead = |at: u64| {
        json!({"status": "failed", "updatedAt": at,
        "tags": {"spawnedBy": "coord"}})
    };
    let alive = json!({"status": "idle", "tags": {"spawnedBy": "coord"}});
    let mut w = Watch::new(MAX_DEATHS);
    // A death every 40 min: never 3 within 60 min.
    for i in 0..6u64 {
        let at = NOW + i * 40 * MIN;
        let n = w.pass([("k", "vm-1", &dead(at))], at + MIN, GRACE_MS, |_| true, |_| false);
        assert!(n[0].deaths <= 2, "{}", n[0].deaths);
        assert_eq!(n[0].route, Route::Restart { number: 1 });
        w.told(&n[0]);
        w.pass([("k", "vm-1", &alive)], at + 2 * MIN, GRACE_MS, |_| true, |_| false);
    }
    // A day later nothing of it is kept.
    w.pass(std::iter::empty(), NOW + 24 * 60 * MIN, GRACE_MS, |_| true, |_| false);
    assert!(w.deaths.is_empty());
}

#[test]
fn a_starter_on_another_machine_is_not_told_here() {
    let dead = json!({"status": "failed", "tags": {"spawnedBy": "elsewhere"}});
    let mut w = Watch::default();
    assert!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |p| p == "coord", |_| false).is_empty());
    let orphan = json!({"status": "failed"});
    assert!(w.pass([("k", "vm-1", &orphan)], NOW, GRACE_MS, |_| true, |_| false).is_empty());
}

/// A link this daemon closed because nothing used it (`peer_demand.rs` `idle_ended`) leaves
/// the peer's rows `unreachable` until the next use dials it again. That machine is fine:
/// its lanes are not told dead, ten minutes after every idle close (chief-subagents-2,
/// 2026-11-27: six false deaths in four hours). A real outage, and a lane that died before
/// the link went idle, are still told.
#[test]
fn an_idle_closed_link_is_not_a_dead_machine() {
    let away = json!({"name": "lane-a", "status": "unreachable", "lastSeen": NOW - 11 * MIN,
                      "tags": {"spawnedBy": "coord"}});
    let failed = json!({"name": "lane-b", "status": "failed", "tags": {"spawnedBy": "coord"}});
    let mut w = Watch::default();
    let idle = |h: &str| h == "vm-1";
    assert!(w.pass([("k", "vm-1", &away)], NOW, GRACE_MS, |_| true, idle).is_empty());
    assert_eq!(w.pass([("k2", "vm-1", &failed)], NOW, GRACE_MS, |_| true, idle).len(), 1);
    // The same row on a machine whose link dropped on its own is a dead machine.
    assert_eq!(w.pass([("k", "vm-2", &away)], NOW, GRACE_MS, |_| true, idle).len(), 1);
}

#[test]
fn a_machine_down_within_the_grace_asks_it_to_start() {
    let dead =
        Dead { why: "its machine does not answer", since_ms: NOW - 11 * MIN, host_down: true };
    // Past the 10 min watch grace but within the 20 min host grace recovery uses.
    let r = route_of("k", "vm-1", &dead, NOW, 20 * MIN, 1, MAX_DEATHS);
    // `route_of` reads a down host as startable (#61428), so within the grace the starter
    // is told to start it, not "nothing to do"; #61325 had expected `Route::None` for the
    // code before #61428, and the two merged into a red.
    assert_eq!(r, Route::StartHost);
}
