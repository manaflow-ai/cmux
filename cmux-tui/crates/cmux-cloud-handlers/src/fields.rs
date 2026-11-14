//! The `action.run` result fields of the Cloud machine actions, from the facts
//! the app reads off its machine models and the Cloud API's answers.

use serde::Deserialize;
use serde_json::{Value, json};

use crate::Fields;
use crate::args::{BootstrapKind, NewMachine, create_size};
use crate::time;

fn object(value: Value) -> Fields {
    match value {
        Value::Object(map) => map,
        _ => Fields::new(),
    }
}

/// A machine action's result: `extra`, then the machine's id and the `--target` that names it
/// in the next command (those two win over `extra`'s).
pub fn machine_fields(machine_id: &str, mut extra: Fields) -> Fields {
    extra.insert("machine_id".into(), json!(machine_id));
    extra.insert("target".into(), json!(format!("machine:{machine_id}")));
    extra
}

/// The `pending` answer of a kill that outlasted its wait.
pub fn deletion_pending(machine_id: &str) -> Fields {
    machine_fields(machine_id, object(json!({"pending": true, "status": "deleting"})))
}

/// The `pending` answer of a terminal run that outlasted its wait: a paused machine says it resumes.
pub fn terminal_pending(machine_id: &str, paused: bool) -> Fields {
    let mut fields = object(json!({"machine_id": machine_id}));
    if paused {
        fields.insert("resuming".into(), json!(true));
    }
    fields
}

/// A terminal tab's ids on the machine's daemon: `surface_id` and, from daemons that report
/// one, the durable `terminal_id`.
pub fn terminal_fields(surface: &str, terminal: Option<&str>) -> Fields {
    let mut fields = object(json!({"surface_id": surface}));
    if let Some(terminal) = terminal {
        fields.insert("terminal_id".into(), json!(terminal));
    }
    fields
}

/// The facts of a machine the server returned.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Machine {
    pub id: String,
    pub title: String,
    /// The record's status as the app shows it (`effectiveStatus`).
    pub status: String,
    pub display_name: Option<String>,
    pub size_name: Option<String>,
    pub cpu: Option<i64>,
    pub memory_mb: Option<i64>,
    pub idle_pause_minutes: Option<i64>,
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
}

/// A created machine's answer: its id, title, status, target and, once open, its workspace.
pub fn created_machine(machine: &Machine, workspace_id: Option<&str>) -> Fields {
    let mut fields = object(json!({
        "machine_id": machine.id, "title": machine.title, "status": machine.status,
        "target": format!("machine:{}", machine.id),
    }));
    if let Some(workspace) = workspace_id {
        fields.insert("workspace_id".into(), json!(workspace));
    }
    fields
}

/// The request's facts next to the machine's. `persistent` is what the server stored, not what
/// was asked (`persistent_requested`); a `pending` answer, with no machine yet, has no `persistent`.
pub fn new_machine(request: &NewMachine, machine: Option<&Machine>) -> Fields {
    let mut fields = object(json!({"persistent_requested": request.persistent}));
    if let Some(name) =
        machine.and_then(|m| m.display_name.clone()).or_else(|| request.name.clone())
    {
        fields.insert("name".into(), json!(name));
    }
    let asked = request
        .size
        .as_deref()
        .and_then(|size| create_size(size).map(|(cpu, memory)| (size, cpu, memory)));
    if let Some(size) = asked
        .map(|(size, ..)| size.to_owned())
        .or_else(|| machine.and_then(|m| m.size_name.clone()))
    {
        fields.insert("size".into(), json!(size));
    }
    if let Some(cpu) = machine.and_then(|m| m.cpu).or(asked.map(|(_, cpu, _)| cpu)) {
        fields.insert("cpu".into(), json!(cpu));
    }
    if let Some(memory) = machine.and_then(|m| m.memory_mb).or(asked.map(|(.., memory)| memory)) {
        fields.insert("memory_mb".into(), json!(memory));
    }
    if let Some(machine) = machine {
        fields.insert("persistent".into(), json!(machine.idle_pause_minutes == Some(0)));
        if let Some(minutes) = machine.idle_pause_minutes {
            fields.insert("idle_pause_minutes".into(), json!(minutes));
        }
        if let Some(address) = machine.ipv4.as_ref().or(machine.ipv6.as_ref()) {
            fields.insert("address".into(), json!(address));
        }
    }
    fields
}

