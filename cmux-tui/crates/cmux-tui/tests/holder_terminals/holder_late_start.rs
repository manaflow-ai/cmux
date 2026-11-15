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

/// The line a daemon writes for its ask of the holder at a start, from the daemon's log at
/// `path`. It must say that the holder was silent and that the one terminal re-attaches after
/// the start: a daemon writes that only after its greeting went to the holder and its wait for
/// the answer ran out.
fn silent_holder_pass(path: &Path, which: &str) -> String {
    let text = fs::read_to_string(path).unwrap();
    let line =
        text.lines().find(|line| line.contains("terminal holder at this start")).unwrap_or_else(
            || panic!("the {which} restarted daemon did not log its holder pass:\n{text}"),
        );
    assert!(
        line.contains("(Silent") && line.contains(" 1 re-attach after the start"),
        "the {which} restarted daemon did not wait for a silent holder: {line}"
    );
    line.trim().to_string()
}

/// The user of `fd`'s peer, read as the terminal holder reads it for a new connect.
#[cfg(target_os = "linux")]
fn peer_user(fd: i32) -> std::io::Result<libc::uid_t> {
    // SAFETY: a zeroed ucred is a valid out-buffer.
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: SO_PEERCRED fills one ucred; both pointers are to live locals.
    let read = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    if read == 0 { Ok(cred.uid) } else { Err(std::io::Error::last_os_error()) }
}

/// The user of `fd`'s peer, read as the terminal holder reads it for a new connect.
#[cfg(not(target_os = "linux"))]
fn peer_user(fd: i32) -> std::io::Result<libc::uid_t> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: out-pointers to live locals.
    if unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } == 0 {
        Ok(uid)
    } else {
        Err(std::io::Error::last_os_error())
    }
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

