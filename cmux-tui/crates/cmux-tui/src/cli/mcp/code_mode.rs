//! Code mode: `serve` offers two tools, `cmux_docs` and `cmux_exec`, in
//! place of one tool per operation (plans/cmux-next/code-mode.md). The
//! full tool list (daemon operations, browser host, agents, app actions)
//! stays the API: `cmux_docs` searches it and a `cmux_exec` script calls
//! it through the same `Server::call` path, so a script has exactly the
//! rights of a direct tool call and nothing else. 638 tool schemas were
//! about 208k tokens in every agent turn; these two are about 1k.
//!
//! A script runs in an embedded QuickJS engine on its own thread. The engine
//! has no file system, network, process or timer access: its only host
//! functions are `cmux.call`, `cmux.docs` and `console`. Each call goes back
//! to the server's thread over a channel and is answered there, one at a
//! time, in order.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_json::JsonSet as _;
use rquickjs::{CatchResultExt, Context, Function, Object, Runtime};
use serde_json::{Map, Value, json};

pub(super) const DOCS: &str = "cmux_docs";
pub(super) const EXEC: &str = "cmux_exec";

/// The largest script source.
const MAX_SCRIPT_BYTES: usize = 256 << 10;
/// The engine's stack, inside a thread stack of `THREAD_STACK`.
const MAX_STACK: usize = 1 << 20;
const THREAD_STACK: usize = 8 << 20;
/// What one script may use.
#[derive(Clone, Copy, Debug)]
pub(super) struct Limits {
    /// The engine's heap.
    pub memory: usize,
    /// A script that computes this long without a cmux call is stopped (a
    /// loop that never ends). Time inside a call does not count: a call has
    /// its own owner deadline.
    pub compute: Duration,
    /// The whole script, calls included. While a script runs the server
    /// reads no other request, so this bounds that wait.
    pub total: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            memory: 64 << 20,
            compute: Duration::from_secs(30),
            total: Duration::from_secs(10 * 60),
        }
    }
}

/// Calls and docs searches in one script.
const MAX_CALLS: usize = 2_000;
/// Calls a result lists one by one; the rest are only counted.
const MAX_CALL_RECORDS: usize = 200;
/// The longest tool name a script may call (the longest real one is under 60).
const MAX_TOOL_NAME_BYTES: usize = 128;
/// Console text kept per script (each line counts one more byte, so empty
/// lines count too); later lines are dropped and counted.
const MAX_LOG_BYTES: usize = 64 << 10;
/// Tools with schemas in one docs answer, by default and at most.
const DOCS_DEFAULT_LIMIT: usize = 8;
const DOCS_MAX_LIMIT: usize = 30;
/// Further matching names a docs answer lists without schemas.
const DOCS_MORE_NAMES: usize = 24;

/// Optional arguments every change or read takes (an idempotency key, a
/// revision precondition, a session or machine route); a docs answer lists
/// them by name only, in `alsoTakes`.
const COMMON_ARGUMENTS: [&str; 5] =
    ["idempotency_key", "expected_revision", "correlation_key", "session", "machine"];
/// Selector arguments, whose long shared description [`INSTRUCTIONS`] gives.
const SELECTORS: [&str; 6] = ["workspace", "screen", "pane", "tab", "terminal", "window"];
/// Sentences every daemon tool or app action description repeats.
const BOILERPLATE: [&str; 4] = [
    " Changes state on the cmux session daemon. A call that fails with state in_progress may \
     have applied; retry it with the idempotency_key the error returns.",
    " Reads the cmux session daemon and changes nothing.",
    " Runs in the cmux app and waits until its work is done.",
    " An MCP run changes the user's focus only when focus is true or the action's purpose is \
     focus.",
];

pub(super) const INSTRUCTIONS: &str = "This chat runs in cmux: a terminal, tab or workspace \
    the person asks for (\"on my right\", \"a new workspace\") is a cmux one, made and run with \
    these tools, not your own shell. cmux tools run through cmux_exec scripts; its \
    description lists the common ones. Selectors take a public id (ws_…, pane_…, tab_…, \
    term_…), a unique prefix, <session>:<id> or an exact name; workspace, screen, pane and tab \
    also take `current` (this chat's own) or `focused` (the one the person looks at). Tools of the chat's \
    other cmux servers (cua_*: computer use on Mac \
    apps; secrets_*, sessions_*, subsessions_*, forum_*) come with their \
    rules in `servers` of a cmux.docs answer: follow them. A change takes idempotency_key: on \
    in_progress, retry with the key from the error; another server's call that fails \
    in_progress has no key and may have run, so check its effect first. Tools never move the \
    person's focus unless the call passes focus: true or the tool's purpose is focus. Name workspaces and tabs to the person \
    by title, never by id. When they must act in a tab (log in, confirm), tab_update {tab, \
    attention: \"reason\"} marks it. In a reply, ![alt](/abs/path.png) shows an image.";

/// The tool family of the computer use server (`cmux-cua` folds as `cua_*`).
pub(super) const COMPUTER_USE_FAMILY: &str = "cua";
/// What `cmux_exec` says when the chat has computer use.
pub(super) const COMPUTER_USE_NOTE: &str = " It includes cmux Computer Use: the cua_* tools see \
    and operate the apps on the person's Mac (screenshots, clicks, typing). Use them for any \
    task in a desktop app, never osascript or AppleScript keystrokes; `cmux.docs(\"cua\")` \
    lists them with their rules. Never type into a terminal or script tool, never copy app \
    data out of the app unless the person asked, and stop before a payment, a password, \
    sending a message or deleting that they did not ask for, and say what is left.";

