//! What woke the guest (goal cloud-autoscale-no-knobs, census never_used `resume_inbound_soon`):
//! Freestyle resumes a paused VM on any inbound packet, and the platform learns afterwards with no
//! way to tell who sent it. Since the durable pausing notice (cmux-platform#2468), most VMs woken
//! under 30 s after a pause woke with no person client told, so the packet is the platform's, a
//! relay's or a reply to the guest's own connection (a pooled HTTPS connection's FIN, a peer's
//! ping). Right at the resume, before any pooled connection is dropped, the role reads the kernel's
//! TCP table once: a socket the peer closed reads CLOSE_WAIT, a connect in progress reads SYN_RECV,
//! and data nobody read yet sits in its receive queue. Those sockets ride along in the wake block
//! (`sockets`) as state and ports only, never an address.

use serde_json::{Value, json};

/// At most this many sockets are kept per wake.
pub const WAKE_SOCKETS_MAX: usize = 16;

/// One socket that may have woken the guest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WakeSocket {
    /// `close_wait`, `syn_recv` or another state with unread data (`established`, ...).
    pub state: &'static str,
    pub local_port: u16,
    pub remote_port: u16,
    /// Bytes wait unread in its receive queue.
    pub unread: bool,
    /// Its local port is one this guest listens on: the peer dialed in.
    pub inbound: bool,
}

impl WakeSocket {
    pub fn to_json(&self) -> Value {
        json!({
            "state": self.state,
            "local_port": self.local_port,
            "remote_port": self.remote_port,
            "unread": self.unread,
            "inbound": self.inbound,
        })
    }
}

fn state_name(code: u8) -> &'static str {
    match code {
        0x01 => "established",
        0x02 => "syn_sent",
        0x03 => "syn_recv",
        0x04 => "fin_wait1",
        0x05 => "fin_wait2",
        0x06 => "time_wait",
        0x07 => "close",
        0x08 => "close_wait",
        0x09 => "last_ack",
        0x0A => "listen",
        0x0B => "closing",
        _ => "unknown",
    }
}

struct Row {
    state: u8,
    local_port: u16,
    remote_port: u16,
    rx: u64,
}

/// One `/proc/net/tcp{,6}` line: `sl local rem st tx:rx ...`; None for the header or a bad line.
fn row(line: &str) -> Option<Row> {
    let mut f = line.split_whitespace();
    let _sl = f.next()?.strip_suffix(':')?;
    let port = |addr: &str| u16::from_str_radix(addr.rsplit_once(':')?.1, 16).ok();
    let local_port = port(f.next()?)?;
    let remote_port = port(f.next()?)?;
    let state = u8::from_str_radix(f.next()?, 16).ok()?;
    let rx = u64::from_str_radix(f.next()?.split_once(':')?.1, 16).ok()?;
    Some(Row { state, local_port, remote_port, rx })
}

/// The sockets of `tables` (the text of `/proc/net/tcp` and `/proc/net/tcp6`) that may have woken
/// the guest: CLOSE_WAIT, SYN_RECV, or any non-listening socket with unread data. At most
/// WAKE_SOCKETS_MAX, CLOSE_WAIT and SYN_RECV first.
pub fn wake_sockets(tables: &[&str]) -> Vec<WakeSocket> {
    let rows: Vec<Row> = tables.iter().flat_map(|t| t.lines().filter_map(row)).collect();
    let listening: Vec<u16> =
        rows.iter().filter(|r| r.state == 0x0A).map(|r| r.local_port).collect();
    let mut out: Vec<WakeSocket> = rows
        .iter()
        .filter(|r| r.state != 0x0A && (r.state == 0x08 || r.state == 0x03 || r.rx > 0))
        .map(|r| WakeSocket {
            state: state_name(r.state),
            local_port: r.local_port,
            remote_port: r.remote_port,
            unread: r.rx > 0,
            inbound: listening.contains(&r.local_port),
        })
        .collect();
    out.sort_by_key(|s| match s.state {
        "close_wait" => 0,
        "syn_recv" => 1,
        _ => 2,
    });
    out.truncate(WAKE_SOCKETS_MAX);
    out
}

/// Reads this guest's TCP tables now (an empty list where they cannot be read).
pub fn read_wake_sockets() -> Value {
    let v4 = std::fs::read_to_string("/proc/net/tcp").unwrap_or_default();
    let v6 = std::fs::read_to_string("/proc/net/tcp6").unwrap_or_default();
    Value::Array(wake_sockets(&[&v4, &v6]).iter().map(WakeSocket::to_json).collect())
}
