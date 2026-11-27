//! cmux Remote's service rules (`CmuxNextMacScreen/CmuxRemote/CmuxRemoteService*`,
//! `RemoteDeviceChannel`), as data. Sockets, processes and timers stay in Swift. See `ui/mod.rs`.
//!
//! - `service.capture`: a capture phase's public answer from the daemon's raw one (or a failure
//!   code), so a caller only sees a verified, terminal result.
//! - `service.hostStatus`: the Computer Use state read from the host's status object.
//! - `service.approvals`: the saved approvals list, sorted by app id.
//! - `service.workerLabel`: the Settings card's worker state.
//! - `service.channelOpen` / `service.channelAnswer`: the app socket's hello and channel request
//!   lines, and the host's answer to them.
//! - `service.answerResult`: a channel answer line's `result`, or why it failed.

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, args_value: &Value) -> Answer {
    Some(match name {
        "capture" => args::<CaptureArgs>(args_value).map(|a| capture(&a)),
        "hostStatus" => Ok(host_status(args_value.get("host").filter(|v| !v.is_null()))),
        "approvals" => answer(&approvals(args_value.get("answer"))),
        "workerLabel" => Ok(json!(worker_label(args_value.get("state").and_then(Value::as_str)))),
        "channelOpen" => args::<ChannelOpenArgs>(args_value).map(|a| json!(channel_open(&a))),
        "channelAnswer" => args::<ChannelAnswerArgs>(args_value).and_then(|a| channel_answer(&a)),
        "answerResult" => Ok(answer_result(args_value.get("line").and_then(Value::as_str))),
        _ => return None,
    })
}

/// A JSON number Swift's `as? Int` takes from a Foundation object: an integral number, or a bool.
fn foundation_int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Bool(flag) => Some(i64::from(*flag)),
        Value::Number(number) => number.as_i64().or_else(|| {
            let float = number.as_f64()?;
            (float.fract() == 0.0 && float.abs() < 9.2e18).then_some(float as i64)
        }),
        _ => None,
    }
}

/// A pid (`pid_t`), when the number fits one.
fn pid(value: Option<&Value>) -> Option<i32> {
    foundation_int(value).and_then(|pid| i32::try_from(pid).ok())
}

/// Swift's `as? Bool == true` on a Foundation object: `true`, or the number 1.
fn foundation_true(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64() == Some(1.0),
        _ => false,
    }
}

// MARK: Capture

#[derive(Deserialize)]
struct CaptureArgs {
    phase: String,
    #[serde(default)]
    raw: Value,
    #[serde(default)]
    failure: Option<String>,
}

const PHASES: [&str; 3] = ["prepare", "resume", "cleanup"];

fn capture(args: &CaptureArgs) -> Value {
    if !PHASES.contains(&args.phase.as_str()) {
        return capture_failure("invalid_request");
    }
    if let Some(code) = &args.failure {
        return capture_failure(code);
    }
    if args.phase == "resume" {
        return capture_resume(&args.raw);
    }
    capture_result(&args.raw, &args.phase)
}

/// Resume holds only with exactly `{ok: true, code: "remote_capture_resumed", lease_bound: true}`.
fn capture_resume(raw: &Value) -> Value {
    let held = raw.as_object().is_some_and(|fields| {
        fields.len() == 3
            && fields.get("ok") == Some(&Value::Bool(true))
            && fields.get("code").and_then(Value::as_str) == Some("remote_capture_resumed")
            && fields.get("lease_bound") == Some(&Value::Bool(true))
    });
    if held {
        json!({"ok": true, "code": "remote_capture_resumed", "lease_bound": true})
    } else {
        json!({"ok": false, "code": "remote_resume_unverified", "lease_bound": false})
    }
}

/// A count the daemon reports: a number that is a whole, non-negative Int.
fn count(raw: &Value, key: &str) -> Option<f64> {
    let value = raw.get(key)?.as_f64()?;
    (value >= 0.0 && value.fract() == 0.0 && value < 9.223_372_036_854_776e18).then_some(value)
}

fn capture_result(raw: &Value, phase: &str) -> Value {
    let flag = |key: &str| raw.get(key).and_then(Value::as_bool);
    let (
        Some(code),
        Some(producer_ok),
        Some(worker_started),
        Some(lease_bound),
        Some(verified_absent),
        Some(worker_quiescent),
        Some(worker_exited),
        Some(descendants_exited),
        Some(identities),
        Some(relays),
    ) = (
        raw.get("code").and_then(Value::as_str),
        flag("ok"),
        flag("worker_started"),
        flag("lease_bound"),
        flag("verified_absent"),
        flag("worker_quiescent"),
        flag("worker_pid_exited"),
        flag("descendants_exited"),
        count(raw, "identity_removed"),
        count(raw, "relays_removed"),
    )
    else {
        return capture_failure("remote_invalid_result");
    };
    let terminal = producer_ok
        && lease_bound
        && worker_exited
        && descendants_exited
        && verified_absent
        && worker_quiescent;
    let pristine = !worker_started && identities == 0.0 && relays == 0.0;
    let prepared = phase == "prepare" && code == "no_remote_started" && pristine;
    let cleaned = phase == "cleanup" && code == "remote_cleaned" && (worker_started || pristine);
    let accepted = terminal && (prepared || cleaned);
    let public_code = match (accepted, pristine) {
        (true, true) => "no_remote_started",
        (true, false) => "ok",
        (false, _) => code,
    };
    json!({
        "ok": accepted, "code": public_code, "lease_bound": lease_bound,
        "worker_started": worker_started, "identity_removed": identities,
        "relays_removed": relays, "verified_absent": verified_absent,
        "worker_quiescent": worker_quiescent, "worker_pid_exited": worker_exited,
        "descendants_exited": descendants_exited,
    })
}

