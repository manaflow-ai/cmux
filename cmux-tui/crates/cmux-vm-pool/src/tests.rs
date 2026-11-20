use std::collections::HashSet;

use serde_json::json;

use crate::model::{Machine, Power, Provider, Runner};
use crate::schedule::{Policy, Scheduler, feed_queued};
use crate::watch::Tracker;
use crate::{freestyle, gce, github, plan};

fn machine(provider: Provider, name: &str, power: Power, slots: u32) -> Machine {
    Machine {
        provider,
        id: format!("id-{name}"),
        name: name.to_owned(),
        zone: (provider == Provider::Gcp).then(|| "us-west1-a".to_owned()),
        power,
        state: format!("{power:?}"),
        slots,
    }
}

fn runner(name: &str, online: bool, busy: bool) -> Runner {
    Runner { name: name.to_owned(), online, busy }
}

#[test]
fn no_delete_path() {
    // The pool is persistent (cmuxterm-hq#15332): no source file of this crate may call a delete, stop,
    // or a Freestyle/GCE route that removes a machine.
    let sources = [
        include_str!("freestyle.rs"),
        include_str!("gce.rs"),
        include_str!("github.rs"),
        include_str!("cli.rs"),
        include_str!("schedule.rs"),
        include_str!("plan.rs"),
        include_str!("http.rs"),
    ];
    for source in sources {
        for banned in ["Method::DELETE", "/delete", "/stop\"", "\"stop\"", "/retire"] {
            assert!(
                !source.contains(banned),
                "a pool verb must never delete or stop a machine: found {banned}"
            );
        }
    }
}

#[test]
fn owns_runner_matches_name_or_numbered_suffix_only() {
    let m = machine(Provider::Gcp, "cmux-runner-pool-w1a-0001", Power::Running, 4);
    assert!(m.owns_runner("cmux-runner-pool-w1a-0001"));
    assert!(m.owns_runner("cmux-runner-pool-w1a-0001-3"));
    assert!(!m.owns_runner("cmux-runner-pool-w1a-00011"));
    assert!(!m.owns_runner("cmux-runner-pool-w1a-0001-x"));
    assert!(!m.owns_runner("cmux-runner-pool-w1a-0001-"));
}

#[test]
fn owner_prefers_the_longest_machine_name() {
    let machines = vec![
        machine(Provider::Gcp, "cmux-runner-pool-w1a-0001", Power::Running, 1),
        machine(Provider::Gcp, "cmux-runner-pool-w1a-0001-2", Power::Running, 1),
    ];
    assert_eq!(
        plan::owner(&machines, "cmux-runner-pool-w1a-0001-2").map(|m| m.name.as_str()),
        Some("cmux-runner-pool-w1a-0001-2")
    );
}

#[test]
fn pick_up_takes_paused_freestyle_first_until_the_slots_cover_the_count() {
    let machines = vec![
        machine(Provider::Gcp, "g-1", Power::Paused, 4),
        machine(Provider::Freestyle, "fsp-b", Power::Paused, 2),
        machine(Provider::Freestyle, "fsp-a", Power::Stopped, 2),
        machine(Provider::Freestyle, "fsp-c", Power::Running, 2),
        machine(Provider::Freestyle, "fsp-d", Power::Paused, 2),
    ];
    let picked: Vec<&str> = plan::pick_up(&machines, 5).iter().map(|m| m.name.as_str()).collect();
    // Paused Freestyle (b, d: 4 slots), then paused GCP (4 more), never the running one; stopped comes last.
    assert_eq!(picked, ["fsp-b", "fsp-d", "g-1"]);
    let all: Vec<&str> = plan::pick_up(&machines, 100).iter().map(|m| m.name.as_str()).collect();
    assert_eq!(all, ["fsp-b", "fsp-d", "g-1", "fsp-a"]);
    assert!(plan::pick_up(&machines, 0).is_empty());
}

