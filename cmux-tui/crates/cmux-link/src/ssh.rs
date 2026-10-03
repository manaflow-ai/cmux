//! The plain SSH connection kind (transport.md 12c item 1).
//!
//! The link starts the system OpenSSH client through the validated argv
//! builder ([`crate::ssh_args`]) with the user's ssh config and agent, its
//! own known-hosts file and `StrictHostKeyChecking yes` in batch mode, so
//! OpenSSH never asks a question and never stores a key. The offered key
//! comes back through the observer ([`crate::host_key`]); the connection
//! record decides whether it is confirmed, unknown or changed. A changed
//! key refuses every connect until the user confirms the new key in the
//! host-owned sheet.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::AsyncReadExt as _;
use tokio::process::{Child, Command};

use crate::conn::reducer::connect_gate;
use crate::conn::{
    ConnKind, ConnOp, ConnPath, ConnRecord, ConnRequest, ConnStore, CredentialRef, HostKeyState,
    Observation, Origin, PathKind, Principal, Reject, StoreError, Target,
};
use crate::host_key::{
    find_known_elsewhere, new_observation_file, observer_command, parse_observation,
    ssh_config_path,
};
use crate::ids::random_id;
use crate::sftp::{SftpClient, SftpError};
use crate::ssh_args::background_ssh_arguments;

const STDERR_LIMIT: usize = 16 * 1024;
const EXIT_GRACE: Duration = Duration::from_secs(5);

/// How the link runs OpenSSH.
#[derive(Clone, Debug)]
pub struct SshSettings {
    pub ssh: PathBuf,
    pub ssh_keygen: PathBuf,
    /// The user's known-hosts files: read-only input to OpenSSH (as global
    /// files, which it never writes) and to the changed-key check.
    pub user_known_hosts: Vec<PathBuf>,
    /// Options for every run, after the link's own (for example `-F` in
    /// tests).
    pub extra_args: Vec<String>,
    pub connect_timeout: Duration,
}

impl SshSettings {
    /// The system client and the user's usual known-hosts files.
    #[must_use]
    pub fn system(home: &Path) -> Self {
        Self {
            ssh: PathBuf::from("ssh"),
            ssh_keygen: PathBuf::from("ssh-keygen"),
            user_known_hosts: vec![
                home.join(".ssh/known_hosts"),
                home.join(".ssh/known_hosts2"),
                PathBuf::from("/etc/ssh/ssh_known_hosts"),
            ],
            extra_args: Vec::new(),
            connect_timeout: Duration::from_secs(15),
        }
    }
}

/// Turns a credential reference into ssh options. The secret never leaves
/// the link.
pub trait CredentialResolver: Send + Sync {
    fn ssh_arguments(&self, credential: &CredentialRef) -> Result<Vec<String>, ConnectError>;
}

/// Resolves only [`CredentialRef::SshConfig`] (the user's config and agent).
pub struct SshConfigCredentials;

impl CredentialResolver for SshConfigCredentials {
    fn ssh_arguments(&self, credential: &CredentialRef) -> Result<Vec<String>, ConnectError> {
        match credential {
            CredentialRef::SshConfig => Ok(Vec::new()),
            _ => Err(ConnectError::CredentialUnavailable),
        }
    }
}

/// Why a connect failed. `code` is the wire error code.
#[derive(Debug)]
pub enum ConnectError {
    Rejected(Reject),
    /// `host_key.unknown`: the sheet shows the fingerprint and asks.
    HostKeyUnknown {
        key_type: String,
        fingerprint: String,
    },
    /// `host_key.changed`: hard stop.
    HostKeyChanged {
        old_fingerprint: String,
        new_fingerprint: String,
    },
    AuthFailed,
    Unreachable(String),
    CredentialUnavailable,
    NotSsh,
    Store(String),
    Spawn(std::io::Error),
}

impl ConnectError {
    #[must_use]
    pub fn code(&self) -> &'static str {
        match self {
            Self::Rejected(reject) => reject.code(),
            Self::HostKeyUnknown { .. } => "host_key.unknown",
            Self::HostKeyChanged { .. } => "host_key.changed",
            Self::AuthFailed => "auth.failed",
            Self::Unreachable(_) => "host.unreachable",
            Self::CredentialUnavailable => "credential.unavailable",
            Self::NotSsh => "conn.not_ssh",
            Self::Store(_) => "link.store_failed",
            Self::Spawn(_) => "link.ssh_unavailable",
        }
    }
}

impl std::fmt::Display for ConnectError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::HostKeyUnknown { key_type, fingerprint } => {
                write!(formatter, "host_key.unknown: {key_type} {fingerprint}")
            }
            Self::HostKeyChanged { old_fingerprint, new_fingerprint } => {
                write!(formatter, "host_key.changed: was {old_fingerprint}, now {new_fingerprint}")
            }
            Self::Unreachable(reason) => write!(formatter, "host.unreachable: {reason}"),
            Self::Store(message) => write!(formatter, "link.store_failed: {message}"),
            Self::Spawn(error) => write!(formatter, "link.ssh_unavailable: {error}"),
            other => formatter.write_str(other.code()),
        }
    }
}

