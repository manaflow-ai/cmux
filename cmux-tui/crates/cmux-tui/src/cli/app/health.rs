//! `cmux app health [--json]`: does the running app work, checked the way a person would find out.
//!
//! After an update the chat could fail to send while the window looked fine (the picker read only
//! "Model"; NIGHTLY 229690498cfd: the app relay refused every chat page's `initialize` for an
//! unknown `_meta` param). This probe asks the app at the socket, over its sockets only, what
//! broke: the model picker has models, a chat can start (acpmux answers and the default harness
//! passes its handshake), the app relay let the chat pages' frames through (no relay refusal in the
//! error journal since `--since-ms`, after a real chat page handshake with `--open-chat`), and a
//! terminal runs (a throwaway terminal echoes a nonce, read back, then closed). Each check has its own deadline and a stable reason code, so the app's post-update check
//! (CmuxNextUpdater's `UpdateHealthCheck`) and the bisect helper (`cmux --app-socket SOCK app health
//! --json` against a `cmux app try` copy) read the same verdict. Nothing here changes saved state:
//! the terminal it opens is closed again, and the chat check runs the harness without a model call.
//!
//! Exit 0 when every check passed, 1 when one failed, 3 when no app answered.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Value, json};

use super::super::command::{RequestPlan, ResponseView, WireOperation};
use super::{AppCommand, GlobalArgs, Options, OutputMode, UsageError};

/// `system.identify` and `agent.acpmux` on the app socket.
const APP_DEADLINE: Duration = Duration::from_secs(5);
/// acpmux ready (a just-relaunched app starts it), then `_acpmux/models`.
const MODELS_DEADLINE: Duration = Duration::from_secs(20);
/// `_acpmux/harness/doctor` with no prompt: spawn the harness, run its session handshake.
const CHAT_DEADLINE: Duration = Duration::from_secs(30);
/// Create the terminal, type, read the nonce back, close it.
const TERMINAL_DEADLINE: Duration = Duration::from_secs(15);
/// `errors.list` (the app's own 12 s deadline), plus a chat page's open and handshake with
/// `--open-chat`.
const RELAY_DEADLINE: Duration = Duration::from_secs(15);
const RELAY_OPEN_CHAT_DEADLINE: Duration = Duration::from_secs(35);
/// How far back the relay check reads the journal with no `--since-ms`.
const RELAY_DEFAULT_WINDOW: Duration = Duration::from_secs(10 * 60);
/// What the app relay logs when it refuses a chat page's frame (AgentPaneTransport+Check.swift);
/// the error journal harvests both. Any one since `since` fails the relay check.
pub(super) const RELAY_REFUSALS: [&str; 2] =
    ["agent pane params rule refused", "agent pane transport refused frame"];

#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Command {
    /// Relay refusals count from here (unix ms); the app passes its launch. Default: 10 min ago.
    pub since_ms: Option<u64>,
    /// Open a new agent chat (no focus change) so its page does a real handshake through the
    /// relay, then close it. Without it the relay check reads only the chats already open.
    pub open_chat: bool,
}

/// `rest` starts with `health`. `--json` is the global output flag.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let usage = || UsageError::new(crate::localization::catalog().app_control.health.usage);
    let options = Options::parse(rest.get(1..).unwrap_or_default(), &["since-ms"], &["open-chat"])
        .map_err(|_| usage())?;
    let since_ms = match options.value("since-ms") {
        Some(text) => Some(text.parse::<u64>().map_err(|_| usage())?),
        None => None,
    };
    Ok(AppCommand::Health(Command { since_ms, open_chat: options.flag("open-chat") }))
}

/// One check's verdict. `reason` is a stable code (`ok` when it passed); `detail` is for a person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Check {
    pub name: &'static str,
    pub ok: bool,
    pub reason: String,
    pub detail: String,
    pub ms: u128,
    pub deadline_ms: u128,
}

impl Check {
    fn json(&self) -> Value {
        json!({
            "name": self.name,
            "ok": self.ok,
            "reason": self.reason,
            "detail": self.detail,
            "ms": self.ms as u64,
            "deadline_ms": self.deadline_ms as u64,
        })
    }
}

