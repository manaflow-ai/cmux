//! `cmux identify`: where this process runs. In a cmux-tui terminal it reads
//! the terminal's own session (`CMUX_TUI_SOCKET`, or `--socket` /
//! `--session`) and follows the terminal (`CMUX_TUI_TERMINAL_ID`) up to its
//! workspace. The answer has the same fields as `cmux identify` on
//! feat-cmux-next: `kind`, `session`, `machine`, `caller` (`found`,
//! `workspace`, `screen`, `pane`, `tab`, `terminal_id` and names),
//! `outer_app` and `guide`.
//!
//! Outside a cmux-tui terminal there is no caller: `caller.found` is false
//! and the session and machine are the ones this CLI reaches.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::time::Duration;

use cmux_tui_core::resource::{PROTOCOL, ResourceOperation, ResponseEnvelope};
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// A local daemon answers these reads at once; a stuck one fails the call.
const READ_TIMEOUT: Duration = Duration::from_secs(5);
const RESPONSE_LIMIT: u64 = 16 * 1024 * 1024;

/// Why a read did not answer.
#[derive(Debug)]
pub(super) enum Failure {
    /// The `--session` or `--socket` route is not valid: exit 2, as for every
    /// other command.
    Usage(Value),
    /// The session cannot be reached or spoke no protocol: exit 3.
    Transport(Value),
    /// The session refused the read (a resource error object).
    Resource(Value),
}

impl Failure {
    fn report(self, output: OutputMode) -> i32 {
        match self {
            Self::Usage(error) => super::wire::print_local_error(&error, output, 2),
            Self::Transport(error) => super::wire::print_local_error(&error, output, 3),
            Self::Resource(error) => super::wire::print_local_error(&error, output, 1),
        }
    }
}

/// Runs `cmux identify`.
pub(super) fn run(global: &GlobalArgs) -> i32 {
    let caller_terminal = caller_terminal(|key| std::env::var(key).ok());
    let identity = match read_identity(global, caller_terminal.as_deref()) {
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

/// The caller's terminal id (`CMUX_TUI_TERMINAL_ID`, a `term_…` id), when
/// this process runs in a cmux-tui terminal.
pub(super) fn caller_terminal(env: impl Fn(&str) -> Option<String>) -> Option<String> {
    env("CMUX_TUI_TERMINAL_ID").map(|id| id.trim().to_owned()).filter(|id| id.starts_with("term_"))
}

/// The identity record for `caller_terminal` (`None`: not in a terminal),
/// read from the session `global` routes to.
pub(super) fn read_identity(
    global: &GlobalArgs,
    caller_terminal: Option<&str>,
) -> Result<Value, Failure> {
    let messages = &crate::localization::catalog().pane_cli;
    // The only failure is an invalid `--session` name; the text is the one
    // every other command prints for it (wire.rs).
    let (socket, derived) = super::wire::resolve_socket_with_origin(global).map_err(|_| {
        Failure::Usage(json!({
            "code": "usage.invalid",
            "message": crate::localization::catalog().startup.invalid_session_name,
            "details": {},
            "retryable": false,
        }))
    })?;
    let stream =
        cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
            Failure::Transport(json!({
                "code": "socket.unreachable",
                "message": messages
                    .unreachable
                    .replace("{socket}", &socket.display().to_string())
                    .replace("{error}", &error.to_string()),
                "details": {"socket": socket.display().to_string()},
                "retryable": true,
            }))
        })?;
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let mut reader = BufReader::new(stream);
    let mut read = |operation, extra: Option<(&str, &str)>| {
        let mut params = route(global, operation);
        if let Some((key, value)) = extra {
            params.insert(key.into(), Value::String(value.to_owned()));
        }
        request(&mut reader, operation, params)
    };
    let session = read(ResourceOperation::SessionGet, None)?;
    let machine = read(ResourceOperation::MachineGet, None)?;
    let caller = match caller_terminal {
        None => json!({
            "found": false,
            "terminal_id": null,
            "error": {
                "code": "caller.outside_terminal",
                "message": messages.outside_terminal,
            },
        }),
        Some(terminal) => {
            let mut records = CallerRecords::default();
            match caller_records(&mut read, terminal, &mut records) {
                Ok(()) => records.caller(terminal),
                Err(Failure::Resource(error)) => json!({
                    "found": false,
                    "terminal_id": terminal,
                    "error": error,
                }),
                Err(failure) => return Err(failure),
            }
        }
    };
    Ok(identity_value(&socket, &session, &machine, caller, outer_app()))
}

