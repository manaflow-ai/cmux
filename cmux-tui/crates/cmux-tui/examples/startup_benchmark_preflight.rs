mod startup_benchmark_protocol;

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use cmux_tui_core::platform::transport;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use startup_benchmark_protocol::{
    CONTROL_TIMEOUT, TimingPage, arm_line, monotonic_ns, read_control_line, ready_line,
    write_control_line,
};
use wait_timeout::ChildExt;

#[derive(Serialize)]
struct PreflightEvidence {
    schema_version: u32,
    backend: String,
    policy: &'static str,
    handshake: &'static str,
    cleanup: &'static str,
    inside_write: bool,
    adjacent_write_denied: bool,
    descendant_adjacent_write_denied: bool,
    descendant_contained: bool,
    network_denied: bool,
    inbound_network_denied: bool,
    linux_no_new_privs: Option<bool>,
    linux_effective_capabilities_zero: Option<bool>,
    linux_sudo_bwrap: Option<bool>,
    linux_bwrap_version: Option<String>,
    linux_unprivileged_userns_clone: Option<i64>,
    linux_max_user_namespaces: Option<i64>,
    windows_low_integrity: Option<bool>,
    windows_no_enabled_privileges: Option<bool>,
    windows_registry_write_denied: Option<bool>,
    windows_grandchild_in_job: Option<bool>,
    windows_breakaway_denied: Option<bool>,
    windows_active_process_zero: Option<bool>,
    supervisor_ready: bool,
    timing_records: u64,
    supervisor_sha256: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct ProbeEvidence {
    network_denied: bool,
    linux_no_new_privs: Option<bool>,
    linux_effective_capabilities_zero: Option<bool>,
    windows_low_integrity: Option<bool>,
    windows_no_enabled_privileges: Option<bool>,
    windows_registry_write_denied: Option<bool>,
    windows_breakaway_denied: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize)]
struct ChildProbeEvidence {
    adjacent_write_denied: bool,
    windows_in_job: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize)]