/// What a check found, before it is timed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Verdict {
    pub ok: bool,
    pub reason: String,
    pub detail: String,
}

impl Verdict {
    pub(super) fn pass(detail: impl Into<String>) -> Self {
        Verdict { ok: true, reason: "ok".into(), detail: detail.into() }
    }
    pub(super) fn fail(reason: &str, detail: impl Into<String>) -> Self {
        Verdict { ok: false, reason: reason.into(), detail: detail.into() }
    }
}

fn timed(name: &'static str, deadline: Duration, work: impl FnOnce() -> Verdict) -> Check {
    let started = Instant::now();
    let verdict = work();
    let ms = started.elapsed().as_millis();
    // A check that answered after its deadline is a failure: a person would have given up.
    let (ok, reason, detail) = if verdict.ok && started.elapsed() > deadline {
        (false, "deadline".to_owned(), format!("passed only after {ms} ms: {}", verdict.detail))
    } else {
        (verdict.ok, verdict.reason, verdict.detail)
    };
    Check { name, ok, reason, detail, ms, deadline_ms: deadline.as_millis() }
}

/// `cmux app health`: runs the checks and prints them.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let since_ms = command
        .since_ms
        .unwrap_or_else(|| now_ms().saturating_sub(RELAY_DEFAULT_WINDOW.as_millis() as u64));
    let mut stream = match super::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
    };
    let mut checks = Vec::new();
    let mut identify = Value::Null;
    let mut acpmux_socket: Option<PathBuf> = None;
    checks.push(timed("app", APP_DEADLINE, || {
        match super::exchange(&mut stream, "system.identify", json!({}), APP_DEADLINE) {
            Ok(Ok(value)) => identify = value,
            Ok(Err(error)) => return Verdict::fail("app.error", error_text(&error)),
            Err(message) => return Verdict::fail("app.transport", message),
        }
        match super::exchange(&mut stream, "agent.acpmux", json!({}), APP_DEADLINE) {
            Ok(Ok(value)) => acpmux_socket = acpmux_socket_of(&value),
            Ok(Err(error)) => return Verdict::fail("acpmux.unknown", error_text(&error)),
            Err(message) => return Verdict::fail("app.transport", message),
        }
        app_verdict(&identify, acpmux_socket.as_deref())
    }));
    drop(stream);
    let app_ok = checks[0].ok;
    let mut default_harness: Option<String> = None;
    if app_ok && let Some(socket) = acpmux_socket {
        checks.push(timed("models", MODELS_DEADLINE, || {
            match acp::models(&socket, MODELS_DEADLINE) {
                Ok(answer) => {
                    default_harness = default_harness_of(&answer);
                    models_verdict(&answer)
                }
                Err((reason, detail)) => Verdict::fail(reason, detail),
            }
        }));
        checks.push(timed("chat", CHAT_DEADLINE, || match default_harness.as_deref() {
            None => Verdict::fail("chat.no_harness", "no default harness to start a chat with"),
            Some(harness) => match acp::doctor(&socket, harness, CHAT_DEADLINE) {
                Ok(answer) => doctor_verdict(harness, &answer),
                Err((reason, detail)) => Verdict::fail(reason, detail),
            },
        }));
    } else {
        for name in ["models", "chat"] {
            checks.push(skipped(name));
        }
    }
    if app_ok {
        let deadline = if command.open_chat { RELAY_OPEN_CHAT_DEADLINE } else { RELAY_DEADLINE };
        checks.push(timed("relay", deadline, || {
            relay_check(global, &identify, since_ms, command.open_chat)
        }));
        checks.push(timed("terminal", TERMINAL_DEADLINE, || terminal_check(global, &identify)));
    } else {
        checks.push(skipped("relay"));
        checks.push(skipped("terminal"));
    }
    let report = report(&identify, &checks);
    let ok = report["ok"] == Value::Bool(true);
    let printed = match global.output {
        OutputMode::Human => {
            print!("{}", human(&report));
            0
        }
        _ => super::super::wire::print_local_success(&report, global.output),
    };
    if printed != 0 {
        printed
    } else if ok {
        0
    } else {
        1
    }
}

