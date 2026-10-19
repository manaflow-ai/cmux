//! `tailnet.forward`: a local listener that carries each accepted connection
//! over the tailnet to one `host:port` (Node::dial_tcp). The app's viewer
//! points its signaling WebSocket and libwebrtc's TURN-over-TCP at it.
//!
//! Local trust: the default endpoint is a Unix socket, mode 0600, in a 0700
//! folder of this user's runtime directory, so only this user's processes
//! can connect. The `tcp` endpoint (127.0.0.1, for a client that cannot dial
//! a Unix socket, such as libwebrtc's TURN) is open to every local process
//! of every user that can reach loopback; each of them then reaches the
//! target as this node, the same exposure a system Tailscale gives every
//! local process. Only the frontend actor opens one, and it closes with the
//! connection that opened it.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use serde_json::{Map, Value, json};

use super::owner::{failed, owner};
use crate::resource::{ResourceError, ResourceOperation};

const OPERATION: ResourceOperation = ResourceOperation::TailnetForward;
const MAX_PER_CLIENT: usize = 8;
const MAX_TOTAL: usize = 32;
/// Open tunnels per forward (each holds two threads and a tailnet stream).
const MAX_CONNECTIONS: usize = 64;
const THREAD_STACK_BYTES: usize = 256 * 1024;

/// One open forward: its listener's wake address and its socket file.
struct Forward {
    client: u64,
    closed: Arc<AtomicBool>,
    endpoint: Endpoint,
}

#[derive(Clone)]
enum Endpoint {
    Unix(PathBuf),
    Tcp(std::net::SocketAddr),
}

fn forwards() -> &'static Mutex<HashMap<String, Forward>> {
    static FORWARDS: OnceLock<Mutex<HashMap<String, Forward>>> = OnceLock::new();
    FORWARDS.get_or_init(Mutex::default)
}

pub(super) fn open(client: u64, fields: &Map<String, Value>) -> Result<Value, ResourceError> {
    let target = fields.get("target").and_then(Value::as_str).unwrap_or_default();
    validate_target(target)?;
    let tcp = fields.get("transport").and_then(Value::as_str) == Some("tcp");
    let owner = owner();
    let node = owner.node().filter(|_| owner.current().0.running()).ok_or_else(|| {
        failed(OPERATION, "not_running", "the tailnet node is not running; sign in first".into())
    })?;
    {
        let all = forwards().lock().unwrap_or_else(PoisonError::into_inner);
        if all.len() >= MAX_TOTAL
            || all.values().filter(|forward| forward.client == client).count() >= MAX_PER_CLIENT
        {
            return Err(failed(OPERATION, "limit", "too many open tailnet forwards".into()));
        }
    }
    let id = random_id().map_err(|error| failed(OPERATION, "internal", error))?;
    let closed = Arc::new(AtomicBool::new(false));
    let io = |error: std::io::Error| failed(OPERATION, "listen_failed", error.to_string());
    let (endpoint, listener) = if tcp {
        let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(io)?;
        (Endpoint::Tcp(listener.local_addr().map_err(io)?), Listener::Tcp(listener))
    } else {
        let folder = crate::platform::runtime_dir().join("tailnet");
        std::fs::create_dir_all(&folder).map_err(io)?;
        crate::platform::restrict_directory(&folder).map_err(io)?;
        let path = folder.join(format!("{id}.sock"));
        let listener = UnixListener::bind(&path).map_err(io)?;
        crate::platform::restrict_file(&path).map_err(io)?;
        (Endpoint::Unix(path), Listener::Unix(listener))
    };
    let thread_closed = closed.clone();
    let thread_target = target.to_owned();
    let spawned = std::thread::Builder::new()
        .name("tailnet-forward".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || serve(listener, &node, &thread_target, &thread_closed));
    if let Err(error) = spawned {
        remove_file(&endpoint);
        return Err(failed(OPERATION, "internal", error.to_string()));
    }
    let answer = json!({"forward_id": id, "target": target, "endpoint": endpoint_json(&endpoint)});
    forwards()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(id, Forward { client, closed, endpoint });
    Ok(answer)
}

/// Closes every forward of `client` (its connection ended).
pub(super) fn disconnect(client: u64) {
    let gone: Vec<Forward> = {
        let mut all = forwards().lock().unwrap_or_else(PoisonError::into_inner);
        let ids: Vec<String> = all
            .iter()
            .filter(|(_, forward)| forward.client == client)
            .map(|(id, _)| id.clone())
            .collect();
        ids.iter().filter_map(|id| all.remove(id)).collect()
    };
    for forward in gone {
        forward.closed.store(true, Ordering::Release);
        // Wakes the blocked accept: it sees `closed` and returns.
        match &forward.endpoint {
            Endpoint::Unix(path) => drop(UnixStream::connect(path)),
            Endpoint::Tcp(addr) => drop(TcpStream::connect(addr)),
        }
        remove_file(&forward.endpoint);
    }
}

