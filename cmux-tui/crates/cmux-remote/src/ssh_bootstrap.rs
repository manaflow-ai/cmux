use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use flate2::Compression;
use flate2::read::GzEncoder;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{Mutex, mpsc};

use crate::ssh_args::background_ssh_arguments;

const SSH_BOOTSTRAP_OUTPUT_LIMIT: usize = 4_096;
/// Printed by the staging command when the remote can decompress an upload.
const GZIP_UPLOAD_MARKER: &str = "cmux-upload:gzip";
const UPLOAD_CHUNK_BYTES: usize = 256 * 1024;
// Cleanup must not turn a bounded bootstrap timeout into an unbounded wait.
const SSH_BOOTSTRAP_REAP_TIMEOUT: Duration = Duration::from_secs(2);
// A process-wide counter prevents concurrent unpublished uploads from
// selecting the same predictable staging directory.
static NEXT_UPLOAD_NONCE: AtomicU64 = AtomicU64::new(1);
// Bootstrap calls create a fresh SshBootstrapper on each route/reconnect
// attempt. Keep coordination outside the instance so two concurrent attempts
// cannot probe, replace, and verify the same remote binary independently.
type InstallLock = Arc<Mutex<()>>;
static INSTALL_LOCKS: OnceLock<StdMutex<HashMap<String, Weak<Mutex<()>>>>> = OnceLock::new();

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
        if self.remote_binary.starts_with('-') {
            return Err(BootstrapError::Configuration(
                "remote binary cannot begin with an option prefix".into(),
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
        let lock = self.install_lock();
        let _guard = lock.lock().await;
        self.ensure_installed_locked().await
    }

    async fn ensure_installed_locked(&self) -> Result<BootstrapOutcome, BootstrapError> {
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

        self.install_verified_locked().await
    }

    /// Installs the pinned distribution even when an older binary cannot
    /// answer `remote-probe`. This is reserved for an explicit upgrade.
    pub async fn install_verified(&self) -> Result<BootstrapOutcome, BootstrapError> {
        let lock = self.install_lock();
        let _guard = lock.lock().await;
        self.install_verified_locked().await
    }

    async fn install_verified_locked(&self) -> Result<BootstrapOutcome, BootstrapError> {
        if !self.config.package_installable {
            return self.install_local_binary().await;
        }
        let pinned = match self.config.local_binary.as_deref() {
            Some(executable) => crate::ssh_artifacts::PinnedArtifacts::load(
                executable,
                &self.config.build_identity,
            )?,
            None => None,
        };
        if let Some(pinned) = pinned {
            let remote = self.remote_platform().await?;
            if let Some(platform) = pinned.platform(&remote.os, &remote.arch)? {
                return self.install_pinned_package(&platform).await;
            }
        }
        self.install_unpinned_package().await
    }

    /// Downloads the remote platform's npm package without running any of
    /// its code, checks the binary against the digest this build pins, and
    /// only then probes and installs it. A mismatch removes the download.
    async fn install_pinned_package(
        &self,
        platform: &crate::ssh_artifacts::PinnedPlatform,
    ) -> Result<BootstrapOutcome, BootstrapError> {
        let deadline = Instant::now() + self.config.timeout;
        let temporary_dir = self.temporary_upload_path();
        let temporary = format!("{temporary_dir}/payload");
        self.create_remote_staging(self.remote_parent(), &temporary_dir).await?;
        let package = format!("{}@{}", platform.npm_package, self.config.package_version);
        let command = pinned_package_command(&temporary_dir, &package);
        let output = match self.run_remote_script(&command).await {
            Ok(output) => output,
            Err(error) => {
                self.cleanup_remote_staging(&temporary_dir, deadline).await;
                return Err(error);
            }
        };
        if output.status != 0 {
            self.cleanup_remote_staging(&temporary_dir, deadline).await;
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        let actual = String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        if actual != platform.sha256 {
            self.cleanup_remote_staging(&temporary_dir, deadline).await;
            return Err(BootstrapError::ChecksumMismatch { package });
        }
        self.promote_staged(&temporary, &temporary_dir, deadline).await
    }

    /// Builds without a pinned manifest (for example, a PyPI wheel or a
    /// custom build stamped with an npm version) still install through npx.
    /// Only the probe vouches for that binary; install scripts never run.
    async fn install_unpinned_package(&self) -> Result<BootstrapOutcome, BootstrapError> {
        let npm_package = &self.config.npm_package;
        let package_version = &self.config.package_version;
        let package = format!("{npm_package}@{package_version}");
        let output = self
            .run_remote([
                "npx",
                "--yes",
                "--ignore-scripts",
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

    fn install_lock(&self) -> InstallLock {
        let key = format!(
            "{}\0{}\0{:?}\0{:?}\0{}",
            self.config.ssh_binary,
            self.config.destination,
            self.config.port,
            self.config.extra_args,
            self.config.remote_binary,
        );
        let locks = INSTALL_LOCKS.get_or_init(|| StdMutex::new(HashMap::new()));
        let mut locks = locks.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        locks.retain(|_, lock| lock.strong_count() > 0);
        if let Some(lock) = locks.get(&key).and_then(Weak::upgrade) {
            return lock;
        }
        let lock = Arc::new(Mutex::new(()));
        locks.insert(key, Arc::downgrade(&lock));
        lock
    }

    async fn install_local_binary(&self) -> Result<BootstrapOutcome, BootstrapError> {
        let deadline = Instant::now() + self.config.timeout;
        let source = self.config.local_binary.as_deref().ok_or_else(|| {
            BootstrapError::PackageUnavailable(self.config.package_version.clone())
        })?;
        let remote = self.remote_platform().await?;
        let local = Platform::local();
        let artifact = crate::ssh_artifacts::payload(
            source,
            &self.config.build_identity,
            &remote.os,
            &remote.arch,
        )?;
        if artifact.is_none() && !local.compatible_with(&remote) {
            return Err(BootstrapError::LocalBinaryIncompatible {
                local: local.display(),
                remote: remote.display(),
            });
        }
        let source = artifact.as_deref().unwrap_or(source);
        let temporary_dir = self.temporary_upload_path();
        let temporary = format!("{temporary_dir}/payload");
        // Create the directory in a separate, exclusive command. Cleanup is
        // allowed only after this command reports success, which proves that
        // this upload owns the staging directory. A failed or timed-out mkdir
        // is intentionally left untouched because ownership is unknown.
        let encoding = self.create_remote_staging(self.remote_parent(), &temporary_dir).await?;
        let command = upload_command(&temporary, encoding);
        let output = match self.run_remote_with_input(&command, source, encoding).await {
            Ok(output) => output,
            Err(error) => {
                self.cleanup_remote_staging(&temporary_dir, deadline).await;
                return Err(error);
            }
        };
        if output.status != 0 {
            self.cleanup_remote_staging(&temporary_dir, deadline).await;
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        self.promote_staged(&temporary, &temporary_dir, deadline).await
    }

    fn remote_parent(&self) -> &str {
        self.config
            .remote_binary
            .rsplit_once('/')
            .map_or(".", |(parent, _)| if parent.is_empty() { "/" } else { parent })
    }

    /// Probes a verified staged binary, then moves it over the installed one.
    /// A staged binary that fails the probe is removed and never installed.
    async fn promote_staged(
        &self,
        temporary: &str,
        temporary_dir: &str,
        deadline: Instant,
    ) -> Result<BootstrapOutcome, BootstrapError> {
        let probe = match self.probe_binary(temporary).await {
            Ok(Some(probe)) => probe,
            Ok(None) => {
                self.cleanup_remote_staging(temporary_dir, deadline).await;
                return Err(BootstrapError::Install {
                    status: 126,
                    stderr: "staged binary could not run remote-probe".into(),
                });
            }
            Err(error) => {
                self.cleanup_remote_staging(temporary_dir, deadline).await;
                return Err(error);
            }
        };
        if !self.compatible(&probe) {
            self.cleanup_remote_staging(temporary_dir, deadline).await;
            return Err(BootstrapError::Incompatible {
                version: probe.version,
                protocol: probe.remote_protocol,
            });
        }
        // The move also removes the now-empty staging directory, so a
        // successful install spends no extra round trip on cleanup.
        let command = format!(
            "mv -f -- {temporary} {} && {{ rmdir -- {temporary_dir} 2>/dev/null || true; }}",
            self.config.remote_binary
        );
        let output = match self.run_remote_script(&command).await {
            Ok(output) => output,
            Err(error) => {
                self.cleanup_remote_staging(temporary_dir, deadline).await;
                return Err(error);
            }
        };
        if output.status != 0 {
            self.cleanup_remote_staging(temporary_dir, deadline).await;
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        let Some(probe) = self.probe().await? else {
            return Err(BootstrapError::Install {
                status: 0,
                stderr: "install completed but the remote binary is absent".into(),
            });
        };
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
        let nonce = NEXT_UPLOAD_NONCE.fetch_add(1, Ordering::Relaxed);
        format!("{}.cmux-upload-{}-{now}-{nonce}", self.config.remote_binary, std::process::id())
    }

    /// Creates the parent and the exclusive staging directory in one round
    /// trip and reports whether the remote can decompress a gzip upload. The
    /// status is zero only when this command created the staging directory:
    /// the decompressor check cannot fail.
    async fn create_remote_staging(
        &self,
        parent: &str,
        temporary_dir: &str,
    ) -> Result<UploadEncoding, BootstrapError> {
        let command = format!(
            "mkdir -p -- {parent} && mkdir -m 700 -- {temporary_dir} && \
             {{ command -v gzip >/dev/null 2>&1 && echo {GZIP_UPLOAD_MARKER}; true; }}"
        );
        let output = self.run_remote_script(&command).await?;
        if output.status != 0 {
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: sanitize(&String::from_utf8_lossy(&output.stderr)),
            });
        }
        let gzip = String::from_utf8_lossy(&output.stdout)
            .lines()
            .any(|line| line.trim() == GZIP_UPLOAD_MARKER);
        Ok(if gzip { UploadEncoding::Gzip } else { UploadEncoding::Raw })
    }

    async fn cleanup_remote_staging(&self, path: &str, deadline: Instant) {
        // Remove only the payload written by this protocol, then remove the
        // directory only when it is empty. Never recurse through a staging
        // path: a collision or an interrupted prior upload must retain its
        // unrelated contents.
        let payload = format!("{path}/payload");
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }
        // A transport or timeout error leaves ownership uncertain. Do not
        // spend another full SSH timeout on rmdir in that case. A completed
        // command with a non-zero status is different: the transport worked,
        // so the directory removal can still be attempted within the same
        // remaining deadline.
        let payload_result =
            self.run_remote_with_timeout(["rm", "-f", "--", payload.as_str()], remaining).await;
        match payload_result {
            // OpenSSH uses 255 for a transport failure. Treat it like an
            // error so a second cleanup command cannot consume the budget or
            // run against an uncertain connection.
            Ok(output) if output.status != 255 => {}
            _ => return,
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return;
        }
        let _ = self.run_remote_with_timeout(["rmdir", "--", path], remaining).await;
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
        self.run_remote_with_timeout(remote_arguments, self.config.timeout).await
    }

    /// Runs a POSIX `sh` script on the remote. OpenSSH hands the command
    /// string to the user's login shell, which may be fish or tcsh, so any
    /// script with `$?`, `{ ...; }`, `[ ... ]`, subshells or redirections
    /// must go through `sh -c`. Plain argument lists that every shell parses
    /// the same way keep using [`Self::run_remote`].
    async fn run_remote_script(&self, script: &str) -> Result<RemoteOutput, BootstrapError> {
        let command = posix_shell_command(script);
        self.run_remote([command.as_str()]).await
    }

    async fn run_remote_with_timeout<const N: usize>(
        &self,
        remote_arguments: [&str; N],
        timeout: Duration,
    ) -> Result<RemoteOutput, BootstrapError> {
        let mut command = Command::new(&self.config.ssh_binary);
        self.configure_ssh_command(&mut command);
        for argument in remote_arguments {
            command.arg(argument);
        }
        command.stdin(Stdio::null());
        self.run_child_with_timeout(command, timeout, None).await
    }

    fn configure_ssh_command(&self, command: &mut Command) {
        // Forwarding stays as configured unless `extra_args` pin
        // `ControlMaster=no`: otherwise this run can become the shared master
        // that interactive sessions reuse.
        command.args(background_ssh_arguments(
            self.config.port,
            &self.config.extra_args,
            &self.config.destination,
        ));
    }

    /// Runs one ssh command. With `compressed_input`, that file is gzipped
    /// on a blocking thread and streamed to the command's stdin while the
    /// upload is in flight.
    async fn run_child_with_timeout(
        &self,
        mut command: Command,
        timeout: Duration,
        compressed_input: Option<&Path>,
    ) -> Result<RemoteOutput, BootstrapError> {
        if compressed_input.is_some() {
            command.stdin(Stdio::piped());
        }
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
        let input = compressed_input.map(|path| (child.stdin.take(), compress_upload(path)));
        let started = Instant::now();
        let completion = tokio::time::timeout(timeout, async {
            // Drain both pipes concurrently so either stream can fill without
            // blocking the other stream or the child exit observation.
            tokio::try_join!(
                read_bounded(stdout, "stdout"),
                read_bounded(stderr, "stderr"),
                write_upload(input),
                async { child.wait().await.map_err(BootstrapError::Io) },
            )
        })
        .await;
        let (stdout, stderr, sent, status) = match completion {
            Ok(Ok(result)) => result,
            Ok(Err(error)) => {
                terminate_and_reap(&mut child).await;
                // Preserve the bootstrap contract when the timeout and an
                // I/O error race under scheduler load. Once the budget has
                // expired, callers must see Timeout regardless of which
                // cancelled pipe reports first.
                return Err(if started.elapsed() >= timeout {
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
        let status = status.code().unwrap_or(255);
        // A command that exits cleanly without reading the whole upload must
        // not pass for an install. A failed one reports its own status.
        if status == 0 && !sent {
            return Err(BootstrapError::Io(std::io::Error::other(
                "SSH closed the upload before the payload was sent",
            )));
        }
        Ok(RemoteOutput { status, stdout, stderr })
    }

    async fn run_remote_with_input(
        &self,
        remote_command: &str,
        source: &Path,
        encoding: UploadEncoding,
    ) -> Result<RemoteOutput, BootstrapError> {
        let mut command = Command::new(&self.config.ssh_binary);
        self.configure_ssh_command(&mut command);
        command.arg(posix_shell_command(remote_command));
        match encoding {
            UploadEncoding::Raw => {
                let source = std::fs::File::open(source).map_err(BootstrapError::Io)?;
                command.stdin(Stdio::from(source));
                self.run_child_with_timeout(command, self.config.timeout, None).await
            }
            UploadEncoding::Gzip => {
                self.run_child_with_timeout(command, self.config.timeout, Some(source)).await
            }
        }
    }
}

/// Wraps a POSIX script as one `sh -c '<script>'` command that any remote
/// login shell (sh, bash, zsh, fish, tcsh) parses as the same three words.
/// Single quotes keep `$`, `{`, `[`, `;` and redirections away from the login
/// shell. An embedded quote becomes `'\''`, which each of those shells reads
/// as a literal quote. Scripts must not contain backslashes (fish unescapes
/// them inside single quotes), newlines (tcsh rejects them inside quotes) or
/// `!` (csh history), so every caller builds its script from validated,
/// shell-safe values on one line.
fn posix_shell_command(script: &str) -> String {
    debug_assert!(
        !script.contains(['\\', '\n', '!']),
        "remote script is not portable across login shells: {script}"
    );
    format!("sh -c '{}'", script.replace('\'', r"'\''"))
}

/// How the payload travels to the remote staging file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum UploadEncoding {
    Raw,
    /// gzip stream, decompressed remotely. The binary is about 2.5 times
    /// smaller on the wire, and gzip's CRC rejects a truncated upload.
    Gzip,
}

/// Build the remote upload command after the caller has created the staging
/// directory exclusively with mode 0700. `set -C` plus an explicit descriptor
/// opens the payload with no-clobber semantics, so a same-UID process cannot
/// redirect the stream through a planted payload symlink.
fn upload_command(temporary: &str, encoding: UploadEncoding) -> String {
    let writer = match encoding {
        UploadEncoding::Raw => "cat",
        UploadEncoding::Gzip => "gzip -dc",
    };
    // The validated temporary path is rooted under the configured remote
    // binary directory and cannot begin with `-`. macOS chmod does not accept
    // the GNU `--` separator, so keep this command portable across Unix hosts.
    format!("umask 077; (set -C; exec 3> {temporary} && {writer} >&3) && chmod 755 {temporary}")
}

/// Build the remote command that downloads a published platform package into
/// the exclusive staging directory and prints the extracted binary's SHA-256.
/// `npm pack` only fetches the tarball: no package code or install script
/// runs before the caller compares the digest. The package name and version
/// are validated and unscoped, so the tarball name is known in advance and no
/// glob is needed.
fn pinned_package_command(temporary_dir: &str, package: &str) -> String {
    let tarball = format!("{}.tgz", package.replacen('@', "-", 1));
    format!(
        "umask 077; cd {temporary_dir} || exit 1; \
         npm pack --ignore-scripts --silent {package} >/dev/null && \
         tar -xzf {tarball} package/bin/cmux-tui && \
         mv package/bin/cmux-tui payload && chmod 755 payload; rc=$?; \
         rm -f {tarball} package/bin/cmux-tui; rmdir package/bin package 2>/dev/null; \
         [ \"$rc\" -eq 0 ] || exit \"$rc\"; \
         sha256sum payload 2>/dev/null || shasum -a 256 payload 2>/dev/null || \
         openssl dgst -sha256 -r payload 2>/dev/null || \
         {{ echo \"cannot verify the npm package: the remote host has no sha256sum, shasum or openssl\" >&2; exit 1; }}"
    )
}

/// Compressed upload bytes, in order, or the read error that ended them.
type UploadChunks = mpsc::Receiver<std::io::Result<Vec<u8>>>;

/// Compresses `source` on a blocking thread into bounded chunks. Dropping the
/// receiver stops the compressor at its next chunk.
fn compress_upload(source: &Path) -> UploadChunks {
    let (sender, receiver) = mpsc::channel(4);
    let source = source.to_path_buf();
    tokio::task::spawn_blocking(move || {
        use std::io::Read;

        let file = match std::fs::File::open(&source) {
            Ok(file) => file,
            Err(error) => {
                let _ = sender.blocking_send(Err(error));
                return;
            }
        };
        let mut encoder = GzEncoder::new(std::io::BufReader::new(file), Compression::default());
        loop {
            let mut chunk = Vec::with_capacity(UPLOAD_CHUNK_BYTES);
            match (&mut encoder).take(UPLOAD_CHUNK_BYTES as u64).read_to_end(&mut chunk) {
                Ok(0) => return,
                Ok(_) => {
                    if sender.blocking_send(Ok(chunk)).is_err() {
                        return;
                    }
                }
                Err(error) => {
                    let _ = sender.blocking_send(Err(error));
                    return;
                }
            }
        }
    });
    receiver
}

/// Writes a compressed upload to ssh's stdin and closes it. Reports whether
/// every byte was written: a remote that exits early closes the pipe, and its
/// own status and stderr then explain the failure better than the write error.
async fn write_upload(
    input: Option<(Option<ChildStdin>, UploadChunks)>,
) -> Result<bool, BootstrapError> {
    let Some((stdin, mut chunks)) = input else {
        return Ok(true);
    };
    let Some(mut stdin) = stdin else {
        return Err(BootstrapError::Io(std::io::Error::other("SSH stdin pipe is unavailable")));
    };
    while let Some(chunk) = chunks.recv().await {
        let chunk = chunk.map_err(BootstrapError::Io)?;
        if stdin.write_all(&chunk).await.is_err() {
            return Ok(false);
        }
    }
    Ok(stdin.shutdown().await.is_ok())
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
    ChecksumMismatch { package: String },
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
            Self::ChecksumMismatch { package } => write!(
                formatter,
                "npm package {package} does not match the SHA-256 checksum this cmux-tui build pins; the download was removed"
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

    /// A FIFO no writer ever opens. A fake ssh that ends in `exec < fifo`
    /// blocks in the shell's own open() forever, so the hang needs no second
    /// process; `exec /bin/sleep` here used to fail under full-suite fork
    /// pressure, exit the fake early, and turn the expected error into a
    /// different variant (issue #10384).
    #[cfg(unix)]
    fn make_blocking_fifo(directory: &Path) -> String {
        use std::os::unix::ffi::OsStrExt;

        let fifo = directory.join("block");
        let path = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        fifo.to_string_lossy().into_owned()
    }

    /// Runs the real staging command in `sh` against a stand-in `npm` that
    /// only writes a tarball, as `npm pack` does. The command must extract
    /// the binary without running it, report its SHA-256 and leave nothing
    /// but the payload behind.
    #[cfg(unix)]
    #[test]
    fn pinned_package_command_extracts_and_hashes_without_running_the_package() {
        use sha2::{Digest, Sha256};
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let bin = directory.path().join("fake-bin");
        let source = directory.path().join("source");
        let staging = directory.path().join("staging");
        fs::create_dir_all(source.join("package/bin")).unwrap();
        fs::create_dir(&bin).unwrap();
        fs::create_dir(&staging).unwrap();
        let marker = directory.path().join("package-ran");
        let binary = format!("#!/bin/sh\ntouch '{}'\n", marker.display());
        fs::write(source.join("package/bin/cmux-tui"), &binary).unwrap();
        fs::set_permissions(source.join("package/bin/cmux-tui"), fs::Permissions::from_mode(0o755))
            .unwrap();
        fs::write(source.join("package/package.json"), b"{}").unwrap();
        fs::write(
            bin.join("npm"),
            format!(
                "#!/bin/sh\n[ \"$1 $2 $3 $4\" = 'pack --ignore-scripts --silent cmux-tui-linux-arm64@9.9.9' ] || exit 9\ntar -czf cmux-tui-linux-arm64-9.9.9.tgz -C '{}' package\n",
                source.display()
            ),
        )
        .unwrap();
        fs::set_permissions(bin.join("npm"), fs::Permissions::from_mode(0o755)).unwrap();

        let command =
            pinned_package_command(&staging.to_string_lossy(), "cmux-tui-linux-arm64@9.9.9");
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(&command)
            .env("PATH", format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default()))
            .output()
            .unwrap();

        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let reported = String::from_utf8_lossy(&output.stdout);
        assert_eq!(
            reported.split_whitespace().next(),
            Some(format!("{:x}", Sha256::digest(binary.as_bytes())).as_str())
        );
        let entries = fs::read_dir(&staging)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(entries, ["payload"]);
        assert_eq!(fs::read(staging.join("payload")).unwrap(), binary.as_bytes());
        assert_eq!(
            fs::metadata(staging.join("payload")).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert!(!marker.exists(), "the downloaded package ran before verification");
    }

    /// The login shell must see exactly `sh`, `-c` and the unchanged script,
    /// including a script that itself contains single quotes.
    #[cfg(unix)]
    #[test]
    fn posix_shell_command_hands_sh_the_exact_script() {
        let script = "rc=0; { printf '%s|' \"a b\" $rc; }; [ \"$rc\" -eq 0 ] || exit 1";
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!(
                "set -- {}; printf '%s\\n' \"$#\" \"$1\" \"$2\" \"$3\"",
                posix_shell_command(script)
            ))
            .output()
            .unwrap();
        assert_eq!(String::from_utf8_lossy(&output.stdout), format!("3\nsh\n-c\n{script}\n"));
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(posix_shell_command(script))
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"a b|0|");
    }

    #[test]
    fn upload_command_writes_only_after_exclusive_directory_creation() {
        let payload = "~/.local/bin/.cmux-upload-test/payload";
        let command = upload_command(payload, UploadEncoding::Raw);
        assert!(command.contains("set -C; exec 3> ~/.local/bin/.cmux-upload-test/payload"));
        assert!(command.contains("cat >&3"));
        assert!(command.contains("chmod 755 ~/.local/bin/.cmux-upload-test/payload"));
        assert!(!command.contains("cat > ~/.local/bin"));
        let command = upload_command(payload, UploadEncoding::Gzip);
        assert!(command.contains("set -C; exec 3> ~/.local/bin/.cmux-upload-test/payload"));
        assert!(command.contains("gzip -dc >&3"));
        assert!(command.contains("chmod 755 ~/.local/bin/.cmux-upload-test/payload"));
    }

    #[test]
    fn temporary_upload_paths_are_unique_within_one_process() {
        let bootstrapper = SshBootstrapper::new(SshBootstrapConfig::defaults("host")).unwrap();
        let first = bootstrapper.temporary_upload_path();
        let second = bootstrapper.temporary_upload_path();

        assert_ne!(first, second);
        assert!(first.contains(".cmux-upload-"));
        assert!(second.contains(".cmux-upload-"));
    }

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

    /// Every bootstrap step starts `ssh` the same way. This run is pinned to
    /// `ControlMaster=no`, so it cannot become a shared master and turns
    /// forwarding off.
    #[cfg(unix)]
    #[tokio::test]
    async fn bootstrap_uses_hardened_ssh_argv() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let log = directory.path().join("argv");
        let script = directory.path().join("ssh");
        fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nexit 127\n", log.display()),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = SshBootstrapConfig::defaults("alice@example.com");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.port = Some(2222);
        config.extra_args = vec!["-o".into(), "ControlMaster=no".into()];

        assert_eq!(SshBootstrapper::new(config).unwrap().probe().await.unwrap(), None);
        assert_eq!(
            fs::read_to_string(&log).unwrap().lines().collect::<Vec<_>>(),
            [
                "-T",
                "-p",
                "2222",
                "-o",
                "ForwardAgent=no",
                "-o",
                "ForwardX11=no",
                "-o",
                "ClearAllForwardings=yes",
                "-o",
                "ControlMaster=no",
                "--",
                "alice@example.com",
                "~/.local/bin/cmux-tui",
                "remote-probe",
                "--json",
            ]
        );
    }

    #[test]
    fn option_like_remote_binary_is_rejected_by_bootstrap_config() {
        let mut config = SshBootstrapConfig::defaults("host");
        config.remote_binary = "-bad/path".into();

        assert!(matches!(
            SshBootstrapper::new(config),
            Err(BootstrapError::Configuration(message)) if message.contains("remote binary")
        ));
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
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\"mkdir -p \"*|*\"mkdir -m 700 \"*) exit 0 ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*)\n    [ -f '{staged}' ] || exit 127\n    printf '%s' '{probe}'\n    ;;\n  *\"remote-probe --json\"*)\n    [ -f '{installed}' ] || exit 127\n    printf '%s' '{probe}'\n    ;;\n  *\"exec 3> \"*\".cmux-upload-\"*) cat >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) mv '{staged}' '{installed}' ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
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

    /// A first connect uploads tens of megabytes over the user's own link, so
    /// the payload must travel compressed when the remote can decompress it,
    /// and the install must not spend a round trip per shell step.
    #[cfg(unix)]
    #[tokio::test]
    async fn raw_build_streams_a_compressed_upload_in_few_round_trips() {
        use std::fs;
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let script = directory.path().join("ssh");
        let installed = directory.path().join("installed");
        let staged = directory.path().join("staged");
        let wire = directory.path().join("wire");
        let commands = directory.path().join("commands");
        let source = directory.path().join("cmux-tui");
        let payload = b"compressible unpublished build\n".repeat(64 * 1024);
        fs::write(&source, &payload).unwrap();
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
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >>'{commands}'\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\"mkdir -p \"*|*\"mkdir -m 700 \"*) command -v gzip >/dev/null 2>&1 && printf '%s\\n' 'cmux-upload:gzip' ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*)\n    [ -f '{staged}' ] || exit 127\n    printf '%s' '{probe}'\n    ;;\n  *\"remote-probe --json\"*)\n    [ -f '{installed}' ] || exit 127\n    printf '%s' '{probe}'\n    ;;\n  *\"exec 3> \"*\".cmux-upload-\"*\"gzip -dc\"*) tee '{wire}' | gzip -dc >'{staged}' ;;\n  *\"exec 3> \"*\".cmux-upload-\"*) tee '{wire}' >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) mv '{staged}' '{installed}' ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *\"rmdir \"*\".cmux-upload-\"*) exit 0 ;;\n  *) exit 2 ;;\nesac\n",
                commands = commands.display(),
                installed = installed.display(),
                staged = staged.display(),
                wire = wire.display(),
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
        assert_eq!(fs::read(installed).unwrap(), payload);
        let sent = fs::read(wire).unwrap();
        assert_eq!(sent.get(..2), Some(&[0x1f, 0x8b][..]), "upload was not gzip");
        assert!(sent.len() * 10 < payload.len(), "upload sent {} bytes", sent.len());
        // probe, platform, staging, upload, staged probe, move, final probe.
        let commands = fs::read_to_string(commands).unwrap();
        assert!(commands.lines().count() <= 7, "install ran:\n{commands}");
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
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\"mkdir -p \"*|*\"mkdir -m 700 \"*) exit 0 ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*)\n    [ -f '{staged}' ] || exit 127\n    printf '%s' '{staged_probe}'\n    ;;\n  *\"remote-probe --json\"*)\n    [ -f '{installed}' ] || exit 127\n    printf '%s' '{installed_probe}'\n    ;;\n  *\"exec 3> \"*\".cmux-upload-\"*) cat >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) touch '{moved}'; mv '{staged}' '{installed}' ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
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
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\"mkdir -p \"*|*\"mkdir -m 700 \"*) exit 0 ;;\n  *\"exec 3> \"*\".cmux-upload-\"*) cat >'{staged}'; head -c 5000 /dev/zero ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
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
                "#!/bin/sh\ncase \"$*\" in\n  *\"uname -s -m\"*) printf '%s\\n' '{uname_os} {uname_arch}' ;;\n  *\"mkdir -p \"*|*\"mkdir -m 700 \"*) exit 0 ;;\n  *\".cmux-upload-\"*\" remote-probe --json\"*) printf '%s' '{probe}' ;;\n  *\"exec 3> \"*\".cmux-upload-\"*) cat >'{staged}' ;;\n  *\"mv -f \"*\".cmux-upload-\"*) head -c 5000 /dev/zero ;;\n  *\"rm -f \"*\".cmux-upload-\"*) rm -f '{staged}' ;;\n  *) exit 2 ;;\nesac\n",
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
        let fifo_path = make_blocking_fifo(directory.path());
        fs::write(
            &script,
            format!("#!/bin/sh\nprintf '%s' \"$$\" > '{pid_file_path}'\nexec < '{fifo_path}'\n"),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = SshBootstrapConfig::defaults("host");
        config.ssh_binary = script.to_string_lossy().into_owned();
        config.timeout = Duration::from_secs(5);
        let error = SshBootstrapper::new(config).unwrap().probe().await.unwrap_err();
        assert!(
            matches!(error, BootstrapError::Timeout),
            "a hung ssh must surface BootstrapError::Timeout, got {error:?}"
        );

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
        let fifo_path = make_blocking_fifo(directory.path());
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s' \"$$\" > '{pid_file_path}'\ni=0\nwhile [ \"$i\" -lt 4097 ]; do\n  printf x{redirect}\n  i=$((i + 1))\ndone\nexec < '{fifo_path}'\n"
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
