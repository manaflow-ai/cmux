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

/// One call site that more than one thread reaches; returns its line.
fn shared_fs_site() -> u32 {
    let line = line!() + 1;
    assert_blocking_allowed(BlockingKind::Fs);
    line
}

fn on_disallowed_thread<R: Send + 'static>(
    name: &str,
    f: impl FnOnce() -> R + Send + 'static,
) -> R {
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            disallow_blocking();
            f()
        })
        .expect("spawn")
        .join()
        .expect("record mode does not panic")
}

#[test]
fn report_has_one_line_per_site_kind_and_thread() {
    set_mode(BlockingMode::Record);
    let file = report_file();
    let (fs_line, other_line) = on_disallowed_thread("mux-conn-report", || {
        shared_fs_site();
        shared_fs_site();
        let fs_line = shared_fs_site();
        let other_line = line!() + 1;
        assert_blocking_allowed(BlockingKind::IpcReply);
        (fs_line, other_line)
    });
    // The same site on a second thread is its own MQ-13 row.
    let echo_line = on_disallowed_thread("mux-echo-report", || {
        shared_fs_site();
        shared_fs_site()
    });
    assert_eq!(echo_line, fs_line);
    // An ordinary thread never reports.
    let ordinary_line = line!() + 1;
    assert_blocking_allowed(BlockingKind::Fs);

    let text = std::fs::read_to_string(&file).expect("read the report");
    let on = |thread: &str| -> Vec<&str> {
        let thread = format!("\"thread\":\"{thread}\"");
        text.lines().filter(|line| line.contains(&thread)).collect()
    };
    let at = |lines: &[&str], line: u32, kind: &str| {
        let key = format!("\"file\":\"{}\",\"line\":{line},", file!().replace('\\', "\\\\"));
        let kind = format!("\"kind\":\"{kind}\"");
        lines.iter().filter(|text| text.contains(&key) && text.contains(&kind)).count()
    };
    let conn = on("mux-conn-report");
    let echo = on("mux-echo-report");
    assert_eq!(at(&conn, fs_line, "fs"), 1, "three hits, one line: {text}");
    assert_eq!(at(&conn, other_line, "ipc-reply"), 1, "{text}");
    assert_eq!(conn.len(), 2, "{text}");
    assert_eq!(at(&echo, fs_line, "fs"), 1, "a second thread, its own line: {text}");
    assert_eq!(echo.len(), 1, "{text}");
    let mine = conn.iter().chain(&echo);
    assert!(mine.clone().all(|line| line.contains("\"mode\":\"record\",\"overflow\":false}")));
    assert!(mine.clone().all(|line| line.contains(&format!("\"pid\":{},", std::process::id()))));
    assert!(!text.contains(&format!("\"line\":{ordinary_line},")), "{text}");

    assert!(matches!(set_report_dir(&std::env::temp_dir()), Err(ReportError::AlreadyConfigured)));
    if std::env::var_os(REPORT_ENV).is_none_or(|dir| dir.is_empty()) {
        let _ = std::fs::remove_file(&file);
        let _ = file.parent().map(std::fs::remove_dir);
    }
}
