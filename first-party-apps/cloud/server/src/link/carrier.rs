//! [`CarrierSpawner`]: the real link of one machine. It owns the machine's
//! local socket (the carrier the Mac client, ports and the browser proxy
//! dial) and runs one `cmux link dial --host <host_…>` child per accepted
//! connection, splicing the connection to the child's stdin and stdout
//! (super::dial is the only place that knows that seam).
//!
//! Ready: the carrier reports `carrier-ready` as soon as it listens (the
//! readiness check before it is a `connect_info` read, super::info). Each
//! stream is one dial and one fresh link token inside `cmux link`
//! (contract 1.7). A stream refused with `unknown_host`, `not_authorized`
//! or `host_paused` reports `dial-failed` with the typed code and the
//! supervisor ends the generation. An `unreachable` dial also ends the
//! generation, so a listening carrier never stays ready after its path failed.
//!
//! Events go to the supervisor only through [`LinkEvents`]: no timer, no
//! polling. Every child is started by this carrier and only those children
//! are ended by it (by their own handles, never by name or pattern).

use super::argv::{LinkCommand, dial_failed_line, ready_line};
use super::dial::{DialCode, DialReply, MAX_REPLY_BYTES, Refusal, parse_reply};
use super::spawner::{LinkEvents, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag};
use crate::app_env::private_dir;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::fs::MetadataExt as _;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// Streams (dialing or carrying) at once per machine; more connections
/// are closed at once (the client sees end of stream and may retry).
const MAX_STREAMS: usize = 64;

/// The real spawner: one carrier per link generation.
pub struct CarrierSpawner;

/// The children of one carrier (or of one file op), so `terminate` (or a
/// deadline) ends exactly them, by their own handles.
pub(crate) type Children = Arc<Mutex<Vec<Arc<Mutex<Child>>>>>;

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The stages a stream reached, for a test's failure message: kinds and byte
/// counts only, never a payload. Compiled out of the server.
#[cfg(test)]
static STAGES: Mutex<Vec<String>> = Mutex::new(Vec::new());

macro_rules! stage {
    ($($arg:tt)*) => {
        #[cfg(test)]
        lock(&STAGES).push(format!($($arg)*));
    };
}

/// A copy's result as a stage says it: its byte count or its error's kind.
#[cfg(test)]
fn copied(result: &std::io::Result<u64>) -> String {
    match result {
        Ok(bytes) => format!("{bytes} bytes"),
        Err(e) => format!("error {:?}", e.kind()),
    }
}

/// A dial child after its `ok` reply line: stdin and stdout carry the
/// daemon stream. The child stays in its `Children` list until
/// [`end_child`].
pub(crate) struct Dialed {
    pub(crate) child: Arc<Mutex<Child>>,
    pub(crate) stdin: ChildStdin,
    pub(crate) stdout: ChildStdout,
}

/// Starts `binary args` (one `cmux link dial`) with exactly `env`, records
/// it in `children` BEFORE it reads the reply line (so a terminate or a
/// deadline can end a dial that hangs), and reads its reply line from
/// stderr. The rest of its stderr goes to this server's stderr (the host's
/// log); the dial writes no credential there. A refused or broken dial is
/// ended before this returns.
pub(crate) fn open_dial(
    binary: &Path,
    args: &[String],
    env: &[(String, String)],
    children: &Children,
) -> Result<Dialed, Refusal> {
    if !binary.is_absolute() {
        return Err(DialCode::Unavailable("the link binary is not an absolute path".into()).into());
    }
    let mut process = Command::new(binary);
    process.args(args).env_clear();
    process.envs(env.iter().map(|(k, v)| (k, v)));
    let mut child = process
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            Refusal::from(DialCode::Unavailable(format!("cmux link dial did not start: {e}")))
        })?;
    let pipes = (child.stdin.take(), child.stdout.take(), child.stderr.take());
    let child = Arc::new(Mutex::new(child));
    lock(children).push(Arc::clone(&child));
    let (Some(stdin), Some(stdout), Some(stderr)) = pipes else {
        end_child(&child, children);
        return Err(DialCode::Unavailable("cmux link dial has no pipes".into()).into());
    };
    let mut stderr = BufReader::new(stderr);
    let mut line = Vec::new();
    let read = (&mut stderr).take(MAX_REPLY_BYTES as u64).read_until(b'\n', &mut line);
    let reply = match read {
        Ok(_) => parse_reply(&String::from_utf8_lossy(&line)),
        Err(e) => DialReply::Refused(DialCode::Unavailable(format!("cmux link dial: {e}")).into()),
    };
    // Drain the rest of stderr so the child never blocks on a full pipe.
    let _ = std::thread::Builder::new().name("cmux-link-dial-stderr".into()).spawn(move || {
        let _ = std::io::copy(&mut stderr, &mut std::io::stderr());
    });
    stage!("dial reply parsed: {}", if matches!(reply, DialReply::Connected { .. }) { "connected" } else { "refused" });
    match reply {
        DialReply::Connected { .. } => Ok(Dialed { child, stdin, stdout }),
        DialReply::Refused(refusal) => {
            end_child(&child, children);
            Err(refusal)
        }
    }
}