/// The one tool `serve` lists in code mode, `cmux_exec` (Lawrence 2026-10-23:
/// an agent sees no other cmux tool name; a script searches with
/// `cmux.docs`, and `cmux_docs` stays callable for older prompts). `tools`
/// is the full list, for the family summary in its description.
pub(super) fn descriptors(tools: &[Value]) -> Vec<Value> {
    // A chat with acpmux's background tasks (acpmux `acpmux_mcp_bg.rs`) is told to use them in
    // the one description every turn shows: in code mode a server's own instructions reach the
    // agent only through `cmux.docs`, and a Codex chat has no hook to steer its shell.
    let bg = if tools.iter().any(|t| t["name"] == BG_START) { BG_STEER } else { "" };
    let grouped = families(tools);
    // A harness that shows one tool must still find computer use in it: a
    // chat asked to "open Calculator" used osascript (2026-10-27).
    let computer_use =
        if grouped.contains_key(COMPUTER_USE_FAMILY) { COMPUTER_USE_NOTE } else { "" };
    let families = grouped
        .iter()
        .map(|(family, names)| format!("{family} ({})", names.len()))
        .collect::<Vec<_>>()
        .join(", ");
    vec![json!({
        "name": EXEC,
        "title": "Run a cmux script",
        "description": format!(
            "Run JavaScript that calls cmux tools and return its result. This chat runs in \
             cmux: a terminal, tab or workspace the person asks for is a cmux one, made here, \
             not in your own shell, and \"this workspace\" is the cmux workspace this chat is \
             in (workspace: \"current\"), never the folder.{computer_use} An async \
             function \
             body, `await cmux.<tool>({{...}})` per call, `return` a JSON value. Do related \
             steps in one script: look up, act and check together. No file system, network or \
             timers; console.log comes back in logs.\n\n\
             Common tools (no docs search needed):\n\
             - workspace_list, workspace_get, pane_list {{workspace}}, tab_list {{pane | \
             workspace}}, terminal_list, terminal_get: ids and names. Lists answer {{items: \
             [...]}}; a change answers {{value: {{...}}}} with the new ids (value.terminal_id, \
             value.pane_id, value.tab_id).\n\
             - pane_neighbor_get {{pane: \"current\", direction: \"right\"}} answers {{pane: \
             {{id, ...}}}} for the pane on the person's right, or {{pane: null}}; \
             terminal_process_get {{terminal}} names the program running in a terminal.\n\
             - To run a command for the person: tab_create_terminal {{name}}, with no pane \
             (pane: \"current\" is this chat's own pane; for a tab beside it, pass its id from pane_get), opens a shell on the person's right (a tab in the column right of this chat, or a new column \
             when there is none), then terminal_input_write {{terminal: value.terminal_id, \
             text: \"cmd\\n\"}} runs it there and the tab stays open with its output. Use this \
             for 'open a terminal', 'run X on my right', 'next to my logs'. With shell (or \
             argv) the tab runs only that command and closes when it exits.\n\
             - pane_split {{pane, direction}}: only when the person says \"split\", \"below\" \
             or \"underneath\" (direction: \"down\"), or wants two terminals \"side by side\". \
             The split makes the new pane's terminal (value.terminal_id): write into it, do not \
             add a tab. \"Next to my logs\", \"beside X\" or \"on the right\" means a \
             new tab in that pane: tab_create_terminal {{pane}}, or no pane for the column \
             right of this chat (pane: \"current\" is this chat's own pane, not the right).\n\
             - terminal_input_write {{terminal, text: \"cmd\\n\"}}; terminal_wait {{terminal, \
             pattern, timeout_ms}} waits for a regex on the screen (never sleep or poll). The \
             typed command is on the screen too, so match the output line: pattern \
             \"(?m)^DONE\" for `cmd; echo DONE`. terminal_screen_read and terminal_history_read \
             {{terminal}} read it (history answers {{text}}, the scrollback's lines); return only the \
             lines you need: (await cmux.terminal_history_read({{terminal}})).text.split(\"\\n\").\
             filter((l) => l.includes(\"error\")). Return small results: a list's ids and names, \
             not every record.\n\
             - tab_rename {{tab, name}}, tab_close {{tab}}, tab_focus {{tab}}; workspace_rename \
             {{workspace, name}}; tab_move {{tab, destination_pane}} (or destination_workspace: \
             its active pane; it goes last); workspace_create {{name}} (it opens with a terminal \
             pane that a moved tab can go into; initial_content: \"empty\" has no pane); \
             terminal_input_keys \
             {{terminal, keys: [\"ctrl+c\"]}} presses keys (enter, escape, up).\n\
             - Groups: tab_group_create {{tabs: [ids], name}}; workspace_group_create {{name}}, \
             then workspace_place {{workspace, group: <its id>}} for each member.\n\
             - Open a file, diff or page in cmux (not a terminal): open {{kind: \"file\" | \
             \"diff\" | \"page\", path | url, where}} in one call; where: right (default), \
             left, below, above, here, sticky (a docked column; edge), pane {{pane}}, workspace \
             {{workspace}}. Several opens with where: right share one column. To make an \
             existing column sticky: column_update {{screen, column, dock: true, edge}} \
             (column: its column_id in screen_layout_export).\n\
             - workspace_status_set {{workspace, key, text}} (a sidebar status pill); \
             workspace_status_clear {{workspace, key}} removes it (an empty text leaves an empty \
             pill); \
             notification_create {{title, body}}.\n\
             - A video file (a screen recording, an attached .mp4 or .mov): video_frames {{path, \
             at: [seconds] | range: {{from, to, count}} | scenes: true, maxSide}} answers its \
             frames as images you see, with each one's time; video_info {{path}} its length, \
             size, fps and audio. Use these instead of ffmpeg.\n\n\
             Anything else: `await cmux.docs(\"words\")` answers {{tools: [{{name, description, \
             inputSchema}}], more: [names]}}; a tool's exact name finds it first. \
             app_* tools are the app's menu actions. A failed call throws an Error whose `cmux` \
             field has the error, its state and its idempotency key; its message names the fix. \
             A failed script reports the calls that already ran. Families: {families}.{bg}"
        ),
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "script": {
                    "type": "string",
                    "minLength": 1,
                    "description": "JavaScript, an async function body",
                },
            },
            "required": ["script"],
        },
        "annotations": {"destructiveHint": true, "openWorldHint": false},
    })]
}

