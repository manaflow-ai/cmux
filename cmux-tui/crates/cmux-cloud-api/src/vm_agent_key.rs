//! `vm.agent_key_create`: the cmux VM API's agent key mint (`POST /v1/agent-keys`, workers/cmux-vm
//! src/api/agents.ts) with the person's session, for the app's `vm.agent_key.create` (what `cmux vm
//! token create` asks the app for). The body and how the answer reads are cmux-cloud-config's
//! `agent_key` rules, which the app already asks over its FFI; this is only the HTTP call the app's
//! Swift used to make. Owner auth: `Authorization`, the team in `x-cmux-team` and `x-cmux-team-id`
//! (the VM API's name for it; a team id, no secret), and the build's space. Answers `{status, body}`
//! for every HTTP status, `body` the answer as text, so the app's reading of a refusal is unchanged.

use std::time::Duration;

use reqwest::Method;
use serde_json::{Map, Value, json};

use super::Failure;
use super::http::{Body, Http, path_text};

/// The mint's route under the VM API (cmux-cloud-config `agent_key::PATH`).
const SEGMENTS: [&str; 2] = ["v1", "agent-keys"];
/// The VM API's wait, as the app's own request had (cmux-cloud-config `agent_key::request`).
const TIMEOUT: Duration = Duration::from_secs(20);

pub(crate) async fn create(http: &Http, args: &Map<String, Value>) -> Result<Value, Failure> {
    let Some(body) = args.get("body").filter(|body| body.is_object()) else {
        return Err(Failure::Transport("no agent key body".into()));
    };
    let Some(team) = http.team.clone() else {
        return Err(Failure::Transport("an agent key is minted for a team: no team".into()));
    };
    let path = path_text(&SEGMENTS);
    let reply = http
        .send_named(
            Method::POST,
            http.url(&SEGMENTS, &[]),
            Some(Body::Json(body.clone())),
            (None, &[("x-cmux-team-id", team)]),
            TIMEOUT,
            &path,
        )
        .await?;
    Ok(json!({ "status": reply.status, "body": String::from_utf8_lossy(&reply.body) }))
}
