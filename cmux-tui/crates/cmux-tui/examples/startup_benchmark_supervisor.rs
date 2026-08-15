mod startup_benchmark_protocol;
#[cfg(windows)]
mod startup_benchmark_windows_diagnostic;

use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};

use anyhow::{Context, Result, bail};
#[cfg(windows)]
use cmux_startup_bootstrap::{
    BOOTSTRAP_SCHEMA_VERSION, BootstrapChildStage, BootstrapConfig, BootstrapLaunchEvidence,
    BootstrapMessage, BootstrapProductLaunch, NativeEntryCheckpointStage,
    decode_native_entry_checkpoint, encode_arm, encode_config, encode_product_handles_adopted,
    read_event,
};
use cmux_tui_core::platform::transport;
#[cfg(any(target_os = "linux", windows))]
use sha2::{Digest, Sha256};
#[cfg(any(target_os = "macos", windows))]
use startup_benchmark_protocol::CONTROL_TIMEOUT;
#[cfg(target_os = "macos")]
use startup_benchmark_protocol::macos_account_identity;
#[cfg(windows)]
use startup_benchmark_protocol::{
    BOOTSTRAP_CLEANUP_TIMEOUT, BOOTSTRAP_FAILURE_SCHEMA_VERSION, BOOTSTRAP_STARTUP_TIMEOUT,
    BootstrapCleanupCheckpoint, BootstrapCleanupResult, BootstrapFailureCheckpoint,
    BootstrapObservedEvent, BootstrapProductLifecycleEvidence, BootstrapStage,
    BootstrapStartupTrace, SECURITY_PREPARATION_TIMEOUT, failure_line, product_exit_line,
    product_started_line, setup_line,
};
use startup_benchmark_protocol::{
    STARTUP_LINE_TIMEOUT, TimingSink, arm_line, read_control_line, ready_line, write_control_line,
};

#[derive(Debug, Clone)]
struct Launch {
    control: PathBuf,
    timing: PathBuf,
    nonce: String,
    fixture_root: PathBuf,
    target: PathBuf,
    target_sha256: String,
    supervisor_sha256: String,
    windows_bootstrap_binary: PathBuf,
    windows_bootstrap_sha256: String,
    product_args: Vec<String>,
    inner: bool,
    prove_private_job: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("cmux-tui startup supervisor: {error:#}");
        std::process::exit(125);
    }
}

fn run() -> Result<()> {
    let values = env::args().skip(1).collect::<Vec<_>>();
    #[cfg(windows)]
    if values.first().map(String::as_str) == Some("--windows-hang-diagnostic") {
        return platform::run_hang_diagnostic(&values[1..]);
    }
    let launch = parse_args(values.into_iter())?;
    validate_launch(&launch)?;
    if launch.inner {
        return run_inner(launch);
    }
    let status = platform::run_outer(&launch)?;
    match status.code() {
        Some(code) => std::process::exit(code),
        None => bail!("sandbox process ended without an exit code"),
    }
}

fn run_inner(launch: Launch) -> Result<()> {
    let timing = TimingSink::open(&launch.timing, &launch.nonce)?;
    let mut control = transport::connect(&launch.control)
        .with_context(|| format!("connect control socket {}", launch.control.display()))?;
    control.set_read_timeout(Some(STARTUP_LINE_TIMEOUT))?;
    control.set_write_timeout(Some(STARTUP_LINE_TIMEOUT))?;
    fs::remove_file(&launch.timing).context("unlink live timing page")?;
    fs::remove_file(&launch.control).context("unlink live control socket")?;
    write_control_line(&mut control, &ready_line(&launch.nonce))?;
    let arm = read_control_line(&mut control)?;
    if arm != arm_line(&launch.nonce).trim_end() {
        bail!("control ARM identity mismatch");
    }
    accept_already_closed_control(control.shutdown(std::net::Shutdown::Both))?;
    drop(control);

    let mut command = Command::new(&launch.target);
    command.args(&launch.product_args);
    command.current_dir(&launch.fixture_root);
    for key in [
        "CMUX_BENCH_LINUX_BWRAP",
        "CMUX_BENCH_LINUX_SUDO",
        "CMUX_BENCH_LINUX_UID",
        "CMUX_BENCH_LINUX_GID",
        "CMUX_BENCH_MACOS_ACCOUNT_PREFIX",
        "CMUX_BENCH_MACOS_GROUP",
        "CMUX_BENCH_MACOS_GID",
        "CMUX_BENCH_MACOS_UID_BASE",
        "CMUX_BENCH_MACOS_PROFILE",
        "CMUX_BENCH_WINDOWS_USER",
        "CMUX_BENCH_WINDOWS_PASSWORD",
    ] {
        command.env_remove(key);
    }
    platform::exec_product(command, timing)
}

fn accept_already_closed_control(result: io::Result<()>) -> io::Result<()> {
    match result {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotConnected => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod control_tests {
    use super::*;

    #[test]
    fn control_shutdown_accepts_only_success_or_an_already_closed_peer() {
        assert!(accept_already_closed_control(Ok(())).is_ok());
        assert!(
            accept_already_closed_control(Err(io::Error::from(io::ErrorKind::NotConnected)))
                .is_ok()
        );
        let error =
            accept_already_closed_control(Err(io::Error::from(io::ErrorKind::PermissionDenied)))
                .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    }
}

fn parse_args(values: impl Iterator<Item = String>) -> Result<Launch> {
    let mut values = values;
    let mut launch = Launch {
        control: PathBuf::new(),
        timing: PathBuf::new(),
        nonce: String::new(),
        fixture_root: PathBuf::new(),
        target: PathBuf::new(),
        target_sha256: String::new(),
        supervisor_sha256: String::new(),
        windows_bootstrap_binary: PathBuf::new(),
        windows_bootstrap_sha256: String::new(),
        product_args: Vec::new(),
        inner: false,
        prove_private_job: false,
    };
    while let Some(argument) = values.next() {
        if argument == "--" {
            launch.product_args.extend(values);
            break;
        }
        match argument.as_str() {
            "--inner" => launch.inner = true,
            "--prove-private-job" => launch.prove_private_job = true,
            "--control" => launch.control = required_value(&mut values, &argument)?.into(),
            "--timing" => launch.timing = required_value(&mut values, &argument)?.into(),
            "--nonce" => launch.nonce = required_value(&mut values, &argument)?,
            "--fixture-root" => {
                launch.fixture_root = required_value(&mut values, &argument)?.into();
            }
            "--target" => launch.target = required_value(&mut values, &argument)?.into(),
            "--target-sha256" => launch.target_sha256 = required_value(&mut values, &argument)?,
            "--supervisor-sha256" => {
                launch.supervisor_sha256 = required_value(&mut values, &argument)?;
            }
            "--windows-bootstrap-binary" => {
                launch.windows_bootstrap_binary = required_value(&mut values, &argument)?.into();
            }
            "--windows-bootstrap-sha256" => {
                launch.windows_bootstrap_sha256 = required_value(&mut values, &argument)?;
            }
            _ => bail!("unknown supervisor argument {argument}"),
        }
    }
    Ok(launch)
}

fn required_value(values: &mut impl Iterator<Item = String>, argument: &str) -> Result<String> {
    values.next().with_context(|| format!("{argument} requires a value"))
}

fn validate_launch(launch: &Launch) -> Result<()> {
    for (name, path) in [
        ("control", &launch.control),
        ("timing", &launch.timing),
        ("fixture root", &launch.fixture_root),
        ("target", &launch.target),
    ] {
        if path.as_os_str().is_empty() {
            bail!("{name} path is required");
        }
    }
    if !launch.fixture_root.is_dir() || !launch.target.is_file() || !launch.timing.is_file() {
        bail!("supervisor input path is missing");
    }
    let fixture_root = launch.fixture_root.canonicalize()?;
    let target = launch.target.canonicalize()?;
    let timing = launch.timing.canonicalize()?;
    if target.starts_with(&fixture_root) {
        bail!("the product must be outside the writable fixture root");
    }
    let control_parent =
        launch.control.parent().context("control path has no parent")?.canonicalize()?;
    if control_parent != fixture_root || timing.parent() != Some(fixture_root.as_path()) {
        bail!("control state must be directly under the fixture root");
    }
    if launch.nonce.len() != 64 || !launch.nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("control nonce must be 64 hexadecimal characters");
    }
    for (name, digest) in
        [("target", &launch.target_sha256), ("supervisor", &launch.supervisor_sha256)]
    {
        if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            bail!("{name} SHA-256 must be 64 hexadecimal characters");
        }
    }
    #[cfg(windows)]
    {
        if !launch.windows_bootstrap_binary.is_file() {
            bail!("dedicated Windows bootstrap must be one trusted external file");
        }
        let bootstrap = launch.windows_bootstrap_binary.canonicalize()?;
        if bootstrap.starts_with(&fixture_root) {
            bail!("dedicated Windows bootstrap must be outside the writable fixture root");
        }
        if launch.windows_bootstrap_sha256.len() != 64
            || !launch.windows_bootstrap_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            bail!("Windows bootstrap SHA-256 must be 64 hexadecimal characters");
        }
        if bootstrap == env::current_exe()?.canonicalize()? {
            bail!("Windows bootstrap must be the dedicated minimal executable");
        }
        verify_file_sha256(
            &launch.windows_bootstrap_binary,
            &launch.windows_bootstrap_sha256,
            "dedicated Windows bootstrap",
        )?;
    }
    Ok(())
}

