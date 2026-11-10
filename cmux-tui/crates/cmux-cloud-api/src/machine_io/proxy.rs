//! The proxied route: the cmux API's own machine routes
//! (`/v1/cloud/machines/{machine}/exec` and `/fs/*`), which run the same
//! operation with the team's provider key, file operations as root. The answer
//! is the route's, status and body, so the app reads it as it reads that route.

use std::time::Duration;

use serde_json::{Value, json};

use super::{Answer, Op, Request};
use crate::session::TEAM_HEADER;

const SHORT: Duration = Duration::from_secs(20);
const FILE: Duration = Duration::from_secs(120);

pub(super) async fn run(client: &reqwest::Client, request: &Request) -> Answer {
    let base = format!("{}/v1/cloud/machines/{}", request.api, request.machine);
    let path = request.path.clone().unwrap_or_default();
    // `?path=` encoded as the app's own client encodes it (every reserved character escaped).
    let with_path = |op: &str| {
        let mut url = reqwest::Url::parse(&format!("{base}/fs/{op}")).ok();
        if let Some(url) = url.as_mut() {
            url.query_pairs_mut().append_pair("path", &path);
        }
        url.map_or_else(|| format!("{base}/fs/{op}"), String::from)
    };
    // Each request ends by the call's deadline (`crate::perform_by`); one with no time left is
    // never sent.
    let (short, file) =
        match (crate::within(SHORT, Duration::ZERO), crate::within(FILE, Duration::ZERO)) {
            (Some(short), Some(file)) => (short, file),
            _ => {
                return Answer::error(
                    0,
                    "timed_out",
                    "the call reached its deadline; nothing was sent",
                );
            }
        };
    let builder = match request.op {
        Op::Dir => client.get(with_path("dir")).timeout(short),
        Op::Stat => client.get(with_path("stat")).timeout(short),
        Op::Read => client.get(with_path("read")).timeout(file),
        Op::Remove => client.delete(with_path("remove")).timeout(file),
        Op::Mkdir => {
            client.post(format!("{base}/fs/mkdir")).json(&json!({ "path": path })).timeout(short)
        }
        Op::Write => {
            let mut body = serde_json::Map::new();
            body.insert("path".into(), json!(path));
            body.insert("dataBase64".into(), json!(request.data_text()));
            if let Some(mode) = request.mode {
                body.insert("mode".into(), json!(mode));
            }
            client.post(format!("{base}/fs/write")).json(&body).timeout(file)
        }
        Op::Exec => {
            let want = Duration::from_millis(request.exec_timeout_ms());
            let Some(fit) = crate::within(want, Duration::from_secs(5)) else {
                return Answer::error(
                    0,
                    "timed_out",
                    "the call reached its deadline; nothing was sent",
                );
            };
            let timeout = u64::try_from(fit.as_millis()).unwrap_or(u64::MAX);
            client
                .post(format!("{base}/exec"))
                .json(&json!({ "command": request.command.clone().unwrap_or_default(), "timeoutMs": timeout }))
                .timeout(Duration::from_millis(timeout).saturating_add(Duration::from_secs(5)))
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
        Err(e) if request.local_only && e.is_connect() => {
            return Answer::error(0, "no_backend", "the local cmux API is not running");
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
    let body = match crate::http::bounded_body(response, crate::MAX_ANSWER_BYTES).await {
        // Code `too_large`, naming this route's own limit: a read into a local file may come to
        // more than a direct read can, but not through here.
        Err(crate::http::BodyError::TooLarge(limit)) => {
            return Answer::too_large(u64::try_from(limit).unwrap_or(u64::MAX));
        }
        // A 2xx is an answer only when it arrived whole and reads as JSON (or is empty);
        // a refusal's body is kept as it reads, since its status already says what happened.
        Err(crate::http::BodyError::Read(_)) if (200..300).contains(&status) => {
            return Answer::error(0, "transport", "the cmux API's answer was cut off");
        }
        Err(crate::http::BodyError::Read(_)) => Value::Null,
        Ok(bytes) if bytes.iter().all(u8::is_ascii_whitespace) => Value::Null,
        Ok(bytes) => match serde_json::from_slice(&bytes) {
            Ok(body) => body,
            Err(_) if (200..300).contains(&status) => {
                return Answer::error(0, "decoding", "the cmux API's answer is not JSON");
            }
            Err(_) => Value::Null,
        },
    };
    // The route's answer as it gave it: the app reads a refusal (a plan's upgrade fields
    // included) exactly as it reads that route's.
    Answer { status, body, code, file: None }
}
