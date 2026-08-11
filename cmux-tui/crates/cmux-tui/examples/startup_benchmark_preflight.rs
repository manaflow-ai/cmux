mod startup_benchmark_protocol;

use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use cmux_tui_core::platform::transport;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use startup_benchmark_protocol::{
    CONTROL_TIMEOUT, TimingPage, arm_line, monotonic_ns, read_control_line, ready_line,
    write_control_line,
};
use wait_timeout::ChildExt;

const MAX_SUPERVISOR_STDERR_BYTES: usize = 64 * 1024;
const MAX_PRODUCT_EVENT_BYTES: usize = 64 * 1024;

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

enum SupervisorStartupEvent {
    Connected(io::Result<Box<dyn transport::Stream>>),
    ProductLine(io::Result<Vec<u8>>),
    ProductOutputClosed(io::Result<()>),
    StderrClosed(io::Result<Vec<u8>>),
}

struct SupervisorEventOwner {
    child: Child,
    input: ChildStdin,
    receiver: mpsc::Receiver<SupervisorStartupEvent>,
    control_path: PathBuf,
    control_thread: Option<thread::JoinHandle<()>>,
    output_thread: Option<thread::JoinHandle<()>>,
    stderr_thread: Option<thread::JoinHandle<()>>,
    stderr: Option<Vec<u8>>,
    output_closed: bool,
}

