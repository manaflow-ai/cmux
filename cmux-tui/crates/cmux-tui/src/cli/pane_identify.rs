//! `cmux identify` in a cmux-tui pane: the pane's own session, machine and
//! caller path, read from the session daemon.
//!
//! The classic `cmux identify` asks the cmux app (`system.identify`). In a
//! cmux-tui pane whose session no app owns (a standalone cmux-tui, or one
//! started in a cmux app terminal, which inherits that app's
//! `CMUX_SOCKET_PATH`), the app does not know the pane and answered
//! `caller.found false`. There the innermost multiplexer answers instead
//! (pane_context.rs). `cmux app identify` and `--app-socket` still ask the app.
//!
//! Where no cmux app can be found at all (a headless session on a runner,
//! `--session NAME` or `CMUX_TUI_SOCKET` naming a session no app owns), the
//! session daemon answers too: the same identity with `app_connected: false`,
//! `app: null` and the app's `app_error`, exit 0. Only the app commands need
//! the app; `identify` says where the caller runs.

use std::io::{BufReader, Write as _};
use std::path::Path;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::pane_context::{self, Innermost};
use super::resolve::{self, Failure};
use super::{GlobalArgs, OutputMode};

/// `Some(exit code)` when `args` is `identify` run in a cmux-tui pane with no
/// explicit route; `None` lets the app answer.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    if !super::app::is_classic_identify(&command_args) {
        return None;
    }
    if !explicitly_routed(&global)
        && let Innermost::SessionPane { socket, terminal } = pane_context::innermost()
    {
        return Some(run(&global, &socket, &terminal));
    }
    run_headless(&global)
}

/// `identify` with no cmux app to ask: the session daemon's answer, marked
/// `app_connected: false`. `None` (the app's own error stands) when an app
/// socket is found or named, or no session daemon answers either.
fn run_headless(global: &GlobalArgs) -> Option<i32> {
    // `--socket` and `--app-socket` name the app socket here, and
    // `--machine` another machine: those keep the classic answer.
    if global.socket.is_some() || global.app_socket.is_some() || global.machine.is_some() {
        return None;
    }
    let app_error = super::app::command_socket(global).err()?;
    let (socket, derived) = super::wire::resolve_socket_with_origin(global).ok()?;
    let terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|id| id.starts_with("term_"));
    let identity = read_identity_at(&socket, derived, terminal.as_deref()).ok()?;
    let identity = with_daemon_build(identity, &socket);
    Some(print(global, &without_app(identity, &app_error)))
}

/// `identity` marked as answered with no cmux app: `app_error` is why none
/// was reached (`app.not_found`, `socket.no_app`).
fn without_app(mut identity: Value, app_error: &Value) -> Value {
    if let Some(object) = identity.as_object_mut() {
        object.insert("app_connected".into(), Value::Bool(false));
        object.insert("app".into(), Value::Null);
        let pick = |key: &str| app_error.get(key).cloned().unwrap_or(Value::Null);
        object
            .insert("app_error".into(), json!({"code": pick("code"), "message": pick("message")}));
    }
    identity
}

/// A route the caller named keeps its classic meaning (`--socket` and
/// `--app-socket` name the app socket there; `--session` and `--machine`
/// name another session than the pane's).
fn explicitly_routed(global: &GlobalArgs) -> bool {
    global.socket.is_some()
        || global.app_socket.is_some()
        || global.session.is_some()
        || global.machine.is_some()
}

fn run(global: &GlobalArgs, socket: &Path, terminal: &str) -> i32 {
    match read_identity(socket, terminal) {
        Ok(identity) => print(global, &with_daemon_build(identity, socket)),
        Err(failure) => failure.report(global.output),
    }
}

fn print(global: &GlobalArgs, identity: &Value) -> i32 {
    match global.output {
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(human(identity).as_bytes());
            let _ = stdout.flush();
            0
        }
        output => super::wire::print_local_success(identity, output),
    }
}

