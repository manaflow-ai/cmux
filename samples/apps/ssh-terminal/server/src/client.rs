//! The SSH client side: host key check, public key auth through the
//! credential handle, and the session channel with a PTY and a shell.

use crate::handles::{CredentialHandle, HostKeyDecision, HostKeyPolicy, SshConnection, SshTarget};
use crate::iface::{BackendError, Grid};
use crate::output::MAX_UNREAD;
use russh::client::{self, Handle, Msg};
use russh::keys::Algorithm;
use russh::keys::agent::AgentIdentity;
use russh::keys::{HashAlg, PublicKeyOrCertificate};
use russh::{Channel, ChannelMsg, ChannelReadHalf, ChannelWriteHalf, SendError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Longest wait for TCP connect, key exchange and auth together.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);

/// The russh client handler. Its only job is the host key check.
pub struct HostKeyGate {
    target: SshTarget,
    policy: Arc<dyn HostKeyPolicy>,
    /// The refusal, kept so `open` can say why the connection ended.
    refusal: Arc<Mutex<Option<BackendError>>>,
}

impl client::Handler for HostKeyGate {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let refusal = match server_key {
            PublicKeyOrCertificate::PublicKey { key, .. } => {
                let fingerprint = key.fingerprint(HashAlg::Sha256);
                match self.policy.check(&self.target, key) {
                    HostKeyDecision::Trusted => return Ok(true),
                    HostKeyDecision::Unknown => format!("host-key-unknown {fingerprint}"),
                    HostKeyDecision::Changed => format!("host-key-changed {fingerprint}"),
                }
            }
            PublicKeyOrCertificate::Certificate(_) => "host-key-certificate-unsupported".into(),
        };
        if let Ok(mut slot) = self.refusal.lock() {
            *slot = Some(BackendError::Unavailable { reason: refusal, retryable: false });
        }
        Ok(false)
    }
}

/// Signs through the credential handle and frames the result like an SSH
/// agent reply: `data || u32 len || string algorithm || string signature`.
struct HandleSigner(Arc<dyn CredentialHandle>);

#[derive(Debug)]
enum SignError {
    Send,
    Handle(BackendError),
}

impl From<SendError> for SignError {
    fn from(_: SendError) -> Self {
        Self::Send
    }
}

impl russh::Signer for HandleSigner {
    type Error = SignError;

    #[allow(clippy::manual_async_fn)]
    fn auth_sign(
        &mut self,
        _key: &AgentIdentity,
        hash_alg: Option<HashAlg>,
        mut to_sign: Vec<u8>,
    ) -> impl Future<Output = Result<Vec<u8>, Self::Error>> + Send {
        let credential = self.0.clone();
        async move {
            let signature = credential.sign(hash_alg, &to_sign).map_err(SignError::Handle)?;
            let algorithm = signature.algorithm();
            let key_algorithm = credential.public_key().algorithm();
            let expected = if key_algorithm.clone().is_rsa() {
                Algorithm::Rsa { hash: hash_alg }
            } else {
                key_algorithm
            };
            if algorithm != expected {
                return Err(SignError::Handle(BackendError::Invalid(format!(
                    "the credential signed with {algorithm}, not {expected}"
                ))));
            }
            let name = algorithm.as_str().as_bytes();
            let blob = signature.as_bytes();
            let total = 8 + name.len() + blob.len();
            to_sign.extend_from_slice(&(total as u32).to_be_bytes());
            to_sign.extend_from_slice(&(name.len() as u32).to_be_bytes());
            to_sign.extend_from_slice(name);
            to_sign.extend_from_slice(&(blob.len() as u32).to_be_bytes());
            to_sign.extend_from_slice(blob);
            Ok(to_sign)
        }
    }
}

/// An open shell: the connection, both channel halves and any bytes that
/// came before the shell request was answered.
pub struct Opened {
    pub ssh: Handle<HostKeyGate>,
    pub read: ChannelReadHalf,
    pub write: ChannelWriteHalf<Msg>,
    pub early: Vec<u8>,
}

