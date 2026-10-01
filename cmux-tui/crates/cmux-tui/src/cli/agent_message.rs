//! `cmux agent message` and `cmux agent inbox` (plans/feat-agent-rooms).
//!
//! A message is stored by the daemon first (`agent.message.send`), so it
//! survives a restart. Then the CLI delivers it to every acpmux recipient as
//! a prompt whose id is the message id; acpmux runs a prompt id once, so a
//! retry never delivers twice. A terminal agent takes its messages from the
//! daemon through its hooks. Messages reach agents as their own input or
//! context, never as keystrokes typed into a terminal.

use std::io::{BufReader, Read};
use std::time::Duration;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::resolve::{Failure, call};
use super::{GlobalArgs, OutputMode, UsageError};

/// UTF-8 bytes of one body; the daemon enforces the same limit.
const MAX_BODY_BYTES: usize = 32 * 1024;
/// Queued messages one send delivers to an acpmux recipient, oldest first.
const DELIVERY_BATCH: u32 = 50;
const READ_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Body {
    Text(String),
    /// `-`: read the body from standard input.
    Stdin,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct MessagePlan {
    /// `None` for a reply, which goes to its parent's sender.
    pub target: Option<String>,
    pub body: Body,
    pub from: Option<String>,
    pub thread: Option<String>,
    pub reply_to: Option<String>,
    pub idempotency_key: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct InboxPlan {
    /// `None`: the caller's own address, else every message.
    pub target: Option<String>,
    pub state: Option<String>,
    pub limit: Option<u32>,
    pub ack: bool,
}

/// `agent message <target> [--from NAME] [--thread ID] <text…|->` and
/// `agent message --reply-to ID [--from NAME] <text…|->`. Text after `--`
/// is taken as it is, so it may start with a dash.
pub(super) fn parse_message(
    words: &[&str],
    argv: Option<Vec<String>>,
    from: Option<String>,
    thread: Option<String>,
    reply_to: Option<String>,
) -> Result<MessagePlan, UsageError> {
    let mut words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    let target = if reply_to.is_some() {
        if thread.is_some() {
            return Err(UsageError::new("a reply stays in its parent's thread; drop --thread"));
        }
        None
    } else if words.is_empty() {
        return Err(UsageError::new(
            "name the agent to message: a terminal (term_...), an agent (agent_...), or an \
             acpmux session",
        ));
    } else {
        Some(words.remove(0))
    };
    words.extend(argv.unwrap_or_default());
    let body = match words.as_slice() {
        [] => return Err(UsageError::new("the message is empty; give text, or - to read stdin")),
        [dash] if dash == "-" => Body::Stdin,
        _ => Body::Text(words.join(" ")),
    };
    if let Some(name) = &from
        && (name.trim().is_empty() || name.chars().count() > 64 || name.contains('\n'))
    {
        return Err(UsageError::new("--from must be one line of at most 64 characters"));
    }
    Ok(MessagePlan { target, body, from, thread, reply_to, idempotency_key: None })
}

pub(super) fn parse_inbox(
    words: &[&str],
    state: Option<String>,
    limit: Option<String>,
    ack: bool,
) -> Result<InboxPlan, UsageError> {
    let target = match words {
        [] => None,
        [target] => Some((*target).to_owned()),
        _ => return Err(UsageError::new("agent inbox takes at most one agent")),
    };
    if let Some(state) = &state
        && !matches!(state.as_str(), "queued" | "delivered" | "acknowledged" | "failed")
    {
        return Err(UsageError::new("--state must be queued, delivered, acknowledged or failed"));
    }
    let limit = limit
        .map(|value| {
            value
                .parse::<u32>()
                .ok()
                .filter(|limit| (1..=1000).contains(limit))
                .ok_or_else(|| UsageError::new("--limit must be a number from 1 to 1000"))
        })
        .transpose()?;
    Ok(InboxPlan { target, state, limit, ack })
}

/// The address this process sends from: its acpmux session, else its
/// terminal, else a plain shell. An agent acpmux started from a cmux
/// terminal inherits that terminal's variables, so the session wins.
fn own_address() -> Option<String> {
    if let Some(session) = env_value("ACPMUX_SESSION_ID") {
        return Some(format!("acp:{session}"));
    }
    env_value("CMUX_TUI_TERMINAL_ID").filter(|terminal| terminal.starts_with("term_"))
}

fn env_value(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.trim().is_empty())
}

type Reader = BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>;

struct Connection {
    reader: Reader,
    route: Map<String, Value>,
}

impl Connection {
    fn open(global: &GlobalArgs) -> Result<Self, Failure> {
        let (socket, derived) = super::wire::resolve_socket_with_origin(global).map_err(|_| {
            Failure::Transport(format!(
                "cmux: {}",
                crate::localization::catalog().startup.invalid_session_name
            ))
        })?;
        let stream =
            cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
                Failure::Transport(format!(
                    "cannot connect to session socket {}: {error}",
                    socket.display()
                ))
            })?;
        let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
        let mut route = Map::new();
        route.insert(
            "machine".into(),
            Value::String(global.machine.clone().unwrap_or_else(|| "current".into())),
        );
        route.insert(
            "session".into(),
            Value::String(global.session.clone().unwrap_or_else(|| "current".into())),
        );
        Ok(Self { reader: BufReader::new(stream), route })
    }

    fn read(&mut self, operation: ResourceOperation, fields: Value) -> Result<Value, Failure> {
        let params = self.params(fields);
        call(&mut self.reader, operation, params, None)
    }

    fn mutate(
        &mut self,
        operation: ResourceOperation,
        fields: Value,
        key: Option<&str>,
    ) -> Result<Value, Failure> {
        let key = match key {
            Some(key) => key.to_owned(),
            None => super::wire::random_idempotency_key()
                .map_err(|error| Failure::Transport(format!("cmux: {error}")))?,
        };
        let params = self.params(fields);
        let result = call(&mut self.reader, operation, params, Some(&key))?;
        Ok(result.get("value").cloned().unwrap_or(Value::Null))
    }

    fn params(&self, fields: Value) -> Map<String, Value> {
        let mut params = self.route.clone();
        if let Value::Object(fields) = fields {
            params.extend(fields);
        }
        params
    }
}

