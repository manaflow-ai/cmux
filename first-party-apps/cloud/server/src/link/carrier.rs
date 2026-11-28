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
//! supervisor ends the generation; other refusals end only that stream.
//!
//! Events go to the supervisor only through [`LinkEvents`]: no timer, no
//! polling. Every child is started by this carrier and only those children
//! are ended by it (by their own handles, never by name or pattern).

use super::argv::{LinkCommand, dial_failed_line, ready_line};
use super::dial::{DialCode, DialReply, MAX_REPLY_BYTES, parse_reply};
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
) -> Result<Dialed, DialCode> {
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
    let pipes = (child.stdin.take(), child.stdout.take(), child.stderr.take());
    let child = Arc::new(Mutex::new(child));
    lock(children).push(Arc::clone(&child));
    let (Some(stdin), Some(stdout), Some(stderr)) = pipes else {
        end_child(&child, children);
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
        DialReply::Connected { .. } => Ok(Dialed { child, stdin, stdout }),
        DialReply::Refused(code) => {
            end_child(&child, children);
            Err(code)
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
/// ended, or it is paused (the next connect starts it). Other refusals
/// (no path now, the link not running) end only that stream.
fn ends_generation(code: &DialCode) -> bool {
    matches!(code, DialCode::UnknownHost | DialCode::NotAuthorized | DialCode::HostPaused)
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
                // or finds the machine paused goes to the supervisor, typed.
                Err(code) if ends_generation(&code) => {
                    let line = dial_failed_line(&code);
                    let _ = events.send(LinkProcessEvent::Line { tag, line });
                }
                Err(code) => eprintln!(
                    "cmux-cloud: a stream to {} was refused: {}",
                    tag.machine,
                    code.as_str()
                ),
            }
        });
    }
}
