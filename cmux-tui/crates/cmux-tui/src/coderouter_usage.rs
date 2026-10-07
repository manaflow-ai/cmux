//! Machine spend readout for cmux Cloud VMs.
//!
//! A Cloud VM daemon learns its coderouter identity from the model-plane env
//! (`CMUX_CODEROUTER_URL` and `CMUX_VM_ID`, in the process environment or in
//! `$HOME/.config/cmux/model-plane.env`) and polls
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
pub(crate) fn resolve_source(
    env: impl Fn(&str) -> Option<String>,
    env_file: Option<&str>,
) -> Option<UsageSource> {
    let file_values = env_file.map(parse_env_exports).unwrap_or_default();
    let lookup = |key: &str| {
        env(key)
            .filter(|value| !value.trim().is_empty())
            .or_else(|| file_values.get(key).cloned())
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    };
    let coderouter_url = lookup(CODEROUTER_URL_VAR)?;
    let vm_id = lookup(VM_ID_VAR)?;
    if !(coderouter_url.starts_with("https://") || coderouter_url.starts_with("http://")) {
        return None;
    }
    Some(UsageSource { coderouter_url, vm_id })
}

pub(crate) fn default_env_file_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(ENV_FILE_RELATIVE_PATH))
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
    let env_file = default_env_file_path();
    let contents = read_env_file(env_file.as_deref());
    let source = resolve_source(|key| std::env::var(key).ok(), contents.as_deref())?;
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
mod tests {
    use super::*;

