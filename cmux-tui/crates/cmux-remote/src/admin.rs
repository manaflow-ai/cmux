//! Owner-only local administration channel for a running remote daemon.
//!
//! Enrollment decisions mutate in-memory approval channels, so admin clients
//! talk to the daemon instead of reopening its state files in another process.

use std::fmt;
use std::io;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use cmux_remote_protocol::SessionId;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{oneshot, watch};

use crate::daemon::RemoteDaemon;
use crate::identity::{EnrollmentRelayAccess, IdentityError};

const MAX_ADMIN_MESSAGE_BYTES: usize = 64 * 1024;

/// Failure to authenticate the process on the other end of a Unix socket.
#[derive(Debug)]
pub enum UnixPeerAuthError {
    Credentials(io::Error),
    WrongUid { peer_uid: u32, expected_uid: u32 },
}

impl fmt::Display for UnixPeerAuthError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Credentials(error) => {
                write!(formatter, "could not read Unix peer credentials: {error}")
            }
            Self::WrongUid { peer_uid, expected_uid } => write!(
                formatter,
                "Unix peer uid {peer_uid} does not match effective uid {expected_uid}"
            ),
        }
    }
}

impl std::error::Error for UnixPeerAuthError {}

/// Authenticates an authoritative Unix-socket responder as the effective user.
///
/// Clients must call this after connecting and before sending any bytes.
pub fn verify_unix_peer_owner(stream: &UnixStream) -> Result<(), UnixPeerAuthError> {
    verify_unix_peer_uid(stream, effective_uid())
}

pub(crate) fn verify_unix_peer_uid(
    stream: &UnixStream,
    expected_uid: u32,
) -> Result<(), UnixPeerAuthError> {
    let peer_uid = stream.peer_cred().map_err(UnixPeerAuthError::Credentials)?.uid();
    if peer_uid != expected_uid {
        return Err(UnixPeerAuthError::WrongUid { peer_uid, expected_uid });
    }
    Ok(())
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions and does not dereference pointers.
    unsafe { libc::geteuid() }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "method", rename_all = "kebab-case")]
pub enum AdminRequest {
    Status,
    CreateInvitation {
        #[serde(default = "default_invitation_ttl")]
        ttl_seconds: u64,
        #[serde(default)]
        route_hints: Vec<String>,
        #[serde(default)]
        relay_access: Vec<EnrollmentRelayAccess>,
    },
    Pending,
    Approve {
        invitation_id: String,
    },
    Deny {
        invitation_id: String,
    },
    Devices,
    Connections,
    Revoke {
        device_id: String,
    },
    Disconnect {
        device_id: String,
        session_id: String,
    },
    Shutdown,
}

