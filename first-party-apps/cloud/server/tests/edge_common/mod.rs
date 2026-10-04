//! Fakes for the files and ports tests: a tunnel whose "machine" is an echo
//! thread on one end of a Unix socket pair (no network), and a transfer that
//! records what it was given.

#![allow(dead_code)]

use crate::attach_common::{FakeSpawner, FakeTransport, attach};
use crate::common::FakeControlPlane;
use cmux_cloud::CloudError;
use cmux_cloud::Server;
use cmux_cloud::connector::iface::Carrier;
use cmux_cloud::fs::{
    Cancel, DaemonFiles, DialTarget, Direction, Transfer, TransferError, TransferJob,
};
use cmux_cloud::ports::{Edge, PortTunnel, TunnelAbort, TunnelConn, TunnelError, TunnelWrite};
use serde_json::Value;
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
    /// The next run fails with this message.
    pub fail_with: Option<String>,
    /// The next run blocks until the test sends on (or drops) the sender.
    pub hold: Option<std::sync::mpsc::Receiver<()>>,
    /// Each run takes the next of these and blocks on it like `hold`.
    pub holds: std::collections::VecDeque<std::sync::mpsc::Receiver<()>>,
    /// The next run blocks until it is cancelled; it then leaves a partial
    /// file at a pull's landing name, as a stopped pull would.
    pub until_cancel: bool,
    /// Runs that saw their cancel.
    pub cancelled: usize,
}

#[derive(Clone, Default)]
pub struct FakeTransfer(pub Arc<Mutex<TransferLog>>);

impl FakeTransfer {
    pub fn log(&self) -> std::sync::MutexGuard<'_, TransferLog> {
        self.0.lock().unwrap()
    }
}

impl Transfer for FakeTransfer {
    fn run(&self, job: &TransferJob, cancel: &Cancel) -> Result<u64, TransferError> {
        let hold = {
            let mut log = self.log();
            log.hold.take().or_else(|| log.holds.pop_front())
        };
        if let Some(hold) = hold {
            let _ = hold.recv();
        }
        if std::mem::take(&mut self.log().until_cancel) {
            let (stop, stopped) = std::sync::mpsc::channel();
            cancel.on_cancel(move || {
                let _ = stop.send(());
            });
            let _ = stopped.recv();
            if job.direction == Direction::Pull {
                std::fs::write(&job.local, b"part").unwrap();
            }
            self.log().cancelled += 1;
            return Err(TransferError { message: "killed".into(), retryable: false });
        }
        let mut log = self.log();
        log.jobs.push(job.clone());
        match log.fail_with.take() {
            Some(message) => {
                if job.direction == Direction::Pull {
                    // A failed copy can leave a partial file behind.
                    let _ = std::fs::write(&job.local, b"part");
                }
                Err(TransferError { message, retryable: true })
            }
            None => {
                if job.direction == Direction::Pull {
                    std::fs::write(&job.local, b"pulled").unwrap();
                }
                Ok(42)
            }
        }
    }
}

/// What the fake daemon file ops saw, and what they answer.
#[derive(Default)]
pub struct FilesLog {
    /// Each call: the dial target, the daemon op and its params.
    pub calls: Vec<(DialTarget, String, Value)>,
    /// Answers by daemon op (`data`), used for every call of that op.
    pub answers: std::collections::HashMap<String, Value>,
    /// Daemon error codes by op.
    pub errors: std::collections::HashMap<String, String>,
}

/// A [`DaemonFiles`] that answers from [`FilesLog`]; it dials nothing.
#[derive(Clone, Default)]
pub struct FakeFiles(pub Arc<Mutex<FilesLog>>);

impl FakeFiles {
    pub fn log(&self) -> std::sync::MutexGuard<'_, FilesLog> {
        self.0.lock().unwrap()
    }

    pub fn answer(&self, op: &str, data: Value) {
        self.log().answers.insert(op.to_owned(), data);
    }

    /// The daemon ops called, in order.
    pub fn ops(&self) -> Vec<String> {
        self.log().calls.iter().map(|(_, op, _)| op.clone()).collect()
    }
}

impl DaemonFiles for FakeFiles {
    fn call(&self, target: &DialTarget, op: &str, params: Value) -> Result<Value, CloudError> {
        let mut log = self.log();
        log.calls.push((target.clone(), op.to_owned(), params));
        if let Some(code) = log.errors.get(op) {
            return Err(cmux_cloud::fs::link_files::fs_error(code, "refused by the fake"));
        }
        Ok(log.answers.get(op).cloned().unwrap_or(Value::Null))
    }
}

pub struct Rig {
    pub server: Server<FakeControlPlane>,
    pub spawner: FakeSpawner,
    pub tunnel: FakeTunnel,
    pub transfer: FakeTransfer,
    pub files: FakeFiles,
}

/// A server with the fake control plane, link, tunnel and transfer.
pub fn rig(fixtures: &[&str]) -> Rig {
    rig_with_env(fixtures, crate::attach_common::test_env())
}

/// [`rig`] with the given app environment.
pub fn rig_with_env(fixtures: &[&str], env: cmux_cloud::app_env::AppEnv) -> Rig {
    let spawner = FakeSpawner::default();
    let tunnel = FakeTunnel::default();
    let transfer = FakeTransfer::default();
    let files = FakeFiles::default();
    let edge = Edge::new(Arc::new(tunnel.clone()), Box::new(transfer.clone()))
        .with_files(Arc::new(files.clone()));
    let server = Server::with_parts(
        FakeControlPlane::with(fixtures),
        attach(&spawner, &FakeTransport::default()).with_env(env),
        edge,
    );
    Rig { server, spawner, tunnel, transfer, files }
}
