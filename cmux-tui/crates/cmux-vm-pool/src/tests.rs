use std::collections::HashSet;

use serde_json::json;

use crate::model::{Machine, Power, Provider, Runner};
use crate::schedule::{Demand, Policy, Scheduler, feed_queued, parse_demand};
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
        vcpu: 16,
        schedule_pause: true,
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
        include_str!("runner.rs"),
        include_str!("runner_cli.rs"),
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
    // Before `since`: the baseline. fsp-a still shows online there (GitHub has not seen its pause yet).
    t.observe(900, &[runner("fsp-a", true, false)]);
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
    let d = s.tick(0, &machines, &roster, Demand::Jobs(4));
    // 4 queued, 1 idle online: resume 3 slots' worth, Freestyle first (2), then GCP (4).
    assert_eq!(d.resume, vec!["id-fsp-b".to_owned(), "id-cmux-runner-pool-x".to_owned()]);
    assert!(d.pause.is_empty());
    let d = s.tick(1, &machines, &roster, Demand::Jobs(1));
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
    assert!(
        s.tick(0, &machines, &roster, Demand::Jobs(0)).pause.is_empty(),
        "idle clocks start now"
    );
    assert!(
        s.tick(999, &machines, &roster, Demand::Jobs(0)).pause.is_empty(),
        "not idle long enough"
    );
    let d = s.tick(1_000, &machines, &roster, Demand::Jobs(0));
    // Two idle machines, keep one idle runner: pause one (the busy one never).
    assert_eq!(d.pause, vec!["id-fsp-a".to_owned()]);
    // Queued work stops every pause.
    assert!(s.tick(2_000, &machines, &roster, Demand::Jobs(1)).pause.is_empty());
    // Busy again resets the clock.
    let busy = vec![
        runner("fsp-a", true, true),
        runner("fsp-b", true, false),
        runner("fsp-c", true, true),
    ];
    s.tick(3_000, &machines, &busy, Demand::Jobs(0));
    assert!(
        !s.tick(3_500, &machines, &roster, Demand::Jobs(0)).pause.contains(&"id-fsp-a".to_owned())
    );
}

#[test]
fn totals_count_slots_and_busy_pool_runners_only() {
    let machines = vec![
        machine(Provider::Gcp, "g-1", Power::Running, 4),
        machine(Provider::Freestyle, "fsp-a", Power::Paused, 1),
    ];
    let roster = vec![
        runner("g-1-1", true, true),
        runner("g-1-2", true, false),
        runner("g-1-3", false, false),
        runner("fsp-a", false, false),
        runner("someone-else", true, true),
    ];
    let t = plan::totals(&machines, &roster);
    assert_eq!(t["slots"], 5);
    assert_eq!((t["running"].clone(), t["paused"].clone()), (json!(1), json!(1)));
    assert_eq!((t["runners_listed"].clone(), t["runners_online"].clone()), (json!(4), json!(2)));
    assert_eq!((t["runners_busy"].clone(), t["runners_idle"].clone()), (json!(1), json!(1)));
}

#[test]
fn demand_file_reads_vcpu() {
    assert_eq!(parse_demand("vcpu=96 mem_gib=192\n"), Some(96));
    assert_eq!(parse_demand("mem_gib=8"), None);
    assert_eq!(parse_demand(""), None);
}

#[test]
fn gce_machine_types_give_vcpu() {
    assert_eq!(
        gce::machine_type_vcpu("https://x/zones/us-west1-a/machineTypes/n2d-standard-32"),
        32
    );
    assert_eq!(gce::machine_type_vcpu("c4d-standard-16-lssd"), 16);
    assert_eq!(gce::machine_type_vcpu("n2-custom-8-32768"), 8);
    assert_eq!(gce::machine_type_vcpu("custom-6-16384"), 6);
    assert_eq!(gce::machine_type_vcpu(""), 0);
}