impl std::error::Error for ConnectError {}

impl From<StoreError> for ConnectError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::Rejected(Reject::HostKeyChanged { old_fingerprint, new_fingerprint }) => {
                Self::HostKeyChanged { old_fingerprint, new_fingerprint }
            }
            StoreError::Rejected(reject) => Self::Rejected(reject),
            other => Self::Store(other.to_string()),
        }
    }
}

/// A live SFTP session on a plain SSH host. Dropping it kills `ssh`.
pub struct SftpSession {
    pub client: SftpClient,
    child: Child,
    store: Arc<ConnStore>,
    principal: Principal,
    conn: String,
}

impl SftpSession {
    /// Ends the session and records the disconnect.
    pub async fn close(mut self) {
        self.client.shutdown().await;
        if tokio::time::timeout(EXIT_GRACE, self.child.wait()).await.is_err() {
            let _ = self.child.kill().await;
        }
        let _ = observe(&self.store, &self.principal, &self.conn, Observation::Disconnected);
    }
}

/// Opens connections of the SSH kind.
pub struct SshConnector {
    pub settings: SshSettings,
    pub store: Arc<ConnStore>,
    pub credentials: Arc<dyn CredentialResolver>,
    /// The jump slot: a `ProxyCommand` that the overlay jump through a cmux
    /// host fills later. `None` lets the user's config decide.
    pub proxy_command: Option<String>,
}

impl SshConnector {
    /// Starts `ssh -s sftp` for `conn` and speaks SFTP over its stdio.
    pub async fn open_sftp(
        &self,
        principal: &Principal,
        conn: &str,
    ) -> Result<SftpSession, ConnectError> {
        let record =
            self.store.get(principal, conn).ok_or(ConnectError::Rejected(Reject::ConnUnknown))?;
        let (Target::Ssh(target), ConnKind::Ssh) = (&record.target, record.kind) else {
            return Err(ConnectError::NotSsh);
        };
        connect_gate(&record).map_err(|reject| ConnectError::from(StoreError::Rejected(reject)))?;
        let credential_args = match &record.credential {
            Some(credential) => self.credentials.ssh_arguments(credential)?,
            None => Vec::new(),
        };
        observe(&self.store, principal, conn, Observation::Connecting)?;

        let observer_directory = self.store.directory().join("observe");
        crate::conn::store::create_private_directory(&observer_directory)
            .map_err(ConnectError::Spawn)?;
        let observation_file =
            new_observation_file(&observer_directory).map_err(ConnectError::Spawn)?;
        let result = self
            .spawn_and_handshake(
                principal,
                &record,
                target.port,
                &target.destination,
                &observation_file,
                credential_args,
            )
            .await;
        let _ = std::fs::remove_file(&observation_file);
        result
    }