struct InboundProbeEvidence {
    bound_address: Option<SocketAddr>,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("cmux-tui startup sandbox preflight: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let values = env::args().skip(1).collect::<Vec<_>>();
    match values.first().map(String::as_str) {
        Some("--probe") => run_probe(&values[1..]),
        Some("--probe-child") => run_probe_child(&values[1..]),
        Some("--breakaway-probe") => Ok(()),
        _ => run_controller(&values),
    }
}

fn run_controller(values: &[String]) -> Result<()> {
    let supervisor = required_path(values, "--supervisor")?;
    let fixture_parent = required_path(values, "--fixture-parent")?;
    let output = required_path(values, "--output")?;
    let backend = required_value(values, "--backend")?;
    if backend != expected_backend() {
        bail!("preflight backend must be {} on this platform", expected_backend());
    }
    let root = fixture_parent.join(format!("preflight-{}", std::process::id()));
    fs::create_dir(&root)?;
    let inside = root.join("inside-write");
    let probe_result = root.join("probe-result.json");
    let adjacent = fixture_parent.join("protected-adjacent");
    let child_adjacent = fixture_parent.join("protected-child-adjacent");
    fs::write(&adjacent, b"protected")?;
    fs::write(&child_adjacent, b"protected")?;
    make_write_probe_permissive(&adjacent)?;
    make_write_probe_permissive(&child_adjacent)?;
    let network_listener = trusted_network_listener()?;
    let network_address = network_listener.local_addr()?;

    let control_path = root.join("control.sock");
    let child_path = root.join("child.sock");
    let inbound_path = root.join("inbound.sock");
    let timing = TimingPage::create(root.join("timing.page"))?;
    let control = transport::listen(&control_path)?;
    let child_listener = transport::listen(&child_path)?;
    let inbound_listener = transport::listen(&inbound_path)?;
    let (control_sender, control_receiver) = mpsc::channel();
    let control_thread = thread::spawn(move || {
        let _ = control_sender.send(control.accept());
    });
    let (child_sender, child_receiver) = mpsc::channel();
    let child_thread = thread::spawn(move || {
        let _ = child_sender.send(child_listener.accept());
    });
    let (inbound_sender, inbound_receiver) = mpsc::channel();
    let inbound_thread = thread::spawn(move || {
        let _ = inbound_sender.send(inbound_listener.accept());
    });

    let current = env::current_exe()?;
    let nonce = timing.nonce_hex();
    let mut command = Command::new(&supervisor);
    command.args([
        "--control",
        &control_path.to_string_lossy(),
        "--timing",
        &timing.path().to_string_lossy(),
        "--nonce",
        &nonce,
        "--fixture-root",
        &root.to_string_lossy(),
        "--target",
        &current.to_string_lossy(),
        "--prove-private-job",
        "--",
        "--probe",
        &inside.to_string_lossy(),
        &adjacent.to_string_lossy(),
        &child_adjacent.to_string_lossy(),
        &child_path.to_string_lossy(),
        &network_address.to_string(),
        &network_address.ip().to_string(),
        &inbound_path.to_string_lossy(),
        &probe_result.to_string_lossy(),
    ]);
    command.env_clear();
    for key in [
        "PATH",
        "SHELL",
        "SystemRoot",
        "WINDIR",
        "COMSPEC",
        "PATHEXT",
        "DEVELOPER_DIR",
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
        if let Ok(value) = env::var(key) {
            command.env(key, value);
        }
    }
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let mut supervisor_stream = control_receiver
        .recv_timeout(CONTROL_TIMEOUT)
        .context("preflight supervisor did not connect")??;
    control_thread.join().map_err(|_| anyhow::anyhow!("control accept thread panicked"))?;
    supervisor_stream.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    supervisor_stream.set_write_timeout(Some(CONTROL_TIMEOUT))?;
    let ready = read_control_line(&mut supervisor_stream)?;
    if ready != ready_line(&nonce).trim_end() {
        bail!("preflight READY identity mismatch");
    }
    write_control_line(&mut supervisor_stream, &arm_line(&nonce))?;
    supervisor_stream.shutdown(std::net::Shutdown::Both)?;

    let mut inbound = inbound_receiver
        .recv_timeout(CONTROL_TIMEOUT)
        .context("preflight inbound-network probe did not connect")??;
    inbound_thread.join().map_err(|_| anyhow::anyhow!("inbound accept thread panicked"))?;
    inbound.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    inbound.set_write_timeout(Some(CONTROL_TIMEOUT))?;
    let inbound_probe: InboundProbeEvidence =
        serde_json::from_str(&read_control_line(&mut inbound)?)
            .context("parse inbound-network probe evidence")?;
    let inbound_network_denied = match inbound_probe.bound_address {
        None => true,
        Some(address) => TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_err(),
    };
    inbound.write_all(b"X")?;
    inbound.shutdown(std::net::Shutdown::Both)?;

    let mut descendant = child_receiver
        .recv_timeout(CONTROL_TIMEOUT)
        .context("preflight descendant did not connect")??;
    child_thread.join().map_err(|_| anyhow::anyhow!("child accept thread panicked"))?;
    descendant.set_read_timeout(Some(CONTROL_TIMEOUT))?;
    descendant.set_write_timeout(Some(CONTROL_TIMEOUT))?;
    let child_evidence: ChildProbeEvidence =
        serde_json::from_str(&read_control_line(&mut descendant)?)
            .context("parse preflight descendant evidence")?;
    let status = child
        .wait_timeout(CONTROL_TIMEOUT)?
        .context("preflight supervisor exceeded its deadline")?;
    let event_ns = monotonic_ns()?;
    let timing_result = timing.measured_duration_ns(event_ns);
    let mut tail = [0_u8; 1];
    let contained = matches!(descendant.read(&mut tail), Ok(0));
    if !contained {
        let _ = descendant.write_all(b"X");
        let _ = descendant.shutdown(std::net::Shutdown::Both);
    }

    let probe: ProbeEvidence = serde_json::from_slice(
        &fs::read(&probe_result).context("read sandbox product probe evidence")?,
    )
    .context("parse sandbox product probe evidence")?;
    drop(network_listener);
    let (bwrap_version, unprivileged_userns_clone, max_user_namespaces) =
        linux_platform_metadata()?;
    let evidence = PreflightEvidence {
        schema_version: 2,
        backend,
        policy: "fixture-root-only-write",
        handshake: "nonce-bound-ready-arm-with-pre-exec-t0",
        cleanup: "descendant-channel-eof-after-process-tree-empty",
        inside_write: inside.is_file(),
        adjacent_write_denied: fs::read(&adjacent)? == b"protected",
        descendant_adjacent_write_denied: child_evidence.adjacent_write_denied
            && fs::read(&child_adjacent)? == b"protected",
        descendant_contained: contained,
        network_denied: probe.network_denied,
        inbound_network_denied,
        linux_no_new_privs: probe.linux_no_new_privs,
        linux_effective_capabilities_zero: probe.linux_effective_capabilities_zero,
        linux_sudo_bwrap: linux_sudo_mode(),
        linux_bwrap_version: bwrap_version,
        linux_unprivileged_userns_clone: unprivileged_userns_clone,
        linux_max_user_namespaces: max_user_namespaces,
        windows_low_integrity: probe.windows_low_integrity,
        windows_no_enabled_privileges: probe.windows_no_enabled_privileges,
        windows_registry_write_denied: probe.windows_registry_write_denied,
        windows_grandchild_in_job: child_evidence.windows_in_job,
        windows_breakaway_denied: probe.windows_breakaway_denied,
        windows_active_process_zero: cfg!(windows).then_some(status.success() && contained),
        supervisor_ready: true,
        timing_records: if timing_result.is_ok() { 1 } else { 0 },
        supervisor_sha256: format!("{:x}", Sha256::digest(fs::read(&supervisor)?)),
    };
    write_evidence(&output, &evidence)?;
    if !status.success()
        || !evidence.inside_write
        || !evidence.adjacent_write_denied
        || !evidence.descendant_adjacent_write_denied
        || !evidence.descendant_contained
        || !evidence.network_denied
        || !evidence.inbound_network_denied
        || !platform_proofs_pass(&evidence)
        || evidence.timing_records != 1
    {
        bail!("sandbox preflight invariant failed; see {}", output.display());
    }
    drop(descendant);
    drop(timing);
    fs::remove_dir_all(&root).context("remove successful sandbox preflight root")?;
    fs::remove_file(&adjacent).context("remove successful parent sentinel")?;
    fs::remove_file(&child_adjacent).context("remove successful descendant sentinel")?;
    Ok(())
}

fn run_probe(values: &[String]) -> Result<()> {
    if values.len() != 8 {
        bail!("probe requires write, child, outbound-network, inbound-network, and result paths");
    }
    let inside = PathBuf::from(&values[0]);
    let adjacent = PathBuf::from(&values[1]);
    let child_adjacent = PathBuf::from(&values[2]);
    let child_socket = PathBuf::from(&values[3]);
    let network_address = values[4].parse::<SocketAddr>()?;
    let inbound_ip = values[5].parse::<std::net::IpAddr>()?;
    let inbound_socket = PathBuf::from(&values[6]);
    let result_path = PathBuf::from(&values[7]);
    fs::write(&inside, b"inside")?;
    let adjacent_denied = fs::write(&adjacent, b"changed").is_err();
    let network_denied =
        TcpStream::connect_timeout(&network_address, Duration::from_secs(2)).is_err();
    let inbound_listener = match TcpListener::bind(SocketAddr::new(inbound_ip, 0)) {
        Ok(listener) => Some(listener),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::PermissionDenied | std::io::ErrorKind::AddrNotAvailable
            ) =>
        {
            None
        }
        Err(error) => return Err(error).context("run contained inbound-network bind probe"),
    };
    let inbound_evidence = InboundProbeEvidence {
        bound_address: inbound_listener.as_ref().map(TcpListener::local_addr).transpose()?,
    };
    let mut inbound = transport::connect(&inbound_socket)?;
    write_control_line(&mut inbound, &format!("{}\n", serde_json::to_string(&inbound_evidence)?))?;
    let mut inbound_release = [0_u8; 1];
    inbound.read_exact(&mut inbound_release)?;
    drop(inbound_listener);
    let platform = product_platform_proofs()?;
    let current = env::current_exe()?;
    let mut child = Command::new(current);
    child
        .arg("--probe-child")
        .arg(child_adjacent)
        .arg(child_socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    detach(&mut child);
    child.spawn()?;
    let evidence = ProbeEvidence {
        network_denied,
        linux_no_new_privs: platform.linux_no_new_privs,
        linux_effective_capabilities_zero: platform.linux_effective_capabilities_zero,
        windows_low_integrity: platform.windows_low_integrity,
        windows_no_enabled_privileges: platform.windows_no_enabled_privileges,
        windows_registry_write_denied: platform.windows_registry_write_denied,
        windows_breakaway_denied: platform.windows_breakaway_denied,
    };
    fs::write(&result_path, serde_json::to_vec(&evidence)?)?;
    if !adjacent_denied {
        bail!("sandbox allowed an adjacent write");
    }
    Ok(())
}

fn run_probe_child(values: &[String]) -> Result<()> {
    if values.len() != 2 {
        bail!("probe child requires adjacent and control paths");
    }
    let denied = fs::write(&values[0], b"changed").is_err();
    let mut stream = transport::connect(Path::new(&values[1]))?;
    let evidence =
        ChildProbeEvidence { adjacent_write_denied: denied, windows_in_job: child_in_job()? };
    write_control_line(&mut stream, &format!("{}\n", serde_json::to_string(&evidence)?))?;
    let mut release = [0_u8; 1];
    let _ = stream.read(&mut release);
    if !denied {
        bail!("sandbox allowed a descendant adjacent write");
    }
    Ok(())
}

fn trusted_network_listener() -> Result<TcpListener> {
    let route = UdpSocket::bind("0.0.0.0:0")?;
    route.connect("192.0.2.1:9")?;
    let address = SocketAddr::new(route.local_addr()?.ip(), 0);
    TcpListener::bind(address).context("bind trusted network-denial listener")
}

fn platform_proofs_pass(evidence: &PreflightEvidence) -> bool {
    #[cfg(target_os = "linux")]
    {
        evidence.linux_no_new_privs == Some(true)
            && evidence.linux_effective_capabilities_zero == Some(true)
            && evidence.linux_sudo_bwrap.is_some()
            && evidence.linux_bwrap_version.as_ref().is_some_and(|value| !value.is_empty())
            && evidence.linux_unprivileged_userns_clone.is_some()
            && evidence.linux_max_user_namespaces.is_some()
            && evidence.windows_low_integrity.is_none()
            && evidence.windows_no_enabled_privileges.is_none()
            && evidence.windows_registry_write_denied.is_none()
            && evidence.windows_grandchild_in_job.is_none()
            && evidence.windows_breakaway_denied.is_none()
            && evidence.windows_active_process_zero.is_none()
    }
    #[cfg(target_os = "macos")]
    {
        evidence.linux_no_new_privs.is_none()
            && evidence.linux_effective_capabilities_zero.is_none()
            && evidence.linux_sudo_bwrap.is_none()
            && evidence.linux_bwrap_version.is_none()
            && evidence.linux_unprivileged_userns_clone.is_none()
            && evidence.linux_max_user_namespaces.is_none()
            && evidence.windows_low_integrity.is_none()
            && evidence.windows_no_enabled_privileges.is_none()
            && evidence.windows_registry_write_denied.is_none()
            && evidence.windows_grandchild_in_job.is_none()
            && evidence.windows_breakaway_denied.is_none()
            && evidence.windows_active_process_zero.is_none()
    }
    #[cfg(windows)]
    {
        evidence.linux_no_new_privs.is_none()
            && evidence.linux_effective_capabilities_zero.is_none()
            && evidence.linux_sudo_bwrap.is_none()
            && evidence.linux_bwrap_version.is_none()
            && evidence.linux_unprivileged_userns_clone.is_none()
            && evidence.linux_max_user_namespaces.is_none()
            && evidence.windows_low_integrity == Some(true)
            && evidence.windows_no_enabled_privileges == Some(true)
            && evidence.windows_registry_write_denied == Some(true)
            && evidence.windows_grandchild_in_job == Some(true)
            && evidence.windows_breakaway_denied == Some(true)
            && evidence.windows_active_process_zero == Some(true)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        false
    }
}

#[cfg(target_os = "linux")]
fn linux_platform_metadata() -> Result<(Option<String>, Option<i64>, Option<i64>)> {
    let bwrap = env::var("CMUX_BENCH_LINUX_BWRAP").context("CMUX_BENCH_LINUX_BWRAP is required")?;
    let output = Command::new(bwrap).arg("--version").output()?;
    if !output.status.success() {
        bail!("Bubblewrap version query failed with {}", output.status);
    }
    let version = String::from_utf8(output.stdout)?.trim().to_string();
    if version.is_empty() {
        bail!("Bubblewrap version query returned no version");
    }
    let userns = read_linux_integer("/proc/sys/kernel/unprivileged_userns_clone")?;
    let maximum = read_linux_integer("/proc/sys/user/max_user_namespaces")?;
    Ok((Some(version), Some(userns), Some(maximum)))
}

#[cfg(target_os = "linux")]
fn linux_sudo_mode() -> Option<bool> {
    Some(env::var("CMUX_BENCH_LINUX_SUDO").as_deref() == Ok("1"))
}

#[cfg(not(target_os = "linux"))]
fn linux_sudo_mode() -> Option<bool> {
    None
}

#[cfg(target_os = "linux")]
fn read_linux_integer(path: &str) -> Result<i64> {
    fs::read_to_string(path)?
        .trim()
        .parse()
        .with_context(|| format!("parse Linux user-namespace setting {path}"))
}

#[cfg(not(target_os = "linux"))]
fn linux_platform_metadata() -> Result<(Option<String>, Option<i64>, Option<i64>)> {
    Ok((None, None, None))
}

#[cfg(target_os = "linux")]
fn product_platform_proofs() -> Result<ProbeEvidence> {
    let status = fs::read_to_string("/proc/self/status")?;
    let no_new_privs = status.lines().find_map(|line| line.strip_prefix("NoNewPrivs:"));
    let cap_eff = status.lines().find_map(|line| line.strip_prefix("CapEff:"));
    Ok(ProbeEvidence {
        network_denied: false,
        linux_no_new_privs: Some(no_new_privs.is_some_and(|value| value.trim() == "1")),
        linux_effective_capabilities_zero: Some(
            cap_eff.and_then(|value| u64::from_str_radix(value.trim(), 16).ok()) == Some(0),
        ),
        windows_low_integrity: None,
        windows_no_enabled_privileges: None,
        windows_registry_write_denied: None,
        windows_breakaway_denied: None,
    })
}

#[cfg(target_os = "macos")]
fn product_platform_proofs() -> Result<ProbeEvidence> {
    Ok(ProbeEvidence {
        network_denied: false,
        linux_no_new_privs: None,
        linux_effective_capabilities_zero: None,
        windows_low_integrity: None,
        windows_no_enabled_privileges: None,
        windows_registry_write_denied: None,
        windows_breakaway_denied: None,
    })
}

#[cfg(not(windows))]
fn child_in_job() -> Result<Option<bool>> {
    Ok(None)
}

#[cfg(windows)]
fn product_platform_proofs() -> Result<ProbeEvidence> {
    use std::ffi::c_void;
    use std::mem::size_of;
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::process::CommandExt;
    use std::ptr::{null, null_mut};

    use windows_sys::Win32::Foundation::{CloseHandle, ERROR_ACCESS_DENIED, HANDLE};
    use windows_sys::Win32::Security::{
        GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, OpenProcessToken,
        SE_PRIVILEGE_ENABLED, TOKEN_MANDATORY_LABEL, TOKEN_PRIVILEGES, TOKEN_QUERY,
        TokenIntegrityLevel, TokenPrivileges,
    };
    use windows_sys::Win32::System::Registry::{
        HKEY_CURRENT_USER, KEY_WRITE, RegCloseKey, RegOpenKeyExW,
    };
    use windows_sys::Win32::System::SystemServices::SECURITY_MANDATORY_LOW_RID;
    use windows_sys::Win32::System::Threading::{CREATE_BREAKAWAY_FROM_JOB, GetCurrentProcess};

    struct Handle(HANDLE);
    impl Drop for Handle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: this owner closes its non-null token handle once.
                unsafe { CloseHandle(self.0) };
            }
        }
    }

    fn token_information(token: HANDLE, class: i32) -> Result<Vec<usize>> {
        let mut byte_count = 0_u32;
        // SAFETY: a null buffer with zero length requests the required byte count.
        let _ = unsafe { GetTokenInformation(token, class, null_mut(), 0, &mut byte_count) };
        if byte_count == 0 {
            return Err(std::io::Error::last_os_error()).context("size token information");
        }
        let words = usize::try_from(byte_count)?.div_ceil(size_of::<usize>());
        let mut storage = vec![0_usize; words];
        // SAFETY: storage is aligned, writable, and has at least byte_count bytes.
        if unsafe {
            GetTokenInformation(
                token,
                class,
                storage.as_mut_ptr().cast::<c_void>(),
                byte_count,
                &mut byte_count,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error()).context("read token information");
        }
        Ok(storage)
    }

    let mut token = null_mut();
    // SAFETY: token points to writable handle storage.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(std::io::Error::last_os_error()).context("open preflight product token");
    }
    let token = Handle(token);

    let integrity = token_information(token.0, TokenIntegrityLevel)?;
    // SAFETY: the token API filled an aligned TOKEN_MANDATORY_LABEL in this live buffer.
    let label = unsafe { &*(integrity.as_ptr().cast::<TOKEN_MANDATORY_LABEL>()) };
    // SAFETY: the label SID came from GetTokenInformation and remains live with integrity.
    let count = unsafe { GetSidSubAuthorityCount(label.Label.Sid) };
    let low_integrity = if count.is_null() || unsafe { *count } == 0 {
        false
    } else {
        // SAFETY: the SID has at least the reported number of subauthorities.
        let rid = unsafe { GetSidSubAuthority(label.Label.Sid, u32::from(*count) - 1) };
        !rid.is_null() && unsafe { *rid } == SECURITY_MANDATORY_LOW_RID as u32
    };

    let privileges = token_information(token.0, TokenPrivileges)?;
    // SAFETY: the token API filled an aligned TOKEN_PRIVILEGES header in this live buffer.
    let privileges = unsafe { &*(privileges.as_ptr().cast::<TOKEN_PRIVILEGES>()) };
    let first = privileges.Privileges.as_ptr();
    let no_enabled_privileges = (0..privileges.PrivilegeCount).all(|index| {
        // SAFETY: TOKEN_PRIVILEGES stores PrivilegeCount contiguous entries after the header.
        unsafe { (*first.add(index as usize)).Attributes & SE_PRIVILEGE_ENABLED == 0 }
    });

    let subkey_wide =
        std::ffi::OsStr::new("Software").encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let mut key = null_mut();
    // SAFETY: the existing HKCU Software path is NUL-terminated and key is writable storage.
    let registry_result =
        unsafe { RegOpenKeyExW(HKEY_CURRENT_USER, subkey_wide.as_ptr(), 0, KEY_WRITE, &mut key) };
    let registry_write_denied = registry_result == ERROR_ACCESS_DENIED;
    if registry_result == 0 {
        // SAFETY: a successful open returned a live key owned by this scope.
        unsafe { RegCloseKey(key) };
    }

    let mut breakaway = Command::new(env::current_exe()?);
    breakaway
        .arg("--breakaway-probe")
        .creation_flags(CREATE_BREAKAWAY_FROM_JOB)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let breakaway_denied = match breakaway.spawn() {
        Err(error) => error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32),
        Ok(mut child) => {
            let completed = child.wait_timeout(CONTROL_TIMEOUT)?;
            if completed.is_none() {
                child.kill()?;
                child.wait()?;
            }
            false
        }
    };

    Ok(ProbeEvidence {
        network_denied: false,
        linux_no_new_privs: None,
        linux_effective_capabilities_zero: None,
        windows_low_integrity: Some(low_integrity),
        windows_no_enabled_privileges: Some(no_enabled_privileges),
        windows_registry_write_denied: Some(registry_write_denied),
        windows_breakaway_denied: Some(breakaway_denied),
    })
}

