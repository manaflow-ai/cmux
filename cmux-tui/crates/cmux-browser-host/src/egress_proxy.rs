//! The isolated host's egress listener (crate::egress_scope): a SOCKS5
//! CONNECT-only listener on 127.0.0.1 that every Chromium of the host uses.
//! Per connection it resolves the target once (crate::egress_scope::
//! EgressRule::resolve), refuses it if any address is in a refused range,
//! and dials only the addresses it checked; then it copies bytes both ways.
//!
//! No authentication: the listener only narrows what a local process could
//! reach directly, so a process other than Chromium that uses it gains
//! nothing. BIND and UDP ASSOCIATE are refused (no inbound sockets, no UDP).

use crate::egress_scope::{EgressRule, Refusal, Target};
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::Duration;

/// Connections served at once (each holds two sockets and two threads);
/// more are closed at accept.
/// Each holds four descriptors, so 128 stay far below a 1024 soft limit.
pub const MAX_CONNECTIONS: usize = 128;
/// How long a client may take to send its greeting and request.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// How long one dial may take.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// SOCKS5 reply codes (RFC 1928 section 6).
mod reply {
    pub const OK: u8 = 0x00;
    pub const FAILURE: u8 = 0x01;
    pub const NOT_ALLOWED: u8 = 0x02;
    pub const HOST_UNREACHABLE: u8 = 0x04;
    pub const REFUSED: u8 = 0x05;
    pub const COMMAND_UNSUPPORTED: u8 = 0x07;
    pub const ADDRESS_UNSUPPORTED: u8 = 0x08;
}

/// Starts the listener on 127.0.0.1 (a free port) and returns its address.
/// It serves for the life of the process.
pub fn start(rule: Arc<EgressRule>) -> io::Result<SocketAddr> {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    let addr = listener.local_addr()?;
    let live: Arc<Live> = Arc::default();
    std::thread::Builder::new().name("cmux-browser-host-egress".into()).spawn(move || {
        loop {
            let client = match listener.accept() {
                Ok((client, _)) => client,
                // Out of descriptors: wait until one of our connections
                // ends (signalled; bounded) instead of spinning on accept.
                Err(error) if matches!(error.raw_os_error(), Some(code) if code == EMFILE || code == ENFILE) => {
                    live.wait_for_end();
                    continue;
                }
                // A connection reset before accept drops that one only.
                Err(_) => continue,
            };
            if !live.enter() {
                continue;
            }
            let (rule, done) = (rule.clone(), live.clone());
            let spawned = std::thread::Builder::new()
                .name("cmux-browser-host-egress-conn".into())
                .spawn(move || {
                    let _ = serve(client, &rule);
                    done.leave();
                });
            if spawned.is_err() {
                live.leave();
            }
        }
    })?;
    Ok(addr)
}

const EMFILE: i32 = 24;
const ENFILE: i32 = 23;

/// Connections being served, and a signal when one ends.
#[derive(Default)]
struct Live {
    count: Mutex<usize>,
    ended: Condvar,
}

impl Live {
    /// Takes a slot; false when all [`MAX_CONNECTIONS`] are taken.
    fn enter(&self) -> bool {
        let mut count = self.count.lock().unwrap_or_else(PoisonError::into_inner);
        if *count >= MAX_CONNECTIONS {
            return false;
        }
        *count += 1;
        true
    }

    fn leave(&self) {
        let mut count = self.count.lock().unwrap_or_else(PoisonError::into_inner);
        *count = count.saturating_sub(1);
        self.ended.notify_all();
    }

    /// Waits for a connection to end (at most a second: descriptors may
    /// also free outside the listener).
    fn wait_for_end(&self) {
        let count = self.count.lock().unwrap_or_else(PoisonError::into_inner);
        let _ = self.ended.wait_timeout(count, Duration::from_secs(1));
    }
}

