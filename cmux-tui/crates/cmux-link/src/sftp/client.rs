//! A pipelined SFTP v3 client over any byte stream (the stdio of
//! `ssh -s sftp`, or a local `sftp-server` in tests).
//!
//! Requests carry ids; one reader task routes each reply to its waiter, so
//! many reads and writes can be in flight at once.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

use bytes::Bytes;
use tokio::io::{AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _};
use tokio::sync::{Mutex, oneshot};
use tokio::task::JoinHandle;

use super::proto::{
    Attrs, MAX_PACKET_BYTES, NameEntry, PacketBuilder, Response, SSH_FXP_CLOSE, SSH_FXP_EXTENDED,
    SSH_FXP_FSTAT, SSH_FXP_INIT, SSH_FXP_LSTAT, SSH_FXP_MKDIR, SSH_FXP_OPEN, SSH_FXP_OPENDIR,
    SSH_FXP_READ, SSH_FXP_READDIR, SSH_FXP_REALPATH, SSH_FXP_REMOVE, SSH_FXP_RENAME, SSH_FXP_RMDIR,
    SSH_FXP_STAT, SSH_FXP_WRITE, StatusCode, decode_response, decode_version,
};

const POSIX_RENAME: &str = "posix-rename@openssh.com";
const FSYNC: &str = "fsync@openssh.com";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SftpError {
    /// The server answered with a status other than OK.
    Status { code: StatusCode, message: String },
    /// The stream ended or failed; every pending request fails with this.
    ConnectionLost(String),
    /// The server sent something this client cannot read.
    Protocol(String),
}

impl std::fmt::Display for SftpError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Status { code, message } => write!(formatter, "SFTP status {code:?}: {message}"),
            Self::ConnectionLost(reason) => write!(formatter, "SFTP connection lost: {reason}"),
            Self::Protocol(message) => write!(formatter, "SFTP protocol error: {message}"),
        }
    }
}

impl std::error::Error for SftpError {}

type Writer = Box<dyn AsyncWrite + Send + Unpin>;

#[derive(Default)]
struct Pending {
    waiters: HashMap<u32, oneshot::Sender<Response>>,
    closed: Option<String>,
}

struct Inner {
    writer: Mutex<Option<Writer>>,
    pending: std::sync::Mutex<Pending>,
    next_id: AtomicU32,
    extensions: Vec<String>,
    reader: std::sync::Mutex<Option<JoinHandle<()>>>,
}

/// An SFTP session. Cheap to clone; every clone shares the stream.
#[derive(Clone)]
pub struct SftpClient {
    inner: Arc<Inner>,
}

/// An open file or directory handle on the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Handle(Bytes);

impl SftpClient {
    /// Sends INIT, reads VERSION and starts routing replies.
    pub async fn connect<R, W>(mut reader: R, mut writer: W) -> Result<Self, SftpError>
    where
        R: AsyncRead + Send + Unpin + 'static,
        W: AsyncWrite + Send + Unpin + 'static,
    {
        let init = PacketBuilder::new(SSH_FXP_INIT, None).u32(3).finish();
        writer.write_all(&init).await.map_err(lost)?;
        writer.flush().await.map_err(lost)?;
        let body = read_packet(&mut reader).await?;
        let (version, extensions) =
            decode_version(body).map_err(|error| SftpError::Protocol(error.to_string()))?;
        if version != 3 {
            return Err(SftpError::Protocol(format!("server speaks SFTP version {version}")));
        }
        let inner = Arc::new(Inner {
            writer: Mutex::new(Some(Box::new(writer))),
            pending: std::sync::Mutex::new(Pending::default()),
            next_id: AtomicU32::new(1),
            extensions,
            reader: std::sync::Mutex::new(None),
        });
        let task = tokio::spawn(route_replies(reader, Arc::downgrade(&inner)));
        *lock(&inner.reader) = Some(task);
        Ok(Self { inner })
    }

    /// True when the server offered the named extension.
    #[must_use]
    pub fn has_extension(&self, name: &str) -> bool {
        self.inner.extensions.iter().any(|extension| extension == name)
    }

    /// Closes the stream; pending requests fail with `ConnectionLost`.
    pub async fn shutdown(&self) {
        if let Some(mut writer) = self.inner.writer.lock().await.take() {
            let _ = writer.shutdown().await;
        }
        if let Some(task) = lock(&self.inner.reader).take() {
            task.abort();
        }
        fail_all(&self.inner, "client shut down");
    }

