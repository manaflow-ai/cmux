//! The site report is chosen once per process, so it gets its own test binary.

use std::path::PathBuf;

use cmux_threads::blocking::{
    BlockingKind, BlockingMode, REPORT_ENV, ReportError, assert_blocking_allowed, report_path,
    set_mode, set_report_dir,
};
use cmux_threads::disallow_blocking;

/// This binary's report file, in the directory the sweep script set in
/// [`REPORT_ENV`] (so its run keeps the lines) or in a fresh one.
fn report_file() -> PathBuf {
    assert_eq!(report_path(), None, "no report before the first violation");
    let dir = std::env::var_os(REPORT_ENV)
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::temp_dir().join(format!("cmux-threads-report-{}", std::process::id()))
        });
    let path = set_report_dir(&dir).expect("open the report");
    assert_eq!(report_path(), Some(path.as_path()));
    path
}

#[test]
fn report_has_one_line_per_new_site_and_kind_with_the_thread() {
    set_mode(BlockingMode::Record);
    let file = report_file();
    let (fs_line, other_line) = std::thread::Builder::new()
        .name("mux-conn-report".into())
        .spawn(|| {
            disallow_blocking();
            let mut fs_line = 0;
            for _ in 0..3 {
                fs_line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Fs);
            }
            let other_line = line!() + 1;
            assert_blocking_allowed(BlockingKind::IpcReply);
            (fs_line, other_line)
        })
        .expect("spawn")
        .join()
        .expect("record mode does not panic");
    // An ordinary thread never reports.
    let ordinary_line = line!() + 1;
    assert_blocking_allowed(BlockingKind::Fs);

    let text = std::fs::read_to_string(&file).expect("read the report");
    let mine: Vec<&str> =
        text.lines().filter(|line| line.contains("\"thread\":\"mux-conn-report\"")).collect();
    let at = |line: u32, kind: &str| {
        let key = format!("\"file\":\"{}\",\"line\":{line},", file!().replace('\\', "\\\\"));
        let kind = format!("\"kind\":\"{kind}\"");
        mine.iter().filter(|text| text.contains(&key) && text.contains(&kind)).count()
    };
    assert_eq!(at(fs_line, "fs"), 1, "three hits, one line: {text}");
    assert_eq!(at(other_line, "ipc-reply"), 1, "{text}");
    assert_eq!(mine.len(), 2, "{text}");
    assert!(mine.iter().all(|line| line.contains("\"mode\":\"record\",\"overflow\":false}")));
    assert!(mine.iter().all(|line| line.contains(&format!("\"pid\":{},", std::process::id()))));
    assert!(!text.contains(&format!("\"line\":{ordinary_line},")), "{text}");

    assert!(matches!(set_report_dir(&std::env::temp_dir()), Err(ReportError::AlreadyConfigured)));
    if std::env::var_os(REPORT_ENV).is_none_or(|dir| dir.is_empty()) {
        let _ = std::fs::remove_file(&file);
        let _ = file.parent().map(std::fs::remove_dir);
    }
}
