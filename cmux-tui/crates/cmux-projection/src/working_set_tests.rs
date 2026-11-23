use super::*;
use crate::manifest::Item;

fn file(path: &str, size: u64) -> Item {
    Item { path: path.into(), kind: Kind::File, mode: 0o644, size, mtime_ns: 1, link: None }
}

/// `top.txt` (10), `src/a.rs` (20), `src/b.rs` (30), `src/deep/c.rs` (40), `huge.bin` (1000),
/// `empty` (0).
fn manifest() -> Manifest {
    Manifest::build(
        1,
        vec![
            file("top.txt", 10),
            file("src/a.rs", 20),
            file("src/b.rs", 30),
            file("src/deep/c.rs", 40),
            file("huge.bin", 1000),
            file("empty", 0),
        ],
    )
    .unwrap()
}

fn paths(manifest: &Manifest, planned: &[(u32, u64)]) -> Vec<String> {
    planned.iter().map(|(index, _)| manifest.path_of(*index)).collect()
}

fn strings(paths: &[&str]) -> Vec<String> {
    paths.iter().map(|path| (*path).to_owned()).collect()
}

#[test]
fn a_trace_round_trips_and_a_bad_file_is_no_trace() {
    let trace =
        Trace { paths: strings(&["a b", "line\nbreak", "src/x.rs"]), bytes: 77, crawled: true };
    assert_eq!(Trace::decode(&trace.encode()), Some(trace.clone()));
    let empty = Trace::default();
    assert_eq!(Trace::decode(&empty.encode()), Some(empty));
    for bad in [&b""[..], b"nope\0", b"cmux-projection working set v1\0bytes=x\0", b"\xff\0"] {
        assert_eq!(Trace::decode(bad), None, "{bad:?} decoded");
    }
    let dir = tempfile::tempdir().unwrap();
    let at = dir.path().join(FILE);
    assert_eq!(Trace::load(&at), None);
    trace.save(&at).unwrap();
    assert_eq!(Trace::load(&at), Some(trace));
}

#[test]
fn the_plan_takes_declared_paths_then_the_trace_each_file_once() {
    let manifest = manifest();
    let declared = strings(&["src/"]);
    let trace = strings(&["top.txt", "src/a.rs", "gone.rs", "empty", "huge.bin"]);
    let (planned, over) = plan(&manifest, &declared, &trace, 1 << 20, 100, |_, _| false);
    // The folder breadth first, then the trace's new file; the empty, the too-big for one ask,
    // and the missing are passed over.
    assert_eq!(paths(&manifest, &planned), ["src/a.rs", "src/b.rs", "src/deep/c.rs", "top.txt"]);
    assert!(!over);
    let (planned, _) = plan(&manifest, &[], &strings(&[""]), 1 << 20, 100, |_, _| false);
    assert_eq!(paths(&manifest, &planned), ["top.txt", "src/a.rs", "src/b.rs", "src/deep/c.rs"]);
}

#[test]
fn the_plan_stays_within_its_byte_budget_and_says_so() {
    let manifest = manifest();
    let trace = strings(&["src/b.rs", "src/deep/c.rs", "src/a.rs", "top.txt"]);
    // 30 + 40 > 60: c.rs does not fit, the smaller ones after it still do.
    let (planned, over) = plan(&manifest, &[], &trace, 60, 100, |_, _| false);
    assert_eq!(paths(&manifest, &planned), ["src/b.rs", "src/a.rs", "top.txt"]);
    assert!(planned.iter().map(|(_, size)| size).sum::<u64>() <= 60);
    assert!(over);
    // A skipped file (cached already) costs nothing.
    let a = manifest.resolve("src/a.rs").unwrap();
    let (planned, _) = plan(&manifest, &[], &trace, 1 << 20, 100, |index, _| index == a);
    assert!(!paths(&manifest, &planned).contains(&"src/a.rs".to_owned()));
}

#[test]
fn a_recorder_keeps_first_reads_once_and_marks_a_crawl() {
    let manifest = manifest();
    let id = |path| manifest.resolve(path).unwrap();
    let mut recorder = Recorder::new(60);
    assert!(recorder.is_empty());
    recorder.touch(id("src/b.rs"), 30);
    recorder.touch(id("src/b.rs"), 30);
    recorder.touch(id("top.txt"), 10);
    let trace = recorder.trace(&manifest);
    assert_eq!(
        trace,
        Trace { paths: strings(&["src/b.rs", "top.txt"]), bytes: 40, crawled: false }
    );
    // Past the cap the session is a crawl: what it read first stays, nothing after it.
    recorder.touch(id("src/deep/c.rs"), 40);
    recorder.touch(id("src/a.rs"), 20);
    let trace = recorder.trace(&manifest);
    assert_eq!(trace, Trace { paths: strings(&["src/b.rs", "top.txt"]), bytes: 40, crawled: true });
}