/// Ends one child this server started and forgets it.
pub(crate) fn end_child(child: &Arc<Mutex<Child>>, children: &Children) {
    {
        let mut child = lock(child);
        let _ = child.kill();
        let _ = child.wait();
    }
    lock(children).retain(|c| !Arc::ptr_eq(c, child));
}

/// Ends every child in `children` (a terminate or a deadline).
pub(crate) fn end_all(children: &Children) {
    let all: Vec<_> = lock(children).drain(..).collect();
    for child in all {
        let mut child = lock(&child);
        let _ = child.kill();
        let _ = child.wait();
    }
}

/// Carries one local connection over one dial; returns when both sides end.
fn splice(connection: UnixStream, dialed: Dialed, children: &Children) {
    let Dialed { child, mut stdin, mut stdout } = dialed;
    let Ok(mut upload_from) = connection.try_clone() else {
        end_child(&child, children);
        return;
    };
    let upload = std::thread::Builder::new().name("cmux-link-up".into()).spawn(move || {
        let _up = pump(&mut upload_from, &mut stdin);
        stage!("upload ended: {}", copied(&_up));
        // Dropping stdin tells the dial the client is done writing.
    });
    let Ok(upload) = upload else {
        // No upload, no stream: the client sees end of stream, never a half-open one.
        stage!("upload worker did not spawn");
        end_child(&child, children);
        return;
    };
    stage!("upload worker spawned");
    let mut download_to = connection;
    let _down = pump(&mut stdout, &mut download_to);
    stage!("download ended: {}", copied(&_down));
    let _ = download_to.flush();
    let _ = download_to.shutdown(std::net::Shutdown::Both);
    end_child(&child, children);
    let _ = upload.join();
}

/// Copies `from` to `to` until `from` ends, writing each read at once: a
/// plain read and write loop, never `std::io::copy`, whose Linux fast path
/// may splice a socket into the dial's pipe and hold a short line (one
/// `identify`) back. Returns the bytes copied, or the first error.
fn pump(from: &mut impl std::io::Read, to: &mut impl std::io::Write) -> std::io::Result<u64> {
    let mut buffer = [0u8; 16 * 1024];
    let mut total = 0u64;
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) => return Ok(total),
            Ok(read) => read,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        to.write_all(&buffer[..read])?;
        to.flush()?;
        total += read as u64;
    }
}

/// The socket file this carrier bound: (device, inode). A later carrier of
/// the same machine binds a new file at the same path; the old carrier
/// removes the path only while it still names its own file.
type FileId = (u64, u64);

fn file_id(path: &Path) -> Option<FileId> {
    std::fs::symlink_metadata(path).ok().map(|m| (m.dev(), m.ino()))
}

struct Carrier {
    stop: Arc<AtomicBool>,
    socket: PathBuf,
    bound: Option<FileId>,
    children: Children,
}

impl LinkProcess for Carrier {
    fn pid(&self) -> Option<u32> {
        None
    }

    fn terminate(&mut self) {
        if self.stop.swap(true, Ordering::SeqCst) {
            return;
        }
        // Wake the accept loop: it sees `stop` and ends the carrier.
        let _ = UnixStream::connect(&self.socket);
        // The socket file goes now, before the next generation binds; never
        // a file this carrier did not bind.
        if self.bound.is_some() && file_id(&self.socket) == self.bound {
            let _ = std::fs::remove_file(&self.socket);
        }
        end_all(&self.children);
    }
}

