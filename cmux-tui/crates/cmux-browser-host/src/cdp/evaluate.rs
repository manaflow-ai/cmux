//! Frames, script evaluation in the page and agent worlds, and agent handles.

use super::driver::{Inner, Session};
use super::state::{AGENT_WORLD, HOST_WORLD, World, error_message};
use crate::protocol::{DriverError, ErrorCode, required_str, timeout_of};
use serde_json::value::RawValue;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// How long to wait for a world's context to be reported before creating it.
const CONTEXT_GRACE: Duration = Duration::from_millis(500);

/// Prefix of the error the handle wrapper throws for a handle that no longer resolves.
const STALE_MARKER: &str = "cmux-stale-handle:";

/// Object group for handle moves, released after each evaluation.
/// Object groups of the driver's own remote objects. Every call takes a
/// group of its own: frames in one process share a CDP session, and a
/// release of one shared group killed the objects of a concurrent call
/// ("Could not find object with given id": the snapshot lost a frame).
fn handle_group() -> String {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    format!("cmux-handles-{}", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed))
}

/// `Runtime.callFunctionOn` with `returnByValue`, parsed once: the value
/// stays the JSON text Chromium sent (a9 raw_value: the page's key order).
#[derive(serde::Deserialize)]
struct CallReply {
    result: CallResult,
    #[serde(rename = "exceptionDetails")]
    exception_details: Option<Value>,
}

#[derive(serde::Deserialize)]
struct CallResult {
    /// Absent for `undefined` and for values JSON cannot hold.
    value: Option<Box<RawValue>>,
}

/// A script context: the CDP session that owns it and its id there.
struct Context {
    session: String,
    id: i64,
}

impl Inner {
    fn frame_or_main(&self, session: &Session, params: &Value) -> Result<String, DriverError> {
        if let Some(frame_id) = params.get("frameId").and_then(Value::as_str) {
            return Ok(frame_id.to_owned());
        }
        self.lock()
            .tabs
            .get(&session.target_id)
            .and_then(|tab| tab.main_frame.clone())
            .ok_or_else(|| DriverError::not_found("The tab has no main frame yet"))
    }