/// Every read names the machine; all but `machine.get` (which takes no
/// session) also name the session. `--session` and `--machine` replace
/// `current`, as for every other command.
fn route(global: &GlobalArgs, operation: ResourceOperation) -> Map<String, Value> {
    let mut params = Map::new();
    let machine = global.machine.as_deref().unwrap_or("current");
    params.insert("machine".into(), json!(machine));
    if operation != ResourceOperation::MachineGet {
        let session = global.session.as_deref().unwrap_or("current");
        params.insert("session".into(), json!(session));
    }
    params
}

/// One `cmux.protocol/2` read on `reader`'s connection.
fn request<S: Read + Write>(
    reader: &mut BufReader<S>,
    operation: ResourceOperation,
    params: Map<String, Value>,
) -> Result<Value, Failure> {
    let transport_error = |message: String| {
        Failure::Transport(json!({
            "code": "transport.failed",
            "message": message,
            "details": {"operation": operation.wire_name()},
            "retryable": true,
        }))
    };
    let id =
        super::command::random_prefixed("request").map_err(|error| transport_error(error.0))?;
    let request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": id,
        "operation": operation.wire_name(),
        "params": params,
    });
    let mut encoded =
        serde_json::to_vec(&request).map_err(|error| transport_error(error.to_string()))?;
    encoded.push(b'\n');
    reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|()| reader.get_mut().flush())
        .map_err(|error| transport_error(format!("transport error: {error}")))?;
    loop {
        let mut line = Vec::new();
        let read = reader
            .by_ref()
            .take(RESPONSE_LIMIT + 2)
            .read_until(b'\n', &mut line)
            .map_err(|error| transport_error(format!("transport error: {error}")))?;
        if read == 0 || !line.ends_with(b"\n") {
            return Err(transport_error("transport closed before response".into()));
        }
        let value: Value = serde_json::from_slice(&line)
            .map_err(|error| transport_error(format!("invalid JSON response: {error}")))?;
        if value.get("type").and_then(Value::as_str) != Some("response") {
            continue;
        }
        let response: ResponseEnvelope = serde_json::from_value(value)
            .map_err(|error| transport_error(format!("invalid response envelope: {error}")))?;
        if response.id.as_str() != id {
            continue;
        }
        if !response.ok {
            let error = response
                .error
                .and_then(|error| serde_json::to_value(error).ok())
                .unwrap_or_else(|| json!({"code": "operation.failed", "message": "read failed"}));
            return Err(Failure::Resource(error));
        }
        return Ok(response.result.unwrap_or(Value::Null));
    }
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

/// Follows `terminal` up to its workspace, keeping each record for its name.
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
                "message": crate::localization::catalog()
                    .pane_cli
                    .not_in_workspace
                    .replace("{terminal}", terminal),
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

