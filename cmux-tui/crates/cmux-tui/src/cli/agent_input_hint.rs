//! A hint after `terminal <t> write` (and tmux `send-keys -l`) types text into a
//! terminal whose hooks report a live agent. Typed input lands in the agent's
//! composer; `cmux agent message` reaches the agent as its own input instead
//! (cli/agent_message.rs). The input is still sent, so scripts that type into
//! agents on purpose keep working; the hint goes to stderr.

use std::io::Write;
use std::time::Duration;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::command::{RequestPlan, WireOperation};
use super::resolve::read;
use super::wire;
use super::{GlobalArgs, OutputMode};

type Reader = std::io::BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>;

/// Selector params of a terminal input request.
const SELECTORS: [&str; 7] =
    ["machine", "session", "workspace", "screen", "pane", "tab", "terminal"];
/// Longest typed text the hint repeats in its command.
const MAX_QUOTED_CHARS: usize = 200;

/// How long each read of the hint's two lookups may wait: the input already
/// succeeded and its result is printed, so a slow daemon only delays the
/// exit (by about a second at worst) and gives no hint.
const LOOKUP_TIMEOUT: Duration = Duration::from_millis(500);

/// [`wire::print_result`] for a request's result, then the hint on stderr
/// when the request typed into a live agent. The result prints first.
pub(super) fn print_result(
    global: &GlobalArgs,
    plan: &RequestPlan,
    reader: &mut Reader,
    result: Value,
) -> i32 {
    let code = wire::print_result(global, plan, result);
    let _ = std::io::stdout().flush();
    if let Some(hint) = after_input(global, plan, reader) {
        eprintln!("cmux: {hint}");
    }
    code
}

/// The hint for a sent `plan`, or `None` when it typed into no live agent.
/// Lookup failures give no hint: the input itself already succeeded.
fn after_input(global: &GlobalArgs, plan: &RequestPlan, reader: &mut Reader) -> Option<String> {
    if global.output == OutputMode::Quiet
        || !matches!(plan.operation, WireOperation::Typed(ResourceOperation::TerminalInputWrite))
    {
        return None;
    }
    let params = plan.params.as_object()?;
    reader.get_mut().set_read_timeout(Some(LOOKUP_TIMEOUT)).ok()?;
    let selector: Map<String, Value> = SELECTORS
        .into_iter()
        .filter_map(|key| params.get(key).map(|value| (key.to_owned(), value.clone())))
        .collect();
    let terminal = read(reader, ResourceOperation::TerminalGet, selector).ok()?;
    let terminal = terminal.get("id")?.as_str()?.to_owned();
    let mut query = super::resolve::route(params);
    query.insert("terminal_id".into(), Value::String(terminal.clone()));
    let listed = read(reader, ResourceOperation::AgentList, query).ok()?;
    let rows = listed.get("agents").unwrap_or(&listed).as_array()?;
    rows.iter().find(|row| row["terminal_id"] == terminal.as_str() && row["state"] != "done")?;
    let text = params
        .get("text")
        .and_then(Value::as_str)
        .filter(|text| {
            !text.trim().is_empty()
                && !text.chars().any(char::is_control)
                && text.chars().count() <= MAX_QUOTED_CHARS
        })
        .map_or_else(|| "'…'".to_owned(), shell_quote);
    let mut command = "cmux".to_owned();
    let socket = global.socket.as_ref().map(|path| path.to_string_lossy().into_owned());
    for (flag, value) in
        [("--machine", &global.machine), ("--session", &global.session), ("--socket", &socket)]
    {
        if let Some(value) = value {
            command.push_str(&format!(" {flag} {}", shell_word(value)));
        }
    }
    // `--` keeps text that starts with a dash (or is `-`) the message.
    command.push_str(&format!(" agent message {terminal} -- {text}"));
    Some(
        crate::localization::catalog()
            .terminal_input
            .agent_message_hint
            .replace("{terminal}", &terminal)
            .replace("{command}", &command),
    )
}

/// `value` as one shell word: as it is when it has only safe characters.
fn shell_word(value: &str) -> String {
    let safe = !value.is_empty()
        && value.chars().all(|c| c.is_ascii_alphanumeric() || "._:@-".contains(c));
    if safe { value.to_owned() } else { shell_quote(value) }
}

/// POSIX single quotes, which `sh`, `bash` and `zsh` all read back exactly.
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}
