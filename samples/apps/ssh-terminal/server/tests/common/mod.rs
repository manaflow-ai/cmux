//! Test harness: an in-process SSH server on 127.0.0.1 (russh server, never
//! a real sshd, never a real host), in-memory handles and keys made in the
//! test. Nothing here reads or writes ~/.ssh or a known_hosts file.
//!
//! The server runs a tiny shell: a line `echo X` answers `X\r\n`; a line
//! `exit N` sends exit status N and closes the channel. Every other line is
//! only recorded.

#![allow(dead_code)]

use russh::keys::ssh_key::Signature;
use russh::keys::{Algorithm, HashAlg, PrivateKey, PublicKey};
use russh::server::{self, Auth, ChannelOpenHandle, Msg, Session};
use russh::{Channel, ChannelId, Pty, Sig};
use ssh_terminal::handles::{
    ConnectionHandles, CredentialHandle, HostKeyDecision, HostKeyPolicy, SshConnection, SshTarget,
};
use ssh_terminal::iface::{BackendError, ByteEvent, ByteTerminal, Grid, OpenRequest};
use ssh_terminal::{SSH_KIND, SshBackend};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

pub const HANDLE: &str = "conn_test";
pub const USER: &str = "tester";
const WAIT: Duration = Duration::from_secs(10);
const TICK: Duration = Duration::from_millis(10);

pub fn random_key() -> PrivateKey {
    PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).expect("ed25519 key")
}

/// What the test server saw.
#[derive(Debug, Clone, Default)]
pub struct ServerLog {
    pub connections: usize,
    /// TCP connections that ended (the client closed or the relay died).
    pub closed_connections: usize,
    pub auth_attempts: usize,
    pub channels: usize,
    pub pty: Option<(u32, u32)>,
    pub windows: Vec<(u32, u32)>,
    pub input: Vec<u8>,
    pub signals: Vec<String>,
}

pub struct TestServer {
    pub addr: SocketAddr,
    pub host_key: PublicKey,
    log: Arc<Mutex<ServerLog>>,
    relays: Arc<Mutex<Vec<JoinHandle<()>>>>,
    runtime: Runtime,
}

impl TestServer {
    /// Starts a server that accepts only `client_key`.
    pub fn start(client_key: PublicKey) -> Self {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("server runtime");
        let host = random_key();
        let host_key = host.public_key().clone();
        let config = Arc::new(server::Config {
            keys: vec![host],
            auth_rejection_time: Duration::from_millis(1),
            auth_rejection_time_initial: Some(Duration::ZERO),
            ..Default::default()
        });
        let log = Arc::new(Mutex::new(ServerLog::default()));
        let relays = Arc::new(Mutex::new(Vec::new()));
        let listener =
            runtime.block_on(tokio::net::TcpListener::bind("127.0.0.1:0")).expect("bind 127.0.0.1");
        let addr = listener.local_addr().expect("addr");
        let (accept_log, accept_relays) = (log.clone(), relays.clone());
        runtime.spawn(async move {
            while let Ok((tcp, _)) = listener.accept().await {
                accept_log.lock().expect("log").connections += 1;
                let handler = Shell {
                    log: accept_log.clone(),
                    allowed: client_key.clone(),
                    line: Vec::new(),
                };
                let relay_log = accept_log.clone();
                let config = config.clone();
                let relay = tokio::spawn(async move {
                    relay(tcp, config, handler).await;
                    relay_log.lock().expect("log").closed_connections += 1;
                });
                accept_relays.lock().expect("relays").push(relay);
            }
        });
        Self { addr, host_key, log, relays, runtime }
    }

    pub fn log(&self) -> ServerLog {
        self.log.lock().expect("log").clone()
    }

    /// Drops every TCP connection without an SSH goodbye.
    pub fn kill_connections(&self) {
        for relay in self.relays.lock().expect("relays").drain(..) {
            relay.abort();
        }
    }

    /// Waits until `check` holds for the server log.
    pub fn wait_for(&self, what: &str, check: impl Fn(&ServerLog) -> bool) -> ServerLog {
        let deadline = Instant::now() + WAIT;
        loop {
            let log = self.log();
            if check(&log) {
                return log;
            }
            assert!(Instant::now() < deadline, "server never saw {what}: {log:?}");
            std::thread::sleep(TICK);
        }
    }
}