impl Drop for Carrier {
    fn drop(&mut self) {
        self.terminate();
    }
}

impl LinkSpawner for CarrierSpawner {
    fn spawn(
        &mut self,
        tag: LinkTag,
        command: &LinkCommand,
        events: LinkEvents,
    ) -> std::io::Result<Box<dyn LinkProcess>> {
        if !command.binary.is_absolute() {
            return Err(std::io::Error::other("the link binary is not an absolute path"));
        }
        private_dir(&command.state_dir)?;
        if let Some(dir) = command.local_socket.parent() {
            private_dir(dir)?;
        }
        // A socket left by a dead carrier would make the bind fail. The
        // folder is owner-only, so no one else can put a file there.
        match std::fs::remove_file(&command.local_socket) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let listener = UnixListener::bind(&command.local_socket)?;
        let stop = Arc::new(AtomicBool::new(false));
        let carrier = Carrier {
            stop: Arc::clone(&stop),
            socket: command.local_socket.clone(),
            bound: file_id(&command.local_socket),
            children: Arc::default(),
        };
        let children = Arc::clone(&carrier.children);
        let command = command.clone();
        std::thread::Builder::new().name(format!("cmux-link-{}", tag.machine)).spawn(
            move || {
                run(&tag, &command, &listener, &stop, &children, &events);
                let _ = events.send(LinkProcessEvent::Exited { tag, code: Some(0) });
            },
        )?;
        Ok(Box::new(carrier))
    }
}

/// Counts one stream from accept to its end.
struct StreamSlot(Arc<AtomicUsize>);

impl Drop for StreamSlot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// A refusal that ends the link generation: the machine is gone, access
/// ended, it is paused (the next connect starts it), or its path is
/// unreachable. A retry opens a new generation; transient malformed or
/// unavailable replies still end only the stream.
fn ends_generation(code: &DialCode) -> bool {
    matches!(
        code,
        DialCode::UnknownHost
            | DialCode::NotAuthorized
            | DialCode::HostPaused
            | DialCode::Unreachable
    )
}

