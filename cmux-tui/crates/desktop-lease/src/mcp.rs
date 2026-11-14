//! `desktop-lease mcp`: the stdio MCP server a session gets (acpmux names it
//! `cmux-desktop`, opt-in). Every computer-use call goes through the pool:
//! `desktop_lease` takes a slot, the action tools resume it, act, screenshot
//! and let the pool suspend it while the model thinks, `desktop_release`
//! gives it back. When the session ends (stdin closes) its slots are released.
//!
//! The action names and arguments follow the cmux computer-use driver
//! (`click` x/y, `type_text`, `press_key` with xdotool key strings, `scroll`,
//! `screenshot`), prefixed `desktop_` so they never collide with `cmux-cua`.

use crate::at;
use crate::server::Client;
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::io::{BufRead, Write};
use std::path::Path;

pub const SERVER_NAME: &str = "cmux-desktop";
/// The lease owner: acpmux sets it to the session id.
pub const OWNER_ENV: &str = "DESKTOP_LEASE_OWNER";

const INSTRUCTIONS: &str = "Computer use on a leased desktop (a Linux desktop with a browser). \
Call desktop_lease once, then act with desktop_click / desktop_type_text / desktop_press_key / \
desktop_scroll / desktop_open_url / desktop_screenshot on its slot; each answers with a screenshot. \
The desktop is suspended between your calls and resumed on the next one, so take your time \
thinking. Call desktop_release when done.";

fn slot_prop() -> Value {
    json!({"type": "string", "description": "The slot id desktop_lease returned."})
}

pub fn tools() -> Value {
    let xy = |extra: Value| {
        let mut props = json!({
            "slot": slot_prop(),
            "x": {"type": "integer", "description": "Pixels from the screenshot's left edge."},
            "y": {"type": "integer", "description": "Pixels from the screenshot's top edge."},
        });
        if let (Some(p), Some(e)) = (props.as_object_mut(), extra.as_object()) {
            p.extend(e.clone());
        }
        props
    };
    json!([
        {"name": "desktop_lease", "description": "Lease a desktop slot (pre-warmed; about a millisecond). Returns its slot id.",
         "inputSchema": {"type": "object", "properties": {
            "backend": {"type": "string", "description": "linux-xvfb (default)."},
            "width": {"type": "integer"}, "height": {"type": "integer"},
            "url": {"type": "string", "description": "The page a fresh, non-default slot opens."}}}},
        {"name": "desktop_screenshot", "description": "Screenshot of the slot's screen.",
         "inputSchema": {"type": "object", "properties": {"slot": slot_prop()}, "required": ["slot"]}},
        {"name": "desktop_click", "description": "Click at pixel x,y; then a screenshot.",
         "inputSchema": {"type": "object", "properties": xy(json!({
            "button": {"type": "integer", "description": "1 left (default), 2 middle, 3 right."},
            "count": {"type": "integer", "description": "2 for a double click."}})),
            "required": ["slot", "x", "y"]}},
        {"name": "desktop_type_text", "description": "Type text into the focused field; then a screenshot.",
         "inputSchema": {"type": "object", "properties": {"slot": slot_prop(), "text": {"type": "string"}},
            "required": ["slot", "text"]}},
        {"name": "desktop_press_key", "description": "Press a key or chord in xdotool form (Return, ctrl+l, super+l); then a screenshot.",
         "inputSchema": {"type": "object", "properties": {"slot": slot_prop(), "key": {"type": "string"}},
            "required": ["slot", "key"]}},
        {"name": "desktop_scroll", "description": "Scroll at x,y; then a screenshot.",
         "inputSchema": {"type": "object", "properties": xy(json!({
            "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
            "amount": {"type": "integer", "description": "Wheel clicks (default 3)."}})),
            "required": ["slot", "x", "y", "direction"]}},
        {"name": "desktop_open_url", "description": "Open a URL in the slot's browser; then a screenshot.",
         "inputSchema": {"type": "object", "properties": {"slot": slot_prop(), "url": {"type": "string"},
            "wait_ms": {"type": "integer", "description": "Let the page load before the screenshot (default 1500)."}},
            "required": ["slot", "url"]}},
        {"name": "desktop_release", "description": "Give the slot back; its desktop is destroyed.",
         "inputSchema": {"type": "object", "properties": {"slot": slot_prop()}, "required": ["slot"]}}
    ])
}