#[cfg(windows)]
fn verify_file_sha256(path: &Path, expected: &str, name: &str) -> Result<()> {
    use std::io::Read;

    let mut file =
        fs::File::open(path).with_context(|| format!("open {name} {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count =
            file.read(&mut buffer).with_context(|| format!("hash {name} {}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let observed = format!("{:x}", hasher.finalize());
    if observed != expected {
        bail!("{name} SHA-256 mismatch: expected {expected}, observed {observed}");
    }
    Ok(())
}

#[cfg(target_os = "linux")]
mod platform {
    use std::fs::File;
    use std::io::{Read, Seek, SeekFrom};
    use std::os::fd::{AsRawFd, FromRawFd, RawFd};
    use std::os::unix::process::CommandExt;

    use super::*;

    pub fn run_outer(launch: &Launch) -> Result<ExitStatus> {
        let bwrap =
            env::var("CMUX_BENCH_LINUX_BWRAP").context("CMUX_BENCH_LINUX_BWRAP is required")?;
        let use_sudo = env::var("CMUX_BENCH_LINUX_SUDO").as_deref() == Ok("1");
        let identity = if use_sudo {
            Some((
                env::var("CMUX_BENCH_LINUX_UID").context("CMUX_BENCH_LINUX_UID is required")?,
                env::var("CMUX_BENCH_LINUX_GID").context("CMUX_BENCH_LINUX_GID is required")?,
            ))
        } else {
            None
        };
        let current = env::current_exe().context("resolve trusted supervisor executable")?;
        let supervisor =
            TrustedBinary::open(&current, &launch.supervisor_sha256, "trusted supervisor")?;
        let product = TrustedBinary::open(&launch.target, &launch.target_sha256, "product binary")?;
        if let Some((_, gid)) = &identity {
            grant_fixture_group_access(launch, gid)?;
        }
        let sandbox_supervisor = Path::new("/cmux-bin/supervisor");
        let sandbox_target = Path::new("/cmux-bin/product");
        let (supervisor_fd, product_fd) =
            if use_sudo { (3, 4) } else { (supervisor.inherited_fd(), product.inherited_fd()) };
        let mut command = if use_sudo {
            let outer_pid = std::process::id().to_string();
            let source_supervisor_fd = supervisor.inherited_fd().to_string();
            let source_product_fd = product.inherited_fd().to_string();
            let mut command = Command::new("sudo");
            command.args([
                "-n",
                "--",
                "/bin/sh",
                "-c",
                "exec 3<\"/proc/$1/fd/$2\"; exec 4<\"/proc/$1/fd/$3\"; shift 3; exec \"$@\"",
                "cmux-bwrap-fd-bridge",
            ]);
            command.args([outer_pid, source_supervisor_fd, source_product_fd]);
            command.arg(&bwrap);
            command
        } else {
            Command::new(&bwrap)
        };
        if use_sudo {
            // Root constructs only the mount and explicit isolation namespaces. It must not enter
            // a user namespace before it opens the fixture bind. The contained setpriv command
            // below owns the one identity and capability transition.
            command.args([
                "--unshare-ipc",
                "--unshare-pid",
                "--unshare-net",
                "--unshare-uts",
                "--unshare-cgroup-try",
                "--disable-userns",
            ]);
        } else {
            command.arg("--unshare-all");
            command.args(["--cap-drop", "ALL"]);
        }
        command.args(["--die-with-parent", "--new-session", "--clearenv", "--dir", "/cmux-bin"]);
        append_contained_environment(&mut command);
        append_binary_data_bind(&mut command, supervisor_fd, sandbox_supervisor);
        append_binary_data_bind(&mut command, product_fd, sandbox_target);
        for root in ["/usr", "/bin", "/lib", "/lib64"] {
            if Path::new(root).exists() {
                command.args(["--ro-bind", root, root]);
            }
        }
        for file in
            ["/etc/ld.so.cache", "/etc/nsswitch.conf", "/etc/passwd", "/etc/group", "/etc/hosts"]
        {
            if Path::new(file).exists() {
                add_parent_directories(&mut command, Path::new(file));
                command.arg("--ro-bind").arg(file).arg(file);
            }
        }
        add_parent_directories(&mut command, &launch.fixture_root);
        command.args(["--dev", "/dev", "--proc", "/proc", "--bind"]);
        command.arg(&launch.fixture_root).arg(&launch.fixture_root);
        command.arg("--chdir").arg(&launch.fixture_root);
        // Keep the explicit submounts above writable as configured, but make Bubblewrap's
        // synthetic root and all adjacent scaffolding read-only.
        command.args(["--remount-ro", "/"]);
        command.arg("--");
        if let Some((uid, gid)) = &identity {
            // Root owns only namespace construction. setpriv makes one contained transition to
            // the dedicated identity after Bubblewrap opens every trusted host bind source.
            command.args([
                "/usr/bin/setpriv",
                "--reuid",
                uid,
                "--regid",
                gid,
                "--clear-groups",
                "--no-new-privs",
                "--bounding-set=-all",
                "--inh-caps=-all",
                "--ambient-caps=-all",
            ]);
        }
        let mut contained = launch.clone();
        contained.target = sandbox_target.into();
        command.arg(sandbox_supervisor).arg("--inner").args(forwarded_args(&contained));
        let status = command.status().context("launch Bubblewrap supervisor");
        // Keep both source descriptions open until Bubblewrap has consumed its inherited copies.
        drop((supervisor, product));
        status
    }

    struct TrustedBinary {
        _source: File,
        inherited: File,
    }

    impl TrustedBinary {
        fn open(path: &Path, expected_sha256: &str, name: &str) -> Result<Self> {
            let mut source =
                File::open(path).with_context(|| format!("open {name} {}", path.display()))?;
            if !source.metadata()?.is_file() {
                bail!("{name} is not a regular file: {}", path.display());
            }
            let mut hasher = Sha256::new();
            let mut buffer = [0_u8; 64 * 1024];
            loop {
                let count = source
                    .read(&mut buffer)
                    .with_context(|| format!("hash {name} {}", path.display()))?;
                if count == 0 {
                    break;
                }
                hasher.update(&buffer[..count]);
            }
            let observed = format!("{:x}", hasher.finalize());
            if observed != expected_sha256 {
                bail!("{name} SHA-256 mismatch: expected {expected_sha256}, observed {observed}");
            }
            source.seek(SeekFrom::Start(0))?;
            // F_DUPFD makes an inheritable duplicate. Rust opens the source with CLOEXEC.
            let raw = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 10) };
            if raw == -1 {
                return Err(io::Error::last_os_error())
                    .with_context(|| format!("duplicate {name} descriptor"));
            }
            // SAFETY: F_DUPFD returned a new owned descriptor.
            let inherited = unsafe { File::from_raw_fd(raw) };
            Ok(Self { _source: source, inherited })
        }

        fn inherited_fd(&self) -> RawFd {
            self.inherited.as_raw_fd()
        }
    }

    fn append_binary_data_bind(command: &mut Command, source: RawFd, destination: &Path) {
        command.args(["--perms", "0555", "--ro-bind-data"]);
        command.arg(source.to_string()).arg(destination);
    }

    pub fn exec_product(mut command: Command, timing: TimingSink) -> Result<()> {
        // SAFETY: prctl, the atomic mmap write, and the monotonic clock call are
        // async-signal-safe and do not access shared Rust state.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                timing.record_pre_exec()
            })
        };
        Err(command.exec()).context("exec contained product")
    }

    fn grant_fixture_group_access(launch: &Launch, gid: &str) -> Result<()> {
        let group = Command::new("sudo")
            .args(["-n", "chgrp", "-R", gid])
            .arg(&launch.fixture_root)
            .status()
            .context("assign Linux benchmark fixture group")?;
        if !group.success() {
            bail!("Linux fixture group command failed with {group}");
        }
        let recursive = Command::new("sudo")
            .args(["-n", "chmod", "-R", "g+rwX"])
            .arg(&launch.fixture_root)
            .status()?;
        let root = Command::new("sudo")
            .args(["-n", "chmod", "g+rwx"])
            .arg(&launch.fixture_root)
            .status()?;
        if !recursive.success() || !root.success() {
            bail!("Linux fixture group permission command failed");
        }
        Ok(())
    }

    fn append_contained_environment(command: &mut Command) {
        for key in [
            "PATH",
            "SHELL",
            "HOME",
            "USERPROFILE",
            "XDG_CONFIG_HOME",
            "XDG_DATA_HOME",
            "XDG_CACHE_HOME",
            "XDG_STATE_HOME",
            "XDG_RUNTIME_DIR",
            "LOCALAPPDATA",
            "APPDATA",
            "TMPDIR",
            "TEMP",
            "TMP",
            "CMUX_TUI_CONFIG",
            "TERM",
            "COLORTERM",
            "LANG",
            "LC_ALL",
            "LD_LIBRARY_PATH",
            "CMUX_STARTUP_TEST_SENTINEL_PATH",
            "CMUX_STARTUP_TEST_START_MARKER_PATH",
        ] {
            if let Some(value) = env::var_os(key) {
                command.arg("--setenv").arg(key).arg(value);
            }
        }
    }

    fn add_parent_directories(command: &mut Command, path: &Path) {
        let mut parents =
            path.ancestors().skip(1).filter(|path| *path != Path::new("/")).collect::<Vec<_>>();
        parents.reverse();
        for parent in parents {
            command.arg("--dir").arg(parent);
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::process::CommandExt;
    use std::time::{Duration, Instant};

    use super::*;

    pub fn run_outer(launch: &Launch) -> Result<ExitStatus> {
        let profile =
            env::var("CMUX_BENCH_MACOS_PROFILE").context("CMUX_BENCH_MACOS_PROFILE is required")?;
        let current = env::current_exe()?;
        let fixture_root = canonical_existing_fixture_root(&launch.fixture_root)?;
        let mut account = JobAccount::create(launch, &fixture_root)?;
        let mut command = Command::new("sudo");
        command.args(["-n", "-u", &account.user, "--", "/usr/bin/env", "-i"]);
        append_product_environment(&mut command);
        command.args(["/usr/bin/sandbox-exec", "-D"]);
        command.arg(format!("CMUX_FIXTURE_ROOT={}", fixture_root.to_string_lossy()));
        command.arg("-f");
        command.arg(profile).arg(current).arg("--inner").args(forwarded_args(launch));
        let result = command.status().context("launch Seatbelt supervisor");
        let cleanup = account.cleanup();
        match (result, cleanup) {
            (Ok(status), Ok(())) => Ok(status),
            (Err(error), Ok(())) => Err(error),
            (Ok(_), Err(cleanup)) => Err(cleanup),
            (Err(error), Err(cleanup)) => {
                Err(error.context(format!("Seatbelt cleanup also failed: {cleanup:#}")))
            }
        }
    }

    struct JobAccount {
        user: String,
        uid: u32,
        group: String,
        nonce: String,
        fixture_root: PathBuf,
        created: bool,
        launchable: bool,
    }

    impl JobAccount {
        fn create(launch: &Launch, fixture_root: &Path) -> Result<Self> {
            let prefix = env::var("CMUX_BENCH_MACOS_ACCOUNT_PREFIX")
                .context("CMUX_BENCH_MACOS_ACCOUNT_PREFIX is required")?;
            let uid_base = env::var("CMUX_BENCH_MACOS_UID_BASE")
                .context("CMUX_BENCH_MACOS_UID_BASE is required")?
                .parse::<u32>()?;
            let group =
                env::var("CMUX_BENCH_MACOS_GROUP").context("CMUX_BENCH_MACOS_GROUP is required")?;
            validate_group(&group)?;
            let gid = env::var("CMUX_BENCH_MACOS_GID")
                .context("CMUX_BENCH_MACOS_GID is required")?
                .parse::<u32>()?;
            validate_group_identity(&group, gid)?;
            let (user, uid) = macos_account_identity(&launch.nonce, &prefix, uid_base)?;
            let mut account = Self {
                user,
                uid,
                group,
                nonce: launch.nonce.clone(),
                fixture_root: fixture_root.to_path_buf(),
                created: false,
                launchable: false,
            };
            let result = account.create_inner(gid);
            if let Err(error) = result {
                let cleanup = account.cleanup();
                return match cleanup {
                    Ok(()) => Err(error),
                    Err(cleanup) => {
                        Err(error
                            .context(format!("partial account cleanup also failed: {cleanup:#}")))
                    }
                };
            }
            Ok(account)
        }

        fn create_inner(&mut self, gid: u32) -> Result<()> {
            if account_exists(&self.user)? {
                bail!("macOS benchmark account already exists: {}", self.user);
            }
            let uid_search = Command::new("dscl")
                .args([".", "-search", "/Users", "UniqueID", &self.uid.to_string()])
                .output()?;
            if !uid_search.status.success() || !uid_search.stdout.is_empty() {
                bail!("macOS benchmark UID {} is unavailable", self.uid);
            }
            sudo(["dscl", ".", "-create", &format!("/Users/{}", self.user)])?;
            self.created = true;
            sudo([
                "dscl",
                ".",
                "-create",
                &format!("/Users/{}", self.user),
                "dsAttrTypeNative:cmuxBenchmarkNonce",
                &self.nonce,
            ])?;
            for (key, value) in [
                ("UniqueID", self.uid.to_string()),
                ("PrimaryGroupID", gid.to_string()),
                ("UserShell", "/usr/bin/false".into()),
                ("NFSHomeDirectory", self.fixture_root.join("home").display().to_string()),
                ("RealName", format!("cmux benchmark {}", self.user)),
            ] {
                sudo(["dscl", ".", "-create", &format!("/Users/{}", self.user), key, &value])?;
            }
            sudo(["dscl", ".", "-create", &format!("/Users/{}", self.user), "Password", "*"])?;
            sudo([
                "dscl",
                ".",
                "-create",
                &format!("/Users/{}", self.user),
                "AuthenticationAuthority",
                ";DisabledUser;",
            ])?;
            self.launchable = true;
            sudo(["dseditgroup", "-o", "edit", "-a", &self.user, "-t", "user", &self.group])?;
            sudo_path(["chgrp", "-R", &self.group], &self.fixture_root)?;
            sudo_path(["chmod", "-R", "g+rwX"], &self.fixture_root)?;
            sudo_path(["chmod", "g+rwx"], &self.fixture_root)?;
            Ok(())
        }

        fn cleanup(&mut self) -> Result<()> {
            if !self.created {
                return Ok(());
            }
            if self.launchable {
                terminate_job_user(&self.user)?;
                let _ = sudo([
                    "dseditgroup",
                    "-o",
                    "edit",
                    "-d",
                    &self.user,
                    "-t",
                    "user",
                    &self.group,
                ]);
            }
            if account_exists(&self.user)? {
                sudo(["dscl", ".", "-delete", &format!("/Users/{}", self.user)])?;
            }
            self.created = false;
            self.launchable = false;
            Ok(())
        }
    }

    fn validate_group(group: &str) -> Result<()> {
        if group.is_empty()
            || group.len() > 31
            || !group.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        {
            bail!("macOS benchmark group must contain 1-31 lowercase letters or digits");
        }
        Ok(())
    }

    fn validate_group_identity(group: &str, gid: u32) -> Result<()> {
        let output = Command::new("dscl")
            .args([".", "-read", &format!("/Groups/{group}"), "PrimaryGroupID"])
            .output()?;
        if !output.status.success()
            || String::from_utf8(output.stdout)?.trim() != format!("PrimaryGroupID: {gid}")
        {
            bail!("macOS benchmark group identity did not match {group}:{gid}");
        }
        Ok(())
    }

    fn account_exists(user: &str) -> Result<bool> {
        let output =
            Command::new("dscl").args([".", "-read", &format!("/Users/{user}")]).output()?;
        Ok(output.status.success())
    }

    fn sudo<const N: usize>(arguments: [&str; N]) -> Result<()> {
        let output = Command::new("sudo").arg("-n").args(arguments).output()?;
        if !output.status.success() {
            bail!(
                "privileged macOS account command failed with {}: {}",
                output.status,
                bounded_command_output(&output.stdout, &output.stderr)
            );
        }
        Ok(())
    }

    fn sudo_path<const N: usize>(arguments: [&str; N], path: &Path) -> Result<()> {
        let output = Command::new("sudo").arg("-n").args(arguments).arg(path).output()?;
        if !output.status.success() {
            bail!(
                "privileged macOS fixture command failed with {}: {}",
                output.status,
                bounded_command_output(&output.stdout, &output.stderr)
            );
        }
        Ok(())
    }

    fn bounded_command_output(stdout: &[u8], stderr: &[u8]) -> String {
        const LIMIT: usize = 4 * 1024;
        let stdout = &stdout[..stdout.len().min(LIMIT)];
        let stderr = &stderr[..stderr.len().min(LIMIT)];
        format!(
            "stdout={:?}, stderr={:?}",
            String::from_utf8_lossy(stdout),
            String::from_utf8_lossy(stderr)
        )
    }

    pub fn exec_product(mut command: Command, timing: TimingSink) -> Result<()> {
        // SAFETY: the closure performs one atomic mmap write and a monotonic clock syscall.
        unsafe { command.pre_exec(move || timing.record_pre_exec()) };
        Err(command.exec()).context("exec contained product")
    }

    fn terminate_job_user(user: &str) -> Result<()> {
        let pids = user_processes(user)?;
        let exits = ExitWatch::new(&pids)?;
        let output = Command::new("sudo").args(["-n", "pkill", "-KILL", "-u", user]).output()?;
        if !output.status.success() && output.status.code() != Some(1) {
            bail!(
                "Seatbelt job-user kill failed with {}: {}",
                output.status,
                bounded_command_output(&output.stdout, &output.stderr)
            );
        }
        exits.wait(CONTROL_TIMEOUT)?;
        let remaining = user_processes(user)?;
        if !remaining.is_empty() {
            bail!("processes survived Seatbelt job cleanup for {user}: {remaining:?}");
        }
        Ok(())
    }

    fn user_processes(user: &str) -> Result<Vec<u32>> {
        let output = Command::new("pgrep").args(["-u", user]).output()?;
        if !output.status.success() {
            if output.status.code() == Some(1) {
                return Ok(Vec::new());
            }
            bail!("list Seatbelt job-user processes failed with {}", output.status);
        }
        String::from_utf8(output.stdout)?
            .lines()
            .map(|line| line.parse::<u32>().context("parse Seatbelt job-user PID"))
            .collect()
    }

    struct ExitWatch {
        queue: OwnedFd,
        registrations: usize,
    }

    impl ExitWatch {
        fn new(pids: &[u32]) -> Result<Self> {
            // SAFETY: kqueue returns a new owned descriptor or -1.
            let raw = unsafe { libc::kqueue() };
            if raw == -1 {
                return Err(io::Error::last_os_error())
                    .context("create Seatbelt process-exit kqueue");
            }
            // SAFETY: raw is a unique descriptor returned by kqueue above.
            let queue = unsafe { OwnedFd::from_raw_fd(raw) };
            let mut registrations = 0;
            for pid in pids {
                let change = libc::kevent {
                    ident: *pid as usize,
                    filter: libc::EVFILT_PROC,
                    flags: libc::EV_ADD | libc::EV_ONESHOT,
                    fflags: libc::NOTE_EXIT,
                    data: 0,
                    udata: std::ptr::null_mut(),
                };
                // SAFETY: change is initialized and no event output is requested.
                let result = unsafe {
                    libc::kevent(
                        queue.as_raw_fd(),
                        &change,
                        1,
                        std::ptr::null_mut(),
                        0,
                        std::ptr::null(),
                    )
                };
                if result == 0 {
                    registrations += 1;
                } else if io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                    return Err(io::Error::last_os_error())
                        .context(format!("register Seatbelt exit event for PID {pid}"));
                }
            }
            Ok(Self { queue, registrations })
        }

        fn wait(self, timeout: Duration) -> Result<()> {
            let deadline = Instant::now()
                .checked_add(timeout)
                .context("Seatbelt process-exit deadline overflow")?;
            let mut remaining = self.registrations;
            while remaining > 0 {
                let duration = deadline
                    .checked_duration_since(Instant::now())
                    .filter(|value| !value.is_zero())
                    .context("Seatbelt process-exit deadline expired")?;
                let timeout = libc::timespec {
                    tv_sec: duration.as_secs().try_into()?,
                    tv_nsec: i64::from(duration.subsec_nanos()),
                };
                let mut events = Vec::with_capacity(remaining);
                for _ in 0..remaining {
                    events.push(libc::kevent {
                        ident: 0,
                        filter: 0,
                        flags: 0,
                        fflags: 0,
                        data: 0,
                        udata: std::ptr::null_mut(),
                    });
                }
                // SAFETY: events has writable capacity for remaining event records.
                let count = unsafe {
                    libc::kevent(
                        self.queue.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        events.as_mut_ptr(),
                        i32::try_from(events.len())?,
                        &timeout,
                    )
                };
                if count == -1 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error).context("wait for Seatbelt process exits");
                }
                if count == 0 {
                    bail!("Seatbelt process-exit deadline expired");
                }
                remaining -= usize::try_from(count)?;
            }
            Ok(())
        }
    }

    fn append_product_environment(command: &mut Command) {
        for key in [
            "PATH",
            "SHELL",
            "HOME",
            "XDG_CONFIG_HOME",
            "XDG_STATE_HOME",
            "XDG_RUNTIME_DIR",
            "TMPDIR",
            "TEMP",
            "TMP",
            "CMUX_TUI_CONFIG",
            "TERM",
            "COLORTERM",
            "LANG",
            "LC_ALL",
            "DEVELOPER_DIR",
            "CMUX_STARTUP_TEST_SENTINEL_PATH",
            "CMUX_STARTUP_TEST_START_MARKER_PATH",
        ] {
            if let Some(value) = env::var_os(key) {
                command.arg(format!("{key}={}", value.to_string_lossy()));
            }
        }
    }
}

