//! `cmux version`: one cheap report of every version an agent (the Chief, a
//! subagent, a bug report) needs, in one call.
//!
//! `cmux --version --json` says only what this CLI binary is. An agent also
//! needs to know which app its socket reaches (NIGHTLY, DEV, stable, the
//! classic app), that app's full build string (`1.0.0-nightly.<build>`),
//! bundle id and path, whether this CLI is the one bundled with that app, the
//! updater's state (checking, downloaded, ready on quit, last check), the
//! versions of the bundled helpers (acpmux, the Chief host, cmux-tui) and the
//! macOS version. This joins them: the CLI's own facts, then `system.identify`
//! and `updates.status` on one app connection, then the `bin/*.version`
//! stamps beside the bundled CLI. Nothing here changes any state. With no app
//! behind the socket the report still prints, with `app: null` and the
//! reason, and exits 0.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::super::GlobalArgs;
use super::super::OutputMode;

/// Each read answers inside the app's own 2 s control deadline.
const READ_TIMEOUT: Duration = Duration::from_secs(3);

/// What `cmux version` gathered before it is shaped into the report.
pub(super) struct Inputs {
    /// `cmux --version --json` of this binary.
    pub cli: Value,
    /// This binary, resolved.
    pub cli_path: Option<PathBuf>,
    /// `system.identify`, or the reason no app answered.
    pub identify: Result<Value, Value>,
    /// `updates.status`, `None` when the app has no updater methods.
    pub updates: Option<Value>,
    /// `bin/<name>.version` stamps of the app bundle, by name.
    pub components: Map<String, Value>,
    /// `{name, version, build}` of the operating system.
    pub os: Value,
}

/// `cmux version`: gathers [`Inputs`] and prints the report.
pub(super) fn run(global: &GlobalArgs) -> i32 {
    let cli_path = std::env::current_exe().ok().and_then(|path| path.canonicalize().ok());
    let (identify, updates) = match super::connect_command(global) {
        Ok(mut stream) => {
            let identify =
                match super::exchange(&mut stream, "system.identify", json!({}), READ_TIMEOUT) {
                    Ok(Ok(value)) => Ok(value),
                    Ok(Err(error)) => Err(error),
                    Err(message) => Err(json!({ "code": "app.transport", "message": message })),
                };
            let updates = identify.as_ref().ok().and_then(|_| {
                match super::exchange(&mut stream, "updates.status", json!({}), READ_TIMEOUT) {
                    Ok(Ok(value)) => Some(value),
                    _ => None,
                }
            });
            (identify, updates)
        }
        Err(error) => (Err(error), None),
    };
    let bundle = identify
        .as_ref()
        .ok()
        .and_then(|value| text(value, "app_bundle_path"))
        .map(PathBuf::from)
        .or_else(|| cli_path.as_deref().and_then(bundle_of));
    let components = bundle.as_deref().map(read_components).unwrap_or_default();
    let inputs = Inputs {
        cli: crate::version_report_json(),
        cli_path,
        identify,
        updates,
        components,
        os: os_facts(),
    };
    let value = report(&inputs);
    match global.output {
        OutputMode::Human => {
            print!("{}", human(&value, &crate::localization::catalog().app_control.version));
            0
        }
        _ => super::super::wire::print_local_success(&value, global.output),
    }
}

/// The report `cmux version --json` prints.
pub(super) fn report(inputs: &Inputs) -> Value {
    let mut cli = inputs.cli.clone();
    if let Some(object) = cli.as_object_mut() {
        object.insert(
            "path".into(),
            inputs.cli_path.as_ref().map(|path| path.display().to_string()).into(),
        );
    }
    let (app, app_error) = match &inputs.identify {
        Ok(identify) => (app_facts(identify, inputs.updates.as_ref()), Value::Null),
        Err(error) => (Value::Null, error_facts(error)),
    };
    let cli_matches_app = match (&inputs.identify, &inputs.cli_path) {
        (Ok(identify), Some(exe)) => match text(identify, "app_cli_path") {
            Some(cli) => Value::Bool(same_file(Path::new(&cli), exe)),
            None => Value::Null,
        },
        _ => Value::Null,
    };
    json!({
        "cli": cli,
        "app": app,
        "app_error": app_error,
        "cli_matches_app": cli_matches_app,
        "updates": inputs.updates.as_ref().map(update_facts),
        "components": inputs.components,
        "os": inputs.os,
    })
}

