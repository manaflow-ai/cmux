use super::*;
use serde_json::json;

fn at(secs: u64) -> Sample {
    Sample { at: secs * 1000, ..Sample::default() }
}
fn mem(secs: u64, v: f64) -> Sample {
    Sample { mem_available_fraction: Some(v), ..at(secs) }
}
fn states(events: &[Event]) -> Vec<String> {
    events
        .iter()
        .map(|e| {
            let v = serde_json::to_value(e).unwrap();
            format!("{}:{}", v["signal"].as_str().unwrap(), v["state"].as_str().unwrap())
        })
        .collect()
}

#[test]
fn memory_prints_once_per_line_crossed() {
    let mut w = Watch::default();
    assert!(w.step(&mem(0, 0.60)).is_empty());
    assert_eq!(states(&w.step(&mem(1, 0.24))), ["memory:warn"]);
    assert!(w.step(&mem(2, 0.20)).is_empty(), "no repeat while it holds");
    assert_eq!(states(&w.step(&mem(3, 0.09))), ["memory:grow"]);
    assert!(w.step(&mem(4, 0.05)).is_empty());
    // A jump straight from ok to under 10% is one grow line, not warn then grow.
    let mut w = Watch::default();
    assert_eq!(states(&w.step(&mem(0, 0.02))), ["memory:grow"]);
    let v = serde_json::to_value(&w.step(&mem(1, 0.40))[0]).unwrap();
    assert_eq!(
        v,
        json!({"signal": "memory", "at": 1000, "state": "ok", "from": "grow",
               "memAvailableFraction": 0.40})
    );
}

#[test]
fn memory_on_a_line_does_not_flap() {
    let mut w = Watch::default();
    assert_eq!(states(&w.step(&mem(0, 0.249))), ["memory:warn"]);
    for (i, v) in [0.251, 0.249, 0.26, 0.24, 0.29].into_iter().enumerate() {
        assert!(w.step(&mem(i as u64 + 1, v)).is_empty(), "{v} stays warn");
    }
    assert_eq!(states(&w.step(&mem(9, 0.30))), ["memory:ok"]);
    // Grow clears to warn only at 15%.
    let mut w = Watch::default();
    w.step(&mem(0, 0.099));
    assert!(w.step(&mem(1, 0.101)).is_empty());
    assert!(w.step(&mem(2, 0.149)).is_empty());
    assert_eq!(states(&w.step(&mem(3, 0.15))), ["memory:warn"]);
}

#[test]
fn an_oom_kill_rise_prints_and_the_baseline_does_not() {
    let mut w = Watch::default();
    let oom = |secs, n| Sample { oom_kills: Some(n), ..at(secs) };
    assert!(w.step(&oom(0, 4)).is_empty(), "the count at start is the baseline");
    assert!(w.step(&oom(1, 4)).is_empty());
    let e = w.step(&oom(2, 6));
    assert_eq!(e, [Event::OomKill { at: 2000, state: "rise", oom_kills: 6, rise: 2 }]);
    assert!(w.step(&oom(3, 6)).is_empty());
    assert!(w.step(&Sample { oom_kills: None, ..at(4) }).is_empty());
    assert_eq!(states(&w.step(&oom(5, 7))), ["oomKill:rise"]);
}

fn cpu(secs: u64, busy: f64, queue: u64) -> Sample {
    Sample { cpu_busy: Some(busy), run_queue: Some(queue), vcpus: Some(2), ..at(secs) }
}

#[test]
fn cpu_prints_after_five_minutes_saturated_not_four() {
    let mut w = Watch::default();
    for t in 0..=240 {
        assert!(w.step(&cpu(t, 0.97, 5)).is_empty(), "{t}s is not 5 minutes");
    }
    // A break resets the hold: four minutes, a calm second, four more is not five.
    assert!(w.step(&cpu(241, 0.30, 1)).is_empty());
    for t in 242..=482 {
        assert!(w.step(&cpu(t, 0.97, 5)).is_empty());
    }
    let mut fired = Vec::new();
    for t in 483..=600 {
        fired.extend(w.step(&cpu(t, 0.97, 5)));
    }
    assert_eq!(
        fired,
        [Event::Cpu {
            at: 542_000,
            state: "saturated",
            cpu_busy: 0.97,
            run_queue: 5,
            vcpus: 2,
            held_secs: 300
        }]
    );
}

#[test]
fn cpu_needs_both_busy_and_a_queue_over_the_vcpus() {
    let mut w = Watch::default();
    for t in 0..=400 {
        // Busy but the queue fits the vCPUs, then queued but not busy enough.
        let s = if t % 2 == 0 { cpu(t, 0.99, 2) } else { cpu(t, 0.89, 9) };
        assert!(w.step(&s).is_empty());
    }
}

#[test]
fn saturated_cpu_clears_after_a_calm_minute_only() {
    let mut w = Watch::default();
    for t in 0..=300 {
        w.step(&cpu(t, 0.95, 4));
    }
    for t in 301..=330 {
        assert!(w.step(&cpu(t, 0.20, 1)).is_empty());
    }
    // Back to saturated before the minute: still the same burst, no new line.
    for t in 331..=340 {
        assert!(w.step(&cpu(t, 0.95, 4)).is_empty());
    }
    let mut out = Vec::new();
    for t in 341..=401 {
        out.extend(w.step(&cpu(t, 0.20, 1)));
    }
    assert_eq!(states(&out), ["cpu:ok"]);
}