/// The cmux app the environment names (`CMUX_SOCKET_PATH`), which this
/// answer is not from. The app's own `cmux identify` answers for it.
fn outer_app() -> Value {
    std::env::var("CMUX_SOCKET_PATH")
        .ok()
        .filter(|path| !path.trim().is_empty())
        .map_or(Value::Null, |path| json!({"socket_path": path}))
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
    let clean = |text: &str| super::wire::sanitize_human_cell(text);
    let text = |pointer: &str| clean(at(pointer).as_str().unwrap_or("-"));
    let named = |id: &str, name: &str| match at(name).as_str().filter(|name| !name.is_empty()) {
        Some(name) => format!("{} {}", text(id), clean(name)),
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
        let why = clean(at("/caller/error/message").as_str().unwrap_or_default());
        rows.push((labels.terminal, labels.not_found.replace("{why}", &why)));
    }
    rows.push((labels.socket, text("/socket_path")));
    if at("/outer_app/socket_path").is_string() {
        rows.push((labels.outer_app, text("/outer_app/socket_path")));
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
    /// that order, and keeps the names.
    #[test]
    fn pane_cli_identify_follows_the_terminal_to_its_workspace() {
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
        assert_eq!(
            asked.iter().map(|(_, id)| id.as_deref()).collect::<Vec<_>>(),
            [Some("term_1"), Some("tab_1"), Some("pane_1"), Some("screen_1"), Some("ws_1")]
        );
        assert_eq!(caller["found"], true);
        assert_eq!(caller["workspace"], "ws_1");
        assert_eq!(caller["workspace_name"], "api");
        assert_eq!(caller["screen"], "screen_1");
        assert_eq!(caller["screen_name"], "main");
        assert_eq!(caller["pane"], "pane_1");
        assert_eq!(caller["tab"], "tab_1");
        assert_eq!(caller["tab_name"], "logs");
        assert_eq!(caller["terminal_id"], "term_1");
    }

    /// A terminal that left its tab says so instead of naming a wrong place.
    #[test]
    fn pane_cli_identify_a_terminal_without_a_tab_is_not_found() {
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
    fn pane_cli_identify_names_the_session_machine_outer_app_and_guide() {
        let value = identity_value(
            Path::new("/tmp/cmux-tui-501/bench.sock"),
            &record(&[("id", "session_1"), ("name", "bench")]),
            &record(&[("id", "machine_1"), ("name", "mac")]),
            json!({"found": true, "terminal_id": "term_1", "pane": "pane_1"}),
            json!({"socket_path": "/x/cmux.sock"}),
        );
        assert_eq!(value["kind"], "cmux-tui");
        assert_eq!(value["session"], json!({"id": "session_1", "name": "bench"}));
        assert_eq!(value["machine"], json!({"id": "machine_1", "name": "mac"}));
        assert_eq!(value["socket_path"], "/tmp/cmux-tui-501/bench.sock");
        assert_eq!(value["outer_app"]["socket_path"], "/x/cmux.sock");
        assert_eq!(value["guide"], "cmux skill show");
        let text = human(&value);
        assert!(text.contains("session_1 bench"), "{text}");
        assert!(text.contains("pane_1"), "{text}");
        assert!(text.contains("/x/cmux.sock"), "{text}");
        assert!(text.contains("cmux skill show"), "{text}");
    }

    /// Outside a terminal the human answer says why the caller is unknown.
    #[test]
    fn pane_cli_identify_outside_a_terminal_reports_no_caller() {
        let value = identity_value(
            Path::new("/tmp/s.sock"),
            &record(&[("id", "session_1")]),
            &record(&[("id", "machine_1")]),
            json!({"found": false, "terminal_id": null, "error": {"message": "not in a terminal"}}),
            Value::Null,
        );
        let text = human(&value);
        assert!(text.contains("not in a terminal"), "{text}");
        assert_eq!(value["outer_app"], Value::Null);
    }

    #[test]
    fn pane_cli_identify_reads_the_caller_terminal_from_the_environment() {
        let env = |value: &'static str| {
            move |key: &str| (key == "CMUX_TUI_TERMINAL_ID").then(|| value.to_owned())
        };
        assert_eq!(caller_terminal(env("term_abc")).as_deref(), Some("term_abc"));
        assert_eq!(caller_terminal(env(" ")), None);
        assert_eq!(caller_terminal(env("pane_abc")), None);
        assert_eq!(caller_terminal(|_: &str| None), None);
    }

    /// `machine.get` refuses a session parameter; `--session` replaces
    /// `current` for the others.
    #[test]
    fn pane_cli_identify_the_machine_read_names_no_session() {
        let global = GlobalArgs::default();
        assert!(route(&global, ResourceOperation::MachineGet).get("session").is_none());
        assert_eq!(route(&global, ResourceOperation::MachineGet)["machine"], "current");
        assert_eq!(route(&global, ResourceOperation::SessionGet)["session"], "current");
        let named = GlobalArgs { session: Some("bench".into()), ..GlobalArgs::default() };
        assert_eq!(route(&named, ResourceOperation::TerminalGet)["session"], "bench");
    }

    /// A read sends one protocol/2 request and returns its result, skipping
    /// events and other responses on the connection.
    #[test]
    fn pane_cli_identify_request_reads_the_matching_response() {
        struct Peer {
            input: std::io::Cursor<Vec<u8>>,
            sent: Vec<u8>,
        }
        impl Read for Peer {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.input.get_ref().is_empty() {
                    let request: Value = serde_json::from_slice(&self.sent).unwrap();
                    let id = request["id"].as_str().unwrap();
                    let lines = format!(
                        "{}\n{}\n",
                        json!({"type": "event", "event": "x"}),
                        json!({"protocol": PROTOCOL, "type": "response", "id": id, "ok": true, "result": {"id": "session_1"}}),
                    );
                    self.input = std::io::Cursor::new(lines.into_bytes());
                }
                self.input.read(buf)
            }
        }
        impl Write for Peer {
            fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
                self.sent.extend_from_slice(buf);
                Ok(buf.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let mut reader =
            BufReader::new(Peer { input: std::io::Cursor::new(Vec::new()), sent: Vec::new() });
        let result = request(
            &mut reader,
            ResourceOperation::SessionGet,
            route(&GlobalArgs::default(), ResourceOperation::SessionGet),
        )
        .unwrap();
        assert_eq!(result["id"], "session_1");
        let sent: Value = serde_json::from_slice(&reader.get_ref().sent).unwrap();
        assert_eq!(sent["operation"], "session.get");
        assert_eq!(sent["params"]["session"], "current");
    }
}
