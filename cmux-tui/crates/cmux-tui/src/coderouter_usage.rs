//! Machine spend readout for cmux Cloud VMs.
//!
//! A Cloud VM daemon learns its coderouter identity from the model-plane env
//! (`CMUX_CODEROUTER_URL` and `CMUX_VM_ID`; see [`machine_source`] for where
//! each comes from) and polls
//! `GET {url}/api/coderouter/vm-usage/self` at a low cadence. The Freestyle
//! edge injects the real credential; the guest only sends a public
//! placeholder bearer. The latest totals land in the mux as
//! [`MachineUsage`], which the protocol exposes through `machine-usage` and
//! `machine-usage-changed`.
//!
//! The endpoint may not exist yet, may reject the machine, or may be
//! unreachable. Every one of those degrades to "no readout" and logs at most
//! one debug line per state change, so a missing backend never spams the
//! daemon log.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_tui_core::{MachineUsage, Mux};
use serde::Deserialize;
use tokio::sync::Notify;

pub(crate) const CODEROUTER_URL_VAR: &str = "CMUX_CODEROUTER_URL";
pub(crate) const VM_ID_VAR: &str = "CMUX_VM_ID";
const ENV_FILE_RELATIVE_PATH: &str = ".config/cmux/model-plane.env";
/// The model-plane env every Cloud image bakes (`/etc/cmux/model-plane.env`,
/// web/services/coderouter/vmGuestEnv.ts): the same bytes on every machine,
/// so it carries the coderouter origin but no `CMUX_VM_ID`.
const IMAGE_ENV_FILE: &str = "model-plane.env";
/// The instance id the bind agent wrote for this machine before it started
/// the daemon (`/etc/cmux/daemon-instance-id`, cmux-host `BOUND_INSTANCE_FILE`).
const BOUND_INSTANCE_FILE: &str = "daemon-instance-id";
/// Longest instance id read.
const MAX_INSTANCE_ID_BYTES: usize = 128;
const USAGE_PATH: &str = "/api/coderouter/vm-usage/self";
/// The guest never holds a credential; the edge replaces this bearer.
const PLACEHOLDER_BEARER: &str = "cmux-vm-edge-placeholder";
const STARTUP_DELAY: Duration = Duration::from_secs(5);
const POLL_INTERVAL: Duration = Duration::from_secs(5 * 60);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_BODY_BYTES: usize = 64 * 1024;
const LOG_AREA: &str = "machine-usage";

/// Where the readout comes from: the coderouter origin and this VM's id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct UsageSource {
    pub coderouter_url: String,
    pub vm_id: String,
}

impl UsageSource {
    pub(crate) fn usage_url(&self) -> String {
        format!("{}{USAGE_PATH}", self.coderouter_url.trim_end_matches('/'))
    }
}

/// Parse the `export KEY='value'` lines the model-plane env file uses.
///
/// Accepts an optional `export ` prefix, single-quoted values with the
/// POSIX `'\''` escape, double-quoted values with backslash escapes, and
/// bare values. Blank lines and `#` comments are skipped; a malformed line
/// is ignored rather than failing the whole file, so one odd entry cannot
/// hide the two keys this module needs.
pub(crate) fn parse_env_exports(contents: &str) -> BTreeMap<String, String> {
    let mut values = BTreeMap::new();
    for raw_line in contents.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").map_or(line, str::trim_start);
        let Some((key, value)) = line.split_once('=') else { continue };
        let key = key.trim();
        if key.is_empty()
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            || key.starts_with(|c: char| c.is_ascii_digit())
        {
            continue;
        }
        let Some(value) = parse_shell_value(value.trim()) else { continue };
        values.insert(key.to_string(), value);
    }
    values
}

