// This protocol module is included by three explicit examples. Each consumer uses a different
// side of the timing-page protocol, so items that are live in one consumer are dead in another.
#![allow(dead_code)]

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Instant;

use anyhow::{Context, Result, bail};
use cmux_startup_bootstrap::BootstrapLaunchEvidence;
use memmap2::{MmapMut, MmapOptions};
use serde::{Deserialize, Serialize};

const PAGE_BYTES: u64 = 4096;
const MAGIC: &[u8; 8] = b"CMUXT001";
const MAGIC_OFFSET: usize = 0;
const NONCE_OFFSET: usize = 8;
const NONCE_BYTES: usize = 32;
const T0_OFFSET: usize = 40;
const GENERATION_OFFSET: usize = 48;
const MAX_PRODUCT_STARTED_LINE_BYTES: usize = 4096;

pub const CONTROL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub const STARTUP_LINE_TIMEOUT: std::time::Duration = if cfg!(windows) {
    std::time::Duration::from_secs(80)
} else {
    std::time::Duration::from_secs(60)
};
pub const PRODUCT_STARTED_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(50);
pub const SECURITY_PREPARATION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub const BOOTSTRAP_STARTUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
pub const BOOTSTRAP_CLEANUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
pub const BOOTSTRAP_HANG_CAPTURE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
pub const MAX_BOOTSTRAP_HANG_REPORT_BYTES: u64 = 256 * 1024;
pub const MAX_BOOTSTRAP_HANG_DUMP_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_PRODUCT_FAILURE_STDOUT_TAIL_BYTES: usize = 8 * 1024;
pub const BOOTSTRAP_FAILURE_SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
#[serde(rename_all = "kebab-case")]
pub enum BootstrapStage {
    PublicControlConnected,
    PrivilegeEnabled,
    AccountLoggedOn,
    ProfileLoaded,
    ProfileSkipped,
    AccountBrokerReady,
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
    RestrictedProductTokenReady,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapStageObservation {
    pub stage: BootstrapStage,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapCleanupResult {
    pub state: String,
    pub detail: Option<String>,
}

impl BootstrapCleanupResult {
    pub fn completed() -> Self {
        Self { state: "completed".into(), detail: None }
    }

    pub fn failed(detail: impl Into<String>) -> Self {
        Self { state: "failed".into(), detail: Some(detail.into()) }
    }

    pub fn not_started() -> Self {
        Self { state: "not-started".into(), detail: None }
    }

    fn validate(&self) -> Result<()> {
        match (self.state.as_str(), &self.detail) {
            ("completed" | "not-started", None) => Ok(()),
            ("failed", Some(detail)) if !detail.is_empty() && detail.len() <= 1_024 => Ok(()),
            _ => bail!("bootstrap cleanup result is invalid"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapStartupTrace {
    #[serde(skip, default = "Instant::now")]
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product_lifecycle: Option<&'a BootstrapProductLifecycleEvidence>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hang_diagnostic: Option<&'a BootstrapHangArtifactReference>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hang_diagnostic_error: Option<&'a str>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapProductLifecycleEvidence {
    pub product_process_id: u32,
    pub product_primary_thread_id: u32,
    pub native_exit_received: bool,
    pub native_exit_code: Option<u32>,
}

impl BootstrapProductLifecycleEvidence {
    pub fn validate(&self) -> Result<()> {
        if self.product_process_id == 0
            || self.product_primary_thread_id == 0
            || self.native_exit_received != self.native_exit_code.is_some()
        {
            bail!("bootstrap product lifecycle evidence is invalid");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapControllerFailureObservation {
    pub schema_version: u32,
    pub record_type: String,
    pub nonce: String,
    pub raw_stdout_tail_hex: String,
    pub raw_stdout_tail_bytes: u64,
    pub complete_stdout_lines: u64,
    pub stdout_closed: bool,
    pub stdout_error: Option<String>,
}

impl BootstrapControllerFailureObservation {
    pub fn validate(&self, expected_nonce: &str) -> Result<()> {
        let expected_hex_bytes = usize::try_from(self.raw_stdout_tail_bytes)?
            .checked_mul(2)
            .context("product stdout tail hex length overflow")?;
        if self.schema_version != BOOTSTRAP_FAILURE_SCHEMA_VERSION
            || self.record_type != "controller-observation"
            || self.nonce != expected_nonce
            || self.raw_stdout_tail_bytes > u64::try_from(MAX_PRODUCT_FAILURE_STDOUT_TAIL_BYTES)?
            || self.raw_stdout_tail_hex.len() != expected_hex_bytes
            || !self.raw_stdout_tail_hex.bytes().all(|byte| byte.is_ascii_hexdigit())
            || self
                .stdout_error
                .as_ref()
                .is_some_and(|error| error.is_empty() || error.len() > 2_048)
        {
            bail!("bootstrap controller failure observation is invalid");
        }
        Ok(())
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BootstrapFailureCheckpointRecord {
    schema_version: u32,
    record_type: String,
    nonce: String,
    reason: String,
    config_present_after_failure: bool,
    trace: BootstrapStartupTrace,
    product_lifecycle: Option<BootstrapProductLifecycleEvidence>,
    hang_diagnostic: Option<BootstrapHangArtifactReference>,
    hang_diagnostic_error: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BootstrapCleanupCheckpointRecord {
    schema_version: u32,
    record_type: String,
    nonce: String,
    containment_cleanup: BootstrapCleanupResult,
    bootstrap_cleanup: BootstrapCleanupResult,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangArtifactReference {
    pub report_name: String,
    pub report_sha256: String,
    pub report_bytes: u64,
    pub dump_name: String,
    pub dump_sha256: String,
    pub dump_bytes: u64,
}

impl BootstrapHangArtifactReference {
    pub fn validate(&self) -> Result<()> {
        validate_portable_artifact_name(&self.report_name, ".json")?;
        validate_portable_artifact_name(&self.dump_name, ".dmp")?;
        if self.report_name == self.dump_name {
            bail!("bootstrap hang diagnostic artifact names must differ");
        }
        for (name, digest) in [
            ("bootstrap hang report", &self.report_sha256),
            ("bootstrap minidump", &self.dump_sha256),
        ] {
            if digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                bail!("{name} SHA-256 is invalid");
            }
        }
        if self.report_bytes == 0 || self.report_bytes > MAX_BOOTSTRAP_HANG_REPORT_BYTES {
            bail!("bootstrap hang report size is outside its bound");
        }
        if self.dump_bytes == 0 || self.dump_bytes > MAX_BOOTSTRAP_HANG_DUMP_BYTES {
            bail!("bootstrap minidump size is outside its bound");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangModule {
    pub base_address: u64,
    pub size: u32,
    pub path: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangThreadContext {
    pub instruction_pointer: u64,
    pub stack_pointer: u64,
    pub module_path: Option<String>,
    pub module_base_address: Option<u64>,
    pub module_offset: Option<u64>,
    pub owner_source: Option<String>,
    pub mapping_windows_error: Option<u32>,
    pub instruction_window: BootstrapHangInstructionWindow,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangInstructionWindow {
    pub start_address: u64,
    pub bytes_hex: Option<String>,
    pub windows_error: Option<u32>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangWaitChainNode {
    pub object_type: i32,
    pub object_status: i32,
    pub process_id: Option<u32>,
    pub thread_id: Option<u32>,
    pub object_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangWaitChain {
    pub captured: bool,
    pub cycle: bool,
    pub windows_error: Option<u32>,
    pub nodes: Vec<BootstrapHangWaitChainNode>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct BootstrapHangDiagnosticReport {
    pub schema_version: u32,
    pub nonce: String,
    pub process_id: u32,
    pub primary_thread_id: u32,
    pub suspended_previous_count: u32,
    pub context: BootstrapHangThreadContext,
    pub modules: Vec<BootstrapHangModule>,
    pub module_map_windows_error: Option<u32>,
    pub wait_chain: BootstrapHangWaitChain,
    pub dump_name: String,
    pub dump_sha256: String,
    pub dump_bytes: u64,
    pub cmux_bench_environment_filtered: bool,
    pub helper_cmux_bench_environment_filtered: bool,
}

impl BootstrapHangDiagnosticReport {
    pub fn validate(&self, expected_nonce: &str) -> Result<()> {
        if self.schema_version != 1 || self.nonce != expected_nonce {
            bail!("bootstrap hang report identity or schema is invalid");
        }
        if self.process_id == 0 || self.primary_thread_id == 0 {
            bail!("bootstrap hang report process identity is invalid");
        }
        if self.suspended_previous_count == u32::MAX {
            bail!("bootstrap hang report did not suspend the primary thread");
        }
        if self.modules.len() > 256
            || (self.modules.is_empty() && self.module_map_windows_error.is_none())
            || self.module_map_windows_error == Some(0)
        {
            bail!("bootstrap hang module map is outside its bound");
        }
        if self.modules.iter().any(|module| {
            module.size == 0 || module.path.is_empty() || module.path.len() > 32 * 1024
        }) {
            bail!("bootstrap hang module map contains an invalid entry");
        }
        let owner = self
            .context
            .module_path
            .as_ref()
            .zip(self.context.module_base_address)
            .zip(self.context.module_offset)
            .zip(self.context.owner_source.as_deref());
        if let Some((((path, base), offset), source)) = owner {
            if path.is_empty()
                || path.len() > 32 * 1024
                || !matches!(source, "module-map" | "virtual-query")
                || self.context.instruction_pointer < base
                || offset != self.context.instruction_pointer.saturating_sub(base)
                || self.context.mapping_windows_error.is_some()
            {
                bail!("bootstrap hang instruction owner is invalid");
            }
        } else if self.context.module_path.is_some()
            || self.context.module_base_address.is_some()
            || self.context.module_offset.is_some()
            || self.context.owner_source.is_some()
            || self.context.mapping_windows_error.is_none_or(|error| error == 0)
        {
            bail!("bootstrap hang instruction owner evidence is incomplete");
        }
        if self.context.instruction_window.bytes_hex.is_some()
            == self.context.instruction_window.windows_error.is_some()
            || self.context.instruction_window.windows_error == Some(0)
        {
            bail!("bootstrap hang instruction window evidence is invalid");
        }
        if self.context.instruction_window.bytes_hex.as_ref().is_some_and(|bytes| {
            bytes.is_empty()
                || bytes.len() > 64
                || !bytes.len().is_multiple_of(2)
                || !bytes.bytes().all(|byte| byte.is_ascii_hexdigit())
        }) {
            bail!("bootstrap hang instruction window bytes are invalid");
        }
        if self.wait_chain.nodes.len() > 16
            || (self.wait_chain.captured == self.wait_chain.windows_error.is_some())
        {
            bail!("bootstrap hang wait-chain evidence is invalid");
        }
        if self.wait_chain.captured && self.wait_chain.nodes.is_empty() {
            bail!("bootstrap hang wait-chain capture is empty");
        }
        validate_portable_artifact_name(&self.dump_name, ".dmp")?;
        if self.dump_sha256.len() != 64
            || !self.dump_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
            || self.dump_bytes == 0
            || self.dump_bytes > MAX_BOOTSTRAP_HANG_DUMP_BYTES
        {
            bail!("bootstrap hang report minidump evidence is invalid");
        }
        if !self.cmux_bench_environment_filtered || !self.helper_cmux_bench_environment_filtered {
            bail!("bootstrap hang report did not prove CMUX_BENCH environment filtering");
        }
        Ok(())
    }
}

fn validate_portable_artifact_name(name: &str, suffix: &str) -> Result<()> {
    if name.len() > 96
        || !name.ends_with(suffix)
        || name
            .bytes()
            .any(|byte| !(byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_')))
    {
        bail!("bootstrap diagnostic artifact name is not portable");
    }
    Ok(())
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
    let records =
        bytes.split(|byte| *byte == b'\n').filter(|record| !record.is_empty()).collect::<Vec<_>>();
    if !(2..=3).contains(&records.len()) {
        bail!("bootstrap checkpoint identity, schema, or ordered records are invalid");
    }
    let failure: BootstrapFailureCheckpointRecord =
        serde_json::from_slice(records[0]).context("parse bootstrap startup failure checkpoint")?;
    let cleanup: BootstrapCleanupCheckpointRecord =
        serde_json::from_slice(records[1]).context("parse bootstrap cleanup checkpoint")?;
    if failure.schema_version != BOOTSTRAP_FAILURE_SCHEMA_VERSION
        || failure.record_type != "startup-failure"
        || failure.nonce != expected_nonce
        || failure.reason.is_empty()
        || failure.reason.len() > 2_048
        || cleanup.schema_version != BOOTSTRAP_FAILURE_SCHEMA_VERSION
        || cleanup.record_type != "cleanup-result"
        || cleanup.nonce != expected_nonce
    {
        bail!("bootstrap checkpoint identity, schema, or ordered records are invalid");
    }
    cleanup.containment_cleanup.validate()?;
    cleanup.bootstrap_cleanup.validate()?;
    let _ = failure.config_present_after_failure;
    let _ = &failure.trace;
    if let Some(lifecycle) = &failure.product_lifecycle {
        lifecycle.validate()?;
    }
    if failure.hang_diagnostic.is_some() && failure.hang_diagnostic_error.is_some() {
        bail!("bootstrap hang diagnostic result is ambiguous");
    }
    if let Some(reference) = &failure.hang_diagnostic {
        reference.validate()?;
    }
    if failure
        .hang_diagnostic_error
        .as_ref()
        .is_some_and(|error| error.is_empty() || error.len() > 2_048)
    {
        bail!("bootstrap hang diagnostic error is invalid");
    }
    if let Some(record) = records.get(2) {
        let observation: BootstrapControllerFailureObservation = serde_json::from_slice(record)
            .context("parse bootstrap controller failure observation")?;
        observation.validate(expected_nonce)?;
    }
    Ok(())
}

pub fn bootstrap_failure_hang_artifact(
    bytes: &[u8],
    expected_nonce: &str,
) -> Result<Option<BootstrapHangArtifactReference>> {
    validate_bootstrap_failure_records(bytes, expected_nonce)?;
    let first = bytes
        .split(|byte| *byte == b'\n')
        .find(|record| !record.is_empty())
        .context("bootstrap failure checkpoint has no startup record")?;
    let record: BootstrapFailureCheckpointRecord = serde_json::from_slice(first)?;
    Ok(record.hang_diagnostic)
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

pub fn product_started_line(nonce: &str, evidence: &BootstrapLaunchEvidence) -> Result<String> {
    evidence.validate_started(nonce, &evidence.bootstrap_sha256)?;
    let payload = serde_json::to_string(evidence)?;
    let line = format!("PRODUCT_STARTED {nonce} {payload}\n");
    if line.len() > MAX_PRODUCT_STARTED_LINE_BYTES {
        bail!("supervisor product-started line exceeded its bound");
    }
    Ok(line)
}

pub fn parse_product_started_line(
    line: &str,
    nonce: &str,
    expected_bootstrap_sha256: Option<&str>,
) -> Result<BootstrapLaunchEvidence> {
    if line.len() > MAX_PRODUCT_STARTED_LINE_BYTES {
        bail!("supervisor product-started line exceeded its bound");
    }
    let prefix = format!("PRODUCT_STARTED {nonce} ");
    let payload =
        line.strip_prefix(&prefix).context("supervisor product-started line identity mismatch")?;
    let evidence: BootstrapLaunchEvidence = serde_json::from_str(payload)?;
    let expected_bootstrap_sha256 = expected_bootstrap_sha256.unwrap_or(&evidence.bootstrap_sha256);
    evidence.validate_started(nonce, expected_bootstrap_sha256)?;
    if product_started_line(nonce, &evidence)?.trim_end() != line {
        bail!("supervisor product-started line was not canonical");
    }
    Ok(evidence)
}

pub fn product_exit_line(nonce: &str, code: u32) -> Result<String> {
    decode_nonce(nonce).context("product-exit nonce is invalid")?;
    Ok(format!("PRODUCT_EXIT {nonce} {code}\n"))
}

#[cfg(windows)]
pub fn parse_product_exit_line(line: &str, nonce: &str) -> Result<u32> {
    decode_nonce(nonce).context("product-exit nonce is invalid")?;
    let prefix = format!("PRODUCT_EXIT {nonce} ");
    let code = line
        .strip_prefix(&prefix)
        .context("product-exit line identity mismatch")?
        .parse::<u32>()
        .context("product-exit code is invalid")?;
    if product_exit_line(nonce, code)?.trim_end() != line {
        bail!("product-exit line is not canonical");
    }
    Ok(code)
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
    read_bounded_control_line(reader, 256, "control")
}

pub fn read_product_started_control_line(reader: &mut impl Read) -> Result<String> {
    read_bounded_control_line(reader, MAX_PRODUCT_STARTED_LINE_BYTES, "product-started control")
}

fn read_bounded_control_line(
    reader: &mut impl Read,
    bound: usize,
    description: &str,
) -> Result<String> {
    let mut bytes = Vec::with_capacity(bound.min(256));
    let mut byte = [0_u8; 1];
    while bytes.len() < bound {
        reader.read_exact(&mut byte)?;
        if byte[0] == b'\n' {
            return String::from_utf8(bytes)
                .with_context(|| format!("{description} line was not UTF-8"));
        }
        bytes.push(byte[0]);
    }
    bail!("{description} line exceeded its bound")
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

    fn sample_hang_report() -> BootstrapHangDiagnosticReport {
        BootstrapHangDiagnosticReport {
            schema_version: 1,
            nonce: "ab".repeat(NONCE_BYTES),
            process_id: 41,
            primary_thread_id: 42,
            suspended_previous_count: 0,
            context: BootstrapHangThreadContext {
                instruction_pointer: 0x1010,
                stack_pointer: 0x2000,
                module_path: Some(r"C:\Windows\System32\ntdll.dll".into()),
                module_base_address: Some(0x1000),
                module_offset: Some(0x10),
                owner_source: Some("module-map".into()),
                mapping_windows_error: None,
                instruction_window: BootstrapHangInstructionWindow {
                    start_address: 0x1008,
                    bytes_hex: Some("00112233".into()),
                    windows_error: None,
                },
            },
            modules: vec![BootstrapHangModule {
                base_address: 0x1000,
                size: 0x100,
                path: r"C:\Windows\System32\ntdll.dll".into(),
            }],
            module_map_windows_error: None,
            wait_chain: BootstrapHangWaitChain {
                captured: true,
                cycle: false,
                windows_error: None,
                nodes: vec![BootstrapHangWaitChainNode {
                    object_type: 8,
                    object_status: 3,
                    process_id: Some(41),
                    thread_id: Some(42),
                    object_name: None,
                }],
            },
            dump_name: "bootstrap-hang-ab.dmp".into(),
            dump_sha256: "12".repeat(32),
            dump_bytes: 4_096,
            cmux_bench_environment_filtered: true,
            helper_cmux_bench_environment_filtered: true,
        }
    }

    fn bootstrap_failure_records(
        hang_diagnostic: Option<&BootstrapHangArtifactReference>,
        hang_diagnostic_error: Option<&str>,
    ) -> Vec<u8> {
        let trace = BootstrapStartupTrace::new();
        let containment = BootstrapCleanupResult::completed();
        let bootstrap = BootstrapCleanupResult::completed();
        let failure = BootstrapFailureCheckpoint {
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
            record_type: "startup-failure",
            nonce: "nonce",
            reason: "bootstrap exited",
            config_present_after_failure: false,
            trace: &trace,
            product_lifecycle: None,
            hang_diagnostic,
            hang_diagnostic_error,
        };
        let cleanup = BootstrapCleanupCheckpoint {
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
            record_type: "cleanup-result",
            nonce: "nonce",
            containment_cleanup: &containment,
            bootstrap_cleanup: &bootstrap,
        };
        let mut records = serde_json::to_vec(&failure).unwrap();
        records.push(b'\n');
        records.extend(serde_json::to_vec(&cleanup).unwrap());
        records.push(b'\n');
        records
    }

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
    fn product_started_line_is_bounded_nonce_bound_and_canonical() {
        let nonce = "ab".repeat(NONCE_BYTES);
        let bootstrap_sha256 = "cd".repeat(32);
        let evidence = BootstrapLaunchEvidence {
            schema_version: cmux_startup_bootstrap::BOOTSTRAP_SCHEMA_VERSION,
            bootstrap_sha256: bootstrap_sha256.clone(),
            config_nonce: nonce.clone(),
            config_consumed: true,
            resume_previous_count: 1,
            ready_elapsed_ms: 1,
            exact_job_proof: true,
            trusted_path_write_denied: true,
            bootstrap_write_denied: true,
            restricting_sid: "S-1-5-21-1-2-3-4".into(),
            broker_authentication_id: "0000000900000007".into(),
            restricted_authentication_id: "0000000900000007".into(),
            product_authentication_id: "0000000900000007".into(),
            restricted_authentication_matches_broker: true,
            product_authentication_matches_broker: true,
            se_increase_quota_present: true,
            se_increase_quota_enabled: true,
            create_process_as_user_succeeded: true,
            restricted_token_write_restricted: true,
            restricted_token_restricting_sid_match: true,
            restricted_token_low_integrity: true,
            restricted_token_no_enabled_privileges: true,
            product_write_restricted: true,
            product_restricting_sid_match: true,
            product_low_integrity: true,
            product_no_enabled_privileges: true,
            product_exact_job: true,
            product_resume_previous_count: 1,
            product_process_id: 41,
            product_primary_thread_id: 42,
            private_desktop: cmux_startup_bootstrap::private_desktop_name(&nonce).unwrap(),
            private_window_station_created: true,
            private_desktop_created: true,
            private_desktop_broker_assigned: true,
            private_desktop_product_assigned: true,
            private_desktop_closed_after_job_empty: false,
        };
        let line = product_started_line(&nonce, &evidence).unwrap();
        let canonical = line.strip_suffix('\n').unwrap();
        assert_eq!(
            parse_product_started_line(canonical, &nonce, Some(&bootstrap_sha256)).unwrap(),
            evidence
        );
        assert!(
            parse_product_started_line(
                canonical,
                &"ef".repeat(NONCE_BYTES),
                Some(&bootstrap_sha256)
            )
            .is_err()
        );
        assert!(
            parse_product_started_line(&format!("{canonical} "), &nonce, Some(&bootstrap_sha256))
                .is_err()
        );
    }

    #[test]
    #[cfg(windows)]
    fn product_exit_line_is_nonce_bound_and_canonical() {
        let nonce = "ab".repeat(NONCE_BYTES);
        let line = product_exit_line(&nonce, 125).unwrap();

        assert_eq!(parse_product_exit_line(line.trim_end(), &nonce).unwrap(), 125);
        assert!(parse_product_exit_line(line.trim_end(), &"cd".repeat(NONCE_BYTES)).is_err());
        assert!(parse_product_exit_line(&format!("PRODUCT_EXIT {nonce} 0125"), &nonce).is_err());
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
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
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
        let records = bootstrap_failure_records(None, None);

        validate_bootstrap_failure_records(&records, "nonce").unwrap();
        assert!(validate_bootstrap_failure_records(&records, "different").is_err());
        assert!(bootstrap_failure_hang_artifact(&records, "nonce").unwrap().is_none());
    }

    #[test]
    fn bootstrap_checkpoint_preserves_product_lifecycle_and_controller_tail() {
        let mut records = bootstrap_failure_records(None, None);
        let first_newline = records.iter().position(|byte| *byte == b'\n').unwrap();
        let mut first: serde_json::Value =
            serde_json::from_slice(&records[..first_newline]).unwrap();
        first["product_lifecycle"] = serde_json::json!({
            "product_process_id": 41,
            "product_primary_thread_id": 42,
            "native_exit_received": false,
            "native_exit_code": null
        });
        let mut with_lifecycle = serde_json::to_vec(&first).unwrap();
        with_lifecycle.extend_from_slice(&records[first_newline..]);
        let observation = BootstrapControllerFailureObservation {
            schema_version: BOOTSTRAP_FAILURE_SCHEMA_VERSION,
            record_type: "controller-observation".into(),
            nonce: "nonce".into(),
            raw_stdout_tail_hex: "1b5b366e".into(),
            raw_stdout_tail_bytes: 4,
            complete_stdout_lines: 0,
            stdout_closed: true,
            stdout_error: Some("product stdout closed with a partial line".into()),
        };
        with_lifecycle.extend(serde_json::to_vec(&observation).unwrap());
        with_lifecycle.push(b'\n');

        validate_bootstrap_failure_records(&with_lifecycle, "nonce").unwrap();

        let lifecycle_newline = with_lifecycle.iter().position(|byte| *byte == b'\n').unwrap();
        first["unexpected"] = serde_json::Value::Bool(true);
        records = serde_json::to_vec(&first).unwrap();
        records.extend_from_slice(&with_lifecycle[lifecycle_newline..]);
        assert!(validate_bootstrap_failure_records(&records, "nonce").is_err());
    }

    #[test]
    fn bootstrap_checkpoint_rejects_mismatched_native_exit_state() {
        let records = bootstrap_failure_records(None, None);
        let first_newline = records.iter().position(|byte| *byte == b'\n').unwrap();
        let mut first: serde_json::Value =
            serde_json::from_slice(&records[..first_newline]).unwrap();
        first["product_lifecycle"] = serde_json::json!({
            "product_process_id": 41,
            "product_primary_thread_id": 42,
            "native_exit_received": false,
            "native_exit_code": 125
        });
        let mut invalid = serde_json::to_vec(&first).unwrap();
        invalid.extend_from_slice(&records[first_newline..]);

        assert!(validate_bootstrap_failure_records(&invalid, "nonce").is_err());
    }

    #[test]
    fn bootstrap_checkpoint_round_trip_preserves_hang_diagnostic_result() {
        let reference = BootstrapHangArtifactReference {
            report_name: "bootstrap-hang-ab.json".into(),
            report_sha256: "12".repeat(32),
            report_bytes: 4_096,
            dump_name: "bootstrap-hang-ab.dmp".into(),
            dump_sha256: "34".repeat(32),
            dump_bytes: 8_192,
        };
        let records = bootstrap_failure_records(Some(&reference), None);

        validate_bootstrap_failure_records(&records, "nonce").unwrap();
        let decoded = bootstrap_failure_hang_artifact(&records, "nonce").unwrap().unwrap();
        assert_eq!(decoded.report_name, reference.report_name);
        assert_eq!(decoded.dump_sha256, reference.dump_sha256);
    }

    #[test]
    fn bootstrap_checkpoint_round_trip_preserves_hang_diagnostic_error() {
        let records = bootstrap_failure_records(None, Some("diagnostic helper timed out"));

        validate_bootstrap_failure_records(&records, "nonce").unwrap();
        assert!(bootstrap_failure_hang_artifact(&records, "nonce").unwrap().is_none());
    }

    #[test]
    fn bootstrap_checkpoint_treats_null_diagnostic_fields_as_absent() {
        let mut records = bootstrap_failure_records(None, None);
        let first_newline = records.iter().position(|byte| *byte == b'\n').unwrap();
        let mut first: serde_json::Value =
            serde_json::from_slice(&records[..first_newline]).unwrap();
        first["hang_diagnostic"] = serde_json::Value::Null;
        first["hang_diagnostic_error"] = serde_json::Value::Null;
        let mut with_nulls = serde_json::to_vec(&first).unwrap();
        with_nulls.extend_from_slice(&records[first_newline..]);

        validate_bootstrap_failure_records(&with_nulls, "nonce").unwrap();
        assert!(bootstrap_failure_hang_artifact(&with_nulls, "nonce").unwrap().is_none());

        let reference = BootstrapHangArtifactReference {
            report_name: "bootstrap-hang-ab.json".into(),
            report_sha256: "12".repeat(32),
            report_bytes: 4_096,
            dump_name: "bootstrap-hang-ab.dmp".into(),
            dump_sha256: "34".repeat(32),
            dump_bytes: 8_192,
        };
        records = bootstrap_failure_records(Some(&reference), Some("capture failed"));
        assert!(validate_bootstrap_failure_records(&records, "nonce").is_err());
    }

    #[test]
    fn bootstrap_hang_report_requires_bounded_nonce_bound_owner_evidence() {
        let report = sample_hang_report();

        report.validate(&report.nonce).unwrap();
        assert!(report.validate(&"cd".repeat(NONCE_BYTES)).is_err());

        let mut invalid_window = sample_hang_report();
        invalid_window.context.instruction_window.windows_error = Some(5);
        assert!(invalid_window.validate(&invalid_window.nonce).is_err());

        let mut oversized_modules = sample_hang_report();
        oversized_modules.modules = vec![oversized_modules.modules[0].clone(); 257];
        assert!(oversized_modules.validate(&oversized_modules.nonce).is_err());

        let mut module_map_failed = sample_hang_report();
        module_map_failed.modules.clear();
        module_map_failed.module_map_windows_error = Some(299);
        module_map_failed.context.module_path = None;
        module_map_failed.context.module_base_address = None;
        module_map_failed.context.module_offset = None;
        module_map_failed.context.owner_source = None;
        module_map_failed.context.mapping_windows_error = Some(299);
        module_map_failed.validate(&module_map_failed.nonce).unwrap();
    }

    #[test]
    fn bootstrap_hang_artifact_reference_rejects_unsafe_names_and_sizes() {
        let mut reference = BootstrapHangArtifactReference {
            report_name: "bootstrap-hang-ab.json".into(),
            report_sha256: "12".repeat(32),
            report_bytes: 4_096,
            dump_name: "bootstrap-hang-ab.dmp".into(),
            dump_sha256: "34".repeat(32),
            dump_bytes: 8_192,
        };
        reference.validate().unwrap();

        reference.dump_name = "../outside.dmp".into();
        assert!(reference.validate().is_err());
        reference.dump_name = "bootstrap-hang-ab.dmp".into();
        reference.dump_bytes = MAX_BOOTSTRAP_HANG_DUMP_BYTES + 1;
        assert!(reference.validate().is_err());
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
