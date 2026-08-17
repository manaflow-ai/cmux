#[cfg(windows)]
mod startup_benchmark_appcontainer;
mod startup_benchmark_protocol;

use std::env;
#[cfg(windows)]
use std::error::Error;
#[cfg(windows)]
use std::fmt::{self, Display, Formatter};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use cmux_startup_bootstrap::BootstrapLaunchEvidence;
use cmux_tui_core::platform::transport;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use startup_benchmark_protocol::{
    BOOTSTRAP_FAILURE_SCHEMA_VERSION, BootstrapControllerFailureObservation,
    BootstrapHangDiagnosticReport, CONTROL_TIMEOUT, MAX_BOOTSTRAP_HANG_DUMP_BYTES,
    MAX_BOOTSTRAP_HANG_REPORT_BYTES, MAX_PRODUCT_FAILURE_STDOUT_TAIL_BYTES, STARTUP_LINE_TIMEOUT,
    SupervisorStartupLine, TimingPage, arm_line, bootstrap_failure_hang_artifact, monotonic_ns,
    parse_supervisor_startup_line, read_control_line, validate_bootstrap_failure_records,
    write_control_line,
};
#[cfg(windows)]
use startup_benchmark_protocol::{
    PRODUCT_STARTED_TIMEOUT, parse_product_exit_line, parse_product_started_line,
    read_product_started_control_line,
};
use wait_timeout::ChildExt;

const MAX_SUPERVISOR_STDERR_BYTES: usize = 64 * 1024;
const MAX_PRODUCT_EVENT_BYTES: usize = 64 * 1024;
const MAX_BOOTSTRAP_CHECKPOINT_BYTES: u64 = 64 * 1024;

#[cfg(windows)]
const WINDOWS_CLAIM_UNVERIFIED_EXIT: i32 = 78;
#[cfg(windows)]
const WINDOWS_CLAIM_UNVERIFIED_REASON: &str =
    "trusted Windows preflight could not observe all required native security signals";

#[cfg(windows)]
#[derive(Debug)]
struct WindowsClaimUnavailable;

#[cfg(windows)]
impl Display for WindowsClaimUnavailable {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(WINDOWS_CLAIM_UNVERIFIED_REASON)
    }
}

#[cfg(windows)]
impl Error for WindowsClaimUnavailable {}

#[derive(Clone, Serialize)]
#[cfg_attr(test, derive(Default))]
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
    windows_caller_se_impersonate_enabled: Option<bool>,
    windows_standard_handles_valid: Option<bool>,
    windows_explicit_handle_list: Option<bool>,
    windows_bootstrap_sha256: Option<String>,
    windows_bootstrap_config_nonce: Option<String>,
    windows_bootstrap_config_consumed: Option<bool>,
    windows_bootstrap_resume_previous_count: Option<u32>,
    windows_bootstrap_ready_elapsed_ms: Option<u64>,
    windows_bootstrap_exact_job: Option<bool>,
    windows_bootstrap_trusted_path_write_denied: Option<bool>,
    windows_bootstrap_self_write_denied: Option<bool>,
    windows_restricting_sid: Option<String>,
    windows_broker_authentication_id: Option<String>,
    windows_restricted_authentication_id: Option<String>,
    windows_product_authentication_id: Option<String>,
    windows_restricted_authentication_matches_broker: Option<bool>,
    windows_product_authentication_matches_broker: Option<bool>,
    windows_se_increase_quota_present: Option<bool>,
    windows_se_increase_quota_enabled: Option<bool>,
    windows_create_process_as_user_succeeded: Option<bool>,
    windows_restricted_token_write_restricted: Option<bool>,
    windows_restricted_token_restricting_sid_match: Option<bool>,
    windows_restricted_token_low_integrity: Option<bool>,
    windows_restricted_token_no_enabled_privileges: Option<bool>,
    windows_product_write_restricted: Option<bool>,
    windows_product_restricting_sid_match: Option<bool>,
    windows_product_low_integrity: Option<bool>,
    windows_product_no_enabled_privileges: Option<bool>,
    windows_product_exact_job: Option<bool>,
    windows_product_resume_previous_count: Option<u32>,
    windows_product_process_id: Option<u32>,
    windows_product_primary_thread_id: Option<u32>,
    windows_private_desktop: Option<String>,
    windows_private_window_station_created: Option<bool>,
    windows_private_desktop_created: Option<bool>,
    windows_private_desktop_broker_assigned: Option<bool>,
    windows_private_desktop_product_assigned: Option<bool>,
    windows_private_desktop_closed_after_job_empty: Option<bool>,
    supervisor_ready: bool,
    timing_records: u64,
    supervisor_sha256: String,
}

#[cfg(windows)]
#[derive(Serialize)]
struct RelayedProductFailureEvidence<'a> {
    schema_version: u32,
    record_type: &'static str,
    nonce: &'a str,
    bootstrap_evidence: &'a BootstrapLaunchEvidence,
    controller_observation: &'a BootstrapControllerFailureObservation,
    native_exit_code: Option<u32>,
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

#[derive(Debug, PartialEq)]
struct WindowsPreflightObservations {
    grandchild_in_job: Option<bool>,
    active_process_zero: Option<bool>,
    caller_se_impersonate_enabled: Option<bool>,
    standard_handles_valid: Option<bool>,
    explicit_handle_list: Option<bool>,
}

fn windows_preflight_observations(grandchild_in_job: Option<bool>) -> WindowsPreflightObservations {
    // Keep only observations produced by a probe. Do not infer process, privilege, or handle
    // state from supervisor exit status or from the fact that this code runs on Windows.
    WindowsPreflightObservations {
        grandchild_in_job,
        active_process_zero: None,
        caller_se_impersonate_enabled: None,
        standard_handles_valid: None,
        explicit_handle_list: None,
    }
}

#[derive(Debug, PartialEq, Eq)]
enum WindowsPreflightObservationState {
    Verified,
    Unverified,
    Failed,
}

