use super::*;

/// A stdin that never ends (a pipe nobody closes) stops the prompt's read at the deadline; one that ends is read
/// whole. Without the bound the drill waited on such a stdin past any `--timeout`.
#[test]
fn a_stdin_read_stops_at_the_deadline() {
    use std::io::Write as _;
    // A pipe nobody closes: its reader never sees an end.
    let (reader, writer) = std::io::pipe().unwrap();
    let began = Instant::now();
    assert!(read_by(&reader, began + Duration::from_millis(200)).is_err());
    assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
    // One that ends is read whole.
    let (reader, mut writer_two) = std::io::pipe().unwrap();
    writer_two.write_all(b"count").unwrap();
    drop(writer_two);
    let read = read_by(&reader, began + Duration::from_secs(5));
    assert_eq!(read, Ok("count".to_owned()));
    drop(writer);
}

/// A bounded step that answers at once answers its own output and exit, on every Unix the drill runs on (the
/// production drill runs on macOS): never `--timeout ran out` with the deadline far off.
#[cfg(unix)]
#[test]
fn a_bounded_step_that_answers_at_once_answers_its_output() {
    // Many short steps in a row: the window between a step's pipes ending (its exit event) and its zombie
    // (macOS posts `NOTE_EXIT` first) is short, so one step alone may miss it.
    let began = Instant::now();
    for round in 0..100 {
        let mut command = cmux_process::Command::new("sh");
        command.arg("-c").arg("echo hi; echo there >&2; exit 3");
        let ran = output_by(command, began + Duration::from_secs(60));
        assert_eq!(
            (ran.code, ran.stdout.as_str(), ran.stderr.as_str()),
            (3, "hi\n", "there\n"),
            "step {round}, after {:?}",
            began.elapsed()
        );
    }
    assert!(began.elapsed() < Duration::from_secs(30), "{:?}", began.elapsed());
}

/// The marker a re-run of this test binary reads to be the child that ignores `SIGCHLD`.
#[cfg(unix)]
const IGNORED_SIGCHLD_CHILD: &str = "CMUX_TEST_BOUNDED_IGNORED_SIGCHLD_CHILD";

/// A drill started with `SIGCHLD` ignored (inherited across exec from whatever ran it) still answers a bounded
/// step's own output: the system then reaps the step behind the runner's back, and a wait that cannot see its
/// exit is not a deadline. Run in a child process of its own (this test binary again), so the ignored `SIGCHLD`
/// touches no other test.
#[cfg(unix)]
#[test]
fn a_bounded_step_under_an_ignored_sigchld_answers_its_output() {
    if std::env::var_os(IGNORED_SIGCHLD_CHILD).is_some() {
        // SAFETY: `signal` with SIG_IGN installs no handler code; this process is this one test.
        unsafe {
            libc::signal(libc::SIGCHLD, libc::SIG_IGN);
        }
        let mut command = cmux_process::Command::new("sh");
        command.arg("-c").arg("echo hi; exit 3");
        let began = Instant::now();
        let ran = output_by(command, began + Duration::from_secs(30));
        assert_eq!((ran.code, ran.stdout.as_str()), (3, "hi\n"), "{}", ran.stderr);
        assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
        return;
    }
    let output = cmux_process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "cli::cloud_start_chat::internal::bounded::tests::a_bounded_step_under_an_ignored_sigchld_answers_its_output",
            "--nocapture",
        ])
        .env(IGNORED_SIGCHLD_CHILD, "1")
        .output()
        .unwrap();
    let said = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "the child with SIGCHLD ignored failed: {}: {said}",
        output.status
    );
    // A name that matched no test would pass with 0 run.
    assert!(said.contains("1 passed"), "the child ran no test: {said}");
}

/// Under a second left after the kill grace and the dispatch margin, no remote script is sent; otherwise the
/// machine's `timeout` holds those whole seconds, the script quoted whole.
#[test]
fn a_remote_script_holds_the_seconds_left() {
    assert_eq!(remote_script("true", Duration::from_millis(3_999)), None);
    assert_eq!(
        remote_script("echo a b", Duration::from_millis(5_900)).as_deref(),
        Some("timeout -k 1 2 sh -c 'echo a b'")
    );
}

/// A step still running when its `until` comes runs on to the later instant `later` names (a new machine still
/// booting, fresh.rs `Boot`), and is killed at the first `until` for which `later` names none.
#[cfg(unix)]
#[test]
fn a_bounded_step_runs_on_while_later_moves_its_end() {
    let began = Instant::now();
    let mut asked = 0;
    let mut command = cmux_process::Command::new("sh");
    command.arg("-c").arg("sleep 1; echo up");
    let ran = output_by_unless(command, began + Duration::from_millis(200), &mut || {
        asked += 1;
        Some(Instant::now() + Duration::from_secs(20))
    });
    assert_eq!((ran.code, ran.stdout.as_str()), (0, "up\n"), "{}", ran.stderr);
    assert_eq!(asked, 1);

    let began = Instant::now();
    let mut asked = 0;
    let mut command = cmux_process::Command::new("sh");
    command.arg("-c").arg("sleep 30");
    let ran = output_by_unless(command, began + Duration::from_millis(200), &mut || {
        asked += 1;
        (asked < 3).then(|| Instant::now() + Duration::from_millis(200))
    });
    assert_eq!(ran.code, PAST_DEADLINE, "{ran:?}");
    assert_eq!(asked, 3);
    assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
}