/// acpmux's `bg_start` behind this server (its upstream prefix `acpmux`).
const BG_START: &str = "acpmux_bg_start";
const BG_STEER: &str = " Long-running commands (a dev server, a watcher, a long build or \
    test run) go to `cmux.acpmux_bg_start({command, cwd})`, not a background shell or terminal \
    of your own: this chat's agent hibernates after 2 idle minutes and its own background shells \
    end with it, while that task keeps running; `cmux.acpmux_bg_output({id, fromByte})` reads it.";

/// Tool names grouped by their first word (`pane_split` is `pane`).
fn families(tools: &[Value]) -> BTreeMap<String, Vec<String>> {
    let mut families = BTreeMap::<String, Vec<String>>::new();
    for name in tools.iter().filter_map(|tool| tool["name"].as_str()) {
        let family = name.split('_').next().unwrap_or(name);
        families.entry(family.to_owned()).or_default().push(name.to_owned());
    }
    families
}

/// `cmux_docs`: tools that match, with schemas; or every name by family.
pub(super) fn docs(tools: &[Value], arguments: &Map<String, Value>) -> Result<Value, String> {
    if let Some(name) =
        arguments.keys().find(|name| !matches!(name.as_str(), "query" | "names" | "limit"))
    {
        return Err(format!("{DOCS} has no argument {name:?}"));
    }
    let limit = match arguments.get("limit") {
        None => DOCS_DEFAULT_LIMIT,
        Some(value) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| (1..=DOCS_MAX_LIMIT).contains(value))
            .ok_or_else(|| format!("{DOCS} limit must be an integer from 1 to {DOCS_MAX_LIMIT}"))?,
    };
    if let Some(names) = arguments.get("names") {
        let names = names
            .as_array()
            .and_then(|names| names.iter().map(Value::as_str).collect::<Option<Vec<_>>>())
            .ok_or_else(|| format!("{DOCS} names must be an array of strings"))?;
        if names.len() > DOCS_MAX_LIMIT {
            return Err(format!("{DOCS} names takes at most {DOCS_MAX_LIMIT} names"));
        }
        let mut found = Vec::new();
        let mut unknown = Vec::new();
        for name in names {
            match tools.iter().find(|tool| tool["name"] == name) {
                Some(tool) => found.push(compact(tool)),
                None => unknown.push(name),
            }
        }
        return Ok(json!({"tools": found, "unknown": unknown}));
    }
    let query = match arguments.get("query") {
        None => None,
        Some(Value::String(query)) => Some(query.trim().to_lowercase()).filter(|q| !q.is_empty()),
        Some(_) => return Err(format!("{DOCS} query must be a string")),
    };
    let Some(query) = query else {
        return Ok(json!({"families": families(tools)}));
    };
    // A query of exact tool names (`cmux.docs("tab_create_browser")`, or several) answers
    // those tools only; the rest of the search goes in `more` by name. A full search put
    // 8 schemas (11k characters) in front of the model for one name (tests/tool-evals r13a).
    let mut words: Vec<&str> = query.split([' ', ',']).filter(|w| !w.is_empty()).collect();
    words.dedup();
    let exact: Vec<&Value> = words
        .iter()
        .filter_map(|word| {
            tools.iter().find(|tool| tool.get("name").and_then(Value::as_str) == Some(*word))
        })
        .collect();
    if !exact.is_empty() && exact.len() == words.len() && exact.len() <= DOCS_MAX_LIMIT {
        let mut answer = search(tools, &query, limit);
        let named: Vec<&str> =
            exact.iter().filter_map(|tool| tool.get("name").and_then(Value::as_str)).collect();
        let rest = answer
            .get("tools")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str))
            .filter(|name| !named.contains(name))
            .map(|name| json!(name));
        let more: Vec<Value> = rest
            .chain(answer.get("more").and_then(Value::as_array).into_iter().flatten().cloned())
            .collect();
        answer.set("tools", Value::Array(exact.into_iter().map(compact).collect()));
        answer.set("more", Value::Array(more));
        return Ok(answer);
    }
    Ok(search(tools, &query, limit))
}

/// Query words that name no tool.
const STOP_WORDS: [&str; 15] = [
    "a", "an", "and", "as", "for", "in", "into", "it", "my", "of", "on", "or", "the", "to", "with",
];