fn classify_windows_preflight_observations(
    observations: &WindowsPreflightObservations,
) -> WindowsPreflightObservationState {
    let values = [
        observations.grandchild_in_job,
        observations.active_process_zero,
        observations.caller_se_impersonate_enabled,
        observations.standard_handles_valid,
        observations.explicit_handle_list,
    ];
    if values.iter().any(Option::is_none) {
        if values.iter().all(|value| *value != Some(false)) {
            WindowsPreflightObservationState::Unverified
        } else {
            WindowsPreflightObservationState::Failed
        }
    } else if values.iter().all(|value| *value == Some(true)) {
        WindowsPreflightObservationState::Verified
    } else {
        WindowsPreflightObservationState::Failed
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct InboundProbeEvidence {
    bound_address: Option<SocketAddr>,
}

enum SupervisorStartupEvent {
    Connected(io::Result<Box<dyn transport::Stream>>),
    ProductOutput(Vec<u8>),
    ProductOutputClosed(io::Result<()>),
    StderrClosed(io::Result<Vec<u8>>),
    #[cfg(windows)]
    PostArmControl(Result<String>),
}

enum ProductAwaitOutcome {
    Line(Vec<u8>),
    #[cfg(windows)]
    StartupFailure {
        checkpoint_name: Option<String>,
    },
    #[cfg(windows)]
    NativeExit {
        code: u32,
    },
}

enum PreflightProtocolOutcome {
    Success {
        status: ExitStatus,
        supervisor_stderr: Vec<u8>,
        contained: bool,
        inbound_network_denied: bool,
        child_evidence: ChildProbeEvidence,
    },
    StartupFailure {
        checkpoint_name: Option<String>,
        public_deadline: Instant,
    },
}

struct SupervisorEventOwner {
    child: Child,
    input: ChildStdin,
    receiver: mpsc::Receiver<SupervisorStartupEvent>,
    control_path: PathBuf,
    control_thread: Option<thread::JoinHandle<()>>,
    output_thread: Option<thread::JoinHandle<()>>,
    stderr_thread: Option<thread::JoinHandle<()>>,
    #[cfg(windows)]
    post_arm_control_thread: Option<thread::JoinHandle<()>>,
    #[cfg(windows)]
    sender: mpsc::Sender<SupervisorStartupEvent>,
    stderr: Option<Vec<u8>>,
    output_closed: bool,
    product_buffer: Vec<u8>,
    product_tail: Vec<u8>,
    complete_product_lines: u64,
    product_output_error: Option<String>,
    native_exit_code: Option<u32>,
    #[cfg(windows)]
    post_arm_nonce: Option<String>,
}

impl SupervisorEventOwner {
    fn accept_control(&mut self, deadline: Instant) -> Result<Box<dyn transport::Stream>> {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("preflight supervisor control accept deadline expired")?;
        match self.receiver.recv_timeout(remaining) {
            Ok(SupervisorStartupEvent::Connected(stream)) => {
                self.join_control_thread()?;
                stream.context("accept preflight supervisor control connection")
            }
            Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                self.stderr = Some(stderr.context("read early preflight supervisor stderr")?);
                self.fail("preflight supervisor exited before READY", "stderr closed")
            }
            Ok(SupervisorStartupEvent::ProductOutput(_)) => self.fail(
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
            #[cfg(windows)]
            Ok(SupervisorStartupEvent::PostArmControl(_)) => self.fail(
                "preflight supervisor protocol failed before READY",
                "post-ARM control arrived before ARM",
            ),
        }
    }

    #[cfg(windows)]
    fn watch_post_arm_control(
        &mut self,
        mut stream: Box<dyn transport::Stream>,
        deadline: Instant,
        nonce: &str,
    ) -> Result<()> {
        if self.post_arm_control_thread.is_some() {
            bail!("preflight post-ARM control reader already exists");
        }
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("preflight post-ARM control deadline expired")?;
        stream.set_read_timeout(Some(remaining))?;
        self.post_arm_nonce = Some(nonce.into());
        let sender = self.sender.clone();
        self.post_arm_control_thread = Some(thread::spawn(move || {
            let result = read_control_line(&mut stream);
            let _ = sender.send(SupervisorStartupEvent::PostArmControl(result));
        }));
        Ok(())
    }

    fn product_line(&mut self, description: &str) -> Result<Vec<u8>> {
        let deadline = Instant::now()
            .checked_add(CONTROL_TIMEOUT)
            .context("preflight product-event deadline overflow")?;
        match self.product_line_until(description, deadline, None)? {
            ProductAwaitOutcome::Line(line) => Ok(line),
            #[cfg(windows)]
            ProductAwaitOutcome::StartupFailure { .. } => {
                self.fail(format!("preflight supervisor failed before {description}"), "FAILURE")
            }
            #[cfg(windows)]
            ProductAwaitOutcome::NativeExit { code } => self.fail(
                format!("preflight product exited before {description}"),
                format!("native exit {code}"),
            ),
        }
    }

    fn product_line_until(
        &mut self,
        description: &str,
        deadline: Instant,
        _nonce: Option<&str>,
    ) -> Result<ProductAwaitOutcome> {
        loop {
            if let Some(line) = self.take_product_line()? {
                return Ok(ProductAwaitOutcome::Line(line));
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return self.fail(format!("preflight {description} deadline expired"), "timeout");
            }
            match self.receiver.recv_timeout(remaining) {
                Ok(SupervisorStartupEvent::ProductOutput(bytes)) => {
                    self.record_product_output(&bytes)?;
                }
                Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                    self.stderr = Some(stderr.context("read preflight supervisor stderr")?);
                }
                Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                    self.record_product_output_closed(result);
                }
                #[cfg(windows)]
                Ok(SupervisorStartupEvent::PostArmControl(line)) => {
                    let nonce = _nonce.context("post-ARM control arrived without a nonce owner")?;
                    let line = line.context("read preflight post-ARM control")?;
                    if let Ok(SupervisorStartupLine::Failure { checkpoint_name }) =
                        parse_supervisor_startup_line(&line, nonce)
                    {
                        return Ok(ProductAwaitOutcome::StartupFailure { checkpoint_name });
                    }
                    let code = parse_product_exit_line(&line, nonce)
                        .context("validate preflight post-ARM control line")?;
                    self.native_exit_code = Some(code);
                    return Ok(ProductAwaitOutcome::NativeExit { code });
                }
                Ok(SupervisorStartupEvent::Connected(_)) => {
                    return self.fail(
                        format!("preflight supervisor protocol failed before {description}"),
                        "a second control connection arrived",
                    );
                }
                Err(error) => {
                    return self.fail(format!("preflight {description} deadline expired"), error);
                }
            }
        }
    }

    fn record_product_output(&mut self, bytes: &[u8]) -> Result<()> {
        if bytes.len() >= MAX_PRODUCT_FAILURE_STDOUT_TAIL_BYTES {
            self.product_tail.clear();
            self.product_tail
                .extend_from_slice(&bytes[bytes.len() - MAX_PRODUCT_FAILURE_STDOUT_TAIL_BYTES..]);
        } else {
            let excess = self
                .product_tail
                .len()
                .saturating_add(bytes.len())
                .saturating_sub(MAX_PRODUCT_FAILURE_STDOUT_TAIL_BYTES);
            if excess > 0 {
                self.product_tail.drain(..excess);
            }
            self.product_tail.extend_from_slice(bytes);
        }
        self.product_buffer.extend_from_slice(bytes);
        if self
            .product_buffer
            .split(|byte| *byte == b'\n')
            .any(|line| line.len() > MAX_PRODUCT_EVENT_BYTES)
        {
            bail!("product event exceeded its byte limit");
        }
        Ok(())
    }

    fn take_product_line(&mut self) -> Result<Option<Vec<u8>>> {
        let Some(newline) = self.product_buffer.iter().position(|byte| *byte == b'\n') else {
            return Ok(None);
        };
        if newline > MAX_PRODUCT_EVENT_BYTES {
            bail!("product event exceeded its byte limit");
        }
        let mut line = self.product_buffer.drain(..=newline).collect::<Vec<_>>();
        line.pop();
        self.complete_product_lines = self
            .complete_product_lines
            .checked_add(1)
            .context("product stdout line count overflow")?;
        Ok(Some(line))
    }

    fn record_product_output_closed(&mut self, result: io::Result<()>) {
        self.output_closed = true;
        self.product_output_error = match result {
            Ok(()) if self.product_buffer.is_empty() => None,
            Ok(()) => Some("product stdout closed with a partial line".into()),
            Err(error) => Some(bounded_text(&error.to_string(), 2_048)),
        };
    }

    fn controller_failure_observation(&self, nonce: &str) -> BootstrapControllerFailureObservation {
        BootstrapControllerFailureObservation {
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
            record_type: "controller-observation".into(),
            nonce: nonce.into(),
            raw_stdout_tail_hex: self
                .product_tail
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
            raw_stdout_tail_bytes: u64::try_from(self.product_tail.len()).unwrap_or(u64::MAX),
            complete_stdout_lines: self.complete_product_lines,
            stdout_closed: self.output_closed,
            stdout_error: self.product_output_error.clone(),
        }
    }

    fn release_product(&mut self, description: &str) -> Result<()> {
        self.input.write_all(b"X").with_context(|| description.to_string())?;
        self.input.flush().with_context(|| description.to_string())
    }

    fn finish(&mut self) -> Result<(ExitStatus, Vec<u8>, bool)> {
        let deadline = Instant::now()
            .checked_add(CONTROL_TIMEOUT)
            .context("preflight completion deadline overflow")?;
        self.finish_until(deadline)
    }

    fn finish_until(&mut self, deadline: Instant) -> Result<(ExitStatus, Vec<u8>, bool)> {
        let process_timeout = deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("preflight supervisor cleanup deadline expired")?;
        let status = match self.child.wait_timeout(process_timeout)? {
            Some(status) => status,
            None => {
                return self.fail("preflight supervisor exceeded its deadline", "process timeout");
            }
        };
        while self.stderr.is_none()
            || !self.output_closed
            || (cfg!(windows) && self.native_exit_code.is_none())
        {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match self.receiver.recv_timeout(remaining) {
                Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                    self.stderr = Some(stderr.context("read preflight supervisor stderr")?);
                }
                Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                    self.record_product_output_closed(result);
                }
                Ok(SupervisorStartupEvent::ProductOutput(bytes)) => {
                    self.record_product_output(&bytes)?;
                    if self.take_product_line()?.is_some() {
                        return self.fail(
                            "preflight product emitted an unexpected event",
                            "extra product output line",
                        );
                    }
                }
                Ok(SupervisorStartupEvent::Connected(_)) => {
                    return self.fail(
                        "preflight supervisor protocol failed during cleanup",
                        "a second control connection arrived",
                    );
                }
                #[cfg(windows)]
                Ok(SupervisorStartupEvent::PostArmControl(line)) => {
                    let line = line.context("read preflight completion control")?;
                    let nonce = self
                        .post_arm_nonce
                        .as_deref()
                        .context("preflight completion control has no nonce owner")?;
                    if parse_supervisor_startup_line(&line, nonce).is_ok() {
                        return self.fail(
                            "preflight supervisor failed during completion",
                            "unexpected FAILURE after product evidence",
                        );
                    }
                    self.native_exit_code = Some(
                        parse_product_exit_line(&line, nonce)
                            .context("validate preflight completion product exit")?,
                    );
                }
                Err(error) => {
                    return self.fail("preflight process-tree cleanup deadline expired", error);
                }
            }
        }
        if !self.product_buffer.is_empty() {
            let partial = String::from_utf8_lossy(&self.product_buffer).into_owned();
            return self.fail("preflight product output closed with a partial event", partial);
        }
        self.join_event_threads()?;
        Ok((status, self.stderr.take().unwrap_or_default(), self.output_closed))
    }

    fn finish_failure_until(&mut self, deadline: Instant) -> Result<(ExitStatus, Vec<u8>, bool)> {
        let process_timeout = deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("preflight supervisor failure-cleanup deadline expired")?;
        let status = match self.child.wait_timeout(process_timeout)? {
            Some(status) => status,
            None => {
                return self.fail(
                    "preflight supervisor exceeded its failure-cleanup deadline",
                    "process timeout",
                );
            }
        };
        while self.stderr.is_none() || !self.output_closed {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return self.fail("preflight failure evidence deadline expired", "event timeout");
            }
            match self.receiver.recv_timeout(remaining) {
                Ok(SupervisorStartupEvent::ProductOutput(bytes)) => {
                    self.record_product_output(&bytes)?;
                    while self.take_product_line()?.is_some() {}
                }
                Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                    self.record_product_output_closed(result);
                }
                Ok(SupervisorStartupEvent::StderrClosed(stderr)) => {
                    self.stderr = Some(stderr.context("read failed preflight supervisor stderr")?);
                }
                #[cfg(windows)]
                Ok(SupervisorStartupEvent::PostArmControl(_)) => {
                    return self.fail(
                        "preflight supervisor sent duplicate post-ARM status",
                        "duplicate control line",
                    );
                }
                Ok(SupervisorStartupEvent::Connected(_)) => {
                    return self.fail(
                        "preflight supervisor protocol failed during failure cleanup",
                        "a second control connection arrived",
                    );
                }
                Err(error) => {
                    return self.fail("preflight failure evidence deadline expired", error);
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
                Ok(SupervisorStartupEvent::ProductOutput(bytes)) => {
                    let _ = self.record_product_output(&bytes);
                }
                Ok(SupervisorStartupEvent::ProductOutputClosed(result)) => {
                    self.record_product_output_closed(result);
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        let _ = self.join_control_thread();
        #[cfg(windows)]
        if let Some(thread) = self.post_arm_control_thread.take() {
            let _ = thread.join();
        }
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
        #[cfg(windows)]
        if let Some(thread) = self.post_arm_control_thread.take() {
            thread.join().map_err(|_| anyhow::anyhow!("post-ARM control thread panicked"))?;
        }
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
        #[cfg(windows)]
        if error.downcast_ref::<WindowsClaimUnavailable>().is_some() {
            eprintln!("cmux-tui startup sandbox preflight: {error:#}");
            std::process::exit(WINDOWS_CLAIM_UNVERIFIED_EXIT);
        }
        eprintln!("cmux-tui startup sandbox preflight: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let values = env::args().skip(1).collect::<Vec<_>>();
    match values.first().map(String::as_str) {
        #[cfg(windows)]
        Some("--appcontainer-feasibility") => {
            startup_benchmark_appcontainer::run_controller(&values[1..])
        }
        #[cfg(windows)]
        Some("--appcontainer-broker") => startup_benchmark_appcontainer::run_broker(&values[1..]),
        #[cfg(windows)]
        Some("--appcontainer-probe") => startup_benchmark_appcontainer::run_probe(&values[1..]),
        #[cfg(windows)]
        Some("--appcontainer-probe-child") => {
            startup_benchmark_appcontainer::run_probe_child(&values[1..])
        }
        Some("--probe") => run_probe(&values[1..]),
        Some("--probe-child") => run_probe_child(&values[1..]),
        Some("--breakaway-probe") => Ok(()),
        _ => run_controller(&values),
    }
}

fn read_preflight_startup_line(
    stream: &mut Box<dyn transport::Stream>,
    deadline: Instant,
    nonce: &str,
) -> Result<SupervisorStartupLine> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .context("preflight public startup-line deadline expired")?;
    stream.set_read_timeout(Some(remaining))?;
    parse_supervisor_startup_line(&read_control_line(stream)?, nonce)
}

fn copy_bootstrap_failure_checkpoint(
    fixture_root: &Path,
    output: &Path,
    checkpoint_name: Option<&str>,
    expected_nonce: &str,
    controller_observation: Option<&BootstrapControllerFailureObservation>,
) -> Result<Vec<PathBuf>> {
    let checkpoint_name = checkpoint_name
        .context("preflight supervisor failure did not name a bootstrap checkpoint")?;
    let source = fixture_root.join(checkpoint_name);
    if source.parent() != Some(fixture_root) {
        bail!("bootstrap checkpoint escaped the preflight fixture root");
    }
    let metadata = fs::symlink_metadata(&source)
        .with_context(|| format!("inspect bootstrap checkpoint {}", source.display()))?;
    if !metadata.file_type().is_file() || metadata.len() > MAX_BOOTSTRAP_CHECKPOINT_BYTES {
        bail!("bootstrap checkpoint is not one bounded regular file");
    }
    let bytes = fs::read(&source)?;
    validate_bootstrap_failure_records(&bytes, expected_nonce)?;
    let hang_artifact = bootstrap_failure_hang_artifact(&bytes, expected_nonce)?;
    let stem = output
        .file_stem()
        .and_then(|value| value.to_str())
        .context("preflight evidence output has no portable stem")?;
    let destination = output.with_file_name(format!("{stem}-bootstrap-failure.json"));
    let mut file =
        OpenOptions::new().write(true).create_new(true).open(&destination).with_context(|| {
            format!("create copied bootstrap checkpoint {}", destination.display())
        })?;
    file.write_all(&bytes)?;
    if let Some(observation) = controller_observation {
        observation.validate(expected_nonce)?;
        let observation = serde_json::to_vec(observation)?;
        let final_size = bytes
            .len()
            .checked_add(observation.len())
            .and_then(|size| size.checked_add(1))
            .context("copied bootstrap checkpoint size overflow")?;
        if final_size > usize::try_from(MAX_BOOTSTRAP_CHECKPOINT_BYTES)? {
            bail!("copied bootstrap checkpoint exceeded its bound");
        }
        file.write_all(&observation)?;
        file.write_all(b"\n")?;
    }
    file.flush()?;
    drop(file);
    let copied_bytes = fs::read(&destination)?;
    validate_bootstrap_failure_records(&copied_bytes, expected_nonce)?;
    let mut copied = vec![destination];
    if let Some(reference) = hang_artifact {
        reference.validate()?;
        let report_source = fixture_root.join(&reference.report_name);
        let report_bytes = read_identity_bound_artifact(
            &report_source,
            reference.report_bytes,
            MAX_BOOTSTRAP_HANG_REPORT_BYTES,
            &reference.report_sha256,
            "bootstrap hang report",
        )?;
        let report: BootstrapHangDiagnosticReport = serde_json::from_slice(&report_bytes)?;
        report.validate(expected_nonce)?;
        if report.dump_name != reference.dump_name
            || report.dump_sha256 != reference.dump_sha256
            || report.dump_bytes != reference.dump_bytes
        {
            bail!("bootstrap hang report and failure checkpoint name different minidumps");
        }
        let dump_source = fixture_root.join(&reference.dump_name);
        let dump_bytes = read_identity_bound_artifact(
            &dump_source,
            reference.dump_bytes,
            MAX_BOOTSTRAP_HANG_DUMP_BYTES,
            &reference.dump_sha256,
            "bootstrap minidump",
        )?;
        for (suffix, payload) in
            [("bootstrap-hang.json", report_bytes), ("bootstrap-hang.dmp", dump_bytes)]
        {
            let target = output.with_file_name(format!("{stem}-{suffix}"));
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&target)
                .with_context(|| format!("create copied hang artifact {}", target.display()))?;
            file.write_all(&payload)?;
            file.flush()?;
            copied.push(target);
        }
    }
    Ok(copied)
}

#[cfg(windows)]
fn persist_relayed_product_started_evidence(
    output: &Path,
    evidence: &BootstrapLaunchEvidence,
    expected_nonce: &str,
    expected_bootstrap_sha256: &str,
    controller_observation: &BootstrapControllerFailureObservation,
    native_exit_code: Option<u32>,
) -> Result<PathBuf> {
    evidence.validate_started(expected_nonce, expected_bootstrap_sha256)?;
    controller_observation.validate(expected_nonce)?;
    let stem = output.file_stem().and_then(|value| value.to_str()).unwrap_or("preflight");
    let path = output
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(format!("{stem}-product-bootstrap-failure.json"));
    let bytes = serde_json::to_vec_pretty(&RelayedProductFailureEvidence {
        schema_version: 1,
        record_type: "relayed-product-failure",
        nonce: expected_nonce,
        bootstrap_evidence: evidence,
        controller_observation,
        native_exit_code,
    })?;
    if bytes.len() > MAX_BOOTSTRAP_CHECKPOINT_BYTES as usize {
        bail!("relayed product-started evidence exceeded its file bound");
    }
    let mut file =
        OpenOptions::new().write(true).create_new(true).open(&path).with_context(|| {
            format!("create relayed product-started evidence {}", path.display())
        })?;
    file.write_all(&bytes)?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(path)
}

#[cfg(windows)]
fn copy_final_product_lifecycle_evidence(
    fixture_root: &Path,
    output: &Path,
    relayed: &BootstrapLaunchEvidence,
    expected_nonce: &str,
    expected_bootstrap_sha256: &str,
) -> Result<PathBuf> {
    relayed.validate_started(expected_nonce, expected_bootstrap_sha256)?;
    let source =
        fixture_root.join(format!("windows-bootstrap-evidence-{}.json", &expected_nonce[..16]));
    let final_evidence: BootstrapLaunchEvidence =
        read_bounded_json_file(&source, MAX_BOOTSTRAP_CHECKPOINT_BYTES as usize)?;
    final_evidence.validate(expected_nonce, expected_bootstrap_sha256)?;
    let mut expected = relayed.clone();
    expected.private_desktop_closed_after_job_empty = true;
    if final_evidence != expected {
        bail!("final product lifecycle evidence changed outside its cleanup field");
    }
    let stem = output.file_stem().and_then(|value| value.to_str()).unwrap_or("preflight");
    let destination = output.with_file_name(format!("{stem}-product-bootstrap-final.json"));
    write_new_json_file(&destination, &final_evidence)?;
    Ok(destination)
}

#[cfg(windows)]
fn read_bounded_json_file<T: for<'de> Deserialize<'de>>(path: &Path, maximum: usize) -> Result<T> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > maximum as u64 {
        bail!("final lifecycle evidence is not one bounded regular file");
    }
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

#[cfg(windows)]
fn write_new_json_file(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    serde_json::to_writer(&mut file, value)?;
    file.write_all(b"\n")?;
    file.flush()?;
    Ok(())
}

fn read_identity_bound_artifact(
    source: &Path,
    expected_bytes: u64,
    maximum_bytes: u64,
    expected_sha256: &str,
    name: &str,
) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(source)
        .with_context(|| format!("inspect {name} {}", source.display()))?;
    if !metadata.file_type().is_file()
        || metadata.len() != expected_bytes
        || metadata.len() == 0
        || metadata.len() > maximum_bytes
    {
        bail!("{name} is not the expected bounded regular file");
    }
    let bytes = fs::read(source)?;
    let observed = format!("{:x}", Sha256::digest(&bytes));
    if observed != expected_sha256 {
        bail!("{name} SHA-256 mismatch: expected {expected_sha256}, observed {observed}");
    }
    Ok(bytes)
}

