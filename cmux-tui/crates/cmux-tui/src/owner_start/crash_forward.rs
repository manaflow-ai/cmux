//! Crash forwarding for a standalone cmux-tui (plans/cmux-next/tui-tester-rollout.md #7, #9).
//!
//! The owner's panic hook (`owner_panic.rs`) writes `owner-panics-<session>.jsonl`.
//! The cmux-next app sends those lines to Sentry for the cmux-tui it bundles;
//! a Linux, npm or PyPI cmux-tui had nobody to send them. At owner start this
//! sends the lines not sent yet (a main-thread panic ends the process, so its
//! line goes on the next start) to the app's Sentry project, tagged
//! `process=cmux-tui`, each line once (a byte offset in `<log>.sent`). The
//! memory guard's `owner-memory-<session>.jsonl` goes the same way, at start
//! and right after each alert. A terminal host's panic, which the owner
//! appends to its log with `"source": "cmux-tui-host"`, goes as the host's
//! (`process=cmux-tui-host`, its own fingerprint), as the app labels it.
//!
//! It sends nothing when: the binary is inside the cmux app (the app sends
//! them), a managed policy disables telemetry, `DO_NOT_TRACK` or
//! `CMUX_TUI_TELEMETRY=off` is set, cmux.json has
//! `app.sendAnonymousTelemetry: false`, `CI` is set, or the build is not a
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
    if env_set("CI").is_some() {
        return Consent::Off("CI");
    }
    if !inputs.release_build {
        return Consent::Off("not a release build");
    }
    Consent::Send
}

