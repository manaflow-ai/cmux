// This protocol module is included by three explicit examples. Each consumer uses a different
// side of the timing-page protocol, so items that are live in one consumer are dead in another.
#![allow(dead_code)]

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use anyhow::{Context, Result, bail};
use memmap2::{MmapMut, MmapOptions};
use serde::{Deserialize, Serialize};

const PAGE_BYTES: u64 = 4096;
const MAGIC: &[u8; 8] = b"CMUXT001";
const MAGIC_OFFSET: usize = 0;
const NONCE_OFFSET: usize = 8;
const NONCE_BYTES: usize = 32;
const T0_OFFSET: usize = 40;
const GENERATION_OFFSET: usize = 48;

pub const CONTROL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub const STARTUP_LINE_TIMEOUT: std::time::Duration = if cfg!(windows) {
    std::time::Duration::from_secs(80)
} else {
    std::time::Duration::from_secs(60)
};
pub const SECURITY_PREPARATION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub const BOOTSTRAP_STARTUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub const BOOTSTRAP_CLEANUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum BootstrapStage {
    PublicControlConnected,
    PrivilegeEnabled,
    AccountLoggedOn,
    ProfileLoaded,
    ProfileSkipped,
    RestrictedTokenReady,
    AccountAclApplied,
    RestrictingSidAclApplied,
    LowIntegrityAclApplied,
    JobCompletionPortReady,
    ProcessCreatedSuspended,
    JobAssigned,
    HandlesDuplicated,
    ConfigWritten,
    ProcessResumed,
    NativeEntryReached,
    NativeConfigReadStarted,
    ConfigConsumed,
    LaunchValidated,
    StandardHandlesValidated,
    TimingConsumed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum BootstrapTerminal {
    Ready,
    Exit { code: u32 },
    Eof,
    SecurityTimeout,
    BootstrapTimeout,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BootstrapObservedEvent {
    Stage(BootstrapStage),
    Ready,
    Exit(u32),
    Eof,
    SecurityTimeout,
    BootstrapTimeout,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct BootstrapStageObservation {
    pub stage: BootstrapStage,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BootstrapCleanupResult {
    pub state: &'static str,
    pub detail: Option<String>,
}

impl BootstrapCleanupResult {
    pub fn completed() -> Self {
        Self { state: "completed", detail: None }
    }

    pub fn failed(detail: impl Into<String>) -> Self {
        Self { state: "failed", detail: Some(detail.into()) }
    }

    pub fn not_started() -> Self {
        Self { state: "not-started", detail: None }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BootstrapStartupTrace {
    #[serde(skip)]
    started_at: Instant,
    pub stages: Vec<BootstrapStageObservation>,
    pub config_bytes: Option<u64>,
    pub config_sha256: Option<String>,
    pub config_consumed: bool,
    pub process_exit_code: Option<u32>,
    pub terminal: Option<BootstrapTerminal>,
    pub terminal_elapsed_ms: Option<u64>,
}

impl BootstrapStartupTrace {
    pub fn new() -> Self {
        Self {
            started_at: Instant::now(),
            stages: Vec::new(),
            config_bytes: None,
            config_sha256: None,
            config_consumed: false,
            process_exit_code: None,
            terminal: None,
            terminal_elapsed_ms: None,
        }
    }

    pub fn record_config(&mut self, bytes: u64, sha256: String) {
        self.config_bytes = Some(bytes);
        self.config_sha256 = Some(sha256);
    }

    pub fn observe(&mut self, event: BootstrapObservedEvent) -> Option<BootstrapTerminal> {
        let elapsed_ms = u64::try_from(self.started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
        self.observe_at(event, elapsed_ms)
    }

    pub fn observe_at(
        &mut self,
        event: BootstrapObservedEvent,
        elapsed_ms: u64,
    ) -> Option<BootstrapTerminal> {
        if self.terminal.is_some() {
            return self.terminal;
        }
        let elapsed_ms = self
            .stages
            .last()
            .map_or(elapsed_ms, |observation| elapsed_ms.max(observation.elapsed_ms));
        let terminal = match event {
            BootstrapObservedEvent::Stage(stage) => {
                if stage == BootstrapStage::ConfigConsumed {
                    self.config_consumed = true;
                }
                self.stages.push(BootstrapStageObservation { stage, elapsed_ms });
                return None;
            }
            BootstrapObservedEvent::Ready => BootstrapTerminal::Ready,
            BootstrapObservedEvent::Exit(code) => {
                self.process_exit_code = Some(code);
                BootstrapTerminal::Exit { code }
            }
            BootstrapObservedEvent::Eof => BootstrapTerminal::Eof,
            BootstrapObservedEvent::SecurityTimeout => BootstrapTerminal::SecurityTimeout,
            BootstrapObservedEvent::BootstrapTimeout => BootstrapTerminal::BootstrapTimeout,
            BootstrapObservedEvent::Error => BootstrapTerminal::Error,
        };
        self.terminal = Some(terminal);
        self.terminal_elapsed_ms = Some(elapsed_ms);
        Some(terminal)
    }
}

#[derive(Debug, Serialize)]
pub struct BootstrapFailureCheckpoint<'a> {
    pub schema_version: u32,
    pub record_type: &'static str,
    pub nonce: &'a str,
    pub reason: &'a str,
    pub config_present_after_failure: bool,
    pub trace: &'a BootstrapStartupTrace,
}

#[derive(Debug, Serialize)]
pub struct BootstrapCleanupCheckpoint<'a> {
    pub schema_version: u32,
    pub record_type: &'static str,
    pub nonce: &'a str,
    pub containment_cleanup: &'a BootstrapCleanupResult,
    pub bootstrap_cleanup: &'a BootstrapCleanupResult,
}

pub fn validate_bootstrap_failure_records(bytes: &[u8], expected_nonce: &str) -> Result<()> {
    let records = bytes
        .split(|byte| *byte == b'\n')
        .filter(|record| !record.is_empty())
        .map(serde_json::from_slice::<serde_json::Value>)
        .collect::<serde_json::Result<Vec<_>>>()
        .context("validate bootstrap checkpoint JSON records")?;
    let valid_record = |index: usize, record_type: &str| {
        records.get(index).is_some_and(|record| {
            record.get("schema_version").and_then(serde_json::Value::as_u64) == Some(1)
                && record.get("record_type").and_then(serde_json::Value::as_str)
                    == Some(record_type)
                && record.get("nonce").and_then(serde_json::Value::as_str) == Some(expected_nonce)
        })
    };
    if records.len() != 2
        || !valid_record(0, "startup-failure")
        || !valid_record(1, "cleanup-result")
    {
        bail!("bootstrap checkpoint identity, schema, or ordered records are invalid");
    }
    Ok(())
}

pub fn setup_line(nonce: &str) -> String {
    format!("SETUP {nonce}\n")
}

pub fn failure_line(nonce: &str, checkpoint_name: Option<&str>) -> Result<String> {
    let checkpoint_name = checkpoint_name.unwrap_or("-");
    if checkpoint_name.len() > 96
        || checkpoint_name
            .bytes()
            .any(|byte| !(byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_')))
    {
        bail!("bootstrap failure checkpoint name is not portable");
    }
    Ok(format!("FAILURE {nonce} {checkpoint_name}\n"))
}

#[derive(Debug, PartialEq, Eq)]
pub enum SupervisorStartupLine {
    Setup,
    Ready,
    Failure { checkpoint_name: Option<String> },
}

pub fn parse_supervisor_startup_line(line: &str, nonce: &str) -> Result<SupervisorStartupLine> {
    if line == setup_line(nonce).trim_end() {
        return Ok(SupervisorStartupLine::Setup);
    }
    if line == ready_line(nonce).trim_end() {
        return Ok(SupervisorStartupLine::Ready);
    }
    let prefix = format!("FAILURE {nonce} ");
    let Some(checkpoint) = line.strip_prefix(&prefix) else {
        bail!("supervisor startup line identity mismatch");
    };
    if checkpoint == "-" {
        return Ok(SupervisorStartupLine::Failure { checkpoint_name: None });
    }
    let canonical = failure_line(nonce, Some(checkpoint))?;
    if canonical.trim_end() != line {
        bail!("supervisor failure line was not canonical");
    }
    Ok(SupervisorStartupLine::Failure { checkpoint_name: Some(checkpoint.to_string()) })
}

pub struct TimingPage {
    path: PathBuf,
    mapping: MmapMut,
    nonce: [u8; NONCE_BYTES],
}

impl TimingPage {
    pub fn create(path: PathBuf) -> Result<Self> {
        let mut nonce = [0_u8; NONCE_BYTES];
        getrandom::fill(&mut nonce).map_err(|error| anyhow::anyhow!(error.to_string()))?;
        let file = OpenOptions::new()
            .create_new(true)
            .read(true)
            .write(true)
            .open(&path)
            .with_context(|| format!("create launch timing page {}", path.display()))?;
        file.set_len(PAGE_BYTES)?;
        set_owner_only(&file)?;
        let mut mapping = map_file(&file)?;
        mapping.fill(0);
        mapping[MAGIC_OFFSET..MAGIC_OFFSET + MAGIC.len()].copy_from_slice(MAGIC);
        mapping[NONCE_OFFSET..NONCE_OFFSET + NONCE_BYTES].copy_from_slice(&nonce);
        mapping.flush()?;
        Ok(Self { path, mapping, nonce })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn nonce_hex(&self) -> String {
        hex(&self.nonce)
    }

    pub fn measured_duration_ns(&self, event_ns: u64) -> Result<u64> {
        self.validate_header()?;
        let generation = atomic(&self.mapping, GENERATION_OFFSET).load(Ordering::Acquire);
        if generation != 1 {
            bail!("launch timing page generation was {generation}, expected 1");
        }
        let t0 = atomic(&self.mapping, T0_OFFSET).load(Ordering::Acquire);
        event_ns.checked_sub(t0).context("startup event preceded supervisor t0")
    }

    fn validate_header(&self) -> Result<()> {
        if &self.mapping[MAGIC_OFFSET..MAGIC_OFFSET + MAGIC.len()] != MAGIC {
            bail!("launch timing page magic changed");
        }
        if self.mapping[NONCE_OFFSET..NONCE_OFFSET + NONCE_BYTES] != self.nonce {
            bail!("launch timing page nonce changed");
        }
        Ok(())
    }
}

pub struct TimingSink {
    mapping: MmapMut,
    nonce: [u8; NONCE_BYTES],
}

impl TimingSink {
    pub fn open(path: &Path, expected_nonce: &str) -> Result<Self> {
        let nonce = decode_nonce(expected_nonce)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .open(path)
            .with_context(|| format!("open launch timing page {}", path.display()))?;
        Self::from_file_with_nonce(&file, nonce)
    }

    fn from_file_with_nonce(file: &File, nonce: [u8; NONCE_BYTES]) -> Result<Self> {
        if file.metadata()?.len() != PAGE_BYTES {
            bail!("launch timing page has the wrong size");
        }
        let mapping = map_file(file)?;
        if &mapping[MAGIC_OFFSET..MAGIC_OFFSET + MAGIC.len()] != MAGIC
            || mapping[NONCE_OFFSET..NONCE_OFFSET + NONCE_BYTES] != nonce
        {
            bail!("launch timing page identity mismatch");
        }
        Ok(Self { mapping, nonce })
    }

    pub fn record_pre_exec(&self) -> std::io::Result<()> {
        if self.mapping[NONCE_OFFSET..NONCE_OFFSET + NONCE_BYTES] != self.nonce {
            return Err(std::io::Error::other("launch timing nonce changed"));
        }
        let generation = atomic(&self.mapping, GENERATION_OFFSET);
        if generation.load(Ordering::Acquire) != 0 {
            return Err(std::io::Error::other("launch timing page was already armed"));
        }
        atomic(&self.mapping, T0_OFFSET).store(monotonic_ns()?, Ordering::Release);
        generation.store(1, Ordering::Release);
        Ok(())
    }
}

pub fn ready_line(nonce: &str) -> String {
    format!("READY {nonce}\n")
}

pub fn arm_line(nonce: &str) -> String {
    format!("ARM {nonce}\n")
}

#[cfg(target_os = "macos")]
pub fn macos_account_identity(nonce: &str, prefix: &str, uid_base: u32) -> Result<(String, u32)> {
    if !prefix.starts_with("cmxb")
        || prefix.len() > 12
        || !prefix.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    {
        bail!("macOS benchmark account prefix must be 4-12 lowercase letters or digits");
    }
    if nonce.len() != NONCE_BYTES * 2 || !nonce.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        bail!("macOS benchmark account nonce is invalid");
    }
    if !(200_000..=500_000_000).contains(&uid_base) {
        bail!("macOS benchmark UID base is outside the reserved range");
    }
    let offset = u32::from_str_radix(&nonce[..8], 16)? % 1_000_000_000;
    let uid = uid_base.checked_add(offset).context("macOS benchmark UID overflow")?;
    if uid >= 1_500_000_000 {
        bail!("macOS benchmark UID exceeds the reserved range");
    }
    let user = format!("{prefix}{}", &nonce[..10].to_ascii_lowercase());
    Ok((user, uid))
}

pub fn read_control_line(reader: &mut impl Read) -> Result<String> {
    let mut bytes = Vec::with_capacity(80);
    let mut byte = [0_u8; 1];
    while bytes.len() < 256 {
        reader.read_exact(&mut byte)?;
        if byte[0] == b'\n' {
            return String::from_utf8(bytes).context("control line was not UTF-8");
        }
        bytes.push(byte[0]);
    }
    bail!("control line exceeded 255 bytes")
}

pub fn write_control_line(writer: &mut impl Write, line: &str) -> Result<()> {
    writer.write_all(line.as_bytes())?;
    writer.flush()?;
    Ok(())
}

pub fn monotonic_ns() -> std::io::Result<u64> {
    #[cfg(unix)]
    {
        let mut value = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        // SAFETY: `value` points to valid writable storage for clock_gettime.
        if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut value) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let seconds = u64::try_from(value.tv_sec).map_err(std::io::Error::other)?;
        let nanos = u64::try_from(value.tv_nsec).map_err(std::io::Error::other)?;
        seconds
            .checked_mul(1_000_000_000)
            .and_then(|value| value.checked_add(nanos))
            .ok_or_else(|| std::io::Error::other("monotonic clock overflow"))
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Performance::{
            QueryPerformanceCounter, QueryPerformanceFrequency,
        };

        let mut counter = 0_i64;
        let mut frequency = 0_i64;
        // SAFETY: both pointers reference initialized writable i64 values.
        if unsafe { QueryPerformanceCounter(&mut counter) } == 0
            || unsafe { QueryPerformanceFrequency(&mut frequency) } == 0
        {
            return Err(std::io::Error::last_os_error());
        }
        let counter = u128::try_from(counter).map_err(std::io::Error::other)?;
        let frequency = u128::try_from(frequency).map_err(std::io::Error::other)?;
        let nanos = counter
            .checked_mul(1_000_000_000)
            .and_then(|value| value.checked_div(frequency))
            .ok_or_else(|| std::io::Error::other("performance counter conversion failed"))?;
        u64::try_from(nanos).map_err(std::io::Error::other)
    }
}

fn map_file(file: &File) -> Result<MmapMut> {
    // SAFETY: the file is held open during mapping creation and has a fixed 4096-byte length.
    unsafe { MmapOptions::new().len(PAGE_BYTES as usize).map_mut(file) }.map_err(Into::into)
}

fn atomic(mapping: &[u8], offset: usize) -> &AtomicU64 {
    let pointer = mapping[offset..].as_ptr().cast::<AtomicU64>();
    // SAFETY: mmap pages are page-aligned and both fixed offsets are aligned for AtomicU64.
    unsafe { &*pointer }
}

fn decode_nonce(value: &str) -> Result<[u8; NONCE_BYTES]> {
    if value.len() != NONCE_BYTES * 2 {
        bail!("control nonce has the wrong length");
    }
    let mut nonce = [0_u8; NONCE_BYTES];
    for (index, output) in nonce.iter_mut().enumerate() {
        *output = u8::from_str_radix(&value[index * 2..index * 2 + 2], 16)
            .context("control nonce was not hexadecimal")?;
    }
    Ok(nonce)
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
    }
    output
}

#[cfg(unix)]
fn set_owner_only(file: &File) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(windows)]
fn set_owner_only(_file: &File) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timing_page_accepts_one_nonce_bound_pre_exec_record() {
        let directory = tempfile::tempdir().unwrap();
        let page = TimingPage::create(directory.path().join("timing.page")).unwrap();
        let sink = TimingSink::open(page.path(), &page.nonce_hex()).unwrap();

        sink.record_pre_exec().unwrap();
        let event = monotonic_ns().unwrap();

        assert!(page.measured_duration_ns(event).is_ok());
        assert!(sink.record_pre_exec().is_err());
    }

    #[test]
    fn timing_page_rejects_a_different_nonce() {
        let directory = tempfile::tempdir().unwrap();
        let page = TimingPage::create(directory.path().join("timing.page")).unwrap();
        let wrong = "0".repeat(NONCE_BYTES * 2);

        if wrong != page.nonce_hex() {
            assert!(TimingSink::open(page.path(), &wrong).is_err());
        }
    }

    #[test]
    fn control_messages_bind_ready_and_arm_to_one_nonce() {
        let nonce = "ab".repeat(NONCE_BYTES);
        assert_eq!(ready_line(&nonce), format!("READY {nonce}\n"));
        assert_eq!(arm_line(&nonce), format!("ARM {nonce}\n"));
    }

    #[test]
    fn bootstrap_trace_records_ready_as_a_terminal_event() {
        let mut trace = BootstrapStartupTrace::new();

        assert_eq!(trace.observe(BootstrapObservedEvent::Ready), Some(BootstrapTerminal::Ready));
        assert_eq!(trace.observe(BootstrapObservedEvent::Exit(1)), Some(BootstrapTerminal::Ready));
        assert_eq!(
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ConfigConsumed)),
            Some(BootstrapTerminal::Ready)
        );
        assert_eq!(trace.process_exit_code, None);
        assert!(!trace.config_consumed);
        assert!(trace.stages.is_empty());
    }

    #[test]
    fn bootstrap_trace_records_exit_code_before_ready() {
        let mut trace = BootstrapStartupTrace::new();

        assert_eq!(
            trace.observe(BootstrapObservedEvent::Exit(1)),
            Some(BootstrapTerminal::Exit { code: 1 })
        );
        assert_eq!(trace.process_exit_code, Some(1));
        assert_eq!(
            trace.observe(BootstrapObservedEvent::Ready),
            Some(BootstrapTerminal::Exit { code: 1 })
        );
    }

    #[test]
    fn bootstrap_trace_distinguishes_pipe_eof() {
        let mut trace = BootstrapStartupTrace::new();

        assert_eq!(trace.observe(BootstrapObservedEvent::Eof), Some(BootstrapTerminal::Eof));
    }

    #[test]
    fn bootstrap_trace_distinguishes_security_and_child_timeouts() {
        let mut security = BootstrapStartupTrace::new();
        let mut bootstrap = BootstrapStartupTrace::new();

        assert_eq!(
            security.observe_at(BootstrapObservedEvent::SecurityTimeout, 30_000),
            Some(BootstrapTerminal::SecurityTimeout)
        );
        assert_eq!(
            bootstrap.observe_at(BootstrapObservedEvent::BootstrapTimeout, 10_000),
            Some(BootstrapTerminal::BootstrapTimeout)
        );
        assert_eq!(security.terminal_elapsed_ms, Some(30_000));
        assert_eq!(bootstrap.terminal_elapsed_ms, Some(10_000));
    }

    #[test]
    fn bootstrap_trace_records_config_consumption_as_a_stage() {
        let mut trace = BootstrapStartupTrace::new();

        assert_eq!(
            trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ConfigConsumed)),
            None
        );
        assert!(trace.config_consumed);
        assert_eq!(trace.stages[0].stage, BootstrapStage::ConfigConsumed);
    }

    #[test]
    fn bootstrap_trace_preserves_config_not_consumed_failure_order() {
        let mut trace = BootstrapStartupTrace::new();

        trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::LaunchValidated));
        trace.observe(BootstrapObservedEvent::Error);
        trace.observe(BootstrapObservedEvent::Stage(BootstrapStage::ConfigConsumed));

        assert_eq!(trace.terminal, Some(BootstrapTerminal::Error));
        assert!(!trace.config_consumed);
        assert_eq!(trace.stages[0].stage, BootstrapStage::LaunchValidated);
    }

    #[test]
    fn bootstrap_trace_keeps_elapsed_stage_observations_ordered() {
        let mut trace = BootstrapStartupTrace::new();

        trace.observe_at(BootstrapObservedEvent::Stage(BootstrapStage::PrivilegeEnabled), 7);
        trace.observe_at(BootstrapObservedEvent::Stage(BootstrapStage::AccountLoggedOn), 3);
        trace.observe_at(BootstrapObservedEvent::Stage(BootstrapStage::ProfileSkipped), 12);

        assert_eq!(
            trace.stages,
            vec![
                BootstrapStageObservation {
                    stage: BootstrapStage::PrivilegeEnabled,
                    elapsed_ms: 7,
                },
                BootstrapStageObservation { stage: BootstrapStage::AccountLoggedOn, elapsed_ms: 7 },
                BootstrapStageObservation { stage: BootstrapStage::ProfileSkipped, elapsed_ms: 12 },
            ]
        );
    }

    #[test]
    fn bootstrap_checkpoint_keeps_cleanup_results() {
        let containment = BootstrapCleanupResult::completed();
        let bootstrap = BootstrapCleanupResult::failed("exit wait exceeded deadline");
        let checkpoint = BootstrapCleanupCheckpoint {
            schema_version: 1,
            record_type: "cleanup-result",
            nonce: "nonce",
            containment_cleanup: &containment,
            bootstrap_cleanup: &bootstrap,
        };

        assert_eq!(checkpoint.containment_cleanup.state, "completed");
        assert_eq!(checkpoint.bootstrap_cleanup.state, "failed");
        assert_eq!(
            checkpoint.bootstrap_cleanup.detail.as_deref(),
            Some("exit wait exceeded deadline")
        );
    }

    #[test]
    fn bootstrap_checkpoint_round_trip_preserves_identity_and_order() {
        let trace = BootstrapStartupTrace::new();
        let containment = BootstrapCleanupResult::completed();
        let bootstrap = BootstrapCleanupResult::completed();
        let failure = BootstrapFailureCheckpoint {
            schema_version: 1,
            record_type: "startup-failure",
            nonce: "nonce",
            reason: "bootstrap exited",
            config_present_after_failure: false,
            trace: &trace,
        };
        let cleanup = BootstrapCleanupCheckpoint {
            schema_version: 1,
            record_type: "cleanup-result",
            nonce: "nonce",
            containment_cleanup: &containment,
            bootstrap_cleanup: &bootstrap,
        };
        let mut records = serde_json::to_vec(&failure).unwrap();
        records.push(b'\n');
        records.extend(serde_json::to_vec(&cleanup).unwrap());
        records.push(b'\n');

        validate_bootstrap_failure_records(&records, "nonce").unwrap();
        assert!(validate_bootstrap_failure_records(&records, "different").is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_account_identity_is_deterministic_and_job_scoped() {
        let nonce = "ab".repeat(NONCE_BYTES);
        let first = macos_account_identity(&nonce, "cmxb123", 300_000).unwrap();
        let second = macos_account_identity(&nonce, "cmxb123", 300_000).unwrap();

        assert_eq!(first, second);
        assert!(first.0.starts_with("cmxb123"));
        assert!((300_000..1_000_300_000).contains(&first.1));
    }
}
