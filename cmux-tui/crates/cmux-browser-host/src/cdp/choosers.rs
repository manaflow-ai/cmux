//! Uploads and file choosers on headless Chromium (driver-protocol.md
//! "Files, dialogs, popups, downloads"). A browser the driver owns has no
//! person to show an Open panel to, so every page intercepts its choosers
//! (`Page.setInterceptFileChooserDialog`): `Page.fileChooserOpened` becomes
//! `filechooser.opened` with the input's agent handle, and
//! `filechooser.respond` answers it. Files go in as the protocol says: the
//! agent world builds them with `DataTransfer`, assigns them to the input
//! and dispatches `input` and `change` (no file on disk); a cancel
//! dispatches the browser's `cancel` event.

use super::driver::{INTERNAL_TIMEOUT, Inner, Session};
use super::evaluate::{Context, evaluation_error, handle_group};
use super::state::{Applied, FollowUp, State, World};
use crate::protocol::{DriverError, DriverEvent, ErrorCode, required_str, timeout_of};
use serde_json::{Map, Value, json};
use std::time::{Duration, Instant};

/// How long an input call waits for the events of the choosers it opened.
const CHOOSER_EVENT_WAIT: Duration = Duration::from_secs(5);

/// The longest the renderer round trip after an input may take.
const SETTLE_WAIT: Duration = Duration::from_millis(500);

/// Inputs that can open a file chooser: a button release (a click) and
/// the keys that activate a focused input or button.
fn may_open_chooser(method: &str, params: &Value) -> bool {
    match method {
        "input.mouse" => params.get("type").and_then(Value::as_str) == Some("up"),
        "input.key" => matches!(params.get("key").and_then(Value::as_str), Some("Enter" | " ")),
        _ => false,
    }
}

/// `this` is a file input; `files` are `{ name, mimeType, base64 }`.
const ASSIGN_FILES: &str = "function (files) {\
  const transfer = new DataTransfer();\
  for (const f of files || []) {\
    const bin = atob(f.base64 || '');\
    const bytes = new Uint8Array(bin.length);\
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);\
    transfer.items.add(new File([bytes], f.name, { type: f.mimeType || '' }));\
  }\
  this.files = transfer.files;\
  this.dispatchEvent(new Event('input', { bubbles: true, composed: true }));\
  this.dispatchEvent(new Event('change', { bubbles: true }));\
}";

/// What a browser sends when a person cancels the Open panel.
const CANCEL: &str = "function () { this.dispatchEvent(new Event('cancel', { bubbles: true })); }";

/// The input's handle in the page agent of its world.
const HANDLE_OF: &str = "function () {\
  const agent = globalThis.__cmuxPageAgent;\
  return agent && agent.handleFor ? agent.handleFor(this) : null;\
}";

#[derive(Debug, Clone, PartialEq)]
pub struct Chooser {
    pub target: String,
    pub frame_id: String,
    /// The file input that opened it.
    pub backend: i64,
    pub multiple: bool,
}

impl State {
    /// `Page.fileChooserOpened`: record it (replacing the tab's older one)
    /// and ask for its event.
    pub(super) fn chooser_opened(
        &mut self,
        target_id: &str,
        _session_id: &str,
        params: &Value,
        applied: &mut Applied,
    ) {
        // A chooser without an input (none today) cannot be answered.
        let Some(backend) = params.get("backendNodeId").and_then(Value::as_i64) else {
            return;
        };
        let Some(tab) = self.tabs.get_mut(target_id) else {
            return;
        };
        tab.pending_choosers += 1;
        self.choosers.retain(|_, chooser| chooser.target != target_id);
        self.next_chooser += 1;
        let chooser_id = format!("c{}", self.next_chooser);
        self.choosers.insert(
            chooser_id.clone(),
            Chooser {
                target: target_id.to_owned(),
                frame_id: params.get("frameId").and_then(Value::as_str).unwrap_or("").to_owned(),
                backend,
                multiple: params.get("mode").and_then(Value::as_str) == Some("selectMultiple"),
            },
        );
        applied
            .follow_ups
            .push(FollowUp::ChooserOpened { target_id: target_id.to_owned(), chooser_id });
    }
}