impl SupervisorEventOwner {
    fn accept_control(&mut self) -> Result<Box<dyn transport::Stream>> {
        match self.receiver.recv_timeout(CONTROL_TIMEOUT) {
            Ok(SupervisorStartupEvent::Connected(stream)) => {
                self.join_control_thread()?;
                stream.context("accept preflight supervisor control connection")
            }
            Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                self.stderr = Some(stderr.context("read early preflight supervisor stderr")?);
                self.fail("preflight supervisor exited before READY", "stderr closed")
            }
            Ok(SupervisorStartupEvent::ProductLine(_)) => self.fail(
                "preflight supervisor protocol failed before READY",
                "product output arrived before ARM",
            ),
            Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                result.context("read early preflight product output")?;
                self.output_closed = true;
                self.fail("preflight supervisor exited before READY", "product output closed")
            }
            Err(error) => {
                unblock_control_listener(&self.control_path);
                self.fail("preflight supervisor did not connect", error)
            }
        }
    }

    fn product_line(&mut self, description: &str) -> Result<Vec<u8>> {
        match self.receiver.recv_timeout(CONTROL_TIMEOUT) {
            Ok(SupervisorStartupEvent::ProductLine(line)) => {
                line.with_context(|| format!("read {description}"))
            }
            Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                self.stderr = Some(stderr.context("read preflight supervisor stderr")?);
                self.fail(
                    format!("preflight supervisor exited before {description}"),
                    "stderr closed",
                )
            }
            Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                result.with_context(|| format!("read product output before {description}"))?;
                self.output_closed = true;
                self.fail(format!("preflight product output closed before {description}"), "EOF")
            }
            Ok(SupervisorStartupEvent::Connected(_)) => self.fail(
                format!("preflight supervisor protocol failed before {description}"),
                "a second control connection arrived",
            ),
            Err(error) => self.fail(format!("preflight {description} deadline expired"), error),
        }
    }

    fn release_product(&mut self, description: &str) -> Result<()> {
        self.input.write_all(b"X").with_context(|| description.to_string())?;
        self.input.flush().with_context(|| description.to_string())
    }

    fn finish(&mut self) -> Result<(ExitStatus, Vec<u8>, bool)> {
        let status = match self.child.wait_timeout(CONTROL_TIMEOUT)? {
            Some(status) => status,
            None => {
                return self.fail("preflight supervisor exceeded its deadline", "process timeout");
            }
        };
        let deadline = Instant::now()
            .checked_add(CONTROL_TIMEOUT)
            .context("preflight completion deadline overflow")?;
        while self.stderr.is_none() || !self.output_closed {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.receiver.recv_timeout(remaining) {
                Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                    self.stderr = Some(stderr.context("read preflight supervisor stderr")?);
                }
                Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                    result.context("read preflight product output")?;
                    self.output_closed = true;
                }
                Ok(SupervisorStartupEvent::ProductLine(_)) => {
                    return self.fail(
                        "preflight product emitted an unexpected event",
                        "extra product output line",
                    );
                }
                Ok(SupervisorStartupEvent::Connected(_)) => {
                    return self.fail(
                        "preflight supervisor protocol failed during cleanup",
                        "a second control connection arrived",
                    );
                }
                Err(error) => {
                    return self.fail("preflight process-tree cleanup deadline expired", error);
                }
            }
        }
        self.join_event_threads()?;
        Ok((status, self.stderr.take().unwrap_or_default(), self.output_closed))
    }

    fn abort<T>(&mut self, error: anyhow::Error) -> Result<T> {
        self.fail("preflight supervisor operation failed", format!("{error:#}"))
    }

    fn fail<T>(
        &mut self,
        description: impl std::fmt::Display,
        cause: impl std::fmt::Display,
    ) -> Result<T> {
        let _ = self.input.write_all(b"XX");
        let _ = self.input.flush();
        let status = match self.child.try_wait() {
            Ok(Some(status)) => Some(status),
            Ok(None) => {
                let _ = self.child.kill();
                self.child.wait().ok()
            }
            Err(_) => None,
        };
        unblock_control_listener(&self.control_path);
        let deadline = Instant::now().checked_add(CONTROL_TIMEOUT);
        while (self.stderr.is_none() || !self.output_closed)
            && deadline.is_some_and(|deadline| Instant::now() < deadline)
        {
            let remaining = deadline
                .map(|deadline| deadline.saturating_duration_since(Instant::now()))
                .unwrap_or_default();
            match self.receiver.recv_timeout(remaining) {
                Ok(SupervisorStartupEvent::StderrClosed(Ok(stderr))) => self.stderr = Some(stderr),
                Ok(SupervisorStartupEvent::ProductOutputClosed(Ok(()))) => {
                    self.output_closed = true;
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        let _ = self.join_control_thread();
        if self.output_closed
            && let Some(thread) = self.output_thread.take()
        {
            let _ = thread.join();
        }
        if self.stderr.is_some()
            && let Some(thread) = self.stderr_thread.take()
        {
            let _ = thread.join();
        }
        let status = status.map_or_else(|| "unknown".into(), |status| status.to_string());
        let stderr = self.stderr.as_deref().unwrap_or_default();
        Err(anyhow::anyhow!(
            "{description}: {cause}; supervisor exit {status}; stderr: {}",
            String::from_utf8_lossy(stderr)
        ))
    }

    fn join_control_thread(&mut self) -> Result<()> {
        if let Some(thread) = self.control_thread.take() {
            thread.join().map_err(|_| anyhow::anyhow!("control accept thread panicked"))?;
        }
        Ok(())
    }

    fn join_event_threads(&mut self) -> Result<()> {
        self.join_control_thread()?;
        self.output_thread
            .take()
            .context("preflight product-output thread owner is missing")?
            .join()
            .map_err(|_| anyhow::anyhow!("product-output thread panicked"))?;
        self.stderr_thread
            .take()
            .context("preflight supervisor-stderr thread owner is missing")?
            .join()
            .map_err(|_| anyhow::anyhow!("supervisor-stderr thread panicked"))?;
        Ok(())
    }
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
    let timing = TimingPage::create(root.join("timing.page"))?;
    let control = transport::listen(&control_path)?;
    let (startup_sender, startup_receiver) = mpsc::channel();
    let control_sender = startup_sender.clone();
    let control_thread = thread::spawn(move || {
        let _ = control_sender.send(SupervisorStartupEvent::Connected(control.accept()));
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
        &network_address.to_string(),
        &network_address.ip().to_string(),
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
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command.spawn().context("spawn preflight supervisor")?;
    let Some(supervisor_input) = child.stdin.take() else {
        let _ = child.kill();
        let _ = child.wait();
        unblock_control_listener(&control_path);
        let _ = control_thread.join();
        bail!("capture preflight supervisor stdin");
    };
    let Some(supervisor_output) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        unblock_control_listener(&control_path);
        let _ = control_thread.join();
        bail!("capture preflight supervisor stdout");
    };
    let Some(supervisor_stderr) = child.stderr.take() else {
        let _ = child.kill();
        let _ = child.wait();
        unblock_control_listener(&control_path);
        let _ = control_thread.join();
        bail!("capture preflight supervisor stderr");
    };
    let output_sender = startup_sender.clone();
    let output_thread = thread::spawn(move || {
        read_product_events(supervisor_output, &output_sender);
    });
    let stderr_thread = thread::spawn(move || {
        let stderr = read_bounded_tail(supervisor_stderr, MAX_SUPERVISOR_STDERR_BYTES);
        let _ = startup_sender.send(SupervisorStartupEvent::StderrClosed(stderr));
    });
    let mut events = SupervisorEventOwner {
        child,
        input: supervisor_input,
        receiver: startup_receiver,
        control_path: control_path.clone(),
        control_thread: Some(control_thread),
        output_thread: Some(output_thread),
        stderr_thread: Some(stderr_thread),
        stderr: None,
        output_closed: false,
    };
    let protocol_result = (|| -> Result<_> {
        let mut supervisor_stream = events.accept_control()?;
        supervisor_stream.set_read_timeout(Some(CONTROL_TIMEOUT))?;
        supervisor_stream.set_write_timeout(Some(CONTROL_TIMEOUT))?;
        let ready = read_control_line(&mut supervisor_stream)?;
        if ready != ready_line(&nonce).trim_end() {
            bail!("preflight READY identity mismatch");
        }
        write_control_line(&mut supervisor_stream, &arm_line(&nonce))?;
        supervisor_stream.shutdown(std::net::Shutdown::Both)?;

        let inbound_probe: InboundProbeEvidence =
            serde_json::from_slice(&events.product_line("inbound-network probe evidence")?)
                .context("parse inbound-network probe evidence")?;
        let inbound_network_denied = match inbound_probe.bound_address {
            None => true,
            Some(address) => TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_err(),
        };
        events.release_product("release inbound-network probe")?;

        let child_evidence: ChildProbeEvidence =
            serde_json::from_slice(&events.product_line("descendant probe evidence")?)
                .context("parse preflight descendant evidence")?;
        let (status, supervisor_stderr, contained) = events.finish()?;
        Ok((status, supervisor_stderr, contained, inbound_network_denied, child_evidence))
    })();
    let (status, supervisor_stderr, contained, inbound_network_denied, child_evidence) =
        match protocol_result {
            Ok(result) => result,
            Err(error) => return events.abort(error),
        };
    let event_ns = monotonic_ns()?;
    let timing_result = timing.measured_duration_ns(event_ns);

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
        bail!(
            "sandbox preflight invariant failed; see {}; supervisor stderr: {}",
            output.display(),
            String::from_utf8_lossy(&supervisor_stderr)
        );
    }
    drop(timing);
    fs::remove_dir_all(&root).context("remove successful sandbox preflight root")?;
    fs::remove_file(&adjacent).context("remove successful parent sentinel")?;
    fs::remove_file(&child_adjacent).context("remove successful descendant sentinel")?;
    Ok(())
}

fn run_probe(values: &[String]) -> Result<()> {
    if values.len() != 6 {
        bail!("probe requires write, network, and result paths");
    }
    let inside = PathBuf::from(&values[0]);
    let adjacent = PathBuf::from(&values[1]);
    let child_adjacent = PathBuf::from(&values[2]);
    let network_address = values[3].parse::<SocketAddr>()?;
    let inbound_ip = values[4].parse::<std::net::IpAddr>()?;
    let result_path = PathBuf::from(&values[5]);
    fs::write(&inside, b"inside")?;
    let adjacent_denied = fs::write(&adjacent, b"changed").is_err();
    let network_denied =
        TcpStream::connect_timeout(&network_address, Duration::from_secs(2)).is_err();
    let inbound_listener = match TcpListener::bind(SocketAddr::new(inbound_ip, 0)) {
        Ok(listener) => Some(listener),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::PermissionDenied | io::ErrorKind::AddrNotAvailable
            ) =>
        {
            None
        }
        Err(error) => return Err(error).context("run contained inbound-network bind probe"),
    };
    let inbound_evidence = InboundProbeEvidence {
        bound_address: inbound_listener.as_ref().map(TcpListener::local_addr).transpose()?,
    };
    let stdout = io::stdout();
    let mut controller_output = stdout.lock();
    serde_json::to_writer(&mut controller_output, &inbound_evidence)?;
    controller_output.write_all(b"\n")?;
    controller_output.flush()?;
    let stdin = io::stdin();
    let mut controller_input = stdin.lock();
    let mut inbound_release = [0_u8; 1];
    controller_input
        .read_exact(&mut inbound_release)
        .context("read trusted inbound-network probe release")?;
    drop(inbound_listener);
    let platform = product_platform_proofs()?;
    // The proc magic link reopens this exact running image without resolving its unmounted host
    // source path. Other platforms use the current executable path directly.
    #[cfg(target_os = "linux")]
    let current = PathBuf::from("/proc/self/exe");
    #[cfg(not(target_os = "linux"))]
    let current = env::current_exe().context("resolve contained preflight executable")?;
    let mut child = Command::new(current);
    child
        .arg("--probe-child")
        .arg(child_adjacent)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::piped());
    detach(&mut child);
    let mut child = child.spawn().context("spawn contained preflight descendant")?;
    let mut child_stderr = child.stderr.take().context("capture descendant evidence")?;
    let (ready_sender, ready_receiver) = mpsc::channel();
    let ready_thread = thread::spawn(move || {
        let result = read_bounded_line(&mut child_stderr, MAX_PRODUCT_EVENT_BYTES)
            .and_then(|line| line.ok_or_else(|| io::Error::other("descendant evidence was empty")));
        let _ = ready_sender.send(result);
    });
    let child_line = match ready_receiver.recv_timeout(CONTROL_TIMEOUT) {
        Ok(Ok(line)) => line,
        Ok(Err(error)) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = ready_thread.join();
            return Err(error).context("read sandbox descendant readiness");
        }
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = ready_thread.join();
            return Err(error).context("sandbox descendant readiness deadline expired");
        }
    };
    ready_thread.join().map_err(|_| anyhow::anyhow!("descendant readiness thread panicked"))?;
    let child_evidence: ChildProbeEvidence =
        serde_json::from_slice(&child_line).context("parse contained descendant evidence")?;
    serde_json::to_writer(&mut controller_output, &child_evidence)?;
    controller_output.write_all(b"\n")?;
    controller_output.flush()?;
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
    if values.len() != 1 {
        bail!("probe child requires an adjacent path");
    }
    let denied = fs::write(&values[0], b"changed").is_err();
    let evidence =
        ChildProbeEvidence { adjacent_write_denied: denied, windows_in_job: child_in_job()? };
    let stderr = io::stderr();
    let mut parent = stderr.lock();
    serde_json::to_writer(&mut parent, &evidence)?;
    parent.write_all(b"\n")?;
    parent.flush()?;
    let mut release = [0_u8; 1];
    io::stdin().read_exact(&mut release)?;
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
        GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, SE_PRIVILEGE_ENABLED,
        TOKEN_MANDATORY_LABEL, TOKEN_PRIVILEGES, TOKEN_QUERY, TokenIntegrityLevel, TokenPrivileges,
    };
    use windows_sys::Win32::System::Registry::{
        HKEY_CURRENT_USER, KEY_WRITE, RegCloseKey, RegOpenKeyExW,
    };
    use windows_sys::Win32::System::SystemServices::SECURITY_MANDATORY_LOW_RID;
    use windows_sys::Win32::System::Threading::{
        CREATE_BREAKAWAY_FROM_JOB, GetCurrentProcess, OpenProcessToken,
    };

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
            return Err(io::Error::last_os_error()).context("size token information");
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
            return Err(io::Error::last_os_error()).context("read token information");
        }
        Ok(storage)
    }

    let mut token = null_mut();
    // SAFETY: token points to writable handle storage.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(io::Error::last_os_error()).context("open preflight product token");
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
    let error = (result == 0).then(io::Error::last_os_error);
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
                return Err(io::Error::last_os_error());
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

