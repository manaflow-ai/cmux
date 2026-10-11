//! The per-tab virtual clipboard on a browser the driver owns
//! (driver-protocol.md `clipboard.read` / `clipboard.write`). Meta+C, Meta+X
//! and Meta+V never reach the browser's clipboard (the system's, or the X11
//! one of a headful browser on Xvfb): the driver runs the command itself in
//! the focused frame's host world. It sends the page a `copy`, `cut` or
//! `paste` event with a `DataTransfer` (untrusted, as the agent's paste is
//! by design) and does the default action: the selection's text to the
//! tab's clipboard, a cut's deletion (`execCommand("delete")`), a paste's
//! text through `Input.insertText` (trusted input). A key the page's
//! `keydown` handler prevented runs no command. While the command runs, a
//! JavaScript dialog is dismissed and reported with `dismissedDuring`; a
//! command the page has not finished within [`COMMAND_WAIT`] fails with
//! `timeout` and its late result is dropped (no clipboard outside the tab
//! can be written, so the tab's web content process is not ended).

use super::driver::Inner;
use super::state::World;
use crate::protocol::{DriverError, ErrorCode, timeout_of};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// How long the page may take for one Copy, Cut or Paste.
pub const COMMAND_WAIT: Duration = Duration::from_secs(5);

/// The most bytes (base64) one tab's clipboard holds.
const MAX_CLIPBOARD_BYTES: usize = 32 << 20;

/// Records the next `keydown` (its `defaultPrevented` is read after it).
const RECORD_KEY: &str = "() => { globalThis.__cmuxClipboardKey = null; \
  addEventListener('keydown', (e) => { globalThis.__cmuxClipboardKey = e; }, { capture: true, once: true }); }";

/// Runs `kind` ("copy" | "cut" | "paste") unless the recorded keydown was
/// prevented. Copy and Cut return `{ entries: [[type, text]] }`, Paste
/// `{ insert: text | null }`; `null` when the page prevented the key.
const RUN_COMMAND: &str = "(kind, items) => {\
  const key = globalThis.__cmuxClipboardKey; globalThis.__cmuxClipboardKey = null;\
  if (key && key.defaultPrevented) return null;\
  const doc = document; const active = doc.activeElement;\
  const field = active && (active.tagName === 'INPUT' || active.tagName === 'TEXTAREA') && typeof active.selectionStart === 'number';\
  const selection = getSelection();\
  const anchor = selection && selection.anchorNode;\
  const target = field ? active : anchor ? (anchor.nodeType === 1 ? anchor : anchor.parentElement) : (active || doc.body || doc.documentElement);\
  const data = new DataTransfer();\
  if (kind === 'paste') {\
    for (const item of items) {\
      const bin = atob(item.base64); const bytes = new Uint8Array(bin.length);\
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);\
      if (/^text\\//.test(item.type)) data.setData(item.type, new TextDecoder().decode(bytes));\
      else data.items.add(new File([bytes], 'clipboard', { type: item.type }));\
    }\
  }\
  const event = new ClipboardEvent(kind, { bubbles: true, cancelable: true, composed: true, clipboardData: data });\
  const cancelled = !(target || doc).dispatchEvent(event);\
  if (kind === 'paste') return { insert: cancelled ? null : data.getData('text/plain') || null };\
  if (cancelled) return { entries: Array.from(data.types).filter((t) => t !== 'Files').map((t) => [t, data.getData(t)]) };\
  const text = field ? String(active.value).slice(active.selectionStart, active.selectionEnd) : String(selection || '');\
  if (kind === 'cut' && text) doc.execCommand('delete', false, '');\
  return { entries: text ? [['text/plain', text]] : [] };\
}";

/// The command of a Copy, Cut or Paste shortcut (Meta+C, Meta+X, Meta+V
/// key down), else None.
pub fn shortcut(method: &str, params: &Value) -> Option<&'static str> {
    if method != "input.key" || params.get("type").and_then(Value::as_str) != Some("down") {
        return None;
    }
    let meta = params
        .get("modifiers")
        .and_then(Value::as_array)
        .is_some_and(|mods| mods.iter().any(|m| m.as_str() == Some("Meta")));
    if !meta {
        return None;
    }
    let code = params.get("code").and_then(Value::as_str).unwrap_or("");
    let key = params.get("key").and_then(Value::as_str).unwrap_or("").to_ascii_lowercase();
    match (code, key.as_str()) {
        ("KeyC", _) | ("", "c") => Some("copy"),
        ("KeyX", _) | ("", "x") => Some("cut"),
        ("KeyV", _) | ("", "v") => Some("paste"),
        _ => None,
    }
}