fn skipped(name: &'static str) -> Check {
    Check {
        name,
        ok: false,
        reason: "skipped".into(),
        detail: "not run: the app check failed".into(),
        ms: 0,
        deadline_ms: 0,
    }
}

fn error_text(error: &Value) -> String {
    let code = error["code"].as_str().unwrap_or("error");
    match error["message"].as_str() {
        Some(message) => format!("{code}: {message}"),
        None => code.to_owned(),
    }
}

fn acpmux_socket_of(answer: &Value) -> Option<PathBuf> {
    answer["socket_path"].as_str().filter(|path| !path.is_empty()).map(PathBuf::from)
}

/// The app answered `system.identify` with a build, and names its acpmux.
pub(super) fn app_verdict(identify: &Value, acpmux: Option<&Path>) -> Verdict {
    let build = identify["build"].as_str().or_else(|| identify["version"].as_str());
    let Some(build) = build.filter(|build| !build.is_empty()) else {
        return Verdict::fail("app.no_build", "system.identify named no build");
    };
    match acpmux {
        None => Verdict::fail("acpmux.none", "the app named no acpmux socket (agent.acpmux)"),
        Some(path) => Verdict::pass(format!("build {build}, acpmux {}", path.display())),
    }
}

/// The models a picker shows: every harness's models but the `default` sentinel row.
fn picker_models(harness: &Value) -> usize {
    harness["models"]
        .as_array()
        .map(|models| models.iter().filter(|model| model["id"] != "default").count())
        .unwrap_or(0)
}

/// The harness a new chat starts with: the one marked `isDefault`, else the first.
pub(super) fn default_harness_of(models: &Value) -> Option<String> {
    let harnesses = models["harnesses"].as_array()?;
    harnesses
        .iter()
        .find(|harness| harness["isDefault"] == Value::Bool(true))
        .or_else(|| harnesses.first())
        .and_then(|harness| harness["harness"].as_str())
        .map(str::to_owned)
}

/// The picker is populated: the default harness lists at least one model. Other harnesses' probe
/// errors are named in the detail, but only the default one decides.
pub(super) fn models_verdict(models: &Value) -> Verdict {
    let harnesses = models["harnesses"].as_array().cloned().unwrap_or_default();
    if harnesses.is_empty() {
        return Verdict::fail("models.no_harness", "_acpmux/models listed no harness");
    }
    let total: usize = harnesses.iter().map(picker_models).sum();
    let Some(default) = default_harness_of(models) else {
        return Verdict::fail("models.no_harness", "_acpmux/models named no harness");
    };
    let entry = harnesses.iter().find(|harness| harness["harness"] == default.as_str());
    let count = entry.map(picker_models).unwrap_or(0);
    if count == 0 {
        let why = entry
            .and_then(|harness| harness["probeError"].as_str())
            .map(|error| format!(": {error}"))
            .unwrap_or_default();
        return Verdict::fail(
            "models.empty",
            format!("the default harness {default} lists no model{why} ({total} across all)"),
        );
    }
    Verdict::pass(format!(
        "{default}: {count} models, {total} across {} harnesses",
        harnesses.len()
    ))
}

/// The doctor's answer: ok only when it says `ok: true`; the failed steps name why.
pub(super) fn doctor_verdict(harness: &str, answer: &Value) -> Verdict {
    if answer["ok"] == Value::Bool(true) {
        return Verdict::pass(format!("{harness} started a session"));
    }
    let failed: Vec<String> = answer["steps"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|step| step["ok"] != Value::Bool(true))
        .map(|step| {
            let name = step["name"].as_str().unwrap_or("step");
            match step["detail"].as_str().filter(|detail| !detail.is_empty()) {
                Some(detail) => format!("{name}: {detail}"),
                None => name.to_owned(),
            }
        })
        .collect();
    let detail = if failed.is_empty() { "no step passed".to_owned() } else { failed.join("; ") };
    Verdict::fail("chat.handshake", format!("{harness}: {detail}"))
}