    const READY_BODY: &str = r#"{
        "vmId": "vm-123", "periodDays": 30, "kind": "ready", "asOf": "2026-09-01T00:00:00Z",
        "totals": {"inputTokens": 10, "cachedInputTokens": 2, "outputTokens": 5,
                   "totalTokens": 17, "apiEquivalentUsd": 1.234},
        "days": [{"day": "2026-09-01", "totalTokens": 17, "apiEquivalentUsd": 1.234}]
    }"#;

    #[test]
    fn env_exports_parse_quoted_and_bare_values() {
        let contents = "# generated by cmux from machine boot env; managed, do not edit\n\
            export OPENAI_BASE_URL='https://coderouter.dev/v1'\n\
            export CMUX_CODEROUTER_URL='https://coderouter.dev'\n\
            export CMUX_VM_ID='it'\\''s-a-vm'\n\
            PLAIN=bare-value # trailing comment\n\
            DOUBLE=\"quoted \\\"value\\\"\"\n\
            \n\
            not a valid line\n\
            1BAD=nope\n\
            export BROKEN='unterminated\n";
        let values = parse_env_exports(contents);
        assert_eq!(values["OPENAI_BASE_URL"], "https://coderouter.dev/v1");
        assert_eq!(values["CMUX_CODEROUTER_URL"], "https://coderouter.dev");
        assert_eq!(values["CMUX_VM_ID"], "it's-a-vm");
        assert_eq!(values["PLAIN"], "bare-value");
        assert_eq!(values["DOUBLE"], "quoted \"value\"");
        assert!(!values.contains_key("1BAD"));
        assert!(!values.contains_key("BROKEN"));
        assert_eq!(values.len(), 5, "{values:?}");
    }

    #[test]
    fn source_prefers_process_env_and_falls_back_per_key() {
        let file =
            "export CMUX_CODEROUTER_URL='https://file.example'\nexport CMUX_VM_ID='file-vm'\n";
        let env = |key: &str| (key == VM_ID_VAR).then(|| "env-vm".to_string());
        let source = resolve_source(env, Some(file)).expect("source resolves");
        assert_eq!(
            source,
            UsageSource {
                coderouter_url: "https://file.example".to_string(),
                vm_id: "env-vm".to_string()
            }
        );
        assert_eq!(source.usage_url(), "https://file.example/api/coderouter/vm-usage/self");

        let trailing = resolve_source(
            |key| match key {
                CODEROUTER_URL_VAR => Some("https://coderouter.dev/".to_string()),
                VM_ID_VAR => Some("vm".to_string()),
                _ => None,
            },
            None,
        )
        .expect("env-only source resolves");
        assert_eq!(trailing.usage_url(), "https://coderouter.dev/api/coderouter/vm-usage/self");
    }

    #[test]
    fn source_is_absent_without_both_keys_or_with_a_bad_origin() {
        assert_eq!(resolve_source(|_| None, None), None);
        assert_eq!(resolve_source(|_| None, Some("export CMUX_VM_ID='vm'\n")), None);
        assert_eq!(
            resolve_source(|_| None, Some("export CMUX_CODEROUTER_URL='https://x'\n")),
            None
        );
        assert_eq!(
            resolve_source(
                |_| Some("   ".to_string()),
                Some("export CMUX_CODEROUTER_URL='https://x'\nexport CMUX_VM_ID='vm'\n")
            )
            .map(|source| source.vm_id),
            Some("vm".to_string()),
            "blank process values fall through to the file"
        );
        assert_eq!(
            resolve_source(
                |_| None,
                Some("export CMUX_CODEROUTER_URL='coderouter.dev'\nexport CMUX_VM_ID='vm'\n")
            ),
            None,
            "an origin without a scheme is not polled"
        );
    }

    #[test]
    fn ready_body_decodes_to_a_readout() {
        let usage = decode_usage(READY_BODY.as_bytes()).unwrap().expect("ready totals");
        assert_eq!(usage.vm_id, "vm-123");
        assert_eq!(usage.period_days, 30);
        assert_eq!(usage.total_tokens, 17);
        assert!((usage.api_equivalent_usd - 1.234).abs() < f64::EPSILON);
        assert_eq!(usage.as_of.as_deref(), Some("2026-09-01T00:00:00Z"));
    }

    #[test]
    fn unavailable_and_malformed_bodies_yield_no_readout() {
        let unavailable = r#"{"vmId":"vm","periodDays":30,"kind":"unavailable","asOf":null,"totals":null,"days":[]}"#;
        assert_eq!(decode_usage(unavailable.as_bytes()), Ok(None));
        let ready_without_totals =
            r#"{"vmId":"vm","periodDays":30,"kind":"ready","asOf":null,"days":[]}"#;
        assert_eq!(decode_usage(ready_without_totals.as_bytes()), Ok(None));
        assert!(matches!(decode_usage(b"<html>").unwrap_err(), Unavailable::Malformed(_)));
        assert!(matches!(decode_usage(b"{}").unwrap_err(), Unavailable::Malformed(_)));
        let negative = r#"{"vmId":"vm","periodDays":30,"kind":"ready","totals":{"totalTokens":-3,"apiEquivalentUsd":-0.5}}"#;
        let usage = decode_usage(negative.as_bytes()).unwrap().expect("ready");
        assert_eq!((usage.total_tokens, usage.api_equivalent_usd), (0, 0.0));
    }

    #[test]
    fn http_status_classification_degrades_to_hidden() {
        assert_eq!(
            classify_response(404, b"{\"error\":\"vm_not_found\"}"),
            Err(Unavailable::Rejected(404))
        );
        assert_eq!(classify_response(401, b"{}"), Err(Unavailable::Rejected(401)));
        assert_eq!(classify_response(503, b""), Err(Unavailable::Status(503)));
        assert!(classify_response(200, READY_BODY.as_bytes()).unwrap().is_some());
    }

    #[test]
    fn state_changes_log_once() {
        let mut reported = ReportedState::default();
        let rejected: Result<Option<MachineUsage>, Unavailable> = Err(Unavailable::Rejected(404));
        assert!(reported.observe(&rejected).is_some());
        assert!(reported.observe(&rejected).is_none(), "steady failure stays quiet");
        assert!(reported.observe(&Err(Unavailable::Rejected(401))).is_some());
        let ready = decode_usage(READY_BODY.as_bytes());
        assert!(reported.observe(&ready).unwrap().contains("available"));
        assert!(reported.observe(&ready).is_none(), "steady success stays quiet");
        assert!(reported.observe(&Ok(None)).unwrap().contains("not ready"));
    }

    #[test]
    fn poller_publishes_readout_then_clears_it_when_the_endpoint_disappears() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let hits = Arc::new(AtomicUsize::new(0));
        let hits_for_server = hits.clone();
        let server = std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                let mut request = [0_u8; 2048];
                let mut read = 0;
                while let Ok(n) = stream.read(&mut request[read..]) {
                    if n == 0 {
                        break;
                    }
                    read += n;
                    if request[..read].windows(4).any(|window| window == b"\r\n\r\n")
                        || read == request.len()
                    {
                        break;
                    }
                }
                let request = String::from_utf8_lossy(&request[..read]);
                assert!(
                    request.contains("GET /api/coderouter/vm-usage/self HTTP/1.1"),
                    "{request}"
                );
                assert!(
                    request
                        .to_ascii_lowercase()
                        .contains("authorization: bearer cmux-vm-edge-placeholder"),
                    "{request}"
                );
                let hit = hits_for_server.fetch_add(1, Ordering::AcqRel);
                let (status, body) =
                    if hit == 0 { ("200 OK", READY_BODY) } else { ("404 Not Found", "{}") };
                let response = format!(
                    "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
                if hit >= 1 {
                    break;
                }
            }
        });

        let mux = Mux::new(
            "machine-usage-poller",
            cmux_tui_core::SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".to_string(),
                    "-c".to_string(),
                    "sleep 30".to_string(),
                ]),
                ..Default::default()
            },
        );
        let events = mux.subscribe();
        let source =
            UsageSource { coderouter_url: format!("http://{address}"), vm_id: "vm".into() };
        let poller = start_poller_with_source(
            Arc::downgrade(&mux),
            source,
            Duration::from_millis(1),
            Duration::from_millis(1),
        )
        .expect("poller starts");

        let wait = |predicate: &dyn Fn(&cmux_tui_core::MuxEvent) -> bool| loop {
            match events.recv_timeout(Duration::from_secs(10)) {
                Ok(event) if predicate(&event) => break,
                Ok(_) => {}
                Err(error) => panic!("timed out waiting for machine usage event: {error}"),
            }
        };
        wait(
            &|event| matches!(event, cmux_tui_core::MuxEvent::MachineUsageChanged(Some(usage)) if usage.vm_id == "vm-123"),
        );
        assert_eq!(mux.machine_usage().map(|usage| usage.total_tokens), Some(17));
        wait(&|event| matches!(event, cmux_tui_core::MuxEvent::MachineUsageChanged(None)));
        assert_eq!(mux.machine_usage(), None);
        poller.stop();
        server.join().unwrap();
        assert!(hits.load(Ordering::Acquire) >= 2);
        mux.shutdown();
    }
}
