use std::fmt;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, watch};

use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, SupportedClientAuthModes, TransportProvider,
    sanitized_route,
};
<<<<<<< ours
use crate::ssh_args::background_ssh_arguments;
use crate::ssh_control::{SshConnectionShare, SshTarget};
=======
use crate::ssh_args::carrier_ssh_arguments;
>>>>>>> theirs

const SSH_GRACEFUL_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
/// ssh's ConnectTimeout for a redial (any open after the first). Short, so a
/// redial sent into a dead network gives up within a few seconds and the next
/// one starts on the network that came back, instead of waiting out TCP's SYN
/// backoff (the probe's 10 s drops: about 1.8 s of that per reconnect, with
/// the caller's 15 s). The redialer's budget, not ssh, decides how often.
/// acpmux's peer redial uses the same 3 s (`SSH_CONNECT_SECS`).
const SSH_REDIAL_CONNECT_SECS: u64 = 3;
/// What ssh says when the host answered TCP but not with its banner in time:
/// a slow host, not a dead network. Later redials keep the caller's timeout.
const SSH_BANNER_TIMEOUT: &str = "timed out during banner exchange";
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
    /// One authenticated connection per host, shared by the bootstrap and
    /// every carrier link of this connect (issue 38157). Off by default.
    pub connection_share: SshConnectionShare,
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
            connection_share: SshConnectionShare::disabled(),
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
            slow_banner: AtomicBool::new(false),
            last_stderr: StdMutex::new(None),
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
    /// Set once an ssh run of this group timed out on the host's banner:
    /// redials then keep the caller's ConnectTimeout.
    slow_banner: AtomicBool,
    /// The newest run's generation and stderr, read by the next open for a
    /// banner timeout.
    last_stderr: StdMutex<Option<(u64, Arc<StderrTail>)>>,
}

impl SshLinkGroup {
    /// The ssh options this open adds before the caller's: a short
    /// ConnectTimeout on a redial (generation past the first connect's 0),
    /// unless the host was slow to send its banner or the caller already
    /// asked for a shorter one. OpenSSH keeps the first value it reads.
    async fn connect_timeout_args(&self, generation: u64) -> Vec<String> {
        if generation == 0 {
            return Vec::new();
        }
        let previous = self.last_stderr.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some((ran_for, tail)) = previous {
            // A run of an earlier generation has ended or is ending and may
            // still be writing why: its words are read once its stderr
            // closed or STDERR_SETTLE passed. Another lane of this generation
            // is live, so its stderr stays open: read what it said so far.
            if ran_for < generation {
                let _ = tail.settled().await;
            }
            if tail.said(SSH_BANNER_TIMEOUT) {
                self.slow_banner.store(true, Ordering::Release);
            }
        }
        if self.slow_banner.load(Ordering::Acquire)
            || caller_connect_timeout(&self.config.extra_args)
                .is_some_and(|seconds| seconds <= SSH_REDIAL_CONNECT_SECS)
        {
            return Vec::new();
        }
        vec!["-o".into(), format!("ConnectTimeout={SSH_REDIAL_CONNECT_SECS}")]
    }
}

/// The ConnectTimeout the caller's ssh arguments set (`-oConnectTimeout=N`
/// or `-o ConnectTimeout=N`), the first one, as ssh reads it.
fn caller_connect_timeout(extra_args: &[String]) -> Option<u64> {
    let mut arguments = extra_args.iter();
    while let Some(argument) = arguments.next() {
        if argument == "--" {
            return None;
        }
        let option = match argument.strip_prefix("-o") {
            Some("") => arguments.next().map(String::as_str),
            Some(attached) => Some(attached),
            None => None,
        };
        let Some((key, value)) = option.and_then(|option| option.split_once(['=', ' '])) else {
            continue;
        };
        if key.trim().eq_ignore_ascii_case("ConnectTimeout") {
            return value.trim().parse().ok();
        }
    }
    None
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
                outer: None,
            }),
        }
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(ProviderError::Transport("SSH connection group is closed".into()));
        }
        // With a shared connection the link is a client of its master (no
        // second authentication). Otherwise forwarding stays as configured
        // unless `extra_args` pin `ControlMaster=no`: this run can become the
        // shared master that interactive sessions reuse.
        let mut extra_args = self
            .config
            .connection_share
            .client_arguments(&SshTarget {
                ssh_binary: self.config.ssh_binary.clone(),
                destination: self.destination.clone(),
                port: self.port,
                extra_args: self.config.extra_args.clone(),
            })
            .await
            .map_err(|error| ProviderError::Transport(error.to_string()))?;
        extra_args.extend(self.connect_timeout_args(request.generation).await);
        extra_args.extend(self.config.extra_args.iter().cloned());
        let mut command = Command::new(&self.config.ssh_binary);
