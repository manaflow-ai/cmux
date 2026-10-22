//! End-to-end tests against the real keeper binary on every platform.

use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use cmux_pty_keeper::protocol::Frame;
use cmux_pty_keeper::{Connection, Event, Size};

const KEEPER: &str = env!("CARGO_BIN_EXE_cmux-pty-keeper");
const HELPER_ENV: &str = "CMUX_PTY_KEEPER_TEST_HELPER";
const TIMEOUT: Duration = Duration::from_secs(30);

fn endpoint() -> String {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, Ordering::SeqCst);
    #[cfg(unix)]
    {
        // /tmp keeps the path under the Unix socket length limit on macOS.
        let dir = format!("/tmp/cmux-keeper-{}-{n}", std::process::id());
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir(&dir).unwrap();
        format!("{dir}/k")
    }
    #[cfg(windows)]
    {
        format!(r"\\.\pipe\cmux-keeper-test-{}-{n}", std::process::id())
    }
}

/// `(program, args)` running a script in the platform shell. Windows uses
/// `cmd.exe` with delayed expansion, which starts fast on every image.
fn shell(unix: &str, windows: &str) -> (String, Vec<String>) {
    if cfg!(windows) {
        let args = ["/v:on", "/d", "/s", "/c", windows];
        ("cmd.exe".into(), args.map(String::from).to_vec())
    } else {
        ("/bin/sh".into(), vec!["-c".into(), unix.into()])
    }
}

fn start(program: &str, args: &[String]) -> String {
    let endpoint = endpoint();
    cmux_pty_keeper::spawn(Path::new(KEEPER), &endpoint, 80, 24, program, args, |_| {})
        .expect("keeper starts");
    endpoint
}

struct Output {
    chunks: mpsc::Receiver<Vec<u8>>,
    raw: Vec<u8>,
    /// Bytes of `text()` already matched.
    consumed: usize,
}

impl Output {
    fn start(mut reader: File) -> Self {
        let (tx, chunks) = mpsc::channel();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 || tx.send(buf[..n].to_vec()).is_err() {
                    break;
                }
            }
        });
        Self { chunks, raw: Vec::new(), consumed: 0 }
    }

    /// Output without escape sequences or whitespace. ConPTY repaints the
    /// screen and may replace runs of spaces with cursor movement.
    fn text(&self) -> String {
        let mut out = String::new();
        let mut bytes = self.raw.iter().copied();
        while let Some(b) = bytes.next() {
            match b {
                0x1b => match bytes.next() {
                    Some(b'[') => {
                        while bytes.next().is_some_and(|c| !(0x40..=0x7e).contains(&c)) {}
                    }
                    Some(b']') => while bytes.next().is_some_and(|c| c != 0x07 && c != 0x1b) {},
                    _ => {}
                },
                b if b.is_ascii_whitespace() || b.is_ascii_control() => {}
                b => out.push(b as char),
            }
        }
        out
    }

    /// Waits for `needle` and consumes the output up to and including it.
    fn wait_for(&mut self, needle: &str, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let text = self.text();
            if let Some(at) = text.get(self.consumed..).and_then(|rest| rest.find(needle)) {
                self.consumed += at + needle.len();
                return true;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            match self.chunks.recv_timeout(left) {
                Ok(chunk) => self.raw.extend_from_slice(&chunk),
                Err(_) => return false,
            }
        }
    }

    fn seen(&self) -> String {
        String::from_utf8_lossy(&self.raw).into_owned()
    }
}

fn wait_until_gone(endpoint: &str) {
    let deadline = Instant::now() + TIMEOUT;
    while Instant::now() < deadline {
        if Connection::connect(endpoint).is_err() {
            return;
        }
        thread::sleep(Duration::from_millis(100));
    }
    panic!("keeper at {endpoint} did not exit");
}