/// The carrier's life: ready as soon as it listens (no dial: a dial mints
/// a link token, one per real connection), then one dial per accepted
/// connection until `stop`. An accept error ends the carrier (the link
/// goes down; the next connect opens a new one) instead of spinning.
fn run(
    tag: &LinkTag,
    command: &LinkCommand,
    listener: &UnixListener,
    stop: &Arc<AtomicBool>,
    children: &Children,
    events: &LinkEvents,
) {
    let ready =
        LinkProcessEvent::Line { tag: tag.clone(), line: ready_line(&command.local_socket) };
    if events.send(ready).is_err() {
        return;
    }
    let active = Arc::new(AtomicUsize::new(0));
    for connection in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let connection = match connection {
            Ok(connection) => connection,
            Err(e) => {
                eprintln!("cmux-cloud: the link carrier of {} stopped: {e}", tag.machine);
                return;
            }
        };
        if active.fetch_add(1, Ordering::SeqCst) >= MAX_STREAMS {
            active.fetch_sub(1, Ordering::SeqCst);
            continue; // dropping the connection closes it
        }
        let slot = StreamSlot(Arc::clone(&active));
        let command = command.clone();
        let children = Arc::clone(children);
        let events = events.clone();
        let tag = tag.clone();
        let stop = Arc::clone(stop);
        let _ = std::thread::Builder::new().name("cmux-link-stream".into()).spawn(move || {
            let _slot = slot;
            match open_dial(&command.binary, &command.args, &command.env, &children) {
                // A terminate that came while the dial opened: never serve it.
                Ok(dialed) if stop.load(Ordering::SeqCst) => end_child(&dialed.child, &children),
                Ok(dialed) => splice(connection, dialed, &children),
                // The client sees end of stream. A refusal that ends access
                // finds the machine paused, or cannot reach it goes to the supervisor, typed.
                Err(refusal) if ends_generation(&refusal.code) => {
                    let line = dial_failed_line(&refusal.code, refusal.detail.as_deref());
                    let _ = events.send(LinkProcessEvent::Line { tag, line });
                }
                Err(refusal) => eprintln!(
                    "cmux-cloud: a stream to {} was refused: {}{}",
                    tag.machine,
                    refusal.code.as_str(),
                    refusal.detail.map(|d| format!(" ({d})")).unwrap_or_default()
                ),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::{LinkState, LinkSupervisor};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    #[test]
    fn an_unreachable_dial_ends_the_ready_generation_and_can_be_retried() {
        let root = std::env::temp_dir().join(format!("cc-unreachable-{}", std::process::id()));
        let command = LinkCommand {
            binary: PathBuf::from("/bin/sh"),
            args: vec![
                "-c".into(),
                r#"printf '%s\n' '{"ok":false,"error_code":"unreachable","error_detail":"connect_info: cloud.machine.not_bound"}' >&2"#.into(),
            ],
            env: vec![],
            state_dir: root.join("state"),
            local_socket: root.join("carrier.sock"),
        };
        let (wake, woke) = channel();
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        supervisor.set_wake(Arc::new(move || {
            let _ = wake.send(());
        }));
        let carrier = supervisor.spawn_and_wait("vm-test", &command).expect("carrier listens");
        let connection = UnixStream::connect(&carrier.socket).expect("open a real carrier stream");
        // The ready wake may still be queued. Every next wake is bounded;
        // no sleep or poll is needed to observe the refused dial.
        for _ in 0..3 {
            woke.recv_timeout(Duration::from_secs(5)).expect("carrier event");
            supervisor.pump();
            if supervisor.refusal("vm-test").is_some() {
                break;
            }
        }
        assert_eq!(supervisor.refusal("vm-test"), Some(&DialCode::Unreachable));
        assert!(matches!(
            supervisor.state("vm-test"),
            Some(LinkState::Down { retryable: true, reason })
                if reason == "cmux link refused the dial: unreachable (connect_info: cloud.machine.not_bound)"
        ));
        assert!(supervisor.carrier("vm-test").is_none(), "a refused dial is not a ready link");
        drop(connection);
        let retry = supervisor.spawn_and_wait("vm-test", &command).expect("retry is allowed");
        assert_ne!(retry.generation, carrier.generation);
        supervisor.disconnect("vm-test");
        std::fs::remove_dir_all(root).expect("remove this test's private files");
    }

    /// A second stream whose dial child is slow (an overlay dial plus a token mint, each within its own limit) leaves a
    /// caller that budgets its first answer (cmux-tui's `identify`: 5 s) with nothing within that budget, while the stream
    /// already open keeps answering. Each accepted connection is its own `cmux link dial`, so the caller's budget runs from
    /// before the carrier even starts that dial. Budgets here are a tenth: 400 ms for the caller, 1 s for the dial child.
    /// The child is the carrier's to end: a terminate ends the one still dialing.
    #[test]
    fn a_slow_dial_of_a_second_stream_runs_past_its_callers_budget_while_the_first_stays_up() {
        let root = std::env::temp_dir().join(format!("cc-slow-dial-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("this test's folder");
        // The first dial answers at once; each later one takes 1 s. Every dial then echoes its stream (a daemon that answers).
        // Right after its reply it writes "up N" (its stdout reaches the client), and it marks "inN" once its first stdin line
        // came (the client's bytes reached it), so a stream that does not answer says which way it stopped.
        let script = r#"n=0; [ -f "$1/n" ] && read n < "$1/n"; echo $((n + 1)) > "$1/n"; echo $$ > "$1/pid$n"
[ "$n" -gt 0 ] && /bin/sleep 1
printf '%s\n' '{"ok":true,"path_state":"direct"}' >&2
printf 'up %s\n' "$n"
IFS= read -r line; : > "$1/in$n"; printf '%s\n' "$line"
exec /bin/cat"#;
        let command = LinkCommand {
            binary: PathBuf::from("/bin/sh"),
            args: vec![
                "-c".into(),
                script.into(),
                "sh".into(),
                root.to_string_lossy().into_owned(),
            ],
            env: vec![],
            state_dir: root.join("state"),
            local_socket: root.join("carrier.sock"),
        };
        // The dial child alone, with no carrier (its own folder, so the carrier's count starts at 0): it replies
        // on stderr and echoes stdin. If this holds and the carrier's stream below does not answer, the carrier is why.
        let alone = root.join("alone");
        std::fs::create_dir_all(&alone).expect("the self-check's folder");
        let mut child = Command::new("/bin/sh")
            .args(["-c", script, "sh", &alone.to_string_lossy()])
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("the dial child starts");
        let mut reply = String::new();
        BufReader::new(child.stderr.take().expect("stderr"))
            .read_line(&mut reply)
            .expect("its reply line");
        assert_eq!(reply, "{\"ok\":true,\"path_state\":\"direct\"}\n", "the dial child's reply");
        let mut stdout = BufReader::new(child.stdout.take().expect("stdout"));
        let mut marker = String::new();
        stdout.read_line(&mut marker).expect("its marker");
        assert_eq!(marker, "up 0\n", "the dial child writes its marker");
        child.stdin.take().expect("stdin").write_all(b"ping 0\n").expect("write to the dial child");
        let mut echoed = String::new();
        stdout.read_line(&mut echoed).expect("its echo");
        assert_eq!(echoed, "ping 0\n", "the dial child echoes");
        let _ = child.wait();

        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let carrier = supervisor.spawn_and_wait("vm-test", &command).expect("carrier listens");
        // One line, a byte at a time: nothing past it is read, so the next read starts at the next line.
        let line = |stream: &mut UnixStream| -> std::io::Result<String> {
            let mut answer = Vec::new();
            let mut byte = [0u8; 1];
            while answer.last() != Some(&b'\n') {
                if stream.read(&mut byte)? == 0 {
                    break;
                }
                answer.push(byte[0]);
            }
            Ok(String::from_utf8_lossy(&answer).into_owned())
        };
        let ask = |stream: &mut UnixStream, text: &str| -> std::io::Result<String> {
            stream.write_all(text.as_bytes())?;
            line(stream)
        };
        let mut app = UnixStream::connect(&carrier.socket).expect("the app's stream");
        app.set_read_timeout(Some(Duration::from_secs(5))).expect("bounded read");
        // What the dial children left (each writes its count and pid first), for a failure's message.
        let left = || {
            let mut names: Vec<String> = std::fs::read_dir(&root)
                .map(|dir| {
                    dir.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()
                })
                .unwrap_or_default();
            names.sort();
            format!(
                "{names:?}, n = {:?}; stages {:?}",
                std::fs::read_to_string(root.join("n")).ok(),
                lock(&STAGES).clone()
            )
        };
        let marker = line(&mut app);
        assert_eq!(marker.as_deref().ok(), Some("up 0\n"), "the app's dial reaches it: {marker:?}; {}", left());
        let first = ask(&mut app, "ping 1\n");
        assert_eq!(
            first.as_deref().ok(),
            Some("ping 1\n"),
            "the app's stream answers: {first:?}; dial children left {}",
            left()
        );

        let mut copy = UnixStream::connect(&carrier.socket).expect("the copy's stream");
        let budget = Duration::from_millis(400);
        copy.set_read_timeout(Some(budget)).expect("the caller's budget");
        let started = std::time::Instant::now();
        let silent = ask(&mut copy, "{\"cmd\":\"identify\",\"id\":1}\n")
            .expect_err("no answer within the caller's budget");
        assert!(
            matches!(silent.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut),
            "{silent}"
        );
        assert!(
            started.elapsed() < Duration::from_millis(900),
            "the budget, not the dial, ended the wait"
        );
        eprintln!("carrier stages: {}", left());
        // Meanwhile the open stream never stopped answering.
        assert_eq!(ask(&mut app, "ping 2\n").expect("the app's stream still answers"), "ping 2\n");

        let first = std::fs::read_to_string(root.join("pid0")).expect("the first dial ran");
        let slow = std::fs::read_to_string(root.join("pid1")).expect("the slow dial is running");
        supervisor.disconnect("vm-test");
        // A terminate ended and reaped both dials, the slow one included: no child outlives the carrier.
        for pid in [first.trim(), slow.trim()] {
            let alive = Command::new("/bin/kill")
                .args(["-0", pid])
                .stderr(Stdio::null())
                .status()
                .expect("kill -0");
            assert!(!alive.success(), "dial child {pid} outlived the carrier");
        }
        std::fs::remove_dir_all(root).expect("remove this test's private files");
    }
}
