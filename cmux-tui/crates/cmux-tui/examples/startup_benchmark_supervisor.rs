mod startup_benchmark_protocol;

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};

use anyhow::{Context, Result, bail};
use cmux_tui_core::platform::transport;
#[cfg(target_os = "macos")]
use startup_benchmark_protocol::macos_account_identity;
use startup_benchmark_protocol::{
    CONTROL_TIMEOUT, TimingSink, arm_line, read_control_line, ready_line, write_control_line,
};

#[derive(Debug, Clone)]
struct Launch {
    control: PathBuf,
    timing: PathBuf,
    nonce: String,
    fixture_root: PathBuf,
    target: PathBuf,
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
    let launch = parse_args(env::args().skip(1))?;
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
    control.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    control.set_write_timeout(Some(CONTROL_TIMEOUT))?;
    fs::remove_file(&launch.timing).context("unlink live timing page")?;
    fs::remove_file(&launch.control).context("unlink live control socket")?;
    write_control_line(&mut control, &ready_line(&launch.nonce))?;
    let arm = read_control_line(&mut control)?;
    if arm != arm_line(&launch.nonce).trim_end() {
        bail!("control ARM identity mismatch");
    }
    control.shutdown(std::net::Shutdown::Both)?;
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

fn parse_args(values: impl Iterator<Item = String>) -> Result<Launch> {
    let mut values = values;
    let mut launch = Launch {
        control: PathBuf::new(),
        timing: PathBuf::new(),
        nonce: String::new(),
        fixture_root: PathBuf::new(),
        target: PathBuf::new(),
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
                launch.fixture_root = required_value(&mut values, &argument)?.into()
            }
            "--target" => launch.target = required_value(&mut values, &argument)?.into(),
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
    Ok(())
}

#[cfg(target_os = "linux")]
mod platform {
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
        let current = env::current_exe()?;
        if let Some((_, gid)) = &identity {
            grant_fixture_group_access(launch, gid)?;
        }
        let sandbox_supervisor = Path::new("/cmux-bin/supervisor");
        let sandbox_target = Path::new("/cmux-bin/product");
        let mut command = if use_sudo {
            let mut command = Command::new("sudo");
            command.args(["-n", "--"]).arg(&bwrap);
            command
        } else {
            Command::new(&bwrap)
        };
        command.args([
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--clearenv",
            "--dir",
            "/cmux-bin",
        ]);
        if !use_sudo {
            command.args(["--cap-drop", "ALL"]);
        }
        append_contained_environment(&mut command);
        command.arg("--ro-bind");
        command.arg(&current).arg(sandbox_supervisor);
        command.arg("--ro-bind").arg(&launch.target).arg(sandbox_target);
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
        command.status().context("launch Bubblewrap supervisor")
    }

    pub fn exec_product(mut command: Command, timing: TimingSink) -> Result<()> {
        // SAFETY: prctl, the atomic mmap write, and the monotonic clock call are
        // async-signal-safe and do not access shared Rust state.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1 {
                    return Err(std::io::Error::last_os_error());
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
        let mut account = JobAccount::create(launch)?;
        let mut command = Command::new("sudo");
        command.args(["-n", "-u", &account.user, "--", "/usr/bin/env", "-i"]);
        append_product_environment(&mut command);
        command.args(["/usr/bin/sandbox-exec", "-D"]);
        command.arg(format!("CMUX_FIXTURE_ROOT={}", launch.fixture_root.to_string_lossy()));
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
        fn create(launch: &Launch) -> Result<Self> {
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
                fixture_root: launch.fixture_root.clone(),
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
                ("AuthenticationAuthority", ";DisabledUser;".into()),
            ] {
                sudo(["dscl", ".", "-create", &format!("/Users/{}", self.user), key, &value])?;
            }
            sudo(["dscl", ".", "-passwd", &format!("/Users/{}", self.user), "*"])?;
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
        let status = Command::new("sudo").arg("-n").args(arguments).status()?;
        if !status.success() {
            bail!("privileged macOS account command failed with {status}");
        }
        Ok(())
    }

