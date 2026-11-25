use super::*;
use crate::write_journal::MemoryJournalStore;
use crate::write_journal::browse::{ListOutcome, SearchOutcome};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// A machine that takes `delay` to resume, and counts its resumes.
struct FakeResume {
    delay: Duration,
    calls: AtomicUsize,
}

impl FakeResume {
    fn new(delay: Duration) -> Arc<Self> {
        Arc::new(Self { delay, calls: AtomicUsize::new(0) })
    }
}

impl MachineResume for FakeResume {
    fn resume<'a>(
        &'a self,
        _: &'a str,
    ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(self.delay).await;
            Ok(())
        })
    }
}

struct Fixture {
    _dir: tempfile::TempDir,
    machine: PathBuf,
    fs: PausedFs,
}

fn fixture(files: &[(&str, &str)], bounds: SeedBounds) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let machine = dir.path().join("machine");
    std::fs::create_dir_all(&machine).unwrap();
    for (path, text) in files {
        let p = machine.join(path);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }
    let fs =
        PausedFs::new(Arc::new(MemoryJournalStore::default()), dir.path().join("replicas"), bounds)
            .with_serve_reads(true);
    Fixture { machine, fs, _dir: dir }
}

fn text(r: Routed<ReadOutcome>) -> String {
    match r {
        Routed::Answered(ReadOutcome::Text(t)) => t,
        other => panic!("expected text, got {other:?}"),
    }
}

