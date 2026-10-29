//! A running host's loops are hang-watched: its PTY, parser and
//! client-input threads register with the process's hang watch, an idle host is never blamed, and
//! a PTY write that waits for a program that does not read its input is the program's wait, not a
//! hang: a paste larger than the PTY input queue into `sleep`, and the parser's answer to a
//! terminal query queued behind that paste.
//!
//! The process watch is per process and every host in a process registers with it, so the test
//! runs again in a process of its own (`CHILD`), on a manual clock: the 2 s loop deadlines pass
//! without a 2 s wait.

use super::*;
use cmux_hang_watch::{Clock, Hang, HangSink};

const CHILD: &str = "CMUX_TUI_TEST_HOST_HANG_WATCH_CHILD";
const TEST: &str = "terminal_host_runtime::unix::tests::hang_watch_host::\
                    a_hosts_loops_register_and_a_paste_into_a_program_that_does_not_read_is_no_hang";
/// The host's watched loops: PTY, parser, client input.
const LOOPS: u64 = 3;
/// Past every loop deadline.
const PAST_DEADLINES: Duration = Duration::from_secs(10);
/// Far more than a PTY input queue holds.
const PASTE_BYTES: usize = 1 << 20;

#[derive(Default)]
struct ManualClock(AtomicU64);

impl ManualClock {
    fn advance(&self, by: Duration) {
        self.0.fetch_add(u64::try_from(by.as_nanos()).unwrap(), Ordering::SeqCst);
    }
}

impl Clock for ManualClock {
    fn now_ns(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

struct Recorded(Mutex<Sender<Hang>>);

impl HangSink for Recorded {
    fn record(&self, hang: &Hang) -> std::io::Result<()> {
        let _ = self.0.lock().unwrap().send(hang.clone());
        Ok(())
    }
}

#[test]
fn a_hosts_loops_register_and_a_paste_into_a_program_that_does_not_read_is_no_hang() {
    if std::env::var_os(CHILD).is_some() {
        return watched_host();
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
        .env(CHILD, "1")
        // As a host process: its loops' waits for work are recorded, not fatal.
        .env(cmux_threads::blocking::MODE_ENV, "record")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "the watched host failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stdout).contains("1 passed"),
        "the watched host did not run: {}",
        String::from_utf8_lossy(&output.stdout)
    );
}

fn registered() -> u64 {
    cmux_hang_watch::stats().expect("the process watch runs").registered
}

fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        thread::sleep(Duration::from_millis(10));
    }
}

/// Lets the watcher run passes on the moved clock, then the hangs it reported.
fn hangs_after_the_deadlines(clock: &ManualClock, hangs: &Receiver<Hang>) -> Vec<Hang> {
    clock.advance(PAST_DEADLINES);
    thread::sleep(Duration::from_millis(300));
    hangs.try_iter().collect()
}

/// The host of [`TEST`], in this process only.
fn watched_host() {
    let clock = Arc::new(ManualClock::default());
    let (sender, hangs) = mpsc_channel();
    // A short period, and no drift check: the manual clock jumps.
    let config = cmux_hang_watch::Config {
        min_deadline: Duration::from_millis(20),
        drift_tolerance: Duration::from_secs(3_600),
    };
    cmux_hang_watch::init_process(config, clock.clone(), Box::new(Recorded(Mutex::new(sender))))
        .expect("the process watch starts");

    let root = std::env::temp_dir().join(format!("cmux-host-hang-watch-{}", std::process::id()));
    prepare_private_dir(&root).unwrap();
    // A launcher reserves the record folder's publication until it has read the record.
    let publication = reserve_terminal_host_publication(&root).unwrap();
    let terminal_id = TerminalId::random().unwrap();
    let terminal_hex = terminal_id.to_hex();
    // The endpoint where a launcher puts it, which the owner's connect checks.
    let uid = sys::file_owner(&root).unwrap();
    prepare_endpoint_dir(&sys::endpoint_dir(uid)).unwrap();
    prepare_endpoint_dir(&sys::host_endpoint_dir(uid, &root)).unwrap();
    let endpoint = sys::host_endpoint(uid, &root, &terminal_hex);
    let record_path = root.join(format!("{terminal_hex}.json"));
    // No echo, so the paste is not read back; the program answers nothing and reads nothing. Its
    // two device-attribute queries come before and while the paste waits.
    let script =
        "stty -echo; sleep 0.3; printf '\\033[c'; sleep 1.5; printf '\\033[c'; exec sleep 60";
    let launch = HostLaunch {
        endpoint: endpoint.to_string_lossy().into_owned(),
        record_path: record_path.to_string_lossy().into_owned(),
        term: "xterm-256color".into(),
        cols: 80,
        rows: 24,
        cell_pixels: DEFAULT_CELL_PIXELS,
        scrollback: 1_000,
        cwd: Some("/tmp".into()),
        command: vec!["/bin/sh".into(), "-c".into(), script.into()],
        extra_env: Vec::new(),
        default_colors: DefaultColors::default(),
        kitty_graphics_limits: KittyGraphicsLimits::default(),
        seed: Vec::new(),
        workspace_key: String::new(),
    };
    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id,
        owner_token: CapabilityToken::random().unwrap(),
    };
    let (mut launcher, host_end) = UnixStream::pair().unwrap();
    let host = thread::spawn(move || {
        let (mut reader, mut writer) = (host_end.try_clone().unwrap(), host_end);
        serve_terminal_host_stdio(&["--bootstrap-stdio".to_string()], &mut reader, &mut writer)
    });
    write_frame(&mut launcher, &bootstrap.into_frame(1)).unwrap();
    assert_eq!(read_required_frame(&mut launcher, "bootstrap").unwrap().kind, MessageKind::Ready);
    let mut launch_frame = Frame::new(MessageKind::Launch, launch.encode().unwrap());
    launch_frame.request_id = 2;
    write_frame(&mut launcher, &launch_frame).unwrap();
    let launched = read_required_frame(&mut launcher, "launch")
        .unwrap_or_else(|error| panic!("{error}: the host ended with {:?}", host.join()));
    assert_eq!(launched.kind, MessageKind::Ready);

    let record: TerminalHostRecord =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    drop(publication);
    let attachment = adopt_terminal_host(record, record_path).expect("the owner attaches");
    wait_until("the host loops to register", || registered() == LOOPS);

    // Idle loops wait for work far past their deadlines, and the first query is answered.
    thread::sleep(Duration::from_millis(600));
    let idle = hangs_after_the_deadlines(&clock, &hangs);
    assert!(idle.is_empty(), "an idle host loop was blamed for its wait: {idle:?}");

    // The paste waits for `sleep` to read; the second query's answer waits behind it.
    let paste: Vec<u8> =
        (0..PASTE_BYTES).map(|at| if at % 64 == 63 { b'\n' } else { b'p' }).collect();
    attachment.send(MessageKind::Paste, &paste).unwrap();
    thread::sleep(Duration::from_millis(1_800));
    let blocked = hangs_after_the_deadlines(&clock, &hangs);
    assert!(blocked.is_empty(), "a PTY write's wait for the program was blamed: {blocked:?}");
    assert_eq!(registered(), LOOPS, "a host loop left the watch");

    attachment.disconnect();
    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_file(&endpoint);
}
