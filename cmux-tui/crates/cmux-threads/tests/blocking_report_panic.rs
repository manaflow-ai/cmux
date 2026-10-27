//! A panic-mode violation still leaves its report line: the line is written
//! before the panic. Panic mode and the report are process-wide, so this gets
//! its own test binary.
#![cfg(debug_assertions)]

use cmux_threads::blocking::{
    BlockingKind, BlockingMode, REPORT_ENV, assert_blocking_allowed, set_mode, set_report_dir,
};
use cmux_threads::disallow_blocking;

#[test]
fn a_panic_mode_violation_is_reported_before_it_panics() {
    set_mode(BlockingMode::Panic);
    let fresh =
        std::env::temp_dir().join(format!("cmux-threads-report-panic-{}", std::process::id()));
    let dir = std::env::var_os(REPORT_ENV)
        .filter(|dir| !dir.is_empty())
        .map_or_else(|| fresh.clone(), std::path::PathBuf::from);
    let file = set_report_dir(&dir).expect("open the report");
    let (line_tx, line_rx) = std::sync::mpsc::channel();
    let joined = std::thread::Builder::new()
        .name("mux-conn-report-panic".into())
        .spawn(move || {
            disallow_blocking();
            line_tx.send(line!() + 1).expect("send line");
            assert_blocking_allowed(BlockingKind::Sleep);
        })
        .expect("spawn")
        .join();
    let line = line_rx.recv().expect("line");
    assert!(joined.is_err(), "panic mode panics at the violation");

    let text = std::fs::read_to_string(&file).expect("read the report");
    let key = format!(
        "\"thread\":\"mux-conn-report-panic\",\"file\":\"{}\",\"line\":{line},",
        file!().replace('\\', "\\\\")
    );
    let mine: Vec<&str> = text.lines().filter(|text| text.contains(&key)).collect();
    assert_eq!(mine.len(), 1, "{text}");
    assert!(
        mine[0].ends_with("\"kind\":\"sleep\",\"mode\":\"panic\",\"overflow\":false}"),
        "{text}"
    );
    if dir == fresh {
        let _ = std::fs::remove_dir_all(&dir);
    }
}
