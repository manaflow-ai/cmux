//! [`CarrierSpawner`]: the real link of one machine. It owns the machine's
//! local socket (the carrier the Mac client, ports and the browser proxy
//! dial) and runs one `cmux link dial --host <host_…>` child per accepted
//! connection, splicing the connection to the child's stdin and stdout
//! (super::dial is the only place that knows that seam).
//!
//! Ready: one probe dial first. Its reply line decides the link: on
//! `ok` the carrier reports `carrier-ready` with its socket and ends the
//! probe; on a refusal it reports `dial-failed` with the code and ends.
//! Each dial is one fresh link token inside `cmux link` (contract 1.7: a
//! token serves one hello, a reconnect mints a new one).
//!
//! Events go to the supervisor only through [`LinkEvents`]: no timer, no
//! polling. Every child is started by this carrier and only those children
//! are ended by it (by their own handles, never by name or pattern).

use super::argv::{LinkCommand, dial_failed_line, ready_line};
use super::dial::{DialCode, DialReply, MAX_REPLY_BYTES, parse_reply};
use super::spawner::{LinkEvents, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag};
use std::io::{BufRead as _, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// Dial children running at once per machine; more connections are closed
/// (the client sees end of stream and may retry).
const MAX_STREAMS: usize = 64;

/// The real spawner: one carrier per link generation.
pub struct CarrierSpawner;

fn private_dir(path: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(path)
}

/// The children of one carrier, so `terminate` ends exactly them.
type Children = Arc<Mutex<Vec<Arc<Mutex<Child>>>>>;

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A dial child after its reply line.
struct Dialed {
    child: Arc<Mutex<Child>>,
    stdin: ChildStdin,
    stdout: ChildStdout,
}

/// Starts one dial child and reads its reply line from stderr. The rest
/// of its stderr goes to this server's stderr (the host's log); the dial
/// writes no credential there.
fn dial(command: &LinkCommand, children: &Children) -> Result<Dialed, DialCode> {
    let mut process = Command::new(&command.binary);
    process.args(&command.args).env_clear();
    process.envs(command.env.iter().map(|(k, v)| (k, v)));
    let mut child = process
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| DialCode::Unavailable(format!("cmux link dial did not start: {e}")))?;
    let (Some(stdin), Some(stdout), Some(stderr)) =
        (child.stdin.take(), child.stdout.take(), child.stderr.take())
    else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(DialCode::Unavailable("cmux link dial has no pipes".into()));
    };
    let child = Arc::new(Mutex::new(child));
    lock(children).push(Arc::clone(&child));
    let mut stderr = BufReader::new(stderr);
    let mut line = Vec::new();
    let read = (&mut stderr).take(MAX_REPLY_BYTES as u64).read_until(b'\n', &mut line);
    let reply = match read {
        Ok(_) => parse_reply(&String::from_utf8_lossy(&line)),
        Err(e) => DialReply::Refused(DialCode::Unavailable(format!("cmux link dial: {e}"))),
    };
    // Drain the rest of stderr so the child never blocks on a full pipe.
    let _ = std::thread::Builder::new().name("cmux-link-dial-stderr".into()).spawn(move || {
        let _ = std::io::copy(&mut stderr, &mut std::io::stderr());
    });
    match reply {
        DialReply::Connected { .. } => Ok(Dialed { child, stdin, stdout }),
        DialReply::Refused(code) => {
            end_child(&child, children);
            Err(code)
        }
    }
}

/// Ends one child this carrier started and forgets it.
fn end_child(child: &Arc<Mutex<Child>>, children: &Children) {
    {
        let mut child = lock(child);
        let _ = child.kill();
        let _ = child.wait();
    }
    lock(children).retain(|c| !Arc::ptr_eq(c, child));
}

/// Carries one local connection over one dial; returns when both sides end.
fn splice(connection: UnixStream, dialed: Dialed, children: &Children) {
    let Dialed { child, mut stdin, mut stdout } = dialed;
    let Ok(mut upload_from) = connection.try_clone() else {
        end_child(&child, children);
        return;
    };
    let upload = std::thread::Builder::new().name("cmux-link-up".into()).spawn(move || {
        let _ = std::io::copy(&mut upload_from, &mut stdin);
        // Dropping stdin tells the dial the client is done writing.
    });
    let mut download_to = connection;
    let _ = std::io::copy(&mut stdout, &mut download_to);
    let _ = download_to.flush();
    let _ = download_to.shutdown(std::net::Shutdown::Both);
    end_child(&child, children);
    if let Ok(upload) = upload {
        let _ = upload.join();
    }
}

struct Carrier {
    stop: Arc<AtomicBool>,
    socket: PathBuf,
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
        let children: Vec<_> = lock(&self.children).drain(..).collect();
        for child in children {
            let mut child = lock(&child);
            let _ = child.kill();
            let _ = child.wait();
        }
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
        // A socket left by a dead carrier would make the bind fail.
        match std::fs::remove_file(&command.local_socket) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
        let listener = UnixListener::bind(&command.local_socket)?;
        let stop = Arc::new(AtomicBool::new(false));
        let children: Children = Arc::default();
        let carrier =
            Carrier { stop: Arc::clone(&stop), socket: command.local_socket.clone(), children };
        let children = Arc::clone(&carrier.children);
        let command = command.clone();
        std::thread::Builder::new().name(format!("cmux-link-{}", tag.machine)).spawn(
            move || {
                run(&tag, &command, &listener, &stop, &children, &events);
                let _ = std::fs::remove_file(&command.local_socket);
                let _ = events.send(LinkProcessEvent::Exited { tag, code: Some(0) });
            },
        )?;
        Ok(Box::new(carrier))
    }
}

/// The carrier's life: the probe, then one dial per accepted connection
/// until `stop`.
fn run(
    tag: &LinkTag,
    command: &LinkCommand,
    listener: &UnixListener,
    stop: &AtomicBool,
    children: &Children,
    events: &LinkEvents,
) {
    let line = |line: String| LinkProcessEvent::Line { tag: tag.clone(), line };
    match dial(command, children) {
        Ok(probe) => {
            end_child(&probe.child, children);
            if events.send(line(ready_line(&command.local_socket))).is_err() {
                return;
            }
        }
        Err(code) => {
            let _ = events.send(line(dial_failed_line(&code)));
            return;
        }
    }
    for connection in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Ok(connection) = connection else { continue };
        if lock(children).len() >= MAX_STREAMS {
            continue; // dropping the connection closes it
        }
        let command = command.clone();
        let children = Arc::clone(children);
        let _ =
            std::thread::Builder::new().name("cmux-link-stream".into()).spawn(move || {
                match dial(&command, &children) {
                    Ok(dialed) => splice(connection, dialed, &children),
                    Err(code) => eprintln!(
                        "cmux-cloud: a stream to {} was refused: {}",
                        command.args.last().map_or("?", String::as_str),
                        code.as_str()
                    ),
                }
            });
    }
}
