use super::*;

const P: u64 = 1 << 63;

#[test]
fn present_pages_coalesce_into_runs_and_absent_ones_split_them() {
    let mut out = Vec::new();
    let n = present_runs(0x1000, 0x1000, &[P, P, 0, P, 0, 0, P, P, P], &mut out);
    assert_eq!(n, 6);
    assert_eq!(out, vec![(0x1000, 2), (0x4000, 1), (0x7000, 3)]);
    // A following VMA that starts right where the last run ends extends it.
    present_runs(0xa000, 0x1000, &[P], &mut out);
    assert_eq!(out.last(), Some(&(0x7000, 4)));
}

#[test]
fn the_daemon_goes_first_then_agents_then_shells() {
    assert_eq!(rank("cmux-tui"), 0);
    assert_eq!(rank("claude"), 1);
    assert_eq!(rank("node"), 1);
    assert_eq!(rank("bash"), 2);
    assert_eq!(rank("sshd"), 3);
}

#[test]
fn a_plan_round_trips_and_another_version_is_not_read() {
    let plan = Plan {
        page: 4096,
        recorded_at_ms: 7,
        procs: vec![ProcPlan {
            pid: 42,
            start: 99,
            comm: "cmux-tui".into(),
            ranges: vec![(0x7f00_0000_0000, 3)],
        }],
    };
    let v = plan.to_json();
    assert_eq!(Plan::from_json(&v), Some(plan.clone()));
    assert_eq!(plan.pages(), 3);
    let mut other = v;
    other["v"] = json!(2);
    assert_eq!(Plan::from_json(&other), None);
    assert_eq!(Plan::from_json(&json!({"v": 1, "procs": "x"})), None);
}

#[test]
fn batches_keep_plan_order_skip_dead_processes_and_cap_at_the_batch_size() {
    let plan = Plan {
        page: 4096,
        recorded_at_ms: 0,
        procs: vec![
            ProcPlan {
                pid: 1,
                start: 1,
                comm: "a".into(),
                ranges: vec![(0, BATCH_PAGES as u64 + 1)],
            },
            ProcPlan { pid: 2, start: 1, comm: "b".into(), ranges: vec![(0, 5)] },
            ProcPlan { pid: 3, start: 1, comm: "c".into(), ranges: vec![(0x10000, 2)] },
        ],
    };
    let b = batches(&plan, &[true, false, true]);
    let shape: Vec<(i32, usize)> = b.iter().map(|(pid, pages)| (*pid, pages.len())).collect();
    assert_eq!(shape, vec![(1, BATCH_PAGES), (1, 1), (3, 2)]);
    assert_eq!(b[2].1, vec![0x10000, 0x11000]);
}

#[cfg(target_os = "linux")]
#[test]
fn records_and_touches_this_test_process_and_skips_a_replaced_one() {
    // 8 MiB this process touched is resident: a record of this pid holds at least those pages.
    let mut held = vec![1u8; 8 << 20];
    held[12345] = 2;
    let me = std::process::id() as i32;
    let page = page_size();
    let ranges = resident(me, page, u64::MAX);
    let pages: u64 = ranges.iter().map(|r| r.1).sum();
    assert!(pages >= (8 << 20) / page, "resident pages {pages}");
    let start = proc_start(me).expect("own start time");
    let plan = Plan {
        page,
        recorded_at_ms: 0,
        procs: vec![ProcPlan { pid: me, start, comm: "test".into(), ranges }],
    };
    let out = prefetch(&plan, 4, Duration::from_secs(30));
    assert_eq!(out.stale_procs, 0);
    assert!(out.touched >= (8 << 20) / page, "{out:?}");
    assert!(out.touched <= out.planned);
    assert!(!out.cut);
    // Same pid, other start time: a recycled pid, not this process.
    let mut stale = plan;
    stale.procs[0].start += 1;
    let out = prefetch(&stale, 2, Duration::from_secs(30));
    assert_eq!((out.stale_procs, out.touched), (1, 0));
    assert_eq!(held[12345], 2);
}

#[cfg(target_os = "linux")]
#[test]
fn a_full_record_names_no_kernel_thread_and_respects_the_page_cap() {
    let plan = record(1000);
    assert!(plan.pages() <= 1000 + 8192, "{}", plan.pages());
    assert!(plan.procs.iter().all(|p| p.pid != 2));
    let ranks: Vec<u8> = plan.procs.iter().map(|p| rank(&p.comm)).collect();
    assert!(ranks.windows(2).all(|w| w[0] <= w[1]), "{ranks:?}");
}
