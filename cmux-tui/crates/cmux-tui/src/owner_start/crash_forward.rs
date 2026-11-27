//! Crash forwarding for a standalone cmux-tui (plans/cmux-next/tui-tester-rollout.md #7, #9).
//!
//! The owner's panic hook (`owner_panic.rs`) writes `owner-panics-<session>.jsonl`.
//! The cmux-next app sends those lines to Sentry for the cmux-tui it bundles;
//! a Linux, Windows, npm or PyPI cmux-tui had nobody to send them (Windows
//! too since RFD 0157's crash upload piece; `crash_scrub` redacts its
//! `C:\Users\<name>` paths). At owner start this
//! sends the lines not sent yet (a main-thread panic ends the process, so its
//! line goes on the next start) to the app's Sentry project, tagged
//! `process=cmux-tui`, each line once (a byte offset in `<log>.sent`). The
//! memory guard's `owner-memory-<session>.jsonl` goes the same way, at start
//! and right after each alert, and so does the interactive client's
//! `client-hangs.jsonl` (`ui_watchdog`), at client start and right after each hang.
//! The acpmux daemon's `$ACPMUX_HOME/panics.jsonl` (cmux-panic-log, RFD 0157) goes too, at
//! owner start, tagged `process=acpmux` as the app tags it (`RustPanicSource.acpmux`); every
//! owner on the machine reads that one log, so a file lock beside its offset lets one send.
//!
//! It sends nothing until the person opts in (`app.sendAnonymousTelemetry: true` in cmux.json;
//! unset is off). It also sends nothing when: the binary is inside the cmux app (the app sends
//! them), a managed policy disables telemetry, `DO_NOT_TRACK` or
//! `CMUX_TUI_TELEMETRY=off` is set, `CI` is set, or the build is not a
//! release (no `CMUX_TUI_DISTRIBUTION_VERSION` stamp). Debug builds take a
//! test DSN from `CMUX_TUI_TEST_SENTRY_DSN`, which also stands in for the stamp.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::version_report::{DISTRIBUTION_VERSION, InstallChannel};

/// The cmux-next app's Sentry project (`CrashReporter.dsn`, manaflow/cmuxterm-macos).
const DSN: &str = "https://ecba1ec90ecaee02a102fba931b6d2b3@o4507547940749312.ingest.us.sentry.io/4510796264636416";
/// Lines sent per start at most, so a crash loop cannot flood the project.
const MAX_PER_START: usize = 20;
const LOG_AREA: &str = "crash-forward";
#[cfg(debug_assertions)]
const TEST_DSN_ENV: &str = "CMUX_TUI_TEST_SENTRY_DSN";

/// A Sentry DSN, split into the envelope endpoint and the public key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Dsn {
    pub(super) endpoint: String,
    pub(super) public_key: String,
}

impl Dsn {
    /// `SCHEME://KEY@HOST[:PORT]/PROJECT`; None for anything else.
    pub(super) fn parse(text: &str) -> Option<Dsn> {
        let (scheme, rest) = text.split_once("://")?;
        let (key, host_and_project) = rest.split_once('@')?;
        let (host, project) = host_and_project.rsplit_once('/')?;
        let valid = matches!(scheme, "http" | "https")
            && !key.is_empty()
            && !host.is_empty()
            && !project.is_empty()
            && project.bytes().all(|byte| byte.is_ascii_digit());
        valid.then(|| Dsn {
            endpoint: format!("{scheme}://{host}/api/{project}/envelope/"),
            public_key: key.to_string(),
        })
    }

    fn auth_header(&self) -> String {
        format!(
            "Sentry sentry_version=7, sentry_key={}, sentry_client=cmux-tui/{DISTRIBUTION_VERSION}",
            self.public_key
        )
    }
}

/// Whether this process may send, or why not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Consent {
    Send,
    Off(&'static str),
}

/// What `consent` decides from; every input injected, so tests need no environment.
pub(super) struct ConsentInputs<'a> {
    pub(super) channel: InstallChannel,
    pub(super) managed_forced: &'a std::collections::BTreeMap<String, Value>,
    pub(super) settings: Option<&'a Value>,
    pub(super) release_build: bool,
    pub(super) env: &'a dyn Fn(&str) -> Option<String>,
}