impl Inner {
    /// `input.setFiles { targetId, frameId, element, files }`.
    pub(super) fn set_files(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let frame_id = self.frame_or_main(&session, params)?;
        let element = required_str(params, "element")?;
        let files = params.get("files").cloned().unwrap_or_else(|| json!([]));
        let agent = self.context(&session, &frame_id, World::Agent, deadline)?;
        let group = handle_group();
        let result = self
            .handle_object(&agent, element, &group, deadline)
            .and_then(|object| self.call_on(&agent, &object, ASSIGN_FILES, vec![files], deadline));
        self.release_handles(&agent.session, &group);
        result.map(|_| Value::Null)
    }

    /// `filechooser.respond { targetId, chooserId, files }` or `{ ..., cancel: true }`.
    pub(super) fn chooser_respond(&self, params: &Value) -> Result<Value, DriverError> {
        let chooser_id = required_str(params, "chooserId")?;
        let target = params.get("targetId").and_then(Value::as_str);
        let chooser = {
            let mut state = self.lock();
            let known = state
                .choosers
                .get(chooser_id)
                .is_some_and(|chooser| target.is_none_or(|t| t == chooser.target));
            known.then(|| state.choosers.remove(chooser_id)).flatten()
        }
        .ok_or_else(|| DriverError::not_found(format!("File chooser {chooser_id} is gone")))?;
        let deadline = Instant::now() + timeout_of(params);
        let cancel = params.get("cancel").and_then(Value::as_bool).unwrap_or(false);
        let (function, args) = if cancel {
            (CANCEL, vec![])
        } else {
            (ASSIGN_FILES, vec![params.get("files").cloned().unwrap_or_else(|| json!([]))])
        };
        self.on_chooser_input(&chooser, deadline, |agent, object| {
            self.call_on(agent, object, function, args, deadline)
        })
        .map(|_| Value::Null)
    }

    /// The follow-up of `Page.fileChooserOpened`: the event with the input's
    /// agent handle (null when the input is already gone), unless the
    /// chooser was answered or replaced meanwhile.
    pub(super) fn send_chooser_opened(&self, target_id: &str, chooser_id: &str) {
        let chooser = self.lock().choosers.get(chooser_id).cloned();
        if let Some(chooser) = chooser {
            let deadline = Instant::now() + INTERNAL_TIMEOUT;
            let element = self
                .on_chooser_input(&chooser, deadline, |agent, object| {
                    self.call_on(agent, object, HANDLE_OF, vec![], deadline)
                })
                .unwrap_or(Value::Null);
            let main = self.lock().tabs.get(target_id).and_then(|tab| tab.main_frame.clone());
            let frame = if main.as_deref() == Some(chooser.frame_id.as_str()) {
                Value::Null
            } else {
                json!(chooser.frame_id)
            };
            let mut payload = Map::new();
            payload.insert("targetId".into(), json!(target_id));
            payload.insert("chooserId".into(), json!(chooser_id));
            payload.insert("frameId".into(), frame);
            payload.insert("element".into(), element);
            payload.insert("multiple".into(), json!(chooser.multiple));
            if self.lock().choosers.contains_key(chooser_id) {
                self.emit(DriverEvent {
                    name: "filechooser.opened".into(),
                    payload: Value::Object(payload),
                });
            }
        }
        if let Some(tab) = self.lock().tabs.get_mut(target_id) {
            tab.pending_choosers = tab.pending_choosers.saturating_sub(1);
        }
        self.changed.notify_all();
    }

