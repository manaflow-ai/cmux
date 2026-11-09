use super::*;

struct Home(PathBuf);

impl Home {
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn runs() -> (ShellRuns, Home) {
    let id = new_id().expect("random");
    let home = Home(std::env::temp_dir().join(format!("cmux-shell-runs-{id}")));
    std::fs::create_dir_all(home.path()).expect("home");
    let runs = ShellRuns::new(Config { shell: PathBuf::from("/bin/sh"), home: home.path().to_path_buf() });
    (runs, home)
}

/// Every chunk until the exit, its output joined.
fn read_to_end(runs: &ShellRuns, id: &str) -> (String, Exit) {
    let mut after = 0;
    let mut output = String::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        assert!(Instant::now() < deadline, "the run never ended");
        let chunk = runs.read(id, after, READ_WAIT).expect("read");
        output.push_str(&chunk.output);
        after = chunk.next;
        if let Some(exit) = chunk.exit {
            return (output, exit);
        }
    }
}

#[test]
fn a_command_runs_in_its_folder_with_stdout_and_stderr_and_its_exit_code() {
    let (runs, home) = runs();
    std::fs::create_dir(home.path().join("chat")).expect("folder");
    let id = runs.run("pane", 1, "pwd; echo out; echo err >&2; echo $TERM $PAGER; exit 3", Some("~/chat")).expect("run");
    let (output, exit) = read_to_end(&runs, &id);
    let folder = home.path().join("chat").canonicalize().expect("canonical");
    assert!(output.contains(folder.to_str().expect("utf-8")), "{output}");
    assert!(output.contains("out\n") && output.contains("err\n"), "{output}");
    assert!(output.contains("dumb cat"), "{output}");
    assert_eq!(exit, Exit { code: Some(3), signal: None });
}

#[test]
fn a_command_reads_nothing_from_stdin() {
    let (runs, _home) = runs();
    let id = runs.run("pane", 1, "cat; echo done", None).expect("run");
    let (output, exit) = read_to_end(&runs, &id);
    assert_eq!(output, "done\n");
    assert_eq!(exit.code, Some(0));
}

#[test]
fn a_missing_folder_or_an_empty_command_is_refused() {
    let (runs, home) = runs();
    let missing = home.path().join("nope");
    assert_eq!(runs.run("pane", 1, "true", missing.to_str()).err(), Some(Refusal::FolderMissing));
    assert_eq!(runs.run("pane", 1, "true", Some("relative/path")).err(), Some(Refusal::FolderMissing));
    assert_eq!(runs.run("pane", 1, "   ", None).err(), Some(Refusal::Invalid));
    assert_eq!(runs.run(&"s".repeat(MAX_SCOPE_BYTES + 1), 1, "true", None).err(), Some(Refusal::Invalid));
    assert_eq!(runs.kept(), 0);
}

#[test]
fn at_most_four_run_per_scope_and_a_finished_one_frees_its_place() {
    let (runs, _home) = runs();
    let ids: Vec<_> = (0..MAX_RUNNING).map(|_| runs.run("pane", 1, "sleep 30", None).expect("run")).collect();
    assert_eq!(runs.run("pane", 1, "true", None).err(), Some(Refusal::TooMany));
    // Another pane has its own four.
    let other = runs.run("other", 1, "true", None).expect("other scope");
    runs.stop(&ids[0]).expect("stop");
    let (_, exit) = read_to_end(&runs, &ids[0]);
    assert_eq!(exit.signal, Some(libc::SIGINT));
    assert!(runs.run("pane", 1, "true", None).is_ok());
    for id in &ids[1..] {
        runs.stop(id).expect("stop");
    }
    read_to_end(&runs, &other);
}

#[test]
fn finished_runs_past_sixteen_go_oldest_first() {
    let (runs, _home) = runs();
    let ids: Vec<_> = (0..=MAX_KEPT)
        .map(|_| {
            let id = runs.run("pane", 1, "true", None).expect("run");
            read_to_end(&runs, &id);
            id
        })
        .collect();
    // The next start evicts the oldest finished run.
    let last = runs.run("pane", 1, "true", None).expect("run");
    read_to_end(&runs, &last);
    assert_eq!(runs.read(&ids[0], 0, Duration::ZERO).err(), Some(Refusal::UnknownRun));
    assert!(runs.kept() <= MAX_KEPT);
    assert!(runs.read(&ids[MAX_KEPT], 0, Duration::ZERO).is_ok());
}

