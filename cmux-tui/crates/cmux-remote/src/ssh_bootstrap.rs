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
        if installed.as_ref().is_some_and(|probe| self.same_build(probe).is_ok()) {
            return Ok(BootstrapOutcome::AlreadyInstalled);
        }
        if !self.config.auto_install {
            // Without install rights the remote binary belongs to someone
            // else (a paired server's own installer, an operator). Attach to
            // any build that speaks this link protocol; the daemon's
            // `identify` then judges features. Only a real link
            // incompatibility refuses (cx-mkwc).
            return match installed {
                Some(probe) => match self.attachable(&probe) {
                    Ok(()) => Ok(BootstrapOutcome::AlreadyInstalled),
                    Err(reason) => Err(BootstrapError::incompatible(&probe, reason)),
                },
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
        let Some(actual) = pinned_package_digest(&output.stdout) else {
            self.cleanup_remote_staging(&temporary_dir, deadline).await;
            return Err(BootstrapError::Install {
                status: output.status,
                stderr: format!(
                    "the remote host did not report one SHA-256 digest for {package}; the download was removed"
                ),
            });
        };
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
        if let Err(reason) = self.same_build(&probe) {
            return Err(BootstrapError::incompatible(&probe, reason));
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
        if let Err(reason) = self.same_build(&probe) {
            self.cleanup_remote_staging(temporary_dir, deadline).await;
            return Err(BootstrapError::incompatible(&probe, reason));
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
        if let Err(reason) = self.same_build(&probe) {
            return Err(BootstrapError::incompatible(&probe, reason));
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

    /// The link rule: the remote binary is cmux-tui and frames the link
    /// exactly like this build. This is the only rule when the client may
    /// not install (`--no-install`); the app's `InstallNeed` applies the
    /// same rule before it starts a link.
    fn attachable(&self, probe: &RemoteProbe) -> Result<(), Incompatibility> {
        if probe.app != "cmux-tui" {
            return Err(Incompatibility::WrongApp { app: probe.app.clone() });
        }
        if probe.remote_protocol != REMOTE_PROTOCOL_VERSION {
            return Err(Incompatibility::RemoteProtocol {
                remote: probe.remote_protocol,
                local: REMOTE_PROTOCOL_VERSION,
            });
        }
        Ok(())
    }

    /// The install rule: the remote binary is the exact distribution (and,
    /// for an unpublished build, the exact build) that this client would
    /// install, so an installing client replaces anything else.
    fn same_build(&self, probe: &RemoteProbe) -> Result<(), Incompatibility> {
        self.attachable(probe)?;
        let installed_distribution =
            probe.distribution_version.as_deref().unwrap_or(&probe.version);
        if installed_distribution != self.config.package_version {
            return Err(Incompatibility::Distribution {
                remote: installed_distribution.to_owned(),
                local: self.config.package_version.clone(),
            });
        }
        if self.config.package_installable
            && probe.npm_bootstrap_version.as_deref() != Some(self.config.package_version.as_str())
        {
            return Err(Incompatibility::Distribution {
                remote: format!("npm {}", probe.npm_bootstrap_version.as_deref().unwrap_or("none")),
                local: format!("npm {}", self.config.package_version),
            });
        }
        if !self.config.package_installable
            && probe.build_identity.as_deref() != Some(self.config.build_identity.as_str())
        {
            return Err(Incompatibility::Build {
                remote: probe.build_identity.clone(),
                local: self.config.build_identity.clone(),
            });
        }
        Ok(())
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
         digest=$(sha256sum payload 2>/dev/null || shasum -a 256 payload 2>/dev/null || \
         openssl dgst -sha256 -r payload 2>/dev/null) || \
         {{ echo \"cannot verify the npm package: the remote host has no sha256sum, shasum or openssl\" >&2; exit 1; }}; \
         echo \"{PINNED_DIGEST_MARKER}${{digest%% *}}\""
    )
}

/// Prefix of the one stdout line on which [`pinned_package_command`]
/// reports the payload's SHA-256. npm or the remote shell can print notices
/// on stdout too, so only this line is read.
const PINNED_DIGEST_MARKER: &str = "cmux-sha256 ";

/// The digest [`pinned_package_command`] reported: exactly one marker line
/// carrying 64 lowercase hex digits. Anything else is `None`, and the
/// download is refused.
fn pinned_package_digest(stdout: &[u8]) -> Option<String> {
    let stdout = std::str::from_utf8(stdout).ok()?;
    let mut digests = stdout.lines().filter_map(|line| line.strip_prefix(PINNED_DIGEST_MARKER));
    let digest = digests.next()?.trim_end_matches('\r');
    if digests.next().is_some()
        || digest.len() != 64
        || !digest.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    Some(digest.to_owned())
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
    Incompatible { version: String, build_identity: Option<String>, reason: Incompatibility },
    ChecksumMismatch { package: String },
}

/// Why a remote cmux-tui cannot serve this client. `code()` is the stable,
/// typed name that callers (the app, scripts) match; the text is for people.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incompatibility {
    /// The remote binary is not cmux-tui.
    WrongApp { app: String },
    /// The link framing differs; neither side can talk to the other.
    RemoteProtocol { remote: u8, local: u8 },
    /// An installing client found another distribution version.
    Distribution { remote: String, local: String },
    /// An installing client with an unpublished build found another build.
    Build { remote: Option<String>, local: String },
}

impl Incompatibility {
    pub fn code(&self) -> &'static str {
        match self {
            Self::WrongApp { .. } => "remote-wrong-app",
            Self::RemoteProtocol { remote, local } if remote < local => "remote-protocol-older",
            Self::RemoteProtocol { .. } => "remote-protocol-newer",
            Self::Distribution { .. } => "remote-distribution-mismatch",
            Self::Build { .. } => "remote-build-mismatch",
        }
    }
}

impl BootstrapError {
    fn incompatible(probe: &RemoteProbe, reason: Incompatibility) -> Self {
        Self::Incompatible {
            version: probe.version.clone(),
            build_identity: probe.build_identity.clone(),
            reason,
        }
    }
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
            Self::Incompatible { version, build_identity, reason } => {
                let build = build_identity.as_deref().unwrap_or("unknown");
                match reason {
                    Incompatibility::WrongApp { app } => write!(
                        formatter,
                        "the remote binary is {app}, not cmux-tui; install cmux-tui on the remote host"
                    ),
                    Incompatibility::RemoteProtocol { remote, local } if remote < local => write!(
                        formatter,
                        "remote cmux-tui {version} (build {build}) is older: it speaks remote protocol {remote}, this cmux-tui needs {local}; update the remote cmux-tui"
                    ),
                    Incompatibility::RemoteProtocol { remote, local } => write!(
                        formatter,
                        "remote cmux-tui {version} (build {build}) is newer: it speaks remote protocol {remote}, this cmux-tui speaks {local}; update this cmux-tui"
                    ),
                    Incompatibility::Distribution { remote, local } => write!(
                        formatter,
                        "remote cmux-tui is distribution {remote} (build {build}), this cmux-tui installs {local}; the remote binary does not match this build"
                    ),
                    Incompatibility::Build { remote, local } => write!(
                        formatter,
                        "remote cmux-tui {version} is build {}, this cmux-tui is build {local}; the remote binary does not match this build",
                        remote.as_deref().unwrap_or("unknown")
                    ),
                }?;
                write!(formatter, " [{}]", reason.code())
            }
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
}