fn not_found(message: String, target: &str) -> Failure {
    Failure::Resource(json!({
        "code": "selector.not_found",
        "message": message,
        "details": {"scope": "agent", "selector": target},
        "retryable": false,
    }))
}

/// The address `target` names: a terminal id as it is, an agent id as its
/// terminal, anything else as an acpmux session (`acp:` optional).
fn resolve_target(connection: &mut Connection, target: &str) -> Result<String, Failure> {
    if target.starts_with("term_") {
        return Ok(target.to_owned());
    }
    if target.starts_with("agent_") {
        let agents = connection.read(ResourceOperation::AgentList, json!({}))?;
        return agents
            .as_array()
            .into_iter()
            .flatten()
            .find(|agent| agent.get("id").and_then(Value::as_str) == Some(target))
            .and_then(|agent| agent.get("terminal_id").and_then(Value::as_str))
            .map(str::to_owned)
            .ok_or_else(|| not_found(format!("no agent {target:?} in this session"), target));
    }
    let key = target.strip_prefix("acp:").unwrap_or(target);
    acp::resolve(key).map(|id| format!("acp:{id}")).map_err(|error| {
        not_found(
            format!(
                "no agent matches {target:?}: give a terminal (term_...), an agent \
                 (agent_...), or an acpmux session name ({error})"
            ),
            target,
        )
    })
}

fn read_body(body: Body) -> Result<String, UsageError> {
    let text = match body {
        Body::Text(text) => text,
        Body::Stdin => {
            let mut bytes = Vec::new();
            std::io::stdin()
                .take(MAX_BODY_BYTES as u64 + 2)
                .read_to_end(&mut bytes)
                .map_err(|error| UsageError::new(format!("cannot read stdin: {error}")))?;
            String::from_utf8(bytes)
                .map_err(|_| UsageError::new("the message on stdin is not UTF-8"))?
        }
    };
    // Shells and editors end text with a newline; the message is the text.
    let text = text.replace("\r\n", "\n");
    let text = text.trim_end_matches('\n').to_owned();
    if text.trim().is_empty() {
        return Err(UsageError::new("the message is empty"));
    }
    if text.len() > MAX_BODY_BYTES {
        return Err(UsageError::new(format!("the message is longer than {MAX_BODY_BYTES} bytes")));
    }
    Ok(text)
}

