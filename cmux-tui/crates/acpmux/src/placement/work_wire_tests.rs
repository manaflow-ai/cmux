//! The placer in the command path: the samplers over canned `/proc`, `pmset` and `ioreg` text, and
//! one test for each `decide` branch the hook can take, from the command and the host to the route.

use super::*;
use std::collections::HashMap;

/// A host whose files and commands answer canned text.
#[derive(Default)]
struct Fake {
    files: HashMap<&'static str, &'static str>,
    commands: HashMap<&'static str, &'static str>,
    ncpu: f64,
}

impl Probe for Fake {
    fn read(&self, path: &str) -> Option<String> {
        self.files.get(path).map(|s| (*s).to_owned())
    }

    fn run(&self, program: &str, _args: &[&str]) -> Option<String> {
        self.commands.get(program).map(|s| (*s).to_owned())
    }

    fn ncpu(&self) -> f64 {
        self.ncpu
    }
}

const PMSET_AC: &str = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4653155)\t100%; charged; 0:00 remaining present: true\n";
const PMSET_LOW: &str = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4653155)\t9%; discharging; 0:31 remaining present: true\n";
const LID_OPEN: &str =
    "+-o AppleARMPE  <class IOService>\n    {\n      \"AppleClamshellState\" = No\n    }\n";
const LID_SHUT: &str =
    "+-o AppleARMPE  <class IOService>\n    {\n      \"AppleClamshellState\" = Yes\n    }\n";
const VM_STAT: &str = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                               65536.\nPages active:                            500000.\nPages inactive:                          262144.\nPages speculative:                        65536.\nPages purgeable:                          131072.\n";

fn mac(pmset: &'static str, lid: &'static str) -> Fake {
    Fake {
        commands: HashMap::from([
            ("sysctl", "{ 1.50 1.20 1.00 }\n"),
            ("vm_stat", VM_STAT),
            ("pmset", pmset),
            ("ioreg", lid),
        ]),
        ncpu: 12.0,
        ..Fake::default()
    }
}

fn linux(loadavg: &'static str, psi: &'static str, meminfo: &'static str, ncpu: f64) -> Fake {
    Fake {
        files: HashMap::from([
            ("/proc/loadavg", loadavg),
            ("/proc/pressure/cpu", psi),
            ("/proc/meminfo", meminfo),
        ]),
        ncpu,
        ..Fake::default()
    }
}

const PSI_QUIET: &str = "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
const PSI_BUSY: &str = "some avg10=62.50 avg60=40.00 avg300=20.00 total=99\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
/// 16 GiB total, 12 GiB available.
const MEM_ROOMY: &str =
    "MemTotal:       16777216 kB\nMemFree:         1000000 kB\nMemAvailable:   12582912 kB\n";
/// 8 GiB total, 5 GiB available.
const MEM_TIGHT: &str =
    "MemTotal:        8388608 kB\nMemFree:          500000 kB\nMemAvailable:    5242880 kB\n";

const VM: Option<&str> = Some("vm_abc");

/// Samples `probe`, places `command` and routes it: the hook's whole path but the row.
fn path(
    probe: &Fake,
    os: Os,
    machine: Option<&str>,
    command: &str,
    past: &[Past],
) -> (Verdict, Route) {
    let host = sample(probe, os);
    let total = probe.read("/proc/meminfo").as_deref().and_then(mem_total_gib);
    let machines = machines_now(machine, &host, total);
    let (_, verdict) = place(command, &host, &machines, past);
    let route = route(&verdict, machine);
    (verdict, route)
}

// The samplers.

#[test]
fn linux_sampler_reads_load_psi_and_memory() {
    let host = sample(&linux("3.25 2.00 1.00 2/400 999\n", PSI_BUSY, MEM_ROOMY, 8.0), Os::Linux);
    assert_eq!(host.ncpu, 8.0);
    assert_eq!(host.load1, 3.25);
    assert_eq!(host.psi_cpu_some10, Some(62.5));
    assert_eq!(host.mem_available_gib, 12.0);
    assert!(!host.sleeping && !host.on_battery);
}

#[test]
fn mac_sampler_reads_load_memory_battery_and_lid() {
    let host = sample(&mac(PMSET_LOW, LID_SHUT), Os::Mac);
    assert_eq!(host.load1, 1.5);
    assert_eq!(host.psi_cpu_some10, None);
    // (65536 + 262144 + 65536 + 131072) pages of 16 KiB = 8 GiB.
    assert_eq!(host.mem_available_gib, 8.0);
    assert!(host.on_battery);
    assert_eq!(host.battery_percent, Some(9));
    assert!(host.sleeping);
    let host = sample(&mac(PMSET_AC, LID_OPEN), Os::Mac);
    assert!(!host.on_battery && !host.sleeping);
    assert_eq!(host.battery_percent, Some(100));
}