/// Tools whose name, description or argument names contain words of
/// `query`, best first: a word in the name counts most, then the tools that
/// match more words, then a daemon tool before the app action that does the
/// same (`app_*`). A tool must match at least half the words, so an
/// agent's sentence ("pane split terminal send") still finds `pane_split`
/// (tool-evals, 2026-10-27: an all-words match found nothing and the agent
/// searched again).
fn search(tools: &[Value], query: &str, limit: usize) -> Value {
    let terms = query
        .split(|c: char| c.is_whitespace() || matches!(c, '_' | '.' | '-'))
        .filter(|t| !t.is_empty() && !STOP_WORDS.contains(t))
        .collect::<Vec<_>>();
    if terms.is_empty() {
        return json!({"query": query, "families": families(tools)});
    }
    let needed = terms.len().div_ceil(2);
    // A tool's own name ("tab_list", "tab list") comes first.
    let exact_name = query.trim().replace([' ', '.', '-'], "_");
    let mut scored = tools
        .iter()
        .filter_map(|tool| {
            let name = tool["name"].as_str()?.to_lowercase();
            let description =
                super::upstream::without_rules(tool["description"].as_str().unwrap_or_default())
                    .to_lowercase();
            let arguments = tool["inputSchema"]["properties"]
                .as_object()
                .map(|properties| properties.keys().cloned().collect::<Vec<_>>().join(" "))
                .unwrap_or_default()
                .to_lowercase();
            let (mut matched, mut score) = (0, 0);
            for term in &terms {
                let points = match () {
                    () if name.contains(term) => 4,
                    () if description.contains(term) => 1,
                    () if arguments.contains(term) => 1,
                    () => 0,
                };
                matched += usize::from(points > 0);
                score += points;
            }
            let exact = name == exact_name;
            (matched >= needed).then_some((exact, matched, score, name.starts_with("app_"), tool))
        })
        .collect::<Vec<_>>();
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then(b.2.cmp(&a.2))
            .then(b.1.cmp(&a.1))
            .then(a.3.cmp(&b.3))
            .then_with(|| a.4["name"].as_str().cmp(&b.4["name"].as_str()))
    });
    let scored = scored.into_iter().map(|(_, _, score, _, tool)| (score, tool)).collect::<Vec<_>>();
    let more = scored
        .iter()
        .skip(limit)
        .take(DOCS_MORE_NAMES)
        .filter_map(|(_, tool)| tool["name"].as_str())
        .collect::<Vec<_>>();
    let mut answer = json!({
        "query": query,
        "matches": scored.len(),
        "tools": scored.iter().take(limit).map(|(_, tool)| compact(tool)).collect::<Vec<_>>(),
        "more": more,
    });
    // A task no one tool answers (`cmux docs search` returns the same).
    let guides = super::super::docs::guides(query);
    if !guides.is_empty() {
        answer.set("guides", json!(guides));
    }
    answer
}

/// Up to five tool names for a name no tool has: what a docs search for
/// its words finds, daemon tools first.
pub(super) fn nearest_names(tools: &[Value], name: &str) -> Vec<String> {
    search(tools, &name.to_lowercase(), 5)
        .get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|tool| tool["name"].as_str().map(str::to_owned))
        .collect()
}

/// A tool as a docs answer shows it: what a model needs to call it, at
/// about half the size of the listed descriptor (tests/tool-evals,
/// 2026-10-27: six typical docs answers were 82 KB, most of it the same
/// selector, idempotency and protocol text in every tool). The call is
/// still checked against the full schema.
fn compact(tool: &Value) -> Value {
    // Only cmux's own tools share this text; another server's tool (a
    // sub-session's `session`, say) keeps its full descriptor.
    let own = tool["description"].as_str().is_some_and(|description| {
        description.contains("(cmux.protocol/2 `") || description.contains("cmux app action `")
    });
    if !own {
        return tool.clone();
    }
    let required = tool
        .pointer("/inputSchema/required")
        .and_then(Value::as_array)
        .map(|names| names.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>())
        .unwrap_or_default();
    let mut description = tool["description"].as_str().unwrap_or_default().to_owned();
    for sentence in BOILERPLATE {
        description = description.replace(sentence, "");
    }
    // "(cmux.protocol/2 `pane.split`)" names the wire operation, which a
    // script never uses.
    if let (Some(start), Some(tag)) =
        (description.find(" (cmux.protocol/2 `"), description.find("`)."))
        && start < tag
    {
        description.replace_range(start..tag + 2, ".");
    }
    let schema = &tool["inputSchema"];
    let mut properties = Map::new();
    let mut common = Vec::new();
    for (name, property) in schema["properties"].as_object().into_iter().flatten() {
        if COMMON_ARGUMENTS.contains(&name.as_str()) && !required.contains(name) {
            common.push(name.clone());
            continue;
        }
        let mut property = property.clone();
        if SELECTORS.contains(&name.as_str())
            && !required.contains(name)
            && let Some(object) = property.as_object_mut()
        {
            object.remove("description");
            object.remove("minLength");
        }
        properties.insert(name.clone(), property);
    }
    let mut compact = json!({
        "name": tool["name"],
        "description": description.trim(),
        "inputSchema": {"type": "object", "properties": properties},
    });
    if let Some(required) = schema.get("required").filter(|required| required != &&json!([])) {
        compact.set_path(&["inputSchema", "required"], required.clone());
    }
    if !common.is_empty() {
        compact.set("alsoTakes", json!(common));
    }
    if tool.pointer("/annotations/readOnlyHint").and_then(Value::as_bool) == Some(true) {
        compact.set("readOnly", json!(true));
    }
    if tool.pointer("/annotations/destructiveHint").and_then(Value::as_bool) == Some(true) {
        compact.set("destructive", json!(true));
    }
    compact
}

/// What a script asks the server for while it runs.
pub(super) enum Request {
    /// A tool call; the answer is `{ok, value}` or `{ok: false, message, error}`.
    Call { name: String, arguments: Map<String, Value> },
    /// `cmux.docs(query)`.
    Docs { query: String },
}

enum ToServer {
    Request(Request, mpsc::Sender<Value>),
    Done(Outcome),
}

struct Outcome {
    /// `Ok(value)` the script returned, or `Err(error)` it threw or hit.
    result: Result<Value, Value>,
    logs: Vec<String>,
    dropped_logs: usize,
}