fn parse_shell_value(raw: &str) -> Option<String> {
    let mut chars = raw.chars().peekable();
    let mut out = String::new();
    while let Some(c) = chars.next() {
        match c {
            '\'' => loop {
                match chars.next() {
                    Some('\'') => break,
                    Some(c) => out.push(c),
                    None => return None,
                }
            },
            '"' => loop {
                match chars.next() {
                    Some('"') => break,
                    Some('\\') => match chars.next() {
                        Some(escaped @ ('"' | '\\' | '$' | '`')) => out.push(escaped),
                        Some(other) => {
                            out.push('\\');
                            out.push(other);
                        }
                        None => return None,
                    },
                    Some(c) => out.push(c),
                    None => return None,
                }
            },
            '\\' => out.push(chars.next()?),
            '#' if out.is_empty() => return None,
            c if c.is_whitespace() => break,
            c => out.push(c),
        }
    }
    Some(out)
}

/// Resolve the usage source from the process environment first, then from
/// the env file. Each key resolves independently so a daemon started with
/// only one of the two in its environment still finds the other in the file.
#[cfg(test)]
pub(crate) fn resolve_source(
    env: impl Fn(&str) -> Option<String>,
    env_file: Option<&str>,
) -> Option<UsageSource> {
    resolve_layered_source(env, &[env_file], None)
}

/// [`resolve_source`] over several env files, earlier ones first, each key
/// on its own. `bound_instance_id` is the last place `CMUX_VM_ID` comes
/// from: a fresh Cloud VM's shells never export it (the baked env has none),
/// but the bind agent has written the machine's id.
pub(crate) fn resolve_layered_source(
    env: impl Fn(&str) -> Option<String>,
    env_files: &[Option<&str>],
    bound_instance_id: Option<&str>,
) -> Option<UsageSource> {
    let file_values: Vec<_> =
        env_files.iter().flatten().map(|file| parse_env_exports(file)).collect();
    let lookup = |key: &str| {
        env(key)
            .filter(|value| !value.trim().is_empty())
            .into_iter()
            .chain(file_values.iter().filter_map(|values| values.get(key).cloned()))
            .map(|value| value.trim().to_string())
            .find(|value| !value.is_empty())
    };
    let coderouter_url = lookup(CODEROUTER_URL_VAR)?;
    let vm_id = lookup(VM_ID_VAR).or_else(|| bound_instance_id.and_then(instance_id))?;
    if !(coderouter_url.starts_with("https://") || coderouter_url.starts_with("http://")) {
        return None;
    }
    Some(UsageSource { coderouter_url, vm_id })
}

/// A bound instance id file's text as an id: one token of printable ASCII,
/// at most [`MAX_INSTANCE_ID_BYTES`]; `None` otherwise.
fn instance_id(text: &str) -> Option<String> {
    let id = text.trim();
    (!id.is_empty()
        && id.len() <= MAX_INSTANCE_ID_BYTES
        && id.bytes().all(|byte| byte.is_ascii_graphic()))
    .then(|| id.to_string())
}

pub(crate) fn default_env_file_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(ENV_FILE_RELATIVE_PATH))
}

/// This machine's usage source, each key from the first place that has it:
/// the process environment, `$HOME/.config/cmux/model-plane.env` (what a
/// shell persisted from a boot env), the image's `/etc/cmux/model-plane.env`,
/// and for `CMUX_VM_ID` last the bound `/etc/cmux/daemon-instance-id`.
///
/// The daemon's unit carries none of these, and a fresh VM's shells only
/// source the image file without writing a per-home one, so without the two
/// `/etc/cmux` files a fresh VM never learned its identity and served no
/// `fs-v1`. The `/etc/cmux` folder follows the debug-only test seam
/// ([`crate::agent_start_host::cloud_etc`]).
pub(crate) fn machine_source() -> Option<UsageSource> {
    let home_env = read_env_file(default_env_file_path().as_deref());
    let etc = crate::agent_start_host::cloud_etc();
    let image_env = read_env_file(Some(&etc.file(IMAGE_ENV_FILE)));
    let bound_id = read_env_file(Some(&etc.file(BOUND_INSTANCE_FILE)));
    resolve_layered_source(
        |key| std::env::var(key).ok(),
        &[home_env.as_deref(), image_env.as_deref()],
        bound_id.as_deref(),
    )
}