pub(super) fn consent(inputs: &ConsentInputs<'_>) -> Consent {
    let env_set = |name: &str| (inputs.env)(name).filter(|value| !value.is_empty());
    let falsy =
        |value: &str| matches!(value.to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no");
    if inputs.channel == InstallChannel::App {
        return Consent::Off("the cmux app sends these");
    }
    if inputs.managed_forced.get("DisableTelemetry") == Some(&Value::Bool(true))
        || inputs.managed_forced.get("app.sendAnonymousTelemetry") == Some(&Value::Bool(false))
    {
        return Consent::Off("managed policy DisableTelemetry");
    }
    if env_set("DO_NOT_TRACK").is_some_and(|value| !falsy(&value)) {
        return Consent::Off("DO_NOT_TRACK");
    }
    if env_set("CMUX_TUI_TELEMETRY").is_some_and(|value| falsy(&value)) {
        return Consent::Off("CMUX_TUI_TELEMETRY");
    }
    let setting = inputs.settings.and_then(|root| {
        cmux_config::value::value_at(root, &["app", "sendAnonymousTelemetry"][..])
    });
    if setting == Some(&Value::Bool(false)) {
        return Consent::Off("app.sendAnonymousTelemetry is false");
    }
    // Off until the person turns it on: an unset setting sends nothing.
    if setting != Some(&Value::Bool(true)) {
        return Consent::Off("app.sendAnonymousTelemetry is not turned on");
    }
    if env_set("CI").is_some() {
        return Consent::Off("CI");
    }
    if !inputs.release_build {
        return Consent::Off("not a release build");
    }
    Consent::Send
}

/// Which process wrote a panic log: the tags, fingerprint and message its events carry, the
/// same as the app's `RustPanicSource` for that process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Source {
    pub(super) process: &'static str,
    pub(super) crash_source: &'static str,
    pub(super) fingerprint: &'static str,
    pub(super) label: &'static str,
    /// The tag a line's `version` goes in.
    pub(super) version_tag: &'static str,
    /// Whether a line's `version` is this build's release (the owner's is; acpmux writes its
    /// crate version, so its release is this binary's).
    pub(super) line_version_is_release: bool,
}

impl Source {
    /// The owner (`owner-panics-<session>.jsonl`), its memory log and the client's hang log.
    pub(super) const OWNER: Source = Source {
        process: "cmux-tui",
        crash_source: "owner_panic_log",
        fingerprint: "owner-panic",
        label: "cmux-tui owner panic",
        version_tag: "tui_version",
        line_version_is_release: true,
    };
    /// The acpmux daemon (`$ACPMUX_HOME/panics.jsonl`).
    pub(super) const ACPMUX: Source = Source {
        process: "acpmux",
        crash_source: "acpmux_panic_log",
        fingerprint: "acpmux-panic",
        label: "acpmux daemon panic",
        version_tag: "acpmux_version",
        line_version_is_release: false,
    };

    /// The source of `log`, by its file name (acpmux's is `panics.jsonl`).
    pub(super) fn of(log: &Path) -> Source {
        if log.file_name().and_then(|name| name.to_str()) == Some(ACPMUX_PANIC_LOG) {
            Source::ACPMUX
        } else {
            Source::OWNER
        }
    }
}

/// The acpmux daemon's panic log file name (`acpmux::config::panic_log_path`).
const ACPMUX_PANIC_LOG: &str = "panics.jsonl";

/// The acpmux daemon's panic log: in the home `cmux acp` uses (`ACPMUX_HOME`, else this build's
/// home), else acpmux's own default (`~/.acpmux`). Read without `cmux acp`'s one-time adoption
/// of a pre-isolation home, so forwarding moves nothing.
pub(super) fn acpmux_panic_log() -> PathBuf {
    #[cfg(unix)]
    if let Some(home) = crate::acp::key_lock_home() {
        return home.join(ACPMUX_PANIC_LOG);
    }
    acpmux::config::panic_log_path()
}