/// `cmux_exec`: runs `arguments.script` and answers each of its requests
/// with `answer` on this thread. Returns the tool result.
pub(super) fn exec(
    arguments: &Map<String, Value>,
    limits: Limits,
    answer: &mut dyn FnMut(Request) -> Value,
) -> Result<Value, String> {
    if let Some(name) = arguments.keys().find(|name| name.as_str() != "script") {
        return Err(format!("{EXEC} has no argument {name:?}"));
    }
    let script = match arguments.get("script") {
        Some(Value::String(script)) if !script.trim().is_empty() => script.clone(),
        _ => return Err(format!("{EXEC} needs script, a non-empty string")),
    };
    if script.len() > MAX_SCRIPT_BYTES {
        return Err(format!("{EXEC} script is larger than {} KiB", MAX_SCRIPT_BYTES >> 10));
    }
    let (to_server, from_script) = mpsc::channel();
    let engine = std::thread::Builder::new()
        .name("cmux-mcp-code-mode".into())
        .stack_size(THREAD_STACK)
        .spawn(move || {
            let outcome = run_script(&script, limits, &to_server);
            let _ = to_server.send(ToServer::Done(outcome));
        })
        .map_err(|error| format!("{EXEC} cannot start its engine: {error}"))?;
    let mut calls = 0usize;
    // Whether a call may have changed something: one succeeded, or its
    // outcome is unknown (`in_progress`).
    let mut applied = false;
    let mut records = Vec::new();
    let mut outcome = None;
    for message in &from_script {
        match message {
            ToServer::Request(request, reply) => {
                let name = match &request {
                    Request::Call { name, .. } => Some(name.clone()),
                    Request::Docs { .. } => None,
                };
                let answered = answer(request);
                if let Some(name) = name {
                    calls += 1;
                    let ok = answered["ok"] == true;
                    let state = answered["error"]["state"].as_str().map(str::to_owned);
                    applied |= ok || state.as_deref() == Some("in_progress");
                    if records.len() < MAX_CALL_RECORDS {
                        let mut record = json!({"name": name, "ok": ok});
                        if let Some(state) = state {
                            record.set("state", json!(state));
                        }
                        if let Some(key) = answered["error"]["idempotency_key"].as_str() {
                            record.set("idempotency_key", json!(key));
                        }
                        records.push(record);
                    }
                }
                let _ = reply.send(answered);
            }
            ToServer::Done(done) => {
                outcome = Some(done);
                break;
            }
        }
    }
    let _ = engine.join();
    let Some(outcome) = outcome else {
        return Ok(super::tool_error(json!({
            "error": {
                "code": "script.engine",
                "message": "the script engine stopped",
                "details": {},
                "retryable": false,
            },
            "state": if applied { "partial" } else { "not_run" },
            "calls": calls,
            "call_log": records,
        })));
    };
    let mut value = json!({"calls": calls, "call_log": records, "logs": outcome.logs});
    if outcome.dropped_logs > 0 {
        value.set("dropped_logs", json!(outcome.dropped_logs));
    }
    Ok(match outcome.result {
        Ok(result) => {
            value.set("result", result);
            super::success(fit(value), applied)
        }
        Err(error) => {
            value.set("error", error);
            // `partial`: some call may have applied; `call_log` says which,
            // with each failed call's state and idempotency key.
            value.set("state", json!(if applied { "partial" } else { "not_run" }));
            super::tool_error(fit(value))
        }
    })
}

/// Keeps a result under the server's limit: a large `result` becomes a
/// text preview, then logs are cut.
fn fit(mut value: Value) -> Value {
    let budget = super::MAX_RESULT_BYTES - (4 << 10);
    let size = |value: &Value| serde_json::to_vec(value).map(|bytes| bytes.len()).unwrap_or(0);
    if size(&value) <= budget {
        return value;
    }
    for key in ["result", "error"] {
        if let Some(inner) = value.get(key).filter(|inner| size(inner) > budget / 4) {
            let text = serde_json::to_string(inner).unwrap_or_default();
            // A quarter: the preview is escaped once more inside the result.
            let mut end = budget / 4;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            value[key] = json!({"truncated": true, "bytes": text.len(), "preview": &text[..end]});
        }
    }
    while size(&value) > budget
        && let Some(logs) = value.get_mut("logs").and_then(Value::as_array_mut)
        && !logs.is_empty()
    {
        let keep = logs.len() / 2;
        logs.truncate(keep);
        value.set("logs_truncated", json!(true));
    }
    if size(&value) > budget
        && let Some(records) = value.get_mut("call_log").and_then(Value::as_array_mut)
    {
        records.clear();
        value.set("call_log_truncated", json!(true));
    }
    value
}

