//! `cmux vm new … --wait`: one command from nothing to a configured Cloud VM (Leo, 2026-11-10: "are they a
//! hassle to set up?"). Without it a person makes the VM, waits with `cmux vm ls` when the create answers
//! `pending`, reads `~/.cmux/machine-config/status.json` with `cmux vm file-read` until the machine config is
//! applied, then runs `cmux vm deliver-secrets` (scripts/cmux-next/vm-hassle.ts counts these steps).
//!
//! It runs the app's own verbs in turn, each as this binary with `--json` ([`Runner`]), so each keeps its
//! checks, confirmations and deadlines:
//!
//! 1. `cloud new-machine` with the words given (`--wait` and `--timeout` taken out). A create with no `--name`
//!    gets one (`vm-` and 12 hex characters), so a create that answers `pending` can still be found.
//! 2. Until the VM is running: `cloud list-machines`, the row with its id (or its name, for a pending create).
//! 3. With `--machine-config` or `--repo` (the checkout's own `.cmux/machine.toml`): `cloud file-read` of the
//!    status file until its state is `done`; `failed` stops with the status and the log's path.
//! 4. Then `cloud deliver-secrets`, again while it answers `pending` (it waits on the machine's link).
//!
//! Output: one JSON object: `machine_id`, `target`, `title`, `machine_config` (the applier's status), `secrets`
//! (delivered and missing names), `elapsed_ms`, and `next`, the commands to start an agent or open a terminal.
//! [`wait_until_ready`] is the same wait for `cmux vm redo` (vm_redo.rs).

#[cfg(test)]
pub(super) mod tests;

use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::GlobalArgs;
use super::cloud_start_chat::{Runner, step_result};

/// The applier's status file on a Cloud machine (cmux-cloud-start-core machine_config.rs `status_path`).
pub(super) const CONFIG_STATUS: &str = "/home/cmux/.cmux/machine-config/status.json";
/// The applier's log (machine_config.rs `log_path`), named when setup fails.
const CONFIG_LOG: &str = "/home/cmux/.cmux/machine-config/setup.log";
/// How long `--wait` waits by default: a clone and a dependency install fit.
pub(super) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(20 * 60);
const MAX_TIMEOUT: Duration = Duration::from_secs(3 * 60 * 60);
/// Between two reads of the machine or its status file.
// timeout: the pause between polls, not a deadline; the wait's limit is DEFAULT_TIMEOUT or --timeout
const POLL: Duration = Duration::from_secs(3);

/// `vm new`'s words, split: the app's create words, and how long to wait.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct NewWait {
    pub(super) create: Vec<String>,
    pub(super) timeout: Duration,
    /// The name the VM gets (given, or made here).
    pub(super) name: String,
    /// A machine config is applied (`--machine-config`, or `--repo`'s checkout).
    pub(super) configured: bool,
}

/// `Some` when `tail` (the words after `vm new`) asks for `--wait`; `Err` for a bad `--timeout`.
pub(super) fn parse(
    tail: &[String],
    fresh_name: impl FnOnce() -> String,
) -> Option<Result<NewWait, String>> {
    if !tail.iter().take_while(|word| *word != "--").any(|word| word == "--wait") {
        return None;
    }
    let mut create = Vec::new();
    let mut timeout = DEFAULT_TIMEOUT;
    let mut name = None;
    let mut configured = false;
    let mut words = tail.iter();
    while let Some(word) = words.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        match flag {
            "--wait" => continue,
            "--timeout" => {
                let Some(value) = inline.or_else(|| words.next().cloned()) else {
                    return Some(Err("--timeout needs a number of seconds".to_owned()));
                };
                match value.parse::<u64>() {
                    Ok(seconds) if seconds > 0 => {
                        timeout = Duration::from_secs(seconds).min(MAX_TIMEOUT);
                    }
                    _ => return Some(Err(format!("--timeout {value}: a number of seconds"))),
                }
                continue;
            }
            "--name" => {
                name = inline.or_else(|| words.clone().next().cloned());
            }
            "--machine-config" | "--repo" => configured = true,
            _ => {}
        }
        create.push(word.clone());
    }
    let name = match name {
        Some(name) => name,
        None => {
            let made = fresh_name();
            create.extend(["--name".to_owned(), made.clone()]);
            made
        }
    };
    Some(Ok(NewWait { create, timeout, name, configured }))
}

