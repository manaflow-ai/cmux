use std::fmt;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use tokio::io::AsyncReadExt as _;
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, watch};

use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, SupportedClientAuthModes, TransportProvider,
    sanitized_route,
};
use crate::ssh_args::background_ssh_arguments;

const SSH_GRACEFUL_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
/// How much of a captured ssh's stderr a link keeps: its last bytes.
const STDERR_TAIL_BYTES: usize = 2048;
/// How long a link that ended waits for ssh's last stderr words.
const STDERR_SETTLE: Duration = Duration::from_millis(250);
/// What a link's error says before a captured stderr tail, which follows
/// in double quotes (the tail holds none): `ssh stderr: "<tail>"`.
pub const SSH_STDERR_MARK: &str = "ssh stderr: ";

/// `remote-probe` capability: `remote-link --mux-socket` attaches to that
/// daemon socket. A remote without it (protocol 5 before 2026-10-10) ignores
/// the flag and attaches to its default session daemon (cx-z3zh).
pub const REMOTE_LINK_MUX_SOCKET_CAPABILITY: &str = "remote-link-mux-socket";

/// `remote-probe` capability: `remote-link` refuses any flag it does not
/// know, so a client that passes a newer flag fails loudly, never silently.
pub const REMOTE_LINK_STRICT_FLAGS_CAPABILITY: &str = "remote-link-strict-flags";

#[derive(Debug, Clone)]
pub struct SshProviderConfig {
    pub ssh_binary: String,
    pub remote_binary: String,
    pub remote_session: String,
    pub remote_state_dir: Option<String>,
    /// An existing daemon socket on the host that `remote-link` attaches to
    /// (`--mux-socket`) instead of the session's own derived one; it never
    /// starts a daemon there (a paired server's Chief brain owns it).
    pub remote_mux_socket: Option<String>,
    pub extra_args: Vec<String>,
    pub maximum_frame_bytes: usize,
    /// Coding-agent providers whose hooks `remote-link` installs on the host
    /// before it attaches (`cmux-tui agent hook install <provider>...`).
    pub agent_hooks: Vec<String>,
    /// Capture each `ssh` run's stderr instead of passing it to this
    /// process's: for a caller whose own stderr is a machine-read contract
    /// (the Cloud carrier). The link keeps its last [`STDERR_TAIL_BYTES`],
    /// as one line, and an ended link's error carries it after
    /// [`SSH_STDERR_MARK`]. Off, ssh speaks to the person directly.
    pub capture_stderr: bool,
}

impl Default for SshProviderConfig {
    fn default() -> Self {
        Self {
            ssh_binary: "ssh".into(),
            remote_binary: "~/.local/bin/cmux-tui".into(),
            remote_session: "main".into(),
            remote_state_dir: None,
            remote_mux_socket: None,
            extra_args: Vec::new(),
            maximum_frame_bytes: 65_535,
            agent_hooks: Vec::new(),
            capture_stderr: false,
        }
    }
}

impl SshProviderConfig {
    /// The `remote-probe` capabilities the remote must advertise before
    /// `remote-link` runs there with this configuration. A remote without
    /// one is older than this client: the bootstrap refuses it with
    /// `remote-protocol-older` instead of a link that drops the flag.
    ///
    /// Rule: a new `remote-link` flag whose absence changes what the link
    /// reaches adds its capability here and in `remote_link_command`, in the
    /// same change, and the remote advertises it in `remote-probe`.
    pub fn required_remote_capabilities(&self) -> Vec<String> {
        let mut required = Vec::new();
        if self.remote_mux_socket.is_some() {
            required.push(REMOTE_LINK_MUX_SOCKET_CAPABILITY.to_owned());
        }
        required
    }
}

#[derive(Debug, Clone)]
pub struct SshProvider {
    config: SshProviderConfig,
}

