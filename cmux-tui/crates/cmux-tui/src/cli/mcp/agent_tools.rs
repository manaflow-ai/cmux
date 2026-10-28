//! `agents_<verb>`: the `cmux agents` actions as tools. A call builds the
//! words `cmux agents <verb>` takes and runs the CLI's own parser and
//! `agents::execute`, so it answers what the CLI prints: a receipt
//! `{action, result, state}` whose `state` is a fresh composed snapshot, and
//! the agent never has to screenshot to check what changed.

use serde_json::{Map, Value, json};

use super::super::GlobalArgs;
use super::super::agent_message;
use super::super::agents::{self, AgentCommand, AgentFailure, chat};
use super::{Backend, envelope, failure_result, success, tool_error, v2_tools};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Verb {
    WorkspaceSelect,
    WorkspaceCreate,
    TabSelect,
    TerminalFocus,
    TerminalSplit,
    PaletteOpen,
    DialogList,
    DialogAnswer,
    ChatSend,
    ChatRead,
    ChatNew,
    ChatState,
    ChatInterrupt,
}

pub(super) struct AgentTool {
    pub name: &'static str,
    verb: Verb,
    title: &'static str,
    description: &'static str,
}

const RECEIPT: &str = " Answers {action, result, idempotency_key, state}: the owner's result, \
    the key a change carried and a fresh agents_snapshot-shaped state, so no screenshot is \
    needed to check the change. A state too large to return reads {truncated, hint}.";

pub(super) const TOOLS: &[AgentTool] = &[
    AgentTool {
        name: "agents_workspace_select",
        verb: Verb::WorkspaceSelect,
        title: "Select workspace",
        description: "Select a workspace and show it in the cmux window (`cmux agents \
            workspace select`). Its purpose is focus, so it moves the user's focus.",
    },
    AgentTool {
        name: "agents_workspace_create",
        verb: Verb::WorkspaceCreate,
        title: "Create workspace",
        description: "Create a workspace (`cmux agents workspace create`), with a terminal \
            unless empty is true. The cmux window keeps showing the user's workspace.",
    },
    AgentTool {
        name: "agents_tab_select",
        verb: Verb::TabSelect,
        title: "Select tab",
        description: "Select a tab and show it in the cmux window (`cmux agents tab select`). \
            Its purpose is focus, so it moves the user's focus.",
    },
    AgentTool {
        name: "agents_terminal_focus",
        verb: Verb::TerminalFocus,
        title: "Focus terminal",
        description: "Focus a terminal tab and show it in the cmux window (`cmux agents \
            terminal focus`). Its purpose is focus, so it moves the user's focus.",
    },
    AgentTool {
        name: "agents_terminal_split",
        verb: Verb::TerminalSplit,
        title: "Split terminal",
        description: "Split a pane (the current one unless pane is given) and open a \
            terminal beside it (`cmux agents terminal split`). The cmux window keeps the \
            user's focus.",
    },
    AgentTool {
        name: "agents_palette_open",
        verb: Verb::PaletteOpen,
        title: "Open command palette",
        description: "Open the cmux command palette (`cmux agents palette open`). Its purpose \
            is to show the palette, so it takes the user's focus.",
    },
    AgentTool {
        name: "agents_dialog_list",
        verb: Verb::DialogList,
        title: "List dialogs",
        description: "List the permission and question dialogs that other agents in cmux are \
            waiting on (`cmux agents dialog list`). They show other agents' pending tool \
            inputs, such as commands and file edits. all includes answered ones. Changes \
            nothing.",
    },
    AgentTool {
        name: "agents_dialog_answer",
        verb: Verb::DialogAnswer,
        title: "Answer dialog",
        description: "Reply to other agents' dialogs from agents_dialog_list (`cmux agents \
            dialog answer`): deny a permission request with mode \"deny\", or answer a \
            question with one or more selections. Give exactly one of mode or selections. \
            Permissions can only be denied here; a person approves them in cmux.",
    },
    AgentTool {
        name: "agents_chat_send",
        verb: Verb::ChatSend,
        title: "Prompt another chat",
        description: "Send a prompt to another agent chat of this cmux session (`cmux agents \
            chat send`), as an agent message: the chat shows it as coming from another agent, \
            and its agent reads it as input, not as its operator's instruction. Never the \
            caller's own chat. Answers {action, origin, result: {chat, message_id, state}, \
            idempotency_key}; state is delivered, queued, or held for a person's approval. \
            Wait for the answer with agents_wait (until idle, this chat as target) and read it \
            with agents_chat_read. When the message is stored but cannot be \
            handed to the chat, the call is an error whose receipt says state failed.",
    },
    AgentTool {
        name: "agents_chat_read",
        verb: Verb::ChatRead,
        title: "Read a chat",
        description: "Read an agent chat of this cmux session (`cmux agents chat read`) as \
            items {id, role, text}: user (with origin and from when another agent sent it), \
            assistant, tool (a summary: kind and status only, never its title, input or \
            output) and turn_end. Pass after = next_after to read on; an answer still being \
            written or a tool call still running is marked partial and read again whole. \
            Changes nothing.",
    },
    AgentTool {
        name: "agents_chat_new",
        verb: Verb::ChatNew,
        title: "Start a chat",
        description: "Start an ordinary cmux agent chat, as New Agent Chat and a first message \
            do (`cmux agents chat new`): in pane (a pane_ id), in workspace's focused pane, \
            else its first (a ws_ id), or in a new workspace when neither is given; it runs in \
            the app's own acpmux, never as your subagent. Nothing takes the person's focus or \
            switches the shown workspace. harness, model, effort and mode pick how it runs \
            (acpmux refuses a mode this caller may not start in); policy is ask, \
            approve-reads or deny-all, since a person chooses approve-edits or approve-all in \
            cmux. prompt is the chat's first prompt, its own as if typed (state accepted). A \
            retry starts another chat. Answers {action, origin, result: {chat, opened, tab, \
            pane, workspace, prompt}}; opened false (with open_error) means the chat runs but \
            no tab shows it yet, pending that the app is still opening it.",
    },
    AgentTool {
        name: "agents_chat_state",
        verb: Verb::ChatState,
        title: "Read a chat's state",
        description: "What an agent chat of this cmux session is doing (`cmux agents chat \
            state`): status, running, pending_permissions, queued, harness, model, mode. \
            Changes nothing.",
    },
    AgentTool {
        name: "agents_chat_interrupt",
        verb: Verb::ChatInterrupt,
        title: "Interrupt a chat",
        description: "Stop the running turn of another agent chat of this cmux session \
            (`cmux agents chat interrupt`), as its stop button does. Never the caller's own \
            chat. Nudge it on afterwards with agents_chat_send.",
    },
];