/// A local daemon answers these reads at once; a stuck one fails the call.
// timeout: a stuck local daemon fails the read instead of hanging the CLI.
const READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// The pane's identity from the daemon at `socket`.
pub(super) fn read_identity(socket: &Path, terminal: &str) -> Result<Value, Failure> {
    read_identity_at(socket, false, Some(terminal))
}

/// The identity from the daemon at `socket` (`derived`: a path in cmux's
/// own runtime directory). With no `terminal`, the caller runs in no cmux
/// terminal and `caller.found` is false.
fn read_identity_at(
    socket: &Path,
    derived: bool,
    terminal: Option<&str>,
) -> Result<Value, Failure> {
    let stream =
        cmux_tui_core::server::connect_session_socket(socket, derived).map_err(|error| {
            Failure::Local {
                error: json!({
                    "code": "socket.unreachable",
                    "message": format!(
                        "cannot reach this pane's cmux-tui session at {}: {error}",
                        socket.display()
                    ),
                    "details": {"socket": socket.display().to_string()},
                    "retryable": true,
                }),
                exit: 3,
            }
        })?;
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let mut reader = BufReader::new(stream);
    let mut read = |operation, extra: Option<(&str, &str)>| {
        let mut params = route(operation);
        if let Some((key, value)) = extra {
            params.insert(key.into(), Value::String(value.to_owned()));
        }
        resolve::read(&mut reader, operation, params)
    };
    let session = read(ResourceOperation::SessionGet, None)?;
    let machine = read(ResourceOperation::MachineGet, None)?;
    let mut records = CallerRecords::default();
    let caller = match terminal {
        None => json!({
            "found": false,
            "terminal_id": null,
            "error": {
                "code": "caller.outside",
                "message": "this command runs in no cmux terminal (CMUX_TUI_TERMINAL_ID is unset)",
            },
        }),
        Some(terminal) => match caller_records(&mut read, terminal, &mut records) {
            Ok(()) => records.caller(terminal),
            Err(Failure::Resource(error)) => json!({
                "found": false,
                "terminal_id": terminal,
                "error": error,
            }),
            Err(failure) => return Err(failure),
        },
    };
    Ok(identity_value(socket, &session, &machine, caller, outer_app()))
}

/// Every read names the local machine; all but `machine.get` (which takes
/// no session) also name the socket's own session.
fn route(operation: ResourceOperation) -> Map<String, Value> {
    let mut params = Map::new();
    params.insert("machine".into(), json!("current"));
    if operation != ResourceOperation::MachineGet {
        params.insert("session".into(), json!("current"));
    }
    params
}

/// The records on the caller's path, terminal up to workspace.
#[derive(Default)]
struct CallerRecords {
    tab: Value,
    pane: Value,
    screen: Value,
    workspace: Value,
}

impl CallerRecords {
    fn caller(&self, terminal: &str) -> Value {
        let id = |record: &Value| record.get("id").cloned().unwrap_or(Value::Null);
        let name = |record: &Value| record.get("name").cloned().unwrap_or(Value::Null);
        json!({
            "found": true,
            "terminal_id": terminal,
            "tab": id(&self.tab),
            "tab_name": name(&self.tab),
            "pane": id(&self.pane),
            "screen": id(&self.screen),
            "screen_name": name(&self.screen),
            "workspace": id(&self.workspace),
            "workspace_name": name(&self.workspace),
        })
    }
}

