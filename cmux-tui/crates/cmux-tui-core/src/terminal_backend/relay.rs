//! The session-host relay of connector links: each open link gets one
//! owner-only local socket for the daemon's own clients (the Mac app opens
//! its daemon connection on it, as on a `cmux-tui remote connect` socket).
//! The bytes are the far session host's v12 protocol; nothing here parses
//! them. The path never goes to an app.
//!
//! One client per link: a v12 stream has per-connection state, so a second
//! client is refused while one is attached, and the link closes when that
//! client leaves (a reconnect is a new user run). Two threads move bytes and
//! wait on the registry's condition variable, never on a timer:
//! - app to client: bytes leave the link, go to the socket, and only then
//!   become credit for the app, so a slow client stops the far end;
//! - client to app: bytes from the socket become data frames within the
//!   app's credit.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::{Frame, LinkRegistry};

/// Sends one frame to the app that holds the link.
pub(crate) type Emit = Arc<dyn Fn(Frame) + Send + Sync>;
/// Called once when the link's client leaves; the host closes the link.
pub(crate) type ClientGone = Arc<dyn Fn(&str) + Send + Sync>;

/// Largest read from, or write to, a client at once.
const CHUNK: usize = 64 * 1024;
/// Longest socket path most platforms accept (`sun_path` is 104 on macOS).
const MAX_SOCKET_PATH: usize = 100;

struct Relay {
    path: PathBuf,
    stopped: Arc<AtomicBool>,
    client: Arc<Mutex<Option<UnixStream>>>,
}

/// The running relays, by channel.
#[derive(Default)]
pub(crate) struct RelaySet {
    relays: Mutex<HashMap<String, Relay>>,
}

impl RelaySet {
    /// Binds the socket of `channel` (in `dir`, or in a per-user temporary
    /// directory when that path is too long) and starts accepting. Answers
    /// the socket path.
    pub(crate) fn start(
        &self,
        dir: &Path,
        links: &Arc<LinkRegistry>,
        channel: &str,
        emit: Emit,
        gone: ClientGone,
    ) -> io::Result<PathBuf> {
        let name = format!("{}.sock", channel.trim_start_matches("link-"));
        let mut path = dir.join(&name);
        if path.as_os_str().len() > MAX_SOCKET_PATH {
            let uid = crate::platform::effective_uid();
            path = std::env::temp_dir().join(format!("cmux-tl-{uid}")).join(&name);
        }
        let parent = path.parent().expect("a socket path has a directory");
        prepare_dir(parent)?;
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let relay = Relay {
            path: path.clone(),
            stopped: Arc::new(AtomicBool::new(false)),
            client: Arc::new(Mutex::new(None)),
        };
        let accept = Accept {
            listener,
            links: links.clone(),
            channel: channel.to_owned(),
            stopped: relay.stopped.clone(),
            client: relay.client.clone(),
            emit,
            gone,
        };
        std::thread::Builder::new().name("cmux-link-accept".into()).spawn(move || accept.run())?;
        self.relays.lock().unwrap().insert(channel.to_owned(), relay);
        Ok(path)
    }

    /// Stops the relay of an ended link: no new client, the client's socket
    /// shuts down, the file goes. Never waits for the threads.
    pub(crate) fn stop(&self, channel: &str) {
        let Some(relay) = self.relays.lock().unwrap().remove(channel) else { return };
        relay.stopped.store(true, Ordering::SeqCst);
        if let Some(client) = relay.client.lock().unwrap().take() {
            let _ = client.shutdown(Shutdown::Both);
        }
        // Wakes the accept thread, which sees `stopped` and exits.
        let _ = UnixStream::connect(&relay.path);
        let _ = std::fs::remove_file(&relay.path);
    }

    /// The socket of an open link.
    pub(crate) fn socket(&self, channel: &str) -> Option<PathBuf> {
        self.relays.lock().unwrap().get(channel).map(|r| r.path.clone())
    }
}

/// A directory only this user can enter: created if missing, mode 0700,
/// owned by this user, and not a symbolic link.
fn prepare_dir(dir: &Path) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let meta = std::fs::symlink_metadata(dir)?;
    if !meta.is_dir() || meta.uid() != crate::platform::effective_uid() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a directory owned by this user", dir.display()),
        ));
    }
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

struct Accept {
    listener: UnixListener,
    links: Arc<LinkRegistry>,
    channel: String,
    stopped: Arc<AtomicBool>,
    client: Arc<Mutex<Option<UnixStream>>>,
    emit: Emit,
    gone: ClientGone,
}

impl Accept {
    fn run(self) {
        for stream in self.listener.incoming() {
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            let Ok(stream) = stream else { return };
            // Only this user's processes; anything else is dropped unread.
            let uid = crate::platform::effective_uid();
            if crate::platform::require_unix_peer_uid(&stream, uid).is_err() {
                continue;
            }
            let mut slot = self.client.lock().unwrap();
            if slot.is_some() {
                continue;
            }
            let (Ok(reader), Ok(writer)) = (stream.try_clone(), stream.try_clone()) else {
                continue;
            };
            *slot = Some(stream);
            drop(slot);
            self.serve(reader, writer);
        }
    }

    fn serve(&self, mut reader: UnixStream, mut writer: UnixStream) {
        let (links, channel, emit) = (self.links.clone(), self.channel.clone(), self.emit.clone());
        let _ = std::thread::Builder::new().name("cmux-link-out".into()).spawn(move || {
            while let Ok(bytes) = links.channels().wait_received(&channel, CHUNK) {
                if writer.write_all(&bytes).is_err() {
                    break;
                }
                match links.channels().consumed(&channel, bytes.len() as u64) {
                    Ok(Some(credit)) => emit(credit),
                    Ok(None) => {}
                    Err(_) => break,
                }
            }
            let _ = writer.shutdown(Shutdown::Both);
        });
        let (links, channel, emit) = (self.links.clone(), self.channel.clone(), self.emit.clone());
        let (stopped, gone) = (self.stopped.clone(), self.gone.clone());
        let _ = std::thread::Builder::new().name("cmux-link-in".into()).spawn(move || {
            let mut buf = vec![0u8; CHUNK];
            loop {
                let n = match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                if links.channels().send_all(&channel, &buf[..n], &*emit).is_err() {
                    break;
                }
            }
            if !stopped.load(Ordering::SeqCst) {
                gone(&channel);
            }
        });
    }
}
