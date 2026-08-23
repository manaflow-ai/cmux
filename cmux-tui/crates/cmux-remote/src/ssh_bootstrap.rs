use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};

const SSH_BOOTSTRAP_OUTPUT_LIMIT: usize = 4_096;
// Cleanup must not turn a bounded bootstrap timeout into an unbounded wait.
const SSH_BOOTSTRAP_REAP_TIMEOUT: Duration = Duration::from_secs(2);

/// The version of the npm/PyPI distribution that contains this binary. Release
/// workflows stamp it independently from the Rust crate's internal version.
pub const DISTRIBUTION_VERSION: &str = match option_env!("CMUX_TUI_DISTRIBUTION_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};
pub const NPM_BOOTSTRAP_VERSION: Option<&str> = option_env!("CMUX_TUI_NPM_BOOTSTRAP_VERSION");
pub const BUILD_IDENTITY: &str = env!("CMUX_TUI_BUILD_IDENTITY");

#[derive(Debug, Clone)]
pub struct SshBootstrapConfig {
    pub ssh_binary: String,
    pub destination: String,
    pub port: Option<u16>,
    pub extra_args: Vec<String>,
    pub remote_binary: String,
    pub npm_package: String,
    pub package_version: String,
    pub package_installable: bool,
    pub build_identity: String,
    /// Exact local executable used to bootstrap unpublished same-platform
    /// builds. Published distributions continue to install through npm.
    pub local_binary: Option<PathBuf>,
    pub auto_install: bool,
    pub timeout: Duration,
}

impl SshBootstrapConfig {
    pub fn defaults(destination: impl Into<String>) -> Self {
        Self {
            ssh_binary: "ssh".into(),
            destination: destination.into(),
            port: None,
            extra_args: Vec::new(),
            remote_binary: "~/.local/bin/cmux-tui".into(),
            npm_package: "cmux".into(),
            package_version: NPM_BOOTSTRAP_VERSION.unwrap_or(DISTRIBUTION_VERSION).into(),
            package_installable: NPM_BOOTSTRAP_VERSION.is_some(),
            build_identity: BUILD_IDENTITY.into(),
            local_binary: std::env::current_exe().ok(),
            auto_install: true,
            timeout: Duration::from_secs(60),
        }
    }

    fn validate(&self) -> Result<(), BootstrapError> {
        if self.destination.starts_with('-') {
            return Err(BootstrapError::Configuration(
                "SSH destination cannot begin with an option prefix".into(),
            ));
        }
        for (label, value) in [
            ("SSH destination", self.destination.as_str()),
            ("remote binary", self.remote_binary.as_str()),
            ("npm package", self.npm_package.as_str()),
            ("package version", self.package_version.as_str()),
        ] {
            if value.is_empty()
                || !value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_./~:@+-".contains(&byte))
            {
                return Err(BootstrapError::Configuration(format!("{label} is not shell-safe")));
            }
        }
        if self.timeout.is_zero() {
            return Err(BootstrapError::Configuration("SSH bootstrap timeout is zero".into()));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RemoteProbe {
    pub app: String,
    pub version: String,
    #[serde(default)]
    pub distribution_version: Option<String>,
    #[serde(default)]
    pub npm_bootstrap_version: Option<String>,
    #[serde(default)]
    pub build_identity: Option<String>,
    pub remote_protocol: u8,
    pub os: String,
    pub arch: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapOutcome {
    AlreadyInstalled,
    Installed,
}

pub struct SshBootstrapper {
    config: SshBootstrapConfig,
}

impl SshBootstrapper {
    pub fn new(config: SshBootstrapConfig) -> Result<Self, BootstrapError> {
        config.validate()?;
        Ok(Self { config })
    }

    pub async fn probe(&self) -> Result<Option<RemoteProbe>, BootstrapError> {
        self.probe_binary(&self.config.remote_binary).await
    }

    async fn probe_binary(&self, binary: &str) -> Result<Option<RemoteProbe>, BootstrapError> {
        let output = self.run_remote([binary, "remote-probe", "--json"]).await?;
        if output.status == 127 || output.status == 126 {
            return Ok(None);
        }
        if output.status != 0 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if windows_command_shell_error(&stderr) {
                return Err(BootstrapError::WindowsRequiresWsl);
            }
            if stderr.contains("not found") || stderr.contains("No such file") {
                return Ok(None);
            }
            return Err(BootstrapError::Remote {
                status: output.status,
                stderr: sanitize(&stderr),
            });
        }
        let probe = serde_json::from_slice::<RemoteProbe>(&output.stdout)
            .map_err(BootstrapError::ProbeJson)?;
        Ok(Some(probe))
    }

    pub async fn ensure_installed(&self) -> Result<BootstrapOutcome, BootstrapError> {
        let installed = self.probe().await?;
        if installed.as_ref().is_some_and(|probe| self.compatible(probe)) {
            return Ok(BootstrapOutcome::AlreadyInstalled);
        }
        if !self.config.auto_install {
            return match installed {
                Some(probe) => Err(BootstrapError::Incompatible {
                    version: probe.version,
                    protocol: probe.remote_protocol,
                }),
                None => Err(BootstrapError::Missing),
            };
        }

        self.install_verified().await
    }

    /// Installs the pinned distribution even when an older binary cannot
    /// answer `remote-probe`. This is reserved for an explicit upgrade.
    pub async fn install_verified(&self) -> Result<BootstrapOutcome, BootstrapError> {
        if !self.config.package_installable {
            return self.install_local_binary().await;
        }
        let npm_package = &self.config.npm_package;
        let package_version = &self.config.package_version;
        let package = format!("{npm_package}@{package_version}");
        let output = self
            .run_remote([
                "npx",
                "--yes",
                package.as_str(),
                "install-self",
                "--destination",
                self.config.remote_binary.as_str(),
            ])
            .await?;
        if output.status != 0 {
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        let probe = self.probe().await?.ok_or(BootstrapError::Install {
            status: 0,
            stderr: "installer completed but the remote binary is absent".into(),
        })?;
        if !self.compatible(&probe) {
            return Err(BootstrapError::Incompatible {
                version: probe.version,
                protocol: probe.remote_protocol,
            });
        }
        Ok(BootstrapOutcome::Installed)
    }

    async fn install_local_binary(&self) -> Result<BootstrapOutcome, BootstrapError> {
        let source = self.config.local_binary.as_deref().ok_or_else(|| {
            BootstrapError::PackageUnavailable(self.config.package_version.clone())
        })?;
        let remote = self.remote_platform().await?;
        let local = Platform::local();
        if !local.compatible_with(&remote) {
            return Err(BootstrapError::LocalBinaryIncompatible {
                local: local.display(),
                remote: remote.display(),
            });
        }
        let temporary = self.temporary_upload_path();
        let parent = self
            .config
            .remote_binary
            .rsplit_once('/')
            .map_or(".", |(parent, _)| if parent.is_empty() { "/" } else { parent });
        let command =
            format!("umask 077; mkdir -p {parent} && cat > {temporary} && chmod 755 {temporary}");
        let output = match self.run_remote_with_input(&command, source).await {
            Ok(output) => output,
            Err(error) => {
                self.cleanup_remote_file(&temporary).await;
                return Err(error);
            }
        };
        if output.status != 0 {
            self.cleanup_remote_file(&temporary).await;
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        let probe = match self.probe_binary(&temporary).await {
            Ok(Some(probe)) => probe,
            Ok(None) => {
                self.cleanup_remote_file(&temporary).await;
                return Err(BootstrapError::Install {
                    status: 126,
                    stderr: "uploaded binary could not run remote-probe".into(),
                });
            }
            Err(error) => {
                self.cleanup_remote_file(&temporary).await;
                return Err(error);
            }
        };
        if !self.compatible(&probe) {
            self.cleanup_remote_file(&temporary).await;
            return Err(BootstrapError::Incompatible {
                version: probe.version,
                protocol: probe.remote_protocol,
            });
        }
        let output = match self
            .run_remote(["mv", "-f", temporary.as_str(), self.config.remote_binary.as_str()])
            .await
        {
            Ok(output) => output,
            Err(error) => {
                self.cleanup_remote_file(&temporary).await;
                return Err(error);
            }
        };
        if output.status != 0 {
            self.cleanup_remote_file(&temporary).await;
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        let probe = self.probe().await?.ok_or(BootstrapError::Install {
            status: 0,
            stderr: "upload completed but the remote binary is absent".into(),
        })?;
        if !self.compatible(&probe) {
            return Err(BootstrapError::Incompatible {
                version: probe.version,
                protocol: probe.remote_protocol,
            });
        }
        Ok(BootstrapOutcome::Installed)
    }

    fn temporary_upload_path(&self) -> String {
        let now =
            SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |duration| duration.as_nanos());
        format!("{}.cmux-upload-{}-{now}", self.config.remote_binary, std::process::id())
    }

    async fn cleanup_remote_file(&self, path: &str) {
        let _ = self.run_remote(["rm", "-f", path]).await;
    }

    async fn remote_platform(&self) -> Result<Platform, BootstrapError> {
        let output = self.run_remote(["uname", "-s", "-m"]).await?;
        if output.status != 0 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            if windows_command_shell_error(&stderr) {
                return Err(BootstrapError::WindowsRequiresWsl);
            }
            return Err(BootstrapError::Remote {
                status: output.status,
                stderr: sanitize(&stderr),
            });
        }
        Platform::from_uname(&String::from_utf8_lossy(&output.stdout))
    }

    /// Explicitly stops the named remote daemon so the next carrier launch
    /// starts the already verified binary. This is never called by automatic
    /// installation alone.
    pub async fn stop_daemon(
        &self,
        session: &str,
        state_dir: Option<&str>,
    ) -> Result<(), BootstrapError> {
        if session.is_empty()
            || !session.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
        {
            return Err(BootstrapError::Configuration(
                "remote session name is not shell-safe".into(),
            ));
        }
        if let Some(state_dir) = state_dir
            && (state_dir.is_empty()
                || !state_dir
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_./~:@+-".contains(&byte)))
        {
            return Err(BootstrapError::Configuration(
                "remote state directory is not shell-safe".into(),
            ));
        }
        let output = match state_dir {
            Some(state_dir) => {
                self.run_remote([
                    self.config.remote_binary.as_str(),
                    "remote-stop",
                    "--session",
                    session,
                    "--state-dir",
                    state_dir,
                ])
                .await?
            }
            None => {
                self.run_remote([
                    self.config.remote_binary.as_str(),
                    "remote-stop",
                    "--session",
                    session,
                ])
                .await?
            }
        };
        if output.status != 0 {
            return Err(BootstrapError::Remote {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        Ok(())
    }

    fn compatible(&self, probe: &RemoteProbe) -> bool {
        let installed_distribution =
            probe.distribution_version.as_deref().unwrap_or(&probe.version);
        probe.app == "cmux-tui"
            && installed_distribution == self.config.package_version
            && (!self.config.package_installable
                || probe.npm_bootstrap_version.as_deref()
                    == Some(self.config.package_version.as_str()))
            && (self.config.package_installable
                || probe.build_identity.as_deref() == Some(self.config.build_identity.as_str()))
            && probe.remote_protocol == REMOTE_PROTOCOL_VERSION
    }

    async fn run_remote<const N: usize>(
        &self,
        remote_arguments: [&str; N],
    ) -> Result<RemoteOutput, BootstrapError> {
        let mut command = Command::new(&self.config.ssh_binary);
        self.configure_ssh_command(&mut command);
        for argument in remote_arguments {
            command.arg(argument);
        }
        command.stdin(Stdio::null());
        self.run_child(command).await
    }

    fn configure_ssh_command(&self, command: &mut Command) {
        command.arg("-T");
        if let Some(port) = self.config.port {
            command.arg("-p").arg(port.to_string());
        }
        command.args(&self.config.extra_args).arg(&self.config.destination);
    }

    async fn run_child(&self, mut command: Command) -> Result<RemoteOutput, BootstrapError> {
        let mut child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(BootstrapError::Io)?;
        let stdout = match child.stdout.take() {
            Some(stdout) => stdout,
            None => {
                terminate_and_reap(&mut child).await;
                return Err(BootstrapError::Io(std::io::Error::other(
                    "SSH stdout pipe is unavailable",
                )));
            }
        };
        let stderr = match child.stderr.take() {
            Some(stderr) => stderr,
            None => {
                terminate_and_reap(&mut child).await;
                return Err(BootstrapError::Io(std::io::Error::other(
                    "SSH stderr pipe is unavailable",
                )));
            }
        };
        let started = Instant::now();
        let completion = tokio::time::timeout(self.config.timeout, async {
            // Drain both pipes concurrently so either stream can fill without
            // blocking the other stream or the child exit observation.
            tokio::try_join!(
                read_bounded(stdout, "stdout"),
                read_bounded(stderr, "stderr"),
                async { child.wait().await.map_err(BootstrapError::Io) },
            )
        })
        .await;
        let (stdout, stderr, status) = match completion {
            Ok(Ok(result)) => result,
            Ok(Err(error)) => {
                terminate_and_reap(&mut child).await;
                // Preserve the bootstrap contract when the timeout and an
                // I/O error race under scheduler load. Once the budget has
                // expired, callers must see Timeout regardless of which
                // cancelled pipe reports first.
                return Err(if started.elapsed() >= self.config.timeout {
                    BootstrapError::Timeout
                } else {
                    error
                });
            }
            Err(_) => {
                terminate_and_reap(&mut child).await;
                return Err(BootstrapError::Timeout);
            }
        };
        Ok(RemoteOutput { status: status.code().unwrap_or(255), stdout, stderr })
    }

    async fn run_remote_with_input(
        &self,
        remote_command: &str,
        source: &Path,
    ) -> Result<RemoteOutput, BootstrapError> {
        let source = std::fs::File::open(source).map_err(BootstrapError::Io)?;
        let mut command = Command::new(&self.config.ssh_binary);
        self.configure_ssh_command(&mut command);
        command.arg(remote_command).stdin(Stdio::from(source));
        self.run_child(command).await
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Platform {
    os: String,
    arch: String,
}

impl Platform {
    fn local() -> Self {
        Self {
            os: normalize_os(std::env::consts::OS),
            arch: normalize_arch(std::env::consts::ARCH),
        }
    }

    fn from_uname(value: &str) -> Result<Self, BootstrapError> {
        let mut fields = value.split_whitespace();
        let Some(os) = fields.next() else {
            return Err(BootstrapError::PlatformProbe("uname returned no operating system".into()));
        };
        let Some(arch) = fields.next() else {
            return Err(BootstrapError::PlatformProbe("uname returned no architecture".into()));
        };
        Ok(Self { os: normalize_os(os), arch: normalize_arch(arch) })
    }

    fn compatible_with(&self, other: &Self) -> bool {
        self == other
    }

    fn display(&self) -> String {
        format!("{}-{}", self.os, self.arch)
    }
}

fn normalize_os(value: &str) -> String {
    match value.to_ascii_lowercase().as_str() {
        "darwin" | "macos" => "macos".into(),
        "linux" => "linux".into(),
        other => other.to_string(),
    }
}

fn normalize_arch(value: &str) -> String {
    match value.to_ascii_lowercase().as_str() {
        "arm64" | "aarch64" => "aarch64".into(),
        "amd64" | "x86_64" => "x86_64".into(),
        other => other.to_string(),
    }
}

fn windows_command_shell_error(stderr: &str) -> bool {
    stderr.to_ascii_lowercase().contains("is not recognized as an internal or external command")
}

async fn read_bounded(
    mut reader: impl tokio::io::AsyncRead + Unpin,
    stream: &'static str,
) -> Result<Vec<u8>, BootstrapError> {
    let mut output = Vec::with_capacity(SSH_BOOTSTRAP_OUTPUT_LIMIT);
    let mut buffer = [0_u8; 1_024];
    loop {
        let read = reader.read(&mut buffer).await.map_err(BootstrapError::Io)?;
        if read == 0 {
            return Ok(output);
        }
        if output.len() + read > SSH_BOOTSTRAP_OUTPUT_LIMIT {
            return Err(BootstrapError::OutputLimit { stream, limit: SSH_BOOTSTRAP_OUTPUT_LIMIT });
        }
        output.extend_from_slice(&buffer[..read]);
    }
}

async fn terminate_and_reap(child: &mut Child) {
    let _ = child.start_kill();
    // `wait` can be delayed by scheduler pressure (or a descendant retaining
    // the stdio pipes). Keep the caller's failure path bounded as well.
    let _ = tokio::time::timeout(SSH_BOOTSTRAP_REAP_TIMEOUT, child.wait()).await;
}

struct RemoteOutput {
    status: i32,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn sanitize(value: &str) -> String {
    let value = value.trim().replace(['\r', '\0'], "");
    if value.len() <= 4_096 {
        return value;
    }
    let mut end = 4_096;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    let prefix = &value[..end];
    format!("{prefix}…")
}

#[derive(Debug)]
pub enum BootstrapError {
    Configuration(String),
    Io(std::io::Error),
    ProbeJson(serde_json::Error),
    Timeout,
    OutputLimit { stream: &'static str, limit: usize },
    Missing,
    Remote { status: i32, stderr: String },
    Install { status: i32, stderr: String },
    PackageUnavailable(String),
    PlatformProbe(String),
    LocalBinaryIncompatible { local: String, remote: String },
    WindowsRequiresWsl,
    Incompatible { version: String, protocol: u8 },
}

impl fmt::Display for BootstrapError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(message) => write!(formatter, "invalid SSH bootstrap: {message}"),
            Self::Io(error) => write!(formatter, "SSH bootstrap failed: {error}"),
            Self::ProbeJson(error) => write!(formatter, "remote probe was invalid: {error}"),
            Self::Timeout => formatter.write_str("SSH bootstrap timed out"),
            Self::OutputLimit { stream, limit } => {
                write!(formatter, "SSH bootstrap {stream} exceeded {limit} bytes")
            }
            Self::Missing => formatter.write_str("cmux-tui is not installed on the remote host"),
            Self::Remote { status, stderr } => {
                write!(formatter, "remote probe exited {status}: {stderr}")
            }
            Self::Install { status, stderr } => {
                write!(formatter, "automatic remote install exited {status}: {stderr}")
            }
            Self::PackageUnavailable(version) => write!(
                formatter,
                "this cmux-tui build is not backed by a published npm package ({version}); preinstall the matching remote binary or use an npm release build"
            ),
            Self::PlatformProbe(message) => write!(formatter, "remote platform probe failed: {message}"),
            Self::LocalBinaryIncompatible { local, remote } => write!(
                formatter,
                "this unpublished cmux-tui build cannot be uploaded from {local} to {remote}; use a published build or preinstall a matching remote binary"
            ),
            Self::WindowsRequiresWsl => formatter.write_str(
                "native Windows cannot host the cmux-tui remote daemon yet; install a WSL 2 Linux distro with `wsl --install -d Ubuntu`, then connect through that Linux environment"
            ),
            Self::Incompatible { version, protocol } => write!(
                formatter,
                "remote cmux-tui {version} uses remote protocol {protocol}, expected {REMOTE_PROTOCOL_VERSION}"
            ),
        }
    }
}

impl std::error::Error for BootstrapError {}

impl BootstrapError {
    pub fn is_retryable_carrier_failure(&self) -> bool {
        match self {
            Self::Timeout
            | Self::Remote { status: 255, .. }
            | Self::Install { status: 255, .. } => true,
            Self::Io(error) => matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionRefused
                    | std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::NotConnected
                    | std::io::ErrorKind::BrokenPipe
                    | std::io::ErrorKind::TimedOut
                    | std::io::ErrorKind::Interrupted
                    | std::io::ErrorKind::WouldBlock
                    | std::io::ErrorKind::UnexpectedEof
            ),
            Self::PlatformProbe(_)
            | Self::LocalBinaryIncompatible { .. }
            | Self::WindowsRequiresWsl => false,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe(distribution_version: Option<&str>) -> RemoteProbe {
        RemoteProbe {
            app: "cmux-tui".into(),
            version: "0.1.0".into(),
            distribution_version: distribution_version.map(str::to_owned),
            npm_bootstrap_version: None,
            build_identity: Some(BUILD_IDENTITY.into()),
            remote_protocol: REMOTE_PROTOCOL_VERSION,
            os: "linux".into(),
            arch: "x86_64".into(),
        }
    }

    #[test]
    fn compatibility_uses_the_stamped_distribution_version() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.package_version = "0.9.4".into();
        let bootstrapper = SshBootstrapper::new(config).unwrap();

        assert!(bootstrapper.compatible(&probe(Some("0.9.4"))));
        assert!(!bootstrapper.compatible(&probe(Some("0.9.3"))));
    }

    #[test]
    fn bootstrap_retryability_separates_carrier_loss_from_terminal_setup() {
        assert!(BootstrapError::Timeout.is_retryable_carrier_failure());
        assert!(
            BootstrapError::Remote { status: 255, stderr: "network unreachable".into() }
                .is_retryable_carrier_failure()
        );
        assert!(
            !BootstrapError::Configuration("bad command".into()).is_retryable_carrier_failure()
        );
        assert!(!BootstrapError::Missing.is_retryable_carrier_failure());
        assert!(
            !BootstrapError::Remote { status: 2, stderr: "usage".into() }
                .is_retryable_carrier_failure()
        );
    }

    #[test]
    fn native_windows_shell_failure_reports_the_wsl_prerequisite() {
        assert!(windows_command_shell_error(
            "'~' is not recognized as an internal or external command, operable program or batch file."
        ));
        assert!(!BootstrapError::WindowsRequiresWsl.is_retryable_carrier_failure());
        assert!(BootstrapError::WindowsRequiresWsl.to_string().contains("wsl --install"));
    }

    #[test]
    fn option_like_destination_is_rejected_by_bootstrap_config() {
        let Err(error) =
            SshBootstrapper::new(SshBootstrapConfig::defaults("-Fvalidation@localhost"))
        else {
            panic!("option-like SSH bootstrap destination was accepted");
        };
        assert!(
            matches!(error, BootstrapError::Configuration(message) if message.contains("destination"))
        );
    }

    #[test]
    fn legacy_probe_falls_back_to_the_binary_version() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.package_version = "0.1.0".into();
        let bootstrapper = SshBootstrapper::new(config).unwrap();

        assert!(bootstrapper.compatible(&probe(None)));
    }

    #[test]
    fn raw_build_rejects_the_same_version_from_a_different_source_revision() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.package_version = "0.1.0".into();
        config.package_installable = false;
        let bootstrapper = SshBootstrapper::new(config).unwrap();
        let mut installed = serde_json::from_value::<RemoteProbe>(serde_json::json!({
            "app": "cmux-tui",
            "version": "0.1.0",
            "distribution_version": "0.1.0",
            "build_identity": "different-source-revision",
            "remote_protocol": REMOTE_PROTOCOL_VERSION,
            "os": "linux",
            "arch": "x86_64",
        }))
        .unwrap();

        assert!(!bootstrapper.compatible(&installed));
        installed.build_identity = None;
        assert!(!bootstrapper.compatible(&installed));
    }

    #[test]
    fn npm_bootstrap_requires_a_matching_published_package_stamp() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.package_version = "0.9.4".into();
        config.package_installable = true;
        let bootstrapper = SshBootstrapper::new(config).unwrap();
        let mut installed = probe(Some("0.9.4"));

        assert!(!bootstrapper.compatible(&installed));
        installed.npm_bootstrap_version = Some("0.9.3".into());
        assert!(!bootstrapper.compatible(&installed));
        installed.npm_bootstrap_version = Some("0.9.4".into());
        installed.build_identity = Some("different-package-build".into());
        assert!(bootstrapper.compatible(&installed));
    }

    #[test]
    fn shell_unsafe_bootstrap_values_are_rejected() {
        let mut config = SshBootstrapConfig::defaults("host; reboot");
        config.auto_install = false;

        assert!(matches!(SshBootstrapper::new(config), Err(BootstrapError::Configuration(_))));
    }

    #[tokio::test]
    async fn raw_build_refuses_to_claim_an_unpublished_npm_installer() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.package_version = "0.0.0-r2.test".into();
        config.package_installable = false;
        config.local_binary = None;

        let error = SshBootstrapper::new(config).unwrap().install_verified().await.unwrap_err();
        assert!(matches!(
            error,
            BootstrapError::PackageUnavailable(version) if version == "0.0.0-r2.test"
        ));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn raw_build_uploads_the_exact_binary_to_a_matching_platform() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let installed = directory.path().join("installed");
        let staged = directory.path().join("staged");
        let source = directory.path().join("cmux-tui");
        fs::write(&source, b"exact unpublished build").unwrap();
        let uname_os = if std::env::consts::OS == "macos" { "Darwin" } else { "Linux" };
        let uname_arch =
            if std::env::consts::ARCH == "aarch64" { "arm64" } else { std::env::consts::ARCH };
        let probe = serde_json::json!({
            "app": "cmux-tui",
            "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION,
            "build_identity": BUILD_IDENTITY,
            "remote_protocol": REMOTE_PROTOCOL_VERSION,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        });
        fs::write(
            &script,
            format!(
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*)\n    [ -f '{staged}' ] || exit 127\n    printf '%s' '{probe}'\n    ;;\n  *\"remote-probe --json\"*)\n    [ -f '{installed}' ] || exit 127\n    printf '%s' '{probe}'\n    ;;\n  *\"cat > \"*\".cmux-upload-\"*) cat >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) mv '{staged}' '{installed}' ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
                installed = installed.display(),
                staged = staged.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_installable = false;
        config.local_binary = Some(source);
        config.remote_binary = "~/.local/bin/cmux-upload".into();

        assert_eq!(
            SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap(),
            BootstrapOutcome::Installed
        );
        assert_eq!(fs::read(installed).unwrap(), b"exact unpublished build");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn raw_build_keeps_existing_remote_binary_when_staged_probe_is_incompatible() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let installed = directory.path().join("installed");
        let staged = directory.path().join("staged");
        let moved = directory.path().join("moved");
        let source = directory.path().join("cmux-tui");
        fs::write(&installed, b"existing remote binary").unwrap();
        fs::write(&source, b"incompatible unpublished build").unwrap();
        let uname_os = if std::env::consts::OS == "macos" { "Darwin" } else { "Linux" };
        let uname_arch =
            if std::env::consts::ARCH == "aarch64" { "arm64" } else { std::env::consts::ARCH };
        let installed_probe = serde_json::json!({
            "app": "cmux-tui",
            "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION,
            "build_identity": "older-build",
            "remote_protocol": REMOTE_PROTOCOL_VERSION,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        });
        let staged_probe = serde_json::json!({
            "app": "cmux-tui",
            "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION,
            "build_identity": "wrong-upload",
            "remote_protocol": REMOTE_PROTOCOL_VERSION,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        });
        fs::write(
            &script,
            format!(
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*)\n    [ -f '{staged}' ] || exit 127\n    printf '%s' '{staged_probe}'\n    ;;\n  *\"remote-probe --json\"*)\n    [ -f '{installed}' ] || exit 127\n    printf '%s' '{installed_probe}'\n    ;;\n  *\"cat > \"*\".cmux-upload-\"*) cat >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) touch '{moved}'; mv '{staged}' '{installed}' ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
                installed = installed.display(),
                staged = staged.display(),
                moved = moved.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_installable = false;
        config.local_binary = Some(source);
        config.remote_binary = "~/.local/bin/cmux-upload".into();

        let error = SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap_err();
        assert!(matches!(error, BootstrapError::Incompatible { .. }));
        assert_eq!(fs::read(installed).unwrap(), b"existing remote binary");
        assert!(!staged.exists());
        assert!(!moved.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn raw_build_removes_staged_upload_after_upload_stream_failure() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let staged = directory.path().join("staged");
        let source = directory.path().join("cmux-tui");
        fs::write(&source, b"exact unpublished build").unwrap();
        let uname_os = if std::env::consts::OS == "macos" { "Darwin" } else { "Linux" };
        let uname_arch =
            if std::env::consts::ARCH == "aarch64" { "arm64" } else { std::env::consts::ARCH };
        fs::write(
            &script,
            format!(
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\"cat > \"*\".cmux-upload-\"*) cat >'{staged}'; head -c 5000 /dev/zero ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
                staged = staged.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_installable = false;
        config.local_binary = Some(source);
        config.remote_binary = "~/.local/bin/cmux-upload".into();

        let error = SshBootstrapper::new(config).unwrap().install_verified().await.unwrap_err();

        assert!(matches!(error, BootstrapError::OutputLimit { stream: "stdout", .. }));
        assert!(!staged.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn raw_build_removes_staged_upload_after_move_transport_failure() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let staged = directory.path().join("staged");
        let source = directory.path().join("cmux-tui");
        fs::write(&source, b"exact unpublished build").unwrap();
        let uname_os = if std::env::consts::OS == "macos" { "Darwin" } else { "Linux" };
        let uname_arch =
            if std::env::consts::ARCH == "aarch64" { "arm64" } else { std::env::consts::ARCH };
        let probe = serde_json::json!({
            "app": "cmux-tui",
            "version": DISTRIBUTION_VERSION,
            "distribution_version": DISTRIBUTION_VERSION,
            "build_identity": BUILD_IDENTITY,
            "remote_protocol": REMOTE_PROTOCOL_VERSION,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
        });
        fs::write(
            &script,
            format!(
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*) printf '%s' '{probe}' ;;\n  *\"cat > \"*\".cmux-upload-\"*) cat >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) head -c 5000 /dev/zero ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
                staged = staged.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_installable = false;
        config.local_binary = Some(source);
        config.remote_binary = "~/.local/bin/cmux-upload".into();

        let error = SshBootstrapper::new(config).unwrap().install_verified().await.unwrap_err();

        assert!(matches!(error, BootstrapError::OutputLimit { stream: "stdout", .. }));
        assert!(!staged.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn no_install_distinguishes_an_incompatible_binary_from_a_missing_one() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let remote_protocol_version = REMOTE_PROTOCOL_VERSION;
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s' '{{\"app\":\"cmux-tui\",\"version\":\"0.0.1\",\"distribution_version\":\"0.0.1\",\"remote_protocol\":{remote_protocol_version},\"os\":\"linux\",\"arch\":\"x86_64\"}}'\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_version = "9.9.9".into();
        config.auto_install = false;
        let error = SshBootstrapper::new(config).unwrap().ensure_installed().await.unwrap_err();
        assert!(
            matches!(error, BootstrapError::Incompatible { version, .. } if version == "0.0.1")
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn explicit_install_recovers_when_a_legacy_probe_is_unrecognized() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let installed = directory.path().join("installed");
        let installed_path = installed.display();
        let remote_protocol_version = REMOTE_PROTOCOL_VERSION;
        fs::write(
            &script,
            format!(
                "#!/bin/sh\ncase \"$*\" in\n  *\"npx --yes\"*) touch '{installed_path}'; exit 0 ;;\n  *\"remote-probe --json\"*)\n    if [ -f '{installed_path}' ]; then\n      printf '%s' '{{\"app\":\"cmux-tui\",\"version\":\"0.1.0\",\"distribution_version\":\"9.9.9\",\"npm_bootstrap_version\":\"9.9.9\",\"remote_protocol\":{remote_protocol_version},\"os\":\"linux\",\"arch\":\"x86_64\"}}'\n      exit 0\n    fi\n    printf legacy >&2; exit 2 ;;\nesac\nexit 2\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.package_version = "9.9.9".into();
        config.package_installable = true;
        let bootstrap = SshBootstrapper::new(config).unwrap();
        assert!(matches!(bootstrap.probe().await, Err(BootstrapError::Remote { .. })));
        assert_eq!(bootstrap.install_verified().await.unwrap(), BootstrapOutcome::Installed);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn timeout_kills_and_reaps_the_ssh_process() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let pid_file = directory.path().join("pid");
        let pid_file_path = pid_file.display();
        fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s' \"$$\" > '{pid_file_path}'\nexec /bin/sleep 30\n"),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.timeout = Duration::from_secs(5);
        let error = SshBootstrapper::new(config).unwrap().probe().await.unwrap_err();
        assert!(matches!(error, BootstrapError::Timeout));

        let pid = fs::read_to_string(pid_file).unwrap().parse::<libc::pid_t>().unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    }

    #[cfg(unix)]
    async fn assert_oversized_output_is_bounded(stream: &str) {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let pid_file = directory.path().join("pid");
        let pid_file_path = pid_file.display();
        let redirect = match stream {
            "stdout" => "",
            "stderr" => " >&2",
            _ => panic!("unsupported test stream {stream}"),
        };
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s' \"$$\" > '{pid_file_path}'\ni=0\nwhile [ \"$i\" -lt 4097 ]; do\n  printf x{redirect}\n  i=$((i + 1))\ndone\nexec /bin/sleep 30\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.timeout = Duration::from_secs(30);
        let bootstrap = SshBootstrapper::new(config).unwrap();
        let error = tokio::time::timeout(Duration::from_secs(5), bootstrap.probe())
            .await
            .unwrap_or_else(|_| panic!("oversized SSH {stream} was not rejected promptly"))
            .unwrap_err();
        assert_eq!(error.to_string(), format!("SSH bootstrap {stream} exceeded 4096 bytes"),);

        let pid = fs::read_to_string(pid_file).unwrap().parse::<libc::pid_t>().unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn oversized_probe_stdout_kills_and_reaps_ssh() {
        assert_oversized_output_is_bounded("stdout").await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn oversized_ssh_stderr_kills_and_reaps_ssh() {
        assert_oversized_output_is_bounded("stderr").await;
    }
}