/// The Sentry event for one panic line; None for a test line or a line that is not a panic.
/// The message, location and backtrace go through `crash_scrub` (docs/privacy.md, Telemetry):
/// `home` becomes `~`, and secrets, emails and other user names are redacted, so none of them
/// leaves the machine.
pub(super) fn event_for(line: &str, source: &Source, home: Option<&str>) -> Option<Value> {
    let record: Value = serde_json::from_str(line).ok()?;
    if record.get("test").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let scrub = |text: &str| super::crash_scrub::scrub(text, home);
    let message = scrub(record.get("message")?.as_str()?);
    let location = scrub(record.get("location").and_then(Value::as_str).unwrap_or_default());
    let text = |key: &str| record.get(key).and_then(Value::as_str).map(String::from);
    let mut tags = serde_json::Map::new();
    tags.insert("process".into(), json!(source.process));
    tags.insert("crash_source".into(), json!(source.crash_source));
    for (field, tag) in [
        ("thread", "thread"),
        ("version", source.version_tag),
        ("build_identity", "tui_build"),
        ("os", "tui_os"),
        ("arch", "tui_arch"),
    ] {
        if let Some(value) = text(field) {
            tags.insert(tag.into(), json!(value));
        }
    }
    let version = text("version")
        .filter(|_| source.line_version_is_release)
        .unwrap_or_else(|| DISTRIBUTION_VERSION.to_string());
    let at_ms = record.get("at_ms").and_then(Value::as_u64).unwrap_or_default();
    if record.get("kind").and_then(Value::as_str) == Some("client-hang") {
        // A UI-loop hang of the interactive client (ui_watchdog): a warning, one issue per
        // top frame, with the sampled stack and the waits as extra data.
        tags.insert("crash_source".into(), json!("client_hang_log"));
        let list = |key: &str| -> Vec<String> {
            record
                .get(key)
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(Value::as_str).map(scrub).collect())
                .unwrap_or_default()
        };
        return Some(json!({
            "event_id": uuid::Uuid::new_v4().simple().to_string(),
            "timestamp": at_ms as f64 / 1000.0,
            "platform": "native",
            "level": "warning",
            "logger": "cmux-tui",
            "release": format!("cmux-tui@{version}"),
            "exception": {"values": [{
                "type": "ClientHang",
                "value": message,
                "mechanism": {"type": "ui_watchdog", "handled": true},
            }]},
            "message": {"formatted": message},
            "fingerprint": ["client-hang", location],
            "tags": tags,
            "extra": {
                "duration_ms": record.get("duration_ms"),
                "backtrace": scrub(record.get("backtrace").and_then(Value::as_str).unwrap_or_default()),
                "waits": list("waits"),
                "cancelled": list("cancelled"),
            },
        }));
    }
    if record.get("kind").and_then(Value::as_str) == Some("memory") {
        // A memory guard line (memory_guard.rs): a warning, one issue per
        // release, with the figures as extra data.
        tags.insert("crash_source".into(), json!("owner_memory_log"));
        return Some(json!({
            "event_id": uuid::Uuid::new_v4().simple().to_string(),
            "timestamp": at_ms as f64 / 1000.0,
            "platform": "native",
            "level": "warning",
            "logger": "cmux-tui",
            "release": format!("cmux-tui@{version}"),
            "exception": {"values": [{
                "type": "MemoryGrowth",
                "value": message,
                "mechanism": {"type": "memory_guard", "handled": true},
            }]},
            "message": {"formatted": message},
            "fingerprint": ["owner-memory"],
            "tags": tags,
            "extra": {
                "memory_bytes": record.get("memory_bytes"),
                "threshold_bytes": record.get("threshold_bytes"),
                "uptime_seconds": record.get("uptime_seconds"),
            },
        }));
    }
    Some(json!({
        "event_id": uuid::Uuid::new_v4().simple().to_string(),
        "timestamp": at_ms as f64 / 1000.0,
        "platform": "native",
        "level": "error",
        "logger": source.process,
        "release": format!("cmux-tui@{version}"),
        "exception": {"values": [{
            "type": "RustPanic",
            "value": message,
            "mechanism": {"type": "rust_panic", "handled": false},
        }]},
        "message": {"formatted": format!("{} at {location}: {message}", source.label)},
        // Same panic site, same issue, whatever the message text holds (as the app does).
        "fingerprint": [source.fingerprint, location],
        "tags": tags,
        "extra": {
            "location": location,
            "backtrace": scrub(record.get("backtrace").and_then(Value::as_str).unwrap_or_default()),
        },
    }))
}