pub(super) fn find(name: &str) -> Option<&'static AgentTool> {
    TOOLS.iter().find(|tool| tool.name == name)
}

fn id_schema(description: &str) -> Value {
    json!({"type": "string", "minLength": 1, "pattern": "^[^-]", "description": description})
}

impl AgentTool {
    fn read_only(&self) -> bool {
        matches!(self.verb, Verb::DialogList | Verb::ChatRead | Verb::ChatState)
    }

    /// Daemon changes and `action.run` take a key; the app's feed replies
    /// do not.
    fn keyed(&self) -> bool {
        !matches!(
            self.verb,
            Verb::DialogList
                | Verb::DialogAnswer
                | Verb::ChatRead
                | Verb::ChatNew
                | Verb::ChatState
                | Verb::ChatInterrupt
        )
    }

    /// Daemon requests route to a session; the app has one.
    fn routed(&self) -> bool {
        matches!(
            self.verb,
            Verb::WorkspaceSelect
                | Verb::WorkspaceCreate
                | Verb::TabSelect
                | Verb::TerminalFocus
                | Verb::TerminalSplit
        )
    }

    /// The chat verbs answer their own receipt or page, without a snapshot.
    fn chat(&self) -> bool {
        matches!(
            self.verb,
            Verb::ChatSend | Verb::ChatRead | Verb::ChatNew | Verb::ChatState | Verb::ChatInterrupt
        )
    }

    pub(super) fn descriptor_json(&self) -> Value {
        let idempotent = !matches!(
            self.verb,
            Verb::WorkspaceCreate
                | Verb::TerminalSplit
                | Verb::DialogAnswer
                | Verb::ChatSend
                | Verb::ChatNew
        );
        let description = if self.chat() {
            self.description.to_owned()
        } else {
            format!("{}{RECEIPT}", self.description)
        };
        json!({
            "name": self.name,
            "title": self.title,
            "description": description,
            "inputSchema": self.input_schema(),
            "annotations": {
                "readOnlyHint": self.read_only(),
                "destructiveHint": matches!(
                    self.verb,
                    Verb::DialogAnswer | Verb::ChatSend | Verb::ChatInterrupt
                ),
                "idempotentHint": idempotent,
                "openWorldHint": false,
            },
        })
    }

