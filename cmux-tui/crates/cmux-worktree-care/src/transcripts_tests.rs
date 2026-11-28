use super::*;
use crate::caches::{Options, run};
use crate::never_delete::NeverDelete;
use crate::policy::Pressure;
use crate::procs::parse_lsof;
use crate::procs::{Open, Process, Uses};
use crate::store::care_tests::scratch;
use std::io::Write;

/// Writes `bytes` to `file`.
fn write(file: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::File::create(file).unwrap().write_all(bytes).unwrap();
}

const DAY: Duration = Duration::from_secs(86_400);

static OPEN: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

fn fake_open(root: &Path) -> Result<HashSet<PathBuf>, String> {
    Ok(OPEN.lock().unwrap().iter().filter(|p| p.starts_with(root)).cloned().collect())
}

fn failing_open(_: &Path) -> Result<HashSet<PathBuf>, String> {
    Err("lsof: timed out".into())
}

fn not_open(_: &Path) -> Result<Option<u32>, String> {
    Ok(None)
}

fn no_uses() -> Result<Vec<Process>, String> {
    Ok(Vec::new())
}

fn claude(home: &Path, check: OpenIn) -> Family {
    let mut f = family("claude-transcripts", home.join(".claude/projects"), 30);
    f.source = Source::Transcripts { open: OpenCheck(check) };
    f
}

/// A transcript last changed `days` ago.
fn transcript(home: &Path, rel: &str, days: u64) -> PathBuf {
    let path = home.join(".claude/projects").join(rel);
    write(&path, format!("{{\"session\":\"{rel}\"}}\n").repeat(200).as_bytes());
    let when = std::time::SystemTime::now() - DAY * days as u32;
    std::fs::File::options().write(true).open(&path).unwrap().set_modified(when).unwrap();
    path
}

fn options<'a>(
    home: &'a Path,
    family: Family,
    uses: &'a Uses,
    open: &'a Open,
    never: &'a NeverDelete,
    store: Option<&'a Store>,
) -> Options<'a> {
    Options {
        families: vec![family],
        pressure: Pressure::Normal,
        now_ms: crate::inventory::now_ms(),
        apply: true,
        uses,
        open,
        measure: true,
        home,
        never,
        store,
        off: &[],
    }
}

fn item<'a>(report: &'a crate::caches::Report, path: &Path) -> &'a crate::caches::Item {
    report.items.iter().find(|i| i.path == path).unwrap_or_else(|| panic!("{report:?}"))
}