#[test]
fn vcpu_demand_resumes_until_the_gap_is_covered_and_blocks_pauses() {
    let mut big = machine(Provider::Gcp, "cmux-runner-pool-x", Power::Running, 4);
    big.vcpu = 32;
    let mut paused_fs = machine(Provider::Freestyle, "fsp-b", Power::Paused, 1);
    paused_fs.vcpu = 16;
    let mut paused_gcp = machine(Provider::Gcp, "cmux-runner-pool-y", Power::Paused, 4);
    paused_gcp.vcpu = 32;
    let machines = vec![big, paused_fs, paused_gcp];
    // 2 of the 4 runners on the 32-vCPU machine are idle: 16 vCPU free.
    let roster = vec![
        runner("cmux-runner-pool-x-1", true, true),
        runner("cmux-runner-pool-x-2", true, true),
        runner("cmux-runner-pool-x-3", true, false),
        runner("cmux-runner-pool-x-4", true, false),
    ];
    let mut s = Scheduler::new(Policy { idle_ms: 0, keep_idle: 0, ..Policy::default() });
    let d = s.tick(0, &machines, &roster, Demand::Vcpu { vcpu: 16, queued: 0 });
    assert!(d.resume.is_empty(), "16 free vCPU cover 16 wanted");
    assert_eq!(d.free_vcpu, 16);
    let d = s.tick(1, &machines, &roster, Demand::Vcpu { vcpu: 40, queued: 0 });
    // 24 short: the paused Freestyle VM (16) first, then the paused GCE VM (32).
    assert_eq!(d.resume, vec!["id-fsp-b".to_owned(), "id-cmux-runner-pool-y".to_owned()]);
    let d = s.tick(2, &machines, &roster, Demand::Vcpu { vcpu: 20, queued: 0 });
    assert_eq!(d.resume, vec!["id-fsp-b".to_owned()]);
    assert!(d.pause.is_empty(), "nothing pauses while demand waits");
}

#[test]
fn measured_load_grows_when_every_running_vm_is_full_and_pauses_quiet_ones() {
    use crate::load::Load;
    let machines = vec![
        machine(Provider::Gcp, "cmux-runner-pool-a", Power::Running, 4),
        machine(Provider::Gcp, "cmux-runner-pool-b", Power::Running, 4),
        machine(Provider::Freestyle, "fsp-c", Power::Paused, 1),
    ];
    // Runners look idle (one each), so the slot rule alone would not grow.
    let roster = vec![
        runner("cmux-runner-pool-a-1", true, false),
        runner("cmux-runner-pool-b-1", true, false),
    ];
    let load = |cpu: f64, mem: Option<f64>| Load { cpu_pct: cpu, mem_pct: mem };
    let mut s = Scheduler::new(Policy { idle_ms: 1_000, keep_idle: 0, ..Policy::default() });
    s.set_loads(
        [
            ("cmux-runner-pool-a".to_owned(), load(95.0, None)),
            ("cmux-runner-pool-b".to_owned(), load(40.0, Some(93.0))),
        ]
        .into(),
    );
    let d = s.tick(0, &machines, &roster, Demand::Jobs(1));
    assert!(d.all_full, "a at 95% CPU, b at 93% RAM: both at the line");
    assert_eq!(d.resume, vec!["id-fsp-c".to_owned()]);
    // One machine under the line: no growth (work goes there).
    s.set_loads(
        [
            ("cmux-runner-pool-a".to_owned(), load(95.0, None)),
            ("cmux-runner-pool-b".to_owned(), load(60.0, Some(50.0))),
        ]
        .into(),
    );
    let d = s.tick(1, &machines, &roster, Demand::Jobs(1));
    assert!(!d.all_full && d.resume.is_empty());
    // Quiet (under 20% CPU, no job) for the idle window: pause; a quiet VM with a job never pauses.
    let busy_b = vec![
        runner("cmux-runner-pool-a-1", false, false),
        runner("cmux-runner-pool-b-1", true, true),
    ];
    s.set_loads(
        [
            ("cmux-runner-pool-a".to_owned(), load(5.0, None)),
            ("cmux-runner-pool-b".to_owned(), load(5.0, None)),
        ]
        .into(),
    );
    assert!(s.tick(10, &machines, &busy_b, Demand::Jobs(0)).pause.is_empty());
    let d = s.tick(1_010, &machines, &busy_b, Demand::Jobs(0));
    assert_eq!(
        d.pause,
        vec!["id-cmux-runner-pool-a".to_owned()],
        "a quiet with its listener stopped pauses; b has a job"
    );
}