    fn sudo_path<const N: usize>(arguments: [&str; N], path: &Path) -> Result<()> {
        let status = Command::new("sudo").arg("-n").args(arguments).arg(path).status()?;
        if !status.success() {
            bail!("privileged macOS fixture command failed with {status}");
        }
        Ok(())
    }

    pub fn exec_product(mut command: Command, timing: TimingSink) -> Result<()> {
        // SAFETY: the closure performs one atomic mmap write and a monotonic clock syscall.
        unsafe { command.pre_exec(move || timing.record_pre_exec()) };
        Err(command.exec()).context("exec contained product")
    }

    fn terminate_job_user(user: &str) -> Result<()> {
        let pids = user_processes(user)?;
        let exits = ExitWatch::new(&pids)?;
        let status = Command::new("sudo").args(["-n", "pkill", "-KILL", "-u", user]).status()?;
        if !status.success() && status.code() != Some(1) {
            bail!("Seatbelt job-user kill failed with {status}");
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
                return Err(std::io::Error::last_os_error())
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
                } else if std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                    return Err(std::io::Error::last_os_error())
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
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::Interrupted {
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
    use std::mem::{size_of, zeroed};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::process::ExitStatusExt;
    use std::ptr::{null, null_mut};
    use std::time::Instant;

    use windows_sys::Win32::Foundation::{
        CloseHandle, DuplicateHandle, GENERIC_ALL, HANDLE, INVALID_HANDLE_VALUE, LocalFree,
        WAIT_OBJECT_0,
    };
    use windows_sys::Win32::Security::Authorization::{
        ConvertStringSidToSidW, EXPLICIT_ACCESS_W, GRANT_ACCESS, GetNamedSecurityInfoW,
        NO_MULTIPLE_TRUSTEE, SE_FILE_OBJECT, SetEntriesInAclW, SetNamedSecurityInfoW,
        TRUSTEE_IS_SID, TRUSTEE_IS_UNKNOWN, TRUSTEE_W,
    };
    use windows_sys::Win32::Security::{
        ACL, CreateRestrictedToken, DACL_SECURITY_INFORMATION, DISABLE_MAX_PRIVILEGE, GetLengthSid,
        LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, LogonUserW, PSECURITY_DESCRIPTOR,
        PSID, SID_AND_ATTRIBUTES, SUB_CONTAINERS_AND_OBJECTS_INHERIT, SetTokenInformation,
        TOKEN_MANDATORY_LABEL, TokenIntegrityLevel, WRITE_RESTRICTED,
    };
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
    use windows_sys::Win32::System::SystemServices::{
        JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO, JOB_OBJECT_QUERY, SE_GROUP_INTEGRITY,
    };
    use windows_sys::Win32::System::Threading::{
        CREATE_SUSPENDED, CREATE_UNICODE_ENVIRONMENT, CreateProcessAsUserW, GetCurrentProcess,
        GetExitCodeProcess, INFINITE, PROCESS_INFORMATION, ResumeThread, STARTF_USESTDHANDLES,
        STARTUPINFOW, TerminateProcess, WaitForSingleObject,
    };
    use windows_sys::Win32::UI::Shell::{LoadUserProfileW, PROFILEINFOW, UnloadUserProfile};

    use super::*;

    pub fn run_outer(launch: &Launch) -> Result<ExitStatus> {
        let mut restricted = RestrictedToken::new(launch)?;
        let timing = TimingSink::open(&launch.timing, &launch.nonce)?;
        let mut control = transport::connect(&launch.control)
            .with_context(|| format!("connect control socket {}", launch.control.display()))?;
        control.set_read_timeout(Some(CONTROL_TIMEOUT))?;
        control.set_write_timeout(Some(CONTROL_TIMEOUT))?;
        fs::remove_file(&launch.timing).context("remove live Windows timing page")?;
        match fs::remove_file(&launch.control) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // Windows AF_UNIX names do not create filesystem entries.
            }
            Err(error) => return Err(error).context("remove live Windows control socket"),
        }
        write_control_line(&mut control, &ready_line(&launch.nonce))?;
        let arm = read_control_line(&mut control)?;
        if arm != arm_line(&launch.nonce).trim_end() {
            bail!("control ARM identity mismatch");
        }
        control.shutdown(std::net::Shutdown::Both)?;
        drop(control);

        let result = restricted.create_product(launch, &timing);
        let cleanup = restricted.cleanup();
        match (result, cleanup) {
            (Ok(status), Ok(())) => Ok(status),
            (Err(error), Ok(())) => Err(error),
            (Ok(_), Err(cleanup)) => Err(cleanup),
            (Err(error), Err(cleanup)) => {
                Err(error.context(format!("Windows containment cleanup also failed: {cleanup:#}")))
            }
        }
    }