    fn input_schema(&self) -> Value {
        let mut properties = Map::new();
        let mut required = Vec::new();
        match self.verb {
            Verb::WorkspaceSelect => {
                properties.insert(
                    "workspace".into(),
                    id_schema("The workspace (ws_ id, unique prefix or <session>:<id>)."),
                );
                required.push("workspace");
            }
            Verb::WorkspaceCreate => {
                properties.insert(
                    "name".into(),
                    json!({"type": "string", "minLength": 1, "description": "The name."}),
                );
                properties.insert(
                    "empty".into(),
                    json!({"type": "boolean", "description": "Create it with no terminal."}),
                );
            }
            Verb::TabSelect | Verb::TerminalFocus => {
                properties.insert(
                    "tab".into(),
                    id_schema("The tab (tab_ id, unique prefix or <session>:<id>)."),
                );
                required.push("tab");
            }
            Verb::TerminalSplit => {
                properties.insert(
                    "direction".into(),
                    json!({"type": "string", "enum": ["left", "right", "up", "down"]}),
                );
                properties.insert(
                    "pane".into(),
                    id_schema("The pane to split (pane_ id); default the current pane."),
                );
                required.push("direction");
            }
            Verb::PaletteOpen => {}
            Verb::DialogList => {
                properties.insert(
                    "all".into(),
                    json!({"type": "boolean", "description": "Include answered dialogs."}),
                );
            }
            Verb::DialogAnswer => {
                properties.insert(
                    "request_id".into(),
                    id_schema("The dialog's request id from agents_dialog_list."),
                );
                properties.insert(
                    "mode".into(),
                    json!({
                        "type": "string",
                        "enum": ["deny"],
                        "description": "Deny the permission request. Approving is not offered \
                            over MCP.",
                    }),
                );
                properties.insert(
                    "selections".into(),
                    json!({
                        "type": "array",
                        "minItems": 1,
                        "items": {"type": "string", "minLength": 1, "pattern": "^[^-]"},
                        "description": "The question's chosen options.",
                    }),
                );
                required.push("request_id");
            }
            Verb::ChatSend => {
                properties.insert(
                    "target".into(),
                    id_schema("The chat: its acpmux session id, name or unique prefix."),
                );
                properties.insert(
                    "text".into(),
                    json!({
                        "type": "string",
                        "minLength": 1,
                        "maxLength": agent_message::MAX_BODY_BYTES,
                        "description": "The prompt, at most 32 KiB of UTF-8.",
                    }),
                );
                required.extend(["target", "text"]);
            }
            Verb::ChatRead => {
                properties.insert(
                    "target".into(),
                    id_schema("The chat: its acpmux session id, name or unique prefix."),
                );
                properties.insert(
                    "after".into(),
                    json!({"type": "integer", "minimum": 0, "description": "Read the items \
                        after this item id (next_after of the last read); 0 from the start."}),
                );
                properties.insert(
                    "limit".into(),
                    json!({"type": "integer", "minimum": 1, "maximum": chat::MAX_READ_LIMIT,
                           "default": chat::DEFAULT_READ_LIMIT}),
                );
                required.push("target");
            }
            Verb::ChatNew => {
                properties.insert(
                    "workspace".into(),
                    id_schema(
                        "The workspace whose focused pane (else its first) gets the chat (ws_ id).",
                    ),
                );
                properties
                    .insert("pane".into(), id_schema("The pane that gets the chat (pane_ id)."));
                for (name, description) in [
                    ("harness", "The harness: claude, codex or another acpmux profile."),
                    ("model", "The model, as the harness names it."),
                    ("effort", "Thinking effort: default, low, medium, high, xhigh or max."),
                    ("mode", "The harness mode to start in."),
                    ("policy", "ask, approve-reads or deny-all."),
                    ("cwd", "The chat's folder, an absolute path."),
                    ("name", "The chat's name (and a new workspace's)."),
                ] {
                    properties.insert(
                        name.into(),
                        json!({"type": "string", "minLength": 1, "description": description}),
                    );
                }
                properties.insert(
                    "prompt".into(),
                    json!({
                        "type": "string",
                        "minLength": 1,
                        "maxLength": agent_message::MAX_BODY_BYTES,
                        "description": "A first prompt, at most 32 KiB of UTF-8.",
                    }),
                );
            }
            Verb::ChatState | Verb::ChatInterrupt => {
                properties.insert(
                    "target".into(),
                    id_schema("The chat: its acpmux session id, name or unique prefix."),
                );
                required.push("target");
            }
        }
        if self.routed() {
            properties.insert(
                "session".into(),
                json!({
                    "type": "string",
                    "minLength": 1,
                    "description": "The named cmux session to use, as `cmux --session`.",
                }),
            );
        }
        if self.keyed() {
            properties.insert(
                "idempotency_key".into(),
                json!({
                    "type": "string",
                    "minLength": 1,
                    "maxLength": 128,
                    "description": "Names this change so a retry cannot apply it twice. \
                        Generated when absent; a failed call returns it.",
                }),
            );
        }
        json!({
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        })
    }