pub(super) fn run_message(global: GlobalArgs, plan: MessagePlan) -> i32 {
    let output = global.output;
    let body = match read_body(plan.body.clone()) {
        Ok(body) => body,
        Err(error) => {
            eprintln!("cmux: {}", error.0);
            return 2;
        }
    };
    match send_and_deliver(&global, &plan, body) {
        Ok((message, failures)) => {
            match output {
                OutputMode::Human => println!("{}", sent_summary(&message)),
                OutputMode::Quiet => {}
                _ => println!("{message}"),
            }
            for failure in &failures {
                eprintln!("cmux: {failure}");
            }
            i32::from(!failures.is_empty())
        }
        Err(failure) => failure.report(output),
    }
}

/// Store the message, then deliver what is queued for its acpmux recipients.
/// Returns the message as it ends up and the deliveries that failed.
fn send_and_deliver(
    global: &GlobalArgs,
    plan: &MessagePlan,
    body: String,
) -> Result<(Value, Vec<String>), Failure> {
    let mut connection = Connection::open(global)?;
    let mut fields = Map::new();
    if let Some(target) = &plan.target {
        let recipient = resolve_target(&mut connection, target)?;
        fields.insert("recipients".into(), json!([recipient]));
    }
    fields.insert("body".into(), Value::String(body));
    fields
        .insert("sender".into(), Value::String(own_address().unwrap_or_else(|| "cli".to_owned())));
    for (key, value) in
        [("sender_name", &plan.from), ("thread_id", &plan.thread), ("in_reply_to", &plan.reply_to)]
    {
        if let Some(value) = value {
            fields.insert(key.into(), Value::String(value.clone()));
        }
    }
    let key = plan.idempotency_key.as_deref().or(global.idempotency_key.as_deref());
    let mut message =
        connection.mutate(ResourceOperation::AgentMessageSend, Value::Object(fields), key)?;
    let id = message["id"].as_str().unwrap_or_default().to_owned();
    let recipients: Vec<String> = message["recipients"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect();
    let mut failures = Vec::new();
    for recipient in recipients.iter().filter(|recipient| recipient.starts_with("acp:")) {
        let failed = deliver_queued(&mut connection, recipient)?;
        failures.extend(failed);
    }
    // The receipts as they ended up.
    if let Some(current) = connection
        .read(ResourceOperation::AgentMessageList, json!({"limit": 1000}))?
        .as_array()
        .into_iter()
        .flatten()
        .find(|value| value["id"] == id.as_str())
    {
        message = current.clone();
    }
    Ok((message, failures))
}

/// Deliver every queued message of one acpmux recipient, oldest first, and
/// record each outcome. An earlier message that failed or was interrupted
/// goes out again here; its prompt id keeps it from running twice.
fn deliver_queued(connection: &mut Connection, recipient: &str) -> Result<Vec<String>, Failure> {
    let session = recipient.trim_start_matches("acp:");
    let mut queued: Vec<Value> = Vec::new();
    for state in ["queued", "failed"] {
        let listed = connection.read(
            ResourceOperation::AgentMessageList,
            json!({"recipient": recipient, "state": state, "limit": DELIVERY_BATCH}),
        )?;
        queued.extend(listed.as_array().cloned().unwrap_or_default());
    }
    queued.sort_by_key(|message| {
        message["created_at_ms"].as_str().and_then(|value| value.parse::<u64>().ok())
    });
    let mut failures = Vec::new();
    for message in queued {
        let id = message["id"].as_str().unwrap_or_default().to_owned();
        let text = cmux_tui_core::agent_message_prompt::render(std::slice::from_ref(&message));
        let (state, error) = match acp::deliver(session, &text, &id) {
            Ok(()) => ("delivered", None),
            Err(error) => {
                failures.push(format!(
                    "message {id} was stored but not delivered to {recipient}: {error}"
                ));
                ("failed", Some(truncate(&error, 1024)))
            }
        };
        let mut fields = json!({
            "ids": [id],
            "recipient": recipient,
            "state": state,
            "via": "acp.prompt",
        });
        if let Some(error) = error {
            fields["error"] = Value::String(error);
        }
        connection.mutate(ResourceOperation::AgentMessageMark, fields, None)?;
    }
    Ok(failures)
}

fn truncate(text: &str, max_bytes: usize) -> String {
    let mut end = text.len().min(max_bytes);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

fn sent_summary(message: &Value) -> String {
    let id = message["id"].as_str().unwrap_or_default();
    let deliveries: Vec<String> = message["deliveries"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|delivery| {
            let recipient = delivery["recipient"].as_str().unwrap_or_default();
            let state = delivery["state"].as_str().unwrap_or_default();
            match state {
                "queued" if recipient.starts_with("term_") => {
                    format!("queued for {recipient}; it reaches the agent at its next hook")
                }
                _ => format!("{state} to {recipient}"),
            }
        })
        .collect();
    format!("Sent {id}: {}.", deliveries.join(", "))
}

pub(super) fn run_inbox(global: GlobalArgs, plan: InboxPlan) -> i32 {
    let output = global.output;
    match inbox(&global, &plan) {
        Ok((messages, recipient)) => match output {
            OutputMode::Human => {
                print!("{}", inbox_text(&messages, recipient.as_deref()));
                0
            }
            OutputMode::Quiet => 0,
            _ => {
                println!("{}", Value::Array(messages));
                0
            }
        },
        Err(failure) => failure.report(output),
    }
}

/// The messages, and the recipient whose inbox they are when there is one.
fn inbox(global: &GlobalArgs, plan: &InboxPlan) -> Result<(Vec<Value>, Option<String>), Failure> {
    let mut connection = Connection::open(global)?;
    let recipient = match &plan.target {
        Some(target) => Some(resolve_target(&mut connection, target)?),
        None => own_address(),
    };
    if plan.ack && recipient.is_none() {
        return Err(Failure::Resource(json!({
            "code": "validation.invalid",
            "message": "--ack needs an inbox: name the agent, or run it from an agent's terminal",
            "details": {},
            "retryable": false,
        })));
    }
    let mut fields = Map::new();
    if let Some(recipient) = &recipient {
        fields.insert("recipient".into(), Value::String(recipient.clone()));
    }
    if let Some(state) = &plan.state {
        fields.insert("state".into(), Value::String(state.clone()));
    }
    fields.insert("limit".into(), json!(plan.limit.unwrap_or(50)));
    let mut messages = connection
        .read(ResourceOperation::AgentMessageList, Value::Object(fields))?
        .as_array()
        .cloned()
        .unwrap_or_default();
    if plan.ack
        && let Some(recipient) = &recipient
    {
        let unread: Vec<String> = messages
            .iter()
            .filter(|message| {
                !matches!(delivery_state(message, recipient), Some("acknowledged") | None)
            })
            .filter_map(|message| message["id"].as_str().map(str::to_owned))
            .collect();
        if !unread.is_empty() {
            let marked = connection.mutate(
                ResourceOperation::AgentMessageMark,
                json!({"ids": unread, "recipient": recipient, "state": "acknowledged", "via": "cli.inbox"}),
                None,
            )?;
            for value in marked.as_array().into_iter().flatten() {
                if let Some(row) = messages.iter_mut().find(|message| message["id"] == value["id"])
                {
                    *row = value.clone();
                }
            }
        }
    }
    Ok((messages, recipient))
}

fn delivery_state<'a>(message: &'a Value, recipient: &str) -> Option<&'a str> {
    message["deliveries"]
        .as_array()?
        .iter()
        .find(|delivery| delivery["recipient"] == recipient)?["state"]
        .as_str()
}