impl Inner {
    /// `clipboard.read { targetId }` -> `{ items: [{ type, base64 }] }`.
    pub(super) fn clipboard_read(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let items = self
            .lock()
            .tabs
            .get(&session.target_id)
            .map(|tab| tab.clipboard.clone())
            .unwrap_or_default();
        Ok(json!({"items": items}))
    }

    /// `clipboard.write { targetId, items: [{ type, base64 }] }`.
    pub(super) fn clipboard_write(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let items = clipboard_items(params.get("items"))?;
        self.set_clipboard(&session.target_id, items);
        Ok(Value::Null)
    }

    fn set_clipboard(&self, target: &str, items: Vec<Value>) {
        if let Some(tab) = self.lock().tabs.get_mut(target) {
            tab.clipboard = items;
        }
    }

    /// `input.key` down of a Copy, Cut or Paste shortcut: the key goes to
    /// the page, then the command runs against the tab's clipboard.
    pub(super) fn clipboard_key(
        &self,
        kind: &'static str,
        params: &Value,
    ) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let focused = self.focused_frame(params)?;
        let frame_id = match focused.get("frameId").and_then(Value::as_str) {
            Some(frame) => frame.to_owned(),
            None => self.frame_or_main(&session, params)?,
        };
        let host = self.context(&session, &frame_id, World::Host, deadline)?;
        self.call_in_context(&host.session, host.id, RECORD_KEY, json!([]), deadline)?;
        self.key(params)?;
        let items = match kind {
            "paste" => self
                .lock()
                .tabs
                .get(&session.target_id)
                .map(|tab| tab.clipboard.clone())
                .unwrap_or_default(),
            _ => Vec::new(),
        };
        if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
            tab.clipboard_command = Some(kind);
        }
        let result = self.call_in_context(
            &host.session,
            host.id,
            RUN_COMMAND,
            json!([kind, items]),
            Instant::now() + COMMAND_WAIT,
        );
        if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
            tab.clipboard_command = None;
        }
        let result = result.map_err(|error| {
            if error.code == ErrorCode::Timeout {
                DriverError::timeout(format!(
                    "{kind}: the page did not finish its {kind} handler within 5 s; the tab's clipboard is unchanged"
                ))
            } else {
                error
            }
        })?;
        if result.is_null() {
            return Ok(Value::Null);
        }
        if kind == "paste" {
            if let Some(text) = result["insert"].as_str() {
                self.send_until(&session, "Input.insertText", json!({"text": text}), deadline)?;
            }
            return Ok(Value::Null);
        }
        let items: Vec<Value> = result["entries"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|entry| {
                let kind = entry.get(0)?.as_str()?;
                let text = entry.get(1)?.as_str()?;
                Some(json!({"type": kind, "base64": crate::fs_sandbox::base64_encode(text.as_bytes())}))
            })
            .collect();
        // A command that put nothing there leaves the clipboard as it was.
        if !items.is_empty() {
            self.set_clipboard(&session.target_id, items);
        }
        Ok(Value::Null)
    }

    /// `function(...args)` in a context, by value, with `args` (an array).
    fn call_in_context(
        &self,
        session_id: &str,
        context: i64,
        function: &str,
        args: Value,
        deadline: Instant,
    ) -> Result<Value, DriverError> {
        let arguments: Vec<Value> =
            args.as_array().into_iter().flatten().map(|value| json!({"value": value})).collect();
        let reply = self.send_on(
            session_id,
            "Runtime.callFunctionOn",
            json!({"functionDeclaration": function, "executionContextId": context,
                "arguments": arguments, "returnByValue": true}),
            deadline,
        )?;
        if let Some(details) = reply.get("exceptionDetails") {
            return Err(super::evaluate::evaluation_error(details));
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }
}

/// The binding the page clipboard guard posts through (page world).
pub(super) const GUARD_BINDING: &str = "__cmuxPageClipboard";

/// js/page-clipboard.js, called with a `post` that hands `{ items }` to the
/// binding (taken off the page's global before any page script runs).
static GUARD_SOURCE: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| {
    format!(
        "(() => {{ const g = globalThis; const send = g.{GUARD_BINDING}; if (typeof send !== 'function') return; \
         try {{ delete g.{GUARD_BINDING}; }} catch {{}} \
         ({})((payload) => {{ send(JSON.stringify(payload)); return Promise.resolve(); }}); }})();",
        include_str!("../../js/page-clipboard.js").trim().trim_end_matches(';')
    )
});