fn capture_failure(code: &str) -> Value {
    json!({
        "ok": false, "code": code, "lease_bound": false, "worker_started": false,
        "identity_removed": 0, "relays_removed": 0, "verified_absent": false,
        "worker_quiescent": false, "worker_pid_exited": false, "descendants_exited": false,
    })
}

// MARK: Computer Use state

/// The host status object's Computer Use fields. `takeActivity`: the answer carries the worker's
/// fields (or there is no host), so its `activity` replaces the sessions.
fn host_status(host: Option<&Value>) -> Value {
    let worker = host
        .and_then(|host| host.get("workers"))
        .filter(|workers| workers.is_object())
        .and_then(|workers| workers.get("computer-use"))
        .filter(|worker| worker.is_object());
    let state = worker.and_then(|worker| worker.get("state")).and_then(Value::as_str);
    let failed = state == Some("unavailable");
    let failure = if failed {
        worker.and_then(|worker| worker.get("reason")).and_then(Value::as_str)
    } else {
        None
    };
    let activity = worker
        .and_then(|worker| worker.get("activity"))
        .filter(|activity| activity.is_array())
        .cloned()
        .unwrap_or(Value::Null);
    json!({
        "hostPid": pid(host.and_then(|host| host.get("pid"))),
        "failed": failed,
        "failure": failure,
        "workerState": state,
        "workerPid": pid(worker.and_then(|worker| worker.get("pid"))),
        "takeActivity": host.is_none() || worker.is_some(),
        "activity": activity,
    })
}

#[derive(serde::Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Approval {
    app_id: String,
    decision: &'static str,
}

/// A `list` answer, `{"saved":{"always":[...],"never":[...]}}` (or the saved object itself):
/// ids, or `{"app_id"|"id"}` objects, sorted by id.
fn approvals(answer: Option<&Value>) -> Vec<Approval> {
    let empty = Map::new();
    let answer = answer.and_then(Value::as_object);
    let saved = answer
        .and_then(|answer| answer.get("saved"))
        .and_then(Value::as_object)
        .or(answer)
        .unwrap_or(&empty);
    let ids = |key: &str| -> Vec<String> {
        let entries = saved.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
        entries
            .iter()
            .filter_map(|entry| match entry {
                Value::String(id) => Some(id.clone()),
                Value::Object(object) => {
                    object.get("app_id").or_else(|| object.get("id"))?.as_str().map(str::to_owned)
                }
                _ => None,
            })
            .collect()
    };
    let mut rows: Vec<Approval> = ids("always")
        .into_iter()
        .map(|app_id| Approval { app_id, decision: "always" })
        .chain(ids("never").into_iter().map(|app_id| Approval { app_id, decision: "never" }))
        .collect();
    rows.sort_by(|a, b| a.app_id.cmp(&b.app_id));
    rows
}

fn worker_label(state: Option<&str>) -> &'static str {
    match state {
        Some("ready") => "running",
        Some("starting") => "starting",
        Some("unavailable") => "failed",
        _ => "stopped",
    }
}

// MARK: App socket

#[derive(Deserialize)]
struct ChannelOpenArgs {
    channel: String,
    secret: String,
    #[serde(default)]
    extra: Map<String, Value>,
}

/// The hello line with this launch's secret, then the channel request (`extra` wins over its keys).
fn channel_open(args: &ChannelOpenArgs) -> String {
    let hello = json!({"type": "hello", "secret": args.secret});
    let mut request = Map::new();
    request.insert("id".into(), json!(1));
    request.insert("channel".into(), json!(args.channel));
    for (key, value) in &args.extra {
        request.insert(key.clone(), value.clone());
    }
    format!("{hello}\n{}\n", Value::Object(request))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChannelAnswerArgs {
    #[serde(default)]
    line: Option<String>,
    host_pid: i32,
}

/// The host's answer to a channel request: the pid behind the channel, or the refusal's text.
fn channel_answer(args: &ChannelAnswerArgs) -> Result<Value, String> {
    let answer = args
        .line
        .as_deref()
        .and_then(|line| serde_json::from_str::<Value>(line).ok())
        .filter(Value::is_object)
        .ok_or_else(|| "cmux Remote closed the channel".to_owned())?;
    if !foundation_true(answer.get("ok")) {
        return Err(refusal(&answer));
    }
    let pid = pid(answer.get("result").filter(|r| r.is_object()).and_then(|r| r.get("pid")));
    Ok(json!({"pid": pid.unwrap_or(args.host_pid)}))
}

fn refusal(answer: &Value) -> String {
    answer
        .get("error")
        .filter(|error| error.is_object())
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("refused")
        .to_owned()
}

/// An answer line's `result` (`{}` when it has none), or `{"error": "transport"|"identity",
/// "message"}`.
fn answer_result(line: Option<&str>) -> Value {
    let Some(object) =
        line.and_then(|line| serde_json::from_str::<Value>(line).ok()).filter(Value::is_object)
    else {
        return json!({"error": "transport", "message": "cmux Remote's answer is not JSON"});
    };
    if !foundation_true(object.get("ok")) {
        return json!({"error": "identity", "message": refusal(&object)});
    }
    let result = object.get("result").filter(|r| r.is_object()).cloned();
    json!({"result": result.unwrap_or_else(|| json!({}))})
}

#[cfg(test)]
#[path = "service_tests.rs"]
mod tests;