#[test]
fn a_sampler_that_cannot_see_reads_quiet() {
    let host = sample(&Fake { ncpu: 4.0, ..Fake::default() }, Os::Linux);
    assert_eq!((host.load1, host.psi_cpu_some10), (0.0, None));
    assert!(host.mem_available_gib.is_infinite());
    let host = sample(&Fake { ncpu: 4.0, ..Fake::default() }, Os::Mac);
    assert!(!host.sleeping && !host.on_battery && host.battery_percent.is_none());
}

#[test]
fn work_reads_class_need_and_history() {
    let w = work_for("cd x && cargo test -p acpmux", &[]);
    assert_eq!(w.class, Class::Rust);
    assert_eq!(w.need, Some(Shape { vcpu: 10.0, mem_gib: 17.0 }));
    assert_eq!((w.local_s, w.cpu_s), (None, None));
    let past = [
        Past { wall_s: 30.0, cpu_s: Some(100.0) },
        Past { wall_s: 90.0, cpu_s: None },
        Past { wall_s: 60.0, cpu_s: Some(200.0) },
    ];
    let w = work_for("xcodebuild -scheme cmux", &past);
    assert_eq!(w.class, Class::Swift);
    assert_eq!(w.local_s, Some(60.0));
    assert_eq!(w.cpu_s, Some(200.0));
    assert_eq!(work_for("pnpm test", &[]).class, Class::Other);
}

#[test]
fn history_keeps_the_newest_runs_of_the_class() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("command-placer.jsonl");
    let class = crate::placement::command_shadow::class_of("pnpm test");
    let mut text = String::new();
    for wall in 1..=7 {
        text.push_str(&format!(
            "{{\"class\":\"{class}\",\"wallS\":{wall},\"usage\":{{\"cpuS\":2}}}}\n"
        ));
        text.push_str("{\"class\":\"other\",\"wallS\":999}\nnot json\n");
    }
    std::fs::write(&file, text).unwrap();
    let past = history(&file, "pnpm test");
    let walls: Vec<f64> = past.iter().map(|p| p.wall_s).collect();
    assert_eq!(walls, vec![3.0, 4.0, 5.0, 6.0, 7.0]);
    assert!(past.iter().all(|p| p.cpu_s == Some(2.0)));
    assert!(history(&dir.path().join("none.jsonl"), "pnpm test").is_empty());
}

// Each branch the hook takes.

#[test]
fn fits_on_an_idle_mac_runs_here() {
    let (v, r) = path(&mac(PMSET_AC, LID_OPEN), Os::Mac, None, "pnpm test", &[]);
    assert_eq!((v.place, v.reason), (Place::Local, Reason::Fits));
    assert_eq!(r, Route::Here);
}

#[test]
fn lid_shut_sends_work_off_the_mac_and_says_why_it_ran_here() {
    let (v, r) = path(&mac(PMSET_AC, LID_SHUT), Os::Mac, None, "pnpm test", &[]);
    assert_eq!(v.reason, Reason::Sleep);
    assert_eq!(v.place, Place::BiggerVm { shape: Shape { vcpu: 8.0, mem_gib: 6.0 } });
    assert_eq!(r, Route::Unreached("no VM create with a shape from this computer yet"));
}

#[test]
fn low_battery_sends_work_off_the_mac() {
    let (v, r) = path(&mac(PMSET_LOW, LID_OPEN), Os::Mac, None, "pnpm test", &[]);
    assert_eq!(v.reason, Reason::LowBattery);
    assert!(matches!(v.place, Place::BiggerVm { .. }));
    assert!(matches!(r, Route::Unreached(_)));
}

#[test]
fn huge_rust_build_on_a_cloud_vm_goes_to_the_fork() {
    let probe = linux("0.10 0.10 0.10 1/100 1\n", PSI_QUIET, MEM_ROOMY, 4.0);
    let (v, r) = path(&probe, Os::Linux, VM, "cargo build --release", &[]);
    assert_eq!((v.place, v.reason), (Place::Pool, Reason::Huge));
    assert_eq!(r, Route::Fork);
    // The same build on a Mac: the pool has no dispatch from an agent's call.
    let (v, r) = path(&mac(PMSET_AC, LID_OPEN), Os::Mac, None, "cargo build --release", &[]);
    assert_eq!((v.place, v.reason), (Place::Pool, Reason::Huge));
    assert_eq!(r, Route::Unreached("no pool dispatch from an agent's call yet"));
}

