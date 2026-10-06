//! A warm template terminal host (started at image bake, parked while the
//! daemon is gone, adopted by the clone's daemon) must not wake while idle.
//! A Freestyle VM baked from main measured that host's accept loop at about
//! 50 wakeups per second: `accept4` returned EAGAIN and `poll(listener, 20 ms)`
//! timed out, for the whole life of the terminal (strace, 488 polls in 10 s).

use super::*;

/// Quiet window over which context switches are counted.
const WINDOW: Duration = Duration::from_secs(10);
/// Switches allowed per window. A periodic wake of 1 Hz or faster gives at
/// least 10; a stray one-shot event gives one or two.
const MAX_SWITCHES: u64 = 5;

/// Voluntary plus involuntary context switches of every thread of `pid`.
#[cfg(target_os = "linux")]
fn context_switches(pid: u32) -> u64 {
    fs::read_dir(format!("/proc/{pid}/task"))
        .unwrap()
        .filter_map(Result::ok)
        .filter_map(|task| fs::read_to_string(task.path().join("status")).ok())
        .flat_map(|status| {
            status
                .lines()
                .filter(|line| line.contains("ctxt_switches:"))
                .filter_map(|line| line.split_whitespace().nth(1)?.parse::<u64>().ok())
                .collect::<Vec<_>>()
        })
        .sum()
}

/// Context switches of every thread of `pid` (`pti_csw` of PROC_PIDTASKINFO).
#[cfg(target_os = "macos")]
fn context_switches(pid: u32) -> u64 {
    use std::os::raw::{c_int, c_void};

    #[repr(C)]
    #[derive(Default)]
    struct TaskInfo {
        virtual_size: u64,
        resident_size: u64,
        total_user: u64,
        total_system: u64,
        threads_user: u64,
        threads_system: u64,
        policy: i32,
        faults: i32,
        pageins: i32,
        cow_faults: i32,
        messages_sent: i32,
        messages_received: i32,
        syscalls_mach: i32,
        syscalls_unix: i32,
        csw: i32,
        threadnum: i32,
        numrunning: i32,
        priority: i32,
    }

    unsafe extern "C" {
        fn proc_pidinfo(
            pid: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *mut c_void,
            size: c_int,
        ) -> c_int;
    }
    const PROC_PIDTASKINFO: c_int = 4;
    let mut task = TaskInfo::default();
    let size = size_of::<TaskInfo>() as c_int;
    // SAFETY: the buffer matches PROC_PIDTASKINFO's C layout and size.
    let read =
        unsafe { proc_pidinfo(pid as c_int, PROC_PIDTASKINFO, 0, (&raw mut task).cast(), size) };
    assert_eq!(read, size, "proc_pidinfo({pid})");
    task.csw.max(0) as u64
}

fn switches_over_window(pid: u32) -> u64 {
    let before = context_switches(pid);
    std::thread::sleep(WINDOW);
    context_switches(pid).saturating_sub(before)
}

#[test]
fn parked_and_adopted_template_hosts_do_not_wake_while_idle() {
    let mut harness = RecoveryHarness::start("template-idle");
    let parked = park_template_host(&mut harness);
    // The bake state: the daemon is gone and only the host runs.
    std::thread::sleep(Duration::from_secs(1));
    let parked_switches = switches_over_window(parked.host_pid);

    harness.adopt_template_terminal = true;
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let surface = loop {
        let resolved = request_response(
            &harness.socket,
            serde_json::json!({"id": 6, "cmd": "resolve-terminal", "terminal_id": parked.terminal_id}),
        );
        if resolved["ok"] == true
            && resolved["data"]["lifecycle"] == "running"
            && let Some(surface) = resolved["data"]["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "the template terminal was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    };
    // One-shot adoption work (snapshot, record rewrite) ends first.
    std::thread::sleep(Duration::from_secs(3));
    let adopted_switches = switches_over_window(parked.host_pid);

    assert!(
        parked_switches <= MAX_SWITCHES && adopted_switches <= MAX_SWITCHES,
        "idle template host woke: {parked_switches} switches parked, {adopted_switches} adopted, \
         in {WINDOW:?} each"
    );
    close_terminal_surface(&harness.socket, surface, 7);
    wait_for_no_host_records(&harness.host_root());
}