/// A refusal this command prints, with what to run next.
fn refusal(code: &str, message: impl Into<String>, details: Value) -> Value {
    json!({"code": code, "message": message.into(), "details": details, "retryable": false})
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

/// `cmux vm new … --wait`: the create, then [`wait_until_ready`].
pub(super) fn new_and_wait(runner: &mut dyn Runner, request: &NewWait) -> Result<Value, Value> {
    let started = runner.now();
    let mut create = words(&["cloud", "new-machine"]);
    create.extend(request.create.iter().cloned());
    create.push("--json".to_owned());
    let created = step_result(&runner.cmux(&create))?;
    let id = text(&created, "machine_id").map(str::to_owned);
    wait_until_ready(
        runner,
        Ready {
            id,
            name: &request.name,
            configured: request.configured,
            started,
            timeout: request.timeout,
            created: &created,
            replaces: None,
        },
    )
}

/// What [`wait_until_ready`] waits on.
pub(super) struct Ready<'a> {
    /// The VM's id when the create answered with it; else it is found by `name`.
    pub(super) id: Option<String>,
    pub(super) name: &'a str,
    pub(super) configured: bool,
    pub(super) started: Instant,
    pub(super) timeout: Duration,
    /// The create's answer (its `machine_config.status` may already say `failed`).
    pub(super) created: &'a Value,
    /// The VM a redo deleted: never taken for the new one of the same name.
    pub(super) replaces: Option<&'a str>,
}

/// Running, then (for a configured VM) its config applied and its secrets delivered; one JSON answer.
pub(super) fn wait_until_ready(runner: &mut dyn Runner, ready: Ready<'_>) -> Result<Value, Value> {
    let deadline = ready.started + ready.timeout;
    if ready.created.pointer("/machine_config/status").and_then(Value::as_str) == Some("failed") {
        return Err(refusal(
            "vm.config_failed",
            "the machine config did not start on the new VM",
            json!({"machine_config": ready.created.get("machine_config")}),
        ));
    }
    let (id, title) =
        wait_running(runner, ready.id.as_deref(), ready.name, ready.replaces, deadline)?;
    let target = format!("vm:{id}");
    let mut answer = Map::new();
    answer.insert("machine_id".into(), json!(id));
    answer.insert("target".into(), json!(target));
    answer.insert("title".into(), json!(title));
    if ready.configured {
        let status = wait_config(runner, &id, deadline)?;
        answer.insert("machine_config".into(), status);
        answer.insert("secrets".into(), deliver(runner, &id, deadline)?);
    }
    let elapsed = runner.now().saturating_duration_since(ready.started);
    answer
        .insert("elapsed_ms".into(), json!(u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)));
    answer.insert(
        "next".into(),
        json!({
            "start_agent": format!("cmux vm start-session --target {target} --agent claude"),
            "terminal": format!("cmux vm ssh --target {target}"),
        }),
    );
    Ok(Value::Object(answer))
}

/// The VM's id and title once `list-machines` shows it running.
fn wait_running(
    runner: &mut dyn Runner,
    id: Option<&str>,
    name: &str,
    replaces: Option<&str>,
    deadline: Instant,
) -> Result<(String, String), Value> {
    let mut last = Value::Null;
    loop {
        let listed = step_result(&runner.cmux(&words(&["cloud", "list-machines", "--json"])))?;
        let rows = listed.get("machines").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
        let row = rows.iter().find(|row| match id {
            Some(id) => text(row, "machine_id") == Some(id),
            None => text(row, "title") == Some(name) && text(row, "machine_id") != replaces,
        });
        if let Some(row) = row {
            let status = text(row, "status").unwrap_or("unknown");
            let row_id = text(row, "machine_id").unwrap_or_default().to_owned();
            if status == "running" && !row_id.is_empty() {
                return Ok((row_id, text(row, "title").unwrap_or(name).to_owned()));
            }
            if matches!(status, "failed" | "destroyed" | "deleting") {
                return Err(refusal(
                    "vm.not_running",
                    format!("the new VM is {status}"),
                    json!({"machine_id": row_id, "status": status, "next": "cmux vm ls"}),
                ));
            }
            last = row.clone();
        }
        if runner.now() >= deadline {
            return Err(refusal(
                "vm.wait_timeout",
                format!("the VM {name} is not running yet; it goes on starting"),
                json!({"last": last, "next": "cmux vm ls"}),
            ));
        }
        runner.pause(POLL);
    }
}