/// `CMUX_VM_ID` alone, from the same places as [`machine_source`], with or
/// without a coderouter origin. Never the bound instance id: that is the
/// provider's, not the platform's `vm_…` id `secrets-v1` items are sealed for.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn machine_vm_id() -> Option<String> {
    let etc = crate::agent_start_host::cloud_etc();
    let files = [
        read_env_file(default_env_file_path().as_deref()),
        read_env_file(Some(&etc.file(IMAGE_ENV_FILE))),
    ];
    std::env::var(VM_ID_VAR)
        .ok()
        .into_iter()
        .chain(files.iter().flatten().filter_map(|file| parse_env_exports(file).remove(VM_ID_VAR)))
        .map(|value| value.trim().to_owned())
        .find(|value| !value.is_empty())
}

fn read_env_file(path: Option<&Path>) -> Option<String> {
    std::fs::read_to_string(path?).ok()
}

/// Why the daemon currently has no readout. Only used for log text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Unavailable {
    /// The service refused or does not know the machine (401, 403, 404).
    Rejected(u16),
    /// Any other HTTP status.
    Status(u16),
    /// The body was not the documented JSON shape.
    Malformed(String),
    /// Transport failure (DNS, TLS, timeout, connection refused).
    Transport(String),
}

impl std::fmt::Display for Unavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Unavailable::Rejected(status) => write!(formatter, "rejected with HTTP {status}"),
            Unavailable::Status(status) => write!(formatter, "unexpected HTTP {status}"),
            Unavailable::Malformed(error) => write!(formatter, "malformed response: {error}"),
            Unavailable::Transport(error) => write!(formatter, "transport error: {error}"),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VmUsageResponse {
    vm_id: String,
    period_days: u32,
    kind: String,
    #[serde(default)]
    as_of: Option<String>,
    #[serde(default)]
    totals: Option<VmUsageTotals>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct VmUsageTotals {
    #[serde(default)]
    total_tokens: f64,
    #[serde(default)]
    api_equivalent_usd: f64,
}

/// Decode a `vm-usage/self` body. `Ok(None)` is the documented
/// `kind: "unavailable"` shape; `Err` is anything off-contract.
pub(crate) fn decode_usage(body: &[u8]) -> Result<Option<MachineUsage>, Unavailable> {
    let response: VmUsageResponse =
        serde_json::from_slice(body).map_err(|error| Unavailable::Malformed(error.to_string()))?;
    if response.kind != "ready" {
        return Ok(None);
    }
    let Some(totals) = response.totals else {
        return Ok(None);
    };
    if !totals.api_equivalent_usd.is_finite() || !totals.total_tokens.is_finite() {
        return Err(Unavailable::Malformed("non-finite totals".to_string()));
    }
    if response.period_days == 0 {
        return Err(Unavailable::Malformed("periodDays must be positive".to_string()));
    }
    Ok(Some(MachineUsage {
        vm_id: response.vm_id,
        period_days: response.period_days,
        total_tokens: totals.total_tokens.max(0.0).round() as u64,
        api_equivalent_usd: totals.api_equivalent_usd.max(0.0),
        as_of: response.as_of,
    }))
}

/// Map an HTTP status and body to a readout outcome.
pub(crate) fn classify_response(
    status: u16,
    body: &[u8],
) -> Result<Option<MachineUsage>, Unavailable> {
    match status {
        200 => decode_usage(body),
        401 | 403 | 404 => Err(Unavailable::Rejected(status)),
        other => Err(Unavailable::Status(other)),
    }
}

/// Tracks the last logged state so a steady failure logs once.
#[derive(Debug, Default, PartialEq)]
struct ReportedState {
    last: Option<Result<bool, Unavailable>>,
}

impl ReportedState {
    /// Returns the log line to emit for this outcome, if the state changed.
    fn observe(&mut self, outcome: &Result<Option<MachineUsage>, Unavailable>) -> Option<String> {
        let key = match outcome {
            Ok(usage) => Ok(usage.is_some()),
            Err(error) => Err(error.clone()),
        };
        if self.last.as_ref() == Some(&key) {
            return None;
        }
        let line = match &key {
            Ok(true) => "machine usage readout available".to_string(),
            Ok(false) => "machine usage readout unavailable: usage not ready".to_string(),
            Err(error) => format!("machine usage readout unavailable: {error}"),
        };
        self.last = Some(key);
        Some(line)
    }
}

/// Handle to the background poller. `stop` interrupts any sleep or request
/// in flight and joins the thread.
pub(crate) struct UsagePoller {
    stop: Arc<Notify>,
    thread: Option<JoinHandle<()>>,
}

impl UsagePoller {
    pub(crate) fn stop(mut self) {
        self.stop.notify_one();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for UsagePoller {
    fn drop(&mut self) {
        self.stop.notify_one();
    }
}

/// Start polling when the process resolves a usage source; otherwise `None`.
pub(crate) fn start_poller(mux: Weak<Mux>) -> Option<UsagePoller> {
    let source = machine_source()?;
    start_poller_with_source(mux, source, STARTUP_DELAY, POLL_INTERVAL)
}

fn start_poller_with_source(
    mux: Weak<Mux>,
    source: UsageSource,
    startup_delay: Duration,
    interval: Duration,
) -> Option<UsagePoller> {
    let stop = Arc::new(Notify::new());
    let stop_for_thread = stop.clone();
    let spawn = std::thread::Builder::new().name("machine-usage-poll".into()).spawn(move || {
        let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                crate::client_log::log(
                    "DEBUG",
                    LOG_AREA,
                    &format!("runtime start failed: {error}"),
                );
                return;
            }
        };
        runtime.block_on(poll_loop(mux, source, stop_for_thread, startup_delay, interval));
    });
    match spawn {
        Ok(thread) => Some(UsagePoller { stop, thread: Some(thread) }),
        Err(error) => {
            crate::client_log::log("DEBUG", LOG_AREA, &format!("poller start failed: {error}"));
            None
        }
    }
}

async fn poll_loop(
    mux: Weak<Mux>,
    source: UsageSource,
    stop: Arc<Notify>,
    startup_delay: Duration,
    interval: Duration,
) {
    // reqwest's rustls-no-provider build needs the workspace's ring provider
    // installed once per process before the first TLS client exists.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = match reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
        .build()
    {
        Ok(client) => client,
        Err(error) => {
            crate::client_log::log("DEBUG", LOG_AREA, &format!("http client failed: {error}"));
            return;
        }
    };
    let url = source.usage_url();
    let mut reported = ReportedState::default();
    let mut delay = startup_delay;
    loop {
        tokio::select! {
            biased;
            () = stop.notified() => return,
            () = tokio::time::sleep(delay) => {}
        }
        delay = interval;
        let Some(mux) = mux.upgrade() else { return };
        let outcome = tokio::select! {
            biased;
            () = stop.notified() => return,
            outcome = fetch_usage(&client, &url) => outcome,
        };
        if let Some(line) = reported.observe(&outcome) {
            crate::client_log::log("DEBUG", LOG_AREA, &line);
        }
        mux.set_machine_usage(outcome.unwrap_or_default());
    }
}

async fn fetch_usage(
    client: &reqwest::Client,
    url: &str,
) -> Result<Option<MachineUsage>, Unavailable> {
    let response = client
        .get(url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {PLACEHOLDER_BEARER}"))
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .await
        .map_err(|error| Unavailable::Transport(error.to_string()))?;
    let status = response.status().as_u16();
    let body = response.bytes().await.map_err(|error| Unavailable::Transport(error.to_string()))?;
    if body.len() > MAX_BODY_BYTES {
        return Err(Unavailable::Malformed(format!("body of {} bytes exceeds limit", body.len())));
    }
    classify_response(status, &body)
}

#[cfg(test)]
mod tests;