/// One client: handshake, rule, dial, copy.
fn serve(mut client: TcpStream, rule: &EgressRule) -> io::Result<()> {
    client.set_read_timeout(Some(HANDSHAKE_TIMEOUT))?;
    client.set_nodelay(true)?;
    let mut head = [0u8; 2];
    client.read_exact(&mut head)?;
    if head[0] != 5 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not SOCKS5"));
    }
    let mut methods = vec![0u8; head[1] as usize];
    client.read_exact(&mut methods)?;
    if !methods.contains(&0) {
        client.write_all(&[5, 0xff])?;
        return Ok(());
    }
    client.write_all(&[5, 0])?;
    let mut request = [0u8; 4];
    client.read_exact(&mut request)?;
    if request[0] != 5 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not SOCKS5"));
    }
    let target = match read_target(&mut client, request[3])? {
        Some(target) => target,
        None => return send_reply(&mut client, reply::ADDRESS_UNSUPPORTED),
    };
    if request[1] != 1 {
        return send_reply(&mut client, reply::COMMAND_UNSUPPORTED);
    }
    let addrs = match rule.resolve(&target) {
        Ok(addrs) => addrs,
        Err(Refusal::Blocked(_)) => return send_reply(&mut client, reply::NOT_ALLOWED),
        Err(Refusal::Unresolved(_)) => return send_reply(&mut client, reply::HOST_UNREACHABLE),
    };
    let upstream = match dial(&addrs) {
        Ok(upstream) => upstream,
        Err(error) => {
            let code = match error.kind() {
                io::ErrorKind::ConnectionRefused => reply::REFUSED,
                io::ErrorKind::TimedOut => reply::HOST_UNREACHABLE,
                _ => reply::FAILURE,
            };
            return send_reply(&mut client, code);
        }
    };
    send_reply(&mut client, reply::OK)?;
    client.set_read_timeout(None)?;
    let _ = upstream.set_nodelay(true);
    // A dead peer ends the connection instead of holding its slot forever.
    keepalive(&client);
    keepalive(&upstream);
    copy_both_ways(client, upstream)
}

/// The request's DST.ADDR and DST.PORT; `None` for an unknown address type.
fn read_target(client: &mut TcpStream, kind: u8) -> io::Result<Option<Target>> {
    let target = match kind {
        1 => {
            let mut ip = [0u8; 4];
            client.read_exact(&mut ip)?;
            Target::Address(SocketAddr::from((Ipv4Addr::from(ip), read_port(client)?)))
        }
        3 => {
            let mut len = [0u8; 1];
            client.read_exact(&mut len)?;
            let mut name = vec![0u8; len[0] as usize];
            client.read_exact(&mut name)?;
            let name = String::from_utf8(name)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "name is not UTF-8"))?;
            Target::Name(name, read_port(client)?)
        }
        4 => {
            let mut ip = [0u8; 16];
            client.read_exact(&mut ip)?;
            Target::Address(SocketAddr::from((Ipv6Addr::from(ip), read_port(client)?)))
        }
        _ => return Ok(None),
    };
    Ok(Some(target))
}

fn read_port(client: &mut TcpStream) -> io::Result<u16> {
    let mut port = [0u8; 2];
    client.read_exact(&mut port)?;
    Ok(u16::from_be_bytes(port))
}

/// A reply with an unspecified bound address (the client never uses it).
fn send_reply(client: &mut TcpStream, code: u8) -> io::Result<()> {
    client.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0])
}

/// The first checked address that answers.
fn dial(addrs: &[SocketAddr]) -> io::Result<TcpStream> {
    let mut last = io::Error::new(io::ErrorKind::NotFound, "no address");
    for addr in addrs {
        match TcpStream::connect_timeout(addr, CONNECT_TIMEOUT) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = error,
        }
    }
    Err(last)
}

/// Copies client to upstream on a second thread and upstream to client
/// here. EOF on one side half-closes the other; an error closes both, so
/// the other copy ends too.
fn copy_both_ways(client: TcpStream, upstream: TcpStream) -> io::Result<()> {
    let (mut client_in, mut upstream_out) = (client.try_clone()?, upstream.try_clone()?);
    let up = std::thread::Builder::new().name("cmux-browser-host-egress-up".into()).spawn(
        move || match io::copy(&mut client_in, &mut upstream_out) {
            Ok(_) => {
                let _ = upstream_out.shutdown(Shutdown::Write);
            }
            Err(_) => {
                let _ = upstream_out.shutdown(Shutdown::Both);
                let _ = client_in.shutdown(Shutdown::Both);
            }
        },
    )?;
    let (mut upstream_in, mut client_out) = (upstream, client);
    match io::copy(&mut upstream_in, &mut client_out) {
        Ok(_) => {
            let _ = client_out.shutdown(Shutdown::Write);
        }
        Err(_) => {
            let _ = client_out.shutdown(Shutdown::Both);
            let _ = upstream_in.shutdown(Shutdown::Both);
        }
    }
    let _ = up.join();
    Ok(())
}

/// TCP keepalive: first probe after 60 s idle, then every 20 s, 3 probes.
#[cfg(target_os = "linux")]
fn keepalive(stream: &TcpStream) {
    use std::os::fd::AsRawFd;
    let fd = stream.as_raw_fd();
    for (level, name, value) in [
        (libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1),
        (libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 60),
        (libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 20),
        (libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3),
    ] {
        let value: libc::c_int = value;
        // SAFETY: fd is a live socket owned by `stream`; value outlives the call.
        unsafe {
            libc::setsockopt(
                fd,
                level,
                name,
                (&raw const value).cast(),
                size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn keepalive(_stream: &TcpStream) {}