    async fn request(
        &self,
        kind: u8,
        build: impl FnOnce(PacketBuilder) -> PacketBuilder,
    ) -> Result<Response, SftpError> {
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let packet = build(PacketBuilder::new(kind, Some(id))).finish();
        let (sender, receiver) = oneshot::channel();
        {
            let mut pending = lock(&self.inner.pending);
            if let Some(reason) = &pending.closed {
                return Err(SftpError::ConnectionLost(reason.clone()));
            }
            pending.waiters.insert(id, sender);
        }
        let written = {
            let mut writer = self.inner.writer.lock().await;
            match writer.as_mut() {
                Some(writer) => match writer.write_all(&packet).await {
                    Ok(()) => writer.flush().await,
                    Err(error) => Err(error),
                },
                None => Err(std::io::Error::other("client shut down")),
            }
        };
        if let Err(error) = written {
            lock(&self.inner.pending).waiters.remove(&id);
            return Err(lost(error));
        }
        receiver.await.map_err(|_| {
            let reason = lock(&self.inner.pending).closed.clone();
            SftpError::ConnectionLost(reason.unwrap_or_else(|| "reply dropped".into()))
        })
    }

    async fn status(
        &self,
        kind: u8,
        build: impl FnOnce(PacketBuilder) -> PacketBuilder,
    ) -> Result<(), SftpError> {
        match self.request(kind, build).await? {
            Response::Status { code: StatusCode::Ok, .. } => Ok(()),
            other => Err(unexpected(other)),
        }
    }

    async fn attrs(
        &self,
        kind: u8,
        build: impl FnOnce(PacketBuilder) -> PacketBuilder,
    ) -> Result<Attrs, SftpError> {
        match self.request(kind, build).await? {
            Response::Attrs(attrs) => Ok(attrs),
            other => Err(unexpected(other)),
        }
    }

    async fn handle(
        &self,
        kind: u8,
        build: impl FnOnce(PacketBuilder) -> PacketBuilder,
    ) -> Result<Handle, SftpError> {
        match self.request(kind, build).await? {
            Response::Handle(handle) => Ok(Handle(handle)),
            other => Err(unexpected(other)),
        }
    }

    /// The canonical absolute form of `path` (`"."` is the login directory).
    pub async fn realpath(&self, path: &str) -> Result<String, SftpError> {
        match self.request(SSH_FXP_REALPATH, |packet| packet.string(path.as_bytes())).await? {
            Response::Name(entries) if entries.len() == 1 => {
                String::from_utf8(entries[0].filename.to_vec())
                    .map_err(|_| SftpError::Protocol("realpath is not UTF-8".into()))
            }
            other => Err(unexpected(other)),
        }
    }

    /// Attributes of `path`, following a final symlink.
    pub async fn stat(&self, path: &str) -> Result<Attrs, SftpError> {
        self.attrs(SSH_FXP_STAT, |packet| packet.string(path.as_bytes())).await
    }

    /// Attributes of `path` itself, never following a final symlink.
    pub async fn lstat(&self, path: &str) -> Result<Attrs, SftpError> {
        self.attrs(SSH_FXP_LSTAT, |packet| packet.string(path.as_bytes())).await
    }

    pub async fn fstat(&self, handle: &Handle) -> Result<Attrs, SftpError> {
        self.attrs(SSH_FXP_FSTAT, |packet| packet.string(&handle.0)).await
    }

    pub async fn open(&self, path: &str, flags: u32, attrs: &Attrs) -> Result<Handle, SftpError> {
        self.handle(SSH_FXP_OPEN, |packet| packet.string(path.as_bytes()).u32(flags).attrs(attrs))
            .await
    }

    pub async fn close(&self, handle: &Handle) -> Result<(), SftpError> {
        self.status(SSH_FXP_CLOSE, |packet| packet.string(&handle.0)).await
    }

    /// Reads up to `length` bytes at `offset`; `None` at end of file.
    pub async fn read(
        &self,
        handle: &Handle,
        offset: u64,
        length: u32,
    ) -> Result<Option<Bytes>, SftpError> {
        match self
            .request(SSH_FXP_READ, |packet| packet.string(&handle.0).u64(offset).u32(length))
            .await?
        {
            Response::Data(data) => Ok(Some(data)),
            Response::Status { code: StatusCode::Eof, .. } => Ok(None),
            other => Err(unexpected(other)),
        }
    }

    pub async fn write(&self, handle: &Handle, offset: u64, data: &[u8]) -> Result<(), SftpError> {
        self.status(SSH_FXP_WRITE, |packet| packet.string(&handle.0).u64(offset).string(data)).await
    }