#[test]
fn keeper_round_trip_reports_exit_code() {
    let (program, args) = shell(
        r#"echo marker-ready; read line; echo "got:$line"; exit 7"#,
        "echo marker-ready& set /p line=& echo got:!line!& exit 7",
    );
    let endpoint = start(&program, &args);
    let mut conn = Connection::connect(&endpoint).unwrap();
    assert_eq!(conn.version(), 1);
    assert_ne!(conn.child_pid(), 0);
    let io = conn.take_io().expect("running child has a PTY");
    let mut output = Output::start(io.reader);
    assert!(output.wait_for("marker-ready", TIMEOUT), "no output: {:?}", output.seen());
    (&io.writer).write_all(b"abc\r").unwrap();
    assert!(output.wait_for("got:abc", TIMEOUT), "no echo: {:?}", output.seen());
    assert_eq!(conn.wait_exit().unwrap().code(), Some(7));
    drop(conn);
    wait_until_gone(&endpoint);
}

/// Runs as a separate process when `HELPER_ENV` is set: the first client,
/// which exits like a host being upgraded.
#[test]
fn keeper_helper_first_client() {
    let Ok(endpoint) = std::env::var(HELPER_ENV) else { return };
    let mut conn = Connection::connect(&endpoint).unwrap();
    let io = conn.take_io().unwrap();
    let mut output = Output::start(io.reader);
    (&io.writer).write_all(b"one\r").unwrap();
    let ok = output.wait_for("first:one", TIMEOUT);
    std::process::exit(if ok { 0 } else { 1 });
}

#[test]
fn keeper_keeps_child_alive_when_its_client_process_exits() {
    let (program, args) = shell(
        r#"read a; echo "first:$a"; read b; echo "second:$b"; exit 3"#,
        "set /p a=& echo first:!a!& set /p b=& echo second:!b!& exit 3",
    );
    let endpoint = start(&program, &args);

    let mut helper = Command::new(std::env::current_exe().unwrap())
        .args(["keeper_helper_first_client", "--exact", "--nocapture"])
        .env(HELPER_ENV, &endpoint)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + TIMEOUT * 2;
    let status = loop {
        if let Some(status) = helper.try_wait().unwrap() {
            break status;
        }
        if Instant::now() > deadline {
            let _ = helper.kill();
            panic!("first client process hung");
        }
        thread::sleep(Duration::from_millis(50));
    };
    assert!(status.success(), "first client failed: {status}");

    // Every descriptor of the first client is gone; only the keeper holds the PTY.
    let mut conn = Connection::connect(&endpoint).unwrap();
    let io = conn.take_io().expect("child is still running");
    let mut output = Output::start(io.reader);
    (&io.writer).write_all(b"two\r").unwrap();
    assert!(output.wait_for("second:two", TIMEOUT), "child did not survive: {:?}", output.seen());
    assert_eq!(conn.wait_exit().unwrap().code(), Some(3));
}

#[test]
fn keeper_resizes_and_reports_size_to_every_client() {
    let (program, args) =
        shell("while read a; do stty size; done", "for /l %i in (1,0,2) do @(set /p x=& mode con)");
    let endpoint = start(&program, &args);
    let mut conn = Connection::connect(&endpoint).unwrap();
    assert_eq!(conn.size(), (Size::new(80, 24), 0), "launch size reported after HELLO");
    let mut watcher = Connection::connect(&endpoint).unwrap();
    let io = conn.take_io().unwrap();
    let mut output = Output::start(io.reader);
    // Resize only after the child is running: older ConPTY builds
    // (Windows Server 2022) can lose a resize sent during child startup.
    let started = if cfg!(windows) { "Lines:24Columns:80" } else { "2480" };
    (&io.writer).write_all(b"\r").unwrap();
    assert!(output.wait_for(started, TIMEOUT), "child never started: {:?}", output.seen());
    conn.send_raw(&Frame::new(999, 1, 2, 3)).unwrap();
    conn.resize(Size::new(0, 10)).unwrap();
    let wanted = Size { cols: 100, rows: 40, width_px: 1000, height_px: 800 };
    conn.resize(wanted).unwrap();

    // The zero size is ignored, so the first report is the real resize,
    // and the other client hears about it too.
    let reported = Event::Size { size: wanted, generation: 1 };
    assert_eq!(conn.next_event().unwrap(), reported);
    assert_eq!(watcher.next_event().unwrap(), reported);
    let late = Connection::connect(&endpoint).unwrap();
    assert_eq!(late.size(), (wanted, 1), "a new client learns the current size");

    // SIZE means the size is applied, but the child may still be
    // processing SIGWINCH or the console repaint.
    let needle = if cfg!(windows) { "Lines:40Columns:100" } else { "40100" };
    let seen = (0..40).any(|_| {
        (&io.writer).write_all(b"\r").unwrap();
        output.wait_for(needle, Duration::from_millis(750))
    });
    assert!(seen, "child never saw the size: {:?}", output.seen());
    conn.terminate().unwrap();
    conn.wait_exit().unwrap();
    drop((conn, watcher, late));
    wait_until_gone(&endpoint);
}