#[test]
fn runners_of_paused_machines_are_no_idle_capacity() {
    // GitHub still shows the paused machines' runners online: they neither cover queued jobs nor hold the floor.
    let machines = vec![
        machine(Provider::Freestyle, "fsp-a", Power::Paused, 1),
        machine(Provider::Freestyle, "fsp-b", Power::Paused, 1),
        machine(Provider::Freestyle, "fsp-c", Power::Running, 1),
    ];
    let roster = vec![
        runner("fsp-a", true, false),
        runner("fsp-b", true, false),
        runner("fsp-c", true, false),
    ];
    let mut s = Scheduler::new(Policy { idle_ms: 0, keep_idle: 1, ..Policy::default() });
    let d = s.tick(0, &machines, &roster, Demand::Jobs(2));
    assert_eq!(d.idle_online, 1);
    assert_eq!(d.resume, vec!["id-fsp-a".to_owned()], "2 queued, 1 idle on a running machine");
    let mut s = Scheduler::new(Policy { idle_ms: 0, keep_idle: 1, ..Policy::default() });
    let d = s.tick(0, &machines, &roster, Demand::Jobs(0));
    assert!(d.pause.is_empty(), "the one running idle runner is the floor");
}

#[test]
fn all_full_waits_for_what_it_resumed_and_for_every_running_vm_measured() {
    use crate::load::Load;
    let full = Load { cpu_pct: 95.0, mem_pct: None };
    let mut machines = vec![
        machine(Provider::Gcp, "cmux-runner-pool-a", Power::Running, 1),
        machine(Provider::Freestyle, "fsp-b", Power::Paused, 1),
        machine(Provider::Freestyle, "fsp-c", Power::Paused, 1),
    ];
    let roster = vec![runner("cmux-runner-pool-a", true, true)];
    let mut s = Scheduler::new(Policy::default());
    s.set_loads([("cmux-runner-pool-a".to_owned(), full)].into());
    let d = s.tick(0, &machines, &roster, Demand::Jobs(1));
    assert_eq!(d.resume, vec!["id-fsp-b".to_owned()]);
    // fsp-b is now running with no runner online and no reading: on its way, so the next tick resumes nothing.
    machines[1].power = Power::Running;
    let d = s.tick(5_000, &machines, &roster, Demand::Jobs(1));
    assert_eq!(d.starting, 1);
    assert!(d.resume.is_empty() && !d.all_full);
    // Past the grace window it is no longer on its way, but it is unmeasured: still no growth.
    let d = s.tick(5_000 + 3 * 60 * 1000, &machines, &roster, Demand::Jobs(1));
    assert_eq!(
        d.starting, 0,
        "a running VM with no runner online past the grace window is not capacity"
    );
    assert!(!d.all_full);
}

#[test]
fn queued_jobs_beside_a_vcpu_demand_block_pauses() {
    let machines = vec![machine(Provider::Freestyle, "fsp-a", Power::Running, 1)];
    let roster = vec![runner("fsp-a", true, false)];
    let mut s = Scheduler::new(Policy { idle_ms: 0, keep_idle: 0, ..Policy::default() });
    let d = s.tick(0, &machines, &roster, Demand::Vcpu { vcpu: 0, queued: 2 });
    assert!(d.pause.is_empty(), "jobs are queued");
    assert_eq!(d.queued, 2);
    let d = s.tick(1, &machines, &roster, Demand::Vcpu { vcpu: 0, queued: 0 });
    assert_eq!(d.pause, vec!["id-fsp-a".to_owned()]);
}

#[test]
fn measured_vcpu_room_is_the_headroom_under_the_line() {
    use crate::load::Load;
    let mut a = machine(Provider::Gcp, "cmux-runner-pool-a", Power::Running, 4);
    a.vcpu = 32;
    let mut b = machine(Provider::Freestyle, "fsp-b", Power::Paused, 1);
    b.vcpu = 16;
    let machines = vec![a, b];
    // Every runner looks idle, but the VM is measured at 65%: 32 x (90 - 65)% = 8 vCPU of room.
    let roster = vec![
        runner("cmux-runner-pool-a-1", true, false),
        runner("cmux-runner-pool-a-2", true, false),
    ];
    let mut s = Scheduler::new(Policy::default());
    s.set_loads(
        [("cmux-runner-pool-a".to_owned(), Load { cpu_pct: 65.0, mem_pct: Some(10.0) })].into(),
    );
    let d = s.tick(0, &machines, &roster, Demand::Vcpu { vcpu: 8, queued: 1 });
    assert_eq!(d.free_vcpu, 8);
    assert!(d.resume.is_empty());
    let d = s.tick(1, &machines, &roster, Demand::Vcpu { vcpu: 12, queued: 1 });
    assert_eq!(d.resume, vec!["id-fsp-b".to_owned()]);
}