/// One event as a Sentry envelope body.
pub(super) fn envelope(event: &Value) -> Vec<u8> {
    let payload = event.to_string();
    let header = json!({"event_id": event["event_id"]});
    let item = json!({"type": "event", "length": payload.len()});
    format!("{header}\n{item}\n{payload}\n").into_bytes()
}

/// Sends the complete lines of `log` past the offset in `state`, oldest
/// first, at most `max`; advances the offset past each line it sent or
/// skipped and stops at the first send that fails (that line goes next time).
/// Returns how many it sent.
pub(super) fn forward_new(
    log: &Path,
    state: &Path,
    max: usize,
    home: Option<&str>,
    mut send: impl FnMut(&[u8]) -> Result<(), String>,
) -> Result<usize, String> {
    let bytes = match std::fs::read(log) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(format!("read {}: {error}", log.display())),
    };
    let mut offset = std::fs::read_to_string(state)
        .ok()
        .and_then(|text| text.trim().parse::<usize>().ok())
        .unwrap_or(0);
    // A log shorter than the offset was replaced: start over.
    if offset > bytes.len() {
        offset = 0;
    }
    let source = Source::of(log);
    let mut sent = 0;
    let mut failure = None;
    while sent < max {
        let rest = &bytes[offset..];
        let Some(end) = rest.iter().position(|byte| *byte == b'\n') else { break };
        let line = String::from_utf8_lossy(&rest[..end]);
        if let Some(event) = event_for(&line, &source, home) {
            if let Err(error) = send(&envelope(&event)) {
                failure = Some(error);
                break;
            }
            sent += 1;
        }
        offset += end + 1;
    }
    write_offset(state, offset)?;
    match failure {
        Some(error) => Err(format!("sent={sent} error={error}")),
        None => Ok(sent),
    }
}

fn write_offset(state: &Path, offset: usize) -> Result<(), String> {
    let temp = state.with_extension("sent.tmp");
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    use std::io::Write;
    let mut file = options.open(&temp).map_err(|error| format!("write offset: {error}"))?;
    file.write_all(offset.to_string().as_bytes())
        .map_err(|error| format!("write offset: {error}"))?;
    std::fs::rename(&temp, state).map_err(|error| format!("write offset: {error}"))
}

/// The offset file beside `log`.
pub(super) fn state_path(log: &Path) -> PathBuf {
    let mut name = log.file_name().unwrap_or_default().to_os_string();
    name.push(".sent");
    log.with_file_name(name)
}

/// Where and how this process sends: built once at owner start when consent
/// allows, then shared with the memory guard.
#[derive(Clone, Debug)]
pub(super) struct Forwarder {
    dsn: Dsn,
    home: Option<String>,
    /// One send at a time: the start thread and the memory guard share each
    /// log's offset file, and two readers of one offset would send a line twice.
    sending: std::sync::Arc<std::sync::Mutex<()>>,
}

impl Forwarder {
    /// Sends `log`'s unsent lines (see ``forward_new``). Another process sending the same log
    /// (every owner reads acpmux's) holds `<log>.sent.lock`; then this sends nothing.
    pub(super) fn forward(&self, log: &Path) -> Result<usize, String> {
        let _sending = self.sending.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(_lock) = try_lock_beside(log)? else { return Ok(0) };
        send_all(log, &self.dsn, self.home.as_deref())
    }
}