/// The pool action for a tool call, or `None` for lease/release.
pub fn action_for(name: &str, args: &Value) -> Option<Value> {
    let mut a = args.clone();
    let obj = a.as_object_mut()?;
    obj.remove("slot");
    let kind = match name {
        "desktop_screenshot" => "screenshot",
        "desktop_click" => "click",
        "desktop_type_text" => "type_text",
        "desktop_press_key" => "press_key",
        "desktop_scroll" => "scroll",
        "desktop_open_url" => "open_url",
        _ => return None,
    };
    obj.insert("type".into(), json!(kind));
    Some(a)
}

struct Server {
    client: Option<Client>,
    socket: std::path::PathBuf,
    owner: String,
    leased: BTreeSet<String>,
}

impl Server {
    fn pool(&mut self) -> Result<&mut Client> {
        if self.client.is_none() {
            self.client = Some(Client::connect(&self.socket)?);
        }
        self.client.as_mut().ok_or_else(|| anyhow::anyhow!("no desktop pool connection"))
    }

    fn call_tool(&mut self, name: &str, args: &Value) -> Result<Value> {
        let owner = self.owner.clone();
        let slot = at(args, "/slot").as_str().unwrap_or_default().to_owned();
        match name {
            "desktop_lease" => {
                let mut spec = args.clone();
                if spec.is_null() {
                    spec = json!({});
                }
                let v = self.pool()?.call(&json!({"op": "lease", "owner": owner, "spec": spec}))?;
                if let Some(id) = at(&v, "/lease/slot").as_str() {
                    self.leased.insert(id.to_owned());
                }
                Ok(text_result(at(&v, "/lease")))
            }
            "desktop_release" => {
                self.pool()?.call(&json!({"op": "release", "owner": owner, "slot": slot}))?;
                self.leased.remove(&slot);
                Ok(text_result(&json!({"released": slot})))
            }
            _ => {
                let action =
                    action_for(name, args).ok_or_else(|| anyhow::anyhow!("unknown tool {name}"))?;
                let v = self
                    .pool()?
                    .call(&json!({"op": "act", "owner": owner, "slot": slot, "action": action}))?;
                Ok(json!({
                    "content": [
                        {"type": "text", "text": at(&v, "/report").to_string()},
                        {"type": "image", "data": at(&v, "/png_b64"), "mimeType": "image/png"}
                    ],
                    "isError": false
                }))
            }
        }
    }
}

fn text_result(v: &Value) -> Value {
    json!({"content": [{"type": "text", "text": v.to_string()}], "isError": false})
}

fn error_result(e: &anyhow::Error) -> Value {
    json!({"content": [{"type": "text", "text": format!("{e:#}")}], "isError": true})
}

pub fn run(socket: &Path) -> Result<()> {
    let owner = std::env::var(OWNER_ENV)
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("mcp-{}", std::process::id()));
    let mut server =
        Server { client: None, socket: socket.to_path_buf(), owner, leased: BTreeSet::new() };
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line?;
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = msg.get("id").cloned() else { continue }; // a notification
        let method = at(&msg, "/method").as_str().unwrap_or_default();
        let result = match method {
            "initialize" => json!({
                "protocolVersion": at(&msg, "/params/protocolVersion").as_str().unwrap_or("2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION")},
                "instructions": INSTRUCTIONS,
            }),
            "ping" => json!({}),
            "tools/list" => json!({"tools": tools()}),
            "tools/call" => {
                let name = at(&msg, "/params/name").as_str().unwrap_or_default().to_owned();
                let args = at(&msg, "/params/arguments").clone();
                server.call_tool(&name, &args).unwrap_or_else(|e| error_result(&e))
            }
            _ => {
                let err = json!({"code": -32601, "message": format!("no method {method}")});
                writeln!(stdout, "{}", json!({"jsonrpc": "2.0", "id": id, "error": err}))?;
                stdout.flush()?;
                continue;
            }
        };
        writeln!(stdout, "{}", json!({"jsonrpc": "2.0", "id": id, "result": result}))?;
        stdout.flush()?;
    }
    // The session ended: its slots go back.
    let owner = server.owner.clone();
    if !server.leased.is_empty()
        && let Ok(client) = server.pool()
    {
        let _ = client.call(&json!({"op": "release_owner", "owner": owner}));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
