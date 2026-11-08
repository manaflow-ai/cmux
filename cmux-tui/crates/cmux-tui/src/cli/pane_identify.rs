//! `cmux identify` in a cmux-tui pane: the pane's own session, machine and
//! caller path, read from the session daemon.
//!
//! The classic `cmux identify` asks the cmux app (`system.identify`). In a
//! cmux-tui pane whose session no app owns (a standalone cmux-tui, or one
//! started in a cmux app terminal, which inherits that app's
//! `CMUX_SOCKET_PATH`), the app does not know the pane and answered
//! `caller.found false`. There the innermost multiplexer answers instead
//! (pane_context.rs). `cmux app identify` and `--app-socket` still ask the app.

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
    if !super::app::is_classic_identify(&command_args) || explicitly_routed(&global) {
        return None;
    }
    let Innermost::SessionPane { socket, terminal } = pane_context::innermost() else {
        return None;
    };
    Some(run(&global, &socket, &terminal))
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
    let identity = match read_identity(socket, terminal) {
        Ok(identity) => identity,
        Err(failure) => return failure.report(global.output),
    };
    match global.output {
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(human(&identity).as_bytes());
            let _ = stdout.flush();
            0
        }
        output => super::wire::print_local_success(&identity, output),
    }
}

/// A local daemon answers these reads at once; a stuck one fails the call.
const READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// The pane's identity from the daemon at `socket`.
pub(super) fn read_identity(socket: &Path, terminal: &str) -> Result<Value, Failure> {
    let stream = cmux_tui_core::server::connect_session_socket(socket, false).map_err(|error| {
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
    let caller = match caller_records(&mut read, terminal, &mut records) {
        Ok(()) => records.caller(terminal),
        Err(Failure::Resource(error)) => json!({
            "found": false,
            "terminal_id": terminal,
            "error": error,
        }),
        Err(failure) => return Err(failure),
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
    if let Some(app) = at("/outer_app/socket_path").as_str() {
        rows.push((labels.outer_app, format!("{app} (`cmux app identify`)")));
    }
    rows.push((labels.guide, "cmux skill show".to_owned()));
    let width = rows.iter().map(|(label, _)| label.chars().count()).max().unwrap_or(0);
    rows.into_iter()
        .map(|(label, value)| {
            let pad = width.saturating_sub(label.chars().count());
            format!("{label}{}  {value}\n", " ".repeat(pad))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(pairs: &[(&str, &str)]) -> Value {
        Value::Object(pairs.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect())
    }

    /// The caller path follows terminal, tab, pane, screen and workspace in
    /// that order, and keeps the names the app's caller lacks.
    #[test]
    fn identify_follows_the_terminal_to_its_workspace() {
        let mut asked = Vec::new();
        let mut read = |operation: ResourceOperation,
                        extra: Option<(&str, &str)>|
         -> Result<Value, Failure> {
            asked.push((operation.wire_name().to_owned(), extra.map(|(_, id)| id.to_owned())));
            Ok(match operation {
                ResourceOperation::TerminalGet => record(&[("id", "term_1"), ("tab_id", "tab_1")]),
                ResourceOperation::TabGet => {
                    record(&[("id", "tab_1"), ("pane_id", "pane_1"), ("name", "logs")])
                }
                ResourceOperation::PaneGet => {
                    record(&[("id", "pane_1"), ("screen_id", "screen_1")])
                }
                ResourceOperation::ScreenGet => {
                    record(&[("id", "screen_1"), ("workspace_id", "ws_1"), ("name", "main")])
                }
                ResourceOperation::WorkspaceGet => record(&[("id", "ws_1"), ("name", "api")]),
                _ => Value::Null,
            })
        };
        let mut records = CallerRecords::default();
        assert!(caller_records(&mut read, "term_1", &mut records).is_ok());
        let caller = records.caller("term_1");
        assert_eq!(
            asked.iter().map(|(operation, _)| operation.as_str()).collect::<Vec<_>>(),
            ["terminal.get", "tab.get", "pane.get", "screen.get", "workspace.get"]
        );
        assert_eq!(caller["found"], true);
        assert_eq!(caller["workspace"], "ws_1");
        assert_eq!(caller["workspace_name"], "api");
        assert_eq!(caller["screen"], "screen_1");
        assert_eq!(caller["pane"], "pane_1");
        assert_eq!(caller["tab"], "tab_1");
        assert_eq!(caller["tab_name"], "logs");
        assert_eq!(caller["terminal_id"], "term_1");
    }

    /// A terminal that left its tab says so instead of naming a wrong place.
    #[test]
    fn a_terminal_without_a_tab_is_not_found() {
        let mut read = |_: ResourceOperation, _: Option<(&str, &str)>| -> Result<Value, Failure> {
            Ok(record(&[("id", "t")]))
        };
        let mut records = CallerRecords::default();
        let Err(Failure::Resource(error)) = caller_records(&mut read, "term_9", &mut records)
        else {
            panic!("a terminal with no tab was placed");
        };
        assert_eq!(error["code"], "selector.not_found");
    }

    #[test]
    fn identity_names_the_session_machine_outer_app_and_guide() {
        let value = identity_value(
            Path::new("/tmp/cmux-tui-501/bench.sock"),
            &record(&[("id", "session_1"), ("name", "bench")]),
            &record(&[("id", "machine_1"), ("name", "mac")]),
            json!({"found": true, "terminal_id": "term_1"}),
            json!({"socket_path": "/x/cmux.sock", "identify": "cmux app identify"}),
        );
        assert_eq!(value["kind"], "cmux-tui");
        assert_eq!(value["session"], json!({"id": "session_1", "name": "bench"}));
        assert_eq!(value["machine"], json!({"id": "machine_1", "name": "mac"}));
        assert_eq!(value["socket_path"], "/tmp/cmux-tui-501/bench.sock");
        assert_eq!(value["outer_app"]["identify"], "cmux app identify");
        assert_eq!(value["guide"], "cmux skill show");
        let text = human(&value);
        assert!(text.contains("session_1 bench"), "{text}");
        assert!(text.contains("/x/cmux.sock (`cmux app identify`)"), "{text}");
    }

    /// `machine.get` refuses a session parameter ("unknown parameters").
    #[test]
    fn the_machine_read_names_no_session() {
        assert!(route(ResourceOperation::MachineGet).get("session").is_none());
        assert_eq!(route(ResourceOperation::MachineGet)["machine"], "current");
        assert_eq!(route(ResourceOperation::SessionGet)["session"], "current");
        assert_eq!(route(ResourceOperation::TerminalGet)["session"], "current");
    }

    #[test]
    fn an_explicit_route_keeps_the_classic_identify() {
        let mut global = GlobalArgs::default();
        assert!(!explicitly_routed(&global));
        global.session = Some("other".into());
        assert!(explicitly_routed(&global));
        let global =
            GlobalArgs { app_socket: Some("/x/cmux.sock".into()), ..GlobalArgs::default() };
        assert!(explicitly_routed(&global));
    }
}