/// An exclusive lock on `<log>.sent.lock`, held while the returned file lives; None when another
/// process holds it. No directory (no log yet): nothing to lock, nothing to send.
pub(super) fn try_lock_beside(log: &Path) -> Result<Option<std::fs::File>, String> {
    let mut name = state_path(log).file_name().unwrap_or_default().to_os_string();
    name.push(".lock");
    let path = log.with_file_name(name);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).truncate(false).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = match options.open(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("lock {}: {error}", path.display())),
    };
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(std::fs::TryLockError::WouldBlock) => Ok(None),
        Err(std::fs::TryLockError::Error(error)) => {
            Err(format!("lock {}: {error}", path.display()))
        }
    }
}

/// The home `crash_scrub` turns into `~`: `HOME`, or on Windows (where `HOME` is usually unset)
/// the profile, `USERPROFILE`.
pub(super) fn home_dir(env: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let set = |name: &str| env(name).filter(|value| !value.is_empty());
    set("HOME").or_else(|| if cfg!(windows) { set("USERPROFILE") } else { None })
}

/// Decides consent once and, when it allows, sends the unsent lines of every
/// log in `logs` on a thread of its own. Logs one `crash-forward:` outcome
/// line to the client log; returns the forwarder for later sends.
pub(super) fn start(logs: Vec<PathBuf>) -> Option<Forwarder> {
    let env = |name: &str| std::env::var(name).ok();
    #[cfg(debug_assertions)]
    let test_dsn = env(TEST_DSN_ENV).filter(|dsn| !dsn.is_empty());
    #[cfg(not(debug_assertions))]
    let test_dsn: Option<String> = None;
    let executable = std::env::current_exe().ok().and_then(|path| std::fs::canonicalize(path).ok());
    let managed = cmux_config::managed::default_reader(env).read();
    let settings = std::fs::read_to_string(cmux_config::config_path())
        .ok()
        .and_then(|text| cmux_config::jsonc::parse(&text).ok());
    let decision = consent(&ConsentInputs {
        channel: executable.as_deref().map_or(InstallChannel::Other, InstallChannel::detect),
        managed_forced: &managed.forced,
        settings: settings.as_ref(),
        release_build: test_dsn.is_some() || crate::version_report::RELEASE_STAMPED,
        env: &env,
    });
    if let Consent::Off(reason) = decision {
        crate::client_log::info(LOG_AREA, &format!("crash-forward: off ({reason})"));
        return None;
    }
    let Some(dsn) = Dsn::parse(test_dsn.as_deref().unwrap_or(DSN)) else {
        crate::client_log::warn(LOG_AREA, "crash-forward: off (bad DSN)");
        return None;
    };
    let forwarder = Forwarder { dsn, home: home_dir(&env), sending: Default::default() };
    let worker = forwarder.clone();
    let _ = std::thread::Builder::new().name("crash-forward".into()).spawn(move || {
        let mut sent = 0;
        let mut failures = Vec::new();
        for log in &logs {
            match worker.forward(log) {
                Ok(count) => sent += count,
                Err(error) => failures.push(error),
            }
        }
        let line = if failures.is_empty() {
            format!("crash-forward: sent={sent}")
        } else {
            format!("crash-forward: failed sent={sent} {}", failures.join("; "))
        };
        crate::client_log::info(LOG_AREA, &line);
    });
    Some(forwarder)
}

fn send_all(log: &Path, dsn: &Dsn, home: Option<&str>) -> Result<usize, String> {
    // `cmux_egress::client_builder` installs the ring provider reqwest's rustls build needs.
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("runtime: {error}"))?;
    let client = cmux_egress::client_builder("cmux_tui::owner_start::crash_forward")
        .timeout(std::time::Duration::from_secs(10))
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| format!("http client: {error}"))?;
    forward_new(log, &state_path(log), MAX_PER_START, home, |body| {
        runtime.block_on(async {
            let response = client
                .post(&dsn.endpoint)
                .header("Content-Type", "application/x-sentry-envelope")
                .header("X-Sentry-Auth", dsn.auth_header())
                .body(body.to_vec())
                .send()
                .await
                .map_err(|error| error.to_string())?;
            if response.status().is_success() {
                Ok(())
            } else {
                Err(format!("HTTP {}", response.status()))
            }
        })
    })
}

#[cfg(test)]
#[path = "crash_forward_tests.rs"]
mod tests;
