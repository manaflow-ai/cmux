use std::collections::BTreeMap;
#[cfg(target_os = "linux")]
use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;

use super::{Args, Evidence, Scenario, Target, TargetKind};

const METADATA_COMMAND_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug, Serialize)]
pub struct ComparisonReport {
    pub schema_version: u32,
    pub generated_at_unix_ms: u128,
    pub platform_label: String,
    pub warmups: usize,
    pub paired_samples: usize,
    pub order: &'static str,
    pub infrastructure: InfrastructureMetadata,
    pub host: HostMetadata,
    pub baseline: TargetMetadata,
    pub candidate: TargetMetadata,
    pub scenarios: Vec<ScenarioReport>,
}

#[derive(Debug, Serialize)]
pub struct ProfileReport {
    pub schema_version: u32,
    pub generated_at_unix_ms: u128,
    pub platform_label: String,
    pub target: TargetKind,
    pub scenario: Scenario,
    pub duration_ns: u64,
    pub evidence: Evidence,
    pub infrastructure: InfrastructureMetadata,
    pub host: HostMetadata,
    pub binary: TargetMetadata,
}

#[derive(Debug, Serialize)]
pub struct ScenarioReport {
    pub scenario: Scenario,
    pub event: &'static str,
    pub baseline: SampleSet,
    pub candidate: SampleSet,
    pub pairs: Vec<Pair>,
    pub paired_delta_summary_ns: SignedSummary,
}

#[derive(Debug, Serialize)]
pub struct SampleSet {
    pub ordered_ns: Vec<u64>,
    pub sorted_ns: Vec<u64>,
    pub summary_ns: Summary,
    pub evidence: Evidence,
}

impl SampleSet {
    pub fn new(ordered_ns: Vec<u64>, evidence: Evidence) -> Result<Self> {
        let mut sorted_ns = ordered_ns.clone();
        sorted_ns.sort_unstable();
        let summary_ns = Summary::from_sorted(&sorted_ns)?;
        Ok(Self { ordered_ns, sorted_ns, summary_ns, evidence })
    }
}