/// Follows `terminal` up to its workspace (`caller_path_of` in resolve.rs,
/// keeping each record for its name).
fn caller_records(
    read: &mut impl FnMut(ResourceOperation, Option<(&str, &str)>) -> Result<Value, Failure>,
    terminal: &str,
    records: &mut CallerRecords,
) -> Result<(), Failure> {
    let terminal_record = read(ResourceOperation::TerminalGet, Some(("terminal", terminal)))?;
    let parent = |record: &Value, field: &str| {
        record.get(field).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
            Failure::Resource(json!({
                "code": "selector.not_found",
                "message": format!("the caller's terminal {terminal} is not in a workspace"),
                "details": {"terminal": terminal},
                "retryable": false,
            }))
        })
    };
    let tab = parent(&terminal_record, "tab_id")?;
    records.tab = read(ResourceOperation::TabGet, Some(("tab", tab.as_str())))?;
    let pane = parent(&records.tab, "pane_id")?;
    records.pane = read(ResourceOperation::PaneGet, Some(("pane", pane.as_str())))?;
    let screen = parent(&records.pane, "screen_id")?;
    records.screen = read(ResourceOperation::ScreenGet, Some(("screen", screen.as_str())))?;
    let workspace = parent(&records.screen, "workspace_id")?;
    records.workspace =
        read(ResourceOperation::WorkspaceGet, Some(("workspace", workspace.as_str())))?;
    Ok(())
}

/// The cmux app the pane's environment names, which this answer is not
/// from: `cmux app identify` asks it.
fn outer_app() -> Value {
    std::env::var("CMUX_SOCKET_PATH")
        .ok()
        .filter(|path| !path.trim().is_empty())
        .map_or(Value::Null, |path| json!({"socket_path": path, "identify": "cmux app identify"}))
}

/// The answer's shape. `caller` keeps the field names of the app's
/// `system.identify` caller (`workspace`, `screen`, `pane`, `tab`,
/// `terminal_id`, `found`), so a script reads either answer the same way.
fn identity_value(
    socket: &Path,
    session: &Value,
    machine: &Value,
    caller: Value,
    outer_app: Value,
) -> Value {
    let pick = |record: &Value, key: &str| record.get(key).cloned().unwrap_or(Value::Null);
    json!({
        "kind": "cmux-tui",
        "socket_path": socket.display().to_string(),
        "session": {"id": pick(session, "id"), "name": pick(session, "name")},
        "machine": {"id": pick(machine, "id"), "name": pick(machine, "name")},
        "caller": caller,
        "outer_app": outer_app,
        "guide": "cmux skill show",
    })
}

/// `identity` with `build`: this CLI's build id (`cli`), the daemon's
/// (`daemon`, from `identify`'s `daemon-build-v1`; null from an older
/// daemon), the daemon's own `cmux` (`daemon_cli`) and whether the builds
/// match (`matches`, null when unknown), plus a `warning` when they do not
/// (W5-Q): an agent that runs an older `cmux` on PATH learns which one to run.
fn with_build(
    identity: &mut Value,
    own: &str,
    daemon: Option<&super::skew::DaemonBuild>,
    reach: Reach<'_>,
) {
    let Some(object) = identity.as_object_mut() else { return };
    let matches = daemon.map(|daemon| daemon.build_id == own);
    object.insert(
        "build".into(),
        json!({
            "cli": own,
            "daemon": daemon.map(|daemon| daemon.build_id.as_str()),
            "daemon_cli": daemon.map(|daemon| daemon.cli_path.display().to_string()),
            "matches": matches,
        }),
    );
    let warning = daemon.filter(|_| matches == Some(false)).map(|daemon| match reach {
        // The daemon's `cmux` is a path on the other machine: name the
        // remote upgrade, as the CLI's own skew line does.
        Reach::Tunnel { socket } => super::skew::remote_skew(daemon, own, socket),
        Reach::Local { pane_cli } => {
            let cli = daemon.cli_path.display().to_string();
            // A pane's `CMUX_TUI_CLI` is its own session's `cmux`; a `--socket`
            // to another session's daemon needs that daemon's `cmux`.
            let run = match pane_cli.filter(|path| same_file(Path::new(path), &daemon.cli_path)) {
                Some(_) => format!("\"$CMUX_TUI_CLI\" ({cli})"),
                None => cli,
            };
            crate::localization::catalog()
                .pane_cli
                .build_mismatch
                .replace("{own}", own)
                .replace("{daemon}", &daemon.build_id)
                .replace("{run}", &run)
        }
    });
    object.insert("warning".into(), json!(warning));
}