/// The terminal check: a throwaway `/bin/sh` tab on the app's daemon prints a nonce typed into it;
/// the tab is closed whatever happened.
fn terminal_check(global: &GlobalArgs, identify: &Value) -> Verdict {
    let Some(daemon) = daemon_socket(identify) else {
        return Verdict::fail("terminal.no_daemon", "no daemon socket for this app's identity");
    };
    let mut daemon_global = global.clone();
    daemon_global.socket = Some(daemon);
    let nonce = nonce();
    let terminal = terminal_id();
    let call = |operation: ResourceOperation, params: Value| {
        super::super::mcp::agent_resource(&daemon_global, plan(operation, params))
    };
    let created = match call(
        ResourceOperation::TabCreateTerminal,
        json!({
            "name": "cmux health",
            "argv": ["/bin/sh"],
            "terminal_id": terminal,
        }),
    ) {
        Ok(created) => created,
        Err(error) => return Verdict::fail("terminal.create", error_text(&error)),
    };
    // The tab's public `term_` id, which every selector takes. The bare host id is a name to the
    // resolver: `terminal.close` refused it with "terminal current/name selector requires a tab
    // selector", so every run failed and left its "cmux health" tab open in the app.
    let terminal = created_terminal(&created).unwrap_or(terminal);
    let verdict = (|| {
        // `%s-%s` keeps the typed line from matching: only the output joins the two halves.
        let text = format!("printf '%s-%s\\n' cmuxhealth {nonce}\n");
        if let Err(error) =
            call(ResourceOperation::TerminalInputWrite, json!({"terminal": terminal, "text": text}))
        {
            return Verdict::fail("terminal.write", error_text(&error));
        }
        let wait_ms = TERMINAL_DEADLINE.as_millis().saturating_sub(3_000).max(1_000);
        match call(
            ResourceOperation::TerminalWait,
            json!({
                "terminal": terminal,
                "pattern": format!("cmuxhealth-{nonce}"),
                "timeout_ms": wait_ms.to_string(),
            }),
        ) {
            Ok(answer) => terminal_verdict(&answer),
            Err(error) => Verdict::fail("terminal.wait", error_text(&error)),
        }
    })();
    if let Err(error) = call(ResourceOperation::TerminalClose, json!({"terminal": terminal})) {
        return Verdict::fail("terminal.close", error_text(&error));
    }
    verdict
}

/// The relay check: with `open_chat`, a new agent chat opens (no focus change) and its page does
/// its `initialize` handshake through the app relay, then the tab is closed; then the error
/// journal (`errors.list`, harvested from the logs) must hold no relay refusal since `since_ms`.
fn relay_check(global: &GlobalArgs, identify: &Value, since_ms: u64, open_chat: bool) -> Verdict {
    let mut opened = None;
    if open_chat {
        match open_probe_chat(global, identify) {
            Ok(tab) => opened = Some(tab),
            Err(verdict) => return verdict,
        }
    }
    let journal = (|| {
        let mut stream = super::connect_command(global).map_err(|error| error_text(&error))?;
        let params = json!({
            "since_ms": since_ms,
            "text": "agent pane",
            "harvest": true,
            "limit": 200,
        });
        match super::exchange(&mut stream, "errors.list", params, RELAY_DEADLINE) {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(error)) => Err(error_text(&error)),
            Err(message) => Err(message),
        }
    })();
    if let Some((daemon_global, tab)) = opened {
        let closed = super::super::mcp::agent_resource(
            &daemon_global,
            plan(ResourceOperation::TabClose, json!({"tab": tab})),
        );
        if let Err(error) = closed {
            return Verdict::fail("relay.close", error_text(&error));
        }
    }
    match journal {
        Ok(answer) => relay_verdict(&answer, since_ms),
        Err(message) => Verdict::fail("relay.no_journal", message),
    }
}