#[test]
fn a_read_waits_for_output_and_answers_empty_at_its_deadline() {
    let (runs, _home) = runs();
    let id = runs.run("pane", 1, "sleep 1; echo late", None).expect("run");
    let started = Instant::now();
    let empty = runs.read(&id, 0, Duration::from_millis(100)).expect("read");
    assert!(started.elapsed() >= Duration::from_millis(100));
    assert_eq!((empty.output.as_str(), empty.next, empty.exit), ("", 0, None));
    let chunk = runs.read(&id, 0, READ_WAIT).expect("read");
    assert_eq!(chunk.output, "late\n");
    assert!(started.elapsed() < READ_WAIT, "answered when output came, not at the deadline");
    let (_, exit) = read_to_end(&runs, &id);
    assert_eq!(exit.code, Some(0));
}

#[test]
fn reads_that_wait_are_bounded() {
    let (runs, _home) = runs();
    let id = runs.run("pane", 1, "sleep 30", None).expect("run");
    let permits: Vec<_> = (0..MAX_WAITING_READS)
        .map(|_| match runs.start_read(&id, 0).expect("start") {
            ReadStart::Wait(permit) => permit,
            ReadStart::Ready(_) => panic!("nothing to read yet"),
        })
        .collect();
    assert!(matches!(runs.start_read(&id, 0), Err(Refusal::Busy)));
    drop(permits);
    assert!(matches!(runs.start_read(&id, 0), Ok(ReadStart::Wait(_))));
    runs.stop(&id).expect("stop");
    read_to_end(&runs, &id);
}

#[test]
fn stop_escalates_past_a_command_that_ignores_interrupt() {
    let (runs, _home) = runs();
    let id = runs.run("pane", 1, "trap '' INT TERM; echo ready; sleep 30", None).expect("run");
    let ready = runs.read(&id, 0, READ_WAIT).expect("read");
    assert_eq!(ready.output, "ready\n");
    let started = Instant::now();
    runs.stop(&id).expect("stop");
    let (_, exit) = read_to_end(&runs, &id);
    assert_eq!(exit.signal, Some(libc::SIGKILL));
    assert!(started.elapsed() >= STOP_ESCALATION * 2, "SIGTERM then SIGKILL, each after its wait");
}

#[test]
fn a_background_child_holding_the_pipe_does_not_hold_the_run_open() {
    let (runs, _home) = runs();
    let id = runs.run("pane", 1, "sleep 30 & echo started", None).expect("run");
    let started = Instant::now();
    let (output, exit) = read_to_end(&runs, &id);
    assert_eq!(output, "started\n");
    assert_eq!(exit.code, Some(0));
    assert!(started.elapsed() < Duration::from_secs(5));
    // The leftover sleep is the user's; end it so the test leaves nothing running.
    let pgid = runs.shared.state.lock().recover_poison().runs.get(&id).map(|run| run.pgid).expect("kept");
    signal_group(pgid, libc::SIGKILL);
}

#[test]
fn output_past_the_buffer_drops_its_start() {
    let (runs, _home) = runs();
    // 2 MiB of 'x' lines, then the end marker.
    let id = runs.run("pane", 1, "head -c 2097152 /dev/zero | tr '\\0' x; echo; echo END", None).expect("run");
    // Wait for the exit without reading, so the buffer overflows first.
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let state = runs.shared.state.lock().recover_poison();
        if state.runs.get(&id).is_some_and(Run::finished) {
            break;
        }
        drop(state);
        assert!(Instant::now() < deadline);
        let state = runs.shared.state.lock().recover_poison();
        drop(runs.shared.changed.wait_timeout(state, Duration::from_millis(200)).recover_poison());
    }
    let first = runs.read(&id, 0, Duration::ZERO).expect("read");
    assert!(first.truncated);
    assert!(first.next > MAX_BUFFER as u64);
    assert_eq!(first.output.len(), MAX_READ);
    let (rest, exit) = read_to_end(&runs, &id);
    assert!(rest.ends_with("END\n"));
    assert_eq!(exit.code, Some(0));
    let kept = runs.shared.state.lock().recover_poison().runs.get(&id).map(|run| run.buffer.len()).expect("kept");
    assert_eq!(kept, MAX_BUFFER);
}

#[test]
fn a_hangup_ends_the_runs_of_the_connection_that_left() {
    let (runs, _home) = runs();
    let mine = runs.run("pane", 7, "sleep 30", None).expect("run");
    let theirs = runs.run("pane", 8, "sleep 30", None).expect("run");
    runs.client_left(7);
    let (_, exit) = read_to_end(&runs, &mine);
    assert_eq!(exit.signal, Some(libc::SIGHUP));
    assert!(runs.read(&theirs, 0, Duration::ZERO).expect("read").exit.is_none());
    runs.stop(&theirs).expect("stop");
    read_to_end(&runs, &theirs);
}

#[test]
fn a_split_character_waits_for_its_last_byte() {
    let euro = "€".as_bytes();
    assert_eq!(utf8_complete(&euro[..2]), 0);
    assert_eq!(utf8_complete(euro), 3);
    assert_eq!(utf8_complete(b"ab\xE2"), 2);
    assert_eq!(utf8_complete(b"plain"), 5);
}