#[cfg(windows)]
mod platform {
    use std::ffi::c_void;
    use std::fs::File;
    use std::io::Write;
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, RawHandle};
    use std::os::windows::process::ExitStatusExt;
    use std::process::Stdio;
    use std::ptr::{null, null_mut};
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, Instant};

    use windows_sys::Win32::Foundation::{
        CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_NOT_ALL_ASSIGNED, ERROR_SUCCESS,
        GENERIC_ALL, GetLastError, HANDLE, INVALID_HANDLE_VALUE, LocalFree, SetLastError,
        WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
        ConvertStringSidToSidW, EXPLICIT_ACCESS_W, GRANT_ACCESS, GetNamedSecurityInfoW,
        NO_MULTIPLE_TRUSTEE, SDDL_REVISION_1, SE_FILE_OBJECT, SetEntriesInAclW,
        SetNamedSecurityInfoW, TRUSTEE_IS_SID, TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        ACL, AdjustTokenPrivileges, DACL_SECURITY_INFORMATION, GetTokenInformation,
        LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, LUID_AND_ATTRIBUTES, LogonUserW,
        LookupPrivilegeValueW, PRIVILEGE_SET, PSECURITY_DESCRIPTOR, PSID, PrivilegeCheck,
        SE_IMPERSONATE_NAME, SE_PRIVILEGE_ENABLED, SECURITY_ATTRIBUTES,
        SUB_CONTAINERS_AND_OBJECTS_INHERIT, TOKEN_ADJUST_PRIVILEGES, TOKEN_PRIVILEGES, TOKEN_QUERY,
        TOKEN_USER, TokenUser,
    };
    use windows_sys::Win32::Storage::FileSystem::{FILE_TYPE_UNKNOWN, GetFileType};
    use windows_sys::Win32::System::Console::{
        GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
    };
    use windows_sys::Win32::System::IO::{CreateIoCompletionPort, GetQueuedCompletionStatus};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_ASSOCIATE_COMPLETION_PORT, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JobObjectAssociateCompletionPortInformation, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::StationsAndDesktops::{
        CloseDesktop, CloseWindowStation, CreateDesktopW, CreateWindowStationW, DESKTOP_CREATEMENU,
        DESKTOP_CREATEWINDOW, DESKTOP_ENUMERATE, DESKTOP_HOOKCONTROL, DESKTOP_READOBJECTS,
        DESKTOP_WRITEOBJECTS, GetProcessWindowStation, HDESK, HWINSTA, SetProcessWindowStation,
    };
    use windows_sys::Win32::System::SystemServices::{
        JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO, JOB_OBJECT_QUERY, PRIVILEGE_SET_ALL_NECESSARY,
    };
    use windows_sys::Win32::System::Threading::{
        CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessWithTokenW,
        GetCurrentProcess, GetExitCodeProcess, GetProcessId, GetThreadId, INFINITE,
        OpenProcessToken, PROCESS_INFORMATION, ResumeThread, STARTUPINFOW, TerminateProcess,
        WaitForSingleObject,
    };
    use windows_sys::Win32::UI::Shell::{LoadUserProfileW, PROFILEINFOW, UnloadUserProfile};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CWF_CREATE_ONLY, WINSTA_ACCESSCLIPBOARD, WINSTA_ACCESSGLOBALATOMS, WINSTA_CREATEDESKTOP,
        WINSTA_EXITWINDOWS, WINSTA_READATTRIBUTES,
    };

    use super::*;
    use crate::startup_benchmark_protocol::{BootstrapHangArtifactReference, BootstrapTerminal};
    use crate::startup_benchmark_windows_diagnostic::{self, CaptureRequest};

    const MAX_BOOTSTRAP_CHECKPOINT_BYTES: usize = 64 * 1024;
    const STANDARD_RIGHTS_REQUIRED_VALUE: u32 = 0x000f_0000;
    const PRIVATE_WINSTA_ACCOUNT_ACCESS: u32 = STANDARD_RIGHTS_REQUIRED_VALUE
        | WINSTA_ACCESSCLIPBOARD as u32
        | WINSTA_ACCESSGLOBALATOMS as u32
        | WINSTA_CREATEDESKTOP as u32
        | WINSTA_EXITWINDOWS as u32
        | WINSTA_READATTRIBUTES as u32;
    const PRIVATE_DESKTOP_ACCOUNT_ACCESS: u32 = STANDARD_RIGHTS_REQUIRED_VALUE
        | DESKTOP_CREATEMENU
        | DESKTOP_CREATEWINDOW
        | DESKTOP_ENUMERATE
        | DESKTOP_HOOKCONTROL
        | DESKTOP_READOBJECTS
        | DESKTOP_WRITEOBJECTS;
    const PRIVATE_WINSTA_OWNER_ACCESS: u32 = 0x000f_037f;
    const PRIVATE_DESKTOP_OWNER_ACCESS: u32 = 0x000f_01ff;

    pub fn run_outer(launch: &Launch) -> Result<ExitStatus> {
        let mut control = transport::connect(&launch.control)
            .with_context(|| format!("connect control socket {}", launch.control.display()))?;
        control.set_read_timeout(Some(STARTUP_LINE_TIMEOUT))?;
        control.set_write_timeout(Some(STARTUP_LINE_TIMEOUT))?;
        match fs::remove_file(&launch.control) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // Windows AF_UNIX names do not create filesystem entries.
            }
            Err(error) => return Err(error).context("remove live Windows control socket"),
        }
        write_control_line(&mut control, &setup_line(&launch.nonce))?;
        let mut trace = BootstrapStartupTrace::new();
        trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::PublicControlConnected));
        let security_deadline = Instant::now()
            .checked_add(SECURITY_PREPARATION_TIMEOUT)
            .context("Windows security preparation deadline overflow")?;

        let mut owner = match WindowsLaunchOwner::new(launch, security_deadline, &mut trace) {
            Ok(owner) => owner,
            Err(error) => {
                trace.observe(BootstrapObservedEvent::Error);
                return finish_failed_bootstrap_startup(
                    launch,
                    &mut control,
                    trace,
                    error.context("create Windows restricted startup owner"),
                    None,
                    None,
                );
            }
        };
        let mut bootstrap = match owner.start_bootstrap(launch, &mut trace) {
            Ok(bootstrap) => bootstrap,
            Err(error) => {
                trace.observe(BootstrapObservedEvent::Error);
                return finish_failed_bootstrap_startup(
                    launch,
                    &mut control,
                    trace,
                    error.context("start Windows restricted bootstrap"),
                    Some(&mut owner),
                    None,
                );
            }
        };
        if let Err(mut error) = bootstrap.wait_ready(&launch.nonce, &mut trace) {
            if trace.terminal == Some(BootstrapTerminal::BootstrapTimeout) {
                if let Err(diagnostic) = bootstrap.capture_hang_snapshot(&owner, launch) {
                    error = error.context(format!(
                        "trusted pre-cleanup hang diagnostic also failed: {diagnostic:#}"
                    ));
                }
            }
            return finish_failed_bootstrap_startup(
                launch,
                &mut control,
                trace,
                error,
                Some(&mut owner),
                Some(&mut bootstrap),
            );
        }
        let result = (|| {
            write_control_line(&mut control, &ready_line(&launch.nonce))?;
            let arm = read_control_line(&mut control)?;
            if arm != arm_line(&launch.nonce).trim_end() {
                bail!("control ARM identity mismatch");
            }
            bootstrap.arm_and_wait(&launch.nonce, launch.prove_private_job, &mut control)
        })();
        if launch.prove_private_job && result.is_err() {
            let mut error = result.expect_err("checked product launch failure");
            if bootstrap.product_status_timed_out && bootstrap.product_process.is_some() {
                if let Err(diagnostic) = bootstrap.capture_product_hang_snapshot(&owner, launch) {
                    error = error.context(format!(
                        "trusted restricted-product hang diagnostic also failed: {diagnostic:#}"
                    ));
                }
            }
            return finish_failed_bootstrap_startup(
                launch,
                &mut control,
                trace,
                error,
                Some(&mut owner),
                Some(&mut bootstrap),
            );
        }
        let cleanup_deadline = Instant::now()
            .checked_add(BOOTSTRAP_CLEANUP_TIMEOUT)
            .context("Windows containment cleanup deadline overflow")?;
        owner.private_desktop.product_assigned = bootstrap.product_started_relayed;
        let mut cleanup = owner.cleanup(cleanup_deadline);
        if cleanup.is_ok() {
            cleanup = bootstrap.record_private_desktop_cleanup(&owner);
        }
        let bootstrap_cleanup = bootstrap.finish(cleanup_deadline);
        let mut result = combine_windows_results(result, cleanup, bootstrap_cleanup);
        if result.is_err() && !bootstrap.product_started_relayed {
            let relay = failure_line(&launch.nonce, None)
                .and_then(|line| write_control_line(&mut control, &line));
            if let Err(relay) = relay {
                result = result.map_err(|error| {
                    error.context(format!("relay bounded post-ARM failure: {relay}"))
                });
            }
        }
        let control_close =
            accept_already_closed_control(control.shutdown(std::net::Shutdown::Both));
        drop(control);
        match (result, control_close) {
            (Ok(status), Ok(())) => Ok(status),
            (Err(error), Ok(())) => Err(error),
            (Ok(_), Err(close)) => Err(close).context("close Windows public control channel"),
            (Err(error), Err(close)) => {
                Err(error.context(format!("close Windows public control channel: {close:#}")))
            }
        }
    }

    pub fn exec_product(_command: Command, _timing: TimingSink) -> Result<()> {
        bail!("Windows restricted-token supervisor inner mode is invalid")
    }

    pub fn run_hang_diagnostic(values: &[String]) -> Result<()> {
        startup_benchmark_windows_diagnostic::run_helper(values)
    }

    struct LoadedProfile {
        token: OwnedHandle,
        profile: HANDLE,
        cleaned: bool,
    }

    impl LoadedProfile {
        fn load(token: OwnedHandle, user: &str) -> Result<Self> {
            let mut user = wide(std::ffi::OsStr::new(user));
            let mut information = PROFILEINFOW {
                dwSize: u32::try_from(size_of::<PROFILEINFOW>())?,
                lpUserName: user.as_mut_ptr(),
                ..PROFILEINFOW::default()
            };
            // SAFETY: token is a live interactive account token and information is writable.
            check(
                unsafe { LoadUserProfileW(token.0, &mut information) },
                "load unique Windows benchmark profile",
            )?;
            Ok(Self { token, profile: information.hProfile, cleaned: false })
        }

        fn token(&self) -> HANDLE {
            self.token.0
        }

        fn cleanup(&mut self) -> Result<()> {
            if self.cleaned {
                return Ok(());
            }
            // SAFETY: this token/profile pair came from one successful LoadUserProfileW call.
            check(
                unsafe { UnloadUserProfile(self.token.0, self.profile) },
                "unload unique Windows benchmark profile",
            )?;
            self.cleaned = true;
            Ok(())
        }
    }

    impl Drop for LoadedProfile {
        fn drop(&mut self) {
            if !self.cleaned {
                // SAFETY: this is the fallback for the same live profile pair.
                let _ = unsafe { UnloadUserProfile(self.token.0, self.profile) };
            }
        }
    }

    struct OwnedSecurityDescriptor(PSECURITY_DESCRIPTOR);

    impl OwnedSecurityDescriptor {
        fn from_sddl(sddl: &str) -> Result<Self> {
            let sddl = wide(std::ffi::OsStr::new(sddl));
            let mut descriptor = null_mut();
            // SAFETY: the SDDL is NUL-terminated and descriptor is writable.
            check(
                unsafe {
                    ConvertStringSecurityDescriptorToSecurityDescriptorW(
                        sddl.as_ptr(),
                        SDDL_REVISION_1,
                        &mut descriptor,
                        null_mut(),
                    )
                },
                "create private desktop security descriptor",
            )?;
            Ok(Self(descriptor))
        }

        fn security_attributes(&self) -> Result<SECURITY_ATTRIBUTES> {
            Ok(SECURITY_ATTRIBUTES {
                nLength: u32::try_from(size_of::<SECURITY_ATTRIBUTES>())?,
                lpSecurityDescriptor: self.0,
                bInheritHandle: 0,
            })
        }
    }

    impl Drop for OwnedSecurityDescriptor {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: ConvertStringSecurityDescriptorToSecurityDescriptorW used LocalAlloc.
                unsafe { LocalFree(self.0.cast()) };
            }
        }
    }

    struct PrivateDesktopOwner {
        window_station: HWINSTA,
        desktop: HDESK,
        name: String,
        window_station_created: bool,
        desktop_created: bool,
        bootstrap_assigned: bool,
        product_assigned: bool,
        job_empty_observed: bool,
        desktop_closed: bool,
        window_station_closed: bool,
    }

    impl PrivateDesktopOwner {
        fn create(nonce: &str, account_token: HANDLE, restricting_sid: &str) -> Result<Self> {
            let name = cmux_startup_bootstrap::private_desktop_name(nonce)?;
            let (window_station_name, desktop_name) = name
                .split_once('\\')
                .context("private desktop name lacks a window-station separator")?;
            let trusted_token = current_process_token()?;
            let trusted_sid = token_user_sid_text(trusted_token.0)?;
            let account_sid = token_user_sid_text(account_token)?;
            let station_descriptor = private_object_security_descriptor(
                &trusted_sid,
                &account_sid,
                restricting_sid,
                PRIVATE_WINSTA_OWNER_ACCESS,
                PRIVATE_WINSTA_ACCOUNT_ACCESS,
            )?;
            let desktop_descriptor = private_object_security_descriptor(
                &trusted_sid,
                &account_sid,
                restricting_sid,
                PRIVATE_DESKTOP_OWNER_ACCESS,
                PRIVATE_DESKTOP_ACCOUNT_ACCESS,
            )?;
            let mut station_attributes = station_descriptor.security_attributes()?;
            let mut desktop_attributes = desktop_descriptor.security_attributes()?;
            let station_name = wide(std::ffi::OsStr::new(window_station_name));
            let desktop_name = wide(std::ffi::OsStr::new(desktop_name));
            // SAFETY: this returns a borrowed process-owned station handle.
            let original_station = unsafe { GetProcessWindowStation() };
            if original_station.is_null() {
                return Err(io::Error::last_os_error())
                    .context("get trusted supervisor window station");
            }
            // SAFETY: names and security attributes remain live for this call.
            let window_station = unsafe {
                CreateWindowStationW(
                    station_name.as_ptr(),
                    CWF_CREATE_ONLY,
                    PRIVATE_WINSTA_OWNER_ACCESS,
                    &station_attributes,
                )
            };
            if window_station.is_null() {
                return Err(io::Error::last_os_error())
                    .context("create nonce-bound private window station");
            }
            // SAFETY: both handles are live. The original handle remains process-owned.
            if unsafe { SetProcessWindowStation(window_station) } == 0 {
                let error = io::Error::last_os_error();
                // SAFETY: window_station was created above and is not inherited.
                let _ = unsafe { CloseWindowStation(window_station) };
                return Err(error).context("select private window station for desktop creation");
            }
            // SAFETY: the private station is selected and all inputs remain live.
            let desktop = unsafe {
                CreateDesktopW(
                    desktop_name.as_ptr(),
                    null(),
                    null(),
                    0,
                    PRIVATE_DESKTOP_OWNER_ACCESS,
                    &desktop_attributes,
                )
            };
            let desktop_error = desktop.is_null().then(io::Error::last_os_error);
            // SAFETY: restore the trusted supervisor station before any return.
            let restore_result = unsafe { SetProcessWindowStation(original_station) };
            if let Some(error) = desktop_error {
                // SAFETY: window_station is still owned by this function.
                let _ = unsafe { CloseWindowStation(window_station) };
                return Err(error).context("create nonce-bound private desktop");
            }
            if restore_result == 0 {
                let error = io::Error::last_os_error();
                // SAFETY: both objects were created above and are not inherited.
                let _ = unsafe { CloseDesktop(desktop) };
                let _ = unsafe { CloseWindowStation(window_station) };
                return Err(error).context("restore trusted supervisor window station");
            }
            Ok(Self {
                window_station,
                desktop,
                name,
                window_station_created: true,
                desktop_created: true,
                bootstrap_assigned: false,
                product_assigned: false,
                job_empty_observed: false,
                desktop_closed: false,
                window_station_closed: false,
            })
        }

        fn close_after_job_empty(&mut self) -> Result<()> {
            self.job_empty_observed = true;
            if !self.desktop_closed {
                // SAFETY: desktop is a live, non-inherited handle owned here.
                check(unsafe { CloseDesktop(self.desktop) }, "close private desktop")?;
                self.desktop_closed = true;
                self.desktop = null_mut();
            }
            if !self.window_station_closed {
                // SAFETY: the desktop was closed and this station handle is still live.
                check(
                    unsafe { CloseWindowStation(self.window_station) },
                    "close private window station",
                )?;
                self.window_station_closed = true;
                self.window_station = null_mut();
            }
            Ok(())
        }
    }

    impl Drop for PrivateDesktopOwner {
        fn drop(&mut self) {
            if !self.desktop_closed && !self.desktop.is_null() {
                // SAFETY: fallback close for the same owned desktop handle.
                let _ = unsafe { CloseDesktop(self.desktop) };
            }
            if !self.window_station_closed && !self.window_station.is_null() {
                // SAFETY: fallback close for the same owned station handle.
                let _ = unsafe { CloseWindowStation(self.window_station) };
            }
        }
    }

    struct WindowsLaunchOwner {
        account_token: Option<OwnedHandle>,
        job: OwnedHandle,
        query_job: Option<OwnedHandle>,
        completion_port: OwnedHandle,
        // Drop fallback closes the Job first, then these UI objects, then the account profile.
        private_desktop: PrivateDesktopOwner,
        // Keep the profile after all Job handles so field-drop fallback closes the containment
        // boundary before it tries to unload a profile after an error.
        profile: Option<LoadedProfile>,
        restricting_sid_text: String,
        broker_assigned: bool,
    }

    struct TrustedPathProbe {
        path: PathBuf,
        removed: bool,
    }

    impl TrustedPathProbe {
        fn create(launch: &Launch) -> Result<Self> {
            let bootstrap = launch.windows_bootstrap_binary.canonicalize()?;
            let parent = bootstrap.parent().context("dedicated Windows bootstrap has no parent")?;
            let path = parent.join(format!(".cmux-bootstrap-probe-{}", &launch.nonce[..16]));
            let mut file =
                fs::OpenOptions::new().write(true).create_new(true).open(&path).with_context(
                    || format!("create trusted bootstrap write probe {}", path.display()),
                )?;
            file.write_all(b"protected")?;
            file.flush()?;
            drop(file);
            Ok(Self { path, removed: false })
        }

        fn verify_and_remove(&mut self) -> Result<()> {
            let bytes = fs::read(&self.path).with_context(|| {
                format!("read trusted bootstrap write probe {}", self.path.display())
            })?;
            if bytes != b"protected" {
                bail!("restricted bootstrap changed its trusted write probe");
            }
            fs::remove_file(&self.path).with_context(|| {
                format!("remove trusted bootstrap write probe {}", self.path.display())
            })?;
            self.removed = true;
            Ok(())
        }
    }

    impl Drop for TrustedPathProbe {
        fn drop(&mut self) {
            if !self.removed {
                let _ = fs::remove_file(&self.path);
            }
        }
    }

    impl WindowsLaunchOwner {
        fn new(
            launch: &Launch,
            security_deadline: Instant,
            trace: &mut BootstrapStartupTrace,
        ) -> Result<Self> {
            ensure_caller_impersonate_privilege(security_deadline, trace)?;
            complete_security_stage(
                security_deadline,
                trace,
                BootstrapStage::PrivilegeEnabled,
                "enable caller impersonation privilege",
            )?;
            let user = env::var("CMUX_BENCH_WINDOWS_USER")
                .context("CMUX_BENCH_WINDOWS_USER is required")?;
            let password = env::var("CMUX_BENCH_WINDOWS_PASSWORD")
                .context("CMUX_BENCH_WINDOWS_PASSWORD is required")?;
            let user_wide = wide(std::ffi::OsStr::new(&user));
            let password_wide = wide(std::ffi::OsStr::new(&password));
            let domain_wide = wide(std::ffi::OsStr::new("."));
            let mut account_token = null_mut();
            // SAFETY: all credential strings are NUL-terminated and account_token is writable.
            check(
                unsafe {
                    LogonUserW(
                        user_wide.as_ptr(),
                        domain_wide.as_ptr(),
                        password_wide.as_ptr(),
                        LOGON32_LOGON_INTERACTIVE,
                        LOGON32_PROVIDER_DEFAULT,
                        &mut account_token,
                    )
                },
                "log on unique Windows benchmark account",
            )?;
            let mut account_token = Some(OwnedHandle(account_token));
            complete_security_stage(
                security_deadline,
                trace,
                BootstrapStage::AccountLoggedOn,
                "log on unique Windows benchmark account",
            )?;
            let profile = if launch.prove_private_job {
                let profile = LoadedProfile::load(
                    account_token
                        .take()
                        .context("Windows account token is required for profile preflight")?,
                    &user,
                )?;
                complete_security_stage(
                    security_deadline,
                    trace,
                    BootstrapStage::ProfileLoaded,
                    "load unique Windows benchmark profile",
                )?;
                Some(profile)
            } else {
                complete_security_stage(
                    security_deadline,
                    trace,
                    BootstrapStage::ProfileSkipped,
                    "skip Windows profile outside preflight",
                )?;
                None
            };
            let sid_text = random_restricting_sid()?;
            check_security_deadline(security_deadline, trace, "create random restricting SID")?;
            let restricting_sid = OwnedSid::from_string(&sid_text)?;
            check_security_deadline(security_deadline, trace, "allocate restricting SID")?;
            complete_security_stage(
                security_deadline,
                trace,
                BootstrapStage::AccountBrokerReady,
                "prepare account-owned broker identity",
            )?;
            configure_fixture_acl(
                &launch.fixture_root,
                &user,
                restricting_sid.0,
                security_deadline,
                trace,
            )?;
            let launch_token = profile
                .as_ref()
                .map(LoadedProfile::token)
                .or_else(|| account_token.as_ref().map(|token| token.0))
                .context("Windows account token is required for private desktop")?;
            let private_desktop =
                PrivateDesktopOwner::create(&launch.nonce, launch_token, &sid_text)?;
            check_security_deadline(
                security_deadline,
                trace,
                "create nonce-bound private desktop",
            )?;
            let (job, query_job, completion_port) =
                create_non_breakaway_job(security_deadline, trace)?;
            complete_security_stage(
                security_deadline,
                trace,
                BootstrapStage::JobCompletionPortReady,
                "create containment Job and completion port",
            )?;
            Ok(Self {
                account_token,
                profile,
                job,
                query_job,
                completion_port,
                private_desktop,
                restricting_sid_text: sid_text,
                broker_assigned: false,
            })
        }

        fn account_token(&self) -> Result<HANDLE> {
            self.profile
                .as_ref()
                .map(LoadedProfile::token)
                .or_else(|| self.account_token.as_ref().map(|token| token.0))
                .context("Windows account token owner is missing")
        }

        fn start_bootstrap(
            &mut self,
            launch: &Launch,
            trace: &mut BootstrapStartupTrace,
        ) -> Result<BootstrapSession> {
            let bootstrap_binary = launch.windows_bootstrap_binary.canonicalize()?;
            let fixture_root = launch.fixture_root.canonicalize()?;
            let timing = launch.timing.canonicalize()?;
            let target = launch.target.canonicalize()?;
            let config_path = fixture_root.join(format!("bootstrap-{}.bin", &launch.nonce[..16]));
            let entry_checkpoint_path =
                fixture_root.join(format!("bootstrap-entry-{}.bin", &launch.nonce[..16]));
            verify_file_sha256(
                &bootstrap_binary,
                &launch.windows_bootstrap_sha256,
                "dedicated Windows bootstrap before launch",
            )?;
            let trusted_probe = TrustedPathProbe::create(launch)?;
            let trusted_path_probe = trusted_probe.path.canonicalize()?;
            let application = wide(bootstrap_binary.as_os_str());
            let current_directory = wide(fixture_root.as_os_str());
            let mut command_line = wide(std::ffi::OsStr::new(&windows_command_line(
                &bootstrap_binary,
                &[
                    config_path.to_string_lossy().into_owned(),
                    entry_checkpoint_path.to_string_lossy().into_owned(),
                    launch.nonce.clone(),
                ],
            )));
            // SAFETY: zero is a valid initial state for these Win32 structs.
            let mut startup: STARTUPINFOW = unsafe { zeroed() };
            startup.cb = u32::try_from(size_of::<STARTUPINFOW>())?;
            let mut private_desktop = wide(std::ffi::OsStr::new(&self.private_desktop.name));
            startup.lpDesktop = private_desktop.as_mut_ptr();
            // SAFETY: zero is a valid initial state for PROCESS_INFORMATION.
            let mut process: PROCESS_INFORMATION = unsafe { zeroed() };
            let mut environment =
                bootstrap_environment_block(&entry_checkpoint_path, &launch.nonce);
            let target_cmux_bench_environment_filtered =
                bootstrap_environment_has_only_entry_identity(&environment);
            if !target_cmux_bench_environment_filtered {
                bail!("restricted bootstrap environment retained a CMUX_BENCH secret");
            }
            // SAFETY: all strings are NUL-terminated and output storage remains live.
            check(
                unsafe {
                    CreateProcessWithTokenW(
                        self.account_token()?,
                        0,
                        application.as_ptr(),
                        command_line.as_mut_ptr(),
                        CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                        environment.as_mut_ptr().cast::<c_void>(),
                        current_directory.as_ptr(),
                        &startup,
                        &mut process,
                    )
                },
                "create suspended account-owned bootstrap",
            )?;
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ProcessCreatedSuspended));
            let process_handle = OwnedHandle(process.hProcess);
            let thread_handle = OwnedHandle(process.hThread);
            // SAFETY: both handles are live and the process is still suspended.
            if unsafe { AssignProcessToJobObject(self.job.0, process_handle.0) } == 0 {
                let error = std::io::Error::last_os_error();
                // SAFETY: process_handle is the suspended process created above.
                let _ = unsafe { TerminateProcess(process_handle.0, 125) };
                // SAFETY: process_handle remains live until the end of this scope.
                let _ = unsafe { WaitForSingleObject(process_handle.0, INFINITE) };
                return Err(error).context("assign bootstrap to non-breakaway job");
            }
            self.broker_assigned = true;
            self.private_desktop.bootstrap_assigned = true;
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::JobAssigned));
            let pipes = BootstrapPipes::create()?;
            let control_read = duplicate_into_process(
                pipes.bootstrap_read.0,
                process_handle.0,
                false,
                "bootstrap control read",
            )?;
            let control_write = duplicate_into_process(
                pipes.bootstrap_write.0,
                process_handle.0,
                false,
                "bootstrap control write",
            )?;
            let standard_handles = [
                duplicate_standard_handle(STD_INPUT_HANDLE, process_handle.0, "stdin")?,
                duplicate_standard_handle(STD_OUTPUT_HANDLE, process_handle.0, "stdout")?,
                duplicate_standard_handle(STD_ERROR_HANDLE, process_handle.0, "stderr")?,
            ];
            let query_job = self
                .query_job
                .as_ref()
                .map(|handle| {
                    duplicate_into_process(handle.0, process_handle.0, false, "private Job query")
                })
                .transpose()?;
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::HandlesDuplicated));
            let (config_bytes, config_sha256) = write_bootstrap_config(
                &config_path,
                &BootstrapConfig {
                    schema_version: BOOTSTRAP_SCHEMA_VERSION,
                    nonce: launch.nonce.clone(),
                    launch: BootstrapProductLaunch {
                        timing,
                        fixture_root: fixture_root.clone(),
                        target,
                        target_sha256: launch.target_sha256.clone(),
                        product_args: launch.product_args.clone(),
                        trusted_path_probe,
                        expected_bootstrap_sha256: launch.windows_bootstrap_sha256.clone(),
                        restricting_sid: self.restricting_sid_text.clone(),
                        private_desktop: self.private_desktop.name.clone(),
                    },
                    control_read,
                    control_write,
                    standard_handles,
                    query_job: query_job.context("private Job query handle is required")?,
                },
            )?;
            trace.record_config(config_bytes, config_sha256);
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ConfigWritten));
            // SAFETY: thread_handle is the suspended primary thread.
            let resume_previous_count = unsafe { ResumeThread(thread_handle.0) };
            if resume_previous_count != 1 {
                if resume_previous_count == u32::MAX {
                    return Err(std::io::Error::last_os_error())
                        .context("resume restricted bootstrap");
                }
                bail!(
                    "restricted bootstrap primary thread had suspend count {resume_previous_count}, expected 1"
                );
            }
            let resumed_at = Instant::now();
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ProcessResumed));
            let session = BootstrapSession::new(
                process_handle,
                thread_handle,
                pipes,
                BootstrapIdentity {
                    config_path,
                    entry_checkpoint_path,
                    trusted_probe,
                    bootstrap_binary,
                    bootstrap_sha256: launch.windows_bootstrap_sha256.clone(),
                    fixture_root,
                    nonce: launch.nonce.clone(),
                    resumed_at,
                    resume_previous_count,
                    process_id: process.dwProcessId,
                    primary_thread_id: process.dwThreadId,
                    target_cmux_bench_environment_filtered,
                    restricting_sid: self.restricting_sid_text.clone(),
                },
            )?;
            Ok(session)
        }

        fn cleanup(&mut self, deadline: Instant) -> Result<()> {
            if self.broker_assigned {
                self.terminate_descendants_and_wait_empty(deadline)?;
                self.broker_assigned = false;
            }
            self.private_desktop.close_after_job_empty()?;
            if Instant::now() >= deadline {
                bail!("Windows containment cleanup deadline expired before profile cleanup");
            }
            match self.profile.as_mut() {
                Some(profile) => profile.cleanup(),
                None => Ok(()),
            }
        }

        fn terminate_descendants_and_wait_empty(&self, deadline: Instant) -> Result<()> {
            // SAFETY: job is a live private Job Object owned by this supervisor.
            check(unsafe { TerminateJobObject(self.job.0, 125) }, "terminate contained job")?;
            loop {
                let remaining = deadline
                    .checked_duration_since(Instant::now())
                    .filter(|value| !value.is_zero())
                    .context("Job Object did not report ACTIVE_PROCESS_ZERO")?;
                let timeout_ms =
                    u32::try_from(remaining.as_millis().clamp(1, u128::from(u32::MAX)))?;
                let mut message = 0_u32;
                let mut key = 0_usize;
                let mut overlapped = null_mut();
                // SAFETY: all output pointers reference live storage for this blocking event read.
                check(
                    unsafe {
                        GetQueuedCompletionStatus(
                            self.completion_port.0,
                            &mut message,
                            &mut key,
                            &mut overlapped,
                            timeout_ms,
                        )
                    },
                    "wait for Job Object completion event",
                )?;
                if key == JOB_COMPLETION_KEY && message == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO {
                    return Ok(());
                }
            }
        }
    }

    struct BootstrapPipes {
        controller_read: OwnedHandle,
        controller_write: OwnedHandle,
        bootstrap_read: OwnedHandle,
        bootstrap_write: OwnedHandle,
    }

    impl BootstrapPipes {
        fn create() -> Result<Self> {
            let (bootstrap_read, controller_write) = create_pipe("bootstrap command")?;
            let (controller_read, bootstrap_write) = create_pipe("bootstrap event")?;
            Ok(Self { controller_read, controller_write, bootstrap_read, bootstrap_write })
        }
    }

    struct BootstrapSession {
        process: OwnedHandle,
        primary_thread: OwnedHandle,
        writer: Option<File>,
        receiver: mpsc::Receiver<BootstrapEvent>,
        reader: Option<thread::JoinHandle<()>>,
        status: Option<thread::JoinHandle<()>>,
        config_path: PathBuf,
        entry_checkpoint_path: PathBuf,
        trusted_probe: TrustedPathProbe,
        bootstrap_binary: PathBuf,
        bootstrap_sha256: String,
        fixture_root: PathBuf,
        nonce: String,
        resumed_at: Instant,
        resume_previous_count: u32,
        evidence: Option<BootstrapLaunchEvidence>,
        hang_diagnostic: Option<BootstrapHangArtifactReference>,
        hang_diagnostic_error: Option<String>,
        process_id: u32,
        primary_thread_id: u32,
        target_cmux_bench_environment_filtered: bool,
        restricting_sid: String,
        product_started_relayed: bool,
        product_process: Option<OwnedHandle>,
        product_primary_thread: Option<OwnedHandle>,
        product_process_id: Option<u32>,
        product_primary_thread_id: Option<u32>,
        native_exit_code: Option<u32>,
        product_status_timed_out: bool,
    }

    struct BootstrapIdentity {
        config_path: PathBuf,
        entry_checkpoint_path: PathBuf,
        trusted_probe: TrustedPathProbe,
        bootstrap_binary: PathBuf,
        bootstrap_sha256: String,
        fixture_root: PathBuf,
        nonce: String,
        resumed_at: Instant,
        resume_previous_count: u32,
        process_id: u32,
        primary_thread_id: u32,
        target_cmux_bench_environment_filtered: bool,
        restricting_sid: String,
    }

    enum BootstrapEvent {
        Message(BootstrapMessage),
        PipeEof,
        ProtocolError(String),
        ProcessExited(std::result::Result<u32, String>),
    }

    impl BootstrapSession {
        fn new(
            process: OwnedHandle,
            primary_thread: OwnedHandle,
            mut pipes: BootstrapPipes,
            identity: BootstrapIdentity,
        ) -> Result<Self> {
            let BootstrapIdentity {
                config_path,
                entry_checkpoint_path,
                trusted_probe,
                bootstrap_binary,
                bootstrap_sha256,
                fixture_root,
                nonce,
                resumed_at,
                resume_previous_count,
                process_id,
                primary_thread_id,
                target_cmux_bench_environment_filtered,
                restricting_sid,
            } = identity;
            let wait_handle =
                duplicate_current_process_handle(process.0, "restricted bootstrap status wait")?;
            let controller_read = pipes.controller_read.take();
            let controller_write = pipes.controller_write.take();
            drop(pipes);
            // SAFETY: ownership moved out of OwnedHandle and is transferred to File once.
            let mut reader = unsafe { File::from_raw_handle(controller_read as RawHandle) };
            // SAFETY: same one-owner transfer for the command pipe.
            let writer = unsafe { File::from_raw_handle(controller_write as RawHandle) };
            let (sender, receiver) = mpsc::channel();
            let reader_sender = sender.clone();
            let reader = thread::spawn(move || {
                loop {
                    let event = match read_event(&mut reader) {
                        Ok(None) => BootstrapEvent::PipeEof,
                        Ok(Some(message)) => BootstrapEvent::Message(message),
                        Err(error) => BootstrapEvent::ProtocolError(format!("{error:#}")),
                    };
                    let terminal =
                        matches!(event, BootstrapEvent::PipeEof | BootstrapEvent::ProtocolError(_));
                    if reader_sender.send(event).is_err() || terminal {
                        return;
                    }
                }
            });
            let status = thread::spawn(move || {
                let handle = OwnedHandle(wait_handle as HANDLE);
                let result = wait_process_exit_code(&handle).map_err(|error| format!("{error:#}"));
                let _ = sender.send(BootstrapEvent::ProcessExited(result));
            });
            Ok(Self {
                process,
                primary_thread,
                writer: Some(writer),
                receiver,
                reader: Some(reader),
                status: Some(status),
                config_path,
                entry_checkpoint_path,
                trusted_probe,
                bootstrap_binary,
                bootstrap_sha256,
                fixture_root,
                nonce,
                resumed_at,
                resume_previous_count,
                evidence: None,
                hang_diagnostic: None,
                hang_diagnostic_error: None,
                process_id,
                primary_thread_id,
                target_cmux_bench_environment_filtered,
                restricting_sid,
                product_started_relayed: false,
                product_process: None,
                product_primary_thread: None,
                product_process_id: None,
                product_primary_thread_id: None,
                native_exit_code: None,
                product_status_timed_out: false,
            })
        }

        fn capture_hang_snapshot(
            &mut self,
            owner: &WindowsLaunchOwner,
            launch: &Launch,
        ) -> Result<()> {
            match startup_benchmark_windows_diagnostic::capture(CaptureRequest {
                process: self.process.0,
                primary_thread: self.primary_thread.0,
                process_id: self.process_id,
                primary_thread_id: self.primary_thread_id,
                private_job: owner.job.0,
                fixture_root: &self.fixture_root,
                nonce: &self.nonce,
                supervisor_sha256: &launch.supervisor_sha256,
                target_cmux_bench_environment_filtered: self.target_cmux_bench_environment_filtered,
            }) {
                Ok(reference) => {
                    self.hang_diagnostic = Some(reference);
                    Ok(())
                }
                Err(error) => {
                    self.hang_diagnostic_error = Some(bounded_text(&format!("{error:#}"), 2_048));
                    Err(error)
                }
            }
        }

        fn record_private_desktop_cleanup(&mut self, owner: &WindowsLaunchOwner) -> Result<()> {
            let desktop = &owner.private_desktop;
            if !desktop.window_station_created
                || !desktop.desktop_created
                || !desktop.bootstrap_assigned
                || !desktop.product_assigned
                || !desktop.job_empty_observed
                || !desktop.desktop_closed
                || !desktop.window_station_closed
            {
                bail!("private desktop lifecycle proof is incomplete after Job cleanup");
            }
            let evidence = self
                .evidence
                .as_mut()
                .context("Windows bootstrap evidence is missing after private desktop cleanup")?;
            if evidence.private_desktop != desktop.name {
                bail!("private desktop cleanup identity does not match launch evidence");
            }
            evidence.private_desktop_closed_after_job_empty = true;
            Ok(())
        }

        fn capture_product_hang_snapshot(
            &mut self,
            owner: &WindowsLaunchOwner,
            launch: &Launch,
        ) -> Result<()> {
            let process = self
                .product_process
                .as_ref()
                .context("restricted product process handle was not retained")?;
            let primary_thread = self
                .product_primary_thread
                .as_ref()
                .context("restricted product primary-thread handle was not retained")?;
            let process_id = self
                .product_process_id
                .context("restricted product process ID was not retained")?;
            let primary_thread_id = self
                .product_primary_thread_id
                .context("restricted product primary-thread ID was not retained")?;
            match startup_benchmark_windows_diagnostic::capture(CaptureRequest {
                process: process.0,
                primary_thread: primary_thread.0,
                process_id,
                primary_thread_id,
                private_job: owner.job.0,
                fixture_root: &self.fixture_root,
                nonce: &self.nonce,
                supervisor_sha256: &launch.supervisor_sha256,
                target_cmux_bench_environment_filtered: self.target_cmux_bench_environment_filtered,
            }) {
                Ok(reference) => {
                    self.hang_diagnostic = Some(reference);
                    Ok(())
                }
                Err(error) => {
                    self.hang_diagnostic_error = Some(bounded_text(&format!("{error:#}"), 2_048));
                    Err(error)
                }
            }
        }

        fn retain_product_handles(
            &mut self,
            process_id: u32,
            primary_thread_id: u32,
            remote_process_handle: u64,
            remote_primary_thread_handle: u64,
        ) -> Result<()> {
            if self.product_process.is_some()
                || self.product_primary_thread.is_some()
                || self.product_process_id.is_some()
                || self.product_primary_thread_id.is_some()
            {
                bail!("restricted product handle identity was sent more than once");
            }
            if process_id == 0 || primary_thread_id == 0 {
                bail!("restricted product process or thread ID was zero");
            }
            let process = duplicate_from_process(
                self.process.0,
                remote_process_handle,
                "restricted product process",
            )?;
            let primary_thread = duplicate_from_process(
                self.process.0,
                remote_primary_thread_handle,
                "restricted product primary thread",
            )?;
            if unsafe { GetProcessId(process.0) } != process_id
                || unsafe { GetThreadId(primary_thread.0) } != primary_thread_id
            {
                bail!("restricted product transferred handle identity mismatch");
            }
            self.product_process = Some(process);
            self.product_primary_thread = Some(primary_thread);
            self.product_process_id = Some(process_id);
            self.product_primary_thread_id = Some(primary_thread_id);
            Ok(())
        }

        fn product_lifecycle(&self) -> Option<BootstrapProductLifecycleEvidence> {
            Some(BootstrapProductLifecycleEvidence {
                product_process_id: self.product_process_id?,
                product_primary_thread_id: self.product_primary_thread_id?,
                native_exit_received: self.native_exit_code.is_some(),
                native_exit_code: self.native_exit_code,
            })
        }

        fn wait_ready(&mut self, nonce: &str, trace: &mut BootstrapStartupTrace) -> Result<()> {
            let deadline = self
                .resumed_at
                .checked_add(BOOTSTRAP_STARTUP_TIMEOUT)
                .context("Windows native bootstrap loader deadline overflow")?;
            loop {
                let event = match self
                    .receive_until(deadline, "wait for restricted bootstrap READY")
                {
                    Ok(event) => event,
                    Err(error) if Instant::now() >= deadline => {
                        self.record_native_entry_checkpoint(trace).with_context(|| {
                            format!("read native entry checkpoint after loader timeout: {error:#}")
                        })?;
                        trace.observe(BootstrapObservedEvent::BootstrapTimeout);
                        return Err(error);
                    }
                    Err(error) => {
                        self.record_native_entry_checkpoint(trace).with_context(|| {
                            format!("read native entry checkpoint after READY failure: {error:#}")
                        })?;
                        trace.observe(BootstrapObservedEvent::Error);
                        return Err(error);
                    }
                };
                match event {
                    BootstrapEvent::Message(BootstrapMessage::Stage { nonce: observed, stage })
                        if observed == nonce =>
                    {
                        trace.observe(BootstrapObservedEvent::Stage(map_minimal_stage(stage)));
                    }
                    BootstrapEvent::Message(BootstrapMessage::Ready {
                        nonce: observed,
                        bootstrap_sha256,
                        config_consumed,
                        standard_handles_valid,
                        standard_handles_inheritable,
                        private_job_member,
                        trusted_path_write_denied,
                        bootstrap_write_denied,
                        se_increase_quota_present,
                        se_increase_quota_enabled,
                        restricted_token,
                        restricted_low_integrity,
                        restricted_no_enabled_privileges,
                        restricted_authentication_match,
                        restricting_sid_match,
                        write_restricted_created,
                        broker_authentication_id,
                        restricted_authentication_id,
                        restricting_sid,
                    }) if observed == nonce
                        && bootstrap_sha256 == self.bootstrap_sha256
                        && config_consumed
                        && standard_handles_valid
                        && standard_handles_inheritable
                        && private_job_member
                        && trusted_path_write_denied
                        && bootstrap_write_denied
                        && se_increase_quota_present
                        && se_increase_quota_enabled
                        && restricted_token
                        && restricted_low_integrity
                        && restricted_no_enabled_privileges
                        && restricted_authentication_match
                        && restricting_sid_match
                        && write_restricted_created
                        && restricting_sid == self.restricting_sid =>
                    {
                        if self.record_native_entry_checkpoint(trace)?
                            != Some(NativeEntryCheckpointStage::ConfigConsumed)
                        {
                            trace.observe(BootstrapObservedEvent::Error);
                            bail!(
                                "restricted bootstrap did not publish its consumed config checkpoint"
                            );
                        }
                        if self.config_path.exists() {
                            trace.observe(BootstrapObservedEvent::Error);
                            bail!("restricted bootstrap did not consume its launch config");
                        }
                        self.evidence = Some(BootstrapLaunchEvidence {
                            schema_version: BOOTSTRAP_SCHEMA_VERSION,
                            bootstrap_sha256,
                            config_nonce: observed,
                            config_consumed,
                            resume_previous_count: self.resume_previous_count,
                            ready_elapsed_ms: u64::try_from(self.resumed_at.elapsed().as_millis())
                                .unwrap_or(u64::MAX),
                            exact_job_proof: private_job_member,
                            trusted_path_write_denied,
                            bootstrap_write_denied,
                            restricting_sid,
                            broker_authentication_id: broker_authentication_id.evidence_value(),
                            restricted_authentication_id: restricted_authentication_id
                                .evidence_value(),
                            product_authentication_id: String::new(),
                            restricted_authentication_matches_broker:
                                restricted_authentication_match,
                            product_authentication_matches_broker: false,
                            se_increase_quota_present,
                            se_increase_quota_enabled,
                            create_process_as_user_succeeded: false,
                            restricted_token_write_restricted: write_restricted_created
                                && restricted_token
                                && restricting_sid_match,
                            restricted_token_restricting_sid_match: restricting_sid_match,
                            restricted_token_low_integrity: restricted_low_integrity,
                            restricted_token_no_enabled_privileges:
                                restricted_no_enabled_privileges,
                            product_write_restricted: false,
                            product_restricting_sid_match: false,
                            product_low_integrity: false,
                            product_no_enabled_privileges: false,
                            product_exact_job: false,
                            product_resume_previous_count: 0,
                            product_process_id: 0,
                            product_primary_thread_id: 0,
                            private_desktop: cmux_startup_bootstrap::private_desktop_name(
                                &self.nonce,
                            )?,
                            private_window_station_created: true,
                            private_desktop_created: true,
                            private_desktop_broker_assigned: true,
                            private_desktop_product_assigned: false,
                            private_desktop_closed_after_job_empty: false,
                        });
                        fs::remove_file(&self.entry_checkpoint_path).with_context(|| {
                            format!(
                                "remove consumed native entry checkpoint {}",
                                self.entry_checkpoint_path.display()
                            )
                        })?;
                        trace.observe(BootstrapObservedEvent::Ready);
                        return Ok(());
                    }
                    BootstrapEvent::Message(BootstrapMessage::Error {
                        nonce: observed,
                        windows_error,
                        stage,
                    }) if observed == nonce => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!(
                            "restricted bootstrap failed before READY at native stage {stage} with Windows error {windows_error}"
                        )
                    }
                    BootstrapEvent::ProcessExited(Ok(code)) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Exit(code));
                        bail!("restricted bootstrap exited before READY with code {code}")
                    }
                    BootstrapEvent::ProcessExited(Err(error)) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!("read restricted bootstrap exit state: {error}")
                    }
                    BootstrapEvent::PipeEof => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Eof);
                        bail!("restricted bootstrap event pipe closed before READY")
                    }
                    BootstrapEvent::ProtocolError(error) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!("restricted bootstrap event protocol failed: {error}")
                    }
                    _ => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!("restricted bootstrap READY evidence mismatch")
                    }
                }
            }
        }

        fn record_native_entry_checkpoint(
            &self,
            trace: &mut BootstrapStartupTrace,
        ) -> Result<Option<NativeEntryCheckpointStage>> {
            let bytes = match fs::read(&self.entry_checkpoint_path) {
                Ok(bytes) => bytes,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!(
                            "read native entry checkpoint {}",
                            self.entry_checkpoint_path.display()
                        )
                    });
                }
            };
            let stage = decode_native_entry_checkpoint(&bytes, &self.nonce)?;
            record_stage_once(trace, BootstrapStage::NativeEntryReached);
            if matches!(
                stage,
                NativeEntryCheckpointStage::ConfigReadStarted
                    | NativeEntryCheckpointStage::ConfigConsumed
            ) {
                record_stage_once(trace, BootstrapStage::NativeConfigReadStarted);
            }
            if stage == NativeEntryCheckpointStage::ConfigConsumed {
                record_stage_once(trace, BootstrapStage::ConfigConsumed);
            }
            Ok(Some(stage))
        }

        fn arm_and_wait(
            &mut self,
            nonce: &str,
            require_descendant: bool,
            public_control: &mut Box<dyn transport::Stream>,
        ) -> Result<ExitStatus> {
            let writer =
                self.writer.as_mut().context("Windows bootstrap command pipe is closed")?;
            let arm = encode_arm(nonce)?;
            writer.write_all(&arm)?;
            writer.flush()?;
            let deadline = Instant::now()
                .checked_add(CONTROL_TIMEOUT)
                .context("restricted product status deadline overflow")?;
            let mut product_started = false;
            let (code, contained) = loop {
                let event = match self.receive_until(deadline, "wait for restricted product status")
                {
                    Ok(event) => event,
                    Err(error) if Instant::now() >= deadline => {
                        self.product_status_timed_out = true;
                        return Err(error);
                    }
                    Err(error) => return Err(error),
                };
                match event {
                    BootstrapEvent::Message(BootstrapMessage::ProductStarted {
                        nonce: observed,
                        private_job_descendant_contained,
                        create_process_as_user_succeeded,
                        product_authentication_match,
                        product_low_integrity,
                        product_write_restricted,
                        product_no_enabled_privileges,
                        product_restricting_sid_match,
                        product_authentication_id,
                        resume_previous_count,
                        product_process_id,
                        product_primary_thread_id,
                        product_process_handle,
                        product_primary_thread_handle,
                    }) if observed == nonce => {
                        if product_started
                            || !private_job_descendant_contained
                            || !create_process_as_user_succeeded
                            || !product_authentication_match
                            || !product_low_integrity
                            || !product_write_restricted
                            || !product_no_enabled_privileges
                            || !product_restricting_sid_match
                            || resume_previous_count != 1
                        {
                            bail!("restricted bootstrap product-started evidence mismatch");
                        }
                        self.retain_product_handles(
                            product_process_id,
                            product_primary_thread_id,
                            product_process_handle,
                            product_primary_thread_handle,
                        )?;
                        let evidence = self
                            .evidence
                            .as_mut()
                            .context("Windows bootstrap READY evidence is missing")?;
                        evidence.product_authentication_id =
                            product_authentication_id.evidence_value();
                        evidence.product_authentication_matches_broker =
                            product_authentication_match;
                        evidence.create_process_as_user_succeeded =
                            create_process_as_user_succeeded;
                        evidence.product_write_restricted =
                            product_write_restricted && product_restricting_sid_match;
                        evidence.product_restricting_sid_match = product_restricting_sid_match;
                        evidence.product_low_integrity = product_low_integrity;
                        evidence.product_no_enabled_privileges = product_no_enabled_privileges;
                        evidence.product_exact_job = private_job_descendant_contained;
                        evidence.product_resume_previous_count = resume_previous_count;
                        evidence.product_process_id = product_process_id;
                        evidence.product_primary_thread_id = product_primary_thread_id;
                        evidence.private_desktop_product_assigned = true;
                        evidence.validate_started(&self.nonce, &self.bootstrap_sha256)?;
                        let adoption = encode_product_handles_adopted(nonce)?;
                        let writer = self
                            .writer
                            .as_mut()
                            .context("Windows bootstrap command pipe is closed")?;
                        writer.write_all(&adoption)?;
                        writer.flush()?;
                        write_control_line(
                            public_control,
                            &product_started_line(&self.nonce, evidence)?,
                        )?;
                        self.product_started_relayed = true;
                        product_started = true;
                    }
                    BootstrapEvent::Message(BootstrapMessage::Exit {
                        nonce: observed,
                        code,
                        private_job_descendant_contained,
                        create_process_as_user_succeeded,
                        product_authentication_match,
                        product_low_integrity,
                        product_write_restricted,
                        product_no_enabled_privileges,
                        product_restricting_sid_match,
                        product_authentication_id,
                    }) if observed == nonce => {
                        self.native_exit_code = Some(code);
                        let evidence = self
                            .evidence
                            .as_mut()
                            .context("Windows bootstrap READY evidence is missing")?;
                        if !product_started
                            || !private_job_descendant_contained
                            || !create_process_as_user_succeeded
                            || !product_authentication_match
                            || !product_low_integrity
                            || !product_write_restricted
                            || !product_no_enabled_privileges
                            || !product_restricting_sid_match
                            || product_authentication_id.evidence_value()
                                != evidence.product_authentication_id
                        {
                            bail!("restricted bootstrap exit evidence changed after product start");
                        }
                        if require_descendant {
                            write_control_line(public_control, &product_exit_line(nonce, code)?)?;
                        }
                        break (code, private_job_descendant_contained);
                    }
                    BootstrapEvent::Message(BootstrapMessage::Error {
                        nonce: observed,
                        windows_error,
                        stage,
                    }) if observed == nonce => {
                        bail!(
                            "restricted bootstrap product launch failed at native stage {stage} with Windows error {windows_error}"
                        )
                    }
                    BootstrapEvent::ProcessExited(Ok(_)) => {
                        // The event-pipe line can arrive after the process signal. Keep the one
                        // absolute deadline while the reader drains the already-written status.
                    }
                    BootstrapEvent::ProcessExited(Err(error)) => {
                        bail!("read restricted bootstrap product exit state: {error}")
                    }
                    BootstrapEvent::PipeEof => {
                        bail!("restricted bootstrap event pipe closed before product status")
                    }
                    BootstrapEvent::ProtocolError(error) => {
                        bail!("restricted bootstrap event protocol failed: {error}")
                    }
                    _ => bail!("restricted bootstrap exit evidence mismatch"),
                }
            };
            if require_descendant && !contained {
                bail!(
                    "restricted bootstrap did not prove its surviving descendant in the private Job"
                );
            }
            wait_process(&self.process, CONTROL_TIMEOUT, "restricted bootstrap exit")?;
            Ok(ExitStatus::from_raw(code))
        }

        fn receive_until(&self, deadline: Instant, operation: &str) -> Result<BootstrapEvent> {
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero());
            let Some(remaining) = remaining else {
                bail!("{operation}: deadline expired");
            };
            match self.receiver.recv_timeout(remaining) {
                Ok(event) => Ok(event),
                Err(mpsc::RecvTimeoutError::Timeout) => bail!("{operation}: deadline expired"),
                Err(error) => Err(error).context(operation.to_string()),
            }
        }

        fn finish(&mut self, deadline: Instant) -> Result<()> {
            self.writer.take();
            wait_process_until(&self.process, deadline, "restricted bootstrap cleanup")?;
            if let Some(reader) = self.reader.take() {
                reader.join().map_err(|_| anyhow::anyhow!("bootstrap reader thread panicked"))?;
            }
            if let Some(status) = self.status.take() {
                status.join().map_err(|_| anyhow::anyhow!("bootstrap status thread panicked"))?;
            }
            verify_file_sha256(
                &self.bootstrap_binary,
                &self.bootstrap_sha256,
                "dedicated Windows bootstrap after containment cleanup",
            )?;
            match fs::remove_file(&self.entry_checkpoint_path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!(
                            "remove native entry checkpoint {}",
                            self.entry_checkpoint_path.display()
                        )
                    });
                }
            }
            self.trusted_probe.verify_and_remove()?;
            if let Some(evidence) = &self.evidence {
                evidence.validate(&self.nonce, &self.bootstrap_sha256)?;
                let evidence_path = self
                    .fixture_root
                    .join(format!("windows-bootstrap-evidence-{}.json", &self.nonce[..16]));
                let bytes = serde_json::to_vec_pretty(evidence)?;
                let mut file = fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&evidence_path)
                    .with_context(|| {
                        format!("create Windows bootstrap evidence {}", evidence_path.display())
                    })?;
                file.write_all(&bytes)?;
                file.write_all(b"\n")?;
                file.flush()?;
            }
            Ok(())
        }
    }

    fn map_minimal_stage(stage: BootstrapChildStage) -> BootstrapStage {
        match stage {
            BootstrapChildStage::ConfigConsumed => BootstrapStage::ConfigConsumed,
            BootstrapChildStage::LaunchValidated => BootstrapStage::LaunchValidated,
            BootstrapChildStage::StandardHandlesValidated => {
                BootstrapStage::StandardHandlesValidated
            }
            BootstrapChildStage::TimingConsumed => BootstrapStage::TimingConsumed,
            BootstrapChildStage::NativeEntryReached => BootstrapStage::NativeEntryReached,
            BootstrapChildStage::NativeConfigReadStarted => BootstrapStage::NativeConfigReadStarted,
            BootstrapChildStage::RestrictedProductTokenReady => {
                BootstrapStage::RestrictedProductTokenReady
            }
        }
    }

    fn record_stage_once(trace: &mut BootstrapStartupTrace, stage: BootstrapStage) {
        if !trace.stages.iter().any(|observation| observation.stage == stage) {
            trace.observe(BootstrapObservedEvent::Stage(stage));
        }
    }

    fn finish_failed_bootstrap_startup(
        launch: &Launch,
        control: &mut Box<dyn transport::Stream>,
        mut trace: BootstrapStartupTrace,
        error: anyhow::Error,
        owner: Option<&mut WindowsLaunchOwner>,
        mut bootstrap: Option<&mut BootstrapSession>,
    ) -> Result<ExitStatus> {
        if trace.terminal.is_none() {
            trace.observe(BootstrapObservedEvent::Error);
        }
        let config_present = bootstrap_config_path(launch).is_file();
        let reason = bounded_text(&format!("{error:#}"), 2_048);
        let hang_diagnostic = bootstrap.as_deref().and_then(|value| value.hang_diagnostic.as_ref());
        let hang_diagnostic_error =
            bootstrap.as_deref().and_then(|value| value.hang_diagnostic_error.as_deref());
        let product_lifecycle = bootstrap.as_deref().and_then(BootstrapSession::product_lifecycle);
        let checkpoint = BootstrapFailureCheckpoint {
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
            record_type: "startup-failure",
            nonce: &launch.nonce,
            reason: &reason,
            config_present_after_failure: config_present,
            trace: &trace,
            product_lifecycle: product_lifecycle.as_ref(),
            hang_diagnostic,
            hang_diagnostic_error,
        };
        let checkpoint_result = create_bootstrap_failure_checkpoint(launch, &checkpoint);
        let cleanup_deadline = Instant::now()
            .checked_add(BOOTSTRAP_CLEANUP_TIMEOUT)
            .context("Windows failed-startup cleanup deadline overflow")?;
        let containment_started = owner.is_some();
        let bootstrap_started = bootstrap.is_some();
        let containment_result = match owner {
            Some(owner) => {
                owner.private_desktop.product_assigned =
                    bootstrap.as_deref().is_some_and(|value| value.product_started_relayed);
                let mut cleanup = owner.cleanup(cleanup_deadline);
                if cleanup.is_ok()
                    && let Some(bootstrap) = bootstrap.as_deref_mut()
                    && bootstrap.product_started_relayed
                {
                    cleanup = bootstrap.record_private_desktop_cleanup(owner);
                }
                cleanup
            }
            None => Ok(()),
        };
        let bootstrap_result = match bootstrap {
            Some(bootstrap) => bootstrap.finish(cleanup_deadline),
            None => Ok(()),
        };
        let containment_cleanup = cleanup_checkpoint(&containment_result, containment_started);
        let bootstrap_cleanup = cleanup_checkpoint(&bootstrap_result, bootstrap_started);
        let cleanup_checkpoint = BootstrapCleanupCheckpoint {
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
            record_type: "cleanup-result",
            nonce: &launch.nonce,
            containment_cleanup: &containment_cleanup,
            bootstrap_cleanup: &bootstrap_cleanup,
        };
        let (checkpoint_name, checkpoint_append_error) = match checkpoint_result {
            Ok((name, mut file)) => {
                let result = append_bootstrap_cleanup_checkpoint(&mut file, &cleanup_checkpoint);
                (Some(name), result.err())
            }
            Err(checkpoint) => (None, Some(checkpoint)),
        };
        let failure = failure_line(&launch.nonce, checkpoint_name.as_deref())?;
        write_control_line(control, &failure)?;
        control.shutdown(std::net::Shutdown::Both)?;

        let mut details = Vec::new();
        if let Err(cleanup) = containment_result {
            details.push(format!("containment cleanup failed: {cleanup:#}"));
        }
        if let Err(cleanup) = bootstrap_result {
            details.push(format!("bootstrap cleanup failed: {cleanup:#}"));
        }
        if let Some(checkpoint) = checkpoint_append_error {
            details.push(format!("bootstrap checkpoint failed: {checkpoint:#}"));
        }
        if details.is_empty() { Err(error) } else { Err(error.context(details.join("; "))) }
    }

    fn cleanup_checkpoint(result: &Result<()>, started: bool) -> BootstrapCleanupResult {
        if !started {
            return BootstrapCleanupResult::not_started();
        }
        match result {
            Ok(()) => BootstrapCleanupResult::completed(),
            Err(error) => {
                BootstrapCleanupResult::failed(bounded_text(&format!("{error:#}"), 1_024))
            }
        }
    }

    fn create_bootstrap_failure_checkpoint(
        launch: &Launch,
        checkpoint: &BootstrapFailureCheckpoint<'_>,
    ) -> Result<(String, File)> {
        let name = format!("bootstrap-failure-{}.json", &launch.nonce[..16]);
        let bytes = serde_json::to_vec(checkpoint)?;
        if bytes.len() > MAX_BOOTSTRAP_CHECKPOINT_BYTES / 2 {
            bail!("Windows bootstrap failure checkpoint exceeded its bound");
        }
        let path = launch.fixture_root.join(&name);
        let mut file =
            fs::OpenOptions::new().write(true).create_new(true).open(&path).with_context(|| {
                format!("create bootstrap failure checkpoint {}", path.display())
            })?;
        file.write_all(&bytes)?;
        file.write_all(b"\n")?;
        file.flush()?;
        Ok((name, file))
    }

    fn append_bootstrap_cleanup_checkpoint(
        file: &mut File,
        checkpoint: &BootstrapCleanupCheckpoint<'_>,
    ) -> Result<()> {
        let bytes = serde_json::to_vec(checkpoint)?;
        let final_size = file
            .metadata()?
            .len()
            .checked_add(u64::try_from(bytes.len())?)
            .and_then(|size| size.checked_add(1))
            .context("Windows bootstrap checkpoint size overflow")?;
        if final_size > u64::try_from(MAX_BOOTSTRAP_CHECKPOINT_BYTES)? {
            bail!("Windows bootstrap cleanup checkpoint exceeded its bound");
        }
        file.write_all(&bytes)?;
        file.write_all(b"\n")?;
        file.flush()?;
        Ok(())
    }

    fn bounded_text(value: &str, maximum: usize) -> String {
        if value.len() <= maximum {
            return value.to_string();
        }
        let mut end = maximum;
        while !value.is_char_boundary(end) {
            end -= 1;
        }
        format!("{}...", &value[..end])
    }

    fn create_pipe(name: &str) -> Result<(OwnedHandle, OwnedHandle)> {
        let mut read = null_mut();
        let mut write = null_mut();
        check(
            unsafe { CreatePipe(&mut read, &mut write, null(), 0) },
            &format!("create Windows {name} pipe"),
        )?;
        Ok((OwnedHandle(read), OwnedHandle(write)))
    }

    fn duplicate_standard_handle(kind: u32, process: HANDLE, name: &str) -> Result<usize> {
        let source = unsafe { GetStdHandle(kind) };
        if source.is_null() || source == INVALID_HANDLE_VALUE {
            bail!("Windows supervisor {name} handle is invalid");
        }
        if unsafe { GetFileType(source) } == FILE_TYPE_UNKNOWN {
            bail!("Windows supervisor {name} handle has an unknown type");
        }
        duplicate_into_process(source, process, true, name)
    }

    fn duplicate_into_process(
        source: HANDLE,
        process: HANDLE,
        inheritable: bool,
        name: &str,
    ) -> Result<usize> {
        let mut target = null_mut();
        check(
            unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    source,
                    process,
                    &mut target,
                    0,
                    i32::from(inheritable),
                    DUPLICATE_SAME_ACCESS,
                )
            },
            &format!("duplicate Windows {name} handle into bootstrap"),
        )?;
        Ok(target as usize)
    }

    fn duplicate_current_process_handle(source: HANDLE, name: &str) -> Result<usize> {
        let mut target = null_mut();
        check(
            unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    source,
                    GetCurrentProcess(),
                    &mut target,
                    0,
                    0,
                    DUPLICATE_SAME_ACCESS,
                )
            },
            &format!("duplicate Windows {name}"),
        )?;
        Ok(target as usize)
    }

    fn duplicate_from_process(process: HANDLE, source: u64, name: &str) -> Result<OwnedHandle> {
        let source = usize::try_from(source)? as HANDLE;
        if source.is_null() || source == INVALID_HANDLE_VALUE {
            bail!("Windows {name} handle identity is invalid");
        }
        let mut target = null_mut();
        check(
            unsafe {
                DuplicateHandle(
                    process,
                    source,
                    GetCurrentProcess(),
                    &mut target,
                    0,
                    0,
                    DUPLICATE_SAME_ACCESS,
                )
            },
            &format!("duplicate Windows {name} handle from bootstrap"),
        )?;
        Ok(OwnedHandle(target))
    }

    fn bootstrap_config_path(launch: &Launch) -> PathBuf {
        launch.fixture_root.join(format!("bootstrap-{}.bin", &launch.nonce[..16]))
    }

    fn write_bootstrap_config(path: &Path, config: &BootstrapConfig) -> Result<(u64, String)> {
        config.validate_identity(path)?;
        let bytes = encode_config(config)?;
        let digest = format!("{:x}", Sha256::digest(&bytes));
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .with_context(|| format!("create Windows bootstrap config {}", path.display()))?;
        file.write_all(&bytes)?;
        file.flush()?;
        drop(file);
        Ok((u64::try_from(bytes.len())?, digest))
    }

    fn wait_process(process: &OwnedHandle, timeout: Duration, operation: &str) -> Result<()> {
        let timeout_ms = u32::try_from(timeout.as_millis().min(u128::from(u32::MAX)))?;
        match unsafe { WaitForSingleObject(process.0, timeout_ms) } {
            WAIT_OBJECT_0 => Ok(()),
            WAIT_TIMEOUT => bail!("{operation} exceeded its deadline"),
            _ => Err(std::io::Error::last_os_error()).context(operation.to_string()),
        }
    }

    fn wait_process_until(process: &OwnedHandle, deadline: Instant, operation: &str) -> Result<()> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .with_context(|| format!("{operation} deadline expired"))?;
        wait_process(process, remaining, operation)
    }

    fn wait_process_exit_code(process: &OwnedHandle) -> Result<u32> {
        // SAFETY: process is a live duplicated process handle owned by this thread.
        if unsafe { WaitForSingleObject(process.0, INFINITE) } != WAIT_OBJECT_0 {
            return Err(std::io::Error::last_os_error())
                .context("wait for restricted bootstrap status");
        }
        let mut code = 0_u32;
        check(
            unsafe { GetExitCodeProcess(process.0, &mut code) },
            "read restricted bootstrap status",
        )?;
        Ok(code)
    }

    fn combine_windows_results(
        result: Result<ExitStatus>,
        cleanup: Result<()>,
        bootstrap_cleanup: Result<()>,
    ) -> Result<ExitStatus> {
        let mut cleanup_errors = Vec::new();
        if let Err(error) = cleanup {
            cleanup_errors.push(format!("containment cleanup failed: {error:#}"));
        }
        if let Err(error) = bootstrap_cleanup {
            cleanup_errors.push(format!("bootstrap cleanup failed: {error:#}"));
        }
        match (result, cleanup_errors.is_empty()) {
            (Ok(status), true) => Ok(status),
            (Ok(_), false) => bail!("{}", cleanup_errors.join("; ")),
            (Err(error), true) => Err(error),
            (Err(error), false) => Err(error.context(cleanup_errors.join("; "))),
        }
    }

    const JOB_COMPLETION_KEY: usize = 0x434d_5558;

    fn security_remaining(
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
        operation: &str,
    ) -> Result<Duration> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero());
        let Some(remaining) = remaining else {
            trace.observe(BootstrapObservedEvent::SecurityTimeout);
            bail!("Windows security preparation exceeded its deadline after {operation}");
        };
        Ok(remaining)
    }

    fn check_security_deadline(
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
        operation: &str,
    ) -> Result<()> {
        // LogonUserW and LoadUserProfileW are synchronous and do not expose a cancellation
        // handle. A late return is detected here and fails closed through the shared cleanup.
        security_remaining(deadline, trace, operation).map(|_| ())
    }

    fn complete_security_stage(
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
        stage: BootstrapStage,
        operation: &str,
    ) -> Result<()> {
        trace.observe(BootstrapObservedEvent::Stage(stage));
        check_security_deadline(deadline, trace, operation)
    }

    fn ensure_caller_impersonate_privilege(
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<()> {
        let mut token = null_mut();
        // SAFETY: token points to writable handle storage.
        check(
            unsafe {
                OpenProcessToken(
                    GetCurrentProcess(),
                    TOKEN_QUERY | TOKEN_ADJUST_PRIVILEGES,
                    &mut token,
                )
            },
            "open supervisor process token",
        )?;
        let token = OwnedHandle(token);
        check_security_deadline(deadline, trace, "open supervisor process token")?;
        let mut luid = Default::default();
        // SAFETY: the privilege name is a static NUL-terminated string and luid is writable.
        check(
            unsafe { LookupPrivilegeValueW(null(), SE_IMPERSONATE_NAME, &mut luid) },
            "resolve SeImpersonatePrivilege",
        )?;
        check_security_deadline(deadline, trace, "resolve SeImpersonatePrivilege")?;
        let privileges = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }],
        };
        // AdjustTokenPrivileges reports an absent privilege through last-error on success.
        unsafe { SetLastError(ERROR_SUCCESS) };
        // SAFETY: token is live and privileges describes one initialized entry.
        check(
            unsafe { AdjustTokenPrivileges(token.0, 0, &privileges, 0, null_mut(), null_mut()) },
            "enable SeImpersonatePrivilege",
        )?;
        let adjust_error = unsafe { GetLastError() };
        check_security_deadline(deadline, trace, "enable SeImpersonatePrivilege")?;
        // AdjustTokenPrivileges can succeed while reporting that the privilege was absent.
        if adjust_error == ERROR_NOT_ALL_ASSIGNED {
            bail!("supervisor token does not contain SeImpersonatePrivilege");
        }
        let mut required = PRIVILEGE_SET {
            PrivilegeCount: 1,
            Control: PRIVILEGE_SET_ALL_NECESSARY,
            Privilege: [LUID_AND_ATTRIBUTES { Luid: luid, Attributes: SE_PRIVILEGE_ENABLED }],
        };
        let mut enabled = 0;
        // SAFETY: token and required are live, and enabled is writable.
        check(
            unsafe { PrivilegeCheck(token.0, &mut required, &mut enabled) },
            "verify SeImpersonatePrivilege",
        )?;
        check_security_deadline(deadline, trace, "verify SeImpersonatePrivilege")?;
        if enabled == 0 {
            bail!("supervisor SeImpersonatePrivilege is not enabled");
        }
        Ok(())
    }

    fn current_process_token() -> Result<OwnedHandle> {
        let mut token = null_mut();
        // SAFETY: token points to writable handle storage.
        check(
            unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
            "open trusted supervisor token for SID",
        )?;
        Ok(OwnedHandle(token))
    }

    fn token_user_sid_text(token: HANDLE) -> Result<String> {
        let mut required = 0_u32;
        // SAFETY: the first call requests the required buffer length.
        unsafe { GetTokenInformation(token, TokenUser, null_mut(), 0, &mut required) };
        if required < u32::try_from(size_of::<TOKEN_USER>())? {
            return Err(io::Error::last_os_error()).context("size Windows token user SID");
        }
        let mut bytes = vec![0_u8; usize::try_from(required)?];
        // SAFETY: bytes has exactly the size returned by the first call.
        check(
            unsafe {
                GetTokenInformation(
                    token,
                    TokenUser,
                    bytes.as_mut_ptr().cast(),
                    required,
                    &mut required,
                )
            },
            "read Windows token user SID",
        )?;
        // SAFETY: GetTokenInformation initialized a TOKEN_USER at the buffer start.
        let user = unsafe { &*bytes.as_ptr().cast::<TOKEN_USER>() };
        let mut text = null_mut();
        // SAFETY: user SID is live and text points to writable PWSTR storage.
        check(
            unsafe { ConvertSidToStringSidW(user.User.Sid, &mut text) },
            "format Windows token user SID",
        )?;
        let value = wide_pointer_to_string(text)?;
        // SAFETY: ConvertSidToStringSidW allocated text with LocalAlloc.
        unsafe { LocalFree(text.cast()) };
        Ok(value)
    }

    fn wide_pointer_to_string(value: *const u16) -> Result<String> {
        if value.is_null() {
            bail!("Windows wide string pointer is null");
        }
        let mut length = 0_usize;
        // SAFETY: callers pass a NUL-terminated Win32-owned string.
        while unsafe { *value.add(length) } != 0 {
            length = length.checked_add(1).context("Windows wide string length overflow")?;
            if length > 256 {
                bail!("Windows wide string exceeds 256 code units");
            }
        }
        // SAFETY: the scan above proved this initialized range ends before the NUL.
        String::from_utf16(unsafe { std::slice::from_raw_parts(value, length) })
            .context("decode Windows wide string")
    }

    fn private_object_security_descriptor(
        trusted_sid: &str,
        account_sid: &str,
        restricting_sid: &str,
        trusted_access: u32,
        contained_access: u32,
    ) -> Result<OwnedSecurityDescriptor> {
        let sddl = format!(
            "D:P(A;;0x{trusted_access:08x};;;{trusted_sid})(A;;0x{contained_access:08x};;;{account_sid})(A;;0x{contained_access:08x};;;{restricting_sid})S:(ML;;NW;;;LW)"
        );
        OwnedSecurityDescriptor::from_sddl(&sddl)
    }

    fn create_non_breakaway_job(
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<(OwnedHandle, Option<OwnedHandle>, OwnedHandle)> {
        // SAFETY: null security attributes and name request an unnamed private job.
        let job = unsafe { CreateJobObjectW(null(), null()) };
        if job.is_null() {
            return Err(std::io::Error::last_os_error()).context("create containment job");
        }
        let job = OwnedHandle(job);
        check_security_deadline(deadline, trace, "create containment Job")?;
        let mut query_job = null_mut();
        // SAFETY: the source and target process are current, the source job is live, and output
        // is writable. The trusted bootstrap closes this non-inheritable, query-only duplicate.
        // Its explicit product handle list contains only stdin, stdout, and stderr.
        check(
            unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    job.0,
                    GetCurrentProcess(),
                    &mut query_job,
                    JOB_OBJECT_QUERY,
                    0,
                    0,
                )
            },
            "duplicate query-only containment Job handle",
        )?;
        let query_job = Some(OwnedHandle(query_job));
        check_security_deadline(deadline, trace, "duplicate Job query handle")?;
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        // SAFETY: limits points to the exact structure named by the information class.
        check(
            unsafe {
                SetInformationJobObject(
                    job.0,
                    JobObjectExtendedLimitInformation,
                    (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                    u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())?,
                )
            },
            "configure kill-on-close non-breakaway job",
        )?;
        check_security_deadline(deadline, trace, "configure containment Job limits")?;
        // SAFETY: INVALID_HANDLE_VALUE requests a new completion port.
        let completion_port =
            unsafe { CreateIoCompletionPort(INVALID_HANDLE_VALUE, null_mut(), 0, 1) };
        if completion_port.is_null() {
            return Err(std::io::Error::last_os_error())
                .context("create Job Object completion port");
        }
        let completion_port = OwnedHandle(completion_port);
        check_security_deadline(deadline, trace, "create Job completion port")?;
        let association = JOBOBJECT_ASSOCIATE_COMPLETION_PORT {
            CompletionKey: JOB_COMPLETION_KEY as *mut c_void,
            CompletionPort: completion_port.0,
        };
        // SAFETY: association points to the exact structure named by the information class.
        check(
            unsafe {
                SetInformationJobObject(
                    job.0,
                    JobObjectAssociateCompletionPortInformation,
                    (&association as *const JOBOBJECT_ASSOCIATE_COMPLETION_PORT).cast(),
                    u32::try_from(size_of::<JOBOBJECT_ASSOCIATE_COMPLETION_PORT>())?,
                )
            },
            "associate Job Object completion port",
        )?;
        check_security_deadline(deadline, trace, "associate Job completion port")?;
        Ok((job, query_job, completion_port))
    }

    fn configure_fixture_acl(
        root: &Path,
        user: &str,
        sid: PSID,
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<()> {
        let root_text = root.to_string_lossy();
        run_acl(
            [root_text.as_ref(), "/grant", &format!("{user}:(OI)(CI)(F)"), "/T", "/C"],
            deadline,
            trace,
        )?;
        complete_security_stage(
            deadline,
            trace,
            BootstrapStage::AccountAclApplied,
            "apply benchmark account ACL",
        )?;
        grant_restricting_sid_tree(root, sid, deadline, trace)?;
        complete_security_stage(
            deadline,
            trace,
            BootstrapStage::RestrictingSidAclApplied,
            "apply restricting-SID ACL",
        )?;
        run_acl(
            [root_text.as_ref(), "/setintegritylevel", "(OI)(CI)L", "/T", "/C"],
            deadline,
            trace,
        )?;
        complete_security_stage(
            deadline,
            trace,
            BootstrapStage::LowIntegrityAclApplied,
            "apply low-integrity ACL",
        )
    }

    fn grant_restricting_sid_tree(
        path: &Path,
        sid: PSID,
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<()> {
        check_security_deadline(deadline, trace, "walk restricting-SID ACL tree")?;
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() {
            bail!("Windows benchmark fixture contains a symbolic link: {}", path.display());
        }
        grant_restricting_sid(path, sid, metadata.is_dir(), deadline, trace)?;
        if metadata.is_dir() {
            for entry in fs::read_dir(path)? {
                check_security_deadline(deadline, trace, "walk restricting-SID ACL entries")?;
                grant_restricting_sid_tree(&entry?.path(), sid, deadline, trace)?;
            }
        }
        Ok(())
    }

    fn grant_restricting_sid(
        path: &Path,
        sid: PSID,
        container: bool,
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<()> {
        let path = wide(path.as_os_str());
        let mut old_dacl: *mut ACL = null_mut();
        let mut security_descriptor: PSECURITY_DESCRIPTOR = null_mut();
        // SAFETY: path is NUL-terminated and the requested output pointers are writable.
        check_windows_error(
            unsafe {
                GetNamedSecurityInfoW(
                    path.as_ptr(),
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    null_mut(),
                    null_mut(),
                    &mut old_dacl,
                    null_mut(),
                    &mut security_descriptor,
                )
            },
            "read Windows fixture DACL",
        )?;
        if let Err(error) = check_security_deadline(deadline, trace, "read Windows fixture DACL") {
            // SAFETY: GetNamedSecurityInfoW allocated this descriptor with LocalAlloc.
            unsafe { LocalFree(security_descriptor.cast()) };
            return Err(error);
        }
        let entry = EXPLICIT_ACCESS_W {
            grfAccessPermissions: GENERIC_ALL,
            grfAccessMode: GRANT_ACCESS,
            grfInheritance: if container { SUB_CONTAINERS_AND_OBJECTS_INHERIT } else { 0 },
            Trustee: TRUSTEE_W {
                pMultipleTrustee: null_mut(),
                MultipleTrusteeOperation: NO_MULTIPLE_TRUSTEE,
                TrusteeForm: TRUSTEE_IS_SID,
                TrusteeType: TRUSTEE_IS_UNKNOWN,
                ptstrName: sid.cast::<u16>(),
            },
        };
        let mut new_dacl: *mut ACL = null_mut();
        // SAFETY: the explicit SID entry and old DACL remain live for this allocation call.
        let build_result = unsafe { SetEntriesInAclW(1, &entry, old_dacl, &mut new_dacl) };
        if build_result != 0 {
            // SAFETY: GetNamedSecurityInfoW allocated this descriptor with LocalAlloc.
            unsafe { LocalFree(security_descriptor.cast()) };
            return check_windows_error(build_result, "build Windows restricting-SID DACL");
        }
        if let Err(error) =
            check_security_deadline(deadline, trace, "build Windows restricting-SID DACL")
        {
            // SAFETY: both ACL APIs allocated these buffers with LocalAlloc.
            unsafe {
                LocalFree(new_dacl.cast());
                LocalFree(security_descriptor.cast());
            }
            return Err(error);
        }
        // SAFETY: path and the merged DACL remain live for this assignment call.
        let assign_result = unsafe {
            SetNamedSecurityInfoW(
                path.as_ptr(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                new_dacl,
                null_mut(),
            )
        };
        // SAFETY: both ACL APIs allocate their returned buffers with LocalAlloc.
        unsafe {
            LocalFree(new_dacl.cast());
            LocalFree(security_descriptor.cast());
        }
        check_windows_error(assign_result, "assign Windows restricting-SID DACL")?;
        check_security_deadline(deadline, trace, "assign Windows restricting-SID DACL")
    }

    fn check_windows_error(error: u32, operation: &str) -> Result<()> {
        if error == 0 {
            return Ok(());
        }
        let error = i32::try_from(error).context("Windows error code exceeded i32")?;
        Err(std::io::Error::from_raw_os_error(error)).context(operation.to_string())
    }

    fn run_acl<const N: usize>(
        arguments: [&str; N],
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<()> {
        let remaining = security_remaining(deadline, trace, "start icacls")?;
        let mut child = Command::new("icacls.exe")
            .args(arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let wait_ms = u32::try_from(remaining.as_millis().clamp(1, u128::from(u32::MAX)))?;
        // SAFETY: Child owns a live process handle for this bounded wait.
        let wait = unsafe { WaitForSingleObject(child.as_raw_handle() as HANDLE, wait_ms) };
        if wait == WAIT_TIMEOUT {
            trace.observe(BootstrapObservedEvent::SecurityTimeout);
            let _ = child.kill();
            let output = child.wait_with_output()?;
            bail!(
                "Windows security preparation exceeded its deadline while running icacls: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        if wait != WAIT_OBJECT_0 {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::last_os_error()).context("wait for bounded icacls");
        }
        let output = child.wait_with_output()?;
        if !output.status.success() {
            bail!(
                "icacls failed with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            );
        }
        check_security_deadline(deadline, trace, "complete icacls")
    }

    fn random_restricting_sid() -> Result<String> {
        let mut random = [0_u8; 16];
        getrandom::fill(&mut random).map_err(|error| anyhow::anyhow!(error.to_string()))?;
        let parts = random.chunks_exact(4).map(|chunk| {
            u32::from_le_bytes(chunk.try_into().expect("four-byte SID component")) | 1
        });
        Ok(format!(
            "S-1-5-21-{}",
            parts.map(|value| value.to_string()).collect::<Vec<_>>().join("-")
        ))
    }

    fn windows_command_line(program: &Path, arguments: &[String]) -> String {
        std::iter::once(program.to_string_lossy().into_owned())
            .chain(arguments.iter().cloned())
            .map(|argument| quote_windows_argument(&argument))
            .collect::<Vec<_>>()
            .join(" ")
    }

    const ENTRY_CHECKPOINT_PATH_ENV: &str = "CMUX_BENCH_BOOTSTRAP_ENTRY_CHECKPOINT";
    const ENTRY_NONCE_ENV: &str = "CMUX_BENCH_BOOTSTRAP_ENTRY_NONCE";

    fn bootstrap_environment_block(entry_checkpoint_path: &Path, nonce: &str) -> Vec<u16> {
        bootstrap_environment_block_from(env::vars_os(), entry_checkpoint_path, nonce)
    }

    fn bootstrap_environment_block_from(
        environment: impl IntoIterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
        entry_checkpoint_path: &Path,
        nonce: &str,
    ) -> Vec<u16> {
        let mut values = environment
            .into_iter()
            .filter_map(|(key, value)| {
                let key = key.to_string_lossy();
                if key.eq_ignore_ascii_case("CMUX_BENCH_WINDOWS_USER")
                    || key.eq_ignore_ascii_case("CMUX_BENCH_WINDOWS_PASSWORD")
                    || key.to_ascii_uppercase().starts_with("CMUX_BENCH_")
                {
                    return None;
                }
                Some(format!("{key}={}", value.to_string_lossy()))
            })
            .collect::<Vec<_>>();
        values.push(format!(
            "{ENTRY_CHECKPOINT_PATH_ENV}={}",
            entry_checkpoint_path.to_string_lossy()
        ));
        values.push(format!("{ENTRY_NONCE_ENV}={nonce}"));
        values.sort_by_key(|value| value.to_ascii_uppercase());
        let mut block = Vec::new();
        for value in values {
            block.extend(std::ffi::OsStr::new(&value).encode_wide());
            block.push(0);
        }
        block.push(0);
        block
    }

    fn bootstrap_environment_has_only_entry_identity(block: &[u16]) -> bool {
        block
            .split(|value| *value == 0)
            .take_while(|value| !value.is_empty())
            .filter_map(|value| String::from_utf16(value).ok())
            .filter_map(|value| value.split_once('=').map(|(key, _)| key.to_owned()))
            .all(|key| {
                !key.to_ascii_uppercase().starts_with("CMUX_BENCH_")
                    || key.eq_ignore_ascii_case(ENTRY_CHECKPOINT_PATH_ENV)
                    || key.eq_ignore_ascii_case(ENTRY_NONCE_ENV)
            })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn bootstrap_environment_binds_only_the_trusted_entry_identity() {
            let nonce = "ab".repeat(32);
            let block = bootstrap_environment_block_from(
                [
                    ("PATH".into(), "trusted-path".into()),
                    ("CMUX_BENCH_EXISTING".into(), "forbidden".into()),
                    ("CMUX_BENCH_WINDOWS_PASSWORD".into(), "secret".into()),
                ],
                Path::new(r"C:\fixture\bootstrap-entry-ab.bin"),
                &nonce,
            );
            let values = block
                .split(|value| *value == 0)
                .take_while(|value| !value.is_empty())
                .map(|value| String::from_utf16(value).unwrap())
                .collect::<Vec<_>>();

            assert!(values.iter().any(|value| value == "PATH=trusted-path"));
            assert!(values.iter().any(|value| {
                value == "CMUX_BENCH_BOOTSTRAP_ENTRY_CHECKPOINT=C:\\fixture\\bootstrap-entry-ab.bin"
            }));
            assert!(
                values
                    .iter()
                    .any(|value| value == &format!("CMUX_BENCH_BOOTSTRAP_ENTRY_NONCE={nonce}"))
            );
            assert!(values.iter().all(|value| !value.contains("forbidden")));
            assert!(values.iter().all(|value| !value.contains("secret")));
            assert!(bootstrap_environment_has_only_entry_identity(&block));
        }
    }

    fn quote_windows_argument(argument: &str) -> String {
        let mut quoted = String::from("\"");
        let mut backslashes = 0;
        for character in argument.chars() {
            match character {
                '\\' => backslashes += 1,
                '"' => {
                    quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                    quoted.push('"');
                    backslashes = 0;
                }
                _ => {
                    quoted.push_str(&"\\".repeat(backslashes));
                    quoted.push(character);
                    backslashes = 0;
                }
            }
        }
        quoted.push_str(&"\\".repeat(backslashes * 2));
        quoted.push('"');
        quoted
    }

    fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
        value.encode_wide().chain(Some(0)).collect()
    }

    fn check(value: i32, operation: &str) -> Result<()> {
        if value == 0 {
            return Err(std::io::Error::last_os_error()).context(operation.to_string());
        }
        Ok(())
    }

    struct OwnedHandle(HANDLE);

    impl OwnedHandle {
        fn take(&mut self) -> HANDLE {
            std::mem::replace(&mut self.0, null_mut())
        }
    }

    impl Drop for OwnedHandle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: this owner closes each non-null handle once.
                unsafe { CloseHandle(self.0) };
            }
        }
    }

    struct OwnedSid(PSID);

    impl OwnedSid {
        fn from_string(value: &str) -> Result<Self> {
            let value = wide(std::ffi::OsStr::new(value));
            let mut sid = null_mut();
            // SAFETY: sid points to writable PSID storage and value is NUL-terminated.
            check(
                unsafe { ConvertStringSidToSidW(value.as_ptr(), &mut sid) },
                "convert security SID",
            )?;
            Ok(Self(sid))
        }
    }

    impl Drop for OwnedSid {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: ConvertStringSidToSidW allocated this SID with LocalAlloc.
                unsafe { LocalFree(self.0) };
            }
        }
    }
}

fn forwarded_args(launch: &Launch) -> Vec<String> {
    let mut values = vec![
        "--control".into(),
        launch.control.to_string_lossy().into_owned(),
        "--timing".into(),
        launch.timing.to_string_lossy().into_owned(),
        "--nonce".into(),
        launch.nonce.clone(),
        "--fixture-root".into(),
        launch.fixture_root.to_string_lossy().into_owned(),
        "--target".into(),
        launch.target.to_string_lossy().into_owned(),
        "--target-sha256".into(),
        launch.target_sha256.clone(),
        "--supervisor-sha256".into(),
        launch.supervisor_sha256.clone(),
    ];
    if launch.prove_private_job {
        values.push("--prove-private-job".into());
    }
    values.push("--".into());
    values.extend(launch.product_args.clone());
    values
}

#[cfg(target_os = "macos")]
fn canonical_existing_fixture_root(path: &Path) -> Result<PathBuf> {
    let root = path.canonicalize().context("canonicalize macOS benchmark fixture root")?;
    if !fs::symlink_metadata(&root)?.file_type().is_dir() {
        bail!("canonical macOS benchmark fixture root is not a directory");
    }
    Ok(root)
}

#[cfg(all(test, target_os = "macos"))]
mod macos_tests {
    use super::*;

    #[test]
    fn seatbelt_uses_the_kernel_visible_fixture_root() {
        let fixture = tempfile::tempdir_in("/tmp").unwrap();
        let canonical = canonical_existing_fixture_root(fixture.path()).unwrap();

        assert_eq!(canonical, fs::canonicalize(fixture.path()).unwrap());
        assert_ne!(canonical, fixture.path());
    }
}