#[test]
fn a_paused_machine_answers_a_read_with_no_resume() {
    let f = fixture(&[("src/a.rs", "fn a() {}\n")], SeedBounds::default());
    let resume = FakeResume::new(Duration::ZERO);
    let report = f.fs.pause("m1", &f.machine, resume.clone(), 0).unwrap();
    assert_eq!((report.files, report.complete, report.generation), (1, true, 1));
    assert_eq!(f.fs.machine_of(&f.machine.join("src")).as_deref(), Some("m1"));
    assert_eq!(text(f.fs.read("m1", &f.machine.join("src/a.rs"), 0).unwrap()), "fn a() {}\n");
    // A complete copy knows what is absent.
    assert_eq!(
        f.fs.read("m1", &f.machine.join("nope.rs"), 0).unwrap(),
        Routed::Answered(ReadOutcome::NotFound)
    );
    assert_eq!(resume.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn a_write_is_journaled_then_flushed_on_resume() {
    let f = fixture(&[("a.txt", "one\n")], SeedBounds::default());
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    let a = f.machine.join("a.txt");
    let b = f.machine.join("new/b.txt");
    assert!(matches!(f.fs.write("m1", &a, "two\n", 0, 1).unwrap(), Routed::Answered(_)));
    assert!(matches!(f.fs.write("m1", &b, "bee\n", 0, 2).unwrap(), Routed::Answered(_)));
    // Nothing on the machine yet; the agent reads its own writes.
    assert_eq!(std::fs::read_to_string(&a).unwrap(), "one\n");
    assert!(!b.exists());
    assert_eq!(text(f.fs.read("m1", &a, 0).unwrap()), "two\n");
    assert_eq!(text(f.fs.read("m1", &b, 0).unwrap()), "bee\n");
    let report = f.fs.resumed("m1").unwrap().unwrap();
    assert!(report.is_clean(), "{report:?}");
    assert_eq!(report.applied.len(), 2);
    assert_eq!(std::fs::read_to_string(&a).unwrap(), "two\n");
    assert_eq!(std::fs::read_to_string(&b).unwrap(), "bee\n");
    // Running again: the machine answers, and nothing is waiting for the agent.
    assert!(!f.fs.is_paused("m1"));
    assert_eq!(f.fs.read("m1", &a, 0).unwrap(), Routed::NotPaused);
    assert!(f.fs.take_notices("m1").is_empty());
    assert_eq!(f.fs.resumed("m1").unwrap(), None);
}

#[test]
fn a_conflict_on_resume_waits_for_the_next_file_call() {
    let f = fixture(&[("a.txt", "one\n")], SeedBounds::default());
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    let a = f.machine.join("a.txt");
    f.fs.write("m1", &a, "agent\n", 0, 1).unwrap();
    // Something on the machine saved the file before the journal reached it.
    std::fs::write(&a, "machine\n").unwrap();
    let report = f.fs.resumed("m1").unwrap().unwrap();
    assert_eq!(report.conflicts.len(), 1);
    assert_eq!(std::fs::read_to_string(&a).unwrap(), "machine\n");
    let notices = f.fs.take_notices("m1");
    assert_eq!(notices.len(), 1);
    assert!(notices[0].contains("changed on the machine") && notices[0].contains("machine\n"));
    assert!(f.fs.take_notices("m1").is_empty(), "told once");
}

#[test]
fn what_the_seed_left_out_needs_the_machine() {
    let big = "x".repeat(64);
    let bounds = SeedBounds { max_files: 10, max_total_bytes: 1 << 20, max_file_bytes: 32 };
    let f = fixture(&[("big.txt", big.as_str()), (".git/HEAD", "ref\n"), ("ok.txt", "ok")], bounds);
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    for path in ["big.txt", ".git/HEAD"] {
        assert_eq!(
            f.fs.read("m1", &f.machine.join(path), 0).unwrap(),
            Routed::NeedsMachine(NeedsMachine::MachineOnly),
            "{path}"
        );
    }
    // Outside the machine's folder: only the machine knows.
    assert_eq!(
        f.fs.read("m1", Path::new("/etc/hostname"), 0).unwrap(),
        Routed::NeedsMachine(NeedsMachine::MachineOnly)
    );
    // A copy that ran out of budget cannot say a file is absent.
    let tight = SeedBounds { max_files: 1, ..bounds };
    let g = fixture(&[("a.txt", "a"), ("b.txt", "b")], tight);
    let report = g.fs.pause("m1", &g.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    assert!(!report.complete);
    assert_eq!(text(g.fs.read("m1", &g.machine.join("a.txt"), 0).unwrap()), "a");
    assert_eq!(
        g.fs.read("m1", &g.machine.join("b.txt"), 0).unwrap(),
        Routed::NeedsMachine(NeedsMachine::MachineOnly)
    );
}

#[test]
fn a_resume_gap_since_the_seed_makes_the_replica_stale() {
    let f = fixture(&[("a.txt", "one\n")], SeedBounds::default());
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 3).unwrap();
    assert_eq!(
        f.fs.read("m1", &f.machine.join("a.txt"), 4).unwrap(),
        Routed::NeedsMachine(NeedsMachine::Stale)
    );
    // A new pause seeds a new generation that answers again.
    let report = f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 4).unwrap();
    assert_eq!(report.generation, 2);
    assert_eq!(text(f.fs.read("m1", &f.machine.join("a.txt"), 4).unwrap()), "one\n");
}

/// The M20 measurement: a read while paused, from the journal and replica, against the read a
/// daemon without them makes (resume the machine, then read its file), in one harness. The
/// machine is a fake whose resume takes `delay`; the file is a 4 KiB source file.
#[tokio::test]
async fn paused_read_latency_journal_vs_resume_then_read() {
    let body = "let x = 1;\n".repeat(372);
    for delay_ms in [0u64, 10, 100] {
        let f = fixture(&[("src/lib.rs", body.as_str())], SeedBounds::default());
        let resume = FakeResume::new(Duration::from_millis(delay_ms));
        let path = f.machine.join("src/lib.rs");
        f.fs.pause("m1", &f.machine, resume.clone(), 0).unwrap();
        let mut journal = Vec::new();
        for _ in 0..50 {
            let at = Instant::now();
            assert_eq!(text(f.fs.read("m1", &path, 0).unwrap()).len(), body.len());
            journal.push(at.elapsed());
        }
        assert_eq!(resume.calls.load(Ordering::SeqCst), 0);
        let mut woken = Vec::new();
        for _ in 0..5 {
            let at = Instant::now();
            resume.resume("m1").await.unwrap();
            f.fs.resumed("m1").unwrap();
            assert_eq!(std::fs::read_to_string(&path).unwrap().len(), body.len());
            woken.push(at.elapsed());
            f.fs.pause("m1", &f.machine, resume.clone(), 0).unwrap();
        }
        journal.sort();
        woken.sort();
        let (j, w) = (journal[journal.len() / 2], woken[woken.len() / 2]);
        eprintln!(
            "M20 paused read, resume delay {delay_ms} ms: journal p50 {} us, resume-then-read p50 {} us",
            j.as_micros(),
            w.as_micros()
        );
        if delay_ms > 0 {
            assert!(j < w, "journal {j:?} vs resume-then-read {w:?}");
        }
    }
}

fn names(r: Routed<ListOutcome>) -> Vec<(String, bool)> {
    match r {
        Routed::Answered(ListOutcome::Entries(e)) => {
            e.into_iter().map(|e| (e.name, e.is_dir)).collect()
        }
        other => panic!("expected entries, got {other:?}"),
    }
}

#[test]
fn a_paused_machine_lists_and_searches_with_no_resume_and_the_journal_on_top() {
    let f = fixture(
        &[("src/a.rs", "fn a() {}\nlet needle = 1;\n"), ("b.txt", "hello\n"), ("c.txt", "x\n")],
        SeedBounds::default(),
    );
    let resume = FakeResume::new(Duration::ZERO);
    f.fs.pause("m1", &f.machine, resume.clone(), 0).unwrap();
    assert_eq!(
        names(f.fs.list_dir("m1", &f.machine, 0).unwrap()),
        [("b.txt".into(), false), ("c.txt".into(), false), ("src".into(), true)]
    );
    // The journal is laid over the copy: a new file under a new folder, and a delete.
    f.fs.write("m1", &f.machine.join("new/d.txt"), "needle too\n", 0, 1).unwrap();
    f.fs.write("m1", &f.machine.join("b.txt"), "changed\n", 0, 2).unwrap();
    let deleted = f.fs.write("m1", &f.machine.join("c.txt"), "", 0, 3).unwrap();
    assert!(matches!(deleted, Routed::Answered(_)));
    assert_eq!(
        names(f.fs.list_dir("m1", &f.machine, 0).unwrap()),
        [
            ("b.txt".into(), false),
            ("c.txt".into(), false),
            ("new".into(), true),
            ("src".into(), true)
        ]
    );
    assert_eq!(
        f.fs.list_dir("m1", &f.machine.join("nope"), 0).unwrap(),
        Routed::Answered(ListOutcome::NotFound)
    );
    let Routed::Answered(SearchOutcome::Hits { hits, truncated }) =
        f.fs.search("m1", &f.machine, "needle", 10, 0).unwrap()
    else {
        panic!("search was not answered");
    };
    assert!(!truncated);
    let at: Vec<_> = hits.iter().map(|h| (h.path.as_str(), h.line)).collect();
    assert_eq!(at, [("new/d.txt", 1), ("src/a.rs", 2)]);
    assert_eq!(resume.calls.load(Ordering::SeqCst), 0, "a read never wakes the machine");
}

#[test]
fn listings_and_searches_stop_answering_once_the_machine_ran() {
    let f = fixture(&[("a.txt", "needle\n")], SeedBounds::default());
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    // The daemon saw a resume since the seed: anything may have run.
    assert!(matches!(
        f.fs.list_dir("m1", &f.machine, 1).unwrap(),
        Routed::Answered(ListOutcome::NeedsMachine(NeedsMachine::Stale))
    ));
    assert!(matches!(
        f.fs.search("m1", &f.machine, "needle", 5, 1).unwrap(),
        Routed::Answered(SearchOutcome::NeedsMachine(NeedsMachine::Stale))
    ));
}

#[test]
fn listings_and_searches_are_off_unless_the_setting_is_on() {
    let mut f = fixture(&[("a.txt", "x\n")], SeedBounds::default());
    f.fs = f.fs.with_serve_reads(false);
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    assert_eq!(f.fs.list_dir("m1", &f.machine, 0).unwrap(), Routed::NotPaused);
    assert_eq!(f.fs.search("m1", &f.machine, "x", 5, 0).unwrap(), Routed::NotPaused);
}

#[test]
fn a_file_the_seed_left_out_is_still_in_the_tree() {
    let bounds = SeedBounds { max_file_bytes: 4, ..SeedBounds::default() };
    let f = fixture(&[("big.txt", "much too large\n"), ("s.txt", "ok\n")], bounds);
    f.fs.pause("m1", &f.machine, FakeResume::new(Duration::ZERO), 0).unwrap();
    assert_eq!(
        names(f.fs.list_dir("m1", &f.machine, 0).unwrap()),
        [("big.txt".into(), false), ("s.txt".into(), false)]
    );
}

/// Duress (RFD 0144's 200 ms file-open bound): a 5,000-file tree of 4 KiB sources in 50 folders,
/// 200 journal writes on top, then folder listings, file opens and whole-tree searches while
/// paused. Prints p50 and p95 with n; fails past the bound for a listing or an open.
#[test]
fn paused_reads_duress_large_tree_with_a_busy_journal() {
    let body = "let value = compute(1, 2);\n".repeat(150);
    let paths: Vec<String> = (0..5000).map(|i| format!("d{:02}/f{i:04}.rs", i % 50)).collect();
    let files: Vec<(&str, &str)> = paths.iter().map(|p| (p.as_str(), body.as_str())).collect();
    let f = fixture(&files, SeedBounds::default());
    let resume = FakeResume::new(Duration::ZERO);
    let report = f.fs.pause("m1", &f.machine, resume.clone(), 0).unwrap();
    assert!(report.complete);
    for i in 0..200u64 {
        let p = f.machine.join(format!("d{:02}/new{i}.rs", i % 50));
        f.fs.write("m1", &p, "let needle = 1;\n", 0, i + 1).unwrap();
    }
    let pct = |mut v: Vec<Duration>, q: f64| {
        v.sort();
        v[((v.len() as f64 * q).ceil() as usize).saturating_sub(1)]
    };
    let report_line = |what: &str, v: Vec<Duration>| {
        let n = v.len();
        let (p50, p95) = (pct(v.clone(), 0.5), pct(v, 0.95));
        eprintln!(
            "RFD 0144 paused {what}: n={n} p50 {:.2} ms p95 {:.2} ms",
            p50.as_secs_f64() * 1e3,
            p95.as_secs_f64() * 1e3
        );
        p95
    };
    let mut lists = Vec::new();
    for i in 0..200 {
        let dir = f.machine.join(format!("d{:02}", i % 50));
        let at = Instant::now();
        let n = names(f.fs.list_dir("m1", &dir, 0).unwrap()).len();
        lists.push(at.elapsed());
        assert_eq!(n, 104);
    }
    let mut opens = Vec::new();
    for i in 0..200 {
        let at = Instant::now();
        let t = text(f.fs.read("m1", &f.machine.join(&paths[i * 25]), 0).unwrap());
        opens.push(at.elapsed());
        assert_eq!(t.len(), body.len());
    }
    let mut searches = Vec::new();
    for _ in 0..10 {
        let at = Instant::now();
        let r = f.fs.search("m1", &f.machine, "needle", 1000, 0).unwrap();
        searches.push(at.elapsed());
        match r {
            Routed::Answered(SearchOutcome::Hits { hits, .. }) => assert_eq!(hits.len(), 200),
            other => panic!("expected hits, got {other:?}"),
        }
    }
    assert_eq!(resume.calls.load(Ordering::SeqCst), 0, "no read woke the machine");
    let bound = Duration::from_millis(200);
    assert!(report_line("folder listing", lists) < bound);
    assert!(report_line("file open", opens) < bound);
    report_line("whole-tree search (5,200 files)", searches);
}
