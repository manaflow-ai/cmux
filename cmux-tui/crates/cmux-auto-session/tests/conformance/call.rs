//! One step as a call of the `AutoCloud` trait, answered as the route's JSON body.

use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

use cmux_auto_session::cloud::{AutoCloud, CloudResult};
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{KeepRequest, MachineSetting, SessionView};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::vectors::Step;

/// The team `$team` stands for: any team id the store takes.
const TEAM: &str = "team_0123456789abcdef0123";

/// The answer of a request the store does not hold. The vectors' held requests (`wait`,
/// `assignments`) name a deadline of now.
fn ready<T>(future: impl Future<Output = T>) -> Result<T, String> {
    let mut cx = Context::from_waker(Waker::noop());
    match pin!(future).poll(&mut cx) {
        Poll::Ready(answer) => Ok(answer),
        Poll::Pending => Err("the store holds the request".to_owned()),
    }
}

/// The step's body as the request type of its route.
fn body<T: DeserializeOwned>(step: &Step) -> Result<T, String> {
    let body = step.body.clone().ok_or_else(|| format!("{} needs a body", step.op))?;
    serde_json::from_value(body).map_err(|why| format!("{}'s body does not read: {why}", step.op))
}

fn named<'a>(step: &Step, field: &'a Option<String>, name: &str) -> Result<&'a str, String> {
    field.as_deref().ok_or_else(|| format!("{} needs {name}", step.op))
}

fn as_json<T: Serialize>(answer: CloudResult<T>) -> Result<CloudResult<Value>, String> {
    match answer {
        Ok(answer) => serde_json::to_value(answer).map(Ok).map_err(|why| why.to_string()),
        Err(refused) => Ok(Err(refused)),
    }
}

/// A route that answers `{session}`.
fn session(answer: CloudResult<SessionView>) -> Result<CloudResult<Value>, String> {
    as_json(answer.map(|session| json!({ "session": session })))
}

/// Calls the step's route. Err: the step is one the replayer cannot make.
pub fn call(cloud: &FakeAutoCloud, step: &Step, id: &str) -> Result<CloudResult<Value>, String> {
    let query = &step.query;
    match step.op.as_str() {
        "machine" => as_json(ready(cloud.machine())?),
        "set_machine" => {
            let mut setting: MachineSetting = body(step)?;
            if setting.team == "$team" {
                TEAM.clone_into(&mut setting.team);
            }
            as_json(ready(cloud.set_machine(&setting))?)
        }
        "put" => session(ready(cloud.put(id, &body(step)?))?),
        "create" => {
            // `keepInCloud` is the one field of the request the trait's `create` does not send.
            let kept = step.body.as_ref().and_then(|body| body.get("keepInCloud"));
            session(cloud.create_kept(&body(step)?, kept == Some(&Value::Bool(true))))
        }
        "list" => as_json(ready(cloud.list(query.limit, None))?),
        "get" => session(ready(cloud.get(id))?),
        "wait" => {
            let (after, timeout_ms) = (query.after.unwrap_or(0), query.timeout_ms.unwrap_or(0));
            session(ready(cloud.wait(id, after, timeout_ms))?)
        }
        "lease" => as_json(ready(cloud.lease(id, &body(step)?))?),
        "release" => session(ready(cloud.release(id, &body(step)?))?),
        "append_events" => {
            let appended = ready(cloud.append_events(id, &body(step)?))?;
            as_json(appended.map(|last_seq| json!({ "lastSeq": last_seq })))
        }
        "events" => as_json(ready(cloud.events(id, query.after.unwrap_or(0), query.limit))?),
        "put_chunk" => {
            let sha256 = named(step, &step.sha256, "sha256")?;
            let text = named(step, &step.text, "text")?;
            let fence = step.fence.as_ref().ok_or("put_chunk needs fence")?;
            as_json(ready(cloud.put_chunk(id, sha256, text.as_bytes(), fence))?)
        }
        "chunk" => {
            let bytes = ready(cloud.chunk(id, named(step, &step.sha256, "sha256")?))?;
            as_json(bytes.map(|bytes| json!({ "text": String::from_utf8_lossy(&bytes) })))
        }
        "post_snapshot" => {
            let posted = ready(cloud.post_snapshot(id, &body(step)?))?;
            as_json(posted.map(|snapshot| json!({ "snapshot": snapshot })))
        }
        "snapshot" => as_json(ready(cloud.snapshot(id))?),
        "post_inbox" => as_json(ready(cloud.post_inbox(id, &body(step)?))?),
        "inbox" => {
            let messages = ready(cloud.inbox(id, query.after.unwrap_or(0)))?;
            as_json(messages.map(|messages| json!({ "messages": messages })))
        }
        "ack_inbox" => session(ready(cloud.ack_inbox(id, &body(step)?))?),
        "keep" => {
            let keep: KeepRequest = body(step)?;
            session(ready(cloud.keep(id, keep.keep_in_cloud))?)
        }
        "move" => session(ready(cloud.move_(id, &body(step)?))?),
        "give" => session(ready(cloud.give(id, &body(step)?))?),
        "assignments" => {
            let assignments = ready(cloud.assignments(query.timeout_ms.unwrap_or(0)))?;
            as_json(assignments.map(|assignments| json!({ "assignments": assignments })))
        }
        "ack_assignment" => session(ready(cloud.ack_assignment(id, &body(step)?))?),
        other => Err(format!("the vectors name a route the replayer does not know: {other}")),
    }
}