impl SshProvider {
    pub fn new(config: SshProviderConfig) -> Result<Self, ProviderError> {
        validate_remote_word(&config.remote_binary)?;
        validate_remote_word(&config.remote_session)?;
        if let Some(state_dir) = &config.remote_state_dir {
            validate_remote_word(state_dir)?;
        }
        if let Some(socket) = &config.remote_mux_socket {
            validate_remote_word(socket)?;
        }
        for provider in &config.agent_hooks {
            validate_agent_hook_provider(provider)?;
        }
        Ok(Self { config })
    }
}

#[async_trait]
impl TransportProvider for SshProvider {
    fn name(&self) -> &'static str {
        "ssh"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["ssh"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOrCarrier
    }

    async fn connect(&self, request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        if request.endpoint.password().is_some() {
            return Err(ProviderError::Configuration(
                "passwords are not allowed in SSH URLs; use SSH authentication".into(),
            ));
        }
        if !matches!(request.endpoint.path(), "" | "/")
            || request.endpoint.query().is_some()
            || request.endpoint.fragment().is_some()
        {
            return Err(ProviderError::Configuration(
                "SSH routes cannot contain a path, query, or fragment".into(),
            ));
        }
        let (destination, description) = ssh_destination(&request.endpoint)?;
        Ok(Arc::new(SshLinkGroup {
            description: description.clone(),
            destination,
            port: request.endpoint.port(),
            config: self.config.clone(),
            evidence: CarrierEvidence::Ssh { destination: description },
            closed: AtomicBool::new(false),
        }))
    }
}

fn ssh_destination(endpoint: &url::Url) -> Result<(String, String), ProviderError> {
    let host = match endpoint
        .host()
        .ok_or_else(|| ProviderError::Configuration("SSH endpoint is missing a host".into()))?
    {
        url::Host::Domain(host) => host.to_string(),
        url::Host::Ipv4(host) => host.to_string(),
        url::Host::Ipv6(host) => host.to_string(),
    };
    let username = endpoint.username();
    if !username.is_empty()
        && !username.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.+-".contains(&byte))
    {
        return Err(ProviderError::Configuration("SSH username is not shell-safe".into()));
    }
    if username.is_empty() && host.starts_with('-') {
        return Err(ProviderError::Configuration(
            "SSH host cannot start with '-' when no username is present".into(),
        ));
    }
    let destination = if username.is_empty() { host } else { format!("{username}@{host}") };
    if destination.starts_with('-') {
        return Err(ProviderError::Configuration(
            "SSH destination cannot begin with an option prefix".into(),
        ));
    }
    let description = sanitized_route(endpoint);
    Ok((destination, description))
}

struct SshLinkGroup {
    description: String,
    destination: String,
    port: Option<u16>,
    config: SshProviderConfig,
    evidence: CarrierEvidence,
    closed: AtomicBool,
}