/// What is left to make a lane machine a fleet host: the registry entries leo-workspace keeps
/// (`tools/lane-vm-enroll`). A persistent machine the server still pauses says how to finish.
pub fn enrollment(request: &NewMachine, machine: &Machine) -> Fields {
    let mut pending = vec![json!("fleet-registry")];
    if request.persistent && machine.idle_pause_minutes != Some(0) {
        // The create and the PUT after it both left the default: say how to finish.
        pending.insert(
            0,
            json!(format!(
                "idle-pause: cmux cloud set-idle-pause --target machine:{} --minutes off",
                machine.id
            )),
        );
    }
    let mut answer = object(json!({"done": [], "pending": pending}));
    if let (BootstrapKind::Lane, Some(_), Some(name)) =
        (request.bootstrap_kind, &request.bootstrap_path, &request.name)
    {
        let address =
            machine.ipv4.as_ref().map(|ip| format!(" --address {ip}")).unwrap_or_default();
        answer.insert(
            "registry_command".into(),
            json!(format!("tools/lane-vm-enroll {name} {}{address} --apply", machine.id)),
        );
    }
    answer
}

/// How a bootstrap or machine-config start went, and where it writes.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Outcome {
    pub status: String,
    pub reason: Option<String>,
    pub status_file: String,
    pub log: String,
}

fn check_command(machine_id: &str, status_file: &str) -> String {
    format!("cmux cloud file-read --target machine:{machine_id} --path {status_file}")
}

/// The `machine_config` answer of a start: its status and how to read it.
pub fn machine_config(outcome: &Outcome, machine_id: &str) -> Value {
    let mut answer = object(json!({
        "status": outcome.status, "status_file": outcome.status_file, "log": outcome.log,
        "check": check_command(machine_id, &outcome.status_file),
    }));
    if let Some(reason) = &outcome.reason {
        answer.insert("reason".into(), json!(reason));
    }
    Value::Object(answer)
}

/// What a `cloud new-machine` with options made.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Created {
    pub machine: Machine,
    pub workspace_id: Option<String>,
    /// The bootstrap's kind (`plain`, `lane`) when a script went with the machine, and how it went.
    pub script_kind: Option<String>,
    pub bootstrap: Option<Outcome>,
    /// The machine config's start (answered only when the request asked for one).
    pub machine_config: Option<Outcome>,
}

/// The answer of a `cloud new-machine` with options: the machine's facts, the request's,
/// `bootstrap`, `repo` (the request's), `machine_config` (when the request asked for one) and
/// `enrollment`.
pub fn created(request: &NewMachine, made: &Created) -> Fields {
    let mut fields = created_machine(&made.machine, made.workspace_id.as_deref());
    fields.extend(new_machine(request, Some(&made.machine)));
    let mut bootstrap = object(json!({"status": "none"}));
    if let (Some(kind), Some(outcome)) = (&made.script_kind, &made.bootstrap) {
        bootstrap = object(json!({
            "status": outcome.status, "kind": kind, "log": outcome.log, "status_file": outcome.status_file,
            "check": check_command(&made.machine.id, &outcome.status_file),
        }));
        if let Some(reason) = &outcome.reason {
            bootstrap.insert("reason".into(), json!(reason));
        }
    }
    if let Some(repo) = &request.repo {
        // The clone runs in the bootstrap; its result lands later in the status file's `repo`,
        // which `check` reads.
        let check = bootstrap.get("check").cloned().unwrap_or_else(|| json!("none"));
        fields.insert(
            "repo".into(),
            json!({"spec": repo.spec, "url": repo.url, "dir": format!("~/{}", repo.directory), "check": check}),
        );
    }
    fields.insert("bootstrap".into(), Value::Object(bootstrap));
    if let (Some(_), Some(outcome)) = (&request.machine_config_path, &made.machine_config) {
        fields.insert("machine_config".into(), machine_config(outcome, &made.machine.id));
    }
    fields.insert("enrollment".into(), Value::Object(enrollment(request, &made.machine)));
    fields
}

/// `template-<first 12 of the id>-<unix seconds>`, the old CLI's name.
pub fn template_name(machine_id: &str, unix: i64) -> String {
    let prefix: String = machine_id.chars().take(12).collect();
    format!("template-{prefix}-{unix}")
}