fn read_bounded_tail(mut reader: impl Read, limit: usize) -> io::Result<Vec<u8>> {
    let mut tail = Vec::new();
    let mut chunk = [0_u8; 8 * 1024];
    loop {
        let count = reader.read(&mut chunk)?;
        if count == 0 {
            return Ok(tail);
        }
        if count >= limit {
            tail.clear();
            tail.extend_from_slice(&chunk[count - limit..count]);
            continue;
        }
        let excess = tail.len().saturating_add(count).saturating_sub(limit);
        if excess > 0 {
            tail.drain(..excess);
        }
        tail.extend_from_slice(&chunk[..count]);
    }
}

fn read_product_events(mut reader: impl Read, sender: &mpsc::Sender<SupervisorStartupEvent>) {
    loop {
        match read_bounded_line(&mut reader, MAX_PRODUCT_EVENT_BYTES) {
            Ok(Some(line)) => {
                if sender.send(SupervisorStartupEvent::ProductLine(Ok(line))).is_err() {
                    return;
                }
            }
            Ok(None) => {
                let _ = sender.send(SupervisorStartupEvent::ProductOutputClosed(Ok(())));
                return;
            }
            Err(error) => {
                let _ = sender.send(SupervisorStartupEvent::ProductOutputClosed(Err(error)));
                return;
            }
        }
    }
}

fn read_bounded_line(reader: &mut impl Read, limit: usize) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let mut byte = [0_u8; 1];
    loop {
        match reader.read(&mut byte)? {
            0 if line.is_empty() => return Ok(None),
            0 => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "partial product event")),
            _ if byte[0] == b'\n' => return Ok(Some(line)),
            _ if line.len() == limit => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "product event exceeded its byte limit",
                ));
            }
            _ => line.push(byte[0]),
        }
    }
}

fn unblock_control_listener(path: &Path) {
    if let Ok(stream) = transport::connect(path) {
        let _ = stream.shutdown(std::net::Shutdown::Both);
    }
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
