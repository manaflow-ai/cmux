use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex, RwLock};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use tokio::io::AsyncReadExt as _;
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, Notify};
use tokio::task::JoinHandle;

use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, SupportedClientAuthModes, TransportProvider,
    sanitized_route,
};

const SSH_GRACEFUL_CLOSE_TIMEOUT: Duration = Duration::from_secs(2);
const SSH_DIAGNOSTIC_DRAIN_TIMEOUT: Duration = Duration::from_millis(100);
const SSH_DIAGNOSTIC_BYTES: usize = 8 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SshRemoteShell {
    Posix,
    WindowsCmd,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshRemoteTarget {
    pub binary: String,
    pub shell: SshRemoteShell,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct ResolvedSshTargetKey {
    destination: String,
    port: Option<u16>,
    ssh_binary: String,
    remote_binary: String,
    remote_session: String,
    remote_state_dir: Option<String>,
    extra_args: Vec<String>,
    maximum_frame_bytes: usize,
}

#[derive(Debug, Clone, Default)]
pub struct SshResolvedTargets {
    targets: Arc<RwLock<HashMap<ResolvedSshTargetKey, SshRemoteTarget>>>,
}

fn target_key(
    destination: &str,
    port: Option<u16>,
    config: &SshProviderConfig,
) -> ResolvedSshTargetKey {
    ResolvedSshTargetKey {
        destination: destination.to_owned(),
        port,
        ssh_binary: config.ssh_binary.clone(),
        remote_binary: config.remote_binary.clone(),
        remote_session: config.remote_session.clone(),
        remote_state_dir: config.remote_state_dir.clone(),
        extra_args: config.extra_args.clone(),
        maximum_frame_bytes: config.maximum_frame_bytes,
    }
}

impl SshResolvedTargets {
    fn register(
        &self,
        destination: &str,
        port: Option<u16>,
        config: &SshProviderConfig,
        target: SshRemoteTarget,
    ) -> Result<(), ProviderError> {
        validate_remote_target(&target)?;
        self.targets
            .write()
            .map_err(|_| ProviderError::Transport("SSH target registry is poisoned".into()))?
            .insert(target_key(destination, port, config), target);
        Ok(())
    }

    fn resolve(
        &self,
        destination: &str,
        port: Option<u16>,
        config: &SshProviderConfig,
    ) -> Result<SshRemoteTarget, ProviderError> {
        let target = self
            .targets
            .read()
            .map_err(|_| ProviderError::Transport("SSH target registry is poisoned".into()))?
            .get(&target_key(destination, port, config))
            .cloned()
            .ok_or_else(|| {
                ProviderError::Configuration(
                    "SSH remote shell was not resolved for this route; run bootstrap first".into(),
                )
            })?;
        validate_remote_target(&target)?;
        Ok(target)
    }
}

#[derive(Debug, Clone)]
pub struct SshProviderConfig {
    pub ssh_binary: String,
    pub remote_binary: String,
    pub remote_session: String,
    pub remote_state_dir: Option<String>,
    pub extra_args: Vec<String>,
    pub maximum_frame_bytes: usize,
    pub resolved_targets: SshResolvedTargets,
}

impl Default for SshProviderConfig {
    fn default() -> Self {
        Self {
            ssh_binary: "ssh".into(),
            remote_binary: "~/.local/bin/cmux-tui".into(),
            remote_session: "main".into(),
            remote_state_dir: None,
            extra_args: Vec::new(),
            maximum_frame_bytes: 65_535,
            resolved_targets: SshResolvedTargets::default(),
        }
    }
}

impl SshProviderConfig {
    pub fn register_resolved_target(
        &self,
        destination: &str,
        port: Option<u16>,
        target: SshRemoteTarget,
    ) -> Result<(), ProviderError> {
        self.resolved_targets.register(destination, port, self, target)
    }
}

#[derive(Debug, Clone)]
pub struct SshProvider {
    config: SshProviderConfig,
    resolved_targets: SshResolvedTargets,
}

impl SshProvider {
    pub fn new(config: SshProviderConfig) -> Result<Self, ProviderError> {
        validate_remote_word(&config.remote_binary)?;
        validate_remote_word(&config.remote_session)?;
        if let Some(state_dir) = &config.remote_state_dir {
            validate_remote_state_dir(state_dir)?;
        }
        let resolved_targets = config.resolved_targets.clone();
        Ok(Self { config, resolved_targets })
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
        let port = request.endpoint.port();
        let target = self.resolved_targets.resolve(&destination, port, &self.config)?;
        Ok(Arc::new(SshLinkGroup {
            description: description.clone(),
            destination,
            port,
            target,
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
    target: SshRemoteTarget,
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
        match self.target.shell {
            SshRemoteShell::Posix => ProviderCapabilities::MULTI_STREAM,
            SshRemoteShell::WindowsCmd => ProviderCapabilities::STREAM,
        }
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
        command.arg("-T");
        if let Some(port) = self.port {
            command.arg("-p").arg(port.to_string());
        }
        command.args(&self.config.extra_args);
        command.arg(&self.destination);
        match self.target.shell {
            SshRemoteShell::Posix => {
                if let Some(state_dir) = &self.config.remote_state_dir {
                    validate_posix_remote_state_dir(state_dir)?;
                }
                command
                    .arg(&self.target.binary)
                    .arg("remote-link")
                    .arg("--stdio")
                    .arg("--session")
                    .arg(&self.config.remote_session);
                if let Some(state_dir) = &self.config.remote_state_dir {
                    command.arg("--state-dir").arg(state_dir);
                }
            }
            SshRemoteShell::WindowsCmd => {
                command.arg(windows_remote_link_command(
                    &self.target.binary,
                    &self.config.remote_session,
                    self.config.remote_state_dir.as_deref(),
                )?);
            }
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let child = command
            .spawn()
            .map_err(|error| ProviderError::Transport(format!("could not start ssh: {error}")))?;
        let link = SshProcessLink::from_child(
            self.description.clone(),
            self.config.maximum_frame_bytes,
            child,
        )?;
        Ok(Box::new(link))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

struct SshProcessLink {
    inner: LengthDelimitedLink<ChildStdout, ChildStdin>,
    child: Mutex<Option<Child>>,
    diagnostics: Arc<SshDiagnostics>,
    diagnostics_task: Mutex<Option<JoinHandle<()>>>,
}

#[derive(Default)]
struct SshDiagnostics {
    tail: StdMutex<VecDeque<u8>>,
    finished: AtomicBool,
    finished_notify: Notify,
}

impl SshDiagnostics {
    fn push(&self, chunk: &[u8]) {
        let mut tail = self.tail.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if chunk.len() >= SSH_DIAGNOSTIC_BYTES {
            tail.clear();
            tail.extend(&chunk[chunk.len() - SSH_DIAGNOSTIC_BYTES..]);
            return;
        }
        let overflow = tail.len().saturating_add(chunk.len()).saturating_sub(SSH_DIAGNOSTIC_BYTES);
        tail.drain(..overflow);
        tail.extend(chunk);
    }

    fn finish(&self) {
        self.finished.store(true, Ordering::Release);
        self.finished_notify.notify_waiters();
    }

    async fn wait_finished(&self) {
        loop {
            let finished = self.finished_notify.notified();
            if self.finished.load(Ordering::Acquire) {
                return;
            }
            finished.await;
        }
    }

    fn summary(&self) -> Option<String> {
        let bytes = self
            .tail
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .copied()
            .collect::<Vec<_>>();
        let normalized = String::from_utf8_lossy(&bytes)
            .chars()
            .map(|character| if character.is_control() { ' ' } else { character })
            .collect::<String>();
        let compact = normalized.split_whitespace().collect::<Vec<_>>().join(" ");
        (!compact.is_empty()).then_some(compact)
    }
}

impl SshProcessLink {
    fn from_child(
        description: String,
        maximum_frame_bytes: usize,
        mut child: Child,
    ) -> Result<Self, ProviderError> {
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| ProviderError::Transport("ssh stdin was not piped".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| ProviderError::Transport("ssh stdout was not piped".into()))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| ProviderError::Transport("ssh stderr was not piped".into()))?;
        let diagnostics = Arc::new(SshDiagnostics::default());
        let diagnostics_task = tokio::spawn(drain_ssh_diagnostics(stderr, diagnostics.clone()));
        Ok(Self {
            inner: LengthDelimitedLink::new(description, maximum_frame_bytes, stdout, stdin),
            child: Mutex::new(Some(child)),
            diagnostics,
            diagnostics_task: Mutex::new(Some(diagnostics_task)),
        })
    }

    async fn carrier_closed_error(&self) -> LinkError {
        let _ =
            tokio::time::timeout(SSH_DIAGNOSTIC_DRAIN_TIMEOUT, self.diagnostics.wait_finished())
                .await;
        let detail = self
            .diagnostics
            .summary()
            .map(|summary| crate::ssh_bootstrap::sanitize(&summary))
            .unwrap_or_else(|| "SSH carrier closed without diagnostics".into());
        LinkError::Transport(format!("SSH carrier closed: {detail}"))
    }

    async fn finish_diagnostics(&self) {
        let _ =
            tokio::time::timeout(SSH_DIAGNOSTIC_DRAIN_TIMEOUT, self.diagnostics.wait_finished())
                .await;
        if let Some(mut task) = self.diagnostics_task.lock().await.take()
            && tokio::time::timeout(SSH_DIAGNOSTIC_DRAIN_TIMEOUT, &mut task).await.is_err()
        {
            task.abort();
        }
    }
}

async fn drain_ssh_diagnostics(mut stderr: ChildStderr, diagnostics: Arc<SshDiagnostics>) {
    let mut buffer = [0_u8; 1024];
    loop {
        match stderr.read(&mut buffer).await {
            Ok(0) => break,
            Ok(size) => diagnostics.push(&buffer[..size]),
            Err(error) => {
                diagnostics.push(format!("could not read SSH diagnostics: {error}").as_bytes());
                break;
            }
        }
    }
    diagnostics.finish();
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
        self.inner.send(frame).await
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        match self.inner.receive().await {
            Ok(Some(frame)) => Ok(Some(frame)),
            Ok(None) | Err(LinkError::Closed) => Err(self.carrier_closed_error().await),
            Err(error) => Err(error),
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
        self.finish_diagnostics().await;
        Ok(())
    }
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

fn validate_remote_state_dir(value: &str) -> Result<(), ProviderError> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_./\\%~:@+-".contains(&byte))
    {
        return Err(ProviderError::Configuration(
            "remote SSH state directory must be a shell-safe path".into(),
        ));
    }
    Ok(())
}

fn validate_posix_remote_state_dir(value: &str) -> Result<(), ProviderError> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_./~:@+-".contains(&byte))
    {
        return Err(ProviderError::Configuration(
            "remote POSIX state directory must be a shell-safe path".into(),
        ));
    }
    Ok(())
}

fn validate_remote_target(target: &SshRemoteTarget) -> Result<(), ProviderError> {
    match target.shell {
        SshRemoteShell::Posix => validate_remote_word(&target.binary),
        SshRemoteShell::WindowsCmd => {
            if target.binary.is_empty()
                || !target
                    .binary
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_./\\%:-".contains(&byte))
            {
                return Err(ProviderError::Configuration(
                    "remote Windows binary must be a shell-safe path".into(),
                ));
            }
            Ok(())
        }
    }
}

fn windows_remote_link_command(
    binary: &str,
    session: &str,
    state_dir: Option<&str>,
) -> Result<String, ProviderError> {
    validate_remote_target(&SshRemoteTarget {
        binary: binary.to_owned(),
        shell: SshRemoteShell::WindowsCmd,
    })?;
    validate_remote_word(session)?;
    if let Some(state_dir) = state_dir {
        validate_remote_target(&SshRemoteTarget {
            binary: state_dir.to_owned(),
            shell: SshRemoteShell::WindowsCmd,
        })?;
    }
    let mut command = format!("\"{binary}\" remote-link --stdio --session {session}");
    if let Some(state_dir) = state_dir {
        command.push_str(" --state-dir \"");
        command.push_str(state_dir);
        command.push('"');
    }
    Ok(command)
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
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let child = command.spawn().unwrap();
        let link = SshProcessLink::from_child("ssh://test".into(), 1024, child).unwrap();

        link.close().await.unwrap();

        assert_eq!(std::fs::read_to_string(outcome).unwrap(), "graceful");
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn windows_ssh_eof_reports_remote_stderr() {
        let mut command = Command::new("cmd.exe");
        command
            .args(["/D", "/S", "/C", "echo CMUX_WINDOWS_OWNER_DIAGNOSTIC 1>&2"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let child = command.spawn().unwrap();
        let link = SshProcessLink::from_child("ssh://windows-diagnostic-test".into(), 1024, child)
            .unwrap();

        let received = tokio::time::timeout(Duration::from_secs(2), link.receive())
            .await
            .expect("SSH diagnostic fixture did not close stdout");
        link.close().await.unwrap();
        let error = received.expect_err("SSH EOF discarded the remote diagnostic");

        assert!(error.to_string().contains("CMUX_WINDOWS_OWNER_DIAGNOSTIC"), "{error}");
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

    #[test]
    fn resolved_windows_targets_are_scoped_by_full_ssh_configuration() {
        let host = "windows-target-registry.test";
        let config_a = SshProviderConfig {
            ssh_binary: "ssh-a".into(),
            remote_binary: "remote-a".into(),
            extra_args: vec!["-F".into(), "config-a".into()],
            ..SshProviderConfig::default()
        };
        let config_b = SshProviderConfig {
            ssh_binary: "ssh-b".into(),
            remote_binary: "remote-b".into(),
            extra_args: vec!["-F".into(), "config-b".into()],
            ..SshProviderConfig::default()
        };
        let target_a = SshRemoteTarget {
            binary: r"%LOCALAPPDATA%\cmux\bin\cmux-tui.exe".into(),
            shell: SshRemoteShell::WindowsCmd,
        };
        let target_b = SshRemoteTarget { binary: "remote-b".into(), shell: SshRemoteShell::Posix };
        config_a.register_resolved_target(host, Some(2201), target_a.clone()).unwrap();
        config_b.register_resolved_target(host, Some(2201), target_b.clone()).unwrap();
        assert_eq!(
            config_a.resolved_targets.resolve(host, Some(2201), &config_a).unwrap(),
            target_a
        );
        assert_eq!(
            config_b.resolved_targets.resolve(host, Some(2201), &config_b).unwrap(),
            target_b
        );
    }

    #[test]
    fn unresolved_ssh_target_fails_closed() {
        let config = SshProviderConfig::default();
        let error = config.resolved_targets.resolve("unresolved.test", None, &config).unwrap_err();
        assert!(matches!(
            error,
            ProviderError::Configuration(message) if message.contains("run bootstrap first")
        ));
    }

    #[test]
    fn provider_accepts_a_safe_windows_state_directory_before_shell_resolution() {
        let config = SshProviderConfig {
            remote_state_dir: Some(r"%LOCALAPPDATA%\cmux\remote".into()),
            ..SshProviderConfig::default()
        };

        SshProvider::new(config).unwrap();
    }

    #[test]
    fn windows_remote_link_is_one_cmd_safe_command() {
        let command =
            windows_remote_link_command(r"%LOCALAPPDATA%\cmux\bin\cmux-tui.exe", "main", None)
                .unwrap();

        assert_eq!(
            command,
            r#""%LOCALAPPDATA%\cmux\bin\cmux-tui.exe" remote-link --stdio --session main"#
        );
    }
}