    /// Forgets a context id that CDP reported as gone, so the next lookup
    /// waits for (or creates) the frame's current one.
    fn forget_context(&self, session: &Session, frame_id: &str, world: World) {
        if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
            tab.contexts.remove(&(frame_id.to_owned(), world));
        }
    }

    /// The execution context of `world` in a frame. The agent world is created
    /// (and the agent installed) when the frame has none yet.
    fn context(
        &self,
        session: &Session,
        frame_id: &str,
        world: World,
        deadline: Instant,
    ) -> Result<Context, DriverError> {
        let key = (frame_id.to_owned(), world);
        let grace = (Instant::now() + CONTEXT_GRACE).min(deadline);
        let known = self.wait_for(&session.target_id, grace, "the frame's script context", |tab| {
            tab.contexts
                .get(&key)
                .map(|(session, id)| Ok(Context { session: session.clone(), id: *id }))
        });
        match known {
            Ok(context) if world == World::Agent => {
                self.ensure_agent(session, &context, deadline)?;
                return Ok(context);
            }
            Ok(context) => return Ok(context),
            Err(error) if error.code != ErrorCode::Timeout => return Err(error),
            Err(_) => {}
        }
        if world == World::Page {
            return Err(DriverError::not_found(format!("Frame {frame_id} has no document")));
        }
        let owner = self.frame_session(session, frame_id);
        let name = if world == World::Host { HOST_WORLD } else { AGENT_WORLD };
        let created = self.send_on(
            &owner,
            "Page.createIsolatedWorld",
            json!({"frameId": frame_id, "worldName": name, "grantUniveralAccess": true}),
            deadline,
        )?;
        let id = created
            .get("executionContextId")
            .and_then(Value::as_i64)
            .ok_or_else(|| DriverError::not_found(format!("Frame {frame_id} is gone")))?;
        if world == World::Agent {
            let installed = self.send_on(
                &owner,
                "Runtime.evaluate",
                json!({"expression": &*self.agent_source, "contextId": id, "returnByValue": true}),
                deadline,
            )?;
            if let Some(details) = installed.get("exceptionDetails") {
                return Err(evaluation_error(details));
            }
        }
        if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
            tab.contexts.insert(key, (owner.clone(), id));
            if world == World::Agent {
                tab.agent_ready.insert((owner.clone(), id));
            }
        }
        Ok(Context { session: owner, id })
    }

    /// Makes sure a reported agent-world context holds the page agent.
    /// Chromium can report two isolated contexts with the agent world's name
    /// for one new document (seen after a cross-site navigation to an http
    /// page), and the one recorded last may never have run the agent script;
    /// agent calls there failed with "Cannot read properties of undefined".
    /// The agent script returns at once where the agent already exists.
    fn ensure_agent(
        &self,
        session: &Session,
        context: &Context,
        deadline: Instant,
    ) -> Result<(), DriverError> {
        let ready = (context.session.clone(), context.id);
        let known_ready = self
            .lock()
            .tabs
            .get(&session.target_id)
            .is_some_and(|tab| tab.agent_ready.contains(&ready));
        if known_ready {
            return Ok(());
        }
        let probe = self.send_on(
            &context.session,
            "Runtime.evaluate",
            json!({"expression": "typeof globalThis.__cmuxPageAgent === 'object'", "contextId": context.id, "returnByValue": true}),
            deadline,
        )?;
        if probe["result"]["value"].as_bool() != Some(true) {
            let installed = self.send_on(
                &context.session,
                "Runtime.evaluate",
                json!({"expression": &*self.agent_source, "contextId": context.id, "returnByValue": true}),
                deadline,
            )?;
            if let Some(details) = installed.get("exceptionDetails") {
                return Err(evaluation_error(details));
            }
        }
        if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
            tab.agent_ready.insert(ready);
        }
        Ok(())
    }

    /// Remote object id of an agent handle, in the frame's agent world.
    fn handle_object(
        &self,
        agent: &Context,
        handle: &str,
        group: &str,
        deadline: Instant,
    ) -> Result<String, DriverError> {
        let resolved = self.send_on(
            &agent.session,
            "Runtime.callFunctionOn",
            json!({
                "functionDeclaration": "function (id) { const a = globalThis.__cmuxPageAgent; return a && a.resolveHandle ? a.resolveHandle(id) : null; }",
                "executionContextId": agent.id,
                "arguments": [{"value": handle}],
                "returnByValue": false,
                "objectGroup": group,
            }),
            deadline,
        )?;
        if let Some(details) = resolved.get("exceptionDetails") {
            return Err(evaluation_error(details));
        }
        resolved["result"].get("objectId").and_then(Value::as_str).map(str::to_owned).ok_or_else(
            || {
                DriverError::new(
                    ErrorCode::Stale,
                    format!("Element handle {handle} is no longer attached"),
                )
            },
        )
    }

    /// A script's value, parsed (internal callers read fields of it).
    pub(super) fn evaluate(&self, params: &Value) -> Result<Value, DriverError> {
        let raw = self.evaluate_raw(params)?;
        serde_json::from_str(raw.get())
            .map_err(|e| DriverError::invalid(format!("the script's value is not JSON: {e}")))
    }

    /// A script's value as the JSON text Chromium sent.
    pub(super) fn evaluate_raw(&self, params: &Value) -> Result<Box<RawValue>, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let frame_id = self.frame_or_main(&session, params)?;
        let world = World::parse(params.get("world").and_then(Value::as_str)).ok_or_else(|| {
            DriverError::invalid("world: expected \"agent\", \"page\" or \"host\"")
        })?;
        // A context that died with its document is forgotten and the call runs
        // once more in the frame's current context.
        match self.evaluate_once(&session, &frame_id, world, params, deadline) {
            Err(error) if is_stale_context(&error) => {
                self.forget_context(&session, &frame_id, world);
                self.forget_context(&session, &frame_id, World::Agent);
                self.evaluate_once(&session, &frame_id, world, params, deadline)
            }
            other => other,
        }
    }

    fn evaluate_once(
        &self,
        session: &Session,
        frame_id: &str,
        world: World,
        params: &Value,
        deadline: Instant,
    ) -> Result<Box<RawValue>, DriverError> {
        let source = required_str(params, "source")?;
        let args: Vec<Value> =
            params.get("args").and_then(Value::as_array).cloned().unwrap_or_default();
        let handles: Vec<String> = params
            .get("handles")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();

        let mut arguments: Vec<Value> = Vec::new();
        let mut used_group: Option<(String, String)> = None;
        let (context, declaration) = match world {
            World::Host if !handles.is_empty() => {
                return Err(DriverError::invalid("the host world takes no element handles"));
            }
            World::Host => {
                (self.context(session, frame_id, World::Host, deadline)?, source.to_owned())
            }
            World::Agent if handles.is_empty() => {
                (self.context(session, frame_id, World::Agent, deadline)?, source.to_owned())
            }
            World::Agent => {
                arguments.push(json!({"value": handles}));
                let declaration = format!(
                    "function (handles, ...args) {{ const a = globalThis.__cmuxPageAgent; \
                     const els = handles.map((h) => {{ const e = a && a.resolveHandle ? a.resolveHandle(h) : null; \
                     if (!e) throw new Error({STALE_MARKER:?} + h); return e; }}); return ({source})(...els, ...args); }}",
                );
                (self.context(session, frame_id, World::Agent, deadline)?, declaration)
            }
            World::Page => {
                let page = self.context(session, frame_id, World::Page, deadline)?;
                if !handles.is_empty() {
                    let agent = self.context(session, frame_id, World::Agent, deadline)?;
                    let group = handle_group();
                    used_group = Some((agent.session.clone(), group.clone()));
                    let moved = self.move_handles(&agent, &page, &handles, &group, deadline);
                    match moved {
                        Ok(objects) => {
                            arguments.extend(objects.into_iter().map(|id| json!({"objectId": id})));
                        }
                        Err(error) => {
                            self.release_handles(&agent.session, &group);
                            return Err(error);
                        }
                    }
                }
                (page, source.to_owned())
            }
        };
        arguments.extend(args.into_iter().map(|value| json!({"value": value})));
        let left = deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
        let reply: Result<CallReply, DriverError> = self.conn.call_typed(
            Some(&context.session),
            "Runtime.callFunctionOn",
            json!({
                "functionDeclaration": declaration,
                "executionContextId": context.id,
                "arguments": arguments,
                "returnByValue": true,
                "awaitPromise": params.get("awaitPromise").and_then(Value::as_bool).unwrap_or(true),
                "userGesture": true,
            }),
            left,
        );
        if let Some((group_session, group)) = used_group {
            self.release_handles(&group_session, &group);
        }
        let reply = reply?;
        if let Some(details) = &reply.exception_details {
            return Err(evaluation_error(details));
        }
        match reply.result.value {
            Some(value) => Ok(value),
            None => RawValue::from_string("null".to_owned())
                .map_err(|e| DriverError::invalid(e.to_string())),
        }
    }

    /// Agent handles -> remote objects in the page world, through backend node ids.
    fn move_handles(
        &self,
        agent: &Context,
        page: &Context,
        handles: &[String],
        group: &str,
        deadline: Instant,
    ) -> Result<Vec<String>, DriverError> {
        let mut objects = Vec::with_capacity(handles.len());
        for handle in handles {
            let object = self.handle_object(agent, handle, group, deadline)?;
            let node = self.send_on(
                &agent.session,
                "DOM.describeNode",
                json!({"objectId": object}),
                deadline,
            )?;
            let backend = node["node"]["backendNodeId"].as_i64().ok_or_else(|| {
                DriverError::new(ErrorCode::Stale, format!("Element handle {handle} is detached"))
            })?;
            let moved = self.send_on(
                &page.session,
                "DOM.resolveNode",
                json!({"backendNodeId": backend, "executionContextId": page.id, "objectGroup": group}),
                deadline,
            )?;
            let object_id = moved["object"]["objectId"].as_str().ok_or_else(|| {
                DriverError::new(ErrorCode::Stale, format!("Element handle {handle} is detached"))
            })?;
            objects.push(object_id.to_owned());
        }
        Ok(objects)
    }

    fn release_handles(&self, session_id: &str, group: &str) {
        let _ = self.conn.call(
            Some(session_id),
            "Runtime.releaseObjectGroup",
            json!({"objectGroup": group}),
            Duration::from_secs(2),
        );
    }

    /// The tab's whole frame tree: the main session's tree with every
    /// out-of-process frame's tree grafted under its parent frame.
    fn frame_tree(&self, session: &Session) -> Result<Value, DriverError> {
        let mut tree = self.send(session, "Page.getFrameTree", json!({}))?["frameTree"].clone();
        let children: Vec<String> = self
            .lock()
            .tabs
            .get(&session.target_id)
            .map(|tab| tab.frame_sessions.values().cloned().collect())
            .unwrap_or_default();
        let mut pending: Vec<Value> = Vec::new();
        for child in children {
            if let Ok(reply) = self.conn.call(
                Some(&child),
                "Page.getFrameTree",
                json!({}),
                super::driver::INTERNAL_TIMEOUT,
            ) {
                pending.push(reply["frameTree"].clone());
            }
        }
        // Graft until no subtree finds its parent (nested out-of-process frames).
        loop {
            let before = pending.len();
            pending.retain(|subtree| {
                let parent = subtree["frame"]["parentId"].as_str().unwrap_or("").to_owned();
                !graft(&mut tree, &parent, subtree)
            });
            if pending.is_empty() || pending.len() == before {
                break;
            }
        }
        Ok(tree)
    }

    pub(super) fn frames_list(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let tree = self.frame_tree(&session)?;
        let main_origin = tree["frame"]["securityOrigin"].as_str().unwrap_or("").to_owned();
        let mut out = Vec::new();
        let mut queue = std::collections::VecDeque::from([(tree, Value::Null)]);
        while let Some((node, parent)) = queue.pop_front() {
            let frame = &node["frame"];
            let frame_id = frame["id"].clone();
            out.push(json!({
                "frameId": frame_id,
                "parentFrameId": parent,
                "url": super::state::frame_url(frame),
                "name": frame.get("name").and_then(Value::as_str).unwrap_or(""),
                "crossOrigin": frame["securityOrigin"].as_str().unwrap_or("") != main_origin,
            }));
            for child in node["childFrames"].as_array().into_iter().flatten() {
                queue.push_back((child.clone(), frame_id.clone()));
            }
        }
        Ok(Value::Array(out))
    }

    fn content_frame_of(
        &self,
        session: &Session,
        frame_id: &str,
        element: &str,
        deadline: Instant,
    ) -> Result<Value, DriverError> {
        let agent = self.context(session, frame_id, World::Agent, deadline)?;
        let group = handle_group();
        let object = self.handle_object(&agent, element, &group, deadline);
        let node = object.and_then(|object| {
            self.send_on(&agent.session, "DOM.describeNode", json!({"objectId": object}), deadline)
        });
        self.release_handles(&agent.session, &group);
        Ok(match node?["node"].get("frameId").and_then(Value::as_str) {
            Some(child) => json!({"frameId": child}),
            None => Value::Null,
        })
    }

    pub(super) fn content_frame(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let frame_id = self.frame_or_main(&session, params)?;
        let element = required_str(params, "element")?;
        self.content_frame_of(&session, &frame_id, element, deadline)
    }

    pub(super) fn content_frames(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let frame_id = self.frame_or_main(&session, params)?;
        let elements =
            params.get("elements").and_then(Value::as_array).cloned().unwrap_or_default();
        let frames = elements
            .iter()
            .map(|element| match element.as_str() {
                Some(element) => self
                    .content_frame_of(&session, &frame_id, element, deadline)
                    .unwrap_or(Value::Null),
                None => Value::Null,
            })
            .collect();
        Ok(Value::Array(frames))
    }

    /// The owner `<iframe>`'s content box in its parent frame's coordinates.
    pub(super) fn owner_box(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let frame_id = required_str(params, "frameId")?;
        let tree = self.frame_tree(&session)?;
        let parent = parent_of(&tree, frame_id, None).ok_or_else(|| {
            DriverError::not_found(format!("Frame {frame_id} has no owner element"))
        })?;
        let parent_session = self.frame_session(&session, &parent);
        let owner = self.send_on(
            &parent_session,
            "DOM.getFrameOwner",
            json!({"frameId": frame_id}),
            deadline,
        )?;
        let backend = owner["backendNodeId"].as_i64().ok_or_else(|| {
            DriverError::not_found(format!("Frame {frame_id} has no owner element"))
        })?;
        let page = self.context(&session, &parent, World::Page, deadline)?;
        let group = handle_group();
        let resolved = self.send_on(
            &page.session,
            "DOM.resolveNode",
            json!({"backendNodeId": backend, "executionContextId": page.id, "objectGroup": group}),
            deadline,
        )?;
        let object_id = resolved["object"]["objectId"]
            .as_str()
            .ok_or_else(|| {
                DriverError::new(ErrorCode::Stale, "The frame's owner element is detached")
            })?
            .to_owned();
        let reply = self.send_on(
            &page.session,
            "Runtime.callFunctionOn",
            json!({
                "objectId": object_id,
                "functionDeclaration": "function () { const r = this.getBoundingClientRect(); const cs = getComputedStyle(this); \
                    const px = (v) => parseFloat(v) || 0; return { x: r.left + this.clientLeft + px(cs.paddingLeft), \
                    y: r.top + this.clientTop + px(cs.paddingTop), width: this.clientWidth - px(cs.paddingLeft) - px(cs.paddingRight), \
                    height: this.clientHeight - px(cs.paddingTop) - px(cs.paddingBottom) }; }",
                "returnByValue": true,
            }),
            deadline,
        );
        self.release_handles(&page.session, &group);
        let reply = reply?;
        if let Some(details) = reply.get("exceptionDetails") {
            return Err(evaluation_error(details));
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }
}

