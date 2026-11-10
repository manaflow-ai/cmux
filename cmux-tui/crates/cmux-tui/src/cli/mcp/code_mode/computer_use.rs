//! cmux Computer Use in code mode: the `cu_*` tools of the folded
//! `cmux-computer-use` server (`upstream.rs`) as one scripted family. A
//! `cmux_exec` script chains them (`await cu.click({...})`, the prelude's `cu`
//! namespace over `cmux.cu_*`), each call through `Server::call` like any tool,
//! so policy, approvals and the bridge's per-call `call_id` hold per step.
//! Here: what `cmux_exec` says about them, the script defaults (no settle
//! screenshot unless asked), `cmux.docs("cu")`, the images a script returns,
//! and the server that serves only Computer Use (a terminal agent while the
//! cmux tools are off, `TERMINAL_AGENT_ENV`).

use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

use super::{COMPUTER_USE_FAMILY, DOCS_MAX_LIMIT, EXEC, MAX_IMAGE_BYTES, MAX_IMAGES, compact};

/// `1` on the cmux server the `claude` and `codex` terminal shims give the agent
/// they start (`agent_computer_use.rs`). While the settings file keeps the cmux
/// tools off for clients outside cmux's chats, that server still serves cmux
/// Computer Use, which those agents always had: only the `cu_*` tools, in code
/// mode or listed. The env is no security boundary (the same process can run
/// `cmux computer-use call`), so it grants nothing that was not already there.
pub(in crate::cli::mcp) const TERMINAL_AGENT_ENV: &str = "CMUX_MCP_TERMINAL_AGENT";

/// What `cmux_exec` says when the chat has computer use.
pub(in crate::cli::mcp) const COMPUTER_USE_NOTE: &str = " It includes cmux Computer Use, built into cmux \
    (nothing to install; prefer it over any other computer-use driver): the cu_* tools see \
    and use the apps on this computer and on the person's other machines (`machine`, \
    list_machines), in the background, without taking their focus. Use them for any task in \
    a desktop app, never osascript, AppleScript or xdotool keystrokes; `cmux.docs(\"cu\")` \
    lists them with their rules and example scripts. Never type into a terminal or script tool, \
    never copy app data out of the app unless the person asked, and stop before a payment, a \
    password, sending a message or deleting that they did not ask for, and say what is left.";
/// The same for a client with its own Computer Use (Codex): cmux's is the
/// second choice (acpmux `computer_use::mcp::DEFER_INSTRUCTIONS`).
pub(in crate::cli::mcp) const COMPUTER_USE_DEFER_NOTE: &str = " It includes cmux Computer Use (the cu_* \
    tools), a second option: you have your own Computer Use, so use cu_* only when the person \
    asks for cmux Computer Use or names these tools, never by default; `cmux.docs(\"cu\")` \
    lists them with their rules and example scripts. Never type into a terminal or script tool, \
    never copy app data out of the app unless the person asked, and stop before a payment, a \
    password, sending a message or deleting that they did not ask for, and say what is left.";
/// How a script drives Computer Use, in `cmux_exec`'s description.
pub(in crate::cli::mcp) const COMPUTER_USE_SCRIPTING: &str = " Script Computer Use as one cmux_exec call: \
    `await cu.list_windows({app_id})`, `cu.get_ui_tree({window_id})`, `cu.click({window_id, \
    element_id})`, `cu.type_text`, `cu.press_key`, `cu.wait`, ... (cu.<tool> is \
    cmux.cu_<tool>), with loops and conditions between them. In a script an acting call skips \
    its after-action screenshot unless you pass observe: true. A result's images come back as \
    {type: \"image\", image: N} in its `images`; return the ones you want to see (a \
    cu.screenshot result, or r.images) and they reach you as images.";

/// The cu_* acting tools whose result carries the window after acting
/// (`cmux_computer_use::tools::OBSERVES`): inside a script they default to
/// `observe: false`, since a script checks with its own reads.
fn observing_cu_tool(name: &str) -> bool {
    name.strip_prefix(COMPUTER_USE_FAMILY)
        .and_then(|rest| rest.strip_prefix('_'))
        .is_some_and(|tool| acpmux::computer_use::tools::OBSERVES.contains(&tool))
}