#[test]
fn keeper_serves_many_clients_at_once() {
    let (program, args) = shell("exec sleep 1000", "ping -n 1000 127.0.0.1 >nul");
    let endpoint = start(&program, &args);
    let clients: Vec<_> = (0..40).map(|_| Connection::connect(&endpoint).unwrap()).collect();
    let mut first = Connection::connect(&endpoint).unwrap();
    first.terminate().unwrap();
    first.wait_exit().unwrap();
    for mut client in clients {
        assert!(client.wait_exit().is_ok());
    }
    drop(first);
    wait_until_gone(&endpoint);
}

#[test]
fn keeper_terminate_ends_a_running_child() {
    let (program, args) = shell("exec sleep 1000", "ping -n 1000 127.0.0.1 >nul");
    let endpoint = start(&program, &args);
    let mut conn = Connection::connect(&endpoint).unwrap();
    conn.terminate().unwrap();
    let status = conn.wait_exit().unwrap();
    #[cfg(unix)]
    assert_eq!(status.signal(), Some(libc::SIGHUP), "{status:?}");
    #[cfg(windows)]
    assert!(status.code().is_some(), "{status:?}");
    drop(conn);
    wait_until_gone(&endpoint);
}

#[test]
fn keeper_reports_exit_to_a_client_that_connects_later() {
    let (program, args) = shell("exit 5", "exit 5");
    let endpoint = start(&program, &args);
    thread::sleep(Duration::from_secs(2));
    let mut conn = Connection::connect(&endpoint).unwrap();
    if cfg!(unix) {
        assert!(conn.take_io().is_none(), "exited child must not hand out a PTY");
    }
    assert_eq!(conn.wait_exit().unwrap().code(), Some(5));
    drop(conn);
    wait_until_gone(&endpoint);
}

#[test]
fn keeper_spawn_reports_a_missing_program() {
    let program = if cfg!(windows) {
        r"C:\cmux-keeper-missing\nothing.exe"
    } else {
        "/cmux-keeper-missing/nothing"
    };
    let error =
        cmux_pty_keeper::spawn(Path::new(KEEPER), &endpoint(), 80, 24, program, [""; 0], |_| {})
            .expect_err("missing program must fail");
    let message = error.to_string();
    assert!(message.contains("keeper failed to start"), "{message}");
    assert!(message.contains("nothing"), "{message}");
}

/// The keeper's owner-only socket mask must not leak into the user's shell.
#[cfg(unix)]
#[test]
fn keeper_child_keeps_the_spawner_umask() {
    let endpoint = endpoint();
    let (program, args) = shell("echo \"mask:$(umask)\"; read x", "");
    cmux_pty_keeper::spawn(Path::new(KEEPER), &endpoint, 80, 24, &program, &args, |command| {
        use std::os::unix::process::CommandExt;
        // SAFETY: umask is async-signal-safe; it runs between fork and exec.
        unsafe {
            command.pre_exec(|| {
                libc::umask(0o022);
                Ok(())
            })
        };
    })
    .unwrap();
    let mut conn = Connection::connect(&endpoint).unwrap();
    let io = conn.take_io().unwrap();
    let mut output = Output::start(io.reader);
    assert!(output.wait_for("mask:0022", TIMEOUT), "umask leaked: {:?}", output.seen());
    conn.terminate().unwrap();
    conn.wait_exit().unwrap();
}