/// Appends `subtree` to the children of `parent_id` inside `node`.
fn graft(node: &mut Value, parent_id: &str, subtree: &Value) -> bool {
    if node["frame"]["id"].as_str() == Some(parent_id) {
        if !node["childFrames"].is_array() {
            node["childFrames"] = json!([]);
        }
        if let Some(children) = node["childFrames"].as_array_mut() {
            children.retain(|child| child["frame"]["id"] != subtree["frame"]["id"]);
            children.push(subtree.clone());
        }
        return true;
    }
    match node.get_mut("childFrames").and_then(Value::as_array_mut) {
        Some(children) => children.iter_mut().any(|child| graft(child, parent_id, subtree)),
        None => false,
    }
}

/// CDP errors that mean the context id died with its document.
fn is_stale_context(error: &DriverError) -> bool {
    let message = error.message.to_ascii_lowercase();
    message.contains("cannot find context") || message.contains("execution context was destroyed")
}

fn parent_of(node: &Value, frame_id: &str, parent: Option<&str>) -> Option<String> {
    if node["frame"]["id"].as_str() == Some(frame_id) {
        return parent.map(str::to_owned);
    }
    let id = node["frame"]["id"].as_str();
    node["childFrames"]
        .as_array()
        .into_iter()
        .flatten()
        .find_map(|child| parent_of(child, frame_id, id))
}