enum Listener {
    Unix(UnixListener),
    Tcp(TcpListener),
}

/// Accepts until the forward closes; each connection gets its own tunnel.
fn serve(listener: Listener, node: &Arc<cmux_tailnet::Node>, target: &str, closed: &AtomicBool) {
    let open = Arc::new(AtomicUsize::new(0));
    loop {
        let local: Box<dyn Duplex> = match &listener {
            Listener::Unix(listener) => match listener.accept() {
                Ok((stream, _)) => Box::new(stream),
                Err(_) => break,
            },
            Listener::Tcp(listener) => match listener.accept() {
                Ok((stream, _)) => Box::new(stream),
                Err(_) => break,
            },
        };
        if closed.load(Ordering::Acquire) {
            break;
        }
        if open.load(Ordering::Acquire) >= MAX_CONNECTIONS {
            continue;
        }
        open.fetch_add(1, Ordering::AcqRel);
        let (node, target, open_count) = (node.clone(), target.to_owned(), open.clone());
        let spawned = std::thread::Builder::new()
            .name("tailnet-tunnel".into())
            .stack_size(THREAD_STACK_BYTES)
            .spawn(move || {
                // A dial failure just closes the local connection; the
                // client sees EOF. The target is not logged (it names a peer).
                if let Ok(remote) = node.dial_tcp(&target) {
                    tunnel(local, remote);
                }
                open_count.fetch_sub(1, Ordering::AcqRel);
            });
        if spawned.is_err() {
            open.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

trait Duplex: Read + Write + Send {
    fn split(&self) -> std::io::Result<Box<dyn Duplex>>;
    fn close_write(&self);
}

impl Duplex for UnixStream {
    fn split(&self) -> std::io::Result<Box<dyn Duplex>> {
        Ok(Box::new(self.try_clone()?))
    }
    fn close_write(&self) {
        let _ = self.shutdown(Shutdown::Write);
    }
}

impl Duplex for TcpStream {
    fn split(&self) -> std::io::Result<Box<dyn Duplex>> {
        Ok(Box::new(self.try_clone()?))
    }
    fn close_write(&self) {
        let _ = self.shutdown(Shutdown::Write);
    }
}

/// Copies both ways until both sides finish; a side that ends half-closes
/// the other.
fn tunnel(local: Box<dyn Duplex>, remote: UnixStream) {
    let (Ok(local_reader), Ok(remote_writer)) = (local.split(), remote.try_clone()) else { return };
    let upstream = std::thread::Builder::new()
        .name("tailnet-tunnel-up".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let (mut reader, mut writer) = (local_reader, remote_writer);
            let _ = std::io::copy(&mut reader, &mut writer);
            let _ = writer.shutdown(Shutdown::Write);
        });
    let (mut reader, mut writer) = (remote, local);
    let _ = std::io::copy(&mut reader, &mut writer);
    writer.close_write();
    if let Ok(upstream) = upstream {
        let _ = upstream.join();
    }
}

/// `host:port`: a MagicDNS name, a tailnet host name or an IP literal
/// (`[v6]:port` for IPv6), port 1-65535. No scheme, path or whitespace.
fn validate_target(target: &str) -> Result<(), ResourceError> {
    let invalid = || {
        ResourceError::validation_invalid(
            Some("target"),
            "target must be host:port (a tailnet name or address, port 1-65535)",
        )
    };
    let (host, port) = target.rsplit_once(':').ok_or_else(invalid)?;
    let port: u16 = port.parse().map_err(|_| invalid())?;
    let host = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
    let name = host.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            && !label.starts_with('-')
    });
    let ip = host.parse::<std::net::IpAddr>().is_ok();
    if port == 0 || host.len() > 253 || !(name || ip) {
        return Err(invalid());
    }
    Ok(())
}

fn endpoint_json(endpoint: &Endpoint) -> Value {
    match endpoint {
        Endpoint::Unix(path) => json!({"transport": "unix", "path": path.to_string_lossy()}),
        Endpoint::Tcp(addr) => {
            json!({"transport": "tcp", "host": addr.ip().to_string(), "port": addr.port()})
        }
    }
}

fn remove_file(endpoint: &Endpoint) {
    if let Endpoint::Unix(path) = endpoint {
        let _ = std::fs::remove_file(path);
    }
}

fn random_id() -> Result<String, String> {
    let mut bytes = [0_u8; 8];
    getrandom::fill(&mut bytes).map_err(|error| error.to_string())?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