#[derive(Debug, Serialize)]
pub struct Pair {
    pub index: usize,
    pub first: TargetKind,
    pub baseline_ns: u64,
    pub candidate_ns: u64,
    pub candidate_minus_baseline_ns: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Summary {
    pub count: usize,
    pub min: u64,
    pub mean: f64,
    pub stddev_population: f64,
    pub mad: f64,
    pub p50: u64,
    pub p90: u64,
    pub p95: u64,
    pub p99: u64,
    pub max: u64,
}

impl Summary {
    fn from_sorted(values: &[u64]) -> Result<Self> {
        if values.is_empty() {
            bail!("cannot summarize an empty sample set");
        }
        let mean = values.iter().map(|value| *value as f64).sum::<f64>() / values.len() as f64;
        let variance = values
            .iter()
            .map(|value| {
                let delta = *value as f64 - mean;
                delta * delta
            })
            .sum::<f64>()
            / values.len() as f64;
        let values_f64 = values.iter().map(|value| *value as f64).collect::<Vec<_>>();
        let median = median_f64(&values_f64);
        let mut deviations =
            values.iter().map(|value| (*value as f64 - median).abs()).collect::<Vec<_>>();
        deviations.sort_by(f64::total_cmp);
        let mad = median_f64(&deviations);
        Ok(Self {
            count: values.len(),
            min: values[0],
            mean,
            stddev_population: variance.sqrt(),
            mad,
            p50: percentile(values, 50),
            p90: percentile(values, 90),
            p95: percentile(values, 95),
            p99: percentile(values, 99),
            max: values[values.len() - 1],
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct SignedSummary {
    pub count: usize,
    pub min: i64,
    pub mean: f64,
    pub stddev_population: f64,
    pub mad: f64,
    pub p50: i64,
    pub p90: i64,
    pub p95: i64,
    pub p99: i64,
    pub max: i64,
}

impl SignedSummary {
    pub fn new(values: &[i64]) -> Result<Self> {
        if values.is_empty() {
            bail!("cannot summarize empty paired deltas");
        }
        let mut sorted = values.to_vec();
        sorted.sort_unstable();
        let mean = sorted.iter().map(|value| *value as f64).sum::<f64>() / sorted.len() as f64;
        let variance = sorted
            .iter()
            .map(|value| {
                let delta = *value as f64 - mean;
                delta * delta
            })
            .sum::<f64>()
            / sorted.len() as f64;
        let sorted_f64 = sorted.iter().map(|value| *value as f64).collect::<Vec<_>>();
        let median = median_f64(&sorted_f64);
        let mut deviations =
            sorted.iter().map(|value| (*value as f64 - median).abs()).collect::<Vec<_>>();
        deviations.sort_by(f64::total_cmp);
        Ok(Self {
            count: sorted.len(),
            min: sorted[0],
            mean,
            stddev_population: variance.sqrt(),
            mad: median_f64(&deviations),
            p50: percentile_signed(&sorted, 50),
            p90: percentile_signed(&sorted, 90),
            p95: percentile_signed(&sorted, 95),
            p99: percentile_signed(&sorted, 99),
            max: sorted[sorted.len() - 1],
        })
    }
}

fn percentile(values: &[u64], percentile: usize) -> u64 {
    values[nearest_rank(values.len(), percentile)]
}

fn percentile_signed(values: &[i64], percentile: usize) -> i64 {
    values[nearest_rank(values.len(), percentile)]
}

fn nearest_rank(count: usize, percentile: usize) -> usize {
    (count * percentile).div_ceil(100).saturating_sub(1).min(count - 1)
}

fn median_f64(values: &[f64]) -> f64 {
    let midpoint = values.len() / 2;
    if values.len().is_multiple_of(2) {
        (values[midpoint - 1] + values[midpoint]) / 2.0
    } else {
        values[midpoint]
    }
}

#[derive(Debug, Serialize)]
pub struct TargetMetadata {
    pub kind: TargetKind,
    pub requested_sha: String,
    pub observed_sha: String,
    pub ghostty_sha: String,
    pub zig_version: String,
    pub rust_toolchain: String,
    pub source: String,
    pub binary: String,
    pub expected_binary_sha256: String,
    pub binary_sha256: String,
    pub binary_bytes: u64,
    pub embedded_identity_verified: bool,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct InfrastructureMetadata {
    pub trusted_sha: String,
    pub trusted_source: String,
    pub sandbox_backend: String,
    pub sandbox_policy: String,
    pub sandbox_handshake: String,
    pub sandbox_cleanup: String,
    pub supervisor_binary: String,
    pub expected_supervisor_sha256: String,
    pub supervisor_sha256: String,
    pub supervisor_bytes: u64,
    pub windows_bootstrap_binary: Option<String>,
    pub expected_windows_bootstrap_sha256: Option<String>,
    pub windows_bootstrap_sha256: Option<String>,
    pub windows_bootstrap_bytes: Option<u64>,
    pub preflight_evidence: String,
    pub expected_preflight_sha256: String,
    pub preflight_sha256: String,
    pub preflight_bytes: u64,
}

impl InfrastructureMetadata {
    pub fn collect(args: &Args) -> Result<Self> {
        let supervisor = fs::read(&args.supervisor_binary)?;
        let preflight = fs::read(&args.sandbox_preflight)?;
        let supervisor_sha256 = format!("{:x}", Sha256::digest(&supervisor));
        if supervisor_sha256 != args.supervisor_binary_sha256 {
            bail!("supervisor changed after argument validation");
        }
        let preflight_sha256 = format!("{:x}", Sha256::digest(&preflight));
        if preflight_sha256 != args.sandbox_preflight_sha256 {
            bail!("sandbox preflight evidence changed after argument validation");
        }
        let evidence: SandboxPreflightEvidence = serde_json::from_slice(&preflight)
            .context("sandbox preflight evidence was not valid JSON")?;
        evidence.validate(
            &args.sandbox_backend,
            &supervisor_sha256,
            (!args.windows_bootstrap_sha256.is_empty())
                .then_some(args.windows_bootstrap_sha256.as_str()),
        )?;
        #[cfg(windows)]
        let bootstrap = Some(fs::read(&args.windows_bootstrap_binary)?);
        #[cfg(not(windows))]
        let bootstrap: Option<Vec<u8>> = None;
        let windows_bootstrap_sha256 =
            bootstrap.as_ref().map(|bytes| format!("{:x}", Sha256::digest(bytes)));
        #[cfg(windows)]
        if windows_bootstrap_sha256.as_deref() != Some(args.windows_bootstrap_sha256.as_str()) {
            bail!("dedicated Windows bootstrap changed after argument validation");
        }
        Ok(Self {
            trusted_sha: args.trusted_sha.clone(),
            trusted_source: args.trusted_source.display().to_string(),
            sandbox_backend: args.sandbox_backend.clone(),
            sandbox_policy: evidence.policy,
            sandbox_handshake: evidence.handshake,
            sandbox_cleanup: evidence.cleanup,
            supervisor_binary: args.supervisor_binary.display().to_string(),
            expected_supervisor_sha256: args.supervisor_binary_sha256.clone(),
            supervisor_sha256,
            supervisor_bytes: supervisor.len() as u64,
            windows_bootstrap_binary: bootstrap
                .as_ref()
                .map(|_| args.windows_bootstrap_binary.display().to_string()),
            expected_windows_bootstrap_sha256: bootstrap
                .as_ref()
                .map(|_| args.windows_bootstrap_sha256.clone()),
            windows_bootstrap_sha256,
            windows_bootstrap_bytes: bootstrap.as_ref().map(|bytes| bytes.len() as u64),
            preflight_evidence: args.sandbox_preflight.display().to_string(),
            expected_preflight_sha256: args.sandbox_preflight_sha256.clone(),
            preflight_sha256,
            preflight_bytes: preflight.len() as u64,
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SandboxPreflightEvidence {
    schema_version: u32,
    backend: String,
    policy: String,
    handshake: String,
    cleanup: String,
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

impl SandboxPreflightEvidence {
    fn validate(
        &self,
        backend: &str,
        supervisor_sha256: &str,
        windows_bootstrap_sha256: Option<&str>,
    ) -> Result<()> {
        if self.schema_version != 8
            || self.backend != backend
            || self.policy != "fixture-root-only-write"
            || self.handshake != "nonce-bound-ready-arm-with-pre-exec-t0"
            || self.cleanup != "descendant-channel-eof-after-process-tree-empty"
            || !self.inside_write
            || !self.adjacent_write_denied
            || !self.descendant_adjacent_write_denied
            || !self.descendant_contained
            || !self.network_denied
            || !self.inbound_network_denied
            || !self.supervisor_ready
            || self.timing_records != 1
            || self.supervisor_sha256 != supervisor_sha256
        {
            bail!("sandbox preflight evidence did not prove the required containment policy");
        }
        let platform_proof = match backend {
            "linux-bwrap" => {
                self.linux_no_new_privs == Some(true)
                    && self.linux_effective_capabilities_zero == Some(true)
                    && self.linux_sudo_bwrap.is_some()
                    && self.linux_bwrap_version.as_ref().is_some_and(|value| !value.is_empty())
                    && self.windows_proofs_absent()
            }
            "macos-seatbelt" => {
                self.linux_no_new_privs.is_none()
                    && self.linux_effective_capabilities_zero.is_none()
                    && self.linux_provenance_absent()
                    && self.windows_proofs_absent()
            }
            "windows-restricted-token-job" => {
                // A missing native observation is a failed proof. Never treat unavailable
                // Windows signals as an implicit success.
                self.linux_no_new_privs.is_none()
                    && self.linux_effective_capabilities_zero.is_none()
                    && self.linux_provenance_absent()
                    && self.windows_low_integrity == Some(true)
                    && self.windows_no_enabled_privileges == Some(true)
                    && self.windows_registry_write_denied == Some(true)
                    && self.windows_grandchild_in_job == Some(true)
                    && self.windows_breakaway_denied == Some(true)
                    && self.windows_active_process_zero == Some(true)
                    && self.windows_caller_se_impersonate_enabled == Some(true)
                    && self.windows_standard_handles_valid == Some(true)
                    && self.windows_explicit_handle_list == Some(true)
                    && self.windows_bootstrap_sha256.as_deref() == windows_bootstrap_sha256
                    && self.windows_bootstrap_config_nonce.as_deref().is_some_and(|value| {
                        value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
                    })
                    && self.windows_bootstrap_config_consumed == Some(true)
                    && self.windows_bootstrap_resume_previous_count == Some(1)
                    && self
                        .windows_bootstrap_ready_elapsed_ms
                        .is_some_and(|elapsed| elapsed <= 30_000)
                    && self.windows_bootstrap_exact_job == Some(true)
                    && self.windows_bootstrap_trusted_path_write_denied == Some(true)
                    && self.windows_bootstrap_self_write_denied == Some(true)
                    && self
                        .windows_restricting_sid
                        .as_ref()
                        .is_some_and(|value| value.starts_with("S-1-") && value.len() <= 184)
                    && self.windows_broker_authentication_id.as_ref().is_some_and(|value| {
                        value.len() == 16 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
                    })
                    && self.windows_restricted_authentication_id
                        == self.windows_broker_authentication_id
                    && self.windows_product_authentication_id
                        == self.windows_broker_authentication_id
                    && self.windows_restricted_authentication_matches_broker == Some(true)
                    && self.windows_product_authentication_matches_broker == Some(true)
                    && self.windows_se_increase_quota_present == Some(true)
                    && self.windows_se_increase_quota_enabled == Some(true)
                    && self.windows_create_process_as_user_succeeded == Some(true)
                    && self.windows_restricted_token_write_restricted == Some(true)
                    && self.windows_restricted_token_restricting_sid_match == Some(true)
                    && self.windows_restricted_token_low_integrity == Some(true)
                    && self.windows_restricted_token_no_enabled_privileges == Some(true)
                    && self.windows_product_write_restricted == Some(true)
                    && self.windows_product_restricting_sid_match == Some(true)
                    && self.windows_product_low_integrity == Some(true)
                    && self.windows_product_no_enabled_privileges == Some(true)
                    && self.windows_product_exact_job == Some(true)
                    && self.windows_product_resume_previous_count == Some(1)
                    && self.windows_product_process_id.is_some_and(|value| value != 0)
                    && self.windows_product_primary_thread_id.is_some_and(|value| value != 0)
                    && self.windows_private_desktop.as_ref().is_some_and(|value| {
                        value.starts_with("cmuxb-")
                            && value.contains("\\desk-")
                            && value.len() == 60
                    })
                    && self.windows_private_window_station_created == Some(true)
                    && self.windows_private_desktop_created == Some(true)
                    && self.windows_private_desktop_broker_assigned == Some(true)
                    && self.windows_private_desktop_product_assigned == Some(true)
                    && self.windows_private_desktop_closed_after_job_empty == Some(true)
            }
            _ => false,
        };
        if !platform_proof {
            bail!("sandbox preflight evidence omitted a required platform security proof");
        }
        Ok(())
    }

    fn windows_proofs_absent(&self) -> bool {
        self.windows_low_integrity.is_none()
            && self.windows_no_enabled_privileges.is_none()
            && self.windows_registry_write_denied.is_none()
            && self.windows_grandchild_in_job.is_none()
            && self.windows_breakaway_denied.is_none()
            && self.windows_active_process_zero.is_none()
            && self.windows_caller_se_impersonate_enabled.is_none()
            && self.windows_standard_handles_valid.is_none()
            && self.windows_explicit_handle_list.is_none()
            && self.windows_bootstrap_sha256.is_none()
            && self.windows_bootstrap_config_nonce.is_none()
            && self.windows_bootstrap_config_consumed.is_none()
            && self.windows_bootstrap_resume_previous_count.is_none()
            && self.windows_bootstrap_ready_elapsed_ms.is_none()
            && self.windows_bootstrap_exact_job.is_none()
            && self.windows_bootstrap_trusted_path_write_denied.is_none()
            && self.windows_bootstrap_self_write_denied.is_none()
            && self.windows_restricting_sid.is_none()
            && self.windows_broker_authentication_id.is_none()
            && self.windows_restricted_authentication_id.is_none()
            && self.windows_product_authentication_id.is_none()
            && self.windows_restricted_authentication_matches_broker.is_none()
            && self.windows_product_authentication_matches_broker.is_none()
            && self.windows_se_increase_quota_present.is_none()
            && self.windows_se_increase_quota_enabled.is_none()
            && self.windows_create_process_as_user_succeeded.is_none()
            && self.windows_restricted_token_write_restricted.is_none()
            && self.windows_restricted_token_restricting_sid_match.is_none()
            && self.windows_restricted_token_low_integrity.is_none()
            && self.windows_restricted_token_no_enabled_privileges.is_none()
            && self.windows_product_write_restricted.is_none()
            && self.windows_product_restricting_sid_match.is_none()
            && self.windows_product_low_integrity.is_none()
            && self.windows_product_no_enabled_privileges.is_none()
            && self.windows_product_exact_job.is_none()
            && self.windows_product_resume_previous_count.is_none()
            && self.windows_product_process_id.is_none()
            && self.windows_product_primary_thread_id.is_none()
            && self.windows_private_desktop.is_none()
            && self.windows_private_window_station_created.is_none()
            && self.windows_private_desktop_created.is_none()
            && self.windows_private_desktop_broker_assigned.is_none()
            && self.windows_private_desktop_product_assigned.is_none()
            && self.windows_private_desktop_closed_after_job_empty.is_none()
    }

    fn linux_provenance_absent(&self) -> bool {
        self.linux_bwrap_version.is_none()
            && self.linux_sudo_bwrap.is_none()
            && self.linux_unprivileged_userns_clone.is_none()
            && self.linux_max_user_namespaces.is_none()
    }
}

impl TargetMetadata {
    pub fn collect(target: &Target) -> Result<Self> {
        let bytes = fs::read(&target.binary)
            .with_context(|| format!("read {}", target.binary.display()))?;
        let binary_sha256 = format!("{:x}", Sha256::digest(&bytes));
        Ok(Self {
            kind: target.kind,
            requested_sha: target.sha.clone(),
            observed_sha: target.observed_sha.clone(),
            ghostty_sha: target.ghostty_sha.clone(),
            zig_version: target.zig_version.clone(),
            rust_toolchain: target.rust_toolchain.clone(),
            source: target.source.display().to_string(),
            binary: target.binary.display().to_string(),
            expected_binary_sha256: target.expected_binary_sha256.clone(),
            binary_sha256,
            binary_bytes: bytes.len() as u64,
            embedded_identity_verified: target.embedded_identity_verified,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct HostMetadata {
    pub os: &'static str,
    pub arch: &'static str,
    pub family: &'static str,
    pub cpu: String,
    pub logical_processors: usize,
    pub physical_cores: Option<usize>,
    pub memory_bytes: Option<u64>,
    pub kernel: String,
    pub rustc: String,
    pub cargo: String,
    pub zig: String,
    pub ci: BTreeMap<String, String>,
}

impl HostMetadata {
    pub fn collect() -> Self {
        let logical_processors =
            std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get);
        let (cpu, memory_bytes, kernel) = platform_metadata();
        let ci = [
            "CMUX_BENCHMARK_RUN_ID",
            "CMUX_BENCHMARK_RUN_ATTEMPT",
            "CMUX_BENCHMARK_RUNNER_NAME",
            "CMUX_BENCHMARK_RUNNER_OS",
            "CMUX_BENCHMARK_RUNNER_ARCH",
            "CMUX_BENCHMARK_IMAGE_OS",
            "CMUX_BENCHMARK_IMAGE_VERSION",
            "CMUX_BENCHMARK_WORKFLOW_REF",
        ]
        .into_iter()
        .filter_map(|key| env::var(key).ok().map(|value| (key.to_string(), value)))
        .collect();
        Self {
            os: env::consts::OS,
            arch: env::consts::ARCH,
            family: env::consts::FAMILY,
            cpu,
            logical_processors,
            physical_cores: physical_core_count(),
            memory_bytes,
            kernel,
            rustc: command_text("rustc", &["--version", "--verbose"]),
            cargo: command_text("cargo", &["--version", "--verbose"]),
            zig: command_text("zig", &["version"]),
            ci,
        }
    }
}

#[cfg(target_os = "macos")]
fn platform_metadata() -> (String, Option<u64>, String) {
    let mut cpu = command_text("sysctl", &["-n", "machdep.cpu.brand_string"]);
    if cpu == "unavailable" {
        cpu = command_text("sysctl", &["-n", "hw.model"]);
    }
    let memory = command_text("sysctl", &["-n", "hw.memsize"]).trim().parse().ok();
    (cpu, memory, command_text("uname", &["-a"]))
}

#[cfg(target_os = "linux")]
fn platform_metadata() -> (String, Option<u64>, String) {
    let cpu = fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|line| {
                    line.strip_prefix("model name").and_then(|line| line.split_once(':'))
                })
                .map(|(_, value)| value.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string());
    let memory = fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                line.strip_prefix("MemTotal:")?.split_whitespace().next()?.parse::<u64>().ok()
            })
        })
        .and_then(|kilobytes| kilobytes.checked_mul(1024));
    (cpu, memory, command_text("uname", &["-a"]))
}

#[cfg(target_os = "windows")]
fn platform_metadata() -> (String, Option<u64>, String) {
    let cpu = command_text(
        "powershell.exe",
        &[
            "-NoProfile",
            "-Command",
            "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)",
        ],
    );
    let memory = command_text(
        "powershell.exe",
        &["-NoProfile", "-Command", "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory"],
    )
    .trim()
    .parse()
    .ok();
    let kernel = command_text(
        "powershell.exe",
        &["-NoProfile", "-Command", "[System.Environment]::OSVersion.VersionString"],
    );
    (cpu, memory, kernel)
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn platform_metadata() -> (String, Option<u64>, String) {
    ("unknown".to_string(), None, "unknown".to_string())
}

fn command_text(program: &str, args: &[&str]) -> String {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let Ok(mut child) = command.spawn() else {
        return "unavailable".to_string();
    };
    let status = match child.wait_timeout(METADATA_COMMAND_TIMEOUT) {
        Ok(Some(status)) => status,
        Ok(None) | Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            return "unavailable".to_string();
        }
    };
    if !status.success() {
        return "unavailable".to_string();
    }
    let mut output = Vec::new();
    child
        .stdout
        .take()
        .and_then(|mut stdout| stdout.read_to_end(&mut output).ok())
        .and_then(|_| String::from_utf8(output).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unavailable".to_string())
}

#[cfg(target_os = "macos")]
fn physical_core_count() -> Option<usize> {
    command_text("sysctl", &["-n", "hw.physicalcpu"]).trim().parse().ok()
}

#[cfg(target_os = "linux")]
fn physical_core_count() -> Option<usize> {
    let output = command_text("lscpu", &["-p=CORE,SOCKET"]);
    let cores = output
        .lines()
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| line.split_once(','))
        .map(|(core, socket)| (core.to_string(), socket.to_string()))
        .collect::<BTreeSet<_>>();
    (!cores.is_empty()).then_some(cores.len())
}

#[cfg(target_os = "windows")]
fn physical_core_count() -> Option<usize> {
    command_text(
        "powershell.exe",
        &[
            "-NoProfile",
            "-Command",
            "(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum",
        ],
    )
    .trim()
    .parse()
    .ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn physical_core_count() -> Option<usize> {
    None
}

pub fn now_unix_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summary_uses_nearest_rank_percentiles_and_population_spread() {
        let summary = Summary::from_sorted(&[1, 2, 3, 4, 100]).unwrap();
        assert_eq!(summary.count, 5);
        assert_eq!(summary.p50, 3);
        assert_eq!(summary.p90, 100);
        assert_eq!(summary.p99, 100);
        assert_eq!(summary.min, 1);
        assert_eq!(summary.max, 100);
        assert!(summary.stddev_population > 38.0);
    }

    #[test]
    fn signed_summary_preserves_candidate_minus_baseline_direction() {
        let summary = SignedSummary::new(&[-10, -2, 3, 8]).unwrap();
        assert_eq!(summary.min, -10);
        assert_eq!(summary.p50, -2);
        assert_eq!(summary.max, 8);
    }

    #[test]
    fn even_sized_mad_uses_the_arithmetic_median_as_its_center() {
        let unsigned = Summary::from_sorted(&[0, 0, 1, 2, 2, 2]).unwrap();
        let signed = SignedSummary::new(&[-2, -2, -1, 0, 0, 0]).unwrap();

        assert_eq!(unsigned.mad, 0.5);
        assert_eq!(signed.mad, 0.5);
    }
}
