use super::pressure::{CPU_PROBES, PROBE_INTERVAL_MS, Pressure, Reading, Tracker, parse, rose};
use serde_json::json;

const MEMINFO: &str =
    "MemTotal:       4000000 kB\nMemFree:         100000 kB\nMemAvailable:    300000 kB\n";
const VMSTAT: &str = "pgfault 12\noom_kill 3\n";
const STAT: &str = "cpu  1 2 3\ncpu0 1 2 3\ncpu1 1 2 3\nintr 5\nprocs_running 7\nprocs_blocked 0\n";

fn reading(avail: u64, oom: u64, run_queue: u64) -> Reading {
    Reading { mem_total_kib: 1000, mem_available_kib: avail, oom_kills: oom, run_queue, cpus: 2 }
}

/// The three files parse into one reading: the probe's own thread leaves the run queue, and the
/// aggregate `cpu` line is not a CPU.
#[test]
fn the_kernel_files_parse_into_a_reading() {
    let r = parse(MEMINFO, VMSTAT, STAT).unwrap();
    assert_eq!(
        r,
        Reading {
            mem_total_kib: 4_000_000,
            mem_available_kib: 300_000,
            oom_kills: 3,
            run_queue: 6,
            cpus: 2
        }
    );
    assert_eq!(parse(MEMINFO, "", STAT).unwrap().oom_kills, 0, "no counter: no rise");
    assert!(parse("MemTotal: 0 kB\nMemAvailable: 0 kB\n", VMSTAT, STAT).is_none());
    assert!(parse(MEMINFO, VMSTAT, "cpu0 1\n").is_none(), "no procs_running");
}

/// Memory under its 10% line is low at once; an OOM kill after the first reading is a rise; the
/// block names only what is short.
#[test]
fn memory_and_oom_report_at_once() {
    let mut t = Tracker::default();
    assert_eq!(t.observe(&reading(500, 4, 0), 1_000).to_json(), None, "a baseline, nothing short");
    assert_eq!(t.observe(&reading(50, 4, 0), 2_000).to_json(), Some(json!({"memory": "low"})));
    let p = t.observe(&reading(500, 5, 0), 3_000).clone();
    assert_eq!(p, Pressure { memory_low: false, cpu_pegged: false, oom_rise_at: Some(3_000) });
    assert_eq!(t.observe(&reading(500, 5, 0), 4_000).oom_rise_at, Some(3_000), "kept, not renewed");
}

/// More runnable tasks than vCPUs on three probes in a row (2 s held) pegs the CPU; a burst does
/// not, and it clears after as many probes below.
#[test]
fn cpu_pegs_on_three_probes_in_a_row() {
    let mut t = Tracker::default();
    assert!(!t.observe(&reading(500, 0, 9), 0).cpu_pegged, "one probe is a burst");
    assert!(!t.observe(&reading(500, 0, 9), 1_000).cpu_pegged, "two probes are a burst");
    assert!(!t.observe(&reading(500, 0, 1), 2_000).cpu_pegged);
    assert!(!t.observe(&reading(500, 0, 9), 3_000).cpu_pegged);
    assert!(!t.observe(&reading(500, 0, 9), 4_000).cpu_pegged);
    assert!(t.observe(&reading(500, 0, 9), 5_000).cpu_pegged, "held 2 s");
    assert_eq!(t.observe(&reading(500, 0, 9), 6_000).to_json(), Some(json!({"cpu": "pegged"})));
    assert!(t.observe(&reading(500, 0, 2), 7_000).cpu_pegged, "as many as vCPUs: one probe");
    assert!(t.observe(&reading(500, 0, 2), 8_000).cpu_pegged);
    assert!(!t.observe(&reading(500, 0, 2), 9_000).cpu_pegged);
}

/// The probe's timing is what makes "within 5 s" possible: memory seen within a second, a pegged
/// CPU within two, both well inside the platform's 5 s.
#[test]
fn the_probe_sees_pressure_within_two_seconds() {
    const {
        assert!(PROBE_INTERVAL_MS <= 1_000);
        assert!(PROBE_INTERVAL_MS * (CPU_PROBES as u64 - 1) <= 2_000);
    }
}

/// A block that names something newly short (or a newer OOM rise) rose and goes at once; one that
/// only clears, or says the same, did not.
#[test]
fn a_block_rose_only_when_something_new_is_short() {
    let low = json!({"memory": "low"});
    let both = json!({"memory": "low", "cpu": "pegged"});
    assert!(rose(None, Some(&low)));
    assert!(rose(Some(&low), Some(&both)));
    assert!(!rose(Some(&both), Some(&low)), "a clear waits");
    assert!(!rose(Some(&low), None));
    assert!(!rose(Some(&low), Some(&low)));
    assert!(rose(Some(&json!({"oom_rise_at": 1})), Some(&json!({"oom_rise_at": 2}))));
}

/// `trigger_now` sends past the 10 s floor, and a report it finds in flight goes the moment that
/// one is answered rather than at the floor; a plain trigger still waits.
#[test]
fn a_rise_goes_past_the_report_floor() {
    use super::sender::{Answer, Reporter};
    use super::wire::DaemonInfo;
    let ok = Answer::Http { status: 200, body: json!({"ok": true, "value": {}}) };
    let mut r =
        Reporter::new("m", DaemonInfo { version: "0.1.0".to_owned(), capabilities: Vec::new() });
    assert!(r.trigger("start", 0).is_some());
    assert!(r.finished(&ok, 100, 0.5).is_none());
    assert!(r.trigger("change", 1_000).is_none(), "a plain change waits for the floor");
    let req = r.trigger_now("pressure", 1_500).expect("a rise goes now");
    assert!(req.reason.contains("pressure") && req.reason.contains("change"), "{}", req.reason);
    assert!(r.trigger_now("pressure", 1_600).is_none(), "one in flight");
    let next = r.finished(&ok, 1_700, 0.5).expect("goes on the answer");
    assert_eq!(next.reason, "pressure");
    assert!(r.finished(&ok, 1_800, 0.5).is_none());
    assert!(r.trigger("change", 2_000).is_none(), "the floor holds again after the urgent send");
}