const PRELUDE: &str = r#"
(() => {
  const native = globalThis.__cmuxNative;
  delete globalThis.__cmuxNative;
  const format = (value) => {
    if (typeof value === "string") return value;
    try { const text = JSON.stringify(value); return text === undefined ? String(value) : text; }
    catch { return String(value); }
  };
  const encode = (value) => {
    try { const text = JSON.stringify(value); return text === undefined ? "null" : text; }
    catch { return JSON.stringify(String(value)); }
  };
  const log = (level) => (...args) => native.log(level, args.map(format).join(" "));
  globalThis.console = { log: log("log"), info: log("info"), warn: log("warn"), error: log("error"), debug: log("debug") };
  // A change answers {value: {...new ids}, revision, generation}; models read the new ids
  // from the top too (`r.terminal_id`), so they are there as well as under `value`
  // (tests/tool-evals: 6 of 9 models read the top level).
  const flat = (result) => {
    if (!result || typeof result !== "object" || Array.isArray(result)) return result;
    const inner = result.value;
    if (!inner || typeof inner !== "object" || Array.isArray(inner) || !("revision" in result)) return result;
    return { ...inner, ...result };
  };
  const call = (name, args) => {
    const answer = JSON.parse(native.call(String(name), JSON.stringify(args ?? {})));
    if (answer.ok) return flat(answer.value);
    const error = new Error(`${name}: ${answer.message}`);
    error.cmux = answer.error;
    throw error;
  };
  const base = { call, docs: (query) => JSON.parse(native.docs(String(query ?? ""))) };
  const noTimers = () => {
    throw new Error("a cmux script has no timers; wait for terminal text with cmux.terminal_wait({terminal, pattern, timeout_ms})");
  };
  globalThis.setTimeout = noTimers;
  globalThis.setInterval = noTimers;
  globalThis.cmux = new Proxy(base, {
    get(target, key) {
      if (key in target) return target[key];
      if (typeof key !== "string" || key === "then") return undefined;
      // A Promise, so `.catch()` and `.then()` work as on any async API (the call itself
      // runs now, in order). tests/tool-evals: `cmux.terminal_wait(...).catch(() => {})`
      // threw "not a function" for 22 calls across models.
      return (args) => new Promise((resolve, reject) => {
        try { resolve(call(key, args)); } catch (error) { reject(error); }
      });
    },
  });
  // `({cmux}) => {...}` takes the object a function script is called with: cmux itself.
  base.cmux = globalThis.cmux;
  globalThis.__cmuxFinish = (promise) => promise.then(
    (value) => native.done(true, encode(value)),
    (error) => native.done(false, encode({
      code: "script.error",
      message: String(error && error.message !== undefined ? error.message : error),
      stack: error && error.stack ? String(error.stack) : undefined,
      cmux: error && error.cmux,
    })),
  );
})();
"#;

/// The script as a function body. A whole script that is one anonymous function
/// (`async function () {...}`, `async () => {...}`, `(async () => {...})`, the form
/// many models send) is called with `cmux` and its value returned; as a body it would be
/// a syntax error or a function nobody calls (tests/tool-evals: 29 such scripts from one
/// model). The check is on the text alone: the function must open at the start and its
/// braces must close at the very end, so a body that merely starts with `(` (an awaited
/// call) and ends with `}` is left as written. Nothing of the script runs to decide.
fn function_body(script: &str) -> std::borrow::Cow<'_, str> {
    let trimmed = script.trim().trim_end_matches(';').trim_end();
    // `(async () => {...})()` calls itself: only its value was missing, so return it. A
    // script that already starts `return (...)()` does not start with `(`.
    if let Some(called) = trimmed.strip_suffix("()")
        && called.starts_with('(')
        && called.ends_with(')')
        && function_body(called) != std::borrow::Cow::Borrowed(called)
    {
        // Called with cmux, as an uncalled function is: `(async ({cmux}) => {...})()`
        // would destructure undefined.
        return std::borrow::Cow::Owned(format!("return await {called}(cmux);"));
    }
    let inner = match trimmed.strip_prefix('(').and_then(|rest| rest.strip_suffix(')')) {
        Some(inner) => inner.trim(),
        None => trimmed,
    };
    let head = inner.strip_prefix("async").map_or(inner, str::trim_start);
    // The `{` that opens the body: after `function (params)` or `(params) =>`. The
    // parameter list may destructure (`({cmux}) => {`, tests/tool-evals r8e: GLM 5.3
    // FlashX ran it four times and got null), so the body is the brace after the list.
    let (arrow, params) = match head.strip_prefix("function") {
        Some(rest) => (false, rest.trim_start()),
        None => (true, head),
    };
    let body_start = params.strip_prefix('(').and_then(|list| {
        let (list, rest) = list.split_once(')')?;
        if list.contains('(') {
            return None;
        }
        let rest = rest.trim_start();
        let rest = if arrow { rest.strip_prefix("=>")?.trim_start() } else { rest };
        rest.starts_with('{').then(|| inner.len() - rest.len())
    });
    let closes_at_end =
        body_start.is_some_and(|start| block_end(inner, start) == Some(inner.len() - 1));
    if closes_at_end {
        std::borrow::Cow::Owned(format!("return await ({inner})(cmux);"))
    } else {
        std::borrow::Cow::Borrowed(script)
    }
}