/// A script's call with the script defaults: an acting cu_* call without
/// `observe` gets `observe: false` (no settle screenshot) unless asked.
pub(in crate::cli::mcp) fn script_arguments(name: &str, arguments: &mut Map<String, Value>) {
    if observing_cu_tool(name) && !arguments.contains_key("observe") {
        arguments.insert("observe".into(), Value::Bool(false));
    }
}

/// Whether the cu_* tools in `tools` are marked second choice (a Codex client).
fn deferred(tools: &[Value]) -> bool {
    tools.iter().any(|tool| {
        tool["name"].as_str().is_some_and(|name| name.starts_with("cu_"))
            && tool["description"]
                .as_str()
                .is_some_and(|text| text.contains(acpmux::computer_use::mcp::DEFER_PREFIX))
    })
}

/// `cmux_exec` for a server that serves only Computer Use (a Claude Code or
/// Codex typed into a cmux terminal while the cmux tools are off).
pub(in crate::cli::mcp) fn only_descriptor(tools: &[Value]) -> Value {
    let note = if deferred(tools) { COMPUTER_USE_DEFER_NOTE } else { COMPUTER_USE_NOTE };
    json!({
        "name": EXEC,
        "title": "Run a cmux Computer Use script",
        "description": format!(
            "Run JavaScript that calls cmux Computer Use and return its result.{note}\
             {COMPUTER_USE_SCRIPTING} An async function body; `return` a JSON value. No file \
             system, network or timers (use cu.wait); console.log comes back in logs. \
             `await cmux.docs(\"cu\")` answers the tools with their schemas, their rules and \
             example scripts. A failed call throws an Error whose `cmux` field has the error; \
             a refused call (computer_use_off, app_denied, look_only, person_in_control) is \
             final for that step: call cu.status and tell the person which setting in \
             Settings > Computer Use would allow it. Only Computer Use runs here: the other \
             cmux tools need cmux's MCP switch (cmux settings set mcp.enabled true)."
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
    })
}

/// The Computer Use part of `cmux_exec`'s description: none without the
/// `cu_*` tools, the second-choice note for a client with its own Computer Use.
pub(in crate::cli::mcp) fn exec_note(tools: &[Value], present: bool) -> String {
    match () {
        () if !present => String::new(),
        () if deferred(tools) => format!("{COMPUTER_USE_DEFER_NOTE}{COMPUTER_USE_SCRIPTING}"),
        () => format!("{COMPUTER_USE_NOTE}{COMPUTER_USE_SCRIPTING}"),
    }
}

/// `cmux.docs("cu")` (or "computer use"): the Computer Use tools, in catalog
/// order, with the guide's example scripts; `None` for another query or
/// without the tools. A search for the two letters matched every name with
/// "cu" in it (focus, cursor) before them.
pub(in crate::cli::mcp) fn family_docs(
    tools: &[Value],
    query: &str,
    limit: usize,
    arguments: &Map<String, Value>,
) -> Option<Value> {
    if query != COMPUTER_USE_FAMILY && query != "computer use" {
        return None;
    }
    let prefix = format!("{COMPUTER_USE_FAMILY}_");
    let family: Vec<&Value> = tools
        .iter()
        .filter(|tool| tool["name"].as_str().is_some_and(|name| name.starts_with(&prefix)))
        .collect();
    if family.is_empty() {
        return None;
    }
    // All of them unless the call set a limit (the family is under the maximum).
    let limit = if arguments.contains_key("limit") { limit } else { DOCS_MAX_LIMIT };
    let more: Vec<Value> = family.iter().skip(limit).map(|tool| tool["name"].clone()).collect();
    // Each tool's description carries its server's rules; the answer has them
    // once, in `servers` (`add_server_rules`).
    let shown: Vec<Value> = family
        .into_iter()
        .take(limit)
        .map(|tool| {
            let mut tool = compact(tool);
            let own = tool["description"].as_str().map(crate::cli::mcp::upstream::without_rules);
            if let Some(own) = own.map(str::to_owned) {
                tool.set("description", json!(own));
            }
            tool
        })
        .collect();
    let mut answer = json!({"query": query, "tools": shown, "more": more});
    let guides = crate::cli::docs::guides(COMPUTER_USE_FAMILY);
    if !guides.is_empty() {
        answer.set("guides", json!(guides));
    }
    Some(answer)
}

/// Whether `name` is one of cmux Computer Use's folded tools (`cu_click`).
pub(in crate::cli::mcp) fn is_tool(name: &str) -> bool {
    name.strip_prefix(COMPUTER_USE_FAMILY).is_some_and(|rest| rest.starts_with('_'))
}

/// Why a server that serves only Computer Use refuses `name`, or `None`.
pub(in crate::cli::mcp) fn out_of_scope(name: &str) -> Option<Value> {
    if is_tool(name) || name == EXEC || name == super::DOCS {
        return None;
    }
    Some(json!({
        "code": "tool.not_allowed",
        "message": format!(
            "{name} is a cmux tool beyond Computer Use; this agent has only cmux Computer Use \
             until the person turns on cmux's MCP tools (cmux settings set mcp.enabled true)"
        ),
        "details": {},
        "retryable": false,
    }))
}

/// `initialize` of a server that serves only cmux Computer Use: its rules (or,
/// for Codex, the rule that its own Computer Use comes first) and, in code mode,
/// how to script it.
pub(in crate::cli::mcp) fn initialize(params: &Value, defer: bool, code_mode: bool) -> Value {
    let rules = if defer {
        acpmux::computer_use::mcp::DEFER_INSTRUCTIONS
    } else {
        acpmux::computer_use::tools::INSTRUCTIONS
    };
    let how = if code_mode {
        " cmux Computer Use runs through cmux_exec scripts: `await cu.list_windows({})`, \
         `cu.click({window_id, element_id})` and the rest, several steps in one call; \
         `cmux.docs(\"cu\")` has the tools and example scripts."
    } else {
        ""
    };
    json!({
        "protocolVersion": acpmux::secret_mcp::protocol_version(params),
        "capabilities": {"tools": {"listChanged": false}},
        "serverInfo": {"name": "cmux", "title": "cmux", "version": env!("CARGO_PKG_VERSION")},
        "instructions": format!("{rules}{how}"),
    })
}

/// Whether `value` is an image placeholder a script saw (`{type: "image", image: N}`).
fn placeholder(value: &Value) -> Option<usize> {
    (value["type"] == "image")
        .then(|| value["image"].as_u64())
        .flatten()
        .and_then(|index| usize::try_from(index).ok())
}

/// Marks an image block a cu_* call returned, until the script's result is
/// built (never sent: [`returned_images`] removes it).
const FROM_COMPUTER_USE: &str = "_cmux_computer_use";

/// A script call's answer ([`super::script_answer`]), with the images a cu_*
/// call returned marked: those reach the agent only when the script returns
/// them, so a loop of `cu.wait` or acting calls never floods the result.
pub(in crate::cli::mcp) fn script_answer(
    name: &str,
    result: Result<Value, (i64, String)>,
    images: &mut Vec<Value>,
) -> Value {
    let before = images.len();
    let answer = super::script_answer(result, images);
    if is_tool(name) {
        for image in images.iter_mut().skip(before) {
            image.set(FROM_COMPUTER_USE, json!(true));
        }
    }
    answer
}

/// The images one `cmux_exec` result carries: the ones the script's `result`
/// returns (each placeholder in it, first seen first), else, when it returns
/// none, every image its calls got except Computer Use screenshots (as before
/// scripted Computer Use: a `video_frames` script that returns only text still
/// shows its frames). At most [`MAX_IMAGES`] and [`MAX_IMAGE_BYTES`]; returns
/// the images and how many were left out.
pub(in crate::cli::mcp) fn returned_images(
    result: Option<&Value>,
    images: Vec<Value>,
) -> (Vec<Value>, usize) {
    fn walk(value: &Value, found: &mut Vec<usize>, depth: usize) {
        if depth > 64 {
            return;
        }
        if let Some(index) = placeholder(value) {
            if !found.contains(&index) {
                found.push(index);
            }
            return;
        }
        match value {
            Value::Array(items) => items.iter().for_each(|item| walk(item, found, depth + 1)),
            Value::Object(fields) => fields.values().for_each(|item| walk(item, found, depth + 1)),
            _ => {}
        }
    }
    let mut picked = Vec::new();
    if let Some(result) = result {
        walk(result, &mut picked, 0);
    }
    picked.retain(|index| *index < images.len());
    let order: Vec<usize> = if picked.is_empty() {
        (0..images.len()).filter(|index| images[*index].get(FROM_COMPUTER_USE).is_none()).collect()
    } else {
        picked
    };
    let wanted = order.len();
    let mut out = Vec::new();
    let mut bytes = 0;
    let mut images: Vec<Option<Value>> = images.into_iter().map(Some).collect();
    for index in order {
        let Some(mut image) = images.get_mut(index).and_then(Option::take) else { continue };
        if let Some(fields) = image.as_object_mut() {
            fields.remove(FROM_COMPUTER_USE);
        }
        let size = image["data"].as_str().map_or(0, str::len);
        if out.len() >= MAX_IMAGES || bytes + size > MAX_IMAGE_BYTES {
            break;
        }
        bytes += size;
        out.push(image);
    }
    let left_out = wanted - out.len();
    (out, left_out)
}

/// Adds to a `cmux_exec` result the images its script returns (else every
/// image its calls got; [`returned_images`]), and how many were left out.
pub(in crate::cli::mcp) fn attach_images(result: &mut Value, images: Vec<Value>) {
    let (images, left_out) = returned_images(result.pointer("/structuredContent/result"), images);
    if left_out > 0
        && let Some(value) = result.get_mut("structuredContent")
        && value.is_object()
    {
        value.set("images_left_out", json!(left_out));
    }
    if let Some(content) = result["content"].as_array_mut() {
        content.extend(images);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(data: &str) -> Value {
        json!({"type": "image", "data": data, "mimeType": "image/png"})
    }

    /// A script's returned placeholders pick its images; with none returned,
    /// every image but Computer Use's screenshots comes back (a `video_frames`
    /// script that returns text still shows its frames), and the internal mark
    /// never leaves.
    #[test]
    fn the_images_a_script_returns_are_the_ones_sent() {
        let mut cu = image("Y3U=");
        cu.set(FROM_COMPUTER_USE, json!(true));
        let frames = vec![cu, image("ZnJhbWU=")];
        let (sent, left_out) = returned_images(Some(&json!("done")), frames.clone());
        assert_eq!((sent, left_out), (vec![image("ZnJhbWU=")], 0));
        let returned = json!({"shot": {"images": [{"type": "image", "image": 0}]}});
        let (sent, _) = returned_images(Some(&returned), frames.clone());
        assert_eq!(sent, vec![image("Y3U=")], "returned, and without the mark");
        let both = json!([{"type": "image", "image": 1}, {"type": "image", "image": 0},
                          {"type": "image", "image": 1}, {"type": "image", "image": 9}]);
        let (sent, _) = returned_images(Some(&both), frames);
        assert_eq!(sent, vec![image("ZnJhbWU="), image("Y3U=")], "first seen first, once");
        let many: Vec<Value> = (0..MAX_IMAGES + 3).map(|_| image("eA==")).collect();
        let (sent, left_out) = returned_images(None, many);
        assert_eq!((sent.len(), left_out), (MAX_IMAGES, 3));
    }

    /// In a script an acting cu_* call skips its settle screenshot unless it asks;
    /// a reading call and every other tool are left as they are.
    #[test]
    fn script_calls_default_acting_cu_tools_to_no_observation() {
        let defaulted = |name: &str, args: Value| {
            let mut args = args.as_object().cloned().unwrap();
            script_arguments(name, &mut args);
            Value::Object(args)
        };
        assert_eq!(defaulted("cu_click", json!({"x": 1})), json!({"x": 1, "observe": false}));
        assert_eq!(defaulted("cu_batch", json!({"observe": true})), json!({"observe": true}));
        for name in ["cu_screenshot", "cu_get_ui_tree", "cu_wait", "pane_split", "video_frames"] {
            assert_eq!(defaulted(name, json!({})), json!({}), "{name}");
        }
    }
}
