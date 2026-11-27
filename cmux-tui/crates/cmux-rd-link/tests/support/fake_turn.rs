//! An in-process TURN server on loopback: Allocate with long-term
//! credentials (401, optional 438 once), Refresh with lifetimes it enforces,
//! CreatePermission, ChannelBind, ChannelData, Send and Data indications.
//! Or, in hostile mode, a server that answers every request with garbage.

#![allow(dead_code)]

use super::stun::*;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::os::fd::AsRawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub const REALM_NAME: &str = "cmux.test";

#[derive(Clone)]
pub struct Options {
    pub username: &'static str,
    pub password: &'static str,
    pub lifetime_s: u32,
    /// Answer the first authenticated request with 438 and a new nonce.
    pub stale_nonce_once: bool,
    pub hostile: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            username: "alice",
            password: "correct horse",
            lifetime_s: 600,
            stale_nonce_once: false,
            hostile: false,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct Stats {
    pub allocations: u32,
    pub refreshes: u32,
    pub stale_sent: u32,
    pub unauthorized: u32,
    pub permissions: u32,
    pub channel_binds: u32,
    pub channel_data_from_clients: u32,
    pub channel_data_to_clients: u32,
    pub send_indications: u32,
    pub data_indications: u32,
    pub expired: u32,
    pub hostile_sent: u32,
}

struct Allocation {
    relay: UdpSocket,
    perms: HashSet<IpAddr>,
    channels: HashMap<u16, SocketAddr>,
    expires: Instant,
}

pub struct FakeTurn {
    pub addr: SocketAddr,
    stop: Arc<AtomicBool>,
    stats: Arc<Mutex<Stats>>,
    thread: Option<thread::JoinHandle<()>>,
}

impl FakeTurn {
    pub fn start(options: Options) -> Self {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        let addr = socket.local_addr().unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stats = Arc::new(Mutex::new(Stats::default()));
        let mut server = Server {
            socket,
            options,
            nonce: "nonce-1".into(),
            stale_done: false,
            allocations: HashMap::new(),
            stats: stats.clone(),
            rng: Rng(0x9E37_79B9_7F4A_7C15),
        };
        let flag = stop.clone();
        let thread = thread::spawn(move || server.run(&flag));
        Self { addr, stop, stats, thread: Some(thread) }
    }

    pub fn stats(&self) -> Stats {
        self.stats.lock().unwrap().clone()
    }
}

impl Drop for FakeTurn {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            t.join().unwrap();
        }
    }
}

struct Server {
    socket: UdpSocket,
    options: Options,
    nonce: String,
    stale_done: bool,
    allocations: HashMap<SocketAddr, Allocation>,
    stats: Arc<Mutex<Stats>>,
    rng: Rng,
}

