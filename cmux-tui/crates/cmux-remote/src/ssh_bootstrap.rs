use std::fmt;
use std::process::Stdio;
use std::time::Duration;

use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::process::Command;

/// The version of the npm/PyPI distribution that contains this binary. Release
/// workflows stamp it independently from the Rust crate's internal version.
pub const DISTRIBUTION_VERSION: &str = match option_env!("CMUX_TUI_DISTRIBUTION_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};
pub const NPM_BOOTSTRAP_VERSION: Option<&str> = option_env!("CMUX_TUI_NPM_BOOTSTRAP_VERSION");

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
            auto_install: true,
            timeout: Duration::from_secs(60),
        }
    }

    fn validate(&self) -> Result<(), BootstrapError> {
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
        let output =
            self.run_remote([self.config.remote_binary.as_str(), "remote-probe", "--json"]).await?;
        if output.status == 127 || output.status == 126 {
            return Ok(None);
        }
        if output.status != 0 {
            let stderr = String::from_utf8_lossy(&output.stderr);
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
            return Err(BootstrapError::PackageUnavailable(self.config.package_version.clone()));
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
            && probe.remote_protocol == REMOTE_PROTOCOL_VERSION
    }

    async fn run_remote<const N: usize>(
        &self,
        remote_arguments: [&str; N],
    ) -> Result<RemoteOutput, BootstrapError> {
        let mut command = Command::new(&self.config.ssh_binary);
        command.arg("-T");
        if let Some(port) = self.config.port {
            command.arg("-p").arg(port.to_string());
        }
        command.args(&self.config.extra_args).arg(&self.config.destination);
        for argument in remote_arguments {
            command.arg(argument);
        }
        let mut child = command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(BootstrapError::Io)?;
        let mut stdout = child.stdout.take().ok_or_else(|| {
            BootstrapError::Io(std::io::Error::other("SSH stdout pipe is unavailable"))
        })?;
        let mut stderr = child.stderr.take().ok_or_else(|| {
            BootstrapError::Io(std::io::Error::other("SSH stderr pipe is unavailable"))
        })?;
        let mut stdout_bytes = Vec::new();
        let mut stderr_bytes = Vec::new();
        let completion = tokio::time::timeout(self.config.timeout, async {
            let (stdout_result, stderr_result, status_result) = tokio::join!(
                stdout.read_to_end(&mut stdout_bytes),
                stderr.read_to_end(&mut stderr_bytes),
                child.wait(),
            );
            stdout_result?;
            stderr_result?;
            status_result
        })
        .await;
        let status = match completion {
            Ok(result) => result.map_err(BootstrapError::Io)?,
            Err(_) => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                return Err(BootstrapError::Timeout);
            }
        };
        Ok(RemoteOutput {
            status: status.code().unwrap_or(255),
            stdout: stdout_bytes,
            stderr: stderr_bytes,
        })
    }
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
    Missing,
    Remote { status: i32, stderr: String },
    Install { status: i32, stderr: String },
    PackageUnavailable(String),
    Incompatible { version: String, protocol: u8 },
}

impl fmt::Display for BootstrapError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(message) => write!(formatter, "invalid SSH bootstrap: {message}"),
            Self::Io(error) => write!(formatter, "SSH bootstrap failed: {error}"),
            Self::ProbeJson(error) => write!(formatter, "remote probe was invalid: {error}"),
            Self::Timeout => formatter.write_str("SSH bootstrap timed out"),
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
            Self::Incompatible { version, protocol } => write!(
                formatter,
                "remote cmux-tui {version} uses remote protocol {protocol}, expected {REMOTE_PROTOCOL_VERSION}"
            ),
        }
    }
}

impl std::error::Error for BootstrapError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe(distribution_version: Option<&str>) -> RemoteProbe {
        RemoteProbe {
            app: "cmux-tui".into(),
            version: "0.1.0".into(),
            distribution_version: distribution_version.map(str::to_owned),
            npm_bootstrap_version: None,
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
    fn legacy_probe_falls_back_to_the_binary_version() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.package_version = "0.1.0".into();
        let bootstrapper = SshBootstrapper::new(config).unwrap();

        assert!(bootstrapper.compatible(&probe(None)));
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

        let error = SshBootstrapper::new(config).unwrap().install_verified().await.unwrap_err();
        assert!(matches!(
            error,
            BootstrapError::PackageUnavailable(version) if version == "0.0.0-r2.test"
        ));
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
        config.timeout = Duration::from_secs(2);
        let error = SshBootstrapper::new(config).unwrap().probe().await.unwrap_err();
        assert!(matches!(error, BootstrapError::Timeout));

        let pid = fs::read_to_string(pid_file).unwrap().parse::<libc::pid_t>().unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
        assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    }
}