const fn default_invitation_ttl() -> u64 {
    300
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdminResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl AdminResponse {
    fn success(value: impl Serialize) -> Self {
        match serde_json::to_value(value) {
            Ok(value) => Self { ok: true, result: Some(value), error: None },
            Err(error) => Self::failure(error.to_string()),
        }
    }

    fn failure(error: impl Into<String>) -> Self {
        Self { ok: false, result: None, error: Some(error.into()) }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DaemonStatus {
    pub daemon_name: String,
    pub daemon_fingerprint: String,
    pub connected_clients: usize,
}

pub struct AdminServer {
    path: PathBuf,
    shutdown: Option<oneshot::Sender<()>>,
    task: Option<tokio::task::JoinHandle<()>>,
}

impl AdminServer {
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub async fn shutdown(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = task.await;
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

impl Drop for AdminServer {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

pub async fn serve_admin(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    default_route_hints: Vec<String>,
) -> Result<AdminServer, AdminError> {
    serve_admin_with_shutdown(daemon, path, default_route_hints, None).await
}

pub async fn serve_admin_with_shutdown(
    daemon: Arc<RemoteDaemon>,
    path: impl Into<PathBuf>,
    default_route_hints: Vec<String>,
    owner_shutdown: Option<watch::Sender<bool>>,
) -> Result<AdminServer, AdminError> {
    let path = path.into();
    prepare_socket_path(&path).await?;
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let task_path = path.clone();
    let task = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => break,
                accepted = listener.accept() => {
                    let Ok((stream, _)) = accepted else { break };
                    let daemon = daemon.clone();
                    let default_route_hints = default_route_hints.clone();
                    let owner_shutdown = owner_shutdown.clone();
                    tokio::spawn(async move {
                        if validate_peer(&stream).is_ok() {
                            let _ = serve_connection(
                                daemon,
                                default_route_hints,
                                owner_shutdown,
                                stream,
                            )
                            .await;
                        }
                    });
                }
            }
        }
        let _ = std::fs::remove_file(task_path);
    });
    Ok(AdminServer { path, shutdown: Some(shutdown_tx), task: Some(task) })
}

pub async fn call_admin(
    path: impl AsRef<Path>,
    request: &AdminRequest,
) -> Result<AdminResponse, AdminError> {
    let stream = UnixStream::connect(path).await?;
    verify_unix_peer_owner(&stream)?;
    call_admin_over_stream(stream, request).await
}

#[cfg(test)]
async fn call_admin_with_expected_uid(
    path: impl AsRef<Path>,
    request: &AdminRequest,
    expected_uid: u32,
) -> Result<AdminResponse, AdminError> {
    let stream = UnixStream::connect(path).await?;
    verify_unix_peer_uid(&stream, expected_uid)?;
    call_admin_over_stream(stream, request).await
}

async fn call_admin_over_stream(
    mut stream: UnixStream,
    request: &AdminRequest,
) -> Result<AdminResponse, AdminError> {
    let mut encoded = serde_json::to_vec(request)?;
    if encoded.len() > MAX_ADMIN_MESSAGE_BYTES {
        return Err(AdminError::MessageTooLarge(encoded.len()));
    }
    encoded.push(b'\n');
    stream.write_all(&encoded).await?;
    // The newline completes the request. A write-half close can race the
    // daemon's one-response close and return ENOTCONN on macOS.
    let mut reader = BufReader::new(stream);
    let mut response = Vec::new();
    let size = reader.read_until(b'\n', &mut response).await?;
    if size == 0 {
        return Err(AdminError::Protocol("daemon closed the admin connection".into()));
    }
    if size > MAX_ADMIN_MESSAGE_BYTES {
        return Err(AdminError::MessageTooLarge(size));
    }
    Ok(serde_json::from_slice(&response)?)
}

async fn serve_connection(
    daemon: Arc<RemoteDaemon>,
    default_route_hints: Vec<String>,
    owner_shutdown: Option<watch::Sender<bool>>,
    stream: UnixStream,
) -> Result<(), AdminError> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut encoded = Vec::new();
    let size = reader.read_until(b'\n', &mut encoded).await?;
    let response = if size == 0 {
        AdminResponse::failure("empty admin request")
    } else if size > MAX_ADMIN_MESSAGE_BYTES {
        AdminResponse::failure("admin request is too large")
    } else {
        match serde_json::from_slice::<AdminRequest>(&encoded) {
            Ok(request) => {
                dispatch(&daemon, &default_route_hints, owner_shutdown.as_ref(), request).await
            }
            Err(error) => AdminResponse::failure(format!("invalid admin request: {error}")),
        }
    };
    let mut response = serde_json::to_vec(&response)?;
    response.push(b'\n');
    writer.write_all(&response).await?;
    writer.shutdown().await?;
    Ok(())
}

async fn dispatch(
    daemon: &RemoteDaemon,
    default_route_hints: &[String],
    owner_shutdown: Option<&watch::Sender<bool>>,
    request: AdminRequest,
) -> AdminResponse {
    let auth = daemon.auth();
    let result: Result<Value, IdentityError> = match request {
        AdminRequest::Status => Ok(serde_json::to_value(DaemonStatus {
            daemon_name: auth.daemon_name().to_string(),
            daemon_fingerprint: auth.identity().fingerprint(),
            connected_clients: daemon.connections().await.len(),
        })
        .expect("daemon status is serializable")),
        AdminRequest::CreateInvitation { ttl_seconds, route_hints, relay_access } => auth
            .create_invitation_with_relay_access(
                Duration::from_secs(ttl_seconds),
                if route_hints.is_empty() { default_route_hints.to_vec() } else { route_hints },
                relay_access,
            )
            .await
            .and_then(|invitation| invitation.to_uri())
            .map(|uri| serde_json::json!({ "uri": uri })),
        AdminRequest::Pending => Ok(serde_json::to_value(auth.pending_enrollments().await)
            .expect("pending enrollments are serializable")),
        AdminRequest::Approve { invitation_id } => auth
            .approve(&invitation_id)
            .await
            .map(|record| serde_json::to_value(record).expect("device record is serializable")),
        AdminRequest::Deny { invitation_id } => {
            auth.deny(&invitation_id).await.map(|()| serde_json::json!({}))
        }
        AdminRequest::Devices => Ok(serde_json::to_value(auth.list_devices().await)
            .expect("device records are serializable")),
        AdminRequest::Connections => Ok(serde_json::to_value(daemon.connection_snapshots().await)
            .expect("connection snapshots are serializable")),
        AdminRequest::Revoke { device_id } => {
            auth.revoke(&device_id).await.map(|()| serde_json::json!({}))
        }
        AdminRequest::Disconnect { device_id, session_id } => {
            match SessionId::from_hex(&session_id) {
                Ok(session_id) => match daemon.disconnect(&device_id, session_id).await {
                    Ok(true) => Ok(serde_json::json!({ "disconnected": true })),
                    Ok(false) => Err(IdentityError::Invalid(format!(
                        "no active session {session_id:?} for device {device_id}"
                    ))),
                    Err(error) => Err(IdentityError::Invalid(format!(
                        "could not disconnect session: {error}"
                    ))),
                },
                Err(error) => Err(IdentityError::Invalid(error)),
            }
        }
        AdminRequest::Shutdown => match owner_shutdown {
            Some(shutdown) => shutdown
                .send(true)
                .map(|()| serde_json::json!({ "shutting_down": true }))
                .map_err(|_| IdentityError::Invalid("daemon is already shutting down".into())),
            None => Err(IdentityError::Invalid(
                "daemon shutdown is unavailable on this admin socket".into(),
            )),
        },
    };
    match result {
        Ok(value) => AdminResponse::success(value),
        Err(error) => AdminResponse::failure(error.to_string()),
    }
}

async fn prepare_socket_path(path: &Path) -> Result<(), AdminError> {
    let parent = path
        .parent()
        .ok_or_else(|| AdminError::Protocol("admin socket path has no parent".into()))?;
    let parent_existed = parent.exists();
    std::fs::create_dir_all(parent)?;
    if !parent_existed {
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    } else {
        let mode = std::fs::metadata(parent)?.permissions().mode();
        if mode & 0o022 != 0 && mode & 0o1000 == 0 {
            return Err(AdminError::Protocol(format!(
                "admin socket directory {} is writable by other users and is not sticky",
                parent.display()
            )));
        }
    }
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if !metadata.file_type().is_socket() {
            return Err(AdminError::Protocol(format!(
                "refusing to replace non-socket admin path {}",
                path.display()
            )));
        }
        if UnixStream::connect(path).await.is_ok() {
            return Err(AdminError::Protocol(format!(
                "another daemon owns admin socket {}",
                path.display()
            )));
        }
        std::fs::remove_file(path)?;
    }
    Ok(())
}