/// Whether absolute path `path` names the file `target` names (the same
/// path, or a link to it).
fn same_file(path: &Path, target: &Path) -> bool {
    if !path.is_absolute() {
        return false;
    }
    match (std::fs::canonicalize(path), std::fs::canonicalize(target)) {
        (Ok(path), Ok(target)) => path == target,
        _ => path == target,
    }
}

/// How the CLI reached the daemon that answered, as [`with_build`] words its
/// warning.
#[derive(Clone, Copy, Debug)]
enum Reach<'a> {
    /// The daemon itself answered on a local socket; `pane_cli` is the
    /// `CMUX_TUI_CLI` this process has (set in a cmux pane). The warning
    /// names it only when it is the daemon's own `cmux` file.
    Local { pane_cli: Option<&'a str> },
    /// The socket tunnels to a daemon on another machine; its `cmux` is a
    /// path there.
    Tunnel { socket: &'a Path },
}

/// [`with_build`] for the daemon at `socket`, asked over its own connection.
fn with_daemon_build(mut identity: Value, socket: &Path) -> Value {
    let probed = super::skew::probe_socket(socket.to_path_buf());
    let pane_cli = std::env::var("CMUX_TUI_CLI").ok();
    let reach = match &probed {
        Some((_, daemon, route)) if !super::skew::answered_itself(daemon, route) => {
            Reach::Tunnel { socket }
        }
        _ => Reach::Local { pane_cli: pane_cli.as_deref() },
    };
    let daemon = probed.map(|(_, daemon, _)| daemon);
    with_build(&mut identity, super::skew::own_build_id(), daemon.as_ref(), reach);
    identity
}

/// The human answer: one labelled line per object.
fn human(identity: &Value) -> String {
    let labels = &crate::localization::catalog().pane_cli;
    static NULL: Value = Value::Null;
    let at = |pointer: &str| identity.pointer(pointer).unwrap_or(&NULL);
    let text = |pointer: &str| at(pointer).as_str().unwrap_or("-").to_owned();
    let named = |id: &str, name: &str| match at(name).as_str().filter(|name| !name.is_empty()) {
        Some(name) => format!("{} {name}", text(id)),
        None => text(id),
    };
    let mut rows = vec![
        (labels.session, named("/session/id", "/session/name")),
        (labels.machine, named("/machine/id", "/machine/name")),
    ];
    if at("/caller/found").as_bool() == Some(true) {
        rows.extend([
            (labels.workspace, named("/caller/workspace", "/caller/workspace_name")),
            (labels.screen, named("/caller/screen", "/caller/screen_name")),
            (labels.pane, text("/caller/pane")),
            (labels.tab, named("/caller/tab", "/caller/tab_name")),
            (labels.terminal, text("/caller/terminal_id")),
        ]);
    } else {
        let why = at("/caller/error/message").as_str().unwrap_or_default();
        rows.push((labels.terminal, labels.not_found.replace("{why}", why)));
    }
    rows.push((labels.socket, text("/socket_path")));
    if at("/app_connected").as_bool() == Some(false) {
        rows.push((labels.app, labels.no_app.to_owned()));
    }
    if let Some(app) = at("/outer_app/socket_path").as_str() {
        rows.push((labels.outer_app, format!("{app} (`cmux app identify`)")));
    }
    rows.push((labels.guide, "cmux skill show".to_owned()));
    if let Some(warning) = at("/warning").as_str() {
        rows.push((labels.warning, warning.to_owned()));
    }
    let width = rows.iter().map(|(label, _)| label.chars().count()).max().unwrap_or(0);
    rows.into_iter()
        .map(|(label, value)| {
            let pad = width.saturating_sub(label.chars().count());
            format!("{label}{}  {value}\n", " ".repeat(pad))
        })
        .collect()
}

#[cfg(test)]
mod tests;