fn run_controller(values: &[String]) -> Result<()> {
    let supervisor = required_path(values, "--supervisor")?;
    #[cfg(windows)]
    let windows_bootstrap = required_path(values, "--windows-bootstrap-binary")?;
    #[cfg(windows)]
    let windows_bootstrap_sha256 = required_value(values, "--windows-bootstrap-sha256")?;
    let fixture_parent = required_path(values, "--fixture-parent")?;
    let output = required_path(values, "--output")?;
    let backend = required_value(values, "--backend")?;
    if backend != expected_backend() {
        bail!("preflight backend must be {} on this platform", expected_backend());
    }
    let root = fixture_parent.join(format!("preflight-{}", std::process::id()));
    let adjacent = fixture_parent.join("protected-adjacent");
    let child_adjacent = fixture_parent.join("protected-child-adjacent");
    let cleanup = PreflightCleanupGuard::new(&root, &adjacent, &child_adjacent);
    fs::create_dir(&root).context("create sandbox preflight root")?;
    let inside = root.join("inside-write");
    let probe_result = root.join("probe-result.json");
    fs::write(&adjacent, b"protected").context("stage protected parent sentinel")?;
    fs::write(&child_adjacent, b"protected").context("stage protected descendant sentinel")?;
    make_write_probe_permissive(&adjacent).context("prepare protected parent sentinel")?;
    make_write_probe_permissive(&child_adjacent)
        .context("prepare protected descendant sentinel")?;
    let network_listener = trusted_network_listener()?;
    let network_address = network_listener.local_addr()?;

    let control_path = root.join("control.sock");
    let timing = TimingPage::create(root.join("timing.page"))
        .context("create sandbox preflight timing page")?;
    let control =
        transport::listen(&control_path).context("create sandbox preflight control listener")?;
    let (startup_sender, startup_receiver) = mpsc::channel();
    let control_sender = startup_sender.clone();
    let control_thread = thread::spawn(move || {
        let _ = control_sender.send(SupervisorStartupEvent::Connected(control.accept()));
    });

    let current = env::current_exe().context("resolve preflight product executable")?;
    let supervisor_sha256 = sha256_file(&supervisor, "trusted supervisor")?;
    #[cfg(windows)]
    if sha256_file(&windows_bootstrap, "trusted minimal Windows bootstrap")?
        != windows_bootstrap_sha256
    {
        bail!("minimal Windows bootstrap SHA-256 mismatch before preflight");
    }
    let target_sha256 = sha256_file(&current, "preflight product")?;
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
        "--target-sha256",
        &target_sha256,
        "--supervisor-sha256",
        &supervisor_sha256,
    ]);
    #[cfg(windows)]
    command
        .arg("--windows-bootstrap-binary")
        .arg(&windows_bootstrap)
        .arg("--windows-bootstrap-sha256")
        .arg(&windows_bootstrap_sha256);
    command.args([
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
    #[cfg(windows)]
    let post_arm_sender = startup_sender.clone();
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
        #[cfg(windows)]
        post_arm_control_thread: None,
        #[cfg(windows)]
        sender: post_arm_sender,
        stderr: None,
        output_closed: false,
        product_buffer: Vec::new(),
        product_tail: Vec::new(),
        complete_product_lines: 0,
        product_output_error: None,
        native_exit_code: None,
        #[cfg(windows)]
        post_arm_nonce: None,
    };
    #[cfg(windows)]
    let mut relayed_bootstrap_evidence: Option<BootstrapLaunchEvidence> = None;
    let protocol_result = (|| -> Result<_> {
        let public_deadline = Instant::now()
            .checked_add(STARTUP_LINE_TIMEOUT)
            .context("preflight public startup-line deadline overflow")?;
        let mut supervisor_stream = events.accept_control(public_deadline)?;
        let mut startup =
            read_preflight_startup_line(&mut supervisor_stream, public_deadline, &nonce)?;
        if startup == SupervisorStartupLine::Setup {
            startup = read_preflight_startup_line(&mut supervisor_stream, public_deadline, &nonce)?;
        }
        match startup {
            SupervisorStartupLine::Ready => {}
            SupervisorStartupLine::Failure { checkpoint_name } => {
                return Ok(PreflightProtocolOutcome::StartupFailure {
                    checkpoint_name,
                    public_deadline,
                });
            }
            SupervisorStartupLine::Setup => {
                bail!("preflight supervisor sent duplicate SETUP events")
            }
        }
        let write_timeout = public_deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("preflight ARM deadline expired")?;
        supervisor_stream.set_write_timeout(Some(write_timeout))?;
        write_control_line(&mut supervisor_stream, &arm_line(&nonce))?;
        #[cfg(windows)]
        {
            let product_started_deadline = Instant::now()
                .checked_add(PRODUCT_STARTED_TIMEOUT)
                .context("preflight product-started deadline overflow")?;
            let remaining = product_started_deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero())
                .context("preflight product-started deadline expired")?;
            supervisor_stream.set_read_timeout(Some(remaining))?;
            let line = read_product_started_control_line(&mut supervisor_stream)?;
            match parse_product_started_line(&line, &nonce, Some(&windows_bootstrap_sha256)) {
                Ok(evidence) => relayed_bootstrap_evidence = Some(evidence),
                Err(product_started) => match parse_supervisor_startup_line(&line, &nonce) {
                    Ok(SupervisorStartupLine::Failure { checkpoint_name }) => {
                        return Ok(PreflightProtocolOutcome::StartupFailure {
                            checkpoint_name,
                            public_deadline: product_started_deadline,
                        });
                    }
                    _ => {
                        return Err(product_started)
                            .context("validate preflight product-started evidence");
                    }
                },
            }
        }
        #[cfg(windows)]
        let post_arm_deadline = Instant::now()
            .checked_add(PRODUCT_STARTED_TIMEOUT)
            .context("preflight post-ARM evidence deadline overflow")?;
        #[cfg(windows)]
        events.watch_post_arm_control(supervisor_stream, post_arm_deadline, &nonce)?;
        #[cfg(not(windows))]
        drop(supervisor_stream);

        #[cfg(windows)]
        let inbound_line = match events.product_line_until(
            "inbound-network probe evidence",
            post_arm_deadline,
            Some(&nonce),
        )? {
            ProductAwaitOutcome::Line(line) => line,
            ProductAwaitOutcome::StartupFailure { checkpoint_name } => {
                return Ok(PreflightProtocolOutcome::StartupFailure {
                    checkpoint_name,
                    public_deadline: post_arm_deadline,
                });
            }
            ProductAwaitOutcome::NativeExit { code } => {
                bail!("restricted product exited {code} before inbound-network probe evidence")
            }
        };
        #[cfg(not(windows))]
        let inbound_line = events.product_line("inbound-network probe evidence")?;
        let inbound_probe: InboundProbeEvidence = serde_json::from_slice(&inbound_line)
            .context("parse inbound-network probe evidence")?;
        let inbound_network_denied = match inbound_probe.bound_address {
            None => true,
            Some(address) => TcpStream::connect_timeout(&address, Duration::from_secs(2)).is_err(),
        };
        events.release_product("release inbound-network probe")?;

        #[cfg(windows)]
        let child_line = match events.product_line_until(
            "descendant probe evidence",
            post_arm_deadline,
            Some(&nonce),
        )? {
            ProductAwaitOutcome::Line(line) => line,
            ProductAwaitOutcome::StartupFailure { checkpoint_name } => {
                return Ok(PreflightProtocolOutcome::StartupFailure {
                    checkpoint_name,
                    public_deadline: post_arm_deadline,
                });
            }
            ProductAwaitOutcome::NativeExit { code } => {
                bail!("restricted product exited {code} before descendant probe evidence")
            }
        };
        #[cfg(not(windows))]
        let child_line = events.product_line("descendant probe evidence")?;
        let child_evidence: ChildProbeEvidence =
            serde_json::from_slice(&child_line).context("parse preflight descendant evidence")?;
        let (status, supervisor_stderr, contained) = events.finish()?;
        Ok(PreflightProtocolOutcome::Success {
            status,
            supervisor_stderr,
            contained,
            inbound_network_denied,
            child_evidence,
        })
    })();
    let (status, supervisor_stderr, contained, inbound_network_denied, child_evidence) =
        match protocol_result {
            Ok(PreflightProtocolOutcome::Success {
                status,
                supervisor_stderr,
                contained,
                inbound_network_denied,
                child_evidence,
            }) => (status, supervisor_stderr, contained, inbound_network_denied, child_evidence),
            Ok(PreflightProtocolOutcome::StartupFailure { checkpoint_name, public_deadline }) => {
                let finished = events.finish_failure_until(public_deadline);
                let observation = events.controller_failure_observation(&nonce);
                let copied = copy_bootstrap_failure_checkpoint(
                    &root,
                    &output,
                    checkpoint_name.as_deref(),
                    &nonce,
                    Some(&observation),
                );
                #[cfg(windows)]
                let mut copied = copied;
                #[cfg(windows)]
                if let Some(relayed) = relayed_bootstrap_evidence.as_ref() {
                    let relay = persist_relayed_product_started_evidence(
                        &output,
                        relayed,
                        &nonce,
                        &windows_bootstrap_sha256,
                        &observation,
                        events.native_exit_code,
                    );
                    let final_evidence = finished.as_ref().ok().map(|_| {
                        copy_final_product_lifecycle_evidence(
                            &root,
                            &output,
                            relayed,
                            &nonce,
                            &windows_bootstrap_sha256,
                        )
                    });
                    copied = match (copied, relay, final_evidence) {
                        (Ok(mut paths), Ok(relay), Some(Ok(final_evidence))) => {
                            paths.extend([relay, final_evidence]);
                            Ok(paths)
                        }
                        (Ok(mut paths), Ok(relay), None) => {
                            paths.push(relay);
                            Ok(paths)
                        }
                        (Err(error), _, _) | (_, Err(error), _) | (_, _, Some(Err(error))) => {
                            Err(error)
                        }
                    };
                }
                return match (copied, finished) {
                    (Ok(paths), Ok((status, stderr, _))) => Err(anyhow::anyhow!(
                        "preflight supervisor reported bounded startup failure; artifacts {}; exit {status}; stderr: {}",
                        display_paths(&paths),
                        String::from_utf8_lossy(&stderr)
                    )),
                    (Err(copy), Ok((status, stderr, _))) => Err(copy.context(format!(
                        "preflight supervisor startup failed and exited {status}; stderr: {}",
                        String::from_utf8_lossy(&stderr)
                    ))),
                    (Ok(paths), Err(finish)) => Err(finish.context(format!(
                        "preflight supervisor startup failed; artifacts {}",
                        display_paths(&paths)
                    ))),
                    (Err(copy), Err(finish)) => Err(copy.context(format!(
                        "preflight startup checkpoint copy and natural cleanup failed: {finish:#}"
                    ))),
                };
            }
            Err(error) => {
                let error = match events.abort::<()>(error) {
                    Err(error) => error,
                    Ok(()) => anyhow::anyhow!("preflight abort unexpectedly succeeded"),
                };
                #[cfg(windows)]
                let error = if let Some(evidence) = relayed_bootstrap_evidence.as_ref() {
                    let observation = events.controller_failure_observation(&nonce);
                    match persist_relayed_product_started_evidence(
                        &output,
                        evidence,
                        &nonce,
                        &windows_bootstrap_sha256,
                        &observation,
                        events.native_exit_code,
                    ) {
                        Ok(path) => error.context(format!(
                            "relayed product-started evidence: {}",
                            path.display()
                        )),
                        Err(copy) => error
                            .context(format!("persist relayed product-started evidence: {copy:#}")),
                    }
                } else {
                    error
                };
                return Err(error);
            }
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
    #[cfg(windows)]
    let bootstrap_evidence: Option<BootstrapLaunchEvidence> = {
        let path = root.join(format!("windows-bootstrap-evidence-{}.json", &nonce[..16]));
        let evidence: BootstrapLaunchEvidence = serde_json::from_slice(
            &fs::read(&path)
                .with_context(|| format!("read Windows bootstrap evidence {}", path.display()))?,
        )?;
        evidence.validate(&nonce, &windows_bootstrap_sha256)?;
        let mut expected_final = relayed_bootstrap_evidence
            .clone()
            .context("relayed product-started evidence is missing")?;
        expected_final.private_desktop_closed_after_job_empty = true;
        if expected_final != evidence {
            bail!("relayed product-started evidence changed before product exit");
        }
        Some(evidence)
    };
    #[cfg(not(windows))]
    let bootstrap_evidence: Option<BootstrapLaunchEvidence> = None;
    let windows_observations = windows_preflight_observations(child_evidence.windows_in_job);
    let evidence = PreflightEvidence {
        schema_version: 8,
        backend,
        policy: "fixture-root-only-write",
        handshake: "nonce-bound-ready-arm-with-pre-exec-t0",
        cleanup: "descendant-channel-eof-after-process-tree-empty",
        inside_write: inside.is_file(),
        adjacent_write_denied: fs::read(&adjacent).context("read protected parent sentinel")?
            == b"protected",
        descendant_adjacent_write_denied: child_evidence.adjacent_write_denied
            && fs::read(&child_adjacent).context("read protected descendant sentinel")?
                == b"protected",
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
        windows_grandchild_in_job: windows_observations.grandchild_in_job,
        windows_breakaway_denied: probe.windows_breakaway_denied,
        windows_active_process_zero: windows_observations.active_process_zero,
        windows_caller_se_impersonate_enabled: windows_observations.caller_se_impersonate_enabled,
        windows_standard_handles_valid: windows_observations.standard_handles_valid,
        windows_explicit_handle_list: windows_observations.explicit_handle_list,
        windows_bootstrap_sha256: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.bootstrap_sha256.clone()),
        windows_bootstrap_config_nonce: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.config_nonce.clone()),
        windows_bootstrap_config_consumed: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.config_consumed),
        windows_bootstrap_resume_previous_count: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.resume_previous_count),
        windows_bootstrap_ready_elapsed_ms: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.ready_elapsed_ms),
        windows_bootstrap_exact_job: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.exact_job_proof),
        windows_bootstrap_trusted_path_write_denied: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.trusted_path_write_denied),
        windows_bootstrap_self_write_denied: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.bootstrap_write_denied),
        windows_restricting_sid: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricting_sid.clone()),
        windows_broker_authentication_id: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.broker_authentication_id.clone()),
        windows_restricted_authentication_id: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricted_authentication_id.clone()),
        windows_product_authentication_id: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_authentication_id.clone()),
        windows_restricted_authentication_matches_broker: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricted_authentication_matches_broker),
        windows_product_authentication_matches_broker: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_authentication_matches_broker),
        windows_se_increase_quota_present: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.se_increase_quota_present),
        windows_se_increase_quota_enabled: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.se_increase_quota_enabled),
        windows_create_process_as_user_succeeded: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.create_process_as_user_succeeded),
        windows_restricted_token_write_restricted: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricted_token_write_restricted),
        windows_restricted_token_restricting_sid_match: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricted_token_restricting_sid_match),
        windows_restricted_token_low_integrity: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricted_token_low_integrity),
        windows_restricted_token_no_enabled_privileges: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.restricted_token_no_enabled_privileges),
        windows_product_write_restricted: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_write_restricted),
        windows_product_restricting_sid_match: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_restricting_sid_match),
        windows_product_low_integrity: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_low_integrity),
        windows_product_no_enabled_privileges: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_no_enabled_privileges),
        windows_product_exact_job: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_exact_job),
        windows_product_resume_previous_count: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_resume_previous_count),
        windows_product_process_id: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_process_id),
        windows_product_primary_thread_id: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.product_primary_thread_id),
        windows_private_desktop: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.private_desktop.clone()),
        windows_private_window_station_created: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.private_window_station_created),
        windows_private_desktop_created: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.private_desktop_created),
        windows_private_desktop_broker_assigned: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.private_desktop_broker_assigned),
        windows_private_desktop_product_assigned: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.private_desktop_product_assigned),
        windows_private_desktop_closed_after_job_empty: bootstrap_evidence
            .as_ref()
            .map(|evidence| evidence.private_desktop_closed_after_job_empty),
        supervisor_ready: true,
        timing_records: if timing_result.is_ok() { 1 } else { 0 },
        supervisor_sha256,
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
        #[cfg(windows)]
        if status.success()
            && evidence.timing_records == 1
            && windows_claim_unverified_only(&evidence)
        {
            drop(timing);
            cleanup.cleanup()?;
            return Err(WindowsClaimUnavailable.into());
        }
        bail!(
            "sandbox preflight invariant failed; see {}; supervisor stderr: {}",
            output.display(),
            String::from_utf8_lossy(&supervisor_stderr)
        );
    }
    drop(timing);
    cleanup.cleanup()?;
    Ok(())
}

