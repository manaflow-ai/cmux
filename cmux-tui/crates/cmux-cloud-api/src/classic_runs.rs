//! Sandboxed Runs that classic Cloud runs (`/api/runs`, hq#3367), where the cmux app opens no
//! chat for them:
//!
//! - an incognito send's Run (#39022 review at 946e940e, F1). A daemon Run is a Cloud chat the
//!   app opens in the machine's workspace, an ordinary one that shows the prompt and the reply
//!   outside the incognito window and keeps them in its chat history; classic Cloud runs the task
//!   on its own VM and answers only the receipt, as every sandboxed send did before the daemon ran
//!   Runs. An incognito create without the app's classic session is refused: it never falls back
//!   to a daemon Run.
//! - a Run a person made before the daemon ran Runs, drained to its end after an upgrade: the app
//!   keeps following it from its saved list, and a Run the daemon never made is classic Cloud's.

use std::time::Duration;

use reqwest::Method;
use serde_json::{Map, Value};

use super::http::{Auth, Http};
use super::{Failure, Request, optional_int, optional_text, text};

/// The server holds one wait this long at most.
const WAIT_LIMIT_MS: i64 = 10_000;

/// The arg that marks a wait or cancel sent without the app's classic session because it could not
/// be read ([`attach`]), so a Run the daemon does not know is no answer ([`answered`]).
const UNREAD: &str = "classicUnread";

/// Whether `request` is one classic Cloud may take: a wait or cancel (of a Run the daemon may
/// never have made) or an incognito send's create.
fn takes_classic(request: &Request) -> bool {
    matches!(request.call.as_str(), "runs.wait" | "runs.cancel")
        || is_incognito_create(&request.call, &request.args)
}

/// Puts the app's classic Cloud session (`classic`: `{api, access, refresh, team}`, sent beside
/// every Runs call of a client that has one) where a call classic Cloud may take reads it: the
/// Stack credential and refresh, `args.classicApi` and `args.classicTeam` (the Run's Stack team).
/// Any other call drops it, so its own credential and team go unchanged. A session the app could
/// not read (`unread`, or one with no refresh token) marks a wait or cancel, so [`answered`] never
/// reads the daemon's `run_not_found` as the Run's end (#39022 audit at 855beb0d).
pub fn attach(request: &mut Request, classic: Option<&Value>, unread: bool) {
    if !takes_classic(request) {
        return;
    }
    let field = |name: &str| {
        classic.and_then(|c| c.get(name)).and_then(Value::as_str).map(str::trim).unwrap_or("")
    };
    let (api, access, refresh) = (field("api"), field("access"), field("refresh"));
    if api.is_empty() || access.is_empty() || refresh.is_empty() {
        if unread || classic.is_some() {
            request.args.insert(UNREAD.into(), Value::Bool(true));
        }
        return;
    }
    request.credential = access.to_owned();
    request.refresh = Some(refresh.to_owned());
    request.args.insert("classicApi".into(), Value::from(api));
    request.args.insert("classicTeam".into(), Value::from(field("team")));
}

/// The call's answer as the app reads it: a wait or cancel sent without a classic session the app
/// could not read, which the daemon answers `run_not_found`, is `transport` (read again), never the
/// end of a classic Run the app still follows.
pub fn answered(request: &Request, result: Result<Value, Failure>) -> Result<Value, Failure> {
    let unread = request.args.get(UNREAD).and_then(Value::as_bool) == Some(true);
    match result {
        Err(Failure::Http { status: 404, code: Some(code), .. })
            if unread && code == "run_not_found" =>
        {
            Err(Failure::Transport(format!(
                "cloud.{}: the Cloud session could not be read",
                request.call
            )))
        }
        other => other,
    }
}

/// Whether `call` is an incognito send's create (`runs.create` with `incognito: true`), which
/// classic Cloud runs ([`drain`]), never the daemon.
pub fn is_incognito_create(call: &str, args: &Map<String, Value>) -> bool {
    call == "runs.create" && args.get("incognito").and_then(Value::as_bool) == Some(true)
}

/// An incognito send's `runs.create`, or `runs.wait` or `runs.cancel` for a Run the daemon does
/// not know, sent to classic Cloud: the app's classic API (`args.classicApi`) and team
/// (`args.classicTeam`, the Run's), with the Stack session the request carries (`credential` and
/// `refresh`). A request without them sends nothing: a wait or cancel finds no classic Run of the
/// app's there, and an incognito create is refused rather than started as an ordinary chat.
pub async fn drain(request: &Request) -> Result<Value, Failure> {
    let api = optional_text(&request.args, "classicApi").filter(|api| !api.is_empty());
    let (Some(api), Some(_)) = (api, request.refresh.as_deref().filter(|r| !r.is_empty())) else {
        if request.call == "runs.create" {
            return Err(Failure::http(
                409,
                Some("run_incognito_unavailable".into()),
                Some("an incognito Run needs the cmux app's Cloud session".into()),
            ));
        }
        return Err(Failure::http(
            404,
            Some("run_not_found".into()),
            Some("no such Run on this Mac".into()),
        ));
    };
    let team = optional_text(&request.args, "classicTeam").filter(|t| !t.is_empty());
    let http = Http::new(&Request {
        auth: Auth::Stack,
        api: api.to_owned(),
        team: team.map(str::to_owned),
        ..request.clone()
    })?;
    match request.call.as_str() {
        "runs.create" if is_incognito_create(&request.call, &request.args) => {
            create(&http, &request.args).await
        }
        "runs.wait" => wait(&http, &request.args).await,
        "runs.cancel" => cancel(&http, &request.args).await,
        other => Err(Failure::Transport(format!("{other} is never sent to classic Cloud"))),
    }
}

