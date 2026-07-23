use std::fmt;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use bytes::Bytes;
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

use crate::link::{FrameLink, LinkError};
use crate::observability::{TransportPathKind, TransportPathSnapshot, TransportSnapshot};
use crate::provider::{
    CarrierEvidence, ConnectRequest, LengthDelimitedLink, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, TransportProvider,
};

#[derive(Debug, Clone)]
pub struct SshProviderConfig {
    pub ssh_binary: String,
    pub remote_binary: String,
    pub remote_session: String,
    pub remote_state_dir: Option<String>,
    pub extra_args: Vec<String>,
    pub maximum_frame_bytes: usize,
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
        }
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
            description,
            destination: destination.clone(),
            port: request.endpoint.port(),
            config: self.config.clone(),
            evidence: CarrierEvidence::Ssh { destination },
            closed: AtomicBool::new(false),
        }))
    }
}

fn ssh_destination(endpoint: &url::Url) -> Result<(String, String), ProviderError> {
    let (host, display_host) = match endpoint
        .host()
        .ok_or_else(|| ProviderError::Configuration("SSH endpoint is missing a host".into()))?
    {
        url::Host::Domain(host) => (host.to_string(), host.to_string()),
        url::Host::Ipv4(host) => (host.to_string(), host.to_string()),
        url::Host::Ipv6(host) => (host.to_string(), format!("[{host}]")),
    };
    let username = endpoint.username();
    if !username.is_empty()
        && !username.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.+-".contains(&byte))
    {
        return Err(ProviderError::Configuration("SSH username is not shell-safe".into()));
    }
    let destination = if username.is_empty() { host } else { format!("{username}@{host}") };
    let authority =
        if username.is_empty() { display_host } else { format!("{username}@{display_host}") };
    let description = endpoint
        .port()
        .map_or_else(|| format!("ssh://{authority}"), |port| format!("ssh://{authority}:{port}"));
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
                remote: Some(self.destination.clone()),
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
        command
            .arg(&self.destination)
            .arg(&self.config.remote_binary)
            .arg("remote-link")
            .arg("--stdio")
            .arg("--session")
            .arg(&self.config.remote_session);
        if let Some(state_dir) = &self.config.remote_state_dir {
            command.arg("--state-dir").arg(state_dir);
        }
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
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
        let inner = LengthDelimitedLink::new(
            self.description.clone(),
            self.config.maximum_frame_bytes,
            stdout,
            stdin,
        );
        Ok(Box::new(SshProcessLink { inner, child: Mutex::new(Some(child)) }))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

struct SshProcessLink {
    inner: LengthDelimitedLink<ChildStdout, ChildStdin>,
    child: Mutex<Option<Child>>,
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
        self.inner.receive().await
    }

    async fn close(&self) -> Result<(), LinkError> {
        let _ = self.inner.close().await;
        if let Some(mut child) = self.child.lock().await.take() {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destination_preserves_user_and_port_in_description() {
        let endpoint = url::Url::parse("ssh://alice@example.com:2222").unwrap();
        let (destination, description) = ssh_destination(&endpoint).unwrap();
        assert_eq!(destination, "alice@example.com");
        assert_eq!(description, "ssh://alice@example.com:2222");
    }

    #[test]
    fn ipv6_destination_uses_openssh_form_and_bracketed_url() {
        let endpoint = url::Url::parse("ssh://[2001:db8::1]:2222").unwrap();
        let (destination, description) = ssh_destination(&endpoint).unwrap();
        assert_eq!(destination, "2001:db8::1");
        assert_eq!(description, "ssh://[2001:db8::1]:2222");
    }
}