/// One line per message, newest first:
/// `<state> <id>  <sender>: <first line of the body>`.
fn inbox_text(messages: &[Value], recipient: Option<&str>) -> String {
    if messages.is_empty() {
        return "No messages.\n".to_owned();
    }
    let mut text = String::new();
    for message in messages {
        let state = match recipient {
            Some(recipient) => delivery_state(message, recipient),
            None => message["deliveries"][0]["state"].as_str(),
        }
        .unwrap_or("-");
        let sender = message["sender_name"]
            .as_str()
            .or_else(|| message["sender"].as_str())
            .unwrap_or_default();
        let line = message["body"]
            .as_str()
            .unwrap_or_default()
            .lines()
            .find(|line| !line.trim().is_empty())
            .unwrap_or_default();
        let line = if line.chars().count() > 79 {
            format!("{}…", line.chars().take(79).collect::<String>())
        } else {
            line.to_owned()
        };
        let id = message["id"].as_str().unwrap_or_default();
        text.push_str(&format!("{state:<12} {id}  {sender}: {line}\n"));
    }
    text
}

#[cfg(unix)]
mod acp {
    //! acpmux, linked into this binary, reached at the same home `cmux acp`
    //! uses. A message never starts the acpmux daemon: an acpmux recipient
    //! exists only while its daemon runs.