/// The relay refusals in an `errors.list` answer seen since `since_ms`: none passes.
pub(super) fn relay_verdict(answer: &Value, since_ms: u64) -> Verdict {
    let Some(entries) = answer["entries"].as_array() else {
        return Verdict::fail("relay.no_journal", "errors.list returned no entries list");
    };
    let refusals: Vec<&Value> = entries
        .iter()
        .filter(|entry| entry["last_ms"].as_f64().is_some_and(|ms| ms >= since_ms as f64))
        .filter(|entry| {
            let text = format!(
                "{} {}",
                entry["template"].as_str().unwrap_or(""),
                entry["sample"].as_str().unwrap_or("")
            );
            RELAY_REFUSALS.iter().any(|marker| text.contains(marker))
        })
        .collect();
    if refusals.is_empty() {
        return Verdict::pass("no relay refusal in the error journal");
    }
    let count: u64 =
        refusals.iter().map(|entry| entry["count"].as_f64().unwrap_or(1.0) as u64).sum();
    let samples: Vec<String> = refusals
        .iter()
        .take(3)
        .map(|entry| {
            let sample = entry["sample"].as_str().unwrap_or("");
            let fingerprint = entry["fingerprint"].as_str().unwrap_or("?");
            format!("{fingerprint}: {}", sample.chars().take(200).collect::<String>())
        })
        .collect();
    Verdict::fail(
        "relay.refused",
        format!("the app relay refused chat page frames {count} times: {}", samples.join("; ")),
    )
}

/// Opens a new agent chat with `palette.newAgentChat` (`focus: false`: what the app shows does not
/// change) and finds its tab as the one tab the daemon lists after that it did not before. Its
/// page loads and does its `initialize` through the relay; a few seconds are left for that.
fn open_probe_chat(global: &GlobalArgs, identify: &Value) -> Result<(GlobalArgs, String), Verdict> {
    let Some(daemon) = daemon_socket(identify) else {
        return Err(Verdict::fail("relay.no_daemon", "no daemon socket for this app's identity"));
    };
    let mut daemon_global = global.clone();
    daemon_global.socket = Some(daemon);
    let tabs = |daemon_global: &GlobalArgs| -> Result<Vec<String>, Verdict> {
        super::super::mcp::agent_resource(
            daemon_global,
            plan(ResourceOperation::TabList, json!({})),
        )
        .map(|answer| tab_ids(&answer))
        .map_err(|error| Verdict::fail("relay.tabs", error_text(&error)))
    };
    let before = tabs(&daemon_global)?;
    let mut params = Value::Object(super::run::action_run_params(
        "palette.newAgentChat",
        super::ActionName::Any,
        super::action_origin(),
    ));
    params["focus"] = json!(false);
    super::run::insert_run_key(&mut params, None)
        .map_err(|message| Verdict::fail("relay.open", message))?;
    let mut stream = super::connect_command(global)
        .map_err(|error| Verdict::fail("relay.open", error_text(&error)))?;
    match super::exchange(&mut stream, "action.run", params, Duration::from_secs(10)) {
        Ok(Ok(_)) => {}
        Ok(Err(error)) => return Err(Verdict::fail("relay.open", error_text(&error))),
        Err(message) => return Err(Verdict::fail("relay.open", message)),
    }
    let until = Instant::now() + Duration::from_secs(10);
    let tab = loop {
        let after = tabs(&daemon_global)?;
        if let Some(tab) = new_tab(&before, &after) {
            break tab;
        }
        if Instant::now() >= until {
            return Err(Verdict::fail("relay.open", "no new chat tab appeared"));
        }
        std::thread::sleep(Duration::from_millis(250));
    };
    // The page loads, connects and sends `initialize`; a refusal is logged at once.
    std::thread::sleep(Duration::from_secs(8));
    Ok((daemon_global, tab))
}

/// The tab ids in a `tab.list` answer (`tabs` or `items`, each with an `id`).
pub(super) fn tab_ids(answer: &Value) -> Vec<String> {
    ["tabs", "items"]
        .iter()
        .find_map(|key| answer[*key].as_array())
        .into_iter()
        .flatten()
        .filter_map(|tab| tab["id"].as_str().map(str::to_owned))
        .collect()
}

/// The one tab in `after` that `before` did not have; none or several is no answer.
pub(super) fn new_tab(before: &[String], after: &[String]) -> Option<String> {
    let mut fresh = after.iter().filter(|tab| !before.contains(tab));
    let tab = fresh.next()?;
    fresh.next().is_none().then(|| tab.clone())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_millis() as u64)
        .unwrap_or_default()
}