#[test]
fn pick_pause_needs_every_runner_idle_and_allowed() {
    let machines = vec![
        machine(Provider::Gcp, "g-1", Power::Running, 2),
        machine(Provider::Gcp, "g-2", Power::Running, 2),
        machine(Provider::Gcp, "g-3", Power::Running, 1),
        machine(Provider::Gcp, "g-4", Power::Paused, 1),
    ];
    let roster = vec![
        runner("g-1-1", true, false),
        runner("g-1-2", true, false),
        runner("g-2-1", true, false),
        runner("g-2-2", true, true),
        runner("g-4", false, false),
    ];
    let allowed: HashSet<String> =
        ["g-1-1", "g-1-2", "g-2-1", "g-2-2", "g-3", "g-4"].map(str::to_owned).into();
    let picked: Vec<&str> =
        plan::pick_pause(&machines, &roster, &allowed).iter().map(|m| m.name.as_str()).collect();
    // g-2 has a busy runner, g-3 has no runner listed, g-4 is not running.
    assert_eq!(picked, ["g-1"]);
    let narrow: HashSet<String> = ["g-1-1"].map(str::to_owned).into();
    assert!(plan::pick_pause(&machines, &roster, &narrow).is_empty());
}

#[test]
fn a_stale_online_never_counts_as_a_resume() {
    let wanted: HashSet<String> = ["fsp-a", "fsp-b", "fsp-c"].map(str::to_owned).into();
    let mut t = Tracker::new(1_000, Some(wanted));
    // Before `since`: ignored.
    t.observe(900, &[runner("fsp-a", false, false)]);
    // fsp-a still shows online from before its pause; fsp-b offline; fsp-c not listed (offline).
    t.observe(1_000, &[runner("fsp-a", true, false), runner("fsp-b", false, false)]);
    t.observe(
        1_500,
        &[runner("fsp-a", true, false), runner("fsp-b", true, false), runner("fsp-c", true, false)],
    );
    let online: Vec<(String, u64)> = t.online();
    assert_eq!(online, vec![("fsp-b".to_owned(), 500), ("fsp-c".to_owned(), 500)]);
    // An unwanted runner never counts.
    t.observe(1_600, &[runner("other", false, false)]);
    t.observe(1_700, &[runner("other", true, false)]);
    assert_eq!(t.online_count(), 2);
    assert_eq!(t.nth(&[1, 2, 3]).into_iter().collect::<Vec<_>>(), vec![(1, 500), (2, 500)]);
}

#[test]
fn freestyle_rows_parse_pool_vms_only() {
    let row = json!({"id": "vm1", "state": "paused", "metadata": {"purpose": "freestyle-pool", "fsp_runner": "fsp-abc", "fsp_runners": "fsp-abc-1,fsp-abc-2,fsp-abc-3"}});
    let m = freestyle::parse_vm(&row, freestyle::POOL_PURPOSE).expect("pool vm");
    assert_eq!((m.name.as_str(), m.power, m.slots), ("fsp-abc", Power::Paused, 3));
    assert!(m.owns_runner("fsp-abc-2"));
    let other =
        json!({"id": "vm2", "state": "running", "metadata": {"purpose": "freestyle-runners"}});
    assert!(freestyle::parse_vm(&other, freestyle::POOL_PURPOSE).is_none());
    let bare = json!({"id": "vm3", "state": "running"});
    assert!(freestyle::parse_vm(&bare, freestyle::POOL_PURPOSE).is_none());
}

#[test]
fn gce_rows_parse_zone_status_and_runner_count() {
    let row = json!({
        "name": "cmux-runner-pool-w4a-0010",
        "zone": "https://www.googleapis.com/compute/v1/projects/p/zones/us-west4-a",
        "status": "SUSPENDED",
        "metadata": {"items": [{"key": "cmux-runner-pool-runners", "value": "4"}]}
    });
    let m = gce::parse_instance(&row).expect("instance");
    assert_eq!(m.zone.as_deref(), Some("us-west4-a"));
    assert_eq!((m.power, m.slots), (Power::Paused, 4));
    let hand_made = json!({"name": "cmux-runner-pool-w1a-0001", "status": "TERMINATED"});
    let m = gce::parse_instance(&hand_made).expect("instance");
    assert_eq!((m.power, m.slots), (Power::Stopped, 1));
}