#[async_trait]
impl LinkGroup for SshLinkGroup {
    fn description(&self) -> &str {
        &self.description
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::MULTI_STREAM
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn transport_snapshot(&self) -> TransportSnapshot {
        TransportSnapshot {
            provider: "ssh".into(),
            route: self.description.clone(),
            selected_path: Some(TransportPathSnapshot {
                kind: TransportPathKind::Direct,
                remote: Some(self.description.clone()),
                rtt_micros: None,
            }),
        }
    }

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("SSH connection group is closed".into()));
        }
        let mut command = Command::new(&self.config.ssh_binary);
        // Forwarding stays as configured unless `extra_args` pin
        // `ControlMaster=no`: otherwise this run can become the shared master
        // that interactive sessions reuse.
        command
            .args(background_ssh_arguments(self.port, &self.config.extra_args, &self.destination))
            .args(remote_link_command(&self.config));
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(if self.config.capture_stderr { Stdio::piped() } else { Stdio::inherit() })
            .kill_on_drop(true);
        let mut child = command
            .spawn()
            .map_err(|error| ProviderError::Transport(format!("could not start ssh: {error}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ProviderError::Transport("ssh stdin was not piped".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ProviderError::Transport("ssh stdout was not piped".into()))?;
        let stderr = child.stderr.take().map(StderrTail::spawn);
        let inner = LengthDelimitedLink::new(
            self.description.clone(),
            self.config.maximum_frame_bytes,
            stdout,
            stdin,
        );
        Ok(Box::new(SshProcessLink { inner, child: Mutex::new(Some(child)), stderr }))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

struct SshProcessLink {
    inner: LengthDelimitedLink<ChildStdout, ChildStdin>,
    child: Mutex<Option<Child>>,
    /// The run's stderr, when the provider captures it.
    stderr: Option<Arc<StderrTail>>,
}

/// The last [`STDERR_TAIL_BYTES`] an `ssh` run wrote to its stderr, read
/// as it comes, so the pipe never fills and stalls the run.
struct StderrTail {
    bytes: StdMutex<std::collections::VecDeque<u8>>,
    /// True once stderr closed (the run, its ProxyCommand and the remote
    /// command all done with it).
    done: watch::Sender<bool>,
}

impl StderrTail {
    fn spawn(mut stderr: ChildStderr) -> Arc<Self> {
        let tail = Arc::new(Self {
            bytes: StdMutex::new(std::collections::VecDeque::with_capacity(STDERR_TAIL_BYTES)),
            done: watch::channel(false).0,
        });
        let writer = tail.clone();
        tokio::spawn(async move {
            let mut chunk = [0_u8; 512];
            loop {
                match stderr.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => writer.keep(chunk.get(..read).unwrap_or_default()),
                }
            }
            writer.done.send_replace(true);
        });
        tail
    }

    fn keep(&self, read: &[u8]) {
        let mut bytes = self.bytes.lock().unwrap_or_else(PoisonError::into_inner);
        bytes.extend(read);
        let over = bytes.len().saturating_sub(STDERR_TAIL_BYTES);
        bytes.drain(..over);
    }

    /// The tail as one line, once stderr closed or [`STDERR_SETTLE`]
    /// passed: `None` when ssh said nothing.
    async fn settled(&self) -> Option<String> {
        let mut done = self.done.subscribe();
        let _ = tokio::time::timeout(STDERR_SETTLE, done.wait_for(|done| *done)).await;
        let bytes: Vec<u8> =
            self.bytes.lock().unwrap_or_else(PoisonError::into_inner).iter().copied().collect();
        let line = one_line(&String::from_utf8_lossy(&bytes));
        (!line.is_empty()).then_some(line)
    }
}

/// `text` as one printable line: control characters and runs of
/// whitespace become one space, `"` becomes `'` and `\` becomes `/`, so it
/// sits inside a double-quoted log field as it is.
pub fn one_line(text: &str) -> String {
    let mut line = String::with_capacity(text.len());
    for character in text.chars() {
        let character = match character {
            '"' => '\'',
            '\\' => '/',
            c if c.is_control() || c.is_whitespace() => ' ',
            c => c,
        };
        if character == ' ' && (line.is_empty() || line.ends_with(' ')) {
            continue;
        }
        line.push(character);
    }
    line.truncate(line.trim_end().len());
    line
}

/// The captured ssh stderr an error's text carries (see
/// [`SSH_STDERR_MARK`]), if any.
pub fn ssh_stderr_of(detail: &str) -> Option<&str> {
    let (_, rest) = detail.split_once(SSH_STDERR_MARK)?;
    let rest = rest.strip_prefix('"')?;
    rest.split_once('"').map(|(said, _)| said)
}

impl SshProcessLink {
    /// An ended link's error, with what ssh said when it was captured.
    async fn with_stderr(&self, error: Option<LinkError>) -> Option<LinkError> {
        let said = match &self.stderr {
            Some(stderr) => stderr.settled().await,
            None => None,
        };
        match (said, error) {
            (None, error) => error,
            (Some(said), None | Some(LinkError::Closed)) => Some(LinkError::Transport(format!(
                "the ssh link ended; {SSH_STDERR_MARK}\"{said}\""
            ))),
            (Some(said), Some(LinkError::Transport(detail))) => {
                Some(LinkError::Transport(format!("{detail}; {SSH_STDERR_MARK}\"{said}\"")))
            }
            (Some(_), Some(error)) => Some(error),
        }
    }
}

impl fmt::Debug for SshProcessLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("SshProcessLink").field("inner", &self.inner).finish_non_exhaustive()
    }
}