/// `terminal.wait`'s answer: passed only when it says `matched: true`.
pub(super) fn terminal_verdict(answer: &Value) -> Verdict {
    if answer["matched"] == Value::Bool(true) {
        Verdict::pass("echoed the nonce")
    } else {
        Verdict::fail("terminal.no_echo", "the terminal did not echo the nonce in time")
    }
}

fn plan(operation: ResourceOperation, mut params: Value) -> RequestPlan {
    params["machine"] = json!("current");
    params["session"] = json!("current");
    RequestPlan {
        operation: WireOperation::Typed(operation),
        params,
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: ResponseView::Full,
        filter: Default::default(),
    }
}

/// The app's daemon session socket, from the CLI path `system.identify` named.
#[cfg(target_os = "macos")]
fn daemon_socket(identify: &Value) -> Option<PathBuf> {
    let cli = PathBuf::from(identify["app_cli_path"].as_str()?);
    let identity = crate::app_identity::AppIdentity::detect(|_| None, Some(&cli))?;
    crate::app_identity::app_daemon_socket(&identity)
}

#[cfg(not(target_os = "macos"))]
fn daemon_socket(_identify: &Value) -> Option<PathBuf> {
    None
}

/// The created terminal's public id (`term_...`) in a `tab.create_terminal` answer: the first
/// `terminal` field, at any depth, whose value is such an id.
pub(super) fn created_terminal(answer: &Value) -> Option<String> {
    match answer {
        Value::Object(map) => map
            .get("terminal")
            .and_then(Value::as_str)
            .filter(|id| id.starts_with("term_"))
            .map(str::to_owned)
            .or_else(|| map.values().find_map(created_terminal)),
        Value::Array(items) => items.iter().find_map(created_terminal),
        _ => None,
    }
}

/// 16 lowercase hex characters, fresh per run.
fn nonce() -> String {
    random_hex(16)
}

/// A UUIDv4 in 32 lowercase hex characters, the form `terminal_id` takes.
fn terminal_id() -> String {
    let mut hex: Vec<char> = random_hex(32).chars().collect();
    hex[12] = '4';
    hex[16] = ['8', '9', 'a', 'b'][hex[16].to_digit(16).unwrap_or(0) as usize % 4];
    hex.into_iter().collect()
}

fn random_hex(len: usize) -> String {
    use std::hash::{BuildHasher as _, Hasher as _};
    let mut out = String::with_capacity(len);
    let mut counter = 0u64;
    while out.len() < len {
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u64(counter);
        hasher.write_u128(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|since| since.as_nanos())
                .unwrap_or_default(),
        );
        hasher.write_u32(std::process::id());
        out.push_str(&format!("{:016x}", hasher.finish()));
        counter += 1;
    }
    out.truncate(len);
    out
}

/// The report: the app's build and commit, and every check in order.
pub(super) fn report(identify: &Value, checks: &[Check]) -> Value {
    let commit = identify["app_bundle_path"]
        .as_str()
        .map(|bundle| super::version::read_components(Path::new(bundle)))
        .and_then(|components| {
            ["cmux-tui", "acpmux"]
                .iter()
                .find_map(|name| components.get(*name)?["commit"].as_str().map(str::to_owned))
        });
    let app = if identify.is_null() {
        Value::Null
    } else {
        json!({
            "build": identify["build"],
            "version": identify["version"],
            "bundle_id": identify["bundle_id"],
            "commit": commit,
        })
    };
    // `failed`: the checks that ran and failed, each `{name, reason}`, for a caller that acts on the
    // verdict (the updater's Go Back offer, an automatic rollback) without walking `checks`.
    // A check skipped because an earlier one failed is not listed: the earlier one is.
    let failed: Vec<Value> = checks
        .iter()
        .filter(|check| !check.ok && check.reason != "skipped")
        .map(|check| json!({"name": check.name, "reason": check.reason}))
        .collect();
    json!({
        "ok": !checks.is_empty() && checks.iter().all(|check| check.ok),
        "app": app,
        "failed": failed,
        "checks": checks.iter().map(Check::json).collect::<Vec<_>>(),
    })
}

