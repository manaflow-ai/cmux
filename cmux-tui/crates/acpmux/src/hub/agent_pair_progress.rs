//! What counts as progress for the agent pair guard (`agent_pairs.rs`): a tool call that is
//! not a messaging call, or a file the agent wrote.

use super::*;

/// The cmux-subsessions tools (`subsession_mcp.rs`) that only message, read, wait on, stop or
/// retry another session of the family: never progress. `start_session` is not one: it hands work off.
const SUBSESSION_TOOLS: &[&str] = &[
    "send_message",
    "list_sessions",
    "get_session",
    "wait_for_sessions",
    "stop_session",
    "retry_session",
    "set_session_limits",
];
/// The cmux MCP tools that message or read another chat (`cmux-tui` `cli/mcp/agent_tools.rs`):
/// never progress, whatever the server is named.
const CHAT_TOOLS: &[&str] = &["agents_chat_send", "agents_chat_read"];

/// A shell command that is one `cmux agent message` or `cmux agent inbox` call and nothing else.
/// Quoted text is the message's, so `cmux agent message acp:b 'ready; waiting'` is one call.
fn messaging_command(command: &str) -> bool {
    let Some(words) = simple_command_words(command) else { return false };
    let mut words = words.iter().map(String::as_str);
    let program = words.next().unwrap_or("");
    let program = program.rsplit('/').next().unwrap_or(program);
    program == "cmux"
        && words.next() == Some("agent")
        && matches!(words.next(), Some("message" | "inbox"))
}

/// A shell command's words with its quoting removed, or `None` when it is more than one simple
/// command: an unquoted operator, subshell or redirection, or a command substitution (outside
/// single quotes), or an unclosed quote.
fn simple_command_words(command: &str) -> Option<Vec<String>> {
    #[derive(PartialEq)]
    enum Quote {
        No,
        Single,
        Double,
    }
    let (mut words, mut word, mut in_word, mut quote) =
        (Vec::new(), String::new(), false, Quote::No);
    let mut chars = command.trim().chars().peekable();
    while let Some(c) = chars.next() {
        match quote {
            Quote::Single if c == '\'' => quote = Quote::No,
            Quote::Single => word.push(c),
            Quote::Double => match c {
                '"' => quote = Quote::No,
                '`' => return None,
                '$' if chars.peek() == Some(&'(') => return None,
                '\\' => match chars.next() {
                    Some('\n') | None => {}
                    Some(n @ ('"' | '\\' | '$' | '`')) => word.push(n),
                    Some(n) => {
                        word.push('\\');
                        word.push(n);
                    }
                },
                _ => word.push(c),
            },
            Quote::No => match c {
                '\'' => (quote, in_word) = (Quote::Single, true),
                '"' => (quote, in_word) = (Quote::Double, true),
                '\\' => match chars.next() {
                    Some('\n') | None => {}
                    Some(n) => {
                        word.push(n);
                        in_word = true;
                    }
                },
                ';' | '&' | '|' | '<' | '>' | '`' | '(' | ')' | '\n' => return None,
                '$' if chars.peek() == Some(&'(') => return None,
                c if c.is_whitespace() => {
                    if in_word {
                        words.push(std::mem::take(&mut word));
                        in_word = false;
                    }
                }
                c => {
                    word.push(c);
                    in_word = true;
                }
            },
        }
    }
    if quote != Quote::No {
        return None;
    }
    if in_word {
        words.push(word);
    }
    Some(words)
}

/// The command a tool call runs: a string, or an argv whose shell `-c` script is its last word.
fn tool_command(update: &Value) -> Option<String> {
    match update.pointer("/rawInput/command")? {
        Value::String(command) => Some(command.clone()),
        Value::Array(argv) => {
            let argv: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            let shell = argv
                .first()
                .is_some_and(|p| matches!(p.rsplit('/').next(), Some("sh" | "bash" | "zsh")))
                && argv.get(1).is_some_and(|f| f.starts_with('-') && f.ends_with('c'));
            Some(if shell { argv.last().copied().unwrap_or("").to_owned() } else { argv.join(" ") })
        }
        _ => None,
    }
}

/// Whether a tool call only messages or reads another session.
fn messaging_call(update: &Value) -> bool {
    if let Some(command) = tool_command(update) {
        return messaging_command(&command);
    }
    let title = update.get("title").and_then(Value::as_str).unwrap_or("").trim();
    // Codex titles an MCP call `Tool: <server>/<tool>`.
    let title = title.strip_prefix("Tool: ").map_or(title, str::trim);
    if title.contains(char::is_whitespace) {
        return messaging_command(title);
    }
    messaging_tool(title)
}

/// Whether an MCP tool call's title (`mcp__cmux-subsessions__send_message`,
/// `cmux-subsessions.send_message`, `cmux-subsessions/send_message`, or the bare name) names a
/// messaging tool. A sub-session tool name another server also uses is that server's work.
fn messaging_tool(title: &str) -> bool {
    let title = title.strip_prefix("mcp__").unwrap_or(title);
    let (server, name) =
        match title.rsplit_once("__").or_else(|| title.rsplit_once(['.', '/', ':'])) {
            Some((server, name)) => (Some(server), name),
            None => (None, title),
        };
    CHAT_TOOLS.contains(&name)
        || (SUBSESSION_TOOLS.contains(&name)
            && server.is_none_or(|s| s == crate::subsession_mcp::SERVER_NAME))
}

/// Whether a log record shows the session doing work: a tool call that is not a messaging
/// call, or a file the agent wrote.
pub(in crate::hub) fn progress_record(rec: &EventRecord) -> bool {
    match rec.kind.as_str() {
        "fs/write_text_file" => rec.dir == "in",
        "tool_call" => !messaging_call(rec.msg.pointer("/params/update").unwrap_or(&rec.msg)),
        _ => false,
    }
}