#[test]
fn github_runner_rows_parse() {
    let r = github::parse_runner(&json!({"name": "fsp-a", "status": "online", "busy": true}))
        .expect("runner");
    assert_eq!(r, runner("fsp-a", true, true));
    let r = github::parse_runner(&json!({"name": "fsp-b", "status": "offline"})).expect("runner");
    assert_eq!(r, runner("fsp-b", false, false));
}

#[test]
fn feed_counts_queued_untaken_jobs_of_the_label() {
    let body = json!({
        "runs": [{"id": 9, "status": "completed"}, {"id": 1, "status": "in_progress"}],
        "jobs": [
            {"run_id": 1, "status": "queued", "labels": ["cmux-linux"]},
            {"run_id": 1, "status": "queued", "labels": ["cmux-linux"], "runner_name": "fsp-a"},
            {"run_id": 1, "status": "queued", "labels": ["cmux-fleet-linux-x64"]},
            {"run_id": 9, "status": "queued", "labels": ["cmux-linux"]},
            {"run_id": 1, "status": "in_progress", "labels": ["cmux-linux"]},
            {"run_id": 2, "status": "queued", "labels": ["cmux-linux"], "runner_name": null}
        ]
    });
    assert_eq!(feed_queued(&body, "cmux-linux"), 2);
}

#[test]
fn scheduler_resumes_for_queued_jobs_beyond_idle_runners() {
    let machines = vec![
        machine(Provider::Freestyle, "fsp-a", Power::Running, 1),
        machine(Provider::Freestyle, "fsp-b", Power::Paused, 2),
        machine(Provider::Gcp, "cmux-runner-pool-x", Power::Paused, 4),
    ];
    let roster = vec![runner("fsp-a", true, false)];
    let mut s = Scheduler::new(Policy::default());
    let d = s.tick(0, &machines, &roster, 4);
    // 4 queued, 1 idle online: resume 3 slots' worth, Freestyle first (2), then GCP (4).
    assert_eq!(d.resume, vec!["id-fsp-b".to_owned(), "id-cmux-runner-pool-x".to_owned()]);
    assert!(d.pause.is_empty());
    let d = s.tick(1, &machines, &roster, 1);
    assert!(d.resume.is_empty(), "an idle runner covers one queued job");
}

#[test]
fn scheduler_pauses_only_after_the_idle_window_and_keeps_the_floor() {
    let machines = vec![
        machine(Provider::Freestyle, "fsp-a", Power::Running, 1),
        machine(Provider::Freestyle, "fsp-b", Power::Running, 1),
        machine(Provider::Freestyle, "fsp-c", Power::Running, 1),
    ];
    let roster = vec![
        runner("fsp-a", true, false),
        runner("fsp-b", true, false),
        runner("fsp-c", true, true),
    ];
    let policy = Policy { idle_ms: 1_000, keep_idle: 1, ..Policy::default() };
    let mut s = Scheduler::new(policy);
    assert!(s.tick(0, &machines, &roster, 0).pause.is_empty(), "idle clocks start now");
    assert!(s.tick(999, &machines, &roster, 0).pause.is_empty(), "not idle long enough");
    let d = s.tick(1_000, &machines, &roster, 0);
    // Two idle machines, keep one idle runner: pause one (the busy one never).
    assert_eq!(d.pause, vec!["id-fsp-a".to_owned()]);
    // Queued work stops every pause.
    assert!(s.tick(2_000, &machines, &roster, 1).pause.is_empty());
    // Busy again resets the clock.
    let busy = vec![
        runner("fsp-a", true, true),
        runner("fsp-b", true, false),
        runner("fsp-c", true, true),
    ];
    s.tick(3_000, &machines, &busy, 0);
    assert!(!s.tick(3_500, &machines, &roster, 0).pause.contains(&"id-fsp-a".to_owned()));
}