impl Server {
    fn run(&mut self, stop: &AtomicBool) {
        let mut buf = vec![0u8; 65_535];
        while !stop.load(Ordering::SeqCst) {
            let mut fds = vec![libc::pollfd {
                fd: self.socket.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            }];
            for a in self.allocations.values() {
                fds.push(libc::pollfd {
                    fd: a.relay.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                });
            }
            // SAFETY: fds is a valid array of pollfd for its length.
            unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, 20) };
            while let Ok((n, from)) = self.socket.recv_from(&mut buf) {
                if self.options.hostile {
                    self.hostile(&buf[..n], from);
                } else {
                    self.on_client_packet(&buf[..n], from);
                }
            }
            let clients: Vec<SocketAddr> = self.allocations.keys().copied().collect();
            for client in clients {
                while let Some(a) = self.allocations.get(&client) {
                    let Ok((n, peer)) = a.relay.recv_from(&mut buf) else { break };
                    self.on_peer_packet(client, peer, &buf[..n]);
                }
            }
            let now = Instant::now();
            let before = self.allocations.len();
            self.allocations.retain(|_, a| a.expires > now);
            let gone = (before - self.allocations.len()) as u32;
            self.stats.lock().unwrap().expired += gone;
        }
    }

    fn send(&self, packet: &[u8], to: SocketAddr) {
        let _ = self.socket.send_to(packet, to);
    }

    fn key(&self) -> [u8; 16] {
        key(self.options.username, REALM_NAME, self.options.password)
    }

    fn error(&self, msg: &Msg, code: u16, to: SocketAddr) {
        let attrs = [
            (ERROR_CODE, error_code(code, "error")),
            (REALM, REALM_NAME.as_bytes().to_vec()),
            (NONCE, self.nonce.as_bytes().to_vec()),
        ];
        self.send(&build(msg.kind | ERROR, msg.tx, &attrs, None), to);
    }

    /// Checks long-term credentials; answers 401 or 438 itself when they fail.
    fn authenticated(&mut self, msg: &Msg, raw: &[u8], from: SocketAddr) -> bool {
        let (Some(offset), Some(user), Some(_realm), Some(nonce)) =
            (msg.integrity, msg.get(USERNAME), msg.get(REALM), msg.get(NONCE))
        else {
            self.error(msg, 401, from);
            return false;
        };
        if user != self.options.username.as_bytes() || !integrity_ok(raw, offset, &self.key()) {
            self.stats.lock().unwrap().unauthorized += 1;
            self.error(msg, 401, from);
            return false;
        }
        if nonce != self.nonce.as_bytes() {
            self.error(msg, 438, from);
            return false;
        }
        if self.options.stale_nonce_once && !self.stale_done {
            self.stale_done = true;
            self.nonce = "nonce-2".into();
            self.stats.lock().unwrap().stale_sent += 1;
            self.error(msg, 438, from);
            return false;
        }
        true
    }

    fn success(&self, msg: &Msg, attrs: &[(u16, Vec<u8>)], to: SocketAddr) {
        self.send(&build(msg.kind | SUCCESS, msg.tx, attrs, Some(&self.key())), to);
    }

    fn on_client_packet(&mut self, raw: &[u8], from: SocketAddr) {
        if matches!(raw.first(), Some(0x40..=0x4F)) && raw.len() >= 4 {
            let number = u16::from_be_bytes([raw[0], raw[1]]);
            let len = usize::from(u16::from_be_bytes([raw[2], raw[3]]));
            let Some(a) = self.allocations.get(&from) else { return };
            if let (Some(peer), Some(data)) = (a.channels.get(&number), raw.get(4..4 + len)) {
                let _ = a.relay.send_to(data, *peer);
                self.stats.lock().unwrap().channel_data_from_clients += 1;
            }
            return;
        }
        let Some(msg) = parse(raw) else { return };
        if msg.kind == SEND_INDICATION {
            let Some(a) = self.allocations.get(&from) else { return };
            let peer = msg.get(XOR_PEER_ADDRESS).and_then(|v| unxor_addr(v, &msg.tx));
            if let (Some(peer), Some(data)) = (peer, msg.get(DATA))
                && a.perms.contains(&peer.ip())
            {
                let _ = a.relay.send_to(data, peer);
                self.stats.lock().unwrap().send_indications += 1;
            }
            return;
        }
        if !matches!(msg.kind, ALLOCATE | REFRESH | CREATE_PERMISSION | CHANNEL_BIND) {
            return;
        }
        if !self.authenticated(&msg, raw, from) {
            return;
        }
        let lifetime = Duration::from_secs(u64::from(self.options.lifetime_s));
        match msg.kind {
            ALLOCATE => {
                if let Entry::Vacant(slot) = self.allocations.entry(from) {
                    let relay = UdpSocket::bind("127.0.0.1:0").unwrap();
                    relay.set_nonblocking(true).unwrap();
                    slot.insert(Allocation {
                        relay,
                        perms: HashSet::new(),
                        channels: HashMap::new(),
                        expires: Instant::now() + lifetime,
                    });
                    self.stats.lock().unwrap().allocations += 1;
                }
                let relayed = self.allocations[&from].relay.local_addr().unwrap();
                let attrs = [
                    (XOR_RELAYED_ADDRESS, xor_addr(relayed, &msg.tx)),
                    (XOR_MAPPED_ADDRESS, xor_addr(from, &msg.tx)),
                    (LIFETIME, self.options.lifetime_s.to_be_bytes().to_vec()),
                ];
                self.success(&msg, &attrs, from);
            }
            REFRESH => {
                let asked = msg
                    .get(LIFETIME)
                    .and_then(|v| <[u8; 4]>::try_from(v).ok())
                    .map(u32::from_be_bytes)
                    .unwrap_or(600);
                let Some(a) = self.allocations.get_mut(&from) else {
                    return self.error(&msg, 437, from);
                };
                let granted = if asked == 0 { 0 } else { self.options.lifetime_s };
                a.expires = Instant::now() + Duration::from_secs(u64::from(granted));
                self.stats.lock().unwrap().refreshes += 1;
                self.success(&msg, &[(LIFETIME, granted.to_be_bytes().to_vec())], from);
            }
            CREATE_PERMISSION => {
                let peer = msg.get(XOR_PEER_ADDRESS).and_then(|v| unxor_addr(v, &msg.tx));
                let (Some(a), Some(peer)) = (self.allocations.get_mut(&from), peer) else {
                    return self.error(&msg, 400, from);
                };
                a.perms.insert(peer.ip());
                self.stats.lock().unwrap().permissions += 1;
                self.success(&msg, &[], from);
            }
            CHANNEL_BIND => {
                let peer = msg.get(XOR_PEER_ADDRESS).and_then(|v| unxor_addr(v, &msg.tx));
                let number = msg.get(CHANNEL_NUMBER).map(|v| u16::from_be_bytes([v[0], v[1]]));
                let (Some(a), Some(peer), Some(number)) =
                    (self.allocations.get_mut(&from), peer, number)
                else {
                    return self.error(&msg, 400, from);
                };
                if !(0x4000..=0x4FFF).contains(&number) {
                    return self.error(&msg, 400, from);
                }
                a.channels.insert(number, peer);
                a.perms.insert(peer.ip());
                self.stats.lock().unwrap().channel_binds += 1;
                self.success(&msg, &[], from);
            }
            _ => {}
        }
    }

    fn on_peer_packet(&mut self, client: SocketAddr, peer: SocketAddr, data: &[u8]) {
        let Some(a) = self.allocations.get(&client) else { return };
        if !a.perms.contains(&peer.ip()) {
            return;
        }
        if let Some((number, _)) = a.channels.iter().find(|(_, p)| **p == peer) {
            self.send(&channel_data(*number, data), client);
            self.stats.lock().unwrap().channel_data_to_clients += 1;
        } else {
            let tx = [7u8; 12];
            let attrs = [(XOR_PEER_ADDRESS, xor_addr(peer, &tx)), (DATA, data.to_vec())];
            self.send(&build(DATA_INDICATION, tx, &attrs, None), client);
            self.stats.lock().unwrap().data_indications += 1;
        }
    }

    /// Hostile: answer each request with mutated 401s, successes, Data
    /// indications and ChannelData, and never a real answer.
    fn hostile(&mut self, raw: &[u8], from: SocketAddr) {
        let Some(msg) = parse(raw) else { return };
        let k = self.key();
        let bases = [
            build(
                msg.kind | ERROR,
                msg.tx,
                &[
                    (ERROR_CODE, error_code(401, "x")),
                    (REALM, REALM_NAME.as_bytes().to_vec()),
                    (NONCE, b"n".to_vec()),
                ],
                None,
            ),
            build(
                msg.kind | SUCCESS,
                msg.tx,
                &[
                    (XOR_RELAYED_ADDRESS, xor_addr("127.0.0.1:9".parse().unwrap(), &msg.tx)),
                    (LIFETIME, 1u32.to_be_bytes().to_vec()),
                ],
                Some(&k),
            ),
            build(
                DATA_INDICATION,
                msg.tx,
                &[
                    (XOR_PEER_ADDRESS, xor_addr("127.0.0.1:9".parse().unwrap(), &msg.tx)),
                    (DATA, vec![0xD3; 40]),
                ],
                None,
            ),
            channel_data(0x4000, &[0xD3; 40]),
        ];
        for _ in 0..200 {
            let base = &bases[self.rng.below(bases.len())];
            let packet = self.rng.mutate(base);
            self.send(&packet, from);
        }
        self.stats.lock().unwrap().hostile_sent += 200;
    }
}
