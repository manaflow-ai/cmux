//! [`Listener`]: one TCP listener on 127.0.0.1 and a random port, with one
//! thread per accepted connection. Port forwards and browser proxy routes
//! use it. It binds the IPv4 loopback address only, never a wildcard.
//!
//! The op loop owns every `Listener` (single writer of forward state). The
//! threads only pump bytes; [`Listener::close`] ends them all: it stops the
//! accept loop and shuts down every open connection and its tunnel stream,
//! so no byte waits anywhere for a later link.

use super::tunnel::{TunnelAbort, TunnelConn};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

/// Open connections per listener; more are closed at once.
pub const MAX_CONNECTIONS: usize = 64;

/// What each accepted connection runs (on its own thread).
pub type Handler = Arc<dyn Fn(TcpStream, &Session) + Send + Sync>;

struct Open {
    tcp: TcpStream,
    abort: Option<Arc<dyn TunnelAbort>>,
}

/// The shared side of a listener: its closed flag and open connections.
#[derive(Clone)]
pub struct Session {
    closed: Arc<AtomicBool>,
    open: Arc<Mutex<Vec<(u64, Open)>>>,
    next: Arc<AtomicU64>,
}

impl Session {
    fn new() -> Self {
        Self {
            closed: Arc::new(AtomicBool::new(false)),
            open: Arc::new(Mutex::new(Vec::new())),
            next: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<(u64, Open)>> {
        self.open.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Registers a connection so `close` can end it. `None` when the
    /// listener is closed or full (the caller drops the connection).
    fn register(&self, tcp: &TcpStream) -> Option<u64> {
        let mut open = self.lock();
        if self.is_closed() || open.len() >= MAX_CONNECTIONS {
            return None;
        }
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        open.push((id, Open { tcp: tcp.try_clone().ok()?, abort: None }));
        Some(id)
    }

    /// Adds the tunnel stream of a registered connection. Aborts it at once
    /// when the listener closed meanwhile.
    fn attach_tunnel(&self, id: u64, abort: Arc<dyn TunnelAbort>) {
        let mut open = self.lock();
        if self.is_closed() {
            abort.abort();
            return;
        }
        if let Some((_, entry)) = open.iter_mut().find(|(i, _)| *i == id) {
            entry.abort = Some(abort);
        }
    }

    fn unregister(&self, id: u64) {
        self.lock().retain(|(i, _)| *i != id);
    }

    fn close_all(&self) {
        self.closed.store(true, Ordering::SeqCst);
        for (_, entry) in self.lock().drain(..) {
            let _ = entry.tcp.shutdown(Shutdown::Both);
            if let Some(abort) = entry.abort {
                abort.abort();
            }
        }
    }

    /// Pumps bytes both ways between `tcp` and `conn` until both directions
    /// end, after writing `first` (bytes already read from `tcp`) to the
    /// tunnel. Returns when the connection is done or the listener closed.
    pub fn splice(&self, tcp: TcpStream, conn: TunnelConn, first: Vec<u8>) {
        let Some(id) = self.register(&tcp) else {
            conn.abort.abort();
            return;
        };
        self.attach_tunnel(id, Arc::clone(&conn.abort));
        let TunnelConn { mut reader, mut writer, abort } = conn;
        let up_abort = Arc::clone(&abort);
        let up = tcp.try_clone().map(|mut from| {
            std::thread::spawn(move || {
                let done = writer.write_all(&first).and_then(|()| copy(&mut from, &mut writer));
                match done {
                    Ok(()) => {
                        let _ = writer.shutdown_write();
                    }
                    Err(_) => up_abort.abort(),
                }
            })
        });
        let mut to = tcp;
        match copy(&mut reader, &mut to) {
            Ok(()) => {
                let _ = to.shutdown(Shutdown::Write);
            }
            Err(_) => {
                let _ = to.shutdown(Shutdown::Both);
                abort.abort();
            }
        }
        match up {
            Ok(handle) => {
                let _ = handle.join();
            }
            Err(_) => abort.abort(),
        }
        self.unregister(id);
    }
}

fn copy(from: &mut dyn Read, to: &mut dyn Write) -> io::Result<()> {
    let mut buffer = [0u8; 16 * 1024];
    loop {
        let n = match from.read(&mut buffer) {
            Ok(0) => return to.flush(),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        to.write_all(&buffer[..n])?;
    }
}

/// A listener on 127.0.0.1 and a port the system picks.
pub struct Listener {
    addr: SocketAddr,
    session: Session,
    thread: Option<JoinHandle<()>>,
}

impl Listener {
    /// Binds 127.0.0.1:0 and starts the accept thread.
    pub fn bind(handler: Handler) -> io::Result<Self> {
        let socket = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        let addr = socket.local_addr()?;
        let session = Session::new();
        let shared = session.clone();
        let thread = std::thread::Builder::new()
            .name(format!("cmux-cloud-port-{}", addr.port()))
            .spawn(move || {
            for incoming in socket.incoming() {
                if shared.is_closed() {
                    break;
                }
                let Ok(tcp) = incoming else { continue };
                let handler = Arc::clone(&handler);
                let session = shared.clone();
                let spawned = std::thread::Builder::new()
                    .name("cmux-cloud-conn".into())
                    .spawn(move || handler(tcp, &session));
                // No thread: the connection is dropped (closed).
                drop(spawned);
            }
        })?;
        Ok(Self { addr, session, thread: Some(thread) })
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.addr
    }

    /// Stops accepting, ends every open connection and its tunnel stream,
    /// and waits for the accept thread. The port is free after this.
    pub fn close(&mut self) {
        self.session.close_all();
        if let Some(thread) = self.thread.take() {
            // Wake the blocked accept with one connection; it sees the flag.
            let _ = TcpStream::connect(self.addr);
            let _ = thread.join();
        }
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        self.close();
    }
}