/// The relay task owns the TCP socket. Aborting it closes the socket, which
/// is how the tests drop the transport.
async fn relay(mut tcp: tokio::net::TcpStream, config: Arc<server::Config>, handler: Shell) {
    let (mut near, far) = tokio::io::duplex(64 * 1024);
    // The SSH session reads the client's id through the relay, so it runs
    // beside the copy. When the relay ends, `near` drops and the session
    // sees end of file.
    tokio::spawn(async move {
        if let Ok(session) = server::run_stream(config, far, handler).await {
            let _ended = session.await;
        }
    });
    let _closed = tokio::io::copy_bidirectional(&mut tcp, &mut near).await;
}

struct Shell {
    log: Arc<Mutex<ServerLog>>,
    allowed: PublicKey,
    line: Vec<u8>,
}

impl Shell {
    fn with_log(&self, f: impl FnOnce(&mut ServerLog)) {
        f(&mut self.log.lock().expect("log"));
    }

    fn run_line(&mut self, channel: ChannelId, session: &mut Session) -> Result<(), russh::Error> {
        let line = String::from_utf8_lossy(&std::mem::take(&mut self.line)).into_owned();
        if let Some(text) = line.strip_prefix("echo ") {
            session.data(channel, format!("{text}\r\n").into_bytes())?;
        } else if let Some(kib) = line.strip_prefix("flood ") {
            let kib: usize = kib.trim().parse().unwrap_or(0);
            for _ in 0..kib {
                session.data(channel, vec![b'f'; 1024])?;
            }
        } else if let Some(code) = line.strip_prefix("exit ") {
            session.exit_status_request(channel, code.trim().parse().unwrap_or(1))?;
            session.eof(channel)?;
            session.close(channel)?;
        }
        Ok(())
    }
}

impl server::Handler for Shell {
    type Error = russh::Error;

    async fn auth_publickey_offered(
        &mut self,
        _user: &str,
        key: &PublicKey,
    ) -> Result<Auth, Self::Error> {
        self.with_log(|l| l.auth_attempts += 1);
        Ok(if key.key_data() == self.allowed.key_data() { Auth::Accept } else { Auth::reject() })
    }

    async fn auth_publickey(&mut self, user: &str, key: &PublicKey) -> Result<Auth, Self::Error> {
        let ok = user == USER && key.key_data() == self.allowed.key_data();
        Ok(if ok { Auth::Accept } else { Auth::reject() })
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.with_log(|l| l.channels += 1);
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        _term: &str,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _modes: &[(Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.with_log(|l| l.pty = Some((cols, rows)));
        session.channel_success(channel)
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)
    }

    async fn window_change_request(
        &mut self,
        _channel: ChannelId,
        cols: u32,
        rows: u32,
        _pix_width: u32,
        _pix_height: u32,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.with_log(|l| l.windows.push((cols, rows)));
        Ok(())
    }

    async fn signal(
        &mut self,
        _channel: ChannelId,
        signal: Sig,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.with_log(|l| l.signals.push(format!("{signal:?}")));
        Ok(())
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.with_log(|l| l.input.extend_from_slice(data));
        for &byte in data {
            if byte == b'\n' || byte == b'\r' {
                self.run_line(channel, session)?;
            } else {
                self.line.push(byte);
            }
        }
        Ok(())
    }
}

/// Host keys the user accepted, held by the host (here: in memory).
pub struct KnownKeys(pub Vec<(String, u16, PublicKey)>);

impl HostKeyPolicy for KnownKeys {
    fn check(&self, target: &SshTarget, key: &PublicKey) -> HostKeyDecision {
        match self.0.iter().find(|(h, p, _)| *h == target.host && *p == target.port) {
            None => HostKeyDecision::Unknown,
            Some((_, _, known)) if known.key_data() == key.key_data() => HostKeyDecision::Trusted,
            Some(_) => HostKeyDecision::Changed,
        }
    }
}

/// A credential handle over a key made in the test. Counts signatures and
/// keeps the last requested RSA hash.
pub struct MemoryCredential {
    key: PrivateKey,
    pub signs: AtomicUsize,
    pub last_hash: Mutex<Option<HashAlg>>,
}

impl MemoryCredential {
    pub fn new(key: PrivateKey) -> Self {
        Self { key, signs: AtomicUsize::new(0), last_hash: Mutex::new(None) }
    }
}

impl CredentialHandle for MemoryCredential {
    fn public_key(&self) -> PublicKey {
        self.key.public_key().clone()
    }