/// The applier's status once its state is `done`; `failed` refuses with it.
fn wait_config(runner: &mut dyn Runner, id: &str, deadline: Instant) -> Result<Value, Value> {
    let target = format!("machine:{id}");
    let read =
        words(&["cloud", "file-read", "--target", &target, "--path", CONFIG_STATUS, "--json"]);
    let mut last = Value::Null;
    loop {
        // No status file yet (the applier has not started) is a wait, not a failure.
        if let Ok(answer) = step_result(&runner.cmux(&read))
            && let Some(status) =
                text(&answer, "text").and_then(|t| serde_json::from_str::<Value>(t).ok())
        {
            match text(&status, "state") {
                Some("done") => return Ok(status),
                Some("failed") => {
                    return Err(refusal(
                        "vm.config_failed",
                        "the machine config failed on the VM",
                        json!({"machine_id": id, "status": status, "log": CONFIG_LOG,
                               "next": format!("cmux vm file-read --target vm:{id} --path {CONFIG_LOG}")}),
                    ));
                }
                _ => last = status,
            }
        }
        if runner.now() >= deadline {
            return Err(refusal(
                "vm.wait_timeout",
                "the machine config is still applying; it goes on",
                json!({"machine_id": id, "last": last,
                       "next": format!("cmux vm file-read --target vm:{id} --path {CONFIG_STATUS}")}),
            ));
        }
        runner.pause(POLL);
    }
}

/// `cloud deliver-secrets` until it answers something other than `pending` or `delivering`.
fn deliver(runner: &mut dyn Runner, id: &str, deadline: Instant) -> Result<Value, Value> {
    let target = format!("machine:{id}");
    let ask = words(&["cloud", "deliver-secrets", "--target", &target, "--json"]);
    loop {
        let answer = step_result(&runner.cmux(&ask))?;
        let status = text(&answer, "status").unwrap_or("delivered");
        if !matches!(status, "pending" | "delivering") {
            return Ok(json!({
                "status": status,
                "delivered": answer.get("delivered").cloned().unwrap_or(json!([])),
                "missing": answer.get("missing").cloned().unwrap_or(json!([])),
            }));
        }
        if runner.now() >= deadline {
            return Err(refusal(
                "vm.wait_timeout",
                "the secrets are still being delivered; it goes on",
                json!({"machine_id": id, "next": format!("cmux vm deliver-secrets --target vm:{id}")}),
            ));
        }
        runner.pause(POLL);
    }
}

/// A new VM's name for a create with none: `vm-` and 12 hex characters.
pub(super) fn fresh_vm_name() -> String {
    let id = uuid::Uuid::new_v4().simple().to_string();
    format!("vm-{}", id.chars().take(12).collect::<String>())
}

/// Prints `result`: with `--json` the object, else one line a person reads; an error as the app's verbs print one.
pub(super) fn print(global: &GlobalArgs, result: Result<Value, Value>) -> i32 {
    match result {
        Ok(value) if global.output == super::OutputMode::Human => {
            let title = text(&value, "title").unwrap_or_default();
            let target = text(&value, "target").unwrap_or_default();
            let config = value.pointer("/machine_config/state").and_then(Value::as_str);
            let delivered =
                value.pointer("/secrets/delivered").and_then(Value::as_array).map_or(0, Vec::len);
            let missing: Vec<&str> = value
                .pointer("/secrets/missing")
                .and_then(Value::as_array)
                .map(|names| names.iter().filter_map(Value::as_str).collect())
                .unwrap_or_default();
            let mut line = format!("{title} ({target}) is ready");
            if let Some(state) = config {
                line.push_str(&format!(": machine config {state}, {delivered} secrets delivered"));
                if !missing.is_empty() {
                    line.push_str(&format!(
                        ", missing {} (cmux vm secret set NAME)",
                        missing.join(", ")
                    ));
                }
            }
            println!("{line}.");
            println!(
                "  start an agent:  {}",
                value.pointer("/next/start_agent").and_then(Value::as_str).unwrap_or_default()
            );
            println!(
                "  open a terminal: {}",
                value.pointer("/next/terminal").and_then(Value::as_str).unwrap_or_default()
            );
            0
        }
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    }
}

/// `cmux vm new … --wait` with the app: `Some(exit code)`; `None` when `tail` has no `--wait`.
pub(super) fn run_if_requested(global: &GlobalArgs, tail: &[String]) -> Option<i32> {
    let request = match parse(tail, fresh_vm_name)? {
        Ok(request) => request,
        Err(message) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {message}"),
                global.output,
                2,
            ));
        }
    };
    let mut runner = super::cloud_start_chat::self_runner(global);
    Some(print(global, new_and_wait(&mut runner, &request)))
}
