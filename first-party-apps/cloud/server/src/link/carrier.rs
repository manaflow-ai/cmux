//! [`CarrierSpawner`]: the real link of one machine. It owns the machine's
//! local socket (the carrier the Mac client, ports and the browser proxy
//! dial) and carries each accepted connection over one connection to the
//! Mac app's carrier socket of that machine (super::dial is the only place
//! that knows that seam). It starts no process.
//!
//! Ready: the carrier reports `carrier-ready` as soon as it listens (the
//! readiness check before it is a `connect_info` read, super::info, and the
//! app's answer of its carrier socket, super::ops). Each stream is one
//! carrier dial inside the app's `cmux carrier serve`, with a fresh grant.
//! When the app's socket no longer accepts (its serve child ended: sign-out,
//! the session closed, the app quit) the stream reports `dial-failed`
//! `unreachable` and the supervisor ends the generation, so the next connect
//! asks the app for its socket again. A dial the app's carrier refuses
//! closes that connection having written nothing: the client sees end of
//! stream (the app shows the refusal).
//!
//! Events go to the supervisor only through [`LinkEvents`]: no timer, no
//! polling. Every stream this carrier opened is shut down on terminate, by
//! its own handle.

use super::argv::{LinkCommand, dial_failed_line, ready_line};
use super::dial::DialCode;
use super::spawner::{LinkEvents, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag};
use crate::app_env::private_dir;
use std::io::Write as _;
use std::os::unix::fs::MetadataExt as _;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// Streams at once per machine; more connections are closed at once (the
/// client sees end of stream and may retry). The app's serve has the same cap.
const MAX_STREAMS: usize = 64;

/// The real spawner: one carrier per link generation.
pub struct CarrierSpawner;

/// The upstream connections of one carrier (or of one file op), so
/// `terminate` (or a deadline) ends exactly them, by their own handles.
pub(crate) type Streams = Arc<Mutex<StreamSet>>;

/// Each open upstream connection's handle under the key it was given when
/// opened. A socket's (device, inode) is no key: macOS reports 0 for both on
/// every socket, so ending one stream would forget them all.
#[derive(Default)]
pub(crate) struct StreamSet {
    next: u64,
    open: std::collections::HashMap<u64, UnixStream>,
}

/// The key of one stream in its [`StreamSet`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct StreamKey(u64);

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Opens one connection to the app's carrier socket `upstream` and records
/// a handle of it in `streams`, so a terminate or a deadline can end it.
/// A socket that does not accept is [`DialCode::Unreachable`] with the
/// error's kind as its detail.
pub(crate) fn open_upstream(
    upstream: &Path,
    streams: &Streams,
) -> Result<(UnixStream, StreamKey), super::dial::Refusal> {
    let refused = |why: String| super::dial::Refusal {
        code: DialCode::Unreachable,
        detail: super::dial::clip_detail(&why),
    };
    if !upstream.is_absolute() {
        return Err(refused("the app's carrier socket is not an absolute path".into()));
    }
    let stream = UnixStream::connect(upstream).map_err(|e| {
        refused(format!("the cmux app's carrier socket did not accept ({:?})", e.kind()))
    })?;
    let handle = stream
        .try_clone()
        .map_err(|e| refused(format!("the carrier stream has no handle ({:?})", e.kind())))?;
    let mut set = lock(streams);
    set.next += 1;
    let key = StreamKey(set.next);
    set.open.insert(key.0, handle);
    Ok((stream, key))
}

/// Ends one upstream connection and forgets its handle (only its own).
pub(crate) fn end_stream(stream: &UnixStream, key: StreamKey, streams: &Streams) {
    let _ = stream.shutdown(std::net::Shutdown::Both);
    lock(streams).open.remove(&key.0);
}

