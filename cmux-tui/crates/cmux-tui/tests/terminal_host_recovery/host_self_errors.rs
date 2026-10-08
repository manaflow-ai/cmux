//! cx-0tgl LB: a terminal host never ends its own shell. A signal whose
//! default action terminates the process, or an error on the host's own
//! listener (descriptor exhaustion on accept), leaves the shell running and
//! the host serving it.

use super::*;

/// Catchable signals whose default action ends a process, besides the four
/// that L0 already records (TERM, HUP, INT, QUIT).
const DEFAULT_TERMINATING_SIGNALS: [libc::c_int; 8] = [
    libc::SIGUSR1,
    libc::SIGUSR2,
    libc::SIGALRM,
    libc::SIGVTALRM,
    libc::SIGPROF,
    libc::SIGXCPU,
    libc::SIGXFSZ,
    libc::SIGPIPE,
];

fn run_cat(socket: &Path, id: u64, name: &str) -> (String, u64) {
    let created = request(
        socket,
        serde_json::json!({"id":id,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":name}),
    );
    (created["terminal_id"].as_str().unwrap().to_string(), created["surface"].as_u64().unwrap())
}

fn echo_round_trip(socket: &Path, surface: u64, marker: &str) {
    request(
        socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    let screen = wait_for_screen(socket, surface, marker);
    assert!(screen.contains(marker), "terminal did not echo {marker}: {screen}");
}

fn assert_host_live(record_path: &Path, record: &TerminalHostRecord, step: &str) {
    assert_eq!(
        terminal_host_record_liveness(record_path, record).unwrap(),
        TerminalHostLiveness::Live,
        "the terminal host ended after {step}"
    );
}

#[test]
fn default_terminating_signals_to_a_terminal_host_are_survived() {
    let harness = RecoveryHarness::start("host-default-signals");
    let (terminal_id, surface) = run_cat(&harness.socket, 1, "signals");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    for signal in DEFAULT_TERMINATING_SIGNALS {
        // SAFETY: the PID is the terminal host this test started; the
        // signal is a constant.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, signal) }, 0);
        echo_round_trip(&harness.socket, surface, &format!("after-signal-{signal}"));
        assert_host_live(&record_path, &record, &format!("signal {signal}"));
    }
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
}

/// Open descriptors of `pid` (Linux `/proc`).
#[cfg(target_os = "linux")]
fn open_descriptors(pid: u32) -> std::collections::BTreeSet<u64> {
    fs::read_dir(format!("/proc/{pid}/fd"))
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
        .collect()
}

#[cfg(target_os = "linux")]
fn set_descriptor_limit(pid: u32, soft: u64) -> u64 {
    let mut old = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: reads the limit of a process this test started.
    assert_eq!(
        unsafe { libc::prlimit(pid as libc::pid_t, libc::RLIMIT_NOFILE, std::ptr::null(), &mut old) },
        0
    );
    let new = libc::rlimit { rlim_cur: soft.min(old.rlim_max), rlim_max: old.rlim_max };
    // SAFETY: lowers or restores the soft limit of a process this test started.
    assert_eq!(
        unsafe { libc::prlimit(pid as libc::pid_t, libc::RLIMIT_NOFILE, &new, std::ptr::null_mut()) },
        0,
        "prlimit: {}",
        std::io::Error::last_os_error()
    );
    old.rlim_cur
}

/// Descriptor exhaustion makes the host's `accept` fail with EMFILE. That is
/// a transient condition of the host, never a reason to end its shell: once
/// descriptors are free again, the pending and later clients are served.
#[cfg(target_os = "linux")]
#[test]
fn descriptor_exhaustion_on_accept_never_ends_the_shell() {
    let harness = RecoveryHarness::start("host-accept-emfile");
    let (terminal_id, surface) = run_cat(&harness.socket, 1, "emfile");
    echo_round_trip(&harness.socket, surface, "before-emfile");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    let open = open_descriptors(record.host_pid);
    let lowest_free = (0..).find(|fd| !open.contains(fd)).unwrap();
    let previous = set_descriptor_limit(record.host_pid, lowest_free);
    // Clients the host cannot accept now: each wakes its accept loop.
    let pending = (0..4)
        .map(|_| UnixStream::connect(&record.endpoint).expect("connect to the host endpoint"))
        .collect::<Vec<_>>();
    let settle = Instant::now() + Duration::from_millis(500);
    while Instant::now() < settle {
        assert_host_live(&record_path, &record, "an accept failed with EMFILE");
        std::thread::sleep(Duration::from_millis(20));
    }
    set_descriptor_limit(record.host_pid, previous);
    drop(pending);

    echo_round_trip(&harness.socket, surface, "after-emfile");
    assert_host_live(&record_path, &record, "descriptors were free again");
    // The accept loop still serves new clients.
    let mut probe = UnixStream::connect(&record.endpoint).expect("connect after EMFILE");
    probe.set_read_timeout(Some(test_timeout(Duration::from_secs(5)))).unwrap();
    drop(probe);
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    assert_eq!(resolved["terminal_id"], terminal_id.as_str(), "{resolved}");
}