fn validate_peer(stream: &UnixStream) -> Result<(), AdminError> {
    verify_unix_peer_owner(stream).map_err(AdminError::from)
}

#[derive(Debug)]
pub enum AdminError {
    Io(io::Error),
    Json(serde_json::Error),
    Protocol(String),
    MessageTooLarge(usize),
    UnauthorizedPeer(u32),
}

impl fmt::Display for AdminError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "admin socket failed: {error}"),
            Self::Json(error) => write!(formatter, "admin JSON failed: {error}"),
            Self::Protocol(message) => write!(formatter, "admin protocol failed: {message}"),
            Self::MessageTooLarge(size) => write!(formatter, "admin message is too large: {size}"),
            Self::UnauthorizedPeer(uid) => write!(formatter, "admin peer uid {uid} is not allowed"),
        }
    }
}

impl std::error::Error for AdminError {}

impl From<io::Error> for AdminError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for AdminError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<UnixPeerAuthError> for AdminError {
    fn from(error: UnixPeerAuthError) -> Self {
        match error {
            UnixPeerAuthError::Credentials(error) => Self::Io(error),
            UnixPeerAuthError::WrongUid { peer_uid, .. } => Self::UnauthorizedPeer(peer_uid),
        }
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;
    use tokio::io::AsyncReadExt;
    use tokio::net::UnixListener;
    use tokio::time::{Duration as TokioDuration, timeout};

    use super::*;
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    #[tokio::test]
    async fn owner_can_create_invitation_and_read_status() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "test", true).unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server =
            serve_admin(daemon, &socket, vec!["ws://127.0.0.1:1/v1/link".into()]).await.unwrap();

