//! The proxied route: the cmux API's own machine routes
//! (`/v1/cloud/machines/{machine}/exec` and `/fs/*`), which run the same
//! operation with the team's provider key, file operations as root. The answer
//! is the route's, status and body, so the app reads it as it reads that route.

use std::time::Duration;

use serde_json::{Value, json};

use super::super::cloud_client_session::TEAM_HEADER;
use super::{Answer, Op, Request};

const SHORT: Duration = Duration::from_secs(20);
const FILE: Duration = Duration::from_secs(120);

pub(super) async fn run(client: &reqwest::Client, request: &Request) -> Answer {
    let base = format!("{}/v1/cloud/machines/{}", request.api, request.machine);
    let path = request.path.clone().unwrap_or_default();
    let builder = match request.op {
        Op::Dir => client.get(format!("{base}/fs/dir")).query(&[("path", &path)]).timeout(SHORT),
        Op::Stat => client.get(format!("{base}/fs/stat")).query(&[("path", &path)]).timeout(SHORT),
        Op::Read => client.get(format!("{base}/fs/read")).query(&[("path", &path)]).timeout(FILE),
        Op::Remove => {
            client.delete(format!("{base}/fs/remove")).query(&[("path", &path)]).timeout(FILE)
        }
        Op::Mkdir => {
            client.post(format!("{base}/fs/mkdir")).json(&json!({ "path": path })).timeout(SHORT)
        }
        Op::Write => {
            let mut body = json!({ "path": path, "dataBase64": request.data_base64.clone().unwrap_or_default() });
            if let Some(mode) = request.mode {
                body["mode"] = json!(mode);
            }
            client.post(format!("{base}/fs/write")).json(&body).timeout(FILE)
        }
        Op::Exec => {
            let timeout = request.exec_timeout_ms();
            client
                .post(format!("{base}/exec"))
                .json(&json!({ "command": request.command.clone().unwrap_or_default(), "timeoutMs": timeout }))
                .timeout(Duration::from_millis(timeout) + Duration::from_secs(5))
        }
    };
    let mut builder = builder
        .bearer_auth(&request.credential)
        .header("X-Cmux-Client", "cmux-mac")
        .header("X-Cmux-App-Version", request.app_version.as_deref().unwrap_or("cmux-next"));
    if let Some(team) = &request.team {
        builder = builder.header(TEAM_HEADER, team);
    }
    let response = match builder.send().await {
        Ok(response) => response,
        Err(e) if e.is_timeout() => {
            return Answer::error(0, "timed_out", "the cmux API did not answer in time");
        }
        Err(e) => {
            return Answer::error(
                0,
                "transport",
                &format!("the cmux API did not answer: {}", e.without_url()),
            );
        }
    };
    let status = response.status().as_u16();
    let code =
        response.headers().get("x-cmux-vm-error").and_then(|v| v.to_str().ok()).map(str::to_owned);
    let body: Value = response.json().await.unwrap_or(Value::Null);
    // The route's answer as it gave it: the app reads a refusal (a plan's upgrade fields
    // included) exactly as it reads that route's.
    Answer { status, body, code }
}