/// `POST /api/runs` (`environment: sandboxed`): the task on classic Cloud's own VM. The send's
/// idempotency key makes a retry after a lost answer return the same Run, never a second one.
async fn create(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let mut body = Map::new();
    body.insert("environment".into(), Value::from("sandboxed"));
    body.insert("task".into(), Value::from(text(args, "task")?));
    for name in ["agent", "image"] {
        if let Some(value) = optional_text(args, name).filter(|value| !value.is_empty()) {
            body.insert(name.into(), Value::from(value));
        }
    }
    if let Some(timeout) = optional_int(args, "timeoutMs") {
        body.insert("timeoutMs".into(), Value::from(timeout));
    }
    let key = optional_text(args, "idempotencyKey").filter(|key| !key.is_empty());
    let sent = (Some(Value::Object(body)), key);
    http.classic(Method::POST, &["api", "runs"], &[], sent, Duration::from_secs(20)).await
}

/// `GET /api/runs/:id/wait?timeoutMs=`: the snapshot once the Run is terminal or after the wait
/// (at most 10 s), with its receipt when it has one.
async fn wait(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    let held = optional_int(args, "timeoutMs").unwrap_or(WAIT_LIMIT_MS).clamp(0, WAIT_LIMIT_MS);
    let query = [("timeoutMs", held.to_string())];
    let bound = Duration::from_millis(u64::try_from(held).unwrap_or(0).saturating_add(10_000));
    http.classic(Method::GET, &["api", "runs", id, "wait"], &query, (None, None), bound).await
}

/// `POST /api/runs/:id/cancel`: the server destroys the Run's VM before it answers.
async fn cancel(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let id = text(args, "id")?;
    let bound = Duration::from_secs(60);
    http.classic(Method::POST, &["api", "runs", id, "cancel"], &[], (None, None), bound).await
}

/// What the app sends and what each call takes (moved from the app's Swift forwarder to here: the
/// Cloud core's decisions are Rust's, `.github/language-boundaries.toml` `cloud-core-swift-minimal`).
#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::{Failure, answered};

    /// `cmux cloud api`'s request line as the app sends it, read by [`crate::parse`].
    fn sent(call: &str, args: Value, classic: Option<Value>, unread: bool) -> crate::Request {
        let mut line = json!({"call": call, "api": "https://worker.invalid", "auth": "owner",
            "credential": "worker-access", "team": "team_cmux", "args": args});
        if let Some(classic) = classic {
            line["classic"] = classic;
        }
        if unread {
            line["classic_unread"] = json!(true);
        }
        crate::parse(line.to_string().as_bytes()).unwrap().0
    }

    fn session() -> Value {
        json!({"api": "https://classic.invalid", "access": "stack-access",
            "refresh": "stack-refresh", "team": "team_stack"})
    }

    #[test]
    fn a_wait_a_cancel_and_an_incognito_create_take_the_classic_session_nothing_else() {
        for (call, args) in [
            ("runs.wait", json!({"id": "r-old", "timeoutMs": 1})),
            ("runs.cancel", json!({"id": "r-old"})),
            ("runs.create", json!({"task": "private", "incognito": true})),
        ] {
            let request = sent(call, args, Some(session()), false);
            assert_eq!(request.credential, "stack-access", "{call}");
            assert_eq!(request.refresh.as_deref(), Some("stack-refresh"), "{call}");
            assert_eq!(request.args["classicApi"], "https://classic.invalid", "{call}");
            assert_eq!(request.args["classicTeam"], "team_stack", "{call}");
            assert_eq!(request.team.as_deref(), Some("team_cmux"), "the daemon's own team stays");
        }
        for (call, args) in [("runs.create", json!({"task": "hi"})), ("vm.domains", json!({}))] {
            let request = sent(call, args, Some(session()), false);
            assert_eq!(request.credential, "worker-access", "{call}");
            assert_eq!(request.refresh, None, "{call}");
            assert!(!request.args.contains_key("classicApi"), "{call}");
            assert!(!request.args.contains_key("classicUnread"), "{call}");
        }
    }

    #[test]
    fn a_session_the_app_could_not_read_never_ends_a_classic_run() {
        let not_found =
            || Err(Failure::http(404, Some("run_not_found".into()), Some("no such Run".into())));
        let unread = sent("runs.wait", json!({"id": "r-old", "timeoutMs": 1}), None, true);
        assert!(!unread.args.contains_key("classicApi"));
        assert!(matches!(answered(&unread, not_found()), Err(Failure::Transport(_))));
        // A session with no refresh token is no session either.
        let mut empty = session();
        empty["refresh"] = json!("");
        let empty = sent("runs.cancel", json!({"id": "r-old"}), Some(empty), false);
        assert!(matches!(answered(&empty, not_found()), Err(Failure::Transport(_))));
        // A client with no classic session at all: the daemon's answer stands.
        let none = sent("runs.wait", json!({"id": "r-x", "timeoutMs": 1}), None, false);
        assert!(matches!(answered(&none, not_found()), Err(Failure::Http { status: 404, .. })));
        // A Run the daemon knows answers as it is.
        assert_eq!(answered(&unread, Ok(json!({"run": {}}))).unwrap(), json!({"run": {}}));
    }
}
