use super::*;

const MIB: u64 = 1 << 20;
const PAGE: u64 = 4096;

/// A cgroup with a hot set it reads back as soon as anything of it is reclaimed, a cold rest,
/// and memory the kernel cannot reclaim (anonymous memory without swap).
struct Fake {
    hot: u64,
    cold: u64,
    pinned: u64,
    refaults: u64,
    asked: Vec<u64>,
}

impl Cgroup for Fake {
    fn sample(&mut self) -> anyhow::Result<Sample> {
        Ok(Sample { current: self.hot + self.cold + self.pinned, refaults: self.refaults })
    }

    fn reclaim(&mut self, bytes: u64) -> anyhow::Result<bool> {
        self.asked.push(bytes);
        if self.cold + self.hot == 0 {
            return Ok(false);
        }
        let from_cold = bytes.min(self.cold);
        self.cold -= from_cold;
        // What came out of the hot set is read straight back: a refault per page, size unchanged.
        let from_hot = (bytes - from_cold).min(self.hot);
        self.refaults += from_hot / PAGE;
        Ok(true)
    }

    fn settle(&mut self, _ms: u64) {}
}

fn fake(hot: u64, cold: u64, pinned: u64) -> Fake {
    Fake { hot, cold, pinned, refaults: 0, asked: Vec::new() }
}

#[test]
fn it_stops_at_the_hot_set_once_refaults_rise() {
    let mut cg = fake(500 * MIB, 1500 * MIB, 0);
    let probe = Probe { max_steps: 1000, ..Probe::default() };
    let report = run(&probe, &mut cg, "/t", PAGE).unwrap();
    assert_eq!(report.stopped_by, Stop::Refaults);
    // Within one step of the hot set.
    let step = (report.working_set_bytes * probe.step_permille / 1000).max(probe.min_step_bytes);
    assert!(report.working_set_bytes >= 500 * MIB, "{report:?}");
    assert!(report.working_set_bytes <= 500 * MIB + step, "{report:?}");
    assert_eq!(report.start_bytes, 2000 * MIB);
    assert!(report.refaulted_pages > 0);
}

#[test]
fn what_the_kernel_cannot_reclaim_counts_as_working_set() {
    let mut cg = fake(0, 300 * MIB, 700 * MIB);
    let probe = Probe { max_steps: 1000, ..Probe::default() };
    let report = run(&probe, &mut cg, "/t", PAGE).unwrap();
    assert_eq!(report.stopped_by, Stop::NothingReclaimable);
    assert_eq!(report.working_set_bytes, 700 * MIB);
    assert_eq!(report.reclaimed_bytes, 300 * MIB);
}

#[test]
fn it_is_bounded_by_its_step_cap_and_its_floor() {
    let mut cg = fake(0, 4000 * MIB, 0);
    let report = run(&Probe { max_steps: 3, ..Probe::default() }, &mut cg, "/t", PAGE).unwrap();
    assert_eq!((report.steps, report.stopped_by), (3, Stop::MaxSteps));
    assert_eq!(cg.asked.len(), 3);

    let mut small = fake(0, 70 * MIB, 0);
    let report = run(&Probe::default(), &mut small, "/t", PAGE).unwrap();
    assert_eq!((report.steps, report.stopped_by), (0, Stop::Floor));
    assert!(small.asked.is_empty());
}

#[test]
fn a_step_is_a_share_of_the_cgroup_with_a_minimum() {
    let probe = Probe::default();
    let big = Sample { current: 10_000 * MIB, refaults: 0 };
    assert_eq!(next(&probe, big, None, 0, PAGE), Next::Reclaim(200 * MIB));
    let small = Sample { current: 200 * MIB, refaults: 0 };
    assert_eq!(next(&probe, small, None, 0, PAGE), Next::Reclaim(16 * MIB));
    // 10% of a 100 MiB step came back: at the line, not past it.
    let at = Some((100 * MIB, 10 * MIB / PAGE));
    assert_eq!(next(&probe, big, at, 1, PAGE), Next::Reclaim(200 * MIB));
    let past = Some((100 * MIB, 10 * MIB / PAGE + 1));
    assert_eq!(next(&probe, big, past, 1, PAGE), Next::Stop(Stop::Refaults));
}

#[test]
fn refaults_sum_anon_and_file_from_memory_stat() {
    let stat = "anon 1\nworkingset_refault_anon 7\nworkingset_refault_file 35\nworkingset_activate_file 9\n";
    assert_eq!(refaults(stat), 42);
    assert_eq!(refaults(""), 0);
}

#[test]
fn the_default_cgroup_is_the_sessions_slice_of_this_user_manager() {
    let own = "0::/user.slice/user-1001.slice/user@1001.service/acpmuxsessions.slice/acpmuxsessions-ab.slice/run-r1.scope\n";
    assert_eq!(
        default_cgroup(own).as_deref(),
        Some("/user.slice/user-1001.slice/user@1001.service/acpmuxsessions.slice")
    );
    assert_eq!(default_cgroup("0::/system.slice/ssh.service\n"), None);
    assert_eq!(default_cgroup(""), None);
}

#[test]
fn the_report_is_camel_case_json() {
    let report = Report {
        cgroup: "/t".into(),
        start_bytes: 2,
        working_set_bytes: 1,
        reclaimed_bytes: 1,
        refaulted_pages: 0,
        steps: 1,
        stopped_by: Stop::NothingReclaimable,
        elapsed_ms: 5,
    };
    let v = serde_json::to_value(&report).unwrap();
    assert_eq!(v["workingSetBytes"], 1);
    assert_eq!(v["stoppedBy"], "nothing_reclaimable");
}