    /// Runs an input call; when it opened a file chooser, the chooser's
    /// event goes to the sink before the call's reply, so it reaches the
    /// session whose call opened it (a page with no listener holds it).
    pub(super) fn with_chooser_events(
        &self,
        method: &str,
        params: &Value,
        call: impl FnOnce() -> Result<Value, DriverError>,
    ) -> Result<Value, DriverError> {
        let before = self.lock().next_chooser;
        let reply = call();
        if self.owns_browser
            && self.lock().next_chooser == before
            && may_open_chooser(method, params)
        {
            self.settle_renderer(params);
        }
        if self.lock().next_chooser == before {
            return reply;
        }
        let deadline = Instant::now() + CHOOSER_EVENT_WAIT;
        if let Some(target) = params.get("targetId").and_then(Value::as_str) {
            let _ = self.wait_for(target, deadline, "file chooser events", |tab| {
                (tab.pending_choosers == 0).then_some(Ok(()))
            });
        }
        self.flush_events(deadline.saturating_duration_since(Instant::now()));
        reply
    }

    /// Chromium can send `Page.fileChooserOpened` after the reply of the
    /// input that opened it (two IPC routes). One script round trip to the
    /// page's renderer, sent after the input, comes back after the chooser
    /// request the input made. Skipped while a dialog holds the page (no
    /// script runs then); bounded.
    fn settle_renderer(&self, params: &Value) {
        let Ok(session) = self.session(params) else {
            return;
        };
        let dialog =
            self.lock().tabs.get(&session.target_id).is_some_and(|tab| tab.open_dialogs > 0);
        if !dialog {
            let _ = self.conn.call(
                Some(&session.session_id),
                "Runtime.evaluate",
                json!({"expression": "0", "returnByValue": true}),
                SETTLE_WAIT,
            );
        }
    }

    /// Runs `f` on the chooser's input in its frame's agent world.
    fn on_chooser_input(
        &self,
        chooser: &Chooser,
        deadline: Instant,
        f: impl FnOnce(&Context, &str) -> Result<Value, DriverError>,
    ) -> Result<Value, DriverError> {
        let page_session = self
            .lock()
            .tabs
            .get(&chooser.target)
            .map(|tab| tab.session_id.clone())
            .ok_or_else(|| DriverError::closed(format!("Tab {} closed", chooser.target)))?;
        let session = Session { target_id: chooser.target.clone(), session_id: page_session };
        let agent = self.context(&session, &chooser.frame_id, World::Agent, deadline)?;
        let group = handle_group();
        let result = self
            .send_on(
                &agent.session,
                "DOM.resolveNode",
                json!({"backendNodeId": chooser.backend, "executionContextId": agent.id, "objectGroup": group}),
                deadline,
            )
            .and_then(|resolved| {
                let object = resolved["object"]["objectId"].as_str().ok_or_else(|| {
                    DriverError::new(ErrorCode::Stale, "The file chooser's input is gone")
                })?;
                f(&agent, object)
            });
        self.release_handles(&agent.session, &group);
        result
    }

    /// `Runtime.callFunctionOn` on `object` with `args`, by value.
    fn call_on(
        &self,
        context: &Context,
        object: &str,
        function: &str,
        args: Vec<Value>,
        deadline: Instant,
    ) -> Result<Value, DriverError> {
        let arguments: Vec<Value> = args.into_iter().map(|value| json!({"value": value})).collect();
        let reply = self.send_on(
            &context.session,
            "Runtime.callFunctionOn",
            json!({"objectId": object, "functionDeclaration": function, "arguments": arguments, "returnByValue": true}),
            deadline,
        )?;
        if let Some(details) = reply.get("exceptionDetails") {
            return Err(evaluation_error(details));
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }
}

/// The CDP step that turns choosers into events, for a browser the driver
/// owns (headless: no person to show an Open panel to).
pub(super) fn intercept_step(intercept: bool) -> Option<(&'static str, Value)> {
    intercept.then(|| ("Page.setInterceptFileChooserDialog", json!({"enabled": true})))
}
