//! Frames, script evaluation in the page and agent worlds, and agent handles.

use super::driver::{Inner, Session};
use super::state::{AGENT_WORLD, World, error_message};
use crate::protocol::{DriverError, ErrorCode, required_str, timeout_of};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

/// How long to wait for a world's context to be reported before creating it.
const CONTEXT_GRACE: Duration = Duration::from_millis(500);

/// Prefix of the error the handle wrapper throws for a handle that no longer resolves.
const STALE_MARKER: &str = "cmux-stale-handle:";

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

    /// The execution context of `world` in a frame. The agent world is created
    /// (and the agent installed) when the frame has none yet.
    fn context(
        &self,
        session: &Session,
        frame_id: &str,
        world: World,
        deadline: Instant,
    ) -> Result<i64, DriverError> {
        let key = (frame_id.to_owned(), world);
        let grace = (Instant::now() + CONTEXT_GRACE).min(deadline);
        let known = self.wait_for(&session.target_id, grace, "the frame's script context", |tab| {
            tab.contexts.get(&key).map(|id| Ok(*id))
        });
        match known {
            Ok(id) => return Ok(id),
            Err(error) if error.code != ErrorCode::Timeout => return Err(error),
            Err(_) => {}
        }
        if world == World::Page {
            return Err(DriverError::not_found(format!("Frame {frame_id} has no document")));
        }
        let created = self.send_until(
            session,
            "Page.createIsolatedWorld",
            json!({"frameId": frame_id, "worldName": AGENT_WORLD, "grantUniveralAccess": true}),
            deadline,
        )?;
        let context = created
            .get("executionContextId")
            .and_then(Value::as_i64)
            .ok_or_else(|| DriverError::not_found(format!("Frame {frame_id} is gone")))?;
        let installed = self.send_until(
            session,
            "Runtime.evaluate",
            json!({"expression": &*self.agent_source, "contextId": context, "returnByValue": true}),
            deadline,
        )?;
        if let Some(details) = installed.get("exceptionDetails") {
            return Err(evaluation_error(details));
        }
        if let Some(tab) = self.lock().tabs.get_mut(&session.target_id) {
            tab.contexts.insert(key, context);
        }
        Ok(context)
    }

    /// Remote object id of an agent handle, in the frame's agent world.
    fn handle_object(
        &self,
        session: &Session,
        agent_context: i64,
        handle: &str,
        deadline: Instant,
    ) -> Result<String, DriverError> {
        let resolved = self.send_until(
            session,
            "Runtime.callFunctionOn",
            json!({
                "functionDeclaration": "function (id) { const a = globalThis.__cmuxPageAgent; return a && a.resolveHandle ? a.resolveHandle(id) : null; }",
                "executionContextId": agent_context,
                "arguments": [{"value": handle}],
                "returnByValue": false,
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

    pub(super) fn evaluate(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let frame_id = self.frame_or_main(&session, params)?;
        let world = World::parse(params.get("world").and_then(Value::as_str))
            .ok_or_else(|| DriverError::invalid("world: expected \"agent\" or \"page\""))?;
        let source = required_str(params, "source")?;
        let args: Vec<Value> =
            params.get("args").and_then(Value::as_array).cloned().unwrap_or_default();
        let handles: Vec<String> = params
            .get("handles")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default();

        let mut arguments: Vec<Value> = Vec::new();
        let (context, declaration) = match world {
            World::Agent if handles.is_empty() => {
                (self.context(&session, &frame_id, World::Agent, deadline)?, source.to_owned())
            }
            World::Agent => {
                arguments.push(json!({"value": handles}));
                let declaration = format!(
                    "function (handles, ...args) {{ const a = globalThis.__cmuxPageAgent; \
                     const els = handles.map((h) => {{ const e = a && a.resolveHandle ? a.resolveHandle(h) : null; \
                     if (!e) throw new Error({STALE_MARKER:?} + h); return e; }}); return ({source})(...els, ...args); }}",
                );
                (self.context(&session, &frame_id, World::Agent, deadline)?, declaration)
            }
            World::Page => {
                let page = self.context(&session, &frame_id, World::Page, deadline)?;
                if !handles.is_empty() {
                    let agent = self.context(&session, &frame_id, World::Agent, deadline)?;
                    for handle in &handles {
                        let object = self.handle_object(&session, agent, handle, deadline)?;
                        let node = self.send_until(
                            &session,
                            "DOM.describeNode",
                            json!({"objectId": object}),
                            deadline,
                        )?;
                        let backend = node["node"]["backendNodeId"].as_i64().ok_or_else(|| {
                            DriverError::new(
                                ErrorCode::Stale,
                                format!("Element handle {handle} is detached"),
                            )
                        })?;
                        let moved = self.send_until(
                            &session,
                            "DOM.resolveNode",
                            json!({"backendNodeId": backend, "executionContextId": page}),
                            deadline,
                        )?;
                        let object_id = moved["object"]["objectId"].as_str().ok_or_else(|| {
                            DriverError::new(
                                ErrorCode::Stale,
                                format!("Element handle {handle} is detached"),
                            )
                        })?;
                        arguments.push(json!({"objectId": object_id}));
                    }
                }
                (page, source.to_owned())
            }
        };
        arguments.extend(args.into_iter().map(|value| json!({"value": value})));
        let reply = self.send_until(
            &session,
            "Runtime.callFunctionOn",
            json!({
                "functionDeclaration": declaration,
                "executionContextId": context,
                "arguments": arguments,
                "returnByValue": true,
                "awaitPromise": params.get("awaitPromise").and_then(Value::as_bool).unwrap_or(true),
                "userGesture": true,
            }),
            deadline,
        )?;
        if let Some(details) = reply.get("exceptionDetails") {
            return Err(evaluation_error(details));
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }

    pub(super) fn frames_list(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let tree = self.send(&session, "Page.getFrameTree", json!({}))?;
        let main_origin =
            tree["frameTree"]["frame"]["securityOrigin"].as_str().unwrap_or("").to_owned();
        let mut out = Vec::new();
        let mut queue =
            std::collections::VecDeque::from([(tree["frameTree"].clone(), Value::Null)]);
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
        let object = self.handle_object(session, agent, element, deadline)?;
        let node =
            self.send_until(session, "DOM.describeNode", json!({"objectId": object}), deadline)?;
        Ok(match node["node"].get("frameId").and_then(Value::as_str) {
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
        let tree = self.send(&session, "Page.getFrameTree", json!({}))?;
        let parent = parent_of(&tree["frameTree"], frame_id, None).ok_or_else(|| {
            DriverError::not_found(format!("Frame {frame_id} has no owner element"))
        })?;
        let owner =
            self.send_until(&session, "DOM.getFrameOwner", json!({"frameId": frame_id}), deadline)?;
        let backend = owner["backendNodeId"].as_i64().ok_or_else(|| {
            DriverError::not_found(format!("Frame {frame_id} has no owner element"))
        })?;
        let page = self.context(&session, &parent, World::Page, deadline)?;
        let resolved = self.send_until(
            &session,
            "DOM.resolveNode",
            json!({"backendNodeId": backend, "executionContextId": page}),
            deadline,
        )?;
        let object_id = resolved["object"]["objectId"].as_str().ok_or_else(|| {
            DriverError::new(ErrorCode::Stale, "The frame's owner element is detached")
        })?;
        let reply = self.send_until(
            &session,
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
        )?;
        if let Some(details) = reply.get("exceptionDetails") {
            return Err(evaluation_error(details));
        }
        Ok(reply["result"].get("value").cloned().unwrap_or(Value::Null))
    }
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
    fn parents_are_found_in_the_frame_tree() {
        let tree = json!({"frame": {"id": "A"}, "childFrames": [{"frame": {"id": "B"}, "childFrames": [{"frame": {"id": "C"}}]}]});
        assert_eq!(parent_of(&tree, "C", None).as_deref(), Some("B"));
        assert_eq!(parent_of(&tree, "B", None).as_deref(), Some("A"));
        assert_eq!(parent_of(&tree, "A", None), None);
        assert_eq!(parent_of(&tree, "Z", None), None);
    }
}