    /// Every entry of a directory, `.` and `..` included as the server sends them.
    pub async fn read_dir(&self, path: &str) -> Result<Vec<NameEntry>, SftpError> {
        let handle = self.handle(SSH_FXP_OPENDIR, |packet| packet.string(path.as_bytes())).await?;
        let mut entries = Vec::new();
        let result = loop {
            match self.request(SSH_FXP_READDIR, |packet| packet.string(&handle.0)).await {
                Ok(Response::Name(batch)) => entries.extend(batch),
                Ok(Response::Status { code: StatusCode::Eof, .. }) => break Ok(()),
                Ok(other) => break Err(unexpected(other)),
                Err(error) => break Err(error),
            }
        };
        let closed = self.close(&handle).await;
        result?;
        closed?;
        Ok(entries)
    }

    pub async fn mkdir(&self, path: &str, mode: u32) -> Result<(), SftpError> {
        self.status(SSH_FXP_MKDIR, |packet| {
            packet.string(path.as_bytes()).attrs(&Attrs::with_permissions(mode))
        })
        .await
    }

    pub async fn rmdir(&self, path: &str) -> Result<(), SftpError> {
        self.status(SSH_FXP_RMDIR, |packet| packet.string(path.as_bytes())).await
    }

    pub async fn remove(&self, path: &str) -> Result<(), SftpError> {
        self.status(SSH_FXP_REMOVE, |packet| packet.string(path.as_bytes())).await
    }

    /// Version 3 rename: fails when `to` exists.
    pub async fn rename(&self, from: &str, to: &str) -> Result<(), SftpError> {
        self.status(SSH_FXP_RENAME, |packet| packet.string(from.as_bytes()).string(to.as_bytes()))
            .await
    }

    /// Whether [`Self::posix_rename`] is available.
    #[must_use]
    pub fn can_replace_atomically(&self) -> bool {
        self.has_extension(POSIX_RENAME)
    }

    /// `rename(2)` on the server: replaces `to` atomically.
    pub async fn posix_rename(&self, from: &str, to: &str) -> Result<(), SftpError> {
        if !self.can_replace_atomically() {
            return Err(SftpError::Status {
                code: StatusCode::OpUnsupported,
                message: POSIX_RENAME.into(),
            });
        }
        self.status(SSH_FXP_EXTENDED, |packet| {
            packet.string(POSIX_RENAME.as_bytes()).string(from.as_bytes()).string(to.as_bytes())
        })
        .await
    }

    /// `fsync(2)` on the server when it offers the extension; otherwise a no-op.
    pub async fn fsync(&self, handle: &Handle) -> Result<(), SftpError> {
        if !self.has_extension(FSYNC) {
            return Ok(());
        }
        self.status(SSH_FXP_EXTENDED, |packet| packet.string(FSYNC.as_bytes()).string(&handle.0))
            .await
    }
}

async fn read_packet<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Bytes, SftpError> {
    let length = reader.read_u32().await.map_err(lost)?;
    let length = usize::try_from(length).unwrap_or(usize::MAX);
    if length == 0 || length > MAX_PACKET_BYTES {
        return Err(SftpError::Protocol(format!("packet length {length} is out of range")));
    }
    let mut body = vec![0_u8; length];
    reader.read_exact(&mut body).await.map_err(lost)?;
    Ok(Bytes::from(body))
}

async fn route_replies<R: AsyncRead + Unpin>(mut reader: R, inner: std::sync::Weak<Inner>) {
    let reason = loop {
        let body = match read_packet(&mut reader).await {
            Ok(body) => body,
            Err(error) => break error.to_string(),
        };
        let (id, response) = match decode_response(body) {
            Ok(decoded) => decoded,
            Err(error) => break error.to_string(),
        };
        let Some(inner) = inner.upgrade() else { return };
        let waiter = lock(&inner.pending).waiters.remove(&id);
        if let Some(waiter) = waiter {
            let _ = waiter.send(response);
        }
    };
    if let Some(inner) = inner.upgrade() {
        fail_all(&inner, &reason);
    }
}

fn fail_all(inner: &Inner, reason: &str) {
    let mut pending = lock(&inner.pending);
    pending.closed.get_or_insert_with(|| reason.to_owned());
    pending.waiters.clear();
}

fn lock<T>(mutex: &std::sync::Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn lost(error: std::io::Error) -> SftpError {
    SftpError::ConnectionLost(error.to_string())
}

fn unexpected(response: Response) -> SftpError {
    match response {
        Response::Status { code, message } => SftpError::Status { code, message },
        other => SftpError::Protocol(format!("unexpected reply {other:?}")),
    }
}
