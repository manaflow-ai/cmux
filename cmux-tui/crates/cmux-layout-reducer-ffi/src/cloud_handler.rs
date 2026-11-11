//! `cmux-cloud-handlers` over the JSON channel (ops `cloud_handler_*`): the
//! Cloud action handlers' argument checks, decisions, result fields and answer
//! text. The app sends the invocation's arguments and the facts its models
//! hold, and acts on the answer. A refusal comes back as `{"refusal": Said}`
//! (a key into the app's localized strings, with the values it names).

use cmux_cloud_handlers::{Said, answers, args, decide, fields};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_handler_")
}

fn read<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn value<T: serde::Serialize>(value: T) -> Result<Value, i32> {
    serde_json::to_value(value).map_err(|_| ERR_INVALID)
}

/// `{"value": …}` or `{"refusal": …}`.
fn checked<T: serde::Serialize>(result: Result<T, Said>) -> Result<Value, i32> {
    Ok(match result {
        Ok(ok) => json!({ "value": value(ok)? }),
        Err(refusal) => json!({ "refusal": value(refusal)? }),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Arg {
    check: String,
    #[serde(default)]
    args: args::Args,
    #[serde(default)]
    home: String,
    /// The port verb (`open-browser`) a `namedPort` refusal names.
    #[serde(default)]
    verb: String,
    /// The machine and port a `namedPort` or `browserPath` refusal names.
    #[serde(default)]
    names: args::PortNames,
    /// The machine a `machineWorkspace` refusal names.
    #[serde(default)]
    machine: String,
    /// The refusal key of an `id` check (`publicationRequired`).
    #[serde(default)]
    missing: String,
    /// The idle pause choices, in minutes (0 is `off`).
    #[serde(default)]
    choices: Vec<i64>,
}

fn arg(request: &Arg) -> Result<Value, i32> {
    let given = &request.args;
    match request.check.as_str() {
        "command" => checked(args::command(given)),
        "filePath" => checked(args::file_path(given)),
        "port" => checked(args::port(given)),
        "namedPort" => checked(args::named_port(given, &request.verb, &request.names)),
        "idlePause" => checked(args::idle_pause_minutes(given, &request.choices)),
        "machineWorkspace" => checked(args::machine_workspace(given, &request.machine)),
        "id" => {
            let missing = match request.missing.as_str() {
                "publicationRequired" => "publicationRequired",
                _ => return Err(ERR_INVALID),
            };
            checked(args::id_argument(given, missing))
        }
        "browserPath" => checked(args::browser_path(given, &request.names)),
        "resize" => checked(args::resize(given)),
        "provisionAPI" => checked(args::provision_api(given)),
        "applyMachineConfig" => checked(args::apply_machine_config(given, &request.home)),
        "newMachine" => checked(args::new_machine(given, &request.home)),
        other => checked(args::needed(given, other, &request.names)),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Route {
    #[serde(default)]
    has_target: bool,
    #[serde(default)]
    connected: bool,
    #[serde(default)]
    by_user: bool,
    #[serde(default)]
    has_window: bool,
    #[serde(default)]
    is_default: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreationFacts {
    #[serde(default)]
    torn_down: bool,
    #[serde(default)]
    has_workspace: bool,
    #[serde(default)]
    listed: bool,
    #[serde(default)]
    has_session: bool,
    #[serde(default)]
    failed: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Diagnostics {
    unavailable: Option<String>,
    #[serde(default)]
    signed_in: bool,
    #[serde(default)]
    machines: Vec<decide::Diagnosed>,
    #[serde(default)]
    account_label: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TeamPick {
    #[serde(default)]
    teams: Vec<decide::Team>,
    active: Option<String>,
    team: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GitHubConfirm {
    name: Option<String>,
    email: Option<String>,
    app: decide::GitHubApp,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Facts {
    #[serde(default)]
    machine_id: String,
    #[serde(default)]
    extra: Map<String, Value>,
    #[serde(default)]
    paused: bool,
    #[serde(default)]
    surface: String,
    terminal: Option<String>,
    machine: Option<fields::Machine>,
    workspace_id: Option<String>,
    #[serde(default)]
    request: args::NewMachine,
    made: Option<fields::Created>,
    outcome: Option<fields::Outcome>,
    status: Option<fields::Status>,
    list: Option<fields::MachineList>,
    #[serde(default)]
    unix: i64,
    #[serde(default)]
    title: String,
    #[serde(default)]
    provider: String,
    #[serde(default)]
    state: String,
    record: Option<Value>,
    ipv4: Option<String>,
    /// The machine and port a port answer or refusal names.
    #[serde(default)]
    names: args::PortNames,
    /// Whether the machine's provider opens port links.
    #[serde(default)]
    allows_ports: bool,
    link: Option<answers::ShareLink>,
    #[serde(default)]
    url: String,
    code: Option<String>,
    #[serde(default)]
    text: String,
}

/// An answer, or `{"refusal": …}`.
fn answered(result: Result<answers::Answer, Said>) -> Result<Value, i32> {
    match result {
        Ok(answer) => value(answer),
        Err(refusal) => Ok(json!({ "refusal": value(refusal)? })),
    }
}

fn fields_of(fields: Map<String, Value>) -> Value {
    json!({ "fields": Value::Object(fields) })
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // One argument check (`check`): `{"value"}` or `{"refusal"}`.
        b"cloud_handler_arg" => arg(&read(request)?)?,
        b"cloud_handler_machine_pick" => {
            let lookup: decide::Lookup = read(request)?;
            match decide::machine(&lookup) {
                Ok(pick) => json!({ "pick": value(pick)? }),
                Err(refusal) => json!({ "refusal": value(refusal)? }),
            }
        }
        b"cloud_handler_new_workspace" => {
            let r: Route = read(request)?;
            json!({ "route": value(decide::new_workspace(r.has_target, r.connected, r.by_user, r.has_window))? })
        }
        b"cloud_handler_new_machine_start" => {
            let r: Route = read(request)?;
            json!({ "start": value(decide::new_machine_start(r.is_default, r.by_user, r.has_window))? })
        }
        b"cloud_handler_setup_readiness" => {
            let c: CreationFacts = read(request)?;
            json!({ "readiness": value(decide::setup_readiness(c.torn_down, c.has_workspace, c.listed))? })
        }
        b"cloud_handler_creation" => {
            let c: CreationFacts = read(request)?;
            json!({ "state": value(decide::creation(c.listed, c.has_session, c.failed))? })
        }
        // A CLI's `new-machine` once its creation settled (or the wait ended).
        b"cloud_handler_settled" => {
            let settled: decide::Settled = read(request)?;
            match decide::settled(&settled) {
                Ok(fields) => fields_of(fields),
                Err(failure) => json!({ "failure": value(failure)? }),
            }
        }
        b"cloud_handler_diagnostics" => {
            let d: Diagnostics = read(request)?;
            let summary = decide::diagnostics_summary(
                d.unavailable.as_deref(),
                d.signed_in,
                &d.machines,
                &d.account_label,
            );
            json!({ "summary": value(summary)? })
        }
        b"cloud_handler_team" => {
            let t: TeamPick = read(request)?;
            match decide::team(&t.teams, t.active.as_deref(), t.team.as_deref()) {
                Ok(select) => json!({ "select": select }),
                Err(refusal) => json!({ "refusal": value(refusal)? }),
            }
        }
        b"cloud_handler_github_confirm" => {
            let g: GitHubConfirm = read(request)?;
            json!({ "parts": value(decide::github_confirm(g.name.as_deref(), g.email.as_deref(), g.app))? })
        }
        b"cloud_handler_answer" => {
            let found: answers::Found = read(request)?;
            value(answers::of(&found))?
        }
        b"cloud_handler_constants" => {
            let sizes: Map<String, Value> = args::CREATE_SIZES
                .iter()
                .map(|(name, cpu, memory)| {
                    ((*name).to_owned(), json!({ "cpu": cpu, "memoryMb": memory }))
                })
                .collect();
            let resize: Map<String, Value> = args::RESIZE_SIZES
                .iter()
                .map(|(name, cpu, memory)| {
                    ((*name).to_owned(), json!({ "cpu": cpu, "memoryMb": memory }))
                })
                .collect();
            json!({ "toolsProbe": answers::TOOLS_PROBE, "createSizes": sizes, "resizeSizes": resize,
                    "planRequiredCode": decide::PLAN_REQUIRED_CODE })
        }
        _ => facts(operation, read(request)?)?,
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

/// The ops that shape result fields and text from facts.
fn facts(operation: &[u8], f: Facts) -> Result<Value, i32> {
    Ok(match operation {
        b"cloud_handler_machine_fields" => {
            fields_of(fields::machine_fields(&f.machine_id, f.extra))
        }
        b"cloud_handler_deletion_pending" => fields_of(fields::deletion_pending(&f.machine_id)),
        b"cloud_handler_terminal_pending" => {
            fields_of(fields::terminal_pending(&f.machine_id, f.paused))
        }
        b"cloud_handler_terminal_fields" => {
            fields_of(fields::terminal_fields(&f.surface, f.terminal.as_deref()))
        }
        b"cloud_handler_created_machine" => fields_of(fields::created_machine(
            &f.machine.ok_or(ERR_INVALID)?,
            f.workspace_id.as_deref(),
        )),
        b"cloud_handler_new_machine_fields" => {
            fields_of(fields::new_machine(&f.request, f.machine.as_ref()))
        }
        b"cloud_handler_created" => {
            fields_of(fields::created(&f.request, &f.made.ok_or(ERR_INVALID)?))
        }
        b"cloud_handler_machine_config" => {
            json!({ "answer": fields::machine_config(&f.outcome.ok_or(ERR_INVALID)?, &f.machine_id) })
        }
        b"cloud_handler_status" => {
            let status = f.status.ok_or(ERR_INVALID)?;
            json!({ "fields": Value::Object(fields::status_fields(&status)), "text": fields::describe(&status) })
        }
        b"cloud_handler_machine_list" => {
            fields_of(fields::machine_list(&f.list.ok_or(ERR_INVALID)?))
        }
        b"cloud_handler_template_name" => {
            json!({ "name": fields::template_name(&f.machine_id, f.unix) })
        }
        b"cloud_handler_handoff" => {
            json!({ "text": fields::handoff(&f.title, &f.machine_id, &f.provider, &f.state) })
        }
        b"cloud_handler_forward" => {
            answered(answers::forward(&f.record.ok_or(ERR_INVALID)?, &f.names))?
        }
        // `machine-link`: its answer, or `{"refusal"}` (`portNoLink`).
        b"cloud_handler_machine_link" => answered(answers::machine_link(
            &f.names,
            f.ipv4.as_deref(),
            f.allows_ports,
            f.link.as_ref(),
        ))?,
        // Before the app makes a share link: `{}`, or `{"refusal"}` when the machine has none.
        b"cloud_handler_machine_link_port" => {
            match answers::machine_link_port(&f.names, f.allows_ports) {
                Ok(()) => json!({}),
                Err(refusal) => json!({ "refusal": value(refusal)? }),
            }
        }
        // A share link the platform returned: `ok`, and when it is not, the refusal naming the
        // machine and port.
        b"cloud_handler_share_link" => {
            let ok = answers::share_link_ok(&f.url);
            let refusal = (!ok).then(|| {
                f.names.said("portFailed", &["the platform returned an invalid share URL"])
            });
            json!({ "ok": ok, "refusal": value(refusal)? })
        }
        b"cloud_handler_port_failure" => {
            json!({ "refusal": value(decide::port_failure(f.code.as_deref(), &f.text, &f.names))? })
        }
        _ => return Err(ERR_INVALID),
    })
}
