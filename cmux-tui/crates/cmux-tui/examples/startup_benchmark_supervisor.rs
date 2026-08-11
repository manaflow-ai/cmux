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
    ACCOUNT_LAUNCHER_SCHEMA_VERSION, AccountLauncherConfig, AuthenticationId,
    BOOTSTRAP_SCHEMA_VERSION, BootstrapChildStage, BootstrapConfig, BootstrapLaunchEvidence,
    BootstrapMessage, BootstrapProductLaunch, NativeEntryCheckpointStage,
    WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER, WINDOWS_JOB_UI_RESTRICTION_MASK,
    WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER, WINDOWS_WRITE_RESTRICTED_CODE_SID,
    decode_native_entry_checkpoint, encode_account_launcher_adopted,
    encode_account_launcher_config, encode_arm, encode_config, read_event,
    validate_account_launcher_ready_message,
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
    BOOTSTRAP_CLEANUP_TIMEOUT, BOOTSTRAP_STARTUP_TIMEOUT, BootstrapCleanupCheckpoint,
    BootstrapCleanupResult, BootstrapFailureCheckpoint, BootstrapObservedEvent, BootstrapStage,
    BootstrapStartupTrace, SECURITY_PREPARATION_TIMEOUT, failure_line, product_started_line,
    setup_line,
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
    windows_account_launcher_binary: PathBuf,
    windows_account_launcher_sha256: String,
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
        windows_account_launcher_binary: PathBuf::new(),
        windows_account_launcher_sha256: String::new(),
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
            "--windows-account-launcher-binary" => {
                launch.windows_account_launcher_binary =
                    required_value(&mut values, &argument)?.into();
            }
            "--windows-account-launcher-sha256" => {
                launch.windows_account_launcher_sha256 = required_value(&mut values, &argument)?;
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
        if !launch.windows_account_launcher_binary.is_file() {
            bail!("dedicated Windows account launcher must be one trusted external file");
        }
        if !launch.windows_bootstrap_binary.is_file() {
            bail!("dedicated Windows bootstrap must be one trusted external file");
        }
        let account_launcher = launch.windows_account_launcher_binary.canonicalize()?;
        let bootstrap = launch.windows_bootstrap_binary.canonicalize()?;
        if account_launcher == bootstrap {
            bail!("Windows account launcher and native bootstrap must be distinct files");
        }
        if account_launcher.starts_with(&fixture_root) {
            bail!("dedicated Windows account launcher must be outside the writable fixture root");
        }
        if bootstrap.starts_with(&fixture_root) {
            bail!("dedicated Windows bootstrap must be outside the writable fixture root");
        }
        if launch.windows_bootstrap_sha256.len() != 64
            || !launch.windows_bootstrap_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            bail!("Windows bootstrap SHA-256 must be 64 hexadecimal characters");
        }
        if launch.windows_account_launcher_sha256.len() != 64
            || !launch.windows_account_launcher_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            bail!("Windows account launcher SHA-256 must be 64 hexadecimal characters");
        }
        if launch.windows_account_launcher_sha256 == launch.windows_bootstrap_sha256 {
            bail!("Windows account launcher and native bootstrap hashes must be distinct");
        }
        let current_exe = env::current_exe()?.canonicalize()?;
        if bootstrap == current_exe {
            bail!("Windows bootstrap must be the dedicated minimal executable");
        }
        if account_launcher == current_exe {
            bail!("Windows account launcher must be the dedicated minimal executable");
        }
        verify_file_sha256(
            &launch.windows_account_launcher_binary,
            &launch.windows_account_launcher_sha256,
            "dedicated Windows account launcher",
        )?;
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
        GENERIC_ALL, GetLastError, HANDLE, INVALID_HANDLE_VALUE, LocalFree, STILL_ACTIVE,
        SetLastError, WAIT_OBJECT_0, WAIT_TIMEOUT,
    };
    use windows_sys::Win32::Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSidToSidW, EXPLICIT_ACCESS_W, GRANT_ACCESS,
        GetNamedSecurityInfoW, NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, SetEntriesInAclW,
        SetNamedSecurityInfoW, TRUSTEE_IS_SID, TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        ACL, AdjustTokenPrivileges, DACL_SECURITY_INFORMATION, GetTokenInformation,
        LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, LUID_AND_ATTRIBUTES, LogonUserW,
        LookupPrivilegeValueW, PRIVILEGE_SET, PSECURITY_DESCRIPTOR, PSID, PrivilegeCheck,
        SE_IMPERSONATE_NAME, SE_PRIVILEGE_ENABLED, SE_SECURITY_NAME, SID_AND_ATTRIBUTES,
        SUB_CONTAINERS_AND_OBJECTS_INHERIT, TOKEN_ADJUST_PRIVILEGES, TOKEN_GROUPS,
        TOKEN_PRIVILEGES, TOKEN_QUERY, TOKEN_STATISTICS, TOKEN_USER, TokenGroups, TokenSessionId,
        TokenStatistics, TokenUser,
    };
    use windows_sys::Win32::Storage::FileSystem::{FILE_TYPE_UNKNOWN, GetFileType};
    use windows_sys::Win32::System::Console::{
        GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
    };
    use windows_sys::Win32::System::IO::{CreateIoCompletionPort, GetQueuedCompletionStatus};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_ASSOCIATE_COMPLETION_PORT,
        JOBOBJECT_BASIC_UI_RESTRICTIONS, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JobObjectAssociateCompletionPortInformation, JobObjectBasicUIRestrictions,
        JobObjectExtendedLimitInformation, QueryInformationJobObject, SetInformationJobObject,
        TerminateJobObject,
    };
    use windows_sys::Win32::System::Pipes::CreatePipe;
    use windows_sys::Win32::System::SystemServices::{
        JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO, JOB_OBJECT_QUERY, PRIVILEGE_SET_ALL_NECESSARY,
        SE_GROUP_LOGON_ID,
    };
    use windows_sys::Win32::System::Threading::{
        CREATE_NO_WINDOW, CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateEventW,
        CreateProcessWithTokenW, GetCurrentProcess, GetExitCodeProcess, GetProcessId,
        GetProcessIdOfThread, GetThreadId, INFINITE, OpenProcessToken, PROCESS_DUP_HANDLE,
        PROCESS_INFORMATION, QueryFullProcessImageNameW, ResumeThread, STARTUPINFOW, SuspendThread,
        TerminateProcess, WaitForSingleObject,
    };
    use windows_sys::Win32::UI::Shell::{LoadUserProfileW, PROFILEINFOW, UnloadUserProfile};

    use super::*;
    use crate::startup_benchmark_protocol::{BootstrapHangArtifactReference, BootstrapTerminal};
    use crate::startup_benchmark_windows_diagnostic::{self, CaptureRequest};

    const MAX_BOOTSTRAP_CHECKPOINT_BYTES: usize = 64 * 1024;
    const LOGON_ID_ATTRIBUTES: u32 = SE_GROUP_LOGON_ID as u32;

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
        if let Err(mut error) = bootstrap.wait_ready(&launch.nonce, &owner, &mut trace) {
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
        let cleanup_deadline = Instant::now()
            .checked_add(BOOTSTRAP_CLEANUP_TIMEOUT)
            .context("Windows containment cleanup deadline overflow")?;
        let cleanup = owner.cleanup(cleanup_deadline);
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

    fn token_user_sid_string(token: HANDLE) -> Result<String> {
        let mut bytes = 0_u32;
        unsafe { GetTokenInformation(token, TokenUser, null_mut(), 0, &mut bytes) };
        if bytes < u32::try_from(size_of::<TOKEN_USER>())? {
            bail!("account token did not report a user SID size");
        }
        let mut buffer = vec![0_u8; usize::try_from(bytes)?];
        check(
            unsafe {
                GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), bytes, &mut bytes)
            },
            "read benchmark account token user SID",
        )?;
        let user = unsafe { &*buffer.as_ptr().cast::<TOKEN_USER>() };
        sid_string(user.User.Sid)
    }

    fn token_session_id(token: HANDLE) -> Result<u32> {
        let mut session_id = 0_u32;
        let mut bytes = 0_u32;
        check(
            unsafe {
                GetTokenInformation(
                    token,
                    TokenSessionId,
                    std::ptr::addr_of_mut!(session_id).cast(),
                    u32::try_from(size_of::<u32>())?,
                    &mut bytes,
                )
            },
            "read benchmark account token session ID",
        )?;
        if bytes != u32::try_from(size_of::<u32>())? {
            bail!("account token session ID had the wrong size");
        }
        Ok(session_id)
    }

    fn token_authentication_id(token: HANDLE) -> Result<AuthenticationId> {
        // SAFETY: zero is a valid initial state for TOKEN_STATISTICS.
        let mut statistics: TOKEN_STATISTICS = unsafe { zeroed() };
        let mut bytes = 0_u32;
        check(
            unsafe {
                GetTokenInformation(
                    token,
                    TokenStatistics,
                    std::ptr::addr_of_mut!(statistics).cast(),
                    u32::try_from(size_of::<TOKEN_STATISTICS>())?,
                    &mut bytes,
                )
            },
            "read benchmark account token authentication ID",
        )?;
        if bytes != u32::try_from(size_of::<TOKEN_STATISTICS>())? {
            bail!("account token statistics had the wrong size");
        }
        Ok(AuthenticationId {
            low_part: statistics.AuthenticationId.LowPart,
            high_part: statistics.AuthenticationId.HighPart,
        })
    }

    fn single_logon_group_index(attributes: &[u32]) -> Result<usize> {
        let matches = attributes
            .iter()
            .enumerate()
            .filter_map(|(index, attributes)| {
                (*attributes & LOGON_ID_ATTRIBUTES == LOGON_ID_ATTRIBUTES).then_some(index)
            })
            .collect::<Vec<_>>();
        match matches.as_slice() {
            [index] => Ok(*index),
            [] => bail!("account token contained no logon-session SID"),
            _ => bail!("account token contained multiple logon-session SIDs"),
        }
    }

    fn token_groups_required_bytes(group_count: usize) -> Result<usize> {
        std::mem::offset_of!(TOKEN_GROUPS, Groups)
            .checked_add(
                group_count
                    .checked_mul(size_of::<SID_AND_ATTRIBUTES>())
                    .context("account token group array size overflow")?,
            )
            .context("account token group buffer size overflow")
    }

    fn validate_token_group_bounds(returned_bytes: usize, group_count: usize) -> Result<()> {
        let required_bytes = token_groups_required_bytes(group_count)?;
        if returned_bytes < required_bytes {
            bail!(
                "account token group array was truncated: returned {returned_bytes} bytes, required {required_bytes}"
            );
        }
        Ok(())
    }

    fn token_logon_sid_string(token: HANDLE) -> Result<String> {
        let mut bytes = 0_u32;
        unsafe { GetTokenInformation(token, TokenGroups, null_mut(), 0, &mut bytes) };
        if bytes < u32::try_from(size_of::<TOKEN_GROUPS>())? {
            bail!("account token did not report a token-groups size");
        }
        let words = usize::try_from(bytes)?
            .checked_add(size_of::<usize>() - 1)
            .context("account token-groups size overflow")?
            / size_of::<usize>();
        let mut buffer = vec![0_usize; words];
        check(
            unsafe {
                GetTokenInformation(
                    token,
                    TokenGroups,
                    buffer.as_mut_ptr().cast(),
                    bytes,
                    &mut bytes,
                )
            },
            "read benchmark account token groups",
        )?;
        let returned_bytes = usize::try_from(bytes)?;
        let buffer_bytes = buffer
            .len()
            .checked_mul(size_of::<usize>())
            .context("account token group buffer capacity overflow")?;
        if returned_bytes < size_of::<TOKEN_GROUPS>() || returned_bytes > buffer_bytes {
            bail!("account token groups returned an invalid byte count");
        }
        let groups = unsafe { &*buffer.as_ptr().cast::<TOKEN_GROUPS>() };
        let group_count = usize::try_from(groups.GroupCount)?;
        validate_token_group_bounds(returned_bytes, group_count)?;
        let first = std::ptr::addr_of!(groups.Groups).cast::<SID_AND_ATTRIBUTES>();
        let attributes = (0..group_count)
            .map(|index| unsafe { (*first.add(index)).Attributes })
            .collect::<Vec<_>>();
        let index = single_logon_group_index(&attributes)?;
        sid_string(unsafe { (*first.add(index)).Sid })
    }

    fn sid_string(sid: PSID) -> Result<String> {
        if sid.is_null() {
            bail!("security SID was null");
        }
        let mut value = null_mut();
        check(unsafe { ConvertSidToStringSidW(sid, &mut value) }, "format security SID")?;
        let value = OwnedLocalWide(value);
        let mut length = 0_usize;
        while length <= 184 && unsafe { *value.0.add(length) } != 0 {
            length += 1;
        }
        if length == 0 || length > 184 {
            bail!("formatted security SID exceeded its bound");
        }
        String::from_utf16(unsafe { std::slice::from_raw_parts(value.0, length) })
            .context("formatted security SID was invalid UTF-16")
    }

    struct OwnedLocalWide(*mut u16);

    impl Drop for OwnedLocalWide {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { LocalFree(self.0.cast()) };
            }
        }
    }

    struct WindowsLaunchOwner {
        account_token: Option<OwnedHandle>,
        job: OwnedHandle,
        query_job: Option<OwnedHandle>,
        completion_port: OwnedHandle,
        // Keep the profile after all Job handles so field-drop fallback closes the containment
        // boundary before it tries to unload a profile after an error.
        profile: Option<LoadedProfile>,
        account_sid_text: String,
        logon_sid_text: String,
        account_token_session_id: u32,
        account_authentication_id: AuthenticationId,
        job_ui_restriction_mask: u32,
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
            ensure_caller_security_privileges(security_deadline, trace)?;
            complete_security_stage(
                security_deadline,
                trace,
                BootstrapStage::PrivilegeEnabled,
                "enable caller impersonation and security privileges",
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
            let account_token_handle = profile
                .as_ref()
                .map(LoadedProfile::token)
                .or_else(|| account_token.as_ref().map(|token| token.0))
                .context("Windows account token owner is missing")?;
            let account_sid_text = token_user_sid_string(account_token_handle)?;
            let logon_sid_text = token_logon_sid_string(account_token_handle)?;
            let account_token_session_id = token_session_id(account_token_handle)?;
            let account_authentication_id = token_authentication_id(account_token_handle)?;
            configure_fixture_acl(
                &launch.fixture_root,
                &user,
                restricting_sid.0,
                security_deadline,
                trace,
            )?;
            let (job, query_job, completion_port, job_ui_restriction_mask) =
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
                account_sid_text,
                logon_sid_text,
                account_token_session_id,
                account_authentication_id,
                job_ui_restriction_mask,
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
            let account_launcher_binary = launch.windows_account_launcher_binary.canonicalize()?;
            let bootstrap_binary = launch.windows_bootstrap_binary.canonicalize()?;
            let fixture_root = launch.fixture_root.canonicalize()?;
            let timing = launch.timing.canonicalize()?;
            let target = launch.target.canonicalize()?;
            let launcher_config_path =
                fixture_root.join(format!("launcher-{}.bin", &launch.nonce[..16]));
            let bootstrap_config_path =
                fixture_root.join(format!("bootstrap-{}.bin", &launch.nonce[..16]));
            let entry_checkpoint_path =
                fixture_root.join(format!("bootstrap-entry-{}.bin", &launch.nonce[..16]));
            verify_file_sha256(
                &account_launcher_binary,
                &launch.windows_account_launcher_sha256,
                "dedicated Windows account launcher before launch",
            )?;
            verify_file_sha256(
                &bootstrap_binary,
                &launch.windows_bootstrap_sha256,
                "dedicated Windows bootstrap before launch",
            )?;
            let trusted_probe = TrustedPathProbe::create(launch)?;
            let trusted_path_probe = trusted_probe.path.canonicalize()?;
            let application = wide(account_launcher_binary.as_os_str());
            let current_directory = wide(fixture_root.as_os_str());
            let mut command_line = wide(std::ffi::OsStr::new(&windows_command_line(
                &account_launcher_binary,
                &[launcher_config_path.to_string_lossy().into_owned(), launch.nonce.clone()],
            )));
            // SAFETY: zero is a valid initial state for these Win32 structs.
            let mut startup: STARTUPINFOW = unsafe { zeroed() };
            startup.cb = u32::try_from(size_of::<STARTUPINFOW>())?;
            // The USER32-free account launcher can safely inherit the runner desktop. It uses
            // CreateProcessAsUserW with an empty desktop string for the native bootstrap.
            startup.lpDesktop = null_mut();
            // SAFETY: zero is a valid initial state for PROCESS_INFORMATION.
            let mut process: PROCESS_INFORMATION = unsafe { zeroed() };
            let mut environment = vec![0_u16, 0_u16];
            let target_cmux_bench_environment_filtered = environment == [0_u16, 0_u16];
            if !target_cmux_bench_environment_filtered {
                bail!("account launcher environment retained a CMUX_BENCH secret");
            }
            let launcher_creation_flags =
                CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
            // SAFETY: all strings are NUL-terminated and output storage remains live.
            check(
                unsafe {
                    CreateProcessWithTokenW(
                        self.account_token()?,
                        0,
                        application.as_ptr(),
                        command_line.as_mut_ptr(),
                        launcher_creation_flags,
                        environment.as_mut_ptr().cast::<c_void>(),
                        current_directory.as_ptr(),
                        &startup,
                        &mut process,
                    )
                },
                "create suspended account-owned native launcher",
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
                return Err(error).context("assign account launcher to non-breakaway job");
            }
            self.broker_assigned = true;
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::JobAssigned));
            let pipes = BootstrapPipes::create()?;
            // SAFETY: null security attributes and name create an unnamed manual-reset event.
            let launcher_gate = unsafe { CreateEventW(null(), 1, 0, null()) };
            if launcher_gate.is_null() {
                return Err(std::io::Error::last_os_error())
                    .context("create account launcher native-bootstrap gate");
            }
            let launcher_gate = OwnedHandle(launcher_gate);
            let control_read = duplicate_into_process(
                pipes.bootstrap_read.0,
                process_handle.0,
                true,
                "account launcher control read",
            )?;
            let control_write = duplicate_into_process(
                pipes.bootstrap_write.0,
                process_handle.0,
                true,
                "account launcher control write",
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
                    duplicate_into_process(
                        handle.0,
                        process_handle.0,
                        true,
                        "account launcher private Job query",
                    )
                })
                .transpose()?;
            let launcher_gate_value = duplicate_into_process(
                launcher_gate.0,
                process_handle.0,
                true,
                "account launcher native-bootstrap gate",
            )?;
            let supervisor_process = duplicate_into_process_with_access(
                unsafe { GetCurrentProcess() },
                process_handle.0,
                PROCESS_DUP_HANDLE,
                false,
                "account launcher supervisor duplicate-handle target",
            )?;
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::HandlesDuplicated));
            let query_job = query_job.context("private Job query handle is required")?;
            let (bootstrap_config_bytes, bootstrap_config_sha256) = write_bootstrap_config(
                &bootstrap_config_path,
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
                        logon_sid: self.logon_sid_text.clone(),
                        account_token_session_id: self.account_token_session_id,
                        job_ui_restriction_mask: self.job_ui_restriction_mask,
                    },
                    control_read,
                    control_write,
                    standard_handles,
                    query_job,
                    launcher_gate: launcher_gate_value,
                },
            )?;
            let launcher_config = AccountLauncherConfig {
                schema_version: ACCOUNT_LAUNCHER_SCHEMA_VERSION,
                nonce: launch.nonce.clone(),
                launcher_stage_marker: WINDOWS_ACCOUNT_LAUNCHER_STAGE_MARKER,
                bootstrap_stage_marker: WINDOWS_NATIVE_BOOTSTRAP_STAGE_MARKER,
                launcher: account_launcher_binary.clone(),
                launcher_sha256: launch.windows_account_launcher_sha256.clone(),
                bootstrap: bootstrap_binary.clone(),
                bootstrap_sha256: launch.windows_bootstrap_sha256.clone(),
                bootstrap_config: bootstrap_config_path.clone(),
                bootstrap_config_sha256,
                bootstrap_entry_checkpoint: entry_checkpoint_path.clone(),
                account_token_session_id: self.account_token_session_id,
                job_ui_restriction_mask: self.job_ui_restriction_mask,
                control_read,
                control_write,
                standard_handles,
                query_job,
                launcher_gate: launcher_gate_value,
                supervisor_process,
                supervisor_process_id: std::process::id(),
            };
            launcher_config.validate_identity(&launcher_config_path)?;
            let launcher_config_bytes = encode_account_launcher_config(&launcher_config)?;
            let launcher_config_sha256 = format!("{:x}", Sha256::digest(&launcher_config_bytes));
            let mut launcher_config_file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&launcher_config_path)
                .with_context(|| {
                    format!(
                        "create Windows account launcher config {}",
                        launcher_config_path.display()
                    )
                })?;
            launcher_config_file.write_all(&launcher_config_bytes)?;
            launcher_config_file.flush()?;
            drop(launcher_config_file);
            trace.record_config(
                u64::try_from(launcher_config_bytes.len())?
                    .checked_add(bootstrap_config_bytes)
                    .context("combined native config byte count overflow")?,
                launcher_config_sha256,
            );
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ConfigWritten));
            // SAFETY: thread_handle is the suspended primary thread.
            let resume_previous_count = unsafe { ResumeThread(thread_handle.0) };
            if resume_previous_count != 1 {
                if resume_previous_count == u32::MAX {
                    return Err(std::io::Error::last_os_error())
                        .context("resume account-owned native launcher");
                }
                bail!(
                    "account launcher primary thread had suspend count {resume_previous_count}, expected 1"
                );
            }
            let resumed_at = Instant::now();
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ProcessResumed));
            let session = BootstrapSession::new(
                process_handle,
                thread_handle,
                pipes,
                BootstrapIdentity {
                    launcher_config_path,
                    bootstrap_config_path,
                    entry_checkpoint_path,
                    trusted_probe,
                    account_launcher_binary,
                    account_launcher_sha256: launch.windows_account_launcher_sha256.clone(),
                    bootstrap_binary,
                    bootstrap_sha256: launch.windows_bootstrap_sha256.clone(),
                    fixture_root,
                    nonce: launch.nonce.clone(),
                    resumed_at,
                    resume_previous_count,
                    process_id: process.dwProcessId,
                    target_cmux_bench_environment_filtered,
                    account_sid: self.account_sid_text.clone(),
                    restricting_sid: self.restricting_sid_text.clone(),
                    logon_sid: self.logon_sid_text.clone(),
                    account_token_session_id: self.account_token_session_id,
                    account_authentication_id: self.account_authentication_id,
                    job_ui_restrictions_exact_before_resume: self.job_ui_restriction_mask
                        == WINDOWS_JOB_UI_RESTRICTION_MASK,
                    launcher_create_no_window: launcher_creation_flags & CREATE_NO_WINDOW != 0,
                },
            )?;
            Ok(session)
        }

        fn cleanup(&mut self, deadline: Instant) -> Result<()> {
            if self.broker_assigned {
                self.terminate_descendants_and_wait_empty(deadline)?;
                self.broker_assigned = false;
            }
            if Instant::now() >= deadline {
                Err(anyhow::anyhow!(
                    "Windows containment cleanup deadline expired before profile cleanup"
                ))
            } else {
                match self.profile.as_mut() {
                    Some(profile) => profile.cleanup(),
                    None => Ok(()),
                }
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
        _primary_thread: OwnedHandle,
        writer: Option<File>,
        receiver: mpsc::Receiver<BootstrapEvent>,
        sender: mpsc::Sender<BootstrapEvent>,
        reader: Option<thread::JoinHandle<()>>,
        launcher_status: Option<thread::JoinHandle<()>>,
        bootstrap_status: Option<thread::JoinHandle<()>>,
        bootstrap_process: Option<OwnedHandle>,
        bootstrap_primary_thread: Option<OwnedHandle>,
        launcher_config_path: PathBuf,
        bootstrap_config_path: PathBuf,
        entry_checkpoint_path: PathBuf,
        trusted_probe: TrustedPathProbe,
        account_launcher_binary: PathBuf,
        account_launcher_sha256: String,
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
        target_cmux_bench_environment_filtered: bool,
        account_sid: String,
        restricting_sid: String,
        logon_sid: String,
        account_token_session_id: u32,
        account_authentication_id: AuthenticationId,
        job_ui_restrictions_exact_before_resume: bool,
        launcher_create_no_window: bool,
        launcher_ready: bool,
        launcher_bootstrap_process_id: Option<u32>,
        launcher_ready_evidence: Option<AccountLauncherReadyEvidence>,
        product_started_relayed: bool,
    }

    struct AccountLauncherReadyEvidence {
        launcher_token_session_id: u32,
        bootstrap_token_session_id: u32,
        bootstrap_process_id: u32,
        bootstrap_primary_thread_id: u32,
        bootstrap_resume_previous_count: Option<u32>,
        bootstrap_handles_adopted: bool,
        adoption_acknowledged: bool,
        config_consumed: bool,
        handles_exact: bool,
        handle_inheritance_exact: bool,
        supervisor_target_exact: bool,
        private_job_member: bool,
        se_increase_quota_present: bool,
        se_increase_quota_enabled: bool,
        bootstrap_created_suspended: bool,
        empty_desktop_selection: bool,
        create_no_window: bool,
        handle_list_exact: bool,
    }

    struct BootstrapIdentity {
        launcher_config_path: PathBuf,
        bootstrap_config_path: PathBuf,
        entry_checkpoint_path: PathBuf,
        trusted_probe: TrustedPathProbe,
        account_launcher_binary: PathBuf,
        account_launcher_sha256: String,
        bootstrap_binary: PathBuf,
        bootstrap_sha256: String,
        fixture_root: PathBuf,
        nonce: String,
        resumed_at: Instant,
        resume_previous_count: u32,
        process_id: u32,
        target_cmux_bench_environment_filtered: bool,
        account_sid: String,
        restricting_sid: String,
        logon_sid: String,
        account_token_session_id: u32,
        account_authentication_id: AuthenticationId,
        job_ui_restrictions_exact_before_resume: bool,
        launcher_create_no_window: bool,
    }

    enum BootstrapEvent {
        Message(BootstrapMessage),
        PipeEof,
        ProtocolError(String),
        LauncherExited(std::result::Result<u32, String>),
        BootstrapExited(std::result::Result<u32, String>),
    }

    impl BootstrapSession {
        fn new(
            process: OwnedHandle,
            primary_thread: OwnedHandle,
            mut pipes: BootstrapPipes,
            identity: BootstrapIdentity,
        ) -> Result<Self> {
            let BootstrapIdentity {
                launcher_config_path,
                bootstrap_config_path,
                entry_checkpoint_path,
                trusted_probe,
                account_launcher_binary,
                account_launcher_sha256,
                bootstrap_binary,
                bootstrap_sha256,
                fixture_root,
                nonce,
                resumed_at,
                resume_previous_count,
                process_id,
                target_cmux_bench_environment_filtered,
                account_sid,
                restricting_sid,
                logon_sid,
                account_token_session_id,
                account_authentication_id,
                job_ui_restrictions_exact_before_resume,
                launcher_create_no_window,
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
            let status_sender = sender.clone();
            let launcher_status = thread::spawn(move || {
                let handle = OwnedHandle(wait_handle as HANDLE);
                let result = wait_process_exit_code(&handle).map_err(|error| format!("{error:#}"));
                let _ = status_sender.send(BootstrapEvent::LauncherExited(result));
            });
            Ok(Self {
                process,
                _primary_thread: primary_thread,
                writer: Some(writer),
                receiver,
                sender,
                reader: Some(reader),
                launcher_status: Some(launcher_status),
                bootstrap_status: None,
                bootstrap_process: None,
                bootstrap_primary_thread: None,
                launcher_config_path,
                bootstrap_config_path,
                entry_checkpoint_path,
                trusted_probe,
                account_launcher_binary,
                account_launcher_sha256,
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
                target_cmux_bench_environment_filtered,
                account_sid,
                restricting_sid,
                logon_sid,
                account_token_session_id,
                account_authentication_id,
                job_ui_restrictions_exact_before_resume,
                launcher_create_no_window,
                launcher_ready: false,
                launcher_bootstrap_process_id: None,
                launcher_ready_evidence: None,
                product_started_relayed: false,
            })
        }

        fn capture_hang_snapshot(
            &mut self,
            owner: &WindowsLaunchOwner,
            launch: &Launch,
        ) -> Result<()> {
            let process = self
                .bootstrap_process
                .as_ref()
                .context("native bootstrap process handle was not adopted")?;
            let primary_thread = self
                .bootstrap_primary_thread
                .as_ref()
                .context("native bootstrap primary-thread handle was not adopted")?;
            let launcher = self
                .launcher_ready_evidence
                .as_ref()
                .context("account launcher READY evidence is missing")?;
            match startup_benchmark_windows_diagnostic::capture(CaptureRequest {
                process: process.0,
                primary_thread: primary_thread.0,
                process_id: launcher.bootstrap_process_id,
                primary_thread_id: launcher.bootstrap_primary_thread_id,
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

        fn adopt_bootstrap_handles(
            &mut self,
            owner: &WindowsLaunchOwner,
            process_id: u32,
            primary_thread_id: u32,
            process_handle: u64,
            primary_thread_handle: u64,
        ) -> Result<()> {
            let process = owned_adopted_handle(process_handle, "native bootstrap process")?;
            if process_handle == primary_thread_handle {
                bail!("native bootstrap adoption reused one handle value");
            }
            let primary_thread =
                owned_adopted_handle(primary_thread_handle, "native bootstrap primary thread")?;
            if self.bootstrap_process.is_some() || self.bootstrap_primary_thread.is_some() {
                bail!("account launcher sent an extra native bootstrap adoption record");
            }
            if unsafe { GetProcessId(process.0) } != process_id
                || unsafe { GetThreadId(primary_thread.0) } != primary_thread_id
                || unsafe { GetProcessIdOfThread(primary_thread.0) } != process_id
            {
                bail!("native bootstrap adopted handle type or identity changed");
            }
            let observed_path = query_process_image_path(process.0)?;
            let expected_path = self.bootstrap_binary.canonicalize()?;
            if !observed_path
                .to_string_lossy()
                .eq_ignore_ascii_case(&expected_path.to_string_lossy())
            {
                bail!(
                    "native bootstrap adopted image changed: expected {}, observed {}",
                    expected_path.display(),
                    observed_path.display()
                );
            }
            verify_file_sha256(
                &observed_path,
                &self.bootstrap_sha256,
                "adopted native bootstrap before resume",
            )?;
            let mut in_job = 0;
            check(
                unsafe { IsProcessInJob(process.0, owner.job.0, &mut in_job) },
                "verify adopted native bootstrap Job membership",
            )?;
            if in_job == 0 {
                bail!("adopted native bootstrap was outside the private Job");
            }
            let mut token = null_mut();
            check(
                unsafe { OpenProcessToken(process.0, TOKEN_QUERY, &mut token) },
                "open adopted native bootstrap token",
            )?;
            let token = OwnedHandle(token);
            if token_user_sid_string(token.0)? != self.account_sid
                || token_logon_sid_string(token.0)? != self.logon_sid
                || token_session_id(token.0)? != self.account_token_session_id
                || token_authentication_id(token.0)? != self.account_authentication_id
            {
                bail!("adopted native bootstrap account token identity changed");
            }
            let mut exit_code = 0_u32;
            check(
                unsafe { GetExitCodeProcess(process.0, &mut exit_code) },
                "query adopted native bootstrap state",
            )?;
            if exit_code != STILL_ACTIVE {
                bail!("adopted native bootstrap exited before adoption");
            }
            let previous_count = unsafe { SuspendThread(primary_thread.0) };
            if previous_count == u32::MAX {
                return Err(std::io::Error::last_os_error())
                    .context("probe adopted native bootstrap suspended state");
            }
            let restored_count = unsafe { ResumeThread(primary_thread.0) };
            if restored_count == u32::MAX {
                return Err(std::io::Error::last_os_error())
                    .context("restore adopted native bootstrap suspended state");
            }
            if previous_count != 1 || restored_count != 2 {
                bail!(
                    "adopted native bootstrap suspend count changed: before {previous_count}, restore {restored_count}"
                );
            }
            let wait_handle = duplicate_current_process_handle(
                process.0,
                "adopted native bootstrap status wait",
            )?;
            let sender = self.sender.clone();
            let status = thread::spawn(move || {
                let handle = OwnedHandle(wait_handle as HANDLE);
                let result = wait_process_exit_code(&handle).map_err(|error| format!("{error:#}"));
                let _ = sender.send(BootstrapEvent::BootstrapExited(result));
            });
            self.bootstrap_process = Some(process);
            self.bootstrap_primary_thread = Some(primary_thread);
            self.bootstrap_status = Some(status);
            Ok(())
        }

        fn wait_ready(
            &mut self,
            nonce: &str,
            owner: &WindowsLaunchOwner,
            trace: &mut BootstrapStartupTrace,
        ) -> Result<()> {
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
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherReady {
                        nonce: observed,
                        launcher_sha256,
                        bootstrap_sha256,
                        config_consumed,
                        self_hash_match,
                        bootstrap_hash_match,
                        handles_exact,
                        handle_inheritance_exact,
                        private_job_member,
                        job_ui_restrictions_match,
                        se_increase_quota_present,
                        se_increase_quota_enabled,
                        session_match,
                        bootstrap_created_suspended,
                        bootstrap_private_job_member,
                        bootstrap_session_match,
                        empty_desktop_selection,
                        create_no_window,
                        handle_list_exact,
                        supervisor_target_exact,
                        bootstrap_handles_duplicated,
                        account_token_session_id,
                        launcher_token_session_id,
                        bootstrap_token_session_id,
                        job_ui_restriction_mask,
                        bootstrap_process_id,
                        bootstrap_primary_thread_id,
                        supervisor_process_id,
                        launcher_process_id,
                        bootstrap_process_handle,
                        bootstrap_primary_thread_handle,
                    }) => {
                        let readiness = BootstrapMessage::AccountLauncherReady {
                            nonce: observed.clone(),
                            launcher_sha256: launcher_sha256.clone(),
                            bootstrap_sha256: bootstrap_sha256.clone(),
                            config_consumed,
                            self_hash_match,
                            bootstrap_hash_match,
                            handles_exact,
                            handle_inheritance_exact,
                            private_job_member,
                            job_ui_restrictions_match,
                            se_increase_quota_present,
                            se_increase_quota_enabled,
                            session_match,
                            bootstrap_created_suspended,
                            bootstrap_private_job_member,
                            bootstrap_session_match,
                            empty_desktop_selection,
                            create_no_window,
                            handle_list_exact,
                            supervisor_target_exact,
                            bootstrap_handles_duplicated,
                            account_token_session_id,
                            launcher_token_session_id,
                            bootstrap_token_session_id,
                            job_ui_restriction_mask,
                            bootstrap_process_id,
                            bootstrap_primary_thread_id,
                            supervisor_process_id,
                            launcher_process_id,
                            bootstrap_process_handle,
                            bootstrap_primary_thread_handle,
                        };
                        let metadata_valid = !self.launcher_ready
                            && validate_account_launcher_ready_message(
                                &readiness,
                                nonce,
                                &self.account_launcher_sha256,
                                &self.bootstrap_sha256,
                                self.account_token_session_id,
                                std::process::id(),
                                self.process_id,
                            )
                            .is_ok();
                        if !metadata_valid {
                            close_unadopted_handles(
                                bootstrap_process_handle,
                                bootstrap_primary_thread_handle,
                            )?;
                            bail!("account launcher READY or adoption evidence mismatch");
                        }
                        if self.launcher_config_path.exists() {
                            close_unadopted_handles(
                                bootstrap_process_handle,
                                bootstrap_primary_thread_handle,
                            )?;
                            trace.observe(BootstrapObservedEvent::Error);
                            bail!("account launcher did not consume its launch config");
                        }
                        self.adopt_bootstrap_handles(
                            owner,
                            bootstrap_process_id,
                            bootstrap_primary_thread_id,
                            bootstrap_process_handle,
                            bootstrap_primary_thread_handle,
                        )?;
                        let writer = self
                            .writer
                            .as_mut()
                            .context("Windows account launcher command pipe is closed")?;
                        writer.write_all(&encode_account_launcher_adopted(nonce)?)?;
                        writer.flush()?;
                        self.launcher_ready = true;
                        self.launcher_bootstrap_process_id = Some(bootstrap_process_id);
                        self.launcher_ready_evidence = Some(AccountLauncherReadyEvidence {
                            launcher_token_session_id,
                            bootstrap_token_session_id,
                            bootstrap_process_id,
                            bootstrap_primary_thread_id,
                            bootstrap_resume_previous_count: None,
                            bootstrap_handles_adopted: true,
                            adoption_acknowledged: false,
                            config_consumed,
                            handles_exact,
                            handle_inheritance_exact,
                            supervisor_target_exact,
                            private_job_member,
                            se_increase_quota_present,
                            se_increase_quota_enabled,
                            bootstrap_created_suspended,
                            empty_desktop_selection,
                            create_no_window,
                            handle_list_exact,
                        });
                        trace.observe(BootstrapObservedEvent::Stage(
                            BootstrapStage::AccountLauncherReady,
                        ));
                        trace.observe(BootstrapObservedEvent::Stage(
                            BootstrapStage::BootstrapHandlesAdopted,
                        ));
                    }
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherResumed {
                        nonce: observed,
                        bootstrap_resume_previous_count,
                        bootstrap_process_id,
                        adoption_acknowledged,
                    }) if observed == nonce
                        && self.launcher_ready
                        && adoption_acknowledged
                        && bootstrap_resume_previous_count == 1
                        && self.launcher_bootstrap_process_id == Some(bootstrap_process_id)
                        && self.launcher_ready_evidence.as_ref().is_some_and(|launcher| {
                            launcher.bootstrap_resume_previous_count.is_none()
                        }) =>
                    {
                        self.launcher_ready_evidence
                            .as_mut()
                            .context("account launcher READY evidence is missing")?
                            .bootstrap_resume_previous_count =
                            Some(bootstrap_resume_previous_count);
                        self.launcher_ready_evidence
                            .as_mut()
                            .context("account launcher READY evidence is missing")?
                            .adoption_acknowledged = true;
                        trace.observe(BootstrapObservedEvent::Stage(
                            BootstrapStage::AccountLauncherResumed,
                        ));
                    }
                    BootstrapEvent::Message(BootstrapMessage::Stage { nonce: observed, stage })
                        if observed == nonce
                            && self.launcher_ready
                            && self
                                .launcher_ready_evidence
                                .as_ref()
                                .and_then(|launcher| launcher.bootstrap_resume_previous_count)
                                == Some(1) =>
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
                        system_restricting_sid_match,
                        os_assigned_window_station,
                        os_assigned_desktop,
                        window_station_noninteractive,
                        desktop_noninteractive_default,
                        window_station_low_integrity,
                        desktop_low_integrity,
                        restricted_desktop_access,
                        restricted_logon_sid_match,
                        window_station_logon_sid_dacl,
                        desktop_logon_sid_dacl,
                        token_session_match,
                        job_ui_restrictions_match,
                        broker_authentication_id,
                        restricted_authentication_id,
                        account_token_session_id,
                        bootstrap_token_session_id,
                        restricted_token_session_id,
                        job_ui_restriction_mask,
                        restricting_sid,
                        logon_sid,
                        observed_window_station,
                        observed_desktop,
                    }) if observed == nonce
                        && self.launcher_ready
                        && self
                            .launcher_ready_evidence
                            .as_ref()
                            .and_then(|launcher| launcher.bootstrap_resume_previous_count)
                            == Some(1)
                        && self.launcher_ready_evidence.as_ref().is_some_and(|launcher| {
                            launcher.bootstrap_handles_adopted && launcher.adoption_acknowledged
                        })
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
                        && system_restricting_sid_match
                        && os_assigned_window_station
                        && os_assigned_desktop
                        && window_station_noninteractive
                        && desktop_noninteractive_default
                        && window_station_low_integrity
                        && desktop_low_integrity
                        && restricted_desktop_access
                        && restricted_logon_sid_match
                        && window_station_logon_sid_dacl
                        && desktop_logon_sid_dacl
                        && token_session_match
                        && job_ui_restrictions_match
                        && account_token_session_id == self.account_token_session_id
                        && bootstrap_token_session_id == self.account_token_session_id
                        && bootstrap_token_session_id
                            == self
                                .launcher_ready_evidence
                                .as_ref()
                                .map(|launcher| launcher.bootstrap_token_session_id)
                                .unwrap_or(u32::MAX)
                        && restricted_token_session_id == self.account_token_session_id
                        && job_ui_restriction_mask == WINDOWS_JOB_UI_RESTRICTION_MASK
                        && restricting_sid == self.restricting_sid
                        && logon_sid == self.logon_sid =>
                    {
                        cmux_startup_bootstrap::validate_os_assigned_desktop_identity(
                            &observed_window_station,
                            &observed_desktop,
                        )?;
                        if self.record_native_entry_checkpoint(trace)?
                            != Some(NativeEntryCheckpointStage::ConfigConsumed)
                        {
                            trace.observe(BootstrapObservedEvent::Error);
                            bail!(
                                "restricted bootstrap did not publish its consumed config checkpoint"
                            );
                        }
                        if self.bootstrap_config_path.exists() {
                            trace.observe(BootstrapObservedEvent::Error);
                            bail!("restricted bootstrap did not consume its launch config");
                        }
                        let launcher = self
                            .launcher_ready_evidence
                            .as_ref()
                            .context("account launcher READY evidence is missing")?;
                        self.evidence = Some(BootstrapLaunchEvidence {
                            schema_version: BOOTSTRAP_SCHEMA_VERSION,
                            account_launcher_sha256: self.account_launcher_sha256.clone(),
                            bootstrap_sha256,
                            config_nonce: observed,
                            config_consumed,
                            account_launcher_config_consumed: launcher.config_consumed,
                            account_launcher_ready_before_bootstrap: self.launcher_ready,
                            account_launcher_resume_previous_count: self.resume_previous_count,
                            bootstrap_resume_previous_count: launcher
                                .bootstrap_resume_previous_count
                                .context("native bootstrap resume evidence is missing")?,
                            account_launcher_create_no_window: self.launcher_create_no_window,
                            account_launcher_private_job_member: launcher.private_job_member,
                            account_launcher_handles_exact: launcher.handles_exact,
                            account_launcher_handle_inheritance_exact: launcher
                                .handle_inheritance_exact,
                            account_launcher_supervisor_target_exact: launcher
                                .supervisor_target_exact,
                            account_launcher_se_increase_quota_present: launcher
                                .se_increase_quota_present,
                            account_launcher_se_increase_quota_enabled: launcher
                                .se_increase_quota_enabled,
                            account_launcher_token_session_id: launcher.launcher_token_session_id,
                            bootstrap_created_suspended: launcher.bootstrap_created_suspended,
                            bootstrap_created_with_create_process_as_user: true,
                            bootstrap_empty_desktop_selection: launcher.empty_desktop_selection,
                            bootstrap_explicit_handle_list: launcher.handle_list_exact,
                            bootstrap_process_id: launcher.bootstrap_process_id,
                            bootstrap_primary_thread_id: launcher.bootstrap_primary_thread_id,
                            bootstrap_remote_handles_adopted: launcher.bootstrap_handles_adopted,
                            bootstrap_adoption_acknowledged_before_resume: launcher
                                .adoption_acknowledged,
                            bootstrap_handle_types_exact: true,
                            bootstrap_image_identity_verified: true,
                            bootstrap_exact_job_before_resume: true,
                            bootstrap_account_token_identity_verified: true,
                            bootstrap_suspended_state_verified: true,
                            ready_elapsed_ms: u64::try_from(self.resumed_at.elapsed().as_millis())
                                .unwrap_or(u64::MAX),
                            exact_job_proof: private_job_member,
                            trusted_path_write_denied,
                            bootstrap_write_denied,
                            account_sid: self.account_sid.clone(),
                            restricting_sid,
                            system_restricting_sid: WINDOWS_WRITE_RESTRICTED_CODE_SID.into(),
                            logon_sid,
                            observed_window_station,
                            observed_desktop,
                            os_assigned_desktop_ready_before_resume: true,
                            window_station_noninteractive,
                            desktop_noninteractive_default,
                            bootstrap_create_no_window: launcher.create_no_window,
                            broker_authentication_id: broker_authentication_id.evidence_value(),
                            restricted_authentication_id: restricted_authentication_id
                                .evidence_value(),
                            product_authentication_id: String::new(),
                            account_token_session_id,
                            bootstrap_token_session_id,
                            restricted_token_session_id,
                            product_token_session_id: 0,
                            token_session_ids_match: token_session_match,
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
                            restricted_token_system_restricting_sid_match:
                                system_restricting_sid_match,
                            restricted_token_logon_sid_match: restricted_logon_sid_match,
                            restricted_token_low_integrity: restricted_low_integrity,
                            restricted_token_no_enabled_privileges:
                                restricted_no_enabled_privileges,
                            window_station_logon_sid_dacl_proven: window_station_logon_sid_dacl,
                            desktop_logon_sid_dacl_proven: desktop_logon_sid_dacl,
                            window_station_low_integrity,
                            desktop_low_integrity,
                            restricted_desktop_access_proven: restricted_desktop_access,
                            job_ui_restriction_mask,
                            job_ui_restrictions_exact_before_resume: self
                                .job_ui_restrictions_exact_before_resume,
                            product_write_restricted: false,
                            product_restricting_sid_match: false,
                            product_system_restricting_sid_match: false,
                            product_logon_sid_match: false,
                            product_low_integrity: false,
                            product_no_enabled_privileges: false,
                            product_exact_job: false,
                            product_desktop_assignment_match: false,
                            product_window_station_low_integrity: false,
                            product_desktop_low_integrity: false,
                            product_create_no_window: false,
                            product_resume_previous_count: 0,
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
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherError {
                        nonce: observed,
                        windows_error,
                        stage,
                    }) if observed == nonce => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!(
                            "account launcher failed before bootstrap READY at launcher stage {stage} with Windows error {windows_error}"
                        )
                    }
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherExit {
                        nonce: observed,
                        bootstrap_exit_code,
                        bootstrap_resume_previous_count,
                        bootstrap_process_id,
                    }) if observed == nonce => {
                        trace.observe(BootstrapObservedEvent::Exit(bootstrap_exit_code));
                        bail!(
                            "native bootstrap exited before READY through account launcher: code {bootstrap_exit_code} ({bootstrap_exit_code:#010x}), resume count {bootstrap_resume_previous_count}, process {bootstrap_process_id}"
                        )
                    }
                    BootstrapEvent::BootstrapExited(Ok(code)) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Exit(code));
                        bail!("restricted bootstrap exited before READY with code {code}")
                    }
                    BootstrapEvent::BootstrapExited(Err(error)) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!("read restricted bootstrap exit state: {error}")
                    }
                    BootstrapEvent::LauncherExited(Ok(code)) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Exit(code));
                        bail!("account launcher exited before bootstrap READY with code {code}")
                    }
                    BootstrapEvent::LauncherExited(Err(error)) => {
                        self.record_native_entry_checkpoint(trace)?;
                        trace.observe(BootstrapObservedEvent::Error);
                        bail!("read account launcher exit state: {error}")
                    }
                    BootstrapEvent::PipeEof => {
                        self.record_native_entry_checkpoint(trace)?;
                        // The pipe reader and process-status thread race after an early loader
                        // exit. Drain the already-owned process handle with the same absolute
                        // READY deadline so the failure evidence keeps the exact exit code.
                        match self.receive_until(
                            deadline,
                            "read restricted bootstrap exit after READY pipe EOF",
                        ) {
                            Ok(BootstrapEvent::BootstrapExited(Ok(code)))
                            | Ok(BootstrapEvent::LauncherExited(Ok(code))) => {
                                trace.observe(BootstrapObservedEvent::Exit(code));
                                bail!(
                                    "restricted bootstrap event pipe closed before READY; process exited with code {code} ({code:#010x})"
                                )
                            }
                            Ok(BootstrapEvent::BootstrapExited(Err(error)))
                            | Ok(BootstrapEvent::LauncherExited(Err(error))) => {
                                trace.observe(BootstrapObservedEvent::Error);
                                bail!(
                                    "restricted bootstrap event pipe closed before READY; read process exit state: {error}"
                                )
                            }
                            Ok(_) => {
                                trace.observe(BootstrapObservedEvent::Eof);
                                bail!(
                                    "restricted bootstrap event pipe closed before READY without process exit evidence"
                                )
                            }
                            Err(error) => {
                                trace.observe(BootstrapObservedEvent::Eof);
                                return Err(error).context(
                                    "restricted bootstrap event pipe closed before READY",
                                );
                            }
                        }
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
            let mut bootstrap_exit = None;
            let (code, contained) = loop {
                match self.receive_until(deadline, "wait for restricted product status")? {
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherReady {
                        bootstrap_process_handle,
                        bootstrap_primary_thread_handle,
                        ..
                    }) => {
                        close_unadopted_handles(
                            bootstrap_process_handle,
                            bootstrap_primary_thread_handle,
                        )?;
                        bail!("account launcher sent a late native bootstrap adoption record");
                    }
                    BootstrapEvent::Message(BootstrapMessage::ProductStarted {
                        nonce: observed,
                        private_job_descendant_contained,
                        create_process_as_user_succeeded,
                        product_authentication_match,
                        product_low_integrity,
                        product_write_restricted,
                        product_no_enabled_privileges,
                        product_restricting_sid_match,
                        product_system_restricting_sid_match,
                        product_desktop_assignment_match,
                        product_create_no_window,
                        product_logon_sid_match,
                        product_session_id_match,
                        product_window_station_low_integrity,
                        product_desktop_low_integrity,
                        product_authentication_id,
                        product_token_session_id,
                        resume_previous_count,
                    }) if observed == nonce => {
                        if product_started
                            || !private_job_descendant_contained
                            || !create_process_as_user_succeeded
                            || !product_authentication_match
                            || !product_low_integrity
                            || !product_write_restricted
                            || !product_no_enabled_privileges
                            || !product_restricting_sid_match
                            || !product_system_restricting_sid_match
                            || !product_desktop_assignment_match
                            || !product_create_no_window
                            || !product_logon_sid_match
                            || !product_session_id_match
                            || !product_window_station_low_integrity
                            || !product_desktop_low_integrity
                            || product_token_session_id != self.account_token_session_id
                            || resume_previous_count != 1
                        {
                            bail!("restricted bootstrap product-started evidence mismatch");
                        }
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
                        evidence.product_system_restricting_sid_match =
                            product_system_restricting_sid_match;
                        evidence.product_logon_sid_match = product_logon_sid_match;
                        evidence.product_low_integrity = product_low_integrity;
                        evidence.product_no_enabled_privileges = product_no_enabled_privileges;
                        evidence.product_exact_job = private_job_descendant_contained;
                        evidence.product_desktop_assignment_match =
                            product_desktop_assignment_match;
                        evidence.product_window_station_low_integrity =
                            product_window_station_low_integrity;
                        evidence.product_desktop_low_integrity = product_desktop_low_integrity;
                        evidence.product_token_session_id = product_token_session_id;
                        evidence.token_session_ids_match = product_session_id_match;
                        evidence.product_create_no_window = product_create_no_window;
                        evidence.product_resume_previous_count = resume_previous_count;
                        evidence.validate(&self.nonce, &self.bootstrap_sha256)?;
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
                        product_system_restricting_sid_match,
                        product_desktop_assignment_match,
                        product_create_no_window,
                        product_logon_sid_match,
                        product_session_id_match,
                        product_window_station_low_integrity,
                        product_desktop_low_integrity,
                        product_authentication_id,
                        product_token_session_id,
                    }) if observed == nonce => {
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
                            || !product_system_restricting_sid_match
                            || !product_desktop_assignment_match
                            || !product_create_no_window
                            || !product_logon_sid_match
                            || !product_session_id_match
                            || !product_window_station_low_integrity
                            || !product_desktop_low_integrity
                            || product_token_session_id != evidence.product_token_session_id
                            || product_authentication_id.evidence_value()
                                != evidence.product_authentication_id
                        {
                            bail!("restricted bootstrap exit evidence changed after product start");
                        }
                        bootstrap_exit = Some((code, private_job_descendant_contained));
                    }
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherExit {
                        nonce: observed,
                        bootstrap_exit_code,
                        bootstrap_resume_previous_count,
                        bootstrap_process_id,
                    }) if observed == nonce => {
                        let (code, contained) = bootstrap_exit
                            .context("account launcher exited before native bootstrap evidence")?;
                        let launcher = self
                            .launcher_ready_evidence
                            .as_ref()
                            .context("account launcher READY evidence is missing")?;
                        if bootstrap_exit_code != code
                            || bootstrap_resume_previous_count
                                != launcher
                                    .bootstrap_resume_previous_count
                                    .context("native bootstrap resume evidence is missing")?
                            || bootstrap_process_id != launcher.bootstrap_process_id
                        {
                            bail!(
                                "account launcher exit evidence changed native bootstrap identity"
                            );
                        }
                        break (code, contained);
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
                    BootstrapEvent::Message(BootstrapMessage::AccountLauncherError {
                        nonce: observed,
                        windows_error,
                        stage,
                    }) if observed == nonce => {
                        bail!(
                            "account launcher failed after native bootstrap start at launcher stage {stage} with Windows error {windows_error}"
                        )
                    }
                    BootstrapEvent::BootstrapExited(Ok(_))
                    | BootstrapEvent::LauncherExited(Ok(_)) => {
                        // The event-pipe line can arrive after the process signal. Keep the one
                        // absolute deadline while the reader drains the already-written status.
                    }
                    BootstrapEvent::BootstrapExited(Err(error))
                    | BootstrapEvent::LauncherExited(Err(error)) => {
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
            wait_process(
                self.bootstrap_process
                    .as_ref()
                    .context("native bootstrap process handle was not adopted")?,
                CONTROL_TIMEOUT,
                "restricted bootstrap exit",
            )?;
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
            if let Some(process) = self.bootstrap_process.as_ref() {
                wait_process_until(process, deadline, "restricted bootstrap cleanup")?;
            }
            wait_process_until(&self.process, deadline, "account launcher cleanup")?;
            if let Some(reader) = self.reader.take() {
                reader.join().map_err(|_| anyhow::anyhow!("bootstrap reader thread panicked"))?;
            }
            if let Some(status) = self.bootstrap_status.take() {
                status.join().map_err(|_| anyhow::anyhow!("bootstrap status thread panicked"))?;
            }
            if let Some(status) = self.launcher_status.take() {
                status
                    .join()
                    .map_err(|_| anyhow::anyhow!("account launcher status thread panicked"))?;
            }
            verify_file_sha256(
                &self.account_launcher_binary,
                &self.account_launcher_sha256,
                "dedicated Windows account launcher after containment cleanup",
            )?;
            verify_file_sha256(
                &self.bootstrap_binary,
                &self.bootstrap_sha256,
                "dedicated Windows bootstrap after containment cleanup",
            )?;
            if self.launcher_config_path.exists() || self.bootstrap_config_path.exists() {
                bail!("native Windows launch config survived successful containment cleanup");
            }
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
            BootstrapChildStage::OsAssignedDesktopReady => BootstrapStage::OsAssignedDesktopSecured,
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
        bootstrap: Option<&mut BootstrapSession>,
    ) -> Result<ExitStatus> {
        if trace.terminal.is_none() {
            trace.observe(BootstrapObservedEvent::Error);
        }
        let config_present = bootstrap_config_path(launch).is_file();
        let reason = bounded_text(&format!("{error:#}"), 2_048);
        let hang_diagnostic = bootstrap.as_deref().and_then(|value| value.hang_diagnostic.as_ref());
        let hang_diagnostic_error =
            bootstrap.as_deref().and_then(|value| value.hang_diagnostic_error.as_deref());
        let checkpoint = BootstrapFailureCheckpoint {
            schema_version: 1,
            record_type: "startup-failure",
            nonce: &launch.nonce,
            reason: &reason,
            config_present_after_failure: config_present,
            trace: &trace,
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
            Some(owner) => owner.cleanup(cleanup_deadline),
            None => Ok(()),
        };
        let bootstrap_result = match bootstrap {
            Some(bootstrap) => bootstrap.finish(cleanup_deadline),
            None => Ok(()),
        };
        let containment_cleanup = cleanup_checkpoint(&containment_result, containment_started);
        let bootstrap_cleanup = cleanup_checkpoint(&bootstrap_result, bootstrap_started);
        let cleanup_checkpoint = BootstrapCleanupCheckpoint {
            schema_version: 1,
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

    fn duplicate_into_process_with_access(
        source: HANDLE,
        process: HANDLE,
        access: u32,
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
                    access,
                    i32::from(inheritable),
                    0,
                )
            },
            &format!("duplicate Windows {name} handle with exact access"),
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

    fn owned_adopted_handle(value: u64, name: &str) -> Result<OwnedHandle> {
        let value = usize::try_from(value)? as HANDLE;
        if value.is_null() || value == INVALID_HANDLE_VALUE {
            bail!("Windows {name} adoption value is invalid");
        }
        Ok(OwnedHandle(value))
    }

    fn close_unadopted_handles(process: u64, primary_thread: u64) -> Result<()> {
        let process_value = process;
        let process = owned_adopted_handle(process, "unadopted native bootstrap process")?;
        if process_value == primary_thread {
            bail!("unadopted native bootstrap reused one handle value");
        }
        let primary_thread =
            owned_adopted_handle(primary_thread, "unadopted native bootstrap primary thread")?;
        drop(primary_thread);
        drop(process);
        Ok(())
    }

    fn query_process_image_path(process: HANDLE) -> Result<PathBuf> {
        let mut buffer = vec![0_u16; 32_768];
        let mut length = u32::try_from(buffer.len())?;
        check(
            unsafe { QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut length) },
            "query adopted native bootstrap image path",
        )?;
        let length = usize::try_from(length)?;
        if length == 0 || length >= buffer.len() {
            bail!("adopted native bootstrap image path exceeded its bound");
        }
        Ok(PathBuf::from(String::from_utf16(&buffer[..length])?))
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

    fn ensure_caller_security_privileges(
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
        let mut security_luid = Default::default();
        check(
            unsafe { LookupPrivilegeValueW(null(), SE_SECURITY_NAME, &mut security_luid) },
            "resolve SeSecurityPrivilege",
        )?;
        check_security_deadline(deadline, trace, "resolve SeSecurityPrivilege")?;
        let security_privilege = TOKEN_PRIVILEGES {
            PrivilegeCount: 1,
            Privileges: [LUID_AND_ATTRIBUTES {
                Luid: security_luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };
        unsafe { SetLastError(ERROR_SUCCESS) };
        check(
            unsafe {
                AdjustTokenPrivileges(token.0, 0, &security_privilege, 0, null_mut(), null_mut())
            },
            "enable SeSecurityPrivilege",
        )?;
        let adjust_error = unsafe { GetLastError() };
        check_security_deadline(deadline, trace, "enable SeSecurityPrivilege")?;
        if adjust_error == ERROR_NOT_ALL_ASSIGNED {
            bail!("supervisor token does not contain SeSecurityPrivilege");
        }
        let mut required = PRIVILEGE_SET {
            PrivilegeCount: 1,
            Control: PRIVILEGE_SET_ALL_NECESSARY,
            Privilege: [LUID_AND_ATTRIBUTES {
                Luid: security_luid,
                Attributes: SE_PRIVILEGE_ENABLED,
            }],
        };
        enabled = 0;
        check(
            unsafe { PrivilegeCheck(token.0, &mut required, &mut enabled) },
            "verify SeSecurityPrivilege",
        )?;
        check_security_deadline(deadline, trace, "verify SeSecurityPrivilege")?;
        if enabled == 0 {
            bail!("supervisor SeSecurityPrivilege is not enabled");
        }
        Ok(())
    }

    fn create_non_breakaway_job(
        deadline: Instant,
        trace: &mut BootstrapStartupTrace,
    ) -> Result<(OwnedHandle, Option<OwnedHandle>, OwnedHandle, u32)> {
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
        let ui_restrictions = JOBOBJECT_BASIC_UI_RESTRICTIONS {
            UIRestrictionsClass: WINDOWS_JOB_UI_RESTRICTION_MASK,
        };
        check(
            unsafe {
                SetInformationJobObject(
                    job.0,
                    JobObjectBasicUIRestrictions,
                    (&ui_restrictions as *const JOBOBJECT_BASIC_UI_RESTRICTIONS).cast(),
                    u32::try_from(size_of::<JOBOBJECT_BASIC_UI_RESTRICTIONS>())?,
                )
            },
            "configure Job Object UI restrictions",
        )?;
        let mut observed_ui_restrictions = JOBOBJECT_BASIC_UI_RESTRICTIONS::default();
        let mut returned = 0_u32;
        check(
            unsafe {
                QueryInformationJobObject(
                    job.0,
                    JobObjectBasicUIRestrictions,
                    (&mut observed_ui_restrictions as *mut JOBOBJECT_BASIC_UI_RESTRICTIONS).cast(),
                    u32::try_from(size_of::<JOBOBJECT_BASIC_UI_RESTRICTIONS>())?,
                    &mut returned,
                )
            },
            "query Job Object UI restrictions",
        )?;
        if returned != u32::try_from(size_of::<JOBOBJECT_BASIC_UI_RESTRICTIONS>())?
            || observed_ui_restrictions.UIRestrictionsClass != WINDOWS_JOB_UI_RESTRICTION_MASK
        {
            bail!("Job Object UI restriction mask did not match the exact required mask");
        }
        check_security_deadline(deadline, trace, "prove Job Object UI restrictions")?;
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
        Ok((job, query_job, completion_port, observed_ui_restrictions.UIRestrictionsClass))
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
        fn logon_group_selector_requires_exactly_one_logon_sid() {
            assert_eq!(single_logon_group_index(&[0, LOGON_ID_ATTRIBUTES, 4]).unwrap(), 1);
            assert!(single_logon_group_index(&[0, 4]).is_err());
            assert!(single_logon_group_index(&[LOGON_ID_ATTRIBUTES, LOGON_ID_ATTRIBUTES]).is_err());
        }

        #[test]
        fn token_group_bounds_reject_truncation_and_overflow() {
            let offset = std::mem::offset_of!(TOKEN_GROUPS, Groups);
            let one_group = token_groups_required_bytes(1).unwrap();
            assert_eq!(one_group, offset + size_of::<SID_AND_ATTRIBUTES>());
            validate_token_group_bounds(one_group, 1).unwrap();
            assert!(validate_token_group_bounds(one_group - 1, 1).is_err());
            assert!(token_groups_required_bytes(usize::MAX).is_err());
        }

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