/// The handoff text, with the CLI verbs that open a terminal on the machine and report on it.
pub fn handoff(title: &str, id: &str, provider: &str, status: &str) -> String {
    let target = format!("--target machine:{id}");
    let provider = if provider.is_empty() { "?" } else { provider };
    [
        format!("{title} ({id})"),
        format!("provider: {provider}"),
        format!("status: {status}"),
        format!("attach: cmux cloud new-terminal-on-machine {target}"),
        format!("inspect: cmux cloud machine-status {target}"),
    ]
    .join("\n")
}

/// The facts `cloud machine-status` reports.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Status {
    pub machine_id: String,
    pub title: String,
    pub status: String,
    pub state: String,
    pub cpus: Option<i64>,
    pub cpu_percent: Option<f64>,
    pub memory_used_mb: Option<f64>,
    pub memory_total_mb: Option<f64>,
    pub disk_used_mb: Option<f64>,
    pub disk_total_mb: Option<f64>,
    pub ipv4: Option<String>,
    pub desktop: bool,
    pub cost: Option<Cost>,
    pub idle_pause: Option<IdlePause>,
    pub failure: Option<Failure>,
}

/// The machine's cost, from server facts: the rate, since when it runs (unix seconds) and what
/// that cost so far; `usage` is the app's own line for it.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Cost {
    pub hourly_rate_usd: Option<f64>,
    pub running_since: Option<f64>,
    pub estimated_cost_usd: Option<f64>,
    pub usage: Option<String>,
}

/// The server's idle cron diagnostics.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IdlePause {
    pub minutes: i64,
    pub last_checked_at: Option<i64>,
    pub idle_since: Option<i64>,
    pub last_api_activity_at: Option<i64>,
    pub private_address_known: bool,
    pub last_decision: Option<Decision>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Decision {
    pub at: i64,
    pub outcome: String,
    pub reason: String,
    /// The cron run that decided, nested as the server's record has it.
    pub run: Run,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Run {
    pub checked: i64,
    pub elapsed_ms: i64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct Failure {
    pub code: String,
    pub message: String,
}

/// The cost as fields: `hourly_rate_usd`, `running_since` (ISO 8601) and `estimated_cost_usd`
/// (to four places). A paused machine has no `running_since` or estimate.
pub fn cost_fields(cost: &Cost) -> Fields {
    let mut fields = Fields::new();
    if let Some(rate) = cost.hourly_rate_usd {
        fields.insert("hourly_rate_usd".into(), json!(rate));
    }
    if let Some(since) = cost.running_since {
        fields.insert("running_since".into(), json!(time::iso8601(since)));
    }
    if let Some(spent) = cost.estimated_cost_usd {
        fields.insert("estimated_cost_usd".into(), json!((spent * 10_000.0).round() / 10_000.0));
    }
    fields
}

/// The idle cron diagnostics, nested as the server's record has them, in snake case.
pub fn idle_pause_fields(idle: &IdlePause) -> Fields {
    let decision = idle.last_decision.as_ref().map_or(Value::Null, |d| {
        json!({"at": d.at, "outcome": d.outcome, "reason": d.reason,
               "run": {"checked": d.run.checked, "elapsed_ms": d.run.elapsed_ms}})
    });
    object(json!({
        "minutes": idle.minutes, "last_checked_at": idle.last_checked_at, "idle_since": idle.idle_since,
        "last_api_activity_at": idle.last_api_activity_at, "private_address_known": idle.private_address_known,
        "last_decision": decision,
    }))
}

/// `cloud machine-status`'s fields.
pub fn status_fields(status: &Status) -> Fields {
    let mut fields = object(json!({
        "machine_id": status.machine_id, "title": status.title, "state": status.state, "status": status.status,
    }));
    let mut put = |name: &str, value: Option<Value>| {
        if let Some(value) = value {
            fields.insert(name.into(), value);
        }
    };
    put("cpus", status.cpus.map(Value::from));
    put("cpu_percent", status.cpu_percent.map(Value::from));
    put("memory_used_mb", status.memory_used_mb.map(Value::from));
    put("memory_total_mb", status.memory_total_mb.map(Value::from));
    put("disk_used_mb", status.disk_used_mb.map(Value::from));
    put("disk_total_mb", status.disk_total_mb.map(Value::from));
    put("address", status.ipv4.clone().map(Value::from));
    fields.insert("desktop".into(), json!(status.desktop));
    if let Some(cost) = &status.cost {
        fields.extend(cost_fields(cost));
    }
    if let Some(idle) = &status.idle_pause {
        fields.insert("idle_pause".into(), Value::Object(idle_pause_fields(idle)));
    }
    if let Some(failure) = &status.failure {
        fields.insert("error".into(), json!({"code": failure.code, "message": failure.message}));
    }
    fields
}

fn or_null(value: Option<i64>) -> String {
    value.map_or_else(|| "null".to_owned(), |v| v.to_string())
}

/// `cloud machine-status`'s text.
pub fn describe(status: &Status) -> String {
    let mut lines = vec![
        format!("{} ({})", status.title, status.machine_id),
        format!("state: {}, status: {}", status.state, status.status),
    ];
    if let Some(failure) = &status.failure {
        lines.push(format!("error: {}: {}", failure.code, failure.message));
    }
    if let Some(cpus) = status.cpus {
        let percent = status.cpu_percent.map(|p| format!(", {p:.0}%")).unwrap_or_default();
        lines.push(format!("cpus: {cpus}{percent}"));
    }
    if let (Some(used), Some(total)) = (status.memory_used_mb, status.memory_total_mb) {
        lines.push(format!("memory: {used:.0} / {total:.0} MB"));
    }
    if let (Some(used), Some(total)) = (status.disk_used_mb, status.disk_total_mb) {
        lines.push(format!("disk: {used:.0} / {total:.0} MB"));
    }
    if let Some(address) = &status.ipv4 {
        lines.push(format!("address: {address}"));
    }
    if let Some(usage) = status.cost.as_ref().and_then(|cost| cost.usage.clone()) {
        lines.push(usage);
    }
    if let Some(idle) = &status.idle_pause {
        lines.push(format!("idle pause: {} minutes", idle.minutes));
        lines.push(format!("idle pause last checked: {}", or_null(idle.last_checked_at)));
        lines.push(format!("idle pause idle since: {}", or_null(idle.idle_since)));
        lines.push(format!("idle pause last API activity: {}", or_null(idle.last_api_activity_at)));
        lines.push(format!("idle pause private address known: {}", idle.private_address_known));
        lines.push(match &idle.last_decision {
            Some(d) => format!(
                "idle pause decision: {} ({}) at {}; run checked={}, elapsed_ms={}",
                d.outcome, d.reason, d.at, d.run.checked, d.run.elapsed_ms
            ),
            None => "idle pause decision: null".to_owned(),
        });
    }
    lines.join("\n")
}

/// One machine of `cloud list-machines`.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Listed {
    pub machine_id: String,
    pub title: String,
    pub status: String,
    pub created_by: Option<String>,
    /// Unix seconds.
    pub created_at: Option<f64>,
    pub failure: Option<Failure>,
}

/// One create still on its way: its id, the name it asked for, and its failure if it failed.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Creating {
    pub creation_id: String,
    pub name: Option<String>,
    pub failed: Option<String>,
}

