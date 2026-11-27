//! The Slack integration's calls on the cmux API (Settings' Slack page, `SlackPageProvider`):
//!
//! - `owner.slack {route}`, with this Mac's install token (auth `worker`) and the team header,
//!   on the artifacts API: `connection` (`GET /v1/slack/connection`), `install_link`
//!   (`POST /v1/slack/install-link`), `disconnect` (`DELETE /v1/slack/connection`, answered `{}`)
//!   and `create_app {configToken, name?}` ("use your own bot name", `POST /v1/slack/apps`). The
//!   configuration token goes only in that one request body; a refusal of it carries no text the
//!   service wrote, so an echo of the token never comes back.
//! - `owner.slack_awake {chief, allowance?}`, with the person's own Stack session (auth `owner`):
//!   RFD 0123's owner setting, `GET /v1/chiefs/<chief>/slack-awake?days=7` with no `allowance`,
//!   else `PUT {allowance_seconds}` (`allowance: null`: back to the 2 h default). `chief` is an
//!   `agent_` id; anything else is refused before a request. Answers the reply's `value`.
//!
//! Each waits 20 s, as the app's did. Nothing is retried, cached or logged.

use std::time::Duration;

use reqwest::Method;
use serde_json::{Map, Value, json};

use super::http::{Body, Http, path_text, worker_error};
use super::{Failure, optional_text, text};

const TIMEOUT: Duration = Duration::from_secs(20);

/// The longest bot name sent (Slack's own app name limit is 35; the route checks it).
const MAX_NAME_BYTES: usize = 256;
/// The longest configuration token sent.
const MAX_CONFIG_TOKEN_BYTES: usize = 4096;

/// A Chief id: `agent_` and 26 Crockford base32 digits (no I, L, O or U).
pub(crate) fn is_chief_id(id: &str) -> bool {
    id.strip_prefix("agent_").is_some_and(|tail| {
        tail.len() == 26
            && tail.bytes().all(|b| {
                b.is_ascii_digit()
                    || (b.is_ascii_uppercase() && !matches!(b, b'I' | b'L' | b'O' | b'U'))
            })
    })
}

/// `owner.slack`.
pub(crate) async fn slack(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    match text(args, "route")? {
        "connection" => send(http, Method::GET, &["v1", "slack", "connection"], &[], None).await,
        "install_link" => {
            send(http, Method::POST, &["v1", "slack", "install-link"], &[], None).await
        }
        "disconnect" => {
            send_raw(http, Method::DELETE, &["v1", "slack", "connection"], &[], None).await?;
            Ok(json!({}))
        }
        "create_app" => create_app(http, args).await,
        _ => Err(Failure::Transport("unsupported Slack request".into())),
    }
}

async fn create_app(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let token = text(args, "configToken")?;
    if token.is_empty() || token.len() > MAX_CONFIG_TOKEN_BYTES {
        return Err(Failure::Transport("not a Slack configuration token".into()));
    }
    let mut body = Map::new();
    body.insert("configToken".into(), json!(token));
    if let Some(name) = optional_text(args, "name") {
        if name.len() > MAX_NAME_BYTES {
            return Err(Failure::Transport("the bot name is too long".into()));
        }
        body.insert("name".into(), json!(name));
    }
    send(http, Method::POST, &["v1", "slack", "apps"], &[], Some(Value::Object(body)))
        .await
        .map_err(|failure| without_service_text(failure, token))
}

/// `failure` with no message the service wrote, and no code that holds `token`.
fn without_service_text(failure: Failure, token: &str) -> Failure {
    match failure {
        Failure::Http { status, code, .. } => {
            Failure::http(status, code.filter(|c| !c.contains(token)), None)
        }
        Failure::PlanRequired { plan, .. } => {
            Failure::PlanRequired { message: None, upgrade_url: None, plan }
        }
        other => other,
    }
}

/// `owner.slack_awake`.
pub(crate) async fn slack_awake(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let chief = text(args, "chief")?;
    if !is_chief_id(chief) {
        return Err(Failure::Transport("not a Chief id".into()));
    }
    let segments = ["v1", "chiefs", chief, "slack-awake"];
    let reply = match args.get("allowance") {
        None => send(http, Method::GET, &segments, &[("days", "7".to_owned())], None).await?,
        Some(Value::Null) => {
            let body = json!({ "allowance_seconds": null });
            send(http, Method::PUT, &segments, &[], Some(body)).await?
        }
        Some(Value::Number(seconds)) if seconds.as_i64().is_some() => {
            let body = json!({ "allowance_seconds": seconds });
            send(http, Method::PUT, &segments, &[], Some(body)).await?
        }
        Some(_) => return Err(Failure::Transport("not an allowance".into())),
    };
    // The API answers `{ok: true, value}`; the page reads only the value.
    match reply.get("value") {
        Some(value @ Value::Object(_)) => Ok(value.clone()),
        _ => Err(Failure::Transport("unexpected slack-awake reply".into())),
    }
}

/// One request whose 2xx JSON body is answered as sent.
async fn send(
    http: &Http,
    method: Method,
    segments: &[&str],
    query: &[(&str, String)],
    body: Option<Value>,
) -> Result<Value, Failure> {
    let reply = send_raw(http, method, segments, query, body).await?;
    reply.ok_or_else(|| {
        Failure::Decoding(format!("{}: the answer is not JSON", path_text(segments)))
    })
}

/// One request: its 2xx body as JSON (`None` when it is not), or the route's refusal.
async fn send_raw(
    http: &Http,
    method: Method,
    segments: &[&str],
    query: &[(&str, String)],
    body: Option<Value>,
) -> Result<Option<Value>, Failure> {
    let path = path_text(segments);
    let url = http.url(segments, query);
    let reply = http.send(method, url, body.map(Body::Json), None, TIMEOUT, &path).await?;
    let object = reply.json();
    if !reply.ok() {
        return Err(worker_error(reply.status, object.as_ref()));
    }
    Ok(object)
}