        let status = call_admin(&socket, &AdminRequest::Status).await.unwrap();
        assert!(status.ok);
        assert_eq!(status.result.unwrap()["daemon_name"], "test");

        let invitation = call_admin(
            &socket,
            &AdminRequest::CreateInvitation {
                ttl_seconds: 60,
                route_hints: vec![],
                relay_access: vec![],
            },
        )
        .await
        .unwrap();
        assert!(invitation.ok);
        assert!(invitation.result.unwrap()["uri"].as_str().unwrap().starts_with("cmux://enroll/"));
        server.shutdown().await;
    }

    #[tokio::test]
    async fn owner_can_request_runtime_shutdown() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "shutdown-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        let server = serve_admin_with_shutdown(daemon, &socket, Vec::new(), Some(shutdown_tx))
            .await
            .unwrap();

        let response = call_admin(&socket, &AdminRequest::Shutdown).await.unwrap();
        assert!(response.ok);
        shutdown_rx.changed().await.unwrap();
        assert!(*shutdown_rx.borrow());
        server.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn repeated_admin_requests_do_not_fail_spuriously() {
        let directory = tempdir().unwrap();
        let auth =
            AuthDatabase::load_or_create(directory.path().join("state"), "stress-test", true)
                .unwrap();
        let (daemon, _accepted) = RemoteDaemon::new(auth, SessionLimits::default());
        let socket = directory.path().join("admin.sock");
        let server = serve_admin(daemon, &socket, Vec::new()).await.unwrap();

        for iteration in 0..1_000 {
            let response =
                call_admin(&socket, &AdminRequest::Connections).await.unwrap_or_else(|error| {
                    panic!("admin request {iteration} failed spuriously: {error}")
                });
            assert!(response.ok);
        }

        server.shutdown().await;
    }

    #[tokio::test]
    async fn client_rejects_wrong_uid_responder_before_writing_request() {
        let directory = tempdir().unwrap();
        let socket = directory.path().join("impostor-admin.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let responder = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut byte = [0_u8; 1];
            timeout(TokioDuration::from_secs(1), stream.read(&mut byte))
                .await
                .expect("admin client kept the rejected connection open")
                .unwrap()
        });
        let wrong_uid = unsafe { libc::geteuid() }.wrapping_add(1);

        let error = call_admin_with_expected_uid(&socket, &AdminRequest::Status, wrong_uid)
            .await
            .unwrap_err();

        assert!(matches!(error, AdminError::UnauthorizedPeer(_)));
        assert_eq!(responder.await.unwrap(), 0, "admin request leaked to the wrong-uid responder");
    }
}