/// Two restarts of the daemon while the holder is stopped. The first restarted daemon sent
/// its greeting to the holder and is gone before the holder reads it; the second daemon
/// waits on a connect of its own. The holder finds both connects when it runs again. The
/// daemon that runs must then get the terminal back with its shell and its screen, and it
/// must be able to start a new terminal.
///
/// Each restarted daemon's log must have its line of a silent holder, so each sent its
/// greeting to the stopped holder. The test prints these lines, and what the second daemon
/// wrote about the holder after them, as a `HOLDER-LATE-START` line.
#[test]
fn a_second_restart_while_the_holder_is_stopped_reattaches_the_terminal() {
    let mut daemon = Daemon::start();
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
            "name": "two-restarts", "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    daemon.track(surface);
    send(&daemon.socket, surface, "kept-before-the-stop");
    screen_contains(&daemon.socket, surface, "kept-before-the-stop");
    let before =
        request(&daemon.socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
    let shell = shell_pid(&daemon.socket, surface);

    // Only this test's own holder gets a signal (see the test above).
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
    // The first restart: this daemon answers only after its start asked the holder, so its
    // greeting waits at the holder when the daemon is killed.
    let first_log = daemon.dir.join("first-restart.log");
    daemon.restart_with_stderr(Stdio::from(fs::File::create(&first_log).unwrap()));
    let kept_by = |socket: &Path, which: &str| {
        let kept = request(socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
        assert_eq!(
            (&kept["exit"], &kept["surface"], &kept["terminal_incarnation"], &kept["lifecycle"]),
            (&Value::Null, &Value::Null, &before["terminal_incarnation"], &json!("running")),
            "(end, runtime, incarnation, lifecycle) after the {which} restart, while the \
             holder is stopped: the terminal is kept, with no new shell"
        );
    };
    kept_by(&daemon.socket, "first");
    let first_pass = silent_holder_pass(&first_log, "first");
    daemon.sigkill();
    // The second restart: this daemon waits on its own connect.
    let log = daemon.dir.join("second-restart.log");
    daemon.restart_with_stderr(Stdio::from(fs::File::create(&log).unwrap()));
    kept_by(&daemon.socket, "second");
    let second_pass = silent_holder_pass(&log, "second");
    assert!(alive(shell), "the shell died while its holder was stopped");

    // The holder runs again: the same shell re-attaches to the daemon that runs.
    drop(stopped);
    let deadline = Instant::now() + Duration::from_secs(20);
    let surface = loop {
        let resolved =
            request(&daemon.socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(
            Instant::now() < deadline,
            "the terminal did not re-attach after the holder ran again: {resolved}\nthe \
             daemon's log:\n{}",
            fs::read_to_string(&log).unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(
        shell_pid(&daemon.socket, surface),
        shell,
        "the terminal got a new shell; the daemon's log:\n{}",
        fs::read_to_string(&log).unwrap_or_default()
    );
    screen_contains(&daemon.socket, surface, "kept-before-the-stop");
    send(&daemon.socket, surface, "typed-after-the-holder-ran");
    screen_contains(&daemon.socket, surface, "typed-after-the-holder-ran");

    // A new terminal starts on the same holder.
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
            "name": "after-two-restarts", "cols": 80, "rows": 24}),
    );
    let new_surface = created["surface"].as_u64().unwrap();
    daemon.track(new_surface);
    assert_eq!(
        parent_of(shell_pid(&daemon.socket, new_surface)),
        holder,
        "the new terminal does not run on the holder that ran before"
    );
    send(&daemon.socket, new_surface, "typed-in-the-new-terminal");
    screen_contains(&daemon.socket, new_surface, "typed-in-the-new-terminal");

    // The holder took no link that it had given to the daemon that runs. (It
    // can refuse a connect of that daemon before its answer; the daemon then
    // makes one new connect, and the line of that is printed below.)
    let text = fs::read_to_string(&log).unwrap();
    assert!(
        !text.contains("another daemon took the terminal holder"),
        "the holder took its link from the daemon that runs:\n{text}"
    );
    let later: Vec<&str> = text
        .lines()
        .filter(|line| line.contains("holder") && !line.contains("terminal holder at this start"))
        .map(str::trim)
        .collect();
    eprintln!(
        "HOLDER-LATE-START: two restarts while the holder was stopped. The first restart: \
         {first_pass}. The second restart: {second_pass}. The second daemon's later lines on \
         the holder: {later:?}"
    );
}

/// What this system gives a listener for a connect whose client is gone before the accept:
/// the state of the first restarted daemon's connect in the test above. The calls are the
/// ones the terminal holder makes for a new connect: the accept, the read of the peer's user
/// and the read of the bytes. Linux and macOS can differ here, so this test asserts nothing
/// on the results. It prints them as a `HOLDER-LATE-START` line, with a client that lives as
/// the control. It starts no holder and no daemon.
#[test]
fn a_listener_with_a_connect_whose_client_is_gone_prints_what_the_system_gives() {
    use cmux_holder::wire::{self, Kind, Out};
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixListener;

    let dir = unique_dir("cmux-holder");
    let path = dir.join("probe.sock");
    let listener = UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    // Each client sends one greeting frame whose last byte names it.
    let greeting = |name: u8| {
        wire::encode(Kind::Hello, 0, &Out::default().u16(wire::VERSION).bytes(&[name; 32]).0)
    };
    let mut gone = UnixStream::connect(&path).unwrap();
    gone.write_all(&greeting(1)).unwrap();
    drop(gone);
    let mut live = UnixStream::connect(&path).unwrap();
    live.write_all(&greeting(2)).unwrap();

    let mut accepts = Vec::new();
    let mut accept_errors = 0;
    loop {
        let stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(error) => {
                accepts.push(format!("accept error ({error})"));
                accept_errors += 1;
                if accept_errors == 4 {
                    break;
                }
                continue;
            }
        };
        let fd = stream.as_raw_fd();
        let user = match peer_user(fd) {
            // SAFETY: getuid has no failure mode.
            Ok(uid) => {
                format!("peer user read ok (same user: {})", uid == unsafe { libc::getuid() })
            }
            Err(error) => format!("peer user read error ({error})"),
        };
        let nonblocking = match stream.set_nonblocking(true) {
            Ok(()) => String::new(),
            Err(error) => format!("; nonblocking error ({error})"),
        };
        wire::tune_socket(fd);
        let mut reader = wire::Reader::default();
        let read = |reader: &mut wire::Reader| match reader.fill(fd) {
            Ok(true) => "bytes".to_string(),
            Ok(false) => "end of stream".to_string(),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                "no end yet".to_string()
            }
            Err(error) => format!("error ({error})"),
        };
        let first = read(&mut reader);
        let client = match reader.next_frame() {
            Ok(Some(frame)) => match frame.payload.last().copied() {
                Some(1) => "the greeting of the client that is gone",
                Some(2) => "the greeting of the client that lives",
                _ => "a frame of no client",
            },
            Ok(None) => "no whole frame",
            Err(_) => "bytes that are no frame",
        };
        let then = read(&mut reader);
        accepts.push(format!(
            "accept ok; {user}{nonblocking}; first read: {first} ({client}); then: {then}"
        ));
    }
    drop(live);
    let _ = fs::remove_dir_all(&dir);
    eprintln!(
        "HOLDER-LATE-START: a listener of this system ({}) with 2 connects, the older from a \
         client that is gone: {} accepts, in their order: {accepts:?}",
        std::env::consts::OS,
        accepts.len()
    );
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
    // The proof that each terminal runs again is the loop above (each shell's pid). The
    // line's counts are for the print: its first and last add up to `all` by the daemon's
    // own arithmetic, so only `all` is checked.
    assert_eq!(all, SESSION_TABS, "the daemon's holder pass saw every terminal: {line}");
    eprintln!(
        "HOLDER-LATE-START: {SESSION_TABS} terminals, all run again with their own shell; \
         {in_time} re-attached inside the start's wait for the holder, {late} after the start \
         ({})",
        line.trim()
    );
}