fn cleanup_preflight_state(root: &Path, adjacent: &Path, child_adjacent: &Path) -> Result<()> {
    fs::remove_dir_all(root).context("remove sandbox preflight root")?;
    fs::remove_file(adjacent).context("remove protected parent sentinel")?;
    fs::remove_file(child_adjacent).context("remove protected descendant sentinel")?;
    Ok(())
}

struct PreflightCleanupGuard {
    root: PathBuf,
    adjacent: PathBuf,
    child_adjacent: PathBuf,
    armed: bool,
}

impl PreflightCleanupGuard {
    fn new(root: &Path, adjacent: &Path, child_adjacent: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
            adjacent: adjacent.to_path_buf(),
            child_adjacent: child_adjacent.to_path_buf(),
            armed: true,
        }
    }

    fn cleanup(mut self) -> Result<()> {
        cleanup_preflight_state(&self.root, &self.adjacent, &self.child_adjacent)?;
        self.armed = false;
        Ok(())
    }
}

impl Drop for PreflightCleanupGuard {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_dir_all(&self.root);
            let _ = fs::remove_file(&self.adjacent);
            let _ = fs::remove_file(&self.child_adjacent);
        }
    }
}

fn display_paths(paths: &[PathBuf]) -> String {
    paths.iter().map(|path| path.display().to_string()).collect::<Vec<_>>().join(", ")
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

fn sha256_file(path: &Path, name: &str) -> Result<String> {
    let bytes = fs::read(path).with_context(|| format!("read {name} {}", path.display()))?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

#[cfg(windows)]
fn windows_claim_unverified_only(evidence: &PreflightEvidence) -> bool {
    if !evidence.inside_write
        || !evidence.adjacent_write_denied
        || !evidence.descendant_adjacent_write_denied
        || !evidence.descendant_contained
        || !evidence.network_denied
        || !evidence.inbound_network_denied
        || !evidence.supervisor_ready
        || evidence.timing_records != 1
    {
        return false;
    }
    let observations = WindowsPreflightObservations {
        grandchild_in_job: evidence.windows_grandchild_in_job,
        active_process_zero: evidence.windows_active_process_zero,
        caller_se_impersonate_enabled: evidence.windows_caller_se_impersonate_enabled,
        standard_handles_valid: evidence.windows_standard_handles_valid,
        explicit_handle_list: evidence.windows_explicit_handle_list,
    };
    if classify_windows_preflight_observations(&observations)
        != WindowsPreflightObservationState::Unverified
    {
        return false;
    }
    // A Windows child-membership probe can legitimately return None. The shared
    // Python contract records that as unverified, while every other native and
    // common proof must remain true before this exit-78 path is eligible.
    let mut complete = evidence.clone();
    complete.windows_grandchild_in_job = Some(true);
    complete.windows_active_process_zero = Some(true);
    complete.windows_caller_se_impersonate_enabled = Some(true);
    complete.windows_standard_handles_valid = Some(true);
    complete.windows_explicit_handle_list = Some(true);
    platform_proofs_pass(&complete)
}

fn platform_proofs_pass(evidence: &PreflightEvidence) -> bool {
    #[cfg(target_os = "linux")]
    {
        evidence.linux_no_new_privs == Some(true)
            && evidence.linux_effective_capabilities_zero == Some(true)
            && evidence.linux_sudo_bwrap.is_some()
            && evidence.linux_bwrap_version.as_ref().is_some_and(|value| !value.is_empty())
            && evidence.windows_low_integrity.is_none()
            && evidence.windows_no_enabled_privileges.is_none()
            && evidence.windows_registry_write_denied.is_none()
            && evidence.windows_grandchild_in_job.is_none()
            && evidence.windows_breakaway_denied.is_none()
            && evidence.windows_active_process_zero.is_none()
            && evidence.windows_caller_se_impersonate_enabled.is_none()
            && evidence.windows_standard_handles_valid.is_none()
            && evidence.windows_explicit_handle_list.is_none()
            && evidence.windows_bootstrap_sha256.is_none()
            && evidence.windows_bootstrap_config_nonce.is_none()
            && evidence.windows_bootstrap_config_consumed.is_none()
            && evidence.windows_bootstrap_resume_previous_count.is_none()
            && evidence.windows_bootstrap_ready_elapsed_ms.is_none()
            && evidence.windows_bootstrap_exact_job.is_none()
            && evidence.windows_bootstrap_trusted_path_write_denied.is_none()
            && evidence.windows_bootstrap_self_write_denied.is_none()
            && windows_account_broker_proofs_absent(evidence)
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
            && evidence.windows_caller_se_impersonate_enabled.is_none()
            && evidence.windows_standard_handles_valid.is_none()
            && evidence.windows_explicit_handle_list.is_none()
            && evidence.windows_bootstrap_sha256.is_none()
            && evidence.windows_bootstrap_config_nonce.is_none()
            && evidence.windows_bootstrap_config_consumed.is_none()
            && evidence.windows_bootstrap_resume_previous_count.is_none()
            && evidence.windows_bootstrap_ready_elapsed_ms.is_none()
            && evidence.windows_bootstrap_exact_job.is_none()
            && evidence.windows_bootstrap_trusted_path_write_denied.is_none()
            && evidence.windows_bootstrap_self_write_denied.is_none()
            && windows_account_broker_proofs_absent(evidence)
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
            && evidence.windows_caller_se_impersonate_enabled == Some(true)
            && evidence.windows_standard_handles_valid == Some(true)
            && evidence.windows_explicit_handle_list == Some(true)
            && evidence.windows_bootstrap_sha256.as_ref().is_some_and(|value| value.len() == 64)
            && evidence
                .windows_bootstrap_config_nonce
                .as_ref()
                .is_some_and(|value| value.len() == 64)
            && evidence.windows_bootstrap_config_consumed == Some(true)
            && evidence.windows_bootstrap_resume_previous_count == Some(1)
            && evidence.windows_bootstrap_ready_elapsed_ms.is_some_and(|elapsed| elapsed <= 30_000)
            && evidence.windows_bootstrap_exact_job == Some(true)
            && evidence.windows_bootstrap_trusted_path_write_denied == Some(true)
            && evidence.windows_bootstrap_self_write_denied == Some(true)
            && evidence
                .windows_restricting_sid
                .as_ref()
                .is_some_and(|value| value.starts_with("S-1-") && value.len() <= 184)
            && evidence.windows_broker_authentication_id.as_ref().is_some_and(|value| {
                value.len() == 16 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
            && evidence.windows_restricted_authentication_id
                == evidence.windows_broker_authentication_id
            && evidence.windows_product_authentication_id
                == evidence.windows_broker_authentication_id
            && evidence.windows_restricted_authentication_matches_broker == Some(true)
            && evidence.windows_product_authentication_matches_broker == Some(true)
            && evidence.windows_se_increase_quota_present == Some(true)
            && evidence.windows_se_increase_quota_enabled == Some(true)
            && evidence.windows_create_process_as_user_succeeded == Some(true)
            && evidence.windows_restricted_token_write_restricted == Some(true)
            && evidence.windows_restricted_token_restricting_sid_match == Some(true)
            && evidence.windows_restricted_token_low_integrity == Some(true)
            && evidence.windows_restricted_token_no_enabled_privileges == Some(true)
            && evidence.windows_product_write_restricted == Some(true)
            && evidence.windows_product_restricting_sid_match == Some(true)
            && evidence.windows_product_low_integrity == Some(true)
            && evidence.windows_product_no_enabled_privileges == Some(true)
            && evidence.windows_product_exact_job == Some(true)
            && evidence.windows_product_resume_previous_count == Some(1)
            && evidence.windows_product_process_id.is_some_and(|value| value != 0)
            && evidence.windows_product_primary_thread_id.is_some_and(|value| value != 0)
            && evidence.windows_private_desktop.as_ref().is_some_and(|value| {
                value.starts_with("cmuxb-") && value.contains("\\desk-") && value.len() == 60
            })
            && evidence.windows_private_window_station_created == Some(true)
            && evidence.windows_private_desktop_created == Some(true)
            && evidence.windows_private_desktop_broker_assigned == Some(true)
            && evidence.windows_private_desktop_product_assigned == Some(true)
            && evidence.windows_private_desktop_closed_after_job_empty == Some(true)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
    {
        false
    }
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn windows_account_broker_proofs_absent(evidence: &PreflightEvidence) -> bool {
    evidence.windows_restricting_sid.is_none()
        && evidence.windows_broker_authentication_id.is_none()
        && evidence.windows_restricted_authentication_id.is_none()
        && evidence.windows_product_authentication_id.is_none()
        && evidence.windows_restricted_authentication_matches_broker.is_none()
        && evidence.windows_product_authentication_matches_broker.is_none()
        && evidence.windows_se_increase_quota_present.is_none()
        && evidence.windows_se_increase_quota_enabled.is_none()
        && evidence.windows_create_process_as_user_succeeded.is_none()
        && evidence.windows_restricted_token_write_restricted.is_none()
        && evidence.windows_restricted_token_restricting_sid_match.is_none()
        && evidence.windows_restricted_token_low_integrity.is_none()
        && evidence.windows_restricted_token_no_enabled_privileges.is_none()
        && evidence.windows_product_write_restricted.is_none()
        && evidence.windows_product_restricting_sid_match.is_none()
        && evidence.windows_product_low_integrity.is_none()
        && evidence.windows_product_no_enabled_privileges.is_none()
        && evidence.windows_product_exact_job.is_none()
        && evidence.windows_product_resume_previous_count.is_none()
        && evidence.windows_product_process_id.is_none()
        && evidence.windows_product_primary_thread_id.is_none()
        && evidence.windows_private_desktop.is_none()
        && evidence.windows_private_window_station_created.is_none()
        && evidence.windows_private_desktop_created.is_none()
        && evidence.windows_private_desktop_broker_assigned.is_none()
        && evidence.windows_private_desktop_product_assigned.is_none()
        && evidence.windows_private_desktop_closed_after_job_empty.is_none()
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
    let userns = read_optional_linux_integer("/proc/sys/kernel/unprivileged_userns_clone")?;
    let maximum = read_optional_linux_integer("/proc/sys/user/max_user_namespaces")?;
    Ok((Some(version), userns, maximum))
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
fn read_optional_linux_integer(path: &str) -> Result<Option<i64>> {
    let value = match fs::read_to_string(path) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("read Linux user-namespace setting {path}"));
        }
    };
    value
        .trim()
        .parse()
        .map(Some)
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
    Ok(None)
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
    let mut bytes = [0_u8; 4 * 1024];
    loop {
        match reader.read(&mut bytes) {
            Ok(0) => {
                let _ = sender.send(SupervisorStartupEvent::ProductOutputClosed(Ok(())));
                return;
            }
            Ok(count) => {
                if sender
                    .send(SupervisorStartupEvent::ProductOutput(bytes[..count].to_vec()))
                    .is_err()
                {
                    return;
                }
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

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn product_reader_delivers_partial_bytes_before_eof() {
        let (sender, receiver) = mpsc::channel();

        read_product_events(Cursor::new(b"partial-without-newline"), &sender);

        match receiver.recv().unwrap() {
            SupervisorStartupEvent::ProductOutput(bytes) => {
                assert_eq!(bytes, b"partial-without-newline");
            }
            _ => panic!("product reader did not preserve its partial bytes"),
        }
        assert!(matches!(
            receiver.recv().unwrap(),
            SupervisorStartupEvent::ProductOutputClosed(Ok(()))
        ));
    }

    #[test]
    fn unsupported_windows_observations_remain_unavailable() {
        let observations = windows_preflight_observations(None);

        assert_eq!(observations.grandchild_in_job, None);
        assert_eq!(observations.active_process_zero, None);
        assert_eq!(observations.caller_se_impersonate_enabled, None);
        assert_eq!(observations.standard_handles_valid, None);
        assert_eq!(observations.explicit_handle_list, None);
    }

    #[test]
    fn observed_windows_job_membership_is_relayed_without_inventing_other_signals() {
        let observations = windows_preflight_observations(Some(true));

        assert_eq!(observations.grandchild_in_job, Some(true));
        assert_eq!(observations.active_process_zero, None);
        assert_eq!(observations.caller_se_impersonate_enabled, None);
        assert_eq!(observations.standard_handles_valid, None);
        assert_eq!(observations.explicit_handle_list, None);
    }

    #[test]
    fn missing_windows_observation_is_skippable_but_not_verified() {
        let observations = windows_preflight_observations(None);

        assert_eq!(
            classify_windows_preflight_observations(&observations),
            WindowsPreflightObservationState::Unverified,
        );
    }

    #[test]
    fn false_windows_observation_is_failure_not_skippable() {
        let mut observations = windows_preflight_observations(None);
        observations.active_process_zero = Some(false);

        assert_eq!(
            classify_windows_preflight_observations(&observations),
            WindowsPreflightObservationState::Failed,
        );
    }

    #[test]
    fn preflight_cleanup_removes_root_and_sentinels() {
        let unique = format!(
            "cmux-preflight-cleanup-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        );
        let parent = std::env::temp_dir().join(unique);
        let root = parent.join("preflight-root");
        let adjacent = parent.join("protected-adjacent");
        let child_adjacent = parent.join("protected-child-adjacent");
        fs::create_dir_all(&root).unwrap();
        fs::write(&root.join("evidence"), b"evidence").unwrap();
        fs::write(&adjacent, b"protected").unwrap();
        fs::write(&child_adjacent, b"protected").unwrap();

        cleanup_preflight_state(&root, &adjacent, &child_adjacent).unwrap();

        assert!(!root.exists());
        assert!(!adjacent.exists());
        assert!(!child_adjacent.exists());
        fs::remove_dir(&parent).unwrap();
    }

    #[test]
    fn preflight_cleanup_guard_removes_state_when_controller_unwinds() {
        let unique = format!(
            "cmux-preflight-guard-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        );
        let parent = std::env::temp_dir().join(unique);
        let root = parent.join("preflight-root");
        let adjacent = parent.join("protected-adjacent");
        let child_adjacent = parent.join("protected-child-adjacent");
        fs::create_dir_all(&root).unwrap();
        fs::write(&adjacent, b"protected").unwrap();
        fs::write(&child_adjacent, b"protected").unwrap();

        {
            let _guard = PreflightCleanupGuard::new(&root, &adjacent, &child_adjacent);
        }

        assert!(!root.exists());
        assert!(!adjacent.exists());
        assert!(!child_adjacent.exists());
        fs::remove_dir(&parent).unwrap();
    }

    #[cfg(windows)]
    fn complete_windows_evidence() -> PreflightEvidence {
        let mut evidence = PreflightEvidence::default();
        evidence.inside_write = true;
        evidence.adjacent_write_denied = true;
        evidence.descendant_adjacent_write_denied = true;
        evidence.descendant_contained = true;
        evidence.network_denied = true;
        evidence.inbound_network_denied = true;
        evidence.supervisor_ready = true;
        evidence.windows_low_integrity = Some(true);
        evidence.windows_no_enabled_privileges = Some(true);
        evidence.windows_registry_write_denied = Some(true);
        evidence.windows_breakaway_denied = Some(true);
        evidence.windows_bootstrap_sha256 = Some("a".repeat(64));
        evidence.windows_bootstrap_config_nonce = Some("b".repeat(64));
        evidence.windows_bootstrap_config_consumed = Some(true);
        evidence.windows_bootstrap_resume_previous_count = Some(1);
        evidence.windows_bootstrap_ready_elapsed_ms = Some(1);
        evidence.windows_bootstrap_exact_job = Some(true);
        evidence.windows_bootstrap_trusted_path_write_denied = Some(true);
        evidence.windows_bootstrap_self_write_denied = Some(true);
        evidence.windows_restricting_sid = Some("S-1-5-21".into());
        let authentication_id = Some("0123456789abcdef".into());
        evidence.windows_broker_authentication_id = authentication_id.clone();
        evidence.windows_restricted_authentication_id = authentication_id.clone();
        evidence.windows_product_authentication_id = authentication_id;
        evidence.windows_restricted_authentication_matches_broker = Some(true);
        evidence.windows_product_authentication_matches_broker = Some(true);
        evidence.windows_se_increase_quota_present = Some(true);
        evidence.windows_se_increase_quota_enabled = Some(true);
        evidence.windows_create_process_as_user_succeeded = Some(true);
        evidence.windows_restricted_token_write_restricted = Some(true);
        evidence.windows_restricted_token_restricting_sid_match = Some(true);
        evidence.windows_restricted_token_low_integrity = Some(true);
        evidence.windows_restricted_token_no_enabled_privileges = Some(true);
        evidence.windows_product_write_restricted = Some(true);
        evidence.windows_product_restricting_sid_match = Some(true);
        evidence.windows_product_low_integrity = Some(true);
        evidence.windows_product_no_enabled_privileges = Some(true);
        evidence.windows_product_exact_job = Some(true);
        evidence.windows_product_resume_previous_count = Some(1);
        evidence.windows_product_process_id = Some(1);
        evidence.windows_product_primary_thread_id = Some(1);
        evidence.windows_private_desktop = Some(format!("cmuxb-{}\\desk-", "a".repeat(48)));
        evidence.windows_private_window_station_created = Some(true);
        evidence.windows_private_desktop_created = Some(true);
        evidence.windows_private_desktop_broker_assigned = Some(true);
        evidence.windows_private_desktop_product_assigned = Some(true);
        evidence.windows_private_desktop_closed_after_job_empty = Some(true);
        evidence.timing_records = 1;
        evidence
    }

    #[cfg(windows)]
    #[test]
    fn core_failure_with_missing_windows_observations_is_not_skippable() {
        let mut evidence = complete_windows_evidence();
        evidence.inside_write = false;

        assert!(!windows_claim_unverified_only(&evidence));
    }
}