/// The Sentry event for one panic line; None for a test line or a line that is not a panic.
/// `home` is replaced by `~` in the message and backtrace, so no user name leaves the machine.
pub(super) fn event_for(line: &str, home: Option<&str>) -> Option<Value> {
    let record: Value = serde_json::from_str(line).ok()?;
    if record.get("test").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let scrub = |text: &str| match home.filter(|home| home.len() > 1) {
        Some(home) => text.replace(home, "~"),
        None => text.to_string(),
    };
    let message = scrub(record.get("message")?.as_str()?);
    let location = scrub(record.get("location").and_then(Value::as_str).unwrap_or_default());
    let text = |key: &str| record.get(key).and_then(Value::as_str).map(String::from);
    let host =
        text("source").as_deref() == Some(cmux_tui_core::terminal_host_runtime::PANIC_LOG_SOURCE);
    let (process, crash_source, fingerprint, label) = if host {
        ("cmux-tui-host", "terminal_host_crash", "host-panic", "cmux-tui terminal host panic")
    } else {
        ("cmux-tui", "owner_panic_log", "owner-panic", "cmux-tui owner panic")
    };
    let mut tags = serde_json::Map::new();
    tags.insert("process".into(), json!(process));
    tags.insert("crash_source".into(), json!(crash_source));
    for (field, tag) in [
        ("thread", "thread"),
        ("version", "tui_version"),
        ("build_identity", "tui_build"),
        ("os", "tui_os"),
        ("arch", "tui_arch"),
    ] {
        if let Some(value) = text(field) {
            tags.insert(tag.into(), json!(value));
        }
    }
    let version = text("version").unwrap_or_else(|| DISTRIBUTION_VERSION.to_string());
    let at_ms = record.get("at_ms").and_then(Value::as_u64).unwrap_or_default();
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
        "logger": "cmux-tui",
        "release": format!("cmux-tui@{version}"),
        "exception": {"values": [{
            "type": "RustPanic",
            "value": message,
            "mechanism": {"type": "rust_panic", "handled": false},
        }]},
        "message": {"formatted": format!("{label} at {location}: {message}")},
        // Same panic site, same issue, whatever the message text holds (as the app does).
        "fingerprint": [fingerprint, location],
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
    let bytes = match cmux_blocking::fs::read(log) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(format!("read {}: {error}", log.display())),
    };
    let mut offset = cmux_blocking::fs::read_to_string(state)
        .ok()
        .and_then(|text| text.trim().parse::<usize>().ok())
        .unwrap_or(0);
    // A log shorter than the offset was replaced: start over.
    if offset > bytes.len() {
        offset = 0;
    }
    let mut sent = 0;
    let mut failure = None;
    while sent < max {
        let rest = &bytes[offset..];
        let Some(end) = rest.iter().position(|byte| *byte == b'\n') else { break };
        let line = String::from_utf8_lossy(&rest[..end]);
        if let Some(event) = event_for(&line, home) {
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
    let mut file = crate::blocking::fs::open_with(&options, &temp)
        .map_err(|error| format!("write offset: {error}"))?;
    file.write_all(offset.to_string().as_bytes())
        .map_err(|error| format!("write offset: {error}"))?;
    cmux_blocking::fs::rename(&temp, state).map_err(|error| format!("write offset: {error}"))
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
    /// Sends `log`'s unsent lines (see ``forward_new``).
    #[cfg(unix)]
    pub(super) fn forward(&self, log: &Path) -> Result<usize, String> {
        let _sending = self.sending.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        send_all(log, &self.dsn, self.home.as_deref())
    }

    #[cfg(not(unix))]
    pub(super) fn forward(&self, _log: &Path) -> Result<usize, String> {
        Ok(0)
    }
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
    if cfg!(not(unix)) {
        crate::client_log::info(LOG_AREA, "crash-forward: off (unsupported platform)");
        return None;
    }
    let executable =
        std::env::current_exe().ok().and_then(|path| cmux_blocking::fs::canonicalize(path).ok());
    let managed = cmux_config::managed::default_reader(env).read();
    let settings = cmux_blocking::fs::read_to_string(cmux_config::config_path())
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
    let forwarder = Forwarder { dsn, home: env("HOME"), sending: Default::default() };
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

#[cfg(unix)]
fn send_all(log: &Path, dsn: &Dsn, home: Option<&str>) -> Result<usize, String> {
    // reqwest's rustls-no-provider build needs the workspace's ring provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = cmux_threads::tokio::builder(
        "crash-forward",
        cmux_threads::ThreadQos::Background,
        cmux_threads::tokio::Flavor::CurrentThread,
    )
    .build()
    .map_err(|error| format!("runtime: {error}"))?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| format!("http client: {error}"))?;
    forward_new(log, &state_path(log), MAX_PER_START, home, |body| {
        cmux_threads::tokio::block_on(&runtime, async {
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
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn inputs<'a>(
        forced: &'a BTreeMap<String, Value>,
        settings: Option<&'a Value>,
        env: &'a dyn Fn(&str) -> Option<String>,
    ) -> ConsentInputs<'a> {
        ConsentInputs {
            channel: InstallChannel::Npm,
            managed_forced: forced,
            settings,
            release_build: true,
            env,
        }
    }

    #[test]
    fn the_dsn_names_the_envelope_endpoint() {
        let dsn = Dsn::parse("https://abc@o1.ingest.us.sentry.io/42").unwrap();
        assert_eq!(dsn.endpoint, "https://o1.ingest.us.sentry.io/api/42/envelope/");
        assert_eq!(dsn.public_key, "abc");
        assert!(Dsn::parse(DSN).is_some());
        assert_eq!(Dsn::parse("ftp://a@b/1"), None);
        assert_eq!(Dsn::parse("https://b/1"), None);
        assert_eq!(Dsn::parse("https://a@b/x"), None);
    }

    #[test]
    fn consent_sends_only_when_nothing_turns_it_off() {
        let none: BTreeMap<String, Value> = BTreeMap::new();
        let no_env = |_: &str| -> Option<String> { None };
        assert_eq!(consent(&inputs(&none, None, &no_env)), Consent::Send);

        let app = ConsentInputs { channel: InstallChannel::App, ..inputs(&none, None, &no_env) };
        assert!(matches!(consent(&app), Consent::Off(_)));

        let forced = BTreeMap::from([("DisableTelemetry".to_string(), Value::Bool(true))]);
        assert!(matches!(consent(&inputs(&forced, None, &no_env)), Consent::Off(_)));

        let off = json!({"app": {"sendAnonymousTelemetry": false}});
        assert_eq!(
            consent(&inputs(&none, Some(&off), &no_env)),
            Consent::Off("app.sendAnonymousTelemetry is false")
        );
        let on = json!({"app": {"sendAnonymousTelemetry": true}});
        assert_eq!(consent(&inputs(&none, Some(&on), &no_env)), Consent::Send);

        let dnt = |name: &str| (name == "DO_NOT_TRACK").then(|| "1".to_string());
        assert_eq!(consent(&inputs(&none, None, &dnt)), Consent::Off("DO_NOT_TRACK"));
        let telemetry_off = |name: &str| (name == "CMUX_TUI_TELEMETRY").then(|| "off".to_string());
        assert_eq!(
            consent(&inputs(&none, None, &telemetry_off)),
            Consent::Off("CMUX_TUI_TELEMETRY")
        );
        let ci = |name: &str| (name == "CI").then(|| "true".to_string());
        assert_eq!(consent(&inputs(&none, None, &ci)), Consent::Off("CI"));

        let unreleased = ConsentInputs { release_build: false, ..inputs(&none, None, &no_env) };
        assert_eq!(consent(&unreleased), Consent::Off("not a release build"));
    }

    #[test]
    fn a_test_line_is_never_an_event_and_home_is_scrubbed() {
        assert_eq!(event_for(r#"{"message":"x","location":"a.rs:1","test":true}"#, None), None);
        assert_eq!(event_for("not json", None), None);
        let event = event_for(
            r#"{"message":"open /home/maya/x failed","location":"a.rs:1","version":"0.13.5","os":"linux","backtrace":"at /home/maya/src"}"#,
            Some("/home/maya"),
        )
        .unwrap();
        assert_eq!(event["exception"]["values"][0]["value"], "open ~/x failed");
        assert_eq!(event["extra"]["backtrace"], "at ~/src");
        assert_eq!(event["tags"]["process"], "cmux-tui");
        assert_eq!(event["tags"]["tui_version"], "0.13.5");
        assert_eq!(event["release"], "cmux-tui@0.13.5");
        assert_eq!(event["fingerprint"], json!(["owner-panic", "a.rs:1"]));
    }

    #[test]
    fn a_terminal_host_line_is_labeled_as_the_host() {
        let event = event_for(
            r#"{"source":"cmux-tui-host","message":"boom","location":"vt.rs:9:1","thread":"parser"}"#,
            None,
        )
        .unwrap();
        assert_eq!(event["tags"]["process"], "cmux-tui-host");
        assert_eq!(event["tags"]["crash_source"], "terminal_host_crash");
        assert_eq!(event["fingerprint"], json!(["host-panic", "vt.rs:9:1"]));
        assert_eq!(
            event["message"]["formatted"],
            "cmux-tui terminal host panic at vt.rs:9:1: boom"
        );
    }

    #[test]
    fn each_line_goes_once_and_a_failed_send_retries_next_time() {
        let dir =
            std::env::temp_dir().join(format!("cmux-cf-unit-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("owner-panics-s.jsonl");
        let state = state_path(&log);
        let line =
            |message: &str| format!("{{\"message\":\"{message}\",\"location\":\"a.rs:1\"}}\n");
        std::fs::write(&log, format!("{}{}", line("one"), line("two"))).unwrap();

        let mut bodies = Vec::new();
        let result = forward_new(&log, &state, 10, None, |body| {
            let text = String::from_utf8_lossy(body).into_owned();
            if text.contains("two") {
                return Err("offline".into());
            }
            bodies.push(text);
            Ok(())
        });
        assert!(result.is_err());
        assert_eq!(bodies.len(), 1);

        let mut again = Vec::new();
        let sent = forward_new(&log, &state, 10, None, |body| {
            again.push(String::from_utf8_lossy(body).into_owned());
            Ok(())
        })
        .unwrap();
        assert_eq!(sent, 1);
        assert!(again[0].contains("two"));
        assert_eq!(forward_new(&log, &state, 10, None, |_| Ok(())).unwrap(), 0);

        // An unfinished last line waits for its newline.
        std::fs::write(&log, format!("{}{}{}three-partial", line("one"), line("two"), "")).unwrap();
        assert_eq!(forward_new(&log, &state, 10, None, |_| Ok(())).unwrap(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