impl Inner {
    /// Page clipboard guard (driver-protocol.md "Guards"): in every
    /// document of a browser the driver owns, before the page's scripts,
    /// `navigator.clipboard` and `execCommand("copy" | "cut")` write the
    /// tab's clipboard (through [`GUARD_BINDING`]), never the browser's.
    pub(super) fn guard_steps(&self, enabled: bool) -> Vec<(&'static str, Value)> {
        if !enabled || !self.owns_browser {
            return Vec::new();
        }
        vec![
            ("Runtime.addBinding", json!({"name": GUARD_BINDING})),
            (
                "Page.addScriptToEvaluateOnNewDocument",
                json!({"source": &*GUARD_SOURCE, "runImmediately": true}),
            ),
        ]
    }
}

/// The browser refuses page script the clipboard permissions (async
/// Clipboard API reads and writes, sanitized or not) in every origin of a
/// store: the guard's second line, also for a document the guard missed
/// and for isolated worlds.
pub(super) fn deny_clipboard_permissions(
    conn: &super::CdpConnection,
    context: Option<&str>,
) -> Result<(), DriverError> {
    for permission in [
        json!({"name": "clipboard-read"}),
        json!({"name": "clipboard-write"}),
        json!({"name": "clipboard-write", "allowWithoutSanitization": true}),
    ] {
        let mut params = json!({"permission": permission, "setting": "denied"});
        if let Some(context) = context {
            params["browserContextId"] = json!(context);
        }
        conn.call(None, "Browser.setPermission", params, super::driver::INTERNAL_TIMEOUT)?;
    }
    Ok(())
}

/// Raw `cdp` may not run the browser's own clipboard commands (an
/// `Input.dispatchKeyEvent` with `copy`, `cut` or `paste` editing
/// commands would read or write the browser's clipboard).
pub(super) fn raw_refusal(method: &str, params: &Value) -> Option<DriverError> {
    if method != "Input.dispatchKeyEvent" {
        return None;
    }
    let clipboard = params.get("commands").and_then(Value::as_array).is_some_and(|commands| {
        commands.iter().filter_map(Value::as_str).any(|command| {
            let command = command.to_ascii_lowercase();
            ["copy", "cut", "paste"].iter().any(|word| command.contains(word))
        })
    });
    clipboard.then(|| {
        DriverError::new(
            ErrorCode::Forbidden,
            "Input.dispatchKeyEvent: clipboard commands are not available to sessions; use clipboard.read/write and Meta+C/X/V",
        )
    })
}

/// Checks `[{ type, base64 }]` (bounded in size).
pub(super) fn clipboard_items(items: Option<&Value>) -> Result<Vec<Value>, DriverError> {
    let list = items
        .and_then(Value::as_array)
        .ok_or_else(|| DriverError::invalid("clipboard.write: items must be an array"))?;
    let mut size = 0;
    let mut out = Vec::with_capacity(list.len());
    for item in list {
        let kind = item.get("type").and_then(Value::as_str);
        let data = item.get("base64").and_then(Value::as_str);
        let (Some(kind), Some(data)) = (kind, data) else {
            return Err(DriverError::invalid(
                "clipboard.write: every item needs a type and base64",
            ));
        };
        size += data.len();
        if size > MAX_CLIPBOARD_BYTES {
            return Err(DriverError::invalid("clipboard.write: the items are larger than 32 MiB"));
        }
        out.push(json!({"type": kind, "base64": data}));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_meta_c_x_v_key_downs_are_shortcuts() {
        let key = |kind: &str, key: &str, code: &str, mods: Value| json!({"type": kind, "key": key, "code": code, "modifiers": mods});
        assert_eq!(shortcut("input.key", &key("down", "c", "KeyC", json!(["Meta"]))), Some("copy"));
        assert_eq!(
            shortcut("input.key", &key("down", "X", "", json!(["Meta", "Shift"]))),
            Some("cut")
        );
        assert_eq!(
            shortcut("input.key", &key("down", "v", "KeyV", json!(["Meta"]))),
            Some("paste")
        );
        assert_eq!(shortcut("input.key", &key("up", "c", "KeyC", json!(["Meta"]))), None);
        assert_eq!(shortcut("input.key", &key("down", "c", "KeyC", json!(["Control"]))), None);
        assert_eq!(shortcut("input.mouse", &key("down", "c", "KeyC", json!(["Meta"]))), None);
    }

    #[test]
    fn clipboard_items_need_a_type_and_data() {
        assert!(clipboard_items(Some(&json!([{"type": "text/plain", "base64": "YQ=="}]))).is_ok());
        assert!(clipboard_items(Some(&json!([{"type": "text/plain"}]))).is_err());
        assert!(clipboard_items(None).is_err());
    }
}
