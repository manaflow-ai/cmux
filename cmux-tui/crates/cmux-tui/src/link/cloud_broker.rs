//! One inherited parent channel for Cloud reads and per-dial tokens.
//! No endpoint discovery, account credential, arbitrary op or public listener.

use std::io;
use std::os::fd::{AsRawFd as _, FromRawFd as _};
use std::os::unix::net::UnixStream as StdStream;

use cmux_link::connect_info::{ConnectInfo, ConnectInfoError, LinkTokenGrant, is_cloud_host};
use cmux_link::dial::Service;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, oneshot};

use super::cloud::ConnectInfoSource;
use super::dial::DIAL_TIMEOUT;

const MAX_REPLY: usize = 64 * 1024;
const QUEUE_SIZE: usize = 16;

pub(super) struct Bound {
    pub stream: StdStream,
    pub identity: Option<super::native_broker::Identity>,
}

/// Duplicate and seal only a connected stream inherited from this parent.
/// The parent owns the other endpoint; a path, pid file or claimed identity
/// can never substitute for possession of that endpoint.
pub(super) fn inherited(fd: &str) -> io::Result<StdStream> {
    let refused = || io::Error::new(io::ErrorKind::PermissionDenied, "cloud.broker.parent_refused");
    let fd: i32 = fd.parse().map_err(|_| refused())?;
    if fd < 0 {
        return Err(refused());
    }
    // SAFETY: fcntl validates fd and returns a new owned descriptor, or -1.
    let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
    if copy < 0 {
        return Err(refused());
    }
    // SAFETY: copy is the fresh descriptor returned by F_DUPFD_CLOEXEC.
    let stream = unsafe { StdStream::from_raw_fd(copy) };
    let mut kind = 0_i32;
    let mut size = size_of_val(&kind) as libc::socklen_t;
    // SAFETY: kind is writable for size bytes; getsockopt validates the socket.
    if unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            std::ptr::from_mut(&mut kind).cast(),
            &mut size,
        )
    } != 0
        || kind != libc::SOCK_STREAM
    {
        return Err(refused());
    }
    cmux_link::caller::verify_inherited_parent(stream.as_raw_fd()).map_err(|_| refused())?;
    // SAFETY: seal the original descriptor too, before any later exec.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(refused());
    }
    Ok(stream)
}

#[derive(Serialize)]
#[serde(tag = "op")]
enum Request {
    #[serde(rename = "cloud.machine.connect_info")]
    Fetch { host: String },
    #[serde(rename = "cloud.machine.link_token")]
    Mint { host: String, services: Vec<Service> },
}

#[derive(Serialize)]
struct Envelope<'a> {
    version: u8,
    id: u64,
    #[serde(flatten)]
    request: &'a Request,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reply {
    version: u8,
    id: u64,
    value: Option<serde_json::Value>,
    error: Option<Refusal>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Refusal {
    code: String,
}

enum Value {
    Info(Box<ConnectInfo>),
    Token(LinkTokenGrant),
}

struct Call {
    request: Request,
    answer: oneshot::Sender<Result<Value, ConnectInfoError>>,
}

#[derive(Clone)]
pub(super) struct BrokerSource {
    calls: mpsc::Sender<Call>,
}

pub(super) struct Driver {
    stream: UnixStream,
    calls: mpsc::Receiver<Call>,
}

pub(super) fn channel(stream: UnixStream) -> (BrokerSource, Driver) {
    let (send, receive) = mpsc::channel(QUEUE_SIZE);
    (BrokerSource { calls: send }, Driver { stream, calls: receive })
}

fn unavailable() -> ConnectInfoError {
    ConnectInfoError::Unavailable("the Cloud broker is unavailable".into())
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "cloud.broker.invalid_reply")
}

fn host_valid(host: &str) -> bool {
    is_cloud_host(host) && cmux_link::stamp::valid_id(host)
}

impl BrokerSource {
    async fn call(&self, request: Request) -> Result<Value, ConnectInfoError> {
        let (answer, reply) = oneshot::channel();
        tokio::time::timeout(DIAL_TIMEOUT, async {
            self.calls.send(Call { request, answer }).await.map_err(|_| unavailable())?;
            reply.await.map_err(|_| unavailable())?
        })
        .await
        .map_err(|_| unavailable())?
    }
}