fn app_facts(identify: &Value, updates: Option<&Value>) -> Value {
    let name = text(identify, "app").unwrap_or_else(|| "cmux".to_owned());
    let bundle_id = text(identify, "bundle_id");
    let track = updates.and_then(|status| text(status, "track"));
    // `updates.status.track` keeps the updater's internal feed identity. The
    // public app channel retains the established NIGHTLY name for NEXT's
    // `nightly-next` track; the raw value remains in `updates.track`.
    let channel = track
        .as_deref()
        .map(public_channel)
        .map(str::to_owned)
        .unwrap_or_else(|| channel_of(&name, bundle_id.as_deref()).to_owned());
    json!({
        "name": name,
        "classic": name == "cmux",
        "version": text(identify, "version"),
        "build": text(identify, "build"),
        "channel": channel,
        "bundle_id": bundle_id,
        "bundle_path": text(identify, "app_bundle_path"),
        "cli_path": text(identify, "app_cli_path"),
        "socket": text(identify, "socket_path"),
        "pid": identify.get("pid").cloned().unwrap_or(Value::Null),
        "tag": text(identify, "tag"),
        "protocol_version": identify.get("protocol_version").cloned().unwrap_or(Value::Null),
    })
}

/// Convert an updater track to the stable channel name shown by `cmux version`.
fn public_channel(track: &str) -> &str {
    match track {
        "nightly-next" => "nightly",
        other => other,
    }
}

fn error_facts(error: &Value) -> Value {
    json!({
        "code": error.get("code").cloned().unwrap_or(Value::Null),
        "message": error.get("message").cloned().unwrap_or_else(|| error.clone()),
    })
}

/// The release channel of a bundle id, when the updater does not say.
fn channel_of(name: &str, bundle_id: Option<&str>) -> &'static str {
    if name == "cmux" {
        return "classic";
    }
    let Some(id) = bundle_id else { return "unknown" };
    let base = "com.cmuxterm.app";
    let rest = id.strip_prefix(base).unwrap_or("?");
    let first = rest.trim_start_matches('.').split('.').next().unwrap_or("");
    match (rest, first) {
        ("", _) => "stable",
        (_, "nightly") => "nightly",
        (_, "rc") => "rc",
        (_, "debug" | "staging") => "development",
        _ => "unknown",
    }
}

/// The updater facts an agent acts on, without the log or the feed details.
fn update_facts(status: &Value) -> Value {
    let probe = status.get("last_probe").filter(|probe| !probe.is_null());
    let card = status.get("card").filter(|card| !card.is_null());
    json!({
        "track": text(status, "track"),
        "phase": text(status, "phase"),
        "detected_version": text(status, "detected_version"),
        "probing": status.get("probing").cloned().unwrap_or(Value::Null),
        "automatic_checks": status.get("automatic_checks").cloned().unwrap_or(Value::Null),
        "automatic_downloads": status.get("automatic_downloads").cloned().unwrap_or(Value::Null),
        "sparkle_enabled": status.get("sparkle_enabled").cloned().unwrap_or(Value::Null),
        "last_check": probe.and_then(|probe| text(probe, "checked_at")),
        "last_check_result": probe.and_then(|probe| text(probe, "result")),
        "last_check_error": text(status, "last_probe_error"),
        "ready": card.and_then(|card| text(card, "kind")),
        "badge": text(status, "badge"),
        "feed_url": text(status, "feed_url"),
    })
}

/// The `.app` around a CLI at `<app>/Contents/Resources/bin/cmux`.
fn bundle_of(exe: &Path) -> Option<PathBuf> {
    let bin = exe.parent()?;
    let resources = bin.parent()?;
    let contents = resources.parent()?;
    let app = contents.parent()?;
    let shaped = bin.file_name()? == "bin"
        && resources.file_name()? == "Resources"
        && contents.file_name()? == "Contents"
        && app.extension()? == "app";
    shaped.then(|| app.to_path_buf())
}