#[test]
fn disk_low_on_either_line_and_clears_past_the_margin() {
    let gib = 1u64 << 30;
    let disk = |secs, bytes, f| Sample {
        disk_free_bytes: Some(bytes),
        disk_free_fraction: Some(f),
        ..at(secs)
    };
    let mut w = Watch::default();
    assert!(w.step(&disk(0, 50 * gib, 0.5)).is_empty());
    assert_eq!(states(&w.step(&disk(1, 3 * gib, 0.09))), ["disk:low"], "under 10%");
    assert!(w.step(&disk(2, 3 * gib, 0.11)).is_empty(), "11% is inside the margin");
    assert_eq!(states(&w.step(&disk(3, 3 * gib, 0.12))), ["disk:ok"]);
    assert_eq!(states(&w.step(&disk(4, gib, 0.5))), ["disk:low"], "under 2 GiB");
    assert!(w.step(&disk(5, 2 * gib + 1, 0.5)).is_empty());
    assert_eq!(states(&w.step(&disk(6, 3 * gib, 0.5))), ["disk:ok"]);
}

#[test]
fn a_guest_with_no_psi_no_swap_and_unread_fields_still_judges_what_it_read() {
    // Freestyle: no /proc/pressure, no swap; the sample has no PSI field at all, and
    // an unread field leaves its signal alone.
    let mut w = Watch::default();
    assert!(w.step(&at(0)).is_empty());
    assert_eq!(states(&w.step(&mem(1, 0.05))), ["memory:grow"]);
    assert!(w.step(&at(2)).is_empty(), "an unread sample does not clear it");
    assert!(w.step(&mem(3, 0.05)).is_empty());
}

fn reclaim(secs: u64, alloc_stalls: u64, refaults: u64) -> Sample {
    let r = crate::host_pressure::Reclaim { alloc_stalls, direct_scanned: 0, refaults };
    Sample { reclaim: Some(r), ..at(secs) }
}

#[test]
fn memory_stalls_on_three_stalled_samples_in_ten_and_clears_after_thirty_calm() {
    let mut w = Watch::default();
    assert!(w.step(&reclaim(0, 500, 9_000)).is_empty(), "the counts at start are the baseline");
    assert!(w.step(&reclaim(1, 501, 9_000)).is_empty(), "one stall is not pressure");
    assert!(w.step(&reclaim(2, 501, 9_000)).is_empty());
    assert!(w.step(&reclaim(3, 501, 9_000 + 2559)).is_empty(), "under 10 MiB of refaults");
    let e = w.step(&reclaim(4, 501, 9_000 + 2559 + 2560));
    assert!(e.is_empty(), "two stalled samples");
    let e = w.step(&reclaim(5, 504, 11_559 + 2560));
    assert_eq!(
        serde_json::to_value(&e[0]).unwrap(),
        json!({"signal": "reclaim", "at": 5000, "state": "stall", "stalledSamples": 3,
               "windowSamples": 10, "allocStalls": 3, "refaults": 0})
    );
    assert!(w.step(&reclaim(6, 600, 14_119)).is_empty(), "no repeat while it holds");
    let mut out = Vec::new();
    for t in 7..=35 {
        out.extend(w.step(&reclaim(t, 600, 14_119)));
    }
    assert!(out.is_empty(), "29 calm samples do not clear it");
    assert_eq!(states(&w.step(&reclaim(36, 600, 14_119))), ["reclaim:ok"]);
}

#[test]
fn stalls_spread_wider_than_the_window_never_fire_and_a_reboot_rebaselines() {
    let mut w = Watch::default();
    let mut stalls = 0;
    for t in 0..100 {
        if t % 5 == 0 {
            stalls += 1;
        }
        assert!(w.step(&reclaim(t, stalls, 0)).is_empty(), "two in ten at {t}s");
    }
    // Counters reset: the lower reading is a new baseline, not a huge rise.
    assert!(w.step(&reclaim(100, 0, 0)).is_empty());
    assert!(w.step(&Sample { reclaim: None, ..at(101) }).is_empty());
}

#[test]
fn flags_move_the_lines() {
    let mut w = Watch::new(Lines { mem_warn: 0.40, cpu_hold_secs: 10, ..Lines::default() });
    assert_eq!(states(&w.step(&mem(0, 0.35))), ["memory:warn"]);
    let mut out = Vec::new();
    for t in 0..=10 {
        out.extend(w.step(&cpu(t, 0.95, 3)));
    }
    assert_eq!(states(&out), ["cpu:saturated"]);
}

#[test]
fn run_queue_and_vcpus_come_from_proc_stat() {
    let stat = "cpu  1 2 3 4 5 6 7 8 0 0\ncpu0 1 1 1 1 1 1 1 1 0 0\ncpu1 1 1 1 1 1 1 1 1 0 0\n\
                    intr 9\nctxt 9\nprocs_running 3\nprocs_blocked 0\n";
    assert_eq!(parse_run_queue_and_vcpus(stat), (Some(3), Some(2)));
    assert_eq!(parse_run_queue_and_vcpus("cpu 1 2 3\n"), (None, None));
}
