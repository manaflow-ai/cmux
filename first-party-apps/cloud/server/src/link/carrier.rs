//! [`CarrierSpawner`]: the real link of one machine. It owns the machine's
//! local socket (the carrier the Mac client, ports and the browser proxy
//! dial) and runs one `cmux link dial --host <host_…>` child per accepted
//! connection, splicing the connection to the child's stdin and stdout
//! (super::dial is the only place that knows that seam).
//!
//! Ready: the carrier reports `carrier-ready` as soon as it listens (the
//! readiness check before it is a `connect_info` read, super::info). Each
//! stream is one dial and one fresh link token inside `cmux link`
//! (contract 1.7); a refused stream reports `dial-failed` with the typed
//! code, and the supervisor ends the generation.
//!
//! Events go to the supervisor only through [`LinkEvents`]: no timer, no
//! polling. Every child is started by this carrier and only those children
//! are ended by it (by their own handles, never by name or pattern).

use super::argv::{LinkCommand, dial_failed_line, ready_line};
use super::dial::{DialCode, DialReply, MAX_REPLY_BYTES, parse_reply};
use super::spawner::{LinkEvents, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag};
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
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

/// A dial child after its `ok` reply line: stdin and stdout carry the
/// daemon stream.
pub(crate) struct DialStream {
    pub(crate) child: Child,
    pub(crate) stdin: ChildStdin,
    pub(crate) stdout: ChildStdout,
}

/// Starts `binary args` (one `cmux link dial`) with exactly `env` and
/// reads its reply line from stderr. The rest of its stderr goes to this
/// server's stderr (the host's log); the dial writes no credential there.
/// A refused or broken dial is ended before this returns.
pub(crate) fn open_dial(
    binary: &Path,
    args: &[String],
    env: &[(String, String)],
) -> Result<DialStream, DialCode> {
    if !binary.is_absolute() {
        return Err(DialCode::Unavailable("the link binary is not an absolute path".into()));
    }
    let mut process = Command::new(binary);
    process.args(args).env_clear();
    process.envs(env.iter().map(|(k, v)| (k, v)));
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
        DialReply::Connected { .. } => Ok(DialStream { child, stdin, stdout }),
        DialReply::Refused(code) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(code)
        }
    }
}

/// A dial child of this carrier after its reply line.
struct Dialed {
    child: Arc<Mutex<Child>>,
    stdin: ChildStdin,
    stdout: ChildStdout,
}

/// [`open_dial`] for one carrier stream; the child is kept so `terminate`
/// can end it.
fn dial(command: &LinkCommand, children: &Children) -> Result<Dialed, DialCode> {
    let DialStream { child, stdin, stdout } =
        open_dial(&command.binary, &command.args, &command.env)?;
    let child = Arc::new(Mutex::new(child));
    lock(children).push(Arc::clone(&child));
    Ok(Dialed { child, stdin, stdout })
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
    // Ready as soon as it listens: no probe dial (a dial mints a link
    // token, one per real connection). The first stream's reply is the
    // first word of the link; a refusal ends the generation, typed.
    let ready =
        LinkProcessEvent::Line { tag: tag.clone(), line: ready_line(&command.local_socket) };
    if events.send(ready).is_err() {
        return;
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
        let events = events.clone();
        let tag = tag.clone();
        let _ = std::thread::Builder::new().name("cmux-link-stream".into()).spawn(move || {
            match dial(&command, &children) {
                Ok(dialed) => splice(connection, dialed, &children),
                // The client sees end of stream; the supervisor gets the
                // typed refusal and ends this generation.
                Err(code) => {
                    let line = dial_failed_line(&code);
                    let _ = events.send(LinkProcessEvent::Line { tag, line });
                }
            }
        });
    }
}