/// Ends every upstream connection in `streams` (a terminate or a deadline).
pub(crate) fn end_all(streams: &Streams) {
    for (_, stream) in lock(streams).open.drain() {
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
}

/// Carries one local connection over one upstream connection; returns when
/// both sides end.
fn splice(connection: UnixStream, upstream: UnixStream, key: StreamKey, streams: &Streams) {
    let (Ok(mut upload_from), Ok(mut upload_to)) = (connection.try_clone(), upstream.try_clone())
    else {
        end_stream(&upstream, key, streams);
        return;
    };
    let upload = std::thread::Builder::new().name("cmux-link-up".into()).spawn(move || {
        let _ = pump(&mut upload_from, &mut upload_to);
        // The client is done writing: tell the app's carrier.
        let _ = upload_to.shutdown(std::net::Shutdown::Write);
    });
    let Ok(upload) = upload else {
        // No upload, no stream: the client sees end of stream, never a half-open one.
        end_stream(&upstream, key, streams);
        return;
    };
    let mut download_from = upstream;
    let mut download_to = connection;
    let _ = pump(&mut download_from, &mut download_to);
    let _ = download_to.flush();
    let _ = download_to.shutdown(std::net::Shutdown::Both);
    end_stream(&download_from, key, streams);
    let _ = upload.join();
}

/// Copies `from` to `to` until `from` ends, writing each read at once: a
/// plain read and write loop, so a short line (one `identify`) is never
/// held back. Returns the bytes copied, or the first error.
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
    streams: Streams,
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
        end_all(&self.streams);
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
        if !command.upstream.is_absolute() {
            return Err(std::io::Error::other("the app's carrier socket is not an absolute path"));
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
            streams: Arc::default(),
        };
        let streams = Arc::clone(&carrier.streams);
        let command = command.clone();
        std::thread::Builder::new().name(format!("cmux-link-{}", tag.machine)).spawn(
            move || {
                run(&tag, &command, &listener, &stop, &streams, &events);
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

/// The carrier's life: ready as soon as it listens, then one upstream
/// connection per accepted connection until `stop`. An accept error ends
/// the carrier (the link goes down; the next connect opens a new one)
/// instead of spinning.
fn run(
    tag: &LinkTag,
    command: &LinkCommand,
    listener: &UnixListener,
    stop: &Arc<AtomicBool>,
    streams: &Streams,
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
        let upstream = command.upstream.clone();
        let streams = Arc::clone(streams);
        let events = events.clone();
        let tag = tag.clone();
        let stop = Arc::clone(stop);
        let _ = std::thread::Builder::new().name("cmux-link-stream".into()).spawn(move || {
            let _slot = slot;
            match open_upstream(&upstream, &streams) {
                // A terminate that came while the stream opened: never serve it.
                Ok((stream, key)) if stop.load(Ordering::SeqCst) => {
                    end_stream(&stream, key, &streams);
                }
                Ok((stream, key)) => splice(connection, stream, key, &streams),
                // The app's carrier is gone: the generation ends, typed, and
                // the next connect asks the app again. The client sees end
                // of stream.
                Err(refusal) => {
                    let line = dial_failed_line(&refusal.code, refusal.detail.as_deref());
                    let _ = events.send(LinkProcessEvent::Line { tag, line });
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::link::{LinkState, LinkSupervisor};
    use std::io::{BufRead as _, BufReader};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    fn root(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("cc-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("this test's folder");
        root
    }

    #[test]
    fn a_stream_is_spliced_to_the_apps_carrier_socket() {
        let root = root("splice");
        // The app's `carrier serve`: echoes each line it gets.
        let upstream = root.join("serve.sock");
        let serve = UnixListener::bind(&upstream).expect("the fake serve listens");
        std::thread::spawn(move || {
            for connection in serve.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut writer = connection.try_clone().expect("clone");
                    for line in BufReader::new(connection).lines().map_while(Result::ok) {
                        let _ = writeln!(writer, "echo {line}");
                    }
                });
            }
        });
        let command = LinkCommand {
            upstream,
            state_dir: root.join("state"),
            local_socket: root.join("carrier.sock"),
        };
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let carrier = supervisor.spawn_and_wait("vm-test", &command).expect("carrier listens");
        let mut stream = UnixStream::connect(&carrier.socket).expect("a carrier stream");
        stream.set_read_timeout(Some(Duration::from_secs(5))).expect("bounded read");
        writeln!(stream, "{{\"cmd\":\"identify\",\"id\":1}}").expect("write");
        let mut answer = String::new();
        BufReader::new(stream.try_clone().expect("clone"))
            .read_line(&mut answer)
            .expect("the app's carrier answers");
        assert_eq!(answer, "echo {\"cmd\":\"identify\",\"id\":1}\n");
        supervisor.disconnect("vm-test");
        std::fs::remove_dir_all(root).expect("remove this test's private files");
    }

    #[test]
    fn a_gone_app_socket_ends_the_ready_generation_and_can_be_retried() {
        let root = root("gone");
        let command = LinkCommand {
            // Nothing listens here: the app's serve child ended.
            upstream: root.join("serve.sock"),
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
        // no sleep or poll is needed to observe the refused stream.
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
                if reason.contains("unreachable") && reason.contains("did not accept")
        ));
        assert!(supervisor.carrier("vm-test").is_none(), "a refused stream is not a ready link");
        drop(connection);
        let retry = supervisor.spawn_and_wait("vm-test", &command).expect("retry is allowed");
        assert_ne!(retry.generation, carrier.generation);
        supervisor.disconnect("vm-test");
        std::fs::remove_dir_all(root).expect("remove this test's private files");
    }

    #[test]
    fn a_terminate_ends_the_streams_it_opened() {
        let root = root("terminate");
        let upstream = root.join("serve.sock");
        let serve = UnixListener::bind(&upstream).expect("the fake serve listens");
        let (accepted, held) = channel();
        std::thread::spawn(move || {
            for connection in serve.incoming().flatten() {
                let _ = accepted.send(connection);
            }
        });
        let command = LinkCommand {
            upstream,
            state_dir: root.join("state"),
            local_socket: root.join("carrier.sock"),
        };
        let mut supervisor = LinkSupervisor::new(Box::new(CarrierSpawner));
        let carrier = supervisor.spawn_and_wait("vm-test", &command).expect("carrier listens");
        let _client = UnixStream::connect(&carrier.socket).expect("a carrier stream");
        let mut app_side = held.recv_timeout(Duration::from_secs(5)).expect("the app accepted");
        app_side.set_read_timeout(Some(Duration::from_secs(5))).expect("bounded read");
        supervisor.disconnect("vm-test");
        let mut byte = [0u8; 1];
        let read = std::io::Read::read(&mut app_side, &mut byte);
        assert!(matches!(read, Ok(0)), "the app's side sees end of stream: {read:?}");
        std::fs::remove_dir_all(root).expect("remove this test's private files");
    }

    /// Ending one stream forgets only its own handle, whatever the sockets'
    /// (device, inode) say (macOS reports 0 for both on every socket), so a
    /// terminate still ends every other stream.
    #[test]
    fn ending_one_stream_keeps_the_others_for_a_terminate() {
        let root = root("keys");
        let upstream = root.join("serve.sock");
        let serve = UnixListener::bind(&upstream).expect("the fake serve listens");
        let streams: Streams = Arc::default();
        let (first, first_key) = open_upstream(&upstream, &streams).expect("first");
        let (_second, _) = open_upstream(&upstream, &streams).expect("second");
        let (_, _) = serve.accept().expect("first accepted");
        let (mut second_app_side, _) = serve.accept().expect("second accepted");
        end_stream(&first, first_key, &streams);
        assert_eq!(lock(&streams).open.len(), 1, "only the ended stream is forgotten");
        end_all(&streams);
        second_app_side.set_read_timeout(Some(Duration::from_secs(5))).expect("timeout");
        let mut byte = [0u8; 1];
        let read = std::io::Read::read(&mut second_app_side, &mut byte);
        assert!(matches!(read, Ok(0)), "the other stream ended with the terminate: {read:?}");
        std::fs::remove_dir_all(root).expect("remove this test's private files");
    }
}