    pub fn exec_product(_command: Command, _timing: TimingSink) -> Result<()> {
        bail!("Windows restricted-token supervisor inner mode is invalid")
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

    struct RestrictedToken {
        token: OwnedHandle,
        job: OwnedHandle,
        query_job: Option<OwnedHandle>,
        completion_port: OwnedHandle,
        // Keep the profile after all Job handles so field-drop fallback closes the containment
        // boundary before it tries to unload a profile after an error.
        profile: Option<LoadedProfile>,
        restricting_sid: OwnedSid,
        product_assigned: bool,
    }

    impl RestrictedToken {
        fn new(launch: &Launch) -> Result<Self> {
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
            let profile = if launch.prove_private_job {
                Some(LoadedProfile::load(
                    account_token
                        .take()
                        .context("Windows account token is required for profile preflight")?,
                    &user,
                )?)
            } else {
                None
            };
            let source_token = profile
                .as_ref()
                .map(LoadedProfile::token)
                .or_else(|| account_token.as_ref().map(|token| token.0))
                .context("Windows account token owner is missing")?;
            let sid_text = random_restricting_sid()?;
            let restricting_sid = OwnedSid::from_string(&sid_text)?;
            let low_sid = OwnedSid::from_string("S-1-16-4096")?;
            let restricting = SID_AND_ATTRIBUTES { Sid: restricting_sid.0, Attributes: 0 };
            let mut token = null_mut();
            // SAFETY: all pointers and element counts reference live values for this call.
            check(
                unsafe {
                    CreateRestrictedToken(
                        source_token,
                        DISABLE_MAX_PRIVILEGE | WRITE_RESTRICTED,
                        0,
                        null(),
                        0,
                        null(),
                        1,
                        &restricting,
                        &mut token,
                    )
                },
                "create restricted primary token",
            )?;
            let token = OwnedHandle(token);
            let label = TOKEN_MANDATORY_LABEL {
                Label: SID_AND_ATTRIBUTES { Sid: low_sid.0, Attributes: SE_GROUP_INTEGRITY as u32 },
            };
            // SAFETY: the label contains a live SID and the byte count includes its payload.
            check(
                unsafe {
                    SetTokenInformation(
                        token.0,
                        TokenIntegrityLevel,
                        (&label as *const TOKEN_MANDATORY_LABEL).cast::<c_void>(),
                        u32::try_from(size_of::<TOKEN_MANDATORY_LABEL>())?
                            + unsafe { GetLengthSid(low_sid.0) },
                    )
                },
                "set low token integrity",
            )?;
            configure_fixture_acl(&launch.fixture_root, &user, restricting_sid.0)?;
            let (job, query_job, completion_port) =
                create_non_breakaway_job(launch.prove_private_job)?;
            Ok(Self {
                token,
                profile,
                job,
                query_job,
                completion_port,
                restricting_sid,
                product_assigned: false,
            })
        }

        fn create_product(&mut self, launch: &Launch, timing: &TimingSink) -> Result<ExitStatus> {
            let application = wide(launch.target.as_os_str());
            let current_directory = wide(launch.fixture_root.as_os_str());
            let mut command_line = wide(std::ffi::OsStr::new(&windows_command_line(
                &launch.target,
                &launch.product_args,
            )));
            // SAFETY: zero is a valid initial state for these Win32 structs.
            let mut startup: STARTUPINFOW = unsafe { zeroed() };
            startup.cb = u32::try_from(size_of::<STARTUPINFOW>())?;
            startup.dwFlags = STARTF_USESTDHANDLES;
            // SAFETY: these calls return the supervisor's inherited PTY or capture handles.
            startup.hStdInput = unsafe { GetStdHandle(STD_INPUT_HANDLE) };
            startup.hStdOutput = unsafe { GetStdHandle(STD_OUTPUT_HANDLE) };
            startup.hStdError = unsafe { GetStdHandle(STD_ERROR_HANDLE) };
            // SAFETY: zero is a valid initial state for PROCESS_INFORMATION.
            let mut process: PROCESS_INFORMATION = unsafe { zeroed() };
            let mut environment =
                product_environment_block(self.query_job.as_ref().map(|handle| handle.0 as usize));
            timing.record_pre_exec()?;
            // SAFETY: all strings are NUL-terminated and output storage remains live.
            check(
                unsafe {
                    CreateProcessAsUserW(
                        self.token.0,
                        application.as_ptr(),
                        command_line.as_mut_ptr(),
                        null(),
                        null(),
                        1,
                        CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                        environment.as_mut_ptr().cast::<c_void>(),
                        current_directory.as_ptr(),
                        &startup,
                        &mut process,
                    )
                },
                "create suspended restricted product",
            )?;
            let process_handle = OwnedHandle(process.hProcess);
            let thread_handle = OwnedHandle(process.hThread);
            // SAFETY: both handles are live and the process is still suspended.
            if unsafe { AssignProcessToJobObject(self.job.0, process_handle.0) } == 0 {
                let error = std::io::Error::last_os_error();
                // SAFETY: process_handle is the suspended process created above.
                let _ = unsafe { TerminateProcess(process_handle.0, 125) };
                // SAFETY: process_handle remains live until the end of this scope.
                let _ = unsafe { WaitForSingleObject(process_handle.0, INFINITE) };
                return Err(error).context("assign product to non-breakaway job");
            }
            self.product_assigned = true;
            // SAFETY: thread_handle is the suspended primary thread.
            if unsafe { ResumeThread(thread_handle.0) } == u32::MAX {
                return Err(std::io::Error::last_os_error()).context("resume restricted product");
            }
            // SAFETY: process_handle is a live process handle.
            if unsafe { WaitForSingleObject(process_handle.0, INFINITE) } != WAIT_OBJECT_0 {
                return Err(std::io::Error::last_os_error()).context("wait for restricted product");
            }
            let mut code = 0_u32;
            // SAFETY: code points to writable storage and process_handle remains live.
            check(
                unsafe { GetExitCodeProcess(process_handle.0, &mut code) },
                "read restricted product exit code",
            )?;
            let _ = &self.restricting_sid;
            Ok(ExitStatus::from_raw(code))
        }

        fn cleanup(&mut self) -> Result<()> {
            if self.product_assigned {
                self.terminate_descendants_and_wait_empty()?;
                self.product_assigned = false;
            }
            match self.profile.as_mut() {
                Some(profile) => profile.cleanup(),
                None => Ok(()),
            }
        }

        fn terminate_descendants_and_wait_empty(&self) -> Result<()> {
            // SAFETY: job is a live private Job Object owned by this supervisor.
            check(unsafe { TerminateJobObject(self.job.0, 125) }, "terminate contained job")?;
            let deadline = Instant::now()
                .checked_add(CONTROL_TIMEOUT)
                .context("Job Object cleanup deadline overflow")?;
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

    const JOB_COMPLETION_KEY: usize = 0x434d_5558;

    fn create_non_breakaway_job(
        prove_private_job: bool,
    ) -> Result<(OwnedHandle, Option<OwnedHandle>, OwnedHandle)> {
        // SAFETY: null security attributes and name request an unnamed private job.
        let job = unsafe { CreateJobObjectW(null(), null()) };
        if job.is_null() {
            return Err(std::io::Error::last_os_error()).context("create containment job");
        }
        let job = OwnedHandle(job);
        let query_job = if prove_private_job {
            let mut query_job = null_mut();
            // SAFETY: the source and target process are current, the source job is live, and
            // output is writable. The preflight-only duplicate is inheritable and query-only.
            check(
                unsafe {
                    DuplicateHandle(
                        GetCurrentProcess(),
                        job.0,
                        GetCurrentProcess(),
                        &mut query_job,
                        JOB_OBJECT_QUERY,
                        1,
                        0,
                    )
                },
                "duplicate preflight query-only containment Job handle",
            )?;
            Some(OwnedHandle(query_job))
        } else {
            None
        };
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
        // SAFETY: INVALID_HANDLE_VALUE requests a new completion port.
        let completion_port =
            unsafe { CreateIoCompletionPort(INVALID_HANDLE_VALUE, null_mut(), 0, 1) };
        if completion_port.is_null() {
            return Err(std::io::Error::last_os_error())
                .context("create Job Object completion port");
        }
        let completion_port = OwnedHandle(completion_port);
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
        Ok((job, query_job, completion_port))
    }

    fn configure_fixture_acl(root: &Path, user: &str, sid: PSID) -> Result<()> {
        let root_text = root.to_string_lossy();
        run_acl([root_text.as_ref(), "/grant", &format!("{user}:(OI)(CI)(F)"), "/T", "/C"])?;
        grant_restricting_sid_tree(root, sid)?;
        run_acl([root_text.as_ref(), "/setintegritylevel", "(OI)(CI)L", "/T", "/C"])
    }

    fn grant_restricting_sid_tree(path: &Path, sid: PSID) -> Result<()> {
        let metadata = fs::symlink_metadata(path)?;
        if metadata.file_type().is_symlink() {
            bail!("Windows benchmark fixture contains a symbolic link: {}", path.display());
        }
        grant_restricting_sid(path, sid, metadata.is_dir())?;
        if metadata.is_dir() {
            for entry in fs::read_dir(path)? {
                grant_restricting_sid_tree(&entry?.path(), sid)?;
            }
        }
        Ok(())
    }

    fn grant_restricting_sid(path: &Path, sid: PSID, container: bool) -> Result<()> {
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
        check_windows_error(assign_result, "assign Windows restricting-SID DACL")
    }

    fn check_windows_error(error: u32, operation: &str) -> Result<()> {
        if error == 0 {
            return Ok(());
        }
        let error = i32::try_from(error).context("Windows error code exceeded i32")?;
        Err(std::io::Error::from_raw_os_error(error)).context(operation.to_string())
    }

    fn run_acl<const N: usize>(arguments: [&str; N]) -> Result<()> {
        let output = Command::new("icacls.exe").args(arguments).output()?;
        if !output.status.success() {
            bail!(
                "icacls failed with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr)
            );
        }
        Ok(())
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

    fn product_environment_block(query_job: Option<usize>) -> Vec<u16> {
        let mut values = env::vars_os()
            .filter_map(|(key, value)| {
                let key = key.to_string_lossy();
                if key.eq_ignore_ascii_case("CMUX_BENCH_WINDOWS_USER")
                    || key.eq_ignore_ascii_case("CMUX_BENCH_WINDOWS_PASSWORD")
                    || key.starts_with("CMUX_BENCH_")
                {
                    return None;
                }
                Some(format!("{key}={}", value.to_string_lossy()))
            })
            .collect::<Vec<_>>();
        if let Some(query_job) = query_job {
            values.push(format!("CMUX_BENCH_PRIVATE_JOB_HANDLE={query_job}"));
        }
        values.sort_by_key(|value| value.to_ascii_uppercase());
        let mut block = Vec::new();
        for value in values {
            block.extend(std::ffi::OsStr::new(&value).encode_wide());
            block.push(0);
        }
        block.push(0);
        block
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
    ];
    if launch.prove_private_job {
        values.push("--prove-private-job".into());
    }
    values.push("--".into());
    values.extend(launch.product_args.clone());
    values
}