    fn sign(&self, hash_alg: Option<HashAlg>, data: &[u8]) -> Result<Signature, BackendError> {
        use russh::keys::signature::Signer;
        self.signs.fetch_add(1, Ordering::SeqCst);
        *self.last_hash.lock().expect("hash") = hash_alg;
        let signed = match self.key.key_data().rsa() {
            Some(rsa) => (rsa, hash_alg).try_sign(data),
            None => self.key.try_sign(data),
        };
        signed.map_err(|e| BackendError::Invalid(format!("sign: {e}")))
    }
}

/// One connection handle, `conn_test`, of kind `ssh`.
pub struct OneHandle(pub SshConnection);

impl ConnectionHandles for OneHandle {
    fn resolve(&self, kind: &str, handle: &str) -> Result<SshConnection, BackendError> {
        if kind == SSH_KIND && handle == HANDLE {
            Ok(self.0.clone())
        } else {
            Err(BackendError::Revoked { reason: format!("no {kind} handle {handle}") })
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trust {
    /// The host recorded the server's key.
    Known,
    /// The host has no key for the server.
    Unknown,
    /// The host recorded a different key for the server.
    Changed,
}

pub struct Fixture {
    pub server: TestServer,
    pub backend: SshBackend,
    pub credential: Arc<MemoryCredential>,
}

pub fn fixture(trust: Trust) -> Fixture {
    fixture_with(trust, random_key())
}

/// A 2048-bit RSA client key (the default size is slower to make).
pub fn rsa_key() -> PrivateKey {
    use russh::keys::ssh_key::private::{KeypairData, RsaKeypair};
    let rsa = RsaKeypair::random(&mut rand::rng(), 2048).expect("rsa key");
    PrivateKey::new(KeypairData::from(rsa), "").expect("rsa private key")
}

pub fn fixture_with(trust: Trust, client: PrivateKey) -> Fixture {
    let server = TestServer::start(client.public_key().clone());
    let credential = Arc::new(MemoryCredential::new(client));
    let host = server.addr.ip().to_string();
    let port = server.addr.port();
    let known = match trust {
        Trust::Known => vec![(host.clone(), port, server.host_key.clone())],
        Trust::Unknown => Vec::new(),
        Trust::Changed => vec![(host.clone(), port, random_key().public_key().clone())],
    };
    let connection = SshConnection {
        target: SshTarget { host, port, user: USER.into() },
        host_keys: Arc::new(KnownKeys(known)),
        credential: credential.clone(),
    };
    let backend = SshBackend::new(Arc::new(OneHandle(connection))).expect("backend");
    Fixture { server, backend, credential }
}

pub fn request(kind: &str, terminal: &str, grid: Grid) -> OpenRequest {
    OpenRequest {
        kind: kind.into(),
        terminal: terminal.into(),
        target: HANDLE.into(),
        command: None,
        cwd: None,
        env: Vec::new(),
        grid,
        actor: None,
    }
}

/// Drains events until `done` holds for everything taken so far.
pub fn events_until(
    terminal: &mut dyn ByteTerminal,
    what: &str,
    done: impl Fn(&[ByteEvent]) -> bool,
) -> Vec<ByteEvent> {
    let deadline = Instant::now() + WAIT;
    let mut all = Vec::new();
    loop {
        all.extend(terminal.take_events());
        if done(&all) {
            return all;
        }
        assert!(Instant::now() < deadline, "never saw {what}: {all:?}");
        std::thread::sleep(TICK);
    }
}

/// All output bytes in `events`, joined.
pub fn output(events: &[ByteEvent]) -> Vec<u8> {
    events
        .iter()
        .filter_map(|e| match e {
            ByteEvent::Output(bytes) => Some(bytes.as_slice()),
            _ => None,
        })
        .flatten()
        .copied()
        .collect()
}

pub fn contains(haystack: &[u8], needle: &str) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle.as_bytes())
}