/// The `key=value` stamps (`bin/acpmux.version`, `bin/optchat-chief.version`,
/// `bin/cmux-tui.version`) the app build writes beside each bundled binary.
pub(super) fn read_components(bundle: &Path) -> Map<String, Value> {
    let bin = bundle.join("Contents/Resources/bin");
    let mut components = Map::new();
    let Ok(entries) = std::fs::read_dir(&bin) else { return components };
    let mut stamps: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "version"))
        .collect();
    stamps.sort();
    for stamp in stamps {
        let Some(name) = stamp.file_stem().and_then(|stem| stem.to_str()) else { continue };
        let Ok(body) = std::fs::read_to_string(&stamp) else { continue };
        components.insert(name.to_owned(), Value::Object(parse_stamp(&body)));
    }
    components
}

/// One `key=value` per line; an empty value is left out.
pub(super) fn parse_stamp(body: &str) -> Map<String, Value> {
    body.lines()
        .filter_map(|line| line.split_once('='))
        .map(|(key, value)| (key.trim(), value.trim()))
        .filter(|(key, value)| !key.is_empty() && !value.is_empty())
        .map(|(key, value)| (key.to_owned(), Value::String(value.to_owned())))
        .collect()
}

fn os_facts() -> Value {
    #[cfg(target_os = "macos")]
    {
        let sw_vers = |flag: &str| {
            std::process::Command::new("/usr/bin/sw_vers")
                .arg(flag)
                .output()
                .ok()
                .filter(|output| output.status.success())
                .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned())
                .filter(|value| !value.is_empty())
        };
        json!({
            "name": "macOS",
            "version": sw_vers("-productVersion"),
            "build": sw_vers("-buildVersion"),
            "arch": std::env::consts::ARCH,
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        json!({ "name": std::env::consts::OS, "version": null, "build": null, "arch": std::env::consts::ARCH })
    }
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).filter(|value| !value.is_empty()).map(str::to_owned)
}

fn same_file(left: &Path, right: &Path) -> bool {
    match (left.canonicalize(), right.canonicalize()) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

/// The plain-text report, one fact per line.
pub(super) fn human(report: &Value, labels: &crate::localization::VersionLabels) -> String {
    let field = |value: &Value, key: &str| text(value, key).unwrap_or_else(|| "-".to_owned());
    let mut out = String::new();
    let mut line = |label: &str, value: String| {
        out.push_str(&format!("{label:<16} {value}\n"));
    };
    let cli = &report["cli"];
    let short = |commit: String| commit.chars().take(11).collect::<String>();
    line(
        labels.cli,
        format!(
            "{} ({}) {}",
            field(cli, "version"),
            short(field(cli, "build_commit")),
            field(cli, "path")
        ),
    );
    let app = &report["app"];
    if app.is_null() {
        line(labels.app, format!("{} ({})", labels.no_app, field(&report["app_error"], "message")));
    } else {
        line(
            labels.app,
            format!("{} {} [{}]", field(app, "name"), field(app, "version"), field(app, "channel")),
        );
        line(labels.bundle, format!("{} {}", field(app, "bundle_id"), field(app, "bundle_path")));
        let pid =
            app.get("pid").and_then(Value::as_u64).map_or("-".to_owned(), |pid| pid.to_string());
        line(labels.socket, format!("{} (pid {pid})", field(app, "socket")));
    }
    let matches = match report["cli_matches_app"].as_bool() {
        Some(true) => labels.yes.to_owned(),
        Some(false) => format!("{} ({})", labels.no, field(app, "cli_path")),
        None => "-".to_owned(),
    };
    line(labels.cli_matches_app, matches);
    let updates = &report["updates"];
    if !updates.is_null() {
        let mut state = field(updates, "phase");
        if let Some(ready) = text(updates, "ready") {
            state.push_str(&format!(", {ready}"));
        }
        if let Some(version) = text(updates, "detected_version") {
            state.push_str(&format!(", {version}"));
        }
        line(labels.updates, state);
        line(labels.last_check, field(updates, "last_check"));
    }
    if let Some(components) = report["components"].as_object() {
        for (name, stamp) in components {
            let value = text(stamp, "version")
                .or_else(|| text(stamp, "commit").map(short))
                .unwrap_or_else(|| "-".to_owned());
            line(name, value);
        }
    }
    let os = &report["os"];
    line(&field(os, "name"), format!("{} ({})", field(os, "version"), field(os, "build")));
    out
}

#[cfg(test)]
mod tests;
