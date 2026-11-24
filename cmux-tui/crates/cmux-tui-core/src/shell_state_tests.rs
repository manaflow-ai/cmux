//! The shell-state files and the request/ack, with a fake shell: `signal`
//! answers in place of the integration's trap. The real shells are in
//! `shell_integration/shell_state_tests.rs`.

use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "cmux-tui-shell-state-files-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// What the integration writes for a request: a history, then the state
/// file ending in the nonce read from the request.
fn answer(dir: &ShellStateDir, terminal: &TerminalPublicId, status: &str) {
    let nonce = fs::read_to_string(dir.path(terminal, REQUEST)).unwrap();
    fs::write(dir.path(terminal, HISTORY), "echo one\n").unwrap();
    fs::write(
        dir.path(terminal, STATE),
        format!("# cmux-tui shell state 1 bash {status}\nfoo=1\n# end {}\n", nonce.trim()),
    )
    .unwrap();
}

#[cfg(unix)]
fn mode(path: &Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn a_saved_state_is_handed_to_the_next_shell_once() {
    let root = temp_dir("handoff");
    let dir = ShellStateDir::new(root.join(DIRECTORY));
    let terminal = TerminalPublicId::random().unwrap();
    let prefix = dir.prefix(&terminal).unwrap();
    assert_eq!(prefix, root.join(DIRECTORY).join(terminal.as_str()));
    #[cfg(unix)]
    assert_eq!(mode(&root.join(DIRECTORY)), 0o700, "the directory is private");

    let outcomes = save_all(&dir, &[(terminal.clone(), 42)], Duration::from_secs(2), &|pid| {
        assert_eq!(pid, 42);
        #[cfg(unix)]
        assert_eq!(mode(&dir.path(&terminal, REQUEST)), 0o600, "the request is private");
        answer(&dir, &terminal, "ok");
        true
    });
    assert_eq!(outcomes[&terminal], SaveOutcome::Saved);
    assert!(!dir.path(&terminal, REQUEST).exists(), "the request goes when the wait ends");
    assert!(dir.saved_within(&terminal, Duration::from_secs(60)));

    assert!(dir.take_for_restore(&terminal));
    assert!(dir.path(&terminal, RESTORE).is_file());
    assert_eq!(fs::read_to_string(dir.path(&terminal, RESTORE_HISTORY)).unwrap(), "echo one\n");
    assert!(!dir.path(&terminal, STATE).exists() && !dir.path(&terminal, HISTORY).exists());
    assert!(
        !dir.saved_within(&terminal, Duration::from_secs(60)),
        "a handed-off state is not fresh"
    );

    // The next shell read and deleted them. A second restart with no new
    // save restores nothing.
    fs::remove_file(dir.path(&terminal, RESTORE)).unwrap();
    fs::remove_file(dir.path(&terminal, RESTORE_HISTORY)).unwrap();
    assert!(!dir.take_for_restore(&terminal));
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_restart_without_a_complete_save_removes_stale_restore_files() {
    let root = temp_dir("stale");
    let dir = ShellStateDir::new(root.join(DIRECTORY));
    let terminal = TerminalPublicId::random().unwrap();
    dir.prefix(&terminal).unwrap();
    // A restore file a shell never read, and a state cut short.
    fs::write(dir.path(&terminal, RESTORE), "old=1\n").unwrap();
    fs::write(dir.path(&terminal, RESTORE_HISTORY), "old\n").unwrap();
    fs::write(dir.path(&terminal, STATE), "# cmux-tui shell state 1 bash ok\nfoo=1\n").unwrap();
    assert!(!dir.take_for_restore(&terminal));
    assert!(fs::read_dir(root.join(DIRECTORY)).unwrap().next().is_none(), "every file went");

    // An unsaveable answer is never restored either.
    fs::write(
        dir.path(&terminal, STATE),
        "# cmux-tui shell state 1 bash unsaveable jobs\n# end abc\n",
    )
    .unwrap();
    assert!(!dir.take_for_restore(&terminal));
    assert!(!dir.path(&terminal, RESTORE).exists());

    // A respawn that is not a parked tab's restart discards everything.
    fs::write(dir.path(&terminal, RESTORE), "old=1\n").unwrap();
    dir.discard(&terminal);
    assert!(fs::read_dir(root.join(DIRECTORY)).unwrap().next().is_none());
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn a_save_without_an_answer_in_time_is_no_ack() {
    let root = temp_dir("timeout");
    let dir = ShellStateDir::new(root.join(DIRECTORY));
    let quiet = TerminalPublicId::random().unwrap();
    let gone = TerminalPublicId::random().unwrap();
    let fine = TerminalPublicId::random().unwrap();
    let signals = AtomicUsize::new(0);
    let started = Instant::now();
    let outcomes = save_all(
        &dir,
        &[(quiet.clone(), 10), (gone.clone(), 11), (fine.clone(), 12)],
        Duration::from_millis(150),
        &|pid| {
            signals.fetch_add(1, Ordering::Relaxed);
            match pid {
                10 => true,  // signalled, never answers
                11 => false, // no such process
                _ => {
                    answer(&dir, &fine, "unsaveable open-fd-7");
                    true
                }
            }
        },
    );
    let waited = started.elapsed();
    assert_eq!(signals.load(Ordering::Relaxed), 3, "every shell is asked before any wait");
    assert_eq!(outcomes[&quiet], SaveOutcome::NoAck);
    assert_eq!(outcomes[&gone], SaveOutcome::NoAck);
    assert_eq!(outcomes[&fine], SaveOutcome::Unsaveable("open-fd-7".into()));
    assert!(waited >= Duration::from_millis(150), "the wait lasts its bound: {waited:?}");
    assert!(waited < Duration::from_secs(2), "one bound for all shells: {waited:?}");
    for terminal in [&quiet, &gone, &fine] {
        assert!(!dir.path(terminal, REQUEST).exists(), "requests go when the wait ends");
    }
    assert!(!dir.take_for_restore(&quiet) && !dir.take_for_restore(&fine));
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn an_answer_counts_only_for_its_own_request_once_complete() {
    assert_eq!(
        parse_answer("# cmux-tui shell state 1 bash ok\nx=1\n# end n1\n", "n1"),
        Some(SaveOutcome::Saved)
    );
    assert_eq!(
        parse_answer("# cmux-tui shell state 1 zsh ok\nx=1\n# end n1\n", "n2"),
        None,
        "another request's"
    );
    assert_eq!(parse_answer("# cmux-tui shell state 1 bash ok\nx=1\n", "n1"), None, "cut short");
    assert_eq!(parse_answer("x=1\n# end n1\n", "n1"), None, "no header");
    assert_eq!(parse_answer("# cmux-tui shell state 1 bash ok\n# end \n", ""), None, "no nonce");
    assert_eq!(
        parse_answer("# cmux-tui shell state 1 bash unsaveable jobs\n# end n1\n", "n1"),
        Some(SaveOutcome::Unsaveable("jobs".into()))
    );
}

#[test]
fn files_of_terminals_that_left_the_session_are_removed() {
    let root = temp_dir("prune");
    let dir = ShellStateDir::new(root.join(DIRECTORY));
    let live = TerminalPublicId::random().unwrap();
    let closed = TerminalPublicId::random().unwrap();
    dir.prefix(&live).unwrap();
    for terminal in [&live, &closed] {
        fs::write(dir.path(terminal, STATE), "x").unwrap();
        fs::write(dir.path(terminal, RESTORE_HISTORY), "x").unwrap();
    }
    fs::write(root.join(DIRECTORY).join(format!(".{}.request.tmp", closed.as_str())), "x").unwrap();
    fs::write(root.join(DIRECTORY).join("stray"), "x").unwrap();
    let removed = dir.remove_unowned(&HashSet::from([live.clone()]));
    assert_eq!(removed, 4);
    let mut left: Vec<String> = fs::read_dir(root.join(DIRECTORY))
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(
        left,
        vec![format!("{}.restore-history", live.as_str()), format!("{}.state", live.as_str())]
    );
    fs::remove_dir_all(&root).unwrap();
}
