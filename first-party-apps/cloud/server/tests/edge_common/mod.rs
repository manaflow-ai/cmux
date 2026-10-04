//! Fakes for the files and ports tests: a tunnel whose "machine" is an echo
//! thread on one end of a Unix socket pair (no network), and a transfer that
//! records what it was given.

#![allow(dead_code)]

use crate::attach_common::{FakeSpawner, FakeTransport, attach};
use crate::common::FakeControlPlane;
use cmux_cloud::Server;
use cmux_cloud::connector::iface::Carrier;
use cmux_cloud::fs::{Transfer, TransferError, TransferJob, TransferKey};
use cmux_cloud::ports::{Edge, PortTunnel, TunnelAbort, TunnelConn, TunnelError, TunnelWrite};
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};

/// One stream the fake tunnel opened.
#[derive(Debug, Clone)]
pub struct Opened {
    pub carrier: String,
    pub generation: u64,
    pub host: String,
    pub port: u16,
}

#[derive(Default)]
pub struct TunnelLog {
    pub opened: Vec<Opened>,
    /// Bytes the machine side received, per opened stream.
    pub received: Vec<Arc<Mutex<Vec<u8>>>>,
    /// When set, every open fails as if the link were down.
    pub down: bool,
}

#[derive(Clone, Default)]
pub struct FakeTunnel(pub Arc<Mutex<TunnelLog>>);

impl FakeTunnel {
    pub fn log(&self) -> std::sync::MutexGuard<'_, TunnelLog> {
        self.0.lock().unwrap()
    }

    /// Everything the machine side received, over all streams.
    pub fn all_received(&self) -> Vec<u8> {
        self.log().received.iter().flat_map(|r| r.lock().unwrap().clone()).collect()
    }
}

struct Half(UnixStream);

impl Write for Half {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

impl TunnelWrite for Half {
    fn shutdown_write(&mut self) -> std::io::Result<()> {
        self.0.shutdown(Shutdown::Write)
    }
}

struct Abort(UnixStream);

impl TunnelAbort for Abort {
    fn abort(&self) {
        let _ = self.0.shutdown(Shutdown::Both);
    }
}

impl PortTunnel for FakeTunnel {
    fn open(&self, carrier: &Carrier, host: &str, port: u16) -> Result<TunnelConn, TunnelError> {
        let mut log = self.log();
        if log.down {
            return Err(TunnelError::Down("fake link down".into()));
        }
        log.opened.push(Opened {
            carrier: carrier.id.clone(),
            generation: carrier.generation,
            host: host.to_owned(),
            port,
        });
        let received = Arc::new(Mutex::new(Vec::new()));
        log.received.push(Arc::clone(&received));
        drop(log);
        let (near, mut far) = UnixStream::pair().map_err(|e| TunnelError::Down(e.to_string()))?;
        // The machine: echo every byte back and record it.
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match far.read(&mut buf) {
                    Ok(0) | Err(_) => {
                        let _ = far.shutdown(Shutdown::Write);
                        break;
                    }
                    Ok(n) => {
                        received.lock().unwrap().extend_from_slice(&buf[..n]);
                        if far.write_all(&buf[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
        });
        let reader = near.try_clone().unwrap();
        let writer = near.try_clone().unwrap();
        Ok(TunnelConn {
            reader: Box::new(reader),
            writer: Box::new(Half(writer)),
            abort: Arc::new(Abort(near)),
        })
    }
}

/// What the fake transfer saw.
#[derive(Default)]
pub struct TransferLog {
    pub jobs: Vec<TransferJob>,
    pub public_keys: Vec<String>,
    /// The next run fails with this message.
    pub fail_with: Option<String>,
}

#[derive(Clone, Default)]
pub struct FakeTransfer(pub Arc<Mutex<TransferLog>>);

impl FakeTransfer {
    pub fn log(&self) -> std::sync::MutexGuard<'_, TransferLog> {
        self.0.lock().unwrap()
    }
}

impl Transfer for FakeTransfer {
    fn run(&mut self, job: &TransferJob, key: &TransferKey) -> Result<u64, TransferError> {
        let mut log = self.log();
        log.jobs.push(job.clone());
        log.public_keys.push(key.public_openssh());
        match log.fail_with.take() {
            Some(message) => Err(TransferError { message, retryable: false }),
            None => Ok(42),
        }
    }
}

pub struct Rig {
    pub server: Server<FakeControlPlane>,
    pub spawner: FakeSpawner,
    pub tunnel: FakeTunnel,
    pub transfer: FakeTransfer,
}

/// A server with the fake control plane, link, tunnel and transfer.
pub fn rig(fixtures: &[&str]) -> Rig {
    let spawner = FakeSpawner::default();
    let tunnel = FakeTunnel::default();
    let transfer = FakeTransfer::default();
    let edge = Edge::new(Arc::new(tunnel.clone()), Box::new(transfer.clone()));
    let server = Server::with_parts(
        FakeControlPlane::with(fixtures),
        attach(&spawner, &FakeTransport::default()),
        edge,
    );
    Rig { server, spawner, tunnel, transfer }
}