<<<<<<< ours
=======
        // The remote-link run that starts the remote daemon passes its agent
        // socket and display to the shells, and any carrier may be that run,
        // so agent and X11 forwarding stay as configured.
>>>>>>> theirs
        command
<<<<<<< ours
            .args(background_ssh_arguments(self.port, &extra_args, &self.destination))
=======
            .args(carrier_ssh_arguments(self.port, &self.config.extra_args, &self.destination))
>>>>>>> theirs
            .args(remote_link_command(&self.config));
        // stderr is always read, for the banner timeout; uncaptured, every
        // byte still goes on to this process's stderr as ssh wrote it.
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
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
        let tail = child
            .stderr
            .take()
            .map(|stderr| StderrTail::spawn(stderr, !self.config.capture_stderr));
        *self.last_stderr.lock().unwrap_or_else(PoisonError::into_inner) =
            tail.clone().map(|tail| (request.generation, tail));
        let (stderr, forwarding) =
            if self.config.capture_stderr { (tail, None) } else { (None, tail) };
        let inner = LengthDelimitedLink::new(
            self.description.clone(),
            self.config.maximum_frame_bytes,
            stdout,
            stdin,
        );
        Ok(Box::new(SshProcessLink { inner, child: Mutex::new(Some(child)), stderr, forwarding }))
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
    /// The run's stderr, when it is passed on to this process's stderr: an
    /// ended link waits for it to settle, so ssh's last words are written
    /// before the caller reports the end.
    forwarding: Option<Arc<StderrTail>>,
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
    /// Reads `stderr` to its end; with `forward`, every chunk also goes on
    /// to this process's stderr.
    fn spawn(mut stderr: ChildStderr, forward: bool) -> Arc<Self> {
        let tail = Arc::new(Self {
            bytes: StdMutex::new(std::collections::VecDeque::with_capacity(STDERR_TAIL_BYTES)),
            done: watch::channel(false).0,
        });
        let writer = tail.clone();
        tokio::spawn(async move {
            let mut own = forward.then(tokio::io::stderr);
            let mut chunk = [0_u8; 512];
            loop {
                match stderr.read(&mut chunk).await {
                    Ok(0) | Err(_) => break,
                    Ok(read) => {
                        let read = chunk.get(..read).unwrap_or_default();
                        writer.keep(read);
                        if let Some(own) = own.as_mut() {
                            // A closed stderr of ours never stops the reading.
                            let _ = own.write_all(read).await;
                        }
                    }
                }
            }
            writer.done.send_replace(true);
        });
        tail
    }

    /// True when the tail so far holds `words`, compared case-insensitively.
    fn said(&self, words: &str) -> bool {
        let bytes: Vec<u8> =
            self.bytes.lock().unwrap_or_else(PoisonError::into_inner).iter().copied().collect();
        String::from_utf8_lossy(&bytes).to_ascii_lowercase().contains(&words.to_ascii_lowercase())
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
    /// Waits (at most STDERR_SETTLE) until a forwarded stderr is written out.
    async fn forwarded(&self) {
        if let Some(forwarding) = &self.forwarding {
            let _ = forwarding.settled().await;
        }
    }

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
            Err(error) => {
                self.forwarded().await;
                Err(error)
            }
        }
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        match self.inner.receive().await {
            Ok(Some(frame)) => Ok(Some(frame)),
            ended if self.stderr.is_none() => {
                self.forwarded().await;
                ended
            }
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
<<<<<<< ours
#[path = "ssh_tests.rs"]
mod tests;
=======
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

    /// Runs `open` with a fake `ssh` that records its argv, and returns it.
    #[cfg(unix)]
    async fn carrier_argv(extra_args: &[&str]) -> Vec<String> {
        let directory = tempfile::tempdir().unwrap();
        let log = directory.path().join("argv");
        let script = directory.path().join("ssh");
        cmux_test_exec::write_executable(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\n", log.display()),
        )
        .unwrap();
        let group = SshLinkGroup {
            description: "ssh://example.com:2222".into(),
            destination: "alice@example.com".into(),
            port: Some(2222),
            config: SshProviderConfig {
                ssh_binary: script.to_string_lossy().into_owned(),
                extra_args: extra_args.iter().map(|argument| (*argument).to_owned()).collect(),
                ..SshProviderConfig::default()
            },
            evidence: CarrierEvidence::Ssh { destination: "ssh://example.com:2222".into() },
            closed: AtomicBool::new(false),
        };

        let link = group
            .open(LinkRequest { lane: cmux_remote_protocol::Lane::Interactive, generation: 1 })
            .await
            .unwrap();
        link.close().await.unwrap();
        std::fs::read_to_string(&log).unwrap().lines().map(str::to_owned).collect()
    }

    #[cfg(unix)]
    fn expected_carrier_argv(extra_args: &[&str]) -> Vec<String> {
        ["-T", "-p", "2222"]
            .iter()
            .chain(extra_args)
            .chain(&[
                "--",
                "alice@example.com",
                "~/.local/bin/cmux-tui",
                "remote-link",
                "--stdio",
                "--session",
                "main",
            ])
            .map(|argument| (*argument).to_owned())
            .collect()
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn provider_link_uses_hardened_ssh_argv() {
        let extra = ["-o", "ControlMaster=auto"];
        assert_eq!(carrier_argv(&extra).await, expected_carrier_argv(&extra));
    }

    /// The remote-link run that starts the remote daemon passes its
    /// `SSH_AUTH_SOCK` and `DISPLAY` to the shells, so a carrier keeps agent
    /// and X11 forwarding as configured even when it can't become the shared
    /// master. The app passes `ControlPath=none` in place of a ControlPath from
    /// the user's ssh_config when an agent socket is set, and
    /// `ControlMaster=no` when the route has no identity
    /// (https://github.com/manaflow-ai/cmux/issues/24542). Port forwards from
    /// ssh_config are still cleared then, since every carrier to the host would
    /// try to bind them, but a carrier's own `-L` stays.
    #[cfg(unix)]
    #[tokio::test]
    async fn provider_link_keeps_agent_forwarding_without_a_shared_master() {
        for extra in [
            &["-o", "ControlMaster=auto", "-o", "ControlPersist=yes", "-o", "ControlPath=none"][..],
            &["-o", "ControlMaster=no", "-o", "ControlPath=none", "-A"],
        ] {
            let mut expected = vec!["-o", "ClearAllForwardings=yes"];
            expected.extend(extra);
            assert_eq!(carrier_argv(extra).await, expected_carrier_argv(&expected), "{extra:?}");
        }
        for extra in [
            &["-o", "ControlMaster=no", "-A", "-L", "8080:localhost:80"][..],
            // A caller that turns forwarding off itself, like the managed
            // machine rail, keeps its options first.
            &[
                "-o",
                "ForwardAgent=no",
                "-o",
                "ForwardX11=no",
                "-o",
                "ClearAllForwardings=yes",
                "-o",
                "ControlMaster=no",
            ],
        ] {
            assert_eq!(carrier_argv(extra).await, expected_carrier_argv(extra), "{extra:?}");
        }
    }

    #[test]
    fn remote_link_command_requests_agent_hooks_only_when_configured() {
        let mut config = SshProviderConfig::default();
        assert_eq!(
            remote_link_command(&config),
            ["~/.local/bin/cmux-tui", "remote-link", "--stdio", "--session", "main"]
        );
        config.remote_state_dir = Some("~/state".into());
        config.agent_hooks = vec!["claude".into(), "codex".into()];
        assert_eq!(
            remote_link_command(&config),
            [
                "~/.local/bin/cmux-tui",
                "remote-link",
                "--stdio",
                "--session",
                "main",
                "--state-dir",
                "~/state",
                "--agent-hooks",
                "claude,codex",
            ]
        );
    }

    #[test]
    fn agent_hook_providers_must_be_plain_words() {
        for provider in ["claude", "codex", "hermes-agent"] {
            let config = SshProviderConfig {
                agent_hooks: vec![provider.into()],
                ..SshProviderConfig::default()
            };
            assert!(SshProvider::new(config).is_ok(), "{provider}");
        }
        for provider in ["", "a,b", "claude;rm", "$(x)", "a b"] {
            let config = SshProviderConfig {
                agent_hooks: vec![provider.into()],
                ..SshProviderConfig::default()
            };
            assert!(SshProvider::new(config).is_err(), "{provider:?}");
        }
    }

    #[test]
    fn destination_preserves_user_for_dial_but_description_redacts_it() {
        let endpoint = url::Url::parse("ssh://alice@example.com:2222").unwrap();
        let (destination, description) = ssh_destination(&endpoint).unwrap();
        assert_eq!(destination, "alice@example.com");
        assert_eq!(description, "ssh://example.com:2222");
    }

    #[test]
    fn ipv6_destination_uses_openssh_form_and_bracketed_url() {
        let endpoint = url::Url::parse("ssh://[2001:db8::1]:2222").unwrap();
        let (destination, description) = ssh_destination(&endpoint).unwrap();
        assert_eq!(destination, "2001:db8::1");
        assert_eq!(description, "ssh://[2001:db8::1]:2222");
    }

    #[test]
    fn option_like_destination_is_rejected_before_group_construction() {
        let endpoint = url::Url::parse("ssh://-Fvalidation@localhost").unwrap();
        let error = ssh_destination(&endpoint).unwrap_err();
        assert!(
            matches!(error, ProviderError::Configuration(message) if message.contains("destination"))
        );
    }
}
>>>>>>> theirs