/// What the app's machine list holds.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct MachineList {
    /// The store holds a list the server answered for the signed-in user and team.
    pub loaded: bool,
    pub team: bool,
    pub signed_in: bool,
    pub machines: Vec<Listed>,
    pub creating: Vec<Creating>,
}

/// `cloud list-machines`' result: `loaded`, `machines`, `count`, `creating` and `account`.
/// Before the store is loaded the answer has no machines: a caller never reads "not loaded
/// yet" as "none" and creates a second one.
pub fn machine_list(list: &MachineList) -> Fields {
    let owner = if list.team { "team" } else { "personal" };
    let machines: Vec<Value> = if list.loaded {
        list.machines
            .iter()
            .map(|m| {
                json!({
                    "machine_id": m.machine_id, "target": format!("machine:{}", m.machine_id), "title": m.title,
                    "status": m.status, "owner": owner, "created_by": m.created_by,
                    "created_at": m.created_at.map(time::iso8601),
                    "error": m.failure.as_ref().map(|f| json!({"code": f.code, "message": f.message})),
                })
            })
            .collect()
    } else {
        Vec::new()
    };
    let creating: Vec<Value> = list
        .creating
        .iter()
        .map(|c| {
            let mut row =
                object(json!({"creation_id": c.creation_id, "name": c.name, "status": "creating"}));
            if let Some(reason) = &c.failed {
                row.insert("status".into(), json!("failed"));
                row.insert("reason".into(), json!(reason));
            }
            Value::Object(row)
        })
        .collect();
    object(json!({
        "loaded": list.loaded, "count": machines.len(), "machines": machines, "creating": creating,
        "account": {"signed_in": list.signed_in},
    }))
}

#[cfg(test)]
#[path = "fields/tests.rs"]
mod tests;
