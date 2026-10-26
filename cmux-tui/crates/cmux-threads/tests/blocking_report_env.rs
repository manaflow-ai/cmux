//! `CMUX_DAEMON_BLOCKING_REPORT` alone opens the report at the first
//! violation. The report is chosen once per process, so the test runs itself
//! again as a child process with the variable set.

use std::path::PathBuf;
use std::process::{Command, Stdio};

use cmux_threads::blocking::{
    BlockingKind, BlockingMode, MODE_ENV, REPORT_ENV, assert_blocking_allowed, report_path,
    set_mode,
};
use cmux_threads::disallow_blocking;

/// Set in the child: it makes the violation instead of spawning a child.
const CHILD_ENV: &str = "CMUX_THREADS_REPORT_ENV_CHILD";
const TEST_NAME: &str = "the_report_env_opens_blocking_pid_jsonl_at_the_first_violation";

#[test]
fn the_report_env_opens_blocking_pid_jsonl_at_the_first_violation() {
    if std::env::var_os(CHILD_ENV).is_some() {
        child();
        return;
    }
    let dir = std::env::temp_dir().join(format!("cmux-threads-report-env-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let child = Command::new(std::env::current_exe().expect("this test binary"))
        .args([TEST_NAME, "--exact", "--nocapture", "--test-threads=1"])
        .env(CHILD_ENV, "1")
        .env(REPORT_ENV, &dir)
        .env(MODE_ENV, "record")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("run the child");
    let pid = child.id();
    let output = child.wait_with_output().expect("wait for the child");
    let log = String::from_utf8_lossy(&output.stdout).into_owned()
        + &String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{log}");
    assert!(log.contains("1 passed"), "the child ran the test: {log}");

    let file = dir.join(format!("blocking-{pid}.jsonl"));
    let text = std::fs::read_to_string(&file).unwrap_or_else(|error| {
        panic!("{}: {error}\n{log}", file.display());
    });
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert!(lines[0].starts_with(&format!("{{\"pid\":{pid},\"thread\":\"mux-conn-report-env\",")));
    assert!(
        lines[0].ends_with("\"kind\":\"fs\",\"mode\":\"record\",\"overflow\":false}"),
        "{text}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The child: no report until the first violation, then the one the
/// environment names.
fn child() {
    set_mode(BlockingMode::Record);
    assert_eq!(report_path(), None);
    std::thread::Builder::new()
        .name("mux-conn-report-env".into())
        .spawn(|| {
            disallow_blocking();
            assert_blocking_allowed(BlockingKind::Fs);
        })
        .expect("spawn")
        .join()
        .expect("record mode does not panic");
    let dir = PathBuf::from(std::env::var_os(REPORT_ENV).expect("the report env"));
    let expected = dir.join(format!("blocking-{}.jsonl", std::process::id()));
    assert_eq!(report_path(), Some(expected.as_path()));
}