    pub(super) fn call<B: Backend>(&self, backend: &B, arguments: &Map<String, Value>) -> Value {
        let not_run =
            |message: String| tool_error(envelope(v2_tools::invalid(message), "not_run", None));
        let (command, session, key) = match self.command(arguments) {
            Ok(call) => call,
            Err(message) => return not_run(message),
        };
        match agents::execute(backend, session.as_deref(), &command, key.as_deref(), "mcp") {
            Ok(receipt) if self.chat() => {
                let failed = chat::delivery_failed(&receipt);
                let mut result = success(receipt, !self.read_only());
                // Stored but not handed to the chat: an error that keeps its
                // receipt, so a retry can name the message.
                if failed {
                    result["isError"] = json!(true);
                }
                result
            }
            Ok(receipt) => success(fit_receipt(receipt), !self.read_only()),
            Err(AgentFailure::Usage(message)) => not_run(message),
            Err(AgentFailure::Owner(failure)) => failure_result(failure),
        }
    }

    /// The `cmux agents` command these arguments name, its session and key.
    fn command(
        &self,
        arguments: &Map<String, Value>,
    ) -> Result<(AgentCommand, Option<String>, Option<String>), String> {
        let schema = self.input_schema();
        if let Some(name) = arguments.keys().find(|name| schema["properties"].get(*name).is_none())
        {
            return Err(format!("{} has no argument {name:?}", self.name));
        }
        let args = Arguments { tool: self.name, values: arguments };
        let mut words = Vec::new();
        match self.verb {
            Verb::WorkspaceSelect => {
                words.extend(["workspace".into(), "select".into(), args.word("workspace")?]);
            }
            Verb::WorkspaceCreate => {
                words.extend(["workspace".into(), "create".into()]);
                if let Some(name) = args.text("name")? {
                    // Inline, so a name that starts with `--` stays a value.
                    words.push(format!("--name={name}"));
                }
                if args.flag("empty")? {
                    words.push("--empty".into());
                }
            }
            Verb::TabSelect => words.extend(["tab".into(), "select".into(), args.word("tab")?]),
            Verb::TerminalFocus => {
                words.extend(["terminal".into(), "focus".into(), args.word("tab")?]);
            }
            Verb::TerminalSplit => {
                let direction = args.word("direction")?;
                if !matches!(direction.as_str(), "left" | "right" | "up" | "down") {
                    return Err(format!(
                        "{}: direction must be left, right, up or down",
                        self.name
                    ));
                }
                words.extend(["terminal".into(), "split".into(), direction]);
                if args.values.contains_key("pane") {
                    words.extend(["--surface".into(), args.word("pane")?]);
                }
            }
            Verb::PaletteOpen => words.extend(["palette".into(), "open".into()]),
            Verb::DialogList => {
                words.extend(["dialog".into(), "list".into()]);
                if args.flag("all")? {
                    words.push("--all".into());
                }
            }
            Verb::DialogAnswer => {
                words.extend(["dialog".into(), "answer".into(), args.word("request_id")?]);
                if args.values.contains_key("mode") {
                    let mode = args.word("mode")?;
                    // A chat agent must not approve its own request or switch another
                    // session's permissions; a person approves in cmux.
                    if mode != "deny" {
                        return Err(format!(
                            "{}: approve permissions in cmux, not over MCP; only mode \"deny\" \
                             is accepted",
                            self.name
                        ));
                    }
                    words.extend(["--mode".into(), mode]);
                }
                for selection in args.words("selections")? {
                    words.extend(["--selection".into(), selection]);
                }
            }
            Verb::ChatSend => {
                words.extend(["chat".into(), "send".into(), args.word("target")?]);
                let text =
                    args.text("text")?.ok_or_else(|| format!("{}: text is required", self.name))?;
                // After `--`, so text that starts with a dash stays text.
                words.extend(["--".into(), text]);
            }
            Verb::ChatRead => {
                words.extend(["chat".into(), "read".into(), args.word("target")?]);
                for name in ["after", "limit"] {
                    if let Some(value) = args.values.get(name) {
                        let number = value.as_u64().ok_or_else(|| {
                            format!("{}: {name} must be a nonnegative integer", self.name)
                        })?;
                        words.push(format!("--{name}={number}"));
                    }
                }
            }
            Verb::ChatNew => {
                words.extend(["chat".into(), "new".into()]);
                for name in [
                    "workspace",
                    "pane",
                    "harness",
                    "model",
                    "effort",
                    "mode",
                    "policy",
                    "cwd",
                    "name",
                ] {
                    if let Some(value) = args.text(name)? {
                        // Inline, so a value that starts with `--` stays a value.
                        words.push(format!("--{name}={value}"));
                    }
                }
                if let Some(prompt) = args.text("prompt")? {
                    words.extend(["--".into(), prompt]);
                }
            }
            Verb::ChatState => {
                words.extend(["chat".into(), "state".into(), args.word("target")?]);
            }
            Verb::ChatInterrupt => {
                words.extend(["chat".into(), "interrupt".into(), args.word("target")?]);
            }
        }
        let key = match args.text("idempotency_key")? {
            Some(key) => {
                cmux_tui_core::resource::validate_idempotency_key(&key)
                    .map_err(|error| error.message)?;
                Some(key)
            }
            None => None,
        };
        let mut global = GlobalArgs { session: args.text("session")?, ..GlobalArgs::default() };
        agents::normalize_qualified_targets(&mut global, &mut words).map_err(|error| error.0)?;
        let command = agents::command(&words).map_err(|error| error.0)?;
        Ok((command, global.session, key))
    }
}