    async fn spawn_and_handshake(
        &self,
        principal: &Principal,
        record: &ConnRecord,
        port: Option<u16>,
        destination: &str,
        observation_file: &Path,
        credential_args: Vec<String>,
    ) -> Result<SftpSession, ConnectError> {
        let options = self.link_options(observation_file, credential_args)?;
        let mut arguments = background_ssh_arguments(port, &options, destination);
        arguments.push("sftp".to_owned());
        let mut child = Command::new(&self.settings.ssh)
            .args(&arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(ConnectError::Spawn)?;
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = child.stdout.take().expect("stdout is piped");
        let mut stderr = child.stderr.take().expect("stderr is piped");
        let stderr_task = tokio::spawn(async move {
            let mut collected = Vec::new();
            let mut buffer = [0_u8; 4096];
            while let Ok(read) = stderr.read(&mut buffer).await {
                if read == 0 {
                    break;
                }
                if collected.len() < STDERR_LIMIT {
                    collected.extend_from_slice(&buffer[..read]);
                }
            }
            String::from_utf8_lossy(&collected).into_owned()
        });
        let handshake = tokio::time::timeout(
            self.settings.connect_timeout + Duration::from_secs(30),
            SftpClient::connect(stdout, stdin),
        )
        .await;
        let offered = std::fs::read_to_string(observation_file)
            .ok()
            .and_then(|contents| parse_observation(&contents));
        match handshake {
            Ok(Ok(client)) => {
                if offered.is_none() {
                    // The observer saw no key, so the link cannot tell which
                    // key OpenSSH trusted. Refuse rather than guess.
                    client.shutdown().await;
                    let _ = child.kill().await;
                    let _ = observe(&self.store, principal, &record.conn, Observation::Unreachable);
                    return Err(ConnectError::Unreachable("host key was not observed".into()));
                }
                let path = ConnPath { kind: PathKind::Ssh, rtt_ms: None };
                let outcome = observe(
                    &self.store,
                    principal,
                    &record.conn,
                    Observation::Connected { offered, path: Some(path) },
                );
                let after = match outcome {
                    Ok(after) => after,
                    Err(error) => {
                        client.shutdown().await;
                        let _ = child.kill().await;
                        return Err(error);
                    }
                };
                if let HostKeyState::Changed { confirmed, offered } = after.host_key {
                    // OpenSSH accepted a key through a file the link does not
                    // own; the link's confirmed key still wins.
                    client.shutdown().await;
                    let _ = child.kill().await;
                    return Err(ConnectError::HostKeyChanged {
                        old_fingerprint: confirmed.fingerprint,
                        new_fingerprint: offered.fingerprint,
                    });
                }
                Ok(SftpSession {
                    client,
                    child,
                    store: Arc::clone(&self.store),
                    principal: principal.clone(),
                    conn: record.conn.clone(),
                })
            }
            Ok(Err(error)) => {
                if tokio::time::timeout(EXIT_GRACE, child.wait()).await.is_err() {
                    let _ = child.kill().await;
                }
                let stderr = stderr_task.await.unwrap_or_default();
                Err(self.classify_failure(principal, record, offered, &stderr, &error).await)
            }
            Err(_) => {
                let _ = child.kill().await;
                let _ = observe(&self.store, principal, &record.conn, Observation::Unreachable);
                Err(ConnectError::Unreachable("connect timed out".into()))
            }
        }
    }

    fn link_options(
        &self,
        observation_file: &Path,
        credential_args: Vec<String>,
    ) -> Result<Vec<String>, ConnectError> {
        let quote = |path: &Path| {
            ssh_config_path(path).map_err(|error| ConnectError::Store(error.to_string()))
        };
        let known_hosts = quote(&self.store.known_hosts_path())?;
        let global = self
            .settings
            .user_known_hosts
            .iter()
            .map(|path| quote(path))
            .collect::<Result<Vec<_>, _>>()?
            .join(" ");
        let observer = observer_command(observation_file)
            .map_err(|error| ConnectError::Store(error.to_string()))?;
        let mut options = Vec::new();
        let mut option = |value: String| {
            options.push("-o".to_owned());
            options.push(value);
        };
        option("BatchMode=yes".into());
        option("StrictHostKeyChecking=yes".into());
        option(format!("UserKnownHostsFile={known_hosts}"));
        option(format!(
            "GlobalKnownHostsFile={}",
            if global.is_empty() { "/dev/null".to_owned() } else { global }
        ));
        option(format!("KnownHostsCommand={observer}"));
        option("UpdateHostKeys=no".into());
        option("CheckHostIP=no".into());
        // A shared master would skip the host key check of this run.
        option("ControlMaster=no".into());
        option("ControlPath=none".into());
        option(format!("ConnectTimeout={}", self.settings.connect_timeout.as_secs().max(1)));
        option("ServerAliveInterval=15".into());
        option("ServerAliveCountMax=3".into());
        if let Some(proxy) = &self.proxy_command {
            option(format!("ProxyCommand={proxy}"));
        }
        options.extend(self.settings.extra_args.iter().cloned());
        options.extend(credential_args);
        options.push("-s".to_owned());
        Ok(options)
    }

    async fn classify_failure(
        &self,
        principal: &Principal,
        record: &ConnRecord,
        offered: Option<crate::host_key::HostKey>,
        stderr: &str,
        error: &SftpError,
    ) -> ConnectError {
        let conn = &record.conn;
        if stderr.contains("Host key verification failed")
            && let Some(offered) = offered
        {
            let known_elsewhere = find_known_elsewhere(
                &self.settings.ssh_keygen,
                &self.settings.user_known_hosts,
                &offered.lookup_host,
                &offered.key_type,
            )
            .await;
            let observation =
                Observation::HostKeyRejected { offered: offered.clone(), known_elsewhere };
            return match observe(&self.store, principal, conn, observation) {
                Ok(after) => match after.host_key {
                    HostKeyState::Changed { confirmed, offered } => ConnectError::HostKeyChanged {
                        old_fingerprint: confirmed.fingerprint,
                        new_fingerprint: offered.fingerprint,
                    },
                    _ => ConnectError::HostKeyUnknown {
                        key_type: offered.key_type,
                        fingerprint: offered.fingerprint,
                    },
                },
                Err(error) => error,
            };
        }
        if stderr.contains("Permission denied") {
            let _ = observe(&self.store, principal, conn, Observation::AuthFailed);
            return ConnectError::AuthFailed;
        }
        let _ = observe(&self.store, principal, conn, Observation::Unreachable);
        let reason = stderr
            .lines()
            .rev()
            .find(|line| !line.trim().is_empty())
            .map_or_else(|| error.to_string(), |line| line.chars().take(200).collect());
        ConnectError::Unreachable(reason)
    }
}

fn observe(
    store: &ConnStore,
    principal: &Principal,
    conn: &str,
    observation: Observation,
) -> Result<ConnRecord, ConnectError> {
    let outcome = store.apply(&ConnRequest {
        idempotency_key: random_id("obs_"),
        principal: principal.clone(),
        origin: Origin::Link,
        op: ConnOp::Observe { conn: conn.to_owned(), observation },
    })?;
    outcome.record.ok_or(ConnectError::Rejected(Reject::ConnRevoked))
}