#[test]
fn an_offline_baseline_before_since_counts_a_fast_resume() {
    let wanted: HashSet<String> = ["fsp-a", "fsp-b"].map(str::to_owned).into();
    let mut t = Tracker::new(1_000, Some(wanted));
    // Before the resume GitHub shows fsp-a offline and fsp-b online (stale): the resume is faster than any
    // read after `since` could see fsp-a offline.
    t.baseline(&[runner("fsp-a", false, false), runner("fsp-b", true, false)]);
    t.observe(1_200, &[runner("fsp-a", true, false), runner("fsp-b", true, false)]);
    assert_eq!(t.online(), vec![("fsp-a".to_owned(), 200)]);
    // An online sighting before `since` disarms an earlier offline one.
    let mut t = Tracker::new(1_000, Some(["fsp-c".to_owned()].into()));
    t.observe(800, &[runner("fsp-c", false, false)]);
    t.observe(900, &[runner("fsp-c", true, false)]);
    t.observe(1_100, &[runner("fsp-c", true, false)]);
    assert_eq!(t.online_count(), 0);
}

#[test]
fn the_idle_pause_takes_only_opted_in_machines() {
    // The persistent pools (no opt-in) stay running however idle; an opted-in machine or a --pause-prefix pauses.
    let mut persistent = machine(Provider::Freestyle, "fsp-a", Power::Running, 1);
    persistent.schedule_pause = false;
    let mut gce = machine(Provider::Gcp, "cmux-runner-pool-b", Power::Running, 1);
    gce.schedule_pause = false;
    let opted = machine(Provider::Freestyle, "fsp-c", Power::Running, 1);
    let machines = vec![persistent, gce, opted];
    let roster = vec![
        runner("fsp-a", true, false),
        runner("cmux-runner-pool-b", true, false),
        runner("fsp-c", true, false),
    ];
    let policy = Policy { idle_ms: 0, keep_idle: 0, ..Policy::default() };
    let mut s = Scheduler::new(policy.clone());
    assert_eq!(s.tick(0, &machines, &roster, Demand::Jobs(0)).pause, vec!["id-fsp-c".to_owned()]);
    let mut s =
        Scheduler::new(Policy { pause_prefixes: vec!["cmux-runner-pool-".to_owned()], ..policy });
    let mut paused = s.tick(0, &machines, &roster, Demand::Jobs(0)).pause;
    paused.sort();
    assert_eq!(paused, vec!["id-cmux-runner-pool-b".to_owned(), "id-fsp-c".to_owned()]);
    // Resumes still take persistent machines: opting in is about pausing only.
    let mut paused_persistent = machine(Provider::Freestyle, "fsp-d", Power::Paused, 1);
    paused_persistent.schedule_pause = false;
    let mut s = Scheduler::new(Policy::default());
    let d = s.tick(0, &[paused_persistent], &[], Demand::Jobs(1));
    assert_eq!(d.resume, vec!["id-fsp-d".to_owned()]);
}

#[test]
fn providers_read_the_schedule_opt_in() {
    let vm = json!({"id": "v1", "state": "running", "metadata": {"purpose": "freestyle-pool", "fsp_runner": "fsp-x", "cmux_schedule": "pause"}});
    assert!(freestyle::parse_vm(&vm, "freestyle-pool").is_some_and(|m| m.schedule_pause));
    let vm = json!({"id": "v2", "state": "running", "metadata": {"purpose": "freestyle-pool", "fsp_runner": "fsp-y"}});
    assert!(freestyle::parse_vm(&vm, "freestyle-pool").is_some_and(|m| !m.schedule_pause));
    let inst = json!({"name": "cmux-runner-pool-z", "status": "RUNNING", "labels": {"purpose": "cmux-runner-pool", "cmux-schedule": "pause"}});
    assert!(gce::parse_instance(&inst).is_some_and(|m| m.schedule_pause));
    let inst = json!({"name": "cmux-runner-pool-w", "status": "RUNNING", "labels": {"purpose": "cmux-runner-pool"}});
    assert!(gce::parse_instance(&inst).is_some_and(|m| !m.schedule_pause));
}

mod runner_tests;
