//! `cmux app ls` and `cmux app versions` off a Cloud machine: the person's apps as the platform
//! has them, read as the signed-in person (RFD 0003, "Platform contract": `GET /v1/cloud/apps`
//! answers the caller's apps and apps shared with them in the team).
//!
//! A Mac (or any machine without a Cloud machine's agent socket) has no `vm-self` credential, and
//! a `cmux auth token` mint carries no `execute`, which the apps routes refuse. So the CLI asks the
//! cmux app (`cloud.apps`), and the app runs `cmux cloud apps-relay` with its own session. This
//! module is that relay's rules and what the CLI prints from its answer: two reads, nothing else.

use serde_json::{Map, Value, json};

use crate::cli::Output;
use crate::platform::APPS;
use crate::slug::is_slug;

/// A refusal answer: `{ok: false, error: {code, message}}`.
pub fn refusal(code: &str, message: &str) -> Value {
    json!({"ok": false, "error": {"code": code, "message": message}})
}

/// The `GET` path of a relay request: `{op: "list"}` or `{op: "get", slug}`. Anything else is
/// refused, so the app's session reads apps and never writes them.
pub fn route(request: &Value) -> Result<String, Value> {
    let op = request.get("op").and_then(Value::as_str).unwrap_or_default();
    match op {
        "list" => Ok(APPS.to_owned()),
        "get" => match request.get("slug").and_then(Value::as_str) {
            Some(slug) if is_slug(slug) => Ok(format!("{APPS}/{slug}")),
            _ => Err(refusal("invalid_params", "cloud.apps get needs a valid `slug`")),
        },
        _ => Err(refusal("invalid_params", "cloud.apps takes op `list` or `get`")),
    }
}

/// The relay's answer from the platform's: `{ok: true, value: BODY}` for a 2xx JSON object, else
/// `{ok: false, error}` with the platform's `cloud.app.*` code when it sent one.
pub fn answer(status: u16, body: &[u8]) -> Value {
    let reply = serde_json::from_slice::<Value>(body).ok().filter(Value::is_object);
    let success = (200..300).contains(&status);
    match reply {
        Some(reply) if success && reply.get("error").is_none() => {
            json!({"ok": true, "value": reply})
        }
        None if success => refusal(
            "cloud.app.bad_reply",
            "cmux Cloud answered something that is not a JSON object",
        ),
        reply => {
            let error = reply.as_ref().and_then(|r| r.get("error"));
            let text = |key: &str| {
                error.and_then(|e| e.get(key)).and_then(Value::as_str).map(str::to_owned)
            };
            let mut out = Map::new();
            out.insert(
                "code".into(),
                json!(text("code").unwrap_or_else(|| format!("http_{status}"))),
            );
            out.insert(
                "message".into(),
                json!(
                    text("message").unwrap_or_else(|| format!("cmux Cloud answered HTTP {status}"))
                ),
            );
            out.insert("status".into(), json!(status));
            json!({"ok": false, "error": Value::Object(out)})
        }
    }
}

/// One app row as `cmux app ls` prints it on a Cloud machine (`name`, `slug`, `url`, `live`), plus
/// what only the platform knows (`team`, `creator`, `pinned`, `hostname`).
fn app_row(app: &Value) -> Value {
    let field = |key: &str| app.get(key).cloned().unwrap_or(Value::Null);
    json!({
        "name": field("name"),
        "slug": field("slug"),
        "url": field("url"),
        "live": field("live"),
        "team": field("team"),
        "creator": field("creator"),
        "pinned": field("pinned"),
        "hostname": field("hostname"),
    })
}

fn word(value: &Value) -> String {
    match value {
        Value::Null => "-".to_owned(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// What `cmux app ls` prints from the relay's answer (`{items: [app]}`).
pub fn ls_output(json: bool, relayed: &Value) -> Output {
    let value = match ok_value(relayed) {
        Ok(value) => value,
        Err(output) => return output(json),
    };
    let items: Vec<Value> = value
        .get("items")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(app_row).collect())
        .unwrap_or_default();
    if json {
        let body = json!({"items": items, "source": "account"});
        return Output { stdout: format!("{body}\n"), stderr: String::new(), code: 0 };
    }
    let mut line = String::new();
    for app in &items {
        let live = match &app["live"] {
            Value::Number(n) => format!("v{n}"),
            other => word(other),
        };
        line.push_str(&format!("{}\t{live}\t{}\n", word(&app["slug"]), word(&app["url"])));
    }
    Output { stdout: line, stderr: String::new(), code: 0 }
}

/// What `cmux app versions NAME` prints from the relay's answer (`{app, versions}`; only the
/// creator sees versions, so a grantee gets the app and none).
pub fn versions_output(json: bool, relayed: &Value) -> Output {
    let value = match ok_value(relayed) {
        Ok(value) => value,
        Err(output) => return output(json),
    };
    let app = value.get("app").cloned().unwrap_or(Value::Null);
    let versions =
        value.get("versions").cloned().filter(Value::is_array).unwrap_or_else(|| json!([]));
    if json {
        let body = json!({"app": app_row(&app), "versions": versions, "source": "account"});
        return Output { stdout: format!("{body}\n"), stderr: String::new(), code: 0 };
    }
    let mut line = String::new();
    for v in versions.as_array().into_iter().flatten() {
        let live = if app.get("live").is_some_and(|l| !l.is_null() && Some(l) == v.get("n")) {
            " (live)"
        } else {
            ""
        };
        let commit = v.get("commit").and_then(Value::as_str).unwrap_or("-");
        line.push_str(&format!(
            "v{}\t{}{live}\t{}\t{}\n",
            word(v.get("n").unwrap_or(&Value::Null)),
            word(v.get("state").unwrap_or(&Value::Null)),
            commit.get(..12).unwrap_or(commit),
            word(v.get("command").unwrap_or(&Value::Null)),
        ));
    }
    Output { stdout: line, stderr: String::new(), code: 0 }
}

type Refused = Box<dyn Fn(bool) -> Output>;

fn ok_value(relayed: &Value) -> Result<&Value, Refused> {
    if relayed.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(relayed.get("value").unwrap_or(&Value::Null));
    }
    let error = relayed.get("error").cloned().unwrap_or_else(|| json!({"code": "app.unreachable"}));
    Err(Box::new(move |json| {
        let code = error.get("code").and_then(Value::as_str).unwrap_or("error").to_owned();
        let message = error.get("message").and_then(Value::as_str).unwrap_or("").to_owned();
        if json {
            let body = json!({"error": {"code": code, "message": message}, "version": Value::Null});
            return Output { stdout: format!("{body}\n"), stderr: String::new(), code: 1 };
        }
        Output { stdout: String::new(), stderr: format!("cmux app: {code}: {message}\n"), code: 1 }
    }))
}

#[cfg(test)]
#[path = "account_tests.rs"]
mod tests;