    fn runtime() -> Result<tokio::runtime::Runtime, String> {
        crate::acp::configure_home();
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| error.to_string())
    }

    /// The id of the session `key` names.
    pub(super) fn resolve(key: &str) -> Result<String, String> {
        runtime()?.block_on(async {
            let client = acpmux::deliver::connect().await.map_err(|error| format!("{error:#}"))?;
            acpmux::deliver::resolve_session(&client, key)
                .await
                .map(|(id, _name)| id)
                .map_err(|error| format!("{error:#}"))
        })
    }

    pub(super) fn deliver(session: &str, text: &str, prompt_id: &str) -> Result<(), String> {
        runtime()?.block_on(async {
            let client = acpmux::deliver::connect().await.map_err(|error| format!("{error:#}"))?;
            acpmux::deliver::deliver(client, session, text, prompt_id)
                .await
                .map(|_| ())
                .map_err(|error| format!("{error:#}"))
        })
    }
}

#[cfg(not(unix))]
mod acp {
    const UNSUPPORTED: &str = "acpmux sessions are not available on this platform";

    pub(super) fn resolve(_key: &str) -> Result<String, String> {
        Err(UNSUPPORTED.to_owned())
    }

    pub(super) fn deliver(_session: &str, _text: &str, _prompt_id: &str) -> Result<(), String> {
        Err(UNSUPPORTED.to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(words: &[&str], argv: Option<&[&str]>) -> Result<MessagePlan, UsageError> {
        parse_message(
            words,
            argv.map(|argv| argv.iter().map(|word| (*word).to_owned()).collect()),
            None,
            None,
            None,
        )
    }

    #[test]
    fn the_first_word_is_the_target_and_the_rest_is_the_text() {
        let plan = message(&["review", "please", "look"], None).unwrap();
        assert_eq!(plan.target.as_deref(), Some("review"));
        assert_eq!(plan.body, Body::Text("please look".into()));
        let plan = message(&["term_1"], Some(&["-n", "is", "a", "flag"])).unwrap();
        assert_eq!(plan.body, Body::Text("-n is a flag".into()));
        assert_eq!(message(&["review", "-"], None).unwrap().body, Body::Stdin);
        assert!(message(&["review"], None).is_err());
        assert!(message(&[], None).is_err());
    }

    #[test]
    fn a_reply_has_no_target_and_no_thread() {
        let plan = parse_message(&["thanks"], None, Some("me".into()), None, Some("msg_1".into()))
            .unwrap();
        assert_eq!(plan.target, None);
        assert_eq!(plan.body, Body::Text("thanks".into()));
        assert!(parse_message(&["x"], None, None, Some("t".into()), Some("msg_1".into())).is_err());
    }

    #[test]
    fn inbox_flags_are_validated() {
        assert_eq!(parse_inbox(&[], None, None, false).unwrap().target, None);
        assert!(parse_inbox(&["a", "b"], None, None, false).is_err());
        assert!(parse_inbox(&[], Some("read".into()), None, false).is_err());
        assert!(parse_inbox(&[], None, Some("0".into()), false).is_err());
        assert_eq!(parse_inbox(&[], None, Some("5".into()), true).unwrap().limit, Some(5));
    }

    #[test]
    fn bodies_lose_trailing_newlines_and_carriage_returns() {
        assert_eq!(read_body(Body::Text("a\r\nb\n\n".into())).unwrap(), "a\nb");
        assert!(read_body(Body::Text(" \n".into())).is_err());
        assert!(read_body(Body::Text("x".repeat(MAX_BODY_BYTES + 1))).is_err());
    }

    #[test]
    fn inbox_rows_show_the_recipient_state_sender_and_first_line() {
        let messages = vec![json!({
            "id": "msg_1",
            "sender": "term_a",
            "sender_name": "reviewer",
            "body": "\nfirst line\nsecond",
            "deliveries": [
                {"recipient": "acp:x", "state": "queued"},
                {"recipient": "term_b", "state": "delivered"},
            ],
        })];
        assert_eq!(
            inbox_text(&messages, Some("term_b")),
            "delivered    msg_1  reviewer: first line\n"
        );
        assert_eq!(inbox_text(&[], None), "No messages.\n");
    }

    #[test]
    fn the_summary_names_each_delivery() {
        let message = json!({
            "id": "msg_1",
            "deliveries": [
                {"recipient": "term_b", "state": "queued"},
                {"recipient": "acp:s", "state": "delivered"},
            ],
        });
        assert_eq!(
            sent_summary(&message),
            "Sent msg_1: queued for term_b; it reaches the agent at its next hook, delivered to \
             acp:s."
        );
    }
}