/// The index of the `}` that closes the `{` at `open`, skipping strings, template
/// literals and comments; `None` when it never closes.
fn block_end(text: &str, open: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let (mut depth, mut i) = (0usize, open);
    while let Some(&byte) = bytes.get(i) {
        match byte {
            b'"' | b'\'' | b'`' => {
                let quote = byte;
                i += 1;
                while let Some(&inner) = bytes.get(i).filter(|&&inner| inner != quote) {
                    i += if inner == b'\\' { 2 } else { 1 };
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while bytes.get(i).is_some_and(|&inner| inner != b'\n') {
                    i += 1;
                }
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i + 1 < bytes.len() && bytes.get(i..i + 2) != Some(b"*/".as_slice()) {
                    i += 1;
                }
                i += 1;
            }
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Runs one script on this (the engine) thread.
fn run_script(script: &str, limits: Limits, to_server: &mpsc::Sender<ToServer>) -> Outcome {
    let logs = Rc::new(RefCell::new((Vec::<String>::new(), 0usize, 0usize)));
    let done = Rc::new(RefCell::new(None::<Result<Value, Value>>));
    let failed = |message: String| Outcome {
        result: Err(json!({"code": "script.engine", "message": message})),
        logs: Vec::new(),
        dropped_logs: 0,
    };
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => return failed(format!("engine: {error}")),
    };
    runtime.set_memory_limit(limits.memory);
    runtime.set_max_stack_size(MAX_STACK);
    let started = Instant::now();
    let progress = Arc::new(Mutex::new(started));
    let stopped = Arc::new(Mutex::new(false));
    {
        let progress = progress.clone();
        let stopped = stopped.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            let over = started.elapsed() > limits.total
                || progress.lock().map(|at| at.elapsed() > limits.compute).unwrap_or(true);
            if over && let Ok(mut stopped) = stopped.lock() {
                *stopped = true;
            }
            over
        })));
    }
    let context = match Context::full(&runtime) {
        Ok(context) => context,
        Err(error) => return failed(format!("engine: {error}")),
    };
    let calls = Rc::new(RefCell::new(0usize));
    let evaluated = context.with(|ctx| -> Result<(), String> {
        let native = Object::new(ctx.clone()).map_err(|e| e.to_string())?;
        let count = calls.clone();
        let request = {
            let to_server = to_server.clone();
            let progress = progress.clone();
            move |request: Request| -> String {
                let mut used = count.borrow_mut();
                if *used >= MAX_CALLS {
                    return failure(
                        "script.too_many_calls",
                        &format!("a script makes at most {MAX_CALLS} calls and docs searches"),
                    );
                }
                *used += 1;
                drop(used);
                if started.elapsed() > limits.total {
                    return failure(
                        "script.timeout",
                        &format!("a script runs at most {} s", limits.total.as_secs()),
                    );
                }
                let (reply, answer) = mpsc::channel();
                let value = if to_server.send(ToServer::Request(request, reply)).is_ok() {
                    answer.recv().unwrap_or_else(|_| closed())
                } else {
                    closed()
                };
                if let Ok(mut at) = progress.lock() {
                    *at = Instant::now();
                }
                value.to_string()
            }
        };
        let call_request = request.clone();
        native
            .set(
                "call",
                Function::new(ctx.clone(), move |name: String, arguments: String| -> String {
                    if name.len() > MAX_TOOL_NAME_BYTES {
                        return failure("usage.invalid", "no tool has a name that long");
                    }
                    let arguments = match serde_json::from_str::<Value>(&arguments) {
                        Ok(Value::Object(arguments)) => arguments,
                        _ => return failure("usage.invalid", "tool arguments must be an object"),
                    };
                    call_request(Request::Call { name, arguments })
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        native
            .set(
                "docs",
                Function::new(ctx.clone(), move |query: String| -> String {
                    request(Request::Docs { query })
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        let log_sink = logs.clone();
        native
            .set(
                "log",
                Function::new(ctx.clone(), move |level: String, text: String| {
                    let mut logs = log_sink.borrow_mut();
                    let line = if level == "log" { text } else { format!("[{level}] {text}") };
                    if logs.2 + line.len() + 1 > MAX_LOG_BYTES {
                        logs.1 += 1;
                    } else {
                        logs.2 += line.len() + 1;
                        logs.0.push(line);
                    }
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        let done_sink = done.clone();
        native
            .set(
                "done",
                Function::new(ctx.clone(), move |ok: bool, text: String| {
                    let value = serde_json::from_str::<Value>(&text).unwrap_or(Value::String(text));
                    *done_sink.borrow_mut() = Some(if ok { Ok(value) } else { Err(value) });
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        ctx.globals().set("__cmuxNative", native).map_err(|e| e.to_string())?;
        ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(|e| format!("prelude: {e}"))?;
        // The body runs inside an async function so it can await and return.
        // `finish` leaves the global scope first, so the script cannot
        // report a result of its own through it.
        let body = function_body(script);
        let source = format!(
            "((finish) => {{ delete globalThis.__cmuxFinish; finish((async () => {{\n{body}\n}})()); }})(globalThis.__cmuxFinish);"
        );
        ctx.eval::<(), _>(source).catch(&ctx).map_err(|e| e.to_string())?;
        Ok(())
    });
    if let Err(message) = evaluated {
        let mut outcome = take_logs(&logs);
        let interrupted = stopped.lock().map(|stopped| *stopped).unwrap_or(false);
        let code = if interrupted {
            "script.timeout"
        } else if message.contains("out of memory") {
            "script.memory"
        } else {
            "script.error"
        };
        outcome.result = Err(json!({"code": code, "message": message}));
        return outcome;
    }
    loop {
        match runtime.execute_pending_job() {
            Ok(true) => {}
            Ok(false) => break,
            Err(error) => {
                if let Ok(mut logs) = logs.try_borrow_mut() {
                    let line = format!("[error] job: {error}");
                    if logs.2 + line.len() + 1 > MAX_LOG_BYTES {
                        logs.1 += 1;
                    } else {
                        logs.2 += line.len() + 1;
                        logs.0.push(line);
                    }
                }
            }
        }
        if done.borrow().is_some() {
            break;
        }
    }
    let mut outcome = take_logs(&logs);
    let interrupted = stopped.lock().map(|stopped| *stopped).unwrap_or(false);
    let result = done.borrow_mut().take();
    outcome.result = if interrupted {
        // The interrupt also stops the rejection handler, so `done` may hold
        // the engine's bare "interrupted" or nothing.
        Err(json!({
            "code": "script.timeout",
            "message": format!(
                "the script computed for {} ms without a cmux call, or ran longer than {} s",
                limits.compute.as_millis(),
                limits.total.as_secs()
            ),
        }))
    } else {
        match result {
            Some(Err(error))
                if error["message"].as_str().is_some_and(|m| m.contains("out of memory")) =>
            {
                Err(json!({
                    "code": "script.memory",
                    "message": format!(
                        "the script used more than {} MiB",
                        limits.memory >> 20
                    ),
                }))
            }
            Some(result) => result,
            None => Err(json!({
                "code": "script.unfinished",
                "message": "the script ended while it still awaited a promise that nothing resolves",
            })),
        }
    };
    outcome
}

fn take_logs(logs: &Rc<RefCell<(Vec<String>, usize, usize)>>) -> Outcome {
    let mut logs = logs.borrow_mut();
    Outcome { result: Ok(Value::Null), logs: std::mem::take(&mut logs.0), dropped_logs: logs.1 }
}

fn failure(code: &str, message: &str) -> String {
    json!({"ok": false, "message": message, "error": {"error": {"code": code, "message": message}, "state": "not_run"}})
        .to_string()
}

fn closed() -> Value {
    json!({"ok": false, "message": "the server stopped", "error": {"state": "not_run"}})
}

/// Images a script's calls returned that one `cmux_exec` result carries
/// (a computer use screenshot, a `video_frames` call's frames), and their
/// total base64 bytes.
const MAX_IMAGES: usize = super::video_tools::MAX_FRAMES;
const MAX_IMAGE_BYTES: usize = 8 << 20;

/// A tool result as a script sees it. A result without structured content
/// (another server's tool) becomes its JSON text, or `{content}`; its
/// images move to `images`, for the `cmux_exec` result, and the script
/// sees `{type: "image", image: <index>}` in their place.
pub(super) fn script_answer(
    result: Result<Value, (i64, String)>,
    images: &mut Vec<Value>,
) -> Value {
    let result = result.map(|result| {
        if result.get("structuredContent").is_some() {
            return result;
        }
        let mut result = result;
        let failed = result["isError"] == true;
        result.set("structuredContent", from_content(&result["content"], images, failed));
        result
    });
    match result {
        Err((_, message)) => json!({
            "ok": false,
            "message": message,
            "error": {"error": {"code": "usage.invalid", "message": message}, "state": "not_run"},
        }),
        Ok(result) if result["isError"] == true => {
            let error = result["structuredContent"].clone();
            let message = error["error"]["message"]
                .as_str()
                .or_else(|| error["error"]["code"].as_str())
                .unwrap_or("the call failed")
                .to_owned();
            json!({"ok": false, "message": message, "error": error})
        }
        Ok(result) => json!({"ok": true, "value": result["structuredContent"]}),
    }
}

/// The value of an MCP `content` list: one text block that is JSON is that
/// JSON; anything else is `{content}` with images moved to `images`. An
/// error result's text is its `error.message`.
fn from_content(content: &Value, images: &mut Vec<Value>, failed: bool) -> Value {
    let blocks = content.as_array().cloned().unwrap_or_default();
    if let [block] = blocks.as_slice()
        && !failed
        && block["type"] == "text"
        && let Some(value) = block["text"].as_str().and_then(|t| serde_json::from_str(t).ok())
    {
        return value;
    }
    let message =
        blocks.iter().find_map(|block| block["text"].as_str()).unwrap_or_default().to_owned();
    let used = |images: &Vec<Value>| -> usize {
        images.iter().map(|image| image["data"].as_str().map_or(0, str::len)).sum()
    };
    let blocks = blocks
        .into_iter()
        .map(|block| {
            if block["type"] != "image" {
                return block;
            }
            let size = block["data"].as_str().map_or(0, str::len);
            if images.len() >= MAX_IMAGES || used(images) + size > MAX_IMAGE_BYTES {
                return json!({"type": "image", "dropped": true, "mimeType": block["mimeType"]});
            }
            images.push(block.clone());
            json!({"type": "image", "image": images.len() - 1, "mimeType": block["mimeType"]})
        })
        .collect::<Vec<_>>();
    if failed {
        return json!({"content": blocks, "error": {"message": message}});
    }
    json!({"content": blocks})
}

#[cfg(test)]
mod bg_steer_tests {
    use super::*;

    /// A chat whose tools include acpmux's `bg_start` is told in `cmux_exec`'s own description
    /// to run long commands there; one without it is not (acpmux docs/hibernation.md).
    #[test]
    fn the_exec_description_steers_long_commands_to_bg_start_only_where_it_is() {
        let with = descriptors(&[json!({"name": BG_START}), json!({"name": "pane_split"})]);
        let text = with[0]["description"].as_str().unwrap();
        assert!(text.contains("cmux.acpmux_bg_start({command, cwd})"), "{text}");
        assert!(text.contains("hibernates after 2 idle minutes"), "{text}");
        let without = descriptors(&[json!({"name": "pane_split"})]);
        assert!(!without[0]["description"].as_str().unwrap().contains("acpmux_bg_start"));
    }
}

#[cfg(test)]
mod block_end_tests {
    use super::*;

    /// Braces inside strings, template literals and comments are skipped; a block that never
    /// closes, or a string, escape or comment cut off at the end, is `None`, not a panic.
    #[test]
    fn block_end_skips_quoted_and_commented_braces_and_stops_at_the_end() {
        let script = "{ \"}\" '}' `}` /* } */ // }\n }";
        assert_eq!(block_end(script, 0), Some(script.len() - 1));
        for cut in ["{ \"open", "{ 'a\\", "{ /* never closed", "{ // to the end", "{ {", "{ /"] {
            assert_eq!(block_end(cut, 0), None, "{cut:?}");
        }
    }

    /// Only the descriptor's own reads change: a cmux tool keeps its required list,
    /// read-only and destructive hints in the compact form.
    #[test]
    fn compact_keeps_required_and_hints() {
        let tool = json!({
            "name": "pane_close",
            "description": "Close a pane (cmux.protocol/2 `pane.close`).",
            "inputSchema": {"type": "object", "properties": {"pane": {"type": "string"}}, "required": ["pane"]},
            "annotations": {"readOnlyHint": false, "destructiveHint": true},
        });
        let out = compact(&tool);
        assert_eq!(out["inputSchema"]["required"], json!(["pane"]));
        assert_eq!(out.get("destructive"), Some(&json!(true)));
        assert_eq!(out.get("readOnly"), None);
    }
}
