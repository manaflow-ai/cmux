use super::*;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("log-keep-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The kept log moves aside at its cap and the home holds at most two files of it, whatever
/// is written: a daemon that logs for days keeps a bounded log.
#[test]
fn the_kept_log_is_bounded_at_twice_its_cap() {
    let dir = scratch("cap");
    let log = dir.join("daemon.log");
    let mut kept = Kept::open(log.clone(), 4096);
    let line = [b'x'; 99].iter().copied().chain([b'\n']).collect::<Vec<u8>>();
    for _ in 0..1000 {
        kept.write_all(&line).unwrap();
    }
    let now = std::fs::metadata(&log).unwrap().len();
    let before = std::fs::metadata(log.with_extension("log.1")).unwrap().len();
    assert!(now <= 4096 && before <= 4096, "{now} {before}");
    assert!(now > 0 && before > 0);
    let files: Vec<_> = std::fs::read_dir(&dir).unwrap().collect();
    assert_eq!(files.len(), 2, "{files:?}");
    std::fs::remove_dir_all(&dir).unwrap();
}

/// Each line reaches stdout and the kept log, whole and in order; a kept log that fails never
/// costs the stdout copy.
#[test]
fn a_line_goes_to_stdout_and_the_kept_log() {
    let dir = scratch("tee");
    let log = dir.join("daemon.log");
    let mut tee = Tee { out: Vec::new(), kept: Some(Kept::open(log.clone(), CAP)) };
    tee.write_all(b"one\n").unwrap();
    tee.write_all(b"two\n").unwrap();
    assert_eq!(tee.out, b"one\ntwo\n");
    assert_eq!(std::fs::read(&log).unwrap(), b"one\ntwo\n");
    // The kept log's folder gone: stdout still takes every line.
    std::fs::remove_dir_all(&dir).unwrap();
    tee.write_all(b"three\n").unwrap();
    assert_eq!(tee.out, b"one\ntwo\nthree\n");
}

/// Outside systemd (no `INVOCATION_ID`), the daemon keeps no second log: its stdout is the
/// log already (the CLI's start) or a test's pipe.
#[test]
fn no_kept_log_outside_a_service_manager() {
    if std::env::var_os("INVOCATION_ID").is_some() {
        return;
    }
    assert!(Kept::for_service(&scratch("none")).is_none());
}
