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
mod tests {
    use super::*;

    #[test]
    fn only_two_reads_route() {
        assert_eq!(route(&json!({"op": "list"})).unwrap(), "/v1/cloud/apps");
        assert_eq!(
            route(&json!({"op": "get", "slug": "invoice-triage"})).unwrap(),
            "/v1/cloud/apps/invoice-triage"
        );
        for bad in [
            json!({"op": "get", "slug": "../machines"}),
            json!({"op": "get", "slug": "a/b"}),
            json!({"op": "get"}),
            json!({"op": "rollback", "slug": "x"}),
            json!({"op": "promote"}),
            json!({}),
            json!("list"),
        ] {
            assert_eq!(route(&bad).unwrap_err()["ok"], false, "{bad}");
        }
    }

    #[test]
    fn answers_keep_the_platform_code() {
        let ok = answer(200, br#"{"items":[]}"#);
        assert_eq!(ok, json!({"ok": true, "value": {"items": []}}));
        let refused = answer(403, br#"{"error":{"code":"auth.forbidden","message":"no"}}"#);
        assert_eq!(refused["error"]["code"], "auth.forbidden");
        assert_eq!(refused["error"]["status"], 403);
        assert_eq!(answer(502, b"<html>")["error"]["code"], "http_502");
        assert_eq!(answer(200, b"[]")["error"]["code"], "cloud.app.bad_reply");
    }

    #[test]
    fn ls_lists_the_platform_apps() {
        let relayed = json!({"ok": true, "value": {"items": [
            {"id": "app_1", "slug": "demo", "name": "Demo", "team": "team_x", "creator": "user_y",
             "hostname": "a-demo--abcdefgh.preview.cmux.dev", "url": "https://a-demo--abcdefgh.preview.cmux.dev",
             "live": 2, "pinned": false, "createdAt": "2026-11-23T00:00:00Z"}
        ]}});
        let out = ls_output(true, &relayed);
        assert_eq!(out.code, 0);
        let body: Value = serde_json::from_str(&out.stdout).unwrap();
        assert_eq!(body["source"], "account");
        assert_eq!(body["items"][0]["slug"], "demo");
        assert_eq!(body["items"][0]["live"], 2);
        assert_eq!(body["items"][0]["url"], "https://a-demo--abcdefgh.preview.cmux.dev");
        let text = ls_output(false, &relayed);
        assert_eq!(text.stdout, "demo\tv2\thttps://a-demo--abcdefgh.preview.cmux.dev\n");
    }

    #[test]
    fn a_refusal_is_an_error_not_an_empty_list() {
        let relayed =
            json!({"ok": false, "error": {"code": "not_signed_in", "message": "sign in"}});
        let out = ls_output(true, &relayed);
        assert_eq!(out.code, 1);
        let body: Value = serde_json::from_str(&out.stdout).unwrap();
        assert_eq!(body["error"]["code"], "not_signed_in");
        assert!(body.get("items").is_none());
        let text = ls_output(false, &relayed);
        assert_eq!(text.code, 1);
        assert!(text.stderr.contains("not_signed_in"));
    }

    #[test]
    fn versions_marks_live() {
        let relayed = json!({"ok": true, "value": {
        "app": {"slug": "demo", "name": "Demo", "live": 2},
        "versions": [
            {"n": 2, "commit": "0123456789abcdef0123", "command": "npm start", "state": "live"},
            {"n": 1, "commit": "fedcba9876543210fedc", "command": "npm start", "state": "retired"}
        ]}});
        let out = versions_output(false, &relayed);
        assert_eq!(
            out.stdout,
            "v2\tlive (live)\t0123456789ab\tnpm start\nv1\tretired\tfedcba987654\tnpm start\n"
        );
        let body: Value = serde_json::from_str(&versions_output(true, &relayed).stdout).unwrap();
        assert_eq!(body["versions"].as_array().unwrap().len(), 2);
    }
}