#[async_trait]
impl FrameLink for SshProcessLink {
    fn description(&self) -> &str {
        self.inner.description()
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.inner.maximum_frame_bytes()
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        match self.inner.send(frame).await {
            Ok(()) => Ok(()),
            Err(error) if self.stderr.is_some() => {
                Err(self.with_stderr(Some(error)).await.unwrap_or(LinkError::Closed))
            }
            Err(error) => Err(error),
        }
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        match self.inner.receive().await {
            Ok(Some(frame)) => Ok(Some(frame)),
            ended if self.stderr.is_none() => ended,
            Ok(None) => self.with_stderr(None).await.map_or(Ok(None), Err),
            Err(error) => Err(self.with_stderr(Some(error)).await.unwrap_or(LinkError::Closed)),
        }
    }

    async fn close(&self) -> Result<(), LinkError> {
        let _ = self.inner.close().await;
        if let Some(mut child) = self.child.lock().await.take() {
            let exited = matches!(
                tokio::time::timeout(SSH_GRACEFUL_CLOSE_TIMEOUT, child.wait()).await,
                Ok(Ok(_))
            );
            if !exited {
                let _ = child.kill().await;
                let _ = child.wait().await;
            }
        }
        Ok(())
    }
}

/// The remote command line for one link: `<binary> remote-link --stdio ...`.
fn remote_link_command(config: &SshProviderConfig) -> Vec<String> {
    let mut command = vec![
        config.remote_binary.clone(),
        "remote-link".into(),
        "--stdio".into(),
        "--session".into(),
        config.remote_session.clone(),
    ];
    if let Some(state_dir) = &config.remote_state_dir {
        command.extend(["--state-dir".into(), state_dir.clone()]);
    }
    if let Some(socket) = &config.remote_mux_socket {
        command.extend(["--mux-socket".into(), socket.clone()]);
    }
    if !config.agent_hooks.is_empty() {
        command.extend(["--agent-hooks".into(), config.agent_hooks.join(",")]);
    }
    command
}

/// Provider ids travel inside the remote shell command, so they stay plain words.
fn validate_agent_hook_provider(value: &str) -> Result<(), ProviderError> {
    if value.is_empty()
        || value.len() > 64
        || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(ProviderError::Configuration(
            "agent hook provider must be a plain provider id".into(),
        ));
    }
    Ok(())
}

fn validate_remote_word(value: &str) -> Result<(), ProviderError> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_./~:-".contains(&byte))
    {
        return Err(ProviderError::Configuration(
            "remote SSH binary must be a shell-safe path".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[tokio::test]
    async fn close_lets_the_remote_command_observe_eof_before_reaping_ssh() {
        let directory = tempfile::tempdir().unwrap();
        let outcome = directory.path().join("outcome");
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "cat >/dev/null; printf graceful > \"$CMUX_TEST_OUTCOME\""])
            .env("CMUX_TEST_OUTCOME", &outcome)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let mut child = command.spawn().unwrap();
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let link = SshProcessLink {
            inner: LengthDelimitedLink::new("ssh://test", 1024, stdout, stdin),
            child: Mutex::new(Some(child)),
        };

        link.close().await.unwrap();

        assert_eq!(std::fs::read_to_string(outcome).unwrap(), "graceful");
    }
}