impl ConnectInfoSource for BrokerSource {
    async fn fetch(&self, host: &str) -> Result<ConnectInfo, ConnectInfoError> {
        if !host_valid(host) {
            return Err(ConnectInfoError::Forbidden);
        }
        match self.call(Request::Fetch { host: host.into() }).await? {
            Value::Info(value) => Ok(*value),
            Value::Token(_) => Err(unavailable()),
        }
    }

    async fn mint_token(
        &self,
        host: &str,
        services: &[Service],
    ) -> Result<LinkTokenGrant, ConnectInfoError> {
        if !host_valid(host)
            || services.is_empty()
            || services.len() > 2
            || services.contains(&Service::OwnerSession)
            || (services.len() == 2 && services[0] == services[1])
        {
            return Err(ConnectInfoError::Forbidden);
        }
        match self.call(Request::Mint { host: host.into(), services: services.into() }).await? {
            Value::Token(value) => Ok(value),
            Value::Info(_) => Err(unavailable()),
        }
    }
}

impl Driver {
    pub(super) async fn run(mut self) -> io::Result<()> {
        let mut id = 0_u64;
        loop {
            // No periodic wakeup. EOF ends an idle child too. Any unsolicited
            // byte is a protocol violation, never another call's reply.
            let mut call = tokio::select! {
                biased;
                incoming = self.stream.read_u8() => return match incoming {
                    Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok(()),
                    _ => Err(invalid()),
                },
                call = self.calls.recv() => match call { Some(call) => call, None => return Ok(()) },
            };
            if call.answer.is_closed() {
                continue;
            }
            id = id.checked_add(1).ok_or_else(invalid)?;
            let text = serde_json::to_vec(&Envelope { version: 1, id, request: &call.request })
                .map_err(|_| invalid())?;
            // A cancelled in-flight call ends the channel: a late token can
            // never be mistaken for the next request's answer.
            let text = tokio::select! {
                text = tokio::time::timeout(DIAL_TIMEOUT, async {
                    self.stream.write_all(&text).await?;
                    self.stream.write_all(b"\n").await?;
                    super::lines::read_line(&mut self.stream, MAX_REPLY).await
                }) => text.map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "cloud.broker.timeout"))??,
                () = call.answer.closed() => return Err(invalid()),
            };
            let reply: Reply = serde_json::from_str(&text).map_err(|_| invalid())?;
            if reply.version != 1 || reply.id != id {
                return Err(invalid());
            }
            let answer = match (reply.value, reply.error) {
                (Some(value), None) => Ok(decode(&call.request, value)?),
                (None, Some(refusal)) => {
                    Err(match ConnectInfoError::from_code(&refusal.code, "") {
                        // Do not preserve arbitrary response text in an error
                        // that could later be logged.
                        ConnectInfoError::Unavailable(_) => unavailable(),
                        known => known,
                    })
                }
                _ => return Err(invalid()),
            };
            let _ = call.answer.send(answer);
        }
    }
}

fn decode(request: &Request, value: serde_json::Value) -> io::Result<Value> {
    match request {
        Request::Fetch { host } => {
            let info: ConnectInfo = serde_json::from_value(value).map_err(|_| invalid())?;
            info.validate(host).map_err(|_| invalid())?;
            Ok(Value::Info(Box::new(info)))
        }
        Request::Mint { host, services } => {
            let grant: LinkTokenGrant = serde_json::from_value(value).map_err(|_| invalid())?;
            if grant.token.is_empty()
                || grant.services.len() != services.len()
                || !services.iter().all(|service| grant.covers(host, *service))
                || grant.vm_kind.as_deref().is_some_and(|kind| !matches!(kind, "owner" | "team"))
            {
                return Err(invalid());
            }
            Ok(Value::Token(grant))
        }
    }
}

pub(super) async fn run(driver: Option<Driver>) -> io::Result<()> {
    match driver {
        Some(driver) => driver.run().await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
#[path = "cloud_broker_tests.rs"]
mod tests;
