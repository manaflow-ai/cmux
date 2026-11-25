use super::pressure::{Pressure, Reading, Tracker, parse};
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

/// More runnable tasks than vCPUs on two probes in a row pegs the CPU; a single burst does not, and
/// it clears after as many probes below.
#[test]
fn cpu_pegs_on_two_probes_in_a_row() {
    let mut t = Tracker::default();
    assert!(!t.observe(&reading(500, 0, 9), 0).cpu_pegged, "one probe is a burst");
    assert!(!t.observe(&reading(500, 0, 1), 5_000).cpu_pegged);
    assert!(!t.observe(&reading(500, 0, 9), 10_000).cpu_pegged);
    assert!(t.observe(&reading(500, 0, 9), 15_000).cpu_pegged);
    assert_eq!(t.observe(&reading(500, 0, 9), 20_000).to_json(), Some(json!({"cpu": "pegged"})));
    assert!(t.observe(&reading(500, 0, 2), 25_000).cpu_pegged, "as many as vCPUs: one probe");
    assert!(!t.observe(&reading(500, 0, 2), 30_000).cpu_pegged);
}