/// A tool call's arguments, read as the words `cmux agents` takes.
struct Arguments<'a> {
    tool: &'static str,
    values: &'a Map<String, Value>,
}

impl Arguments<'_> {
    /// A nonempty string, when given.
    fn text(&self, name: &str) -> Result<Option<String>, String> {
        match self.values.get(name) {
            None => Ok(None),
            Some(Value::String(value)) if !value.is_empty() => Ok(Some(value.clone())),
            Some(_) => Err(format!("{}: {name} must be a nonempty string", self.tool)),
        }
    }

    /// A required word: a string that the CLI grammar cannot read as a flag.
    fn word(&self, name: &str) -> Result<String, String> {
        let value = self.text(name)?.ok_or_else(|| format!("{}: {name} is required", self.tool))?;
        checked_word(self.tool, name, value)
    }

    /// Each string of an array argument, as words; none when absent.
    fn words(&self, name: &str) -> Result<Vec<String>, String> {
        match self.values.get(name) {
            None => Ok(Vec::new()),
            Some(Value::Array(items)) if !items.is_empty() => items
                .iter()
                .map(|item| match item {
                    Value::String(value) if !value.is_empty() => {
                        checked_word(self.tool, name, value.clone())
                    }
                    _ => Err(format!("{}: {name} must hold nonempty strings", self.tool)),
                })
                .collect(),
            Some(_) => Err(format!("{}: {name} must be a nonempty array of strings", self.tool)),
        }
    }

    fn flag(&self, name: &str) -> Result<bool, String> {
        match self.values.get(name) {
            None => Ok(false),
            Some(Value::Bool(value)) => Ok(*value),
            Some(_) => Err(format!("{}: {name} must be true or false", self.tool)),
        }
    }
}

/// A receipt that fits the result limit: when the snapshot makes it too
/// large, `state` alone gives way, so the action, its result (the new ids)
/// and the idempotency key survive.
pub(super) fn fit_receipt(mut receipt: Value) -> Value {
    let size = serde_json::to_vec(&receipt).map(|bytes| bytes.len()).unwrap_or(usize::MAX);
    if size > super::MAX_RESULT_BYTES {
        receipt["state"] = json!({"truncated": true, "hint": "call agents_snapshot"});
    }
    receipt
}

fn checked_word(tool: &str, name: &str, value: String) -> Result<String, String> {
    if value.starts_with('-') {
        return Err(format!("{tool}: {name} must not start with '-'"));
    }
    Ok(value)
}