/// One line per check: `ok   chat  (812 ms) claude started a session`.
pub(super) fn human(report: &Value) -> String {
    let labels = &crate::localization::catalog().app_control.health;
    let mut out = String::new();
    if let Some(app) = report["app"].as_object() {
        let field = |key: &str| app.get(key).and_then(Value::as_str).unwrap_or("?").to_owned();
        out.push_str(&format!("{} {} ({})\n", labels.app, field("version"), field("commit")));
    }
    for check in report["checks"].as_array().into_iter().flatten() {
        let mark = if check["ok"] == Value::Bool(true) { labels.pass } else { labels.fail };
        let name = check["name"].as_str().unwrap_or("?");
        let ms = check["ms"].as_u64().unwrap_or(0);
        let reason = check["reason"].as_str().unwrap_or("?");
        let detail = check["detail"].as_str().unwrap_or("");
        if check["ok"] == Value::Bool(true) {
            out.push_str(&format!("{mark:<5}{name:<9}({ms} ms) {detail}\n"));
        } else {
            out.push_str(&format!("{mark:<5}{name:<9}({ms} ms) {reason}: {detail}\n"));
        }
    }
    let summary = if report["ok"] == Value::Bool(true) { labels.healthy } else { labels.unhealthy };
    out.push_str(summary);
    out.push('\n');
    out
}

mod acp {
    //! The app's acpmux, reached at the socket the app named: readiness, models, the harness doctor.

    use std::path::Path;
    use std::time::{Duration, Instant};

    use serde_json::{Value, json};

    type Failure = (&'static str, String);

    fn block_on<T>(
        deadline: Duration,
        work: impl Future<Output = Result<T, Failure>>,
    ) -> Result<T, Failure> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| ("acpmux.runtime", error.to_string()))?;
        runtime.block_on(async {
            match tokio::time::timeout(deadline, work).await {
                Ok(result) => result,
                Err(_) => Err(("deadline", format!("no answer in {} s", deadline.as_secs()))),
            }
        })
    }

    async fn ready_client(
        socket: &Path,
        until: Instant,
    ) -> Result<std::sync::Arc<acpmux::client::Client>, Failure> {
        let client = acpmux::client::Client::connect_without_caller(socket)
            .await
            .map_err(|error| ("acpmux.connect", format!("{error:#}")))?;
        // A just-relaunched app starts acpmux; wait for it to say it is ready, inside the deadline.
        loop {
            let status = client
                .request(acpmux::rpc::method::MUX_STATUS, json!({}))
                .await
                .map_err(|error| ("acpmux.status", format!("{error:#}")))?;
            if status["ready"] != Value::Bool(false) {
                return Ok(client);
            }
            if Instant::now() >= until {
                return Err(("acpmux.not_ready", "acpmux never said it was ready".into()));
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }

    /// `_acpmux/models`, once acpmux is ready.
    pub(super) fn models(socket: &Path, deadline: Duration) -> Result<Value, Failure> {
        let until = Instant::now() + deadline;
        block_on(deadline, async {
            let client = ready_client(socket, until).await?;
            client
                .request("_acpmux/models", json!({}))
                .await
                .map_err(|error| ("models.error", format!("{error:#}")))
        })
    }

    /// `_acpmux/harness/doctor` for `harness`, without a prompt (no model call).
    pub(super) fn doctor(
        socket: &Path,
        harness: &str,
        deadline: Duration,
    ) -> Result<Value, Failure> {
        let until = Instant::now() + deadline;
        let secs = deadline.as_secs().saturating_sub(2).clamp(5, 120);
        block_on(deadline, async {
            let client = ready_client(socket, until).await?;
            client
                .request(
                    acpmux::rpc::method::MUX_HARNESS_DOCTOR,
                    json!({"id": harness, "prompt": false, "noPrompt": true, "timeoutSecs": secs}),
                )
                .await
                .map_err(|error| ("chat.error", format!("{error:#}")))
        })
    }
}

#[cfg(test)]
mod tests;