/// `exceptionDetails` to a driver error (`evaluation`, or `stale` for a dead handle).
pub(super) fn evaluation_error(details: &Value) -> DriverError {
    let exception = &details["exception"];
    let description = exception
        .get("description")
        .and_then(Value::as_str)
        .or_else(|| exception.get("value").and_then(Value::as_str))
        .or_else(|| details.get("text").and_then(Value::as_str))
        .unwrap_or("evaluation failed");
    let message = error_message(description);
    if let Some(handle) = message.strip_prefix(STALE_MARKER) {
        return DriverError::new(
            ErrorCode::Stale,
            format!("Element handle {handle} is no longer attached"),
        );
    }
    let mut error = DriverError::new(ErrorCode::Evaluation, message);
    error.error_name = exception.get("className").and_then(Value::as_str).map(str::to_owned);
    error
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exceptions_map_to_evaluation_errors_with_names() {
        let error = evaluation_error(
            &json!({"text": "Uncaught", "exception": {"className": "TypeError", "description": "TypeError: a is not a function\n    at x"}}),
        );
        assert_eq!(error.code, ErrorCode::Evaluation);
        assert_eq!(error.message, "a is not a function");
        assert_eq!(error.error_name.as_deref(), Some("TypeError"));
        let thrown = evaluation_error(
            &json!({"text": "Uncaught", "exception": {"type": "string", "value": "plain"}}),
        );
        assert_eq!(thrown.message, "plain");
    }

    #[test]
    fn dead_handles_are_stale() {
        let error = evaluation_error(
            &json!({"exception": {"className": "Error", "description": format!("Error: {STALE_MARKER}h12\n    at y")}}),
        );
        assert_eq!(error.code, ErrorCode::Stale);
        assert!(error.message.contains("h12"));
    }

    #[test]
    fn out_of_process_subtrees_graft_under_their_parent() {
        let mut tree = json!({"frame": {"id": "A"}, "childFrames": [{"frame": {"id": "B"}}]});
        let subtree = json!({"frame": {"id": "X", "parentId": "B"}});
        assert!(graft(&mut tree, "B", &subtree));
        assert_eq!(tree["childFrames"][0]["childFrames"][0]["frame"]["id"], "X");
        assert!(graft(&mut tree, "B", &subtree), "grafting twice replaces, not duplicates");
        assert_eq!(tree["childFrames"][0]["childFrames"].as_array().unwrap().len(), 1);
        assert!(!graft(&mut tree, "nope", &subtree));
        assert!(is_stale_context(&DriverError::invalid("Execution context was destroyed.")));
        assert!(!is_stale_context(&DriverError::invalid("boom")));
    }

    #[test]
    fn parents_are_found_in_the_frame_tree() {
        let tree = json!({"frame": {"id": "A"}, "childFrames": [{"frame": {"id": "B"}, "childFrames": [{"frame": {"id": "C"}}]}]});
        assert_eq!(parent_of(&tree, "C", None).as_deref(), Some("B"));
        assert_eq!(parent_of(&tree, "B", None).as_deref(), Some("A"));
        assert_eq!(parent_of(&tree, "A", None), None);
        assert_eq!(parent_of(&tree, "Z", None), None);
    }
}
