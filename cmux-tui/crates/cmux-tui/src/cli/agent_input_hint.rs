//! A hint after `terminal <t> write|keys` (and tmux `send-keys`) types into a
//! terminal whose hooks report a live agent. Typed input lands in the agent's
//! composer; `cmux agent message` reaches the agent as its own input instead
//! (cli/agent_message.rs). The input is still sent, so scripts that type into
//! agents on purpose keep working; the hint goes to stderr.

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::command::{RequestPlan, WireOperation};
use super::resolve::read;
use super::{GlobalArgs, OutputMode};

type Reader = std::io::BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>;

/// Selector params of a terminal input request.
const SELECTORS: [&str; 7] =
    ["machine", "session", "workspace", "screen", "pane", "tab", "terminal"];
/// Longest typed text the hint repeats in its command.
const MAX_QUOTED_CHARS: usize = 200;

/// The hint for a sent `plan`, or `None` when it typed into no live agent.
/// Lookup failures give no hint: the input itself already succeeded.
pub(super) fn after_input(
    global: &GlobalArgs,
    plan: &RequestPlan,
    reader: &mut Reader,
) -> Option<String> {
    if global.output == OutputMode::Quiet
        || !matches!(
            plan.operation,
            WireOperation::Typed(
                ResourceOperation::TerminalInputWrite | ResourceOperation::TerminalInputKeys
            )
        )
    {
        return None;
    }
    let params = plan.params.as_object()?;
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
                && !text.contains('\n')
                && text.chars().count() <= MAX_QUOTED_CHARS
        })
        .map_or_else(|| "'…'".to_owned(), shell_quote);
    let command = format!("cmux agent message {terminal} {text}");
    Some(
        crate::localization::catalog()
            .terminal_input
            .agent_message_hint
            .replace("{terminal}", &terminal)
            .replace("{command}", &command),
    )
}

/// POSIX single quotes, which `sh`, `bash` and `zsh` all read back exactly.
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}