#[test]
fn memory_short_on_a_cloud_vm_grows_onto_the_fork() {
    let probe = linux("0.10 0.10 0.10 1/100 1\n", PSI_QUIET, MEM_TIGHT, 4.0);
    let (v, r) = path(&probe, Os::Linux, VM, "pnpm test", &[]);
    assert_eq!(v.reason, Reason::MemoryShort);
    assert_eq!(v.place, Place::Grow { to: Shape { vcpu: 8.0, mem_gib: 8.0 } });
    assert_eq!(r, Route::Fork);
}

#[test]
fn stretch_on_a_loaded_vm_moves_known_long_work_to_the_fork() {
    let probe = linux("12.00 10.00 8.00 9/400 1\n", PSI_BUSY, MEM_ROOMY, 16.0);
    let past = [Past { wall_s: 120.0, cpu_s: Some(600.0) }];
    let (v, r) = path(&probe, Os::Linux, VM, "pnpm test", &past);
    assert_eq!((v.place, v.reason), (Place::WorkVm { resume: false }, Reason::Stretch));
    assert!(v.lose_s.unwrap() > v.remote_s.unwrap());
    assert_eq!(r, Route::Fork);
}

#[test]
fn work_that_fits_its_cloud_vm_stays_on_it() {
    let probe = linux("0.50 0.50 0.50 1/100 1\n", PSI_QUIET, MEM_ROOMY, 16.0);
    let past = [Past { wall_s: 120.0, cpu_s: Some(600.0) }];
    let (v, r) = path(&probe, Os::Linux, VM, "pnpm test", &past);
    assert_eq!((v.place, v.reason), (Place::WorkVm { resume: false }, Reason::OnVm));
    assert_eq!(r, Route::Here);
}

// The routes decide's other places take.

#[test]
fn every_place_has_a_route() {
    let v = |place| Verdict {
        place,
        reason: Reason::Pinned,
        lose_s: None,
        remote_s: None,
        estimate_card: None,
    };
    let big = Shape { vcpu: 8.0, mem_gib: 16.0 };
    assert_eq!(route(&v(Place::Local), VM), Route::Here);
    assert_eq!(route(&v(Place::WorkVm { resume: true }), VM), Route::Here);
    let mut stretched = v(Place::WorkVm { resume: false });
    stretched.reason = Reason::Stretch;
    assert_eq!(route(&stretched, VM), Route::Fork);
    assert_eq!(
        route(&v(Place::WorkVm { resume: false }), None),
        Route::Unreached("no work VM for this computer yet")
    );
    assert_eq!(route(&v(Place::Grow { to: big }), VM), Route::Fork);
    assert_eq!(route(&v(Place::BiggerVm { shape: big }), VM), Route::Fork);
    assert_eq!(route(&v(Place::Pool), VM), Route::Fork);
    assert_eq!(route(&v(Place::ServeVm), VM), Route::Unreached("no serve VMs yet"));
    assert_eq!(route(&v(Place::ServeVm), None), Route::Unreached("no serve VMs yet"));
    assert_eq!(
        route(&v(Place::Pool), Some("  ")),
        Route::Unreached("no pool dispatch from an agent's call yet")
    );
}

// The switch.

#[test]
fn the_hook_question_keeps_light_and_killed_calls_here() {
    // Not heavy: no sample, no row.
    assert_eq!(hook_goes(true, VM, "ls -la"), None);
    // The run-VM kill switch thrown: heavy work still runs here.
    assert_eq!(hook_goes(false, VM, "cargo build"), None);
}

#[test]
fn rows_carry_the_inputs_verdict_and_route() {
    let probe = linux("0.10 0.10 0.10 1/100 1\n", PSI_QUIET, MEM_ROOMY, 4.0);
    let host = sample(&probe, Os::Linux);
    let machines = machines_now(VM, &host, Some(16.0));
    let (work, verdict) = place("cargo build", &host, &machines, &[]);
    let route = route(&verdict, VM);
    let row = Row {
        class: "a Rust build",
        work: &work,
        host: &host,
        machines: &machines,
        verdict: &verdict,
        route: &route,
    };
    let v = serde_json::to_value(&row).unwrap();
    assert_eq!(v["route"], "fork");
    assert_eq!(v["verdict"]["reason"], "huge");
    assert_eq!(v["verdict"]["place"]["place"], "pool");
    assert_eq!(v["host"]["load1"], 0.1);
    assert_eq!(v["machines"]["workVm"]["shape"]["vcpu"], 4.0);
    let unreached = Route::Unreached("no serve VMs yet");
    let row = Row { route: &unreached, ..row };
    let v = serde_json::to_value(&row).unwrap();
    assert_eq!(
        (v["route"].as_str(), v["cause"].as_str()),
        (Some("unreached"), Some("no serve VMs yet"))
    );
}