/// Connects, checks the host key, authenticates and opens a shell channel.
pub async fn connect(
    connection: &SshConnection,
    term: &str,
    grid: Grid,
) -> Result<Opened, BackendError> {
    let refusal = Arc::new(Mutex::new(None));
    let gate = HostKeyGate {
        target: connection.target.clone(),
        policy: connection.host_keys.clone(),
        refusal: refusal.clone(),
    };
    let result = tokio::time::timeout(CONNECT_TIMEOUT, connect_inner(connection, gate, term, grid))
        .await
        .unwrap_or_else(|_| {
            Err(BackendError::Unavailable { reason: "connect timed out".into(), retryable: true })
        });
    match result {
        Ok(opened) => Ok(opened),
        Err(error) => {
            let refused = refusal.lock().ok().and_then(|mut slot| slot.take());
            Err(refused.unwrap_or(error))
        }
    }
}

fn unavailable(stage: &str, error: impl std::fmt::Display) -> BackendError {
    BackendError::Unavailable { reason: format!("{stage}: {error}"), retryable: true }
}

async fn connect_inner(
    connection: &SshConnection,
    gate: HostKeyGate,
    term: &str,
    grid: Grid,
) -> Result<Opened, BackendError> {
    let config = Arc::new(client::Config {
        // Dead peer: the connection ends after 3 unanswered keepalives (45 s).
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 2,
        // Small per-channel queue and packets: when the session host stops
        // taking output, the client stops reading TCP after about 256 KiB.
        channel_buffer_size: 8,
        maximum_packet_size: 32 * 1024,
        ..Default::default()
    });
    let target = &connection.target;
    let address = (target.host.as_str(), target.port);
    let mut session =
        client::connect(config, address, gate).await.map_err(|e| unavailable("connect", e))?;
    let credential = connection.credential.clone();
    let hash_alg = if credential.public_key().algorithm().is_rsa() {
        session.best_supported_rsa_hash().await.map_err(|e| unavailable("auth", e))?.flatten()
    } else {
        None
    };
    let auth = session
        .authenticate_publickey_with(
            target.user.clone(),
            credential.public_key(),
            hash_alg,
            &mut HandleSigner(credential),
        )
        .await
        .map_err(|e| match e {
            SignError::Handle(error) => error,
            SignError::Send => unavailable("auth", "transport closed"),
        })?;
    if !auth.success() {
        return Err(BackendError::Unavailable {
            reason: "authentication refused".into(),
            retryable: false,
        });
    }
    let mut channel =
        session.channel_open_session().await.map_err(|e| unavailable("channel", e))?;
    let (cols, rows) = (u32::from(grid.cols), u32::from(grid.rows));
    channel
        .request_pty(true, term, cols, rows, 0, 0, &[])
        .await
        .map_err(|e| unavailable("pty", e))?;
    let mut early = Vec::new();
    expect_success(&mut channel, "pty", &mut early).await?;
    channel.request_shell(true).await.map_err(|e| unavailable("shell", e))?;
    expect_success(&mut channel, "shell", &mut early).await?;
    let (read, write) = channel.split();
    Ok(Opened { ssh: session, read, write, early })
}

/// Waits for the reply to a request. Output that comes first is kept (at
/// most [`MAX_UNREAD`]); window adjustments are skipped.
async fn expect_success(
    channel: &mut Channel<Msg>,
    what: &str,
    early: &mut Vec<u8>,
) -> Result<(), BackendError> {
    loop {
        match channel.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::Failure) => {
                return Err(BackendError::Unavailable {
                    reason: format!("the server refused the {what} request"),
                    retryable: false,
                });
            }
            Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                if early.len() + data.len() > MAX_UNREAD {
                    return Err(unavailable(what, "too much output before the reply"));
                }
                early.extend_from_slice(&data);
            }
            Some(ChannelMsg::WindowAdjusted { .. }) => {}
            Some(_) => return Err(unavailable(what, "unexpected message before the reply")),
            None => return Err(unavailable(what, "the channel closed")),
        }
    }
}
