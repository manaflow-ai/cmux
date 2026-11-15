//! A daemon start while the holder is slow to answer: the holder still runs every shell, so
//! the start does not wait for it and ends no terminal, and each terminal re-attaches when
//! the holder answers. Part of `holder_terminals.rs`.

use super::*;

/// Tabs of the large session (`a_restart_of_a_large_session_reattaches_every_terminal`).
const SESSION_TABS: usize = 120;

/// A process this test stopped. It runs again when this is dropped, at a failed assert too.
struct Stopped(i32);

impl Stopped {
    /// Stop `pid` and wait until it is stopped.
    fn stop(pid: i32) -> Self {
        // SAFETY: SIGSTOP of the holder this test's own daemon started (the caller proved it).
        unsafe { libc::kill(pid, libc::SIGSTOP) };
        let stopped = Self(pid);
        let deadline = Instant::now() + Duration::from_secs(20);
        while !process_state(pid).starts_with('T') {
            assert!(Instant::now() < deadline, "process {pid} never stopped");
            std::thread::sleep(Duration::from_millis(5));
        }
        stopped
    }
}

impl Drop for Stopped {
    fn drop(&mut self) {
        // SAFETY: SIGCONT of the process this test stopped.
        unsafe { libc::kill(self.0, libc::SIGCONT) };
    }
}

/// The state of `pid` as `ps` shows it (`T`: stopped).
fn process_state(pid: i32) -> String {
    let out = Command::new("ps").args(["-o", "state=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// A holder that is stopped when its daemon starts again (a suspended process, or a machine
/// too loaded to schedule it) answers no connect, and it still runs every shell. The daemon
/// must come up without it, keep the terminal with no new shell, and re-attach the same
/// shell with its screen when the holder runs again. Before, the start waited 30 s for the
/// holder and then recorded an end for the terminal.
#[test]
fn a_restart_keeps_the_terminal_of_a_stopped_holder_and_reattaches_it_when_the_holder_runs() {
    let mut daemon = Daemon::start();
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
            "name": "stopped-holder", "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    daemon.track(surface);
    send(&daemon.socket, surface, "kept-before-the-stop");
    screen_contains(&daemon.socket, surface, "kept-before-the-stop");
    let before =
        request(&daemon.socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
    let shell = shell_pid(&daemon.socket, surface);

    // Only this test's own holder gets a signal: the parent of the shell this test's daemon
    // started, which carries the owner mark of that daemon.
    let holder = parent_of(shell);
    let daemon_pid = daemon.child.as_ref().map(Child::id).unwrap();
    let holder_args = command_line(holder);
    assert!(
        holder > 1
            && holder != std::process::id() as i32
            && holder_args.contains(" --owner ")
            && holder_args.contains(&format!("@{daemon_pid}")),
        "process {holder} is not the holder of this test's daemon {daemon_pid}: {holder_args}"
    );

    daemon.sigkill();
    let stopped = Stopped::stop(holder);
    // The daemon listens while its holder answers nothing.
    daemon.restart();
    let kept =
        request(&daemon.socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
    assert_eq!(
        (&kept["exit"], &kept["surface"], &kept["terminal_incarnation"], &kept["lifecycle"]),
        (&Value::Null, &Value::Null, &before["terminal_incarnation"], &json!("running")),
        "(end, runtime, incarnation, lifecycle) while the holder is stopped: the terminal is \
         kept, with no new shell"
    );
    assert!(alive(shell), "the shell died while its holder was stopped");

    // The holder runs again: the same shell re-attaches, with its screen.
    drop(stopped);
    let surface = running_surface(&daemon.socket, &terminal_id);
    assert_eq!(shell_pid(&daemon.socket, surface), shell, "the terminal got a new shell");
    screen_contains(&daemon.socket, surface, "kept-before-the-stop");
    send(&daemon.socket, surface, "typed-after-the-holder-ran");
    screen_contains(&daemon.socket, surface, "typed-after-the-holder-ran");
}

/// A start gives the holder one wait for all its terminals together, and the terminals whose
/// turn comes after it re-attach after the start. In a large session every terminal must
/// run again with its own shell either way. Prints how many had their turn inside the wait,
/// as a `HOLDER-LATE-START` line (the daemon's own count, from its log).
#[test]
fn a_restart_of_a_large_session_reattaches_every_terminal() {
    let mut daemon = Daemon::start();
    let mut tabs = Vec::new();
    for tab in 0..SESSION_TABS {
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                "name": format!("large-{tab}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        daemon.track(surface);
        tabs.push((created["terminal_id"].as_str().unwrap().to_string(), surface));
    }
    let shells: Vec<i32> =
        tabs.iter().map(|(_, surface)| shell_pid(&daemon.socket, *surface)).collect();

    daemon.sigkill();
    let log = daemon.dir.join("restart.log");
    daemon.restart_with_stderr(Stdio::from(fs::File::create(&log).unwrap()));
    for (tab, (terminal_id, _)) in tabs.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        assert_eq!(shell_pid(&daemon.socket, surface), shells[tab], "tab {tab} got a new shell");
    }

    // "... (Linked, bound 250 ms): 87 of 120 terminals had their turn in time, 33 re-attach
    // after the start"
    let text = fs::read_to_string(&log).unwrap();
    let line = text
        .lines()
        .find(|line| line.contains("terminal holder at this start"))
        .unwrap_or_else(|| panic!("the daemon did not log its holder pass:\n{text}"));
    let numbers: Vec<usize> = line
        .split_once("):")
        .map_or("", |(_, counts)| counts)
        .split(|character: char| !character.is_ascii_digit())
        .filter_map(|number| number.parse().ok())
        .collect();
    let &[in_time, all, late] = numbers.as_slice() else {
        panic!("the daemon's holder pass line has other counts: {line}");
    };
    assert_eq!(
        (all, in_time + late),
        (SESSION_TABS, SESSION_TABS),
        "every terminal had its turn in the start or after it: {line}"
    );
    eprintln!(
        "HOLDER-LATE-START: {SESSION_TABS} terminals, all run again with their own shell; \
         {in_time} re-attached inside the start's wait for the holder, {late} after the start \
         ({})",
        line.trim()
    );
}