#[test]
fn an_old_transcript_is_archived_compressed_then_removed() {
    let home = scratch("tx-old");
    let store = Store::open(home.join("store")).unwrap();
    let old = transcript(&home, "-w-app/aaaa.jsonl", 40);
    let original = std::fs::read(&old).unwrap();
    let recent = transcript(&home, "-w-app/bbbb.jsonl", 3);
    let memory = transcript(&home, "-w-app/memory/notes.jsonl", 400);
    let report = run(&options(
        &home,
        claude(&home, fake_open),
        &no_uses,
        &not_open,
        &crate::never_delete::NONE,
        Some(&store),
    ));
    assert!(!old.exists(), "{report:?}");
    assert!(recent.exists() && memory.exists());
    // Recent and memory files are not entries; the root is one kept report.
    assert!(report.items.iter().all(|i| i.path != recent && i.path != memory));
    assert_eq!(item(&report, &home.join(".claude/projects")).verdict.action, Action::Keep);
    let outcome = item(&report, &old).outcome.clone().unwrap();
    assert!(outcome.ok);
    assert_eq!(outcome.freed, original.len() as u64);
    let id = outcome.archive.unwrap();
    assert_eq!(id, "transcripts/claude-transcripts/-w-app/aaaa.jsonl.gz");
    let gz = std::fs::read(store.dir.join(&id)).unwrap();
    assert!(gz.len() < original.len());
    let mut back = Vec::new();
    flate2::read::GzDecoder::new(&gz[..]).read_to_end(&mut back).unwrap();
    assert_eq!(back, original);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_live_sessions_transcript_is_kept() {
    let home = scratch("tx-live");
    let store = Store::open(home.join("store")).unwrap();
    // Old by its clock, but its session is registered as running: the
    // session's own file and its subagents' files stay.
    let own = transcript(&home, "-w-app/live-1.jsonl", 40);
    let sub = transcript(&home, "-w-app/live-1/subagents/agent-a.jsonl", 40);
    // Old, no session, but a program has it open.
    let open = transcript(&home, "-w-app/held.jsonl", 40);
    OPEN.lock().unwrap().push(open.clone());
    let live = || -> Result<Vec<Process>, String> {
        Ok(vec![Process { pid: 4242, cwd: "/w/app".into(), session_id: Some("live-1".into()) }])
    };
    let report = run(&options(
        &home,
        claude(&home, fake_open),
        &live,
        &not_open,
        &crate::never_delete::NONE,
        Some(&store),
    ));
    assert!(own.exists() && sub.exists() && open.exists(), "{report:?}");
    assert!(item(&report, &own).verdict.reason.contains("pid 4242"));
    assert!(item(&report, &open).verdict.reason.contains("open"));
    assert!(!store.dir.join("transcripts").exists());
    // An open-file check that fails keeps it too.
    forget_open();
    let report = run(&options(
        &home,
        claude(&home, failing_open),
        &no_uses,
        &not_open,
        &crate::never_delete::NONE,
        Some(&store),
    ));
    assert!(own.exists());
    assert!(item(&report, &own).verdict.reason.contains("could not check open files"));
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn never_delete_keeps_a_transcript() {
    let home = scratch("tx-never");
    let store = Store::open(home.join("store")).unwrap();
    let held = transcript(&home, "-w-keep/cccc.jsonl", 400);
    let never = NeverDelete::from_globs(["~/.claude/projects/-w-keep".to_string()]);
    let report =
        run(&options(&home, claude(&home, fake_open), &no_uses, &not_open, &never, Some(&store)));
    assert!(held.exists());
    assert!(item(&report, &held).verdict.reason.starts_with("never-delete"));
    assert!(!store.dir.join("transcripts").exists());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_failed_archive_keeps_the_transcript() {
    let home = scratch("tx-archive-fails");
    let store = Store::open(home.join("store")).unwrap();
    let old = transcript(&home, "-w-app/dddd.jsonl", 400);
    // The archive folder cannot be made: a file stands where it would go.
    std::fs::write(store.dir.join("transcripts"), b"not a folder").unwrap();
    let report = run(&options(
        &home,
        claude(&home, fake_open),
        &no_uses,
        &not_open,
        &crate::never_delete::NONE,
        Some(&store),
    ));
    assert!(old.exists());
    assert!(item(&report, &old).verdict.reason.starts_with("not archived"), "{report:?}");
    assert_eq!(report.freed, 0);
    // No store at all keeps it as well.
    let report = run(&options(
        &home,
        claude(&home, fake_open),
        &no_uses,
        &not_open,
        &crate::never_delete::NONE,
        None,
    ));
    assert!(old.exists());
    assert!(item(&report, &old).verdict.reason.contains("no archive store"));
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn lsof_output_names_other_programs_files() {
    let text = "p10\nn/h/a.jsonl\np20\nn/h/b.jsonl\nn/h/c.jsonl\n";
    let set = parse_lsof(text, 20);
    assert_eq!(set, HashSet::from([PathBuf::from("/h/a.jsonl")]));
}

/// Duress: 10k old transcripts while a live session appends to its own;
/// prints the pass time (`cargo test -- --ignored --nocapture duress`).
#[test]
#[ignore = "duress measurement"]
fn duress_ten_thousand_transcripts_while_a_session_writes() {
    let home = scratch("tx-duress");
    let store = Store::open(home.join("store")).unwrap();
    let root = home.join(".claude/projects");
    let line = "{\"type\":\"assistant\",\"text\":\"hello world\"}\n".repeat(40);
    let when = std::time::SystemTime::now() - DAY * 120;
    for i in 0..10_000 {
        let path = root.join(format!("-w-p{}/s-{i}.jsonl", i % 100));
        write(&path, line.as_bytes());
        std::fs::File::options().write(true).open(&path).unwrap().set_modified(when).unwrap();
    }
    let live = root.join("-w-p0/live-session.jsonl");
    write(&live, b"");
    std::fs::File::options().write(true).open(&live).unwrap().set_modified(when).unwrap();
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writer = {
        let (stop, live) = (stop.clone(), live.clone());
        std::thread::spawn(move || {
            let mut file = std::fs::OpenOptions::new().append(true).open(&live).unwrap();
            let mut n = 0u64;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                writeln!(file, "{{\"n\":{n}}}").unwrap();
                n += 1;
                std::thread::sleep(Duration::from_millis(2));
            }
            n
        })
    };
    let session = || -> Result<Vec<Process>, String> {
        Ok(vec![Process { pid: 1, cwd: "/w".into(), session_id: Some("live-session".into()) }])
    };
    let mut family = family("claude-transcripts", root, 90);
    if std::env::var_os("DURESS_FAKE_LSOF").is_some() {
        family.source = Source::Transcripts { open: OpenCheck(fake_open) };
    }
    let started = Instant::now();
    let report =
        run(&options(&home, family, &session, &not_open, &crate::never_delete::NONE, Some(&store)));
    let took = started.elapsed();
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let lines = writer.join().unwrap();
    let removed = report.items.iter().filter(|i| i.outcome.as_ref().is_some_and(|o| o.ok)).count();
    println!(
        "DURESS: 10000 old transcripts, live writer {lines} appends: pass {:.2}s, removed {removed}, freed {} bytes, errors {:?}",
        took.as_secs_f64(),
        report.freed,
        report.errors.first()
    );
    assert!(live.exists());
    assert_eq!(removed, 10_000);
    let _ = std::fs::remove_dir_all(&home);
}