#[cfg(windows)]
fn child_in_job() -> Result<Option<bool>> {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::IsProcessInJob;
    use windows_sys::Win32::System::Threading::GetCurrentProcess;

    let job = env::var("CMUX_BENCH_PRIVATE_JOB_HANDLE")
        .context("CMUX_BENCH_PRIVATE_JOB_HANDLE is required")?
        .parse::<usize>()? as HANDLE;
    let mut in_job = 0;
    // SAFETY: job is the inherited query-only handle for the supervisor's private Job Object.
    let result = unsafe { IsProcessInJob(GetCurrentProcess(), job, &mut in_job) };
    let error = (result == 0).then(std::io::Error::last_os_error);
    // SAFETY: this trusted child owns its inherited query-only duplicate and closes it once.
    unsafe { CloseHandle(job) };
    if let Some(error) = error {
        return Err(error).context("query exact private Job membership");
    }
    Ok(Some(in_job != 0))
}

#[cfg(unix)]
fn detach(command: &mut Command) {
    use std::os::unix::process::CommandExt;

    // SAFETY: setsid is async-signal-safe and does not access shared Rust state.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

#[cfg(windows)]
fn detach(command: &mut Command) {
    use std::os::windows::process::CommandExt;

    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    command.creation_flags(CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS);
}

fn required_value(values: &[String], option: &str) -> Result<String> {
    values
        .windows(2)
        .find(|pair| pair[0] == option)
        .map(|pair| pair[1].clone())
        .with_context(|| format!("{option} is required"))
}

fn required_path(values: &[String], option: &str) -> Result<PathBuf> {
    required_value(values, option).map(PathBuf::from)
}

fn expected_backend() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        "linux-bwrap"
    }
    #[cfg(target_os = "macos")]
    {
        "macos-seatbelt"
    }
    #[cfg(windows)]
    {
        "windows-restricted-token-job"
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        "unsupported"
    }
}

fn write_evidence(path: &Path, evidence: &PreflightEvidence) -> Result<()> {
    let mut file = OpenOptions::new().create_new(true).write(true).open(path)?;
    serde_json::to_writer_pretty(&mut file, evidence)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

#[cfg(unix)]
fn make_write_probe_permissive(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, fs::Permissions::from_mode(0o666))?;
    Ok(())
}

#[cfg(windows)]
fn make_write_probe_permissive(_path: &Path) -> Result<()> {
    // The Windows write-restricted SID is the independent mandatory write boundary.
    Ok(())
}
