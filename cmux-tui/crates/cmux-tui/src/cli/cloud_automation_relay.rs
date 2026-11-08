//! `cmux cloud automation-relay`: one Cloud automation op as the signed-in
//! person, for the app's `cloud.automation` control method (what `cmux
//! automation --target cloud`, the Automations page and the Chief's
//! automation tool call). A CLI process has no account token, so the app
//! runs this with its own: one JSON request on stdin (the credential never
//! goes in argv), one JSON line out, always `{ok: true, value}` or `{ok:
//! false, error: {code, message, details?}}`. The rules (which ops pass,
//! where each goes, how an answer reads) are `cmux_cloud_wire::automation`'s.
//!
//! ```json
//! {"api": "https://api.cmux.dev", "credential": "…"|null, "request": {"op": "automation.list", "params": {}}}
//! ```

use std::io::{Read as _, Write as _};
use std::time::Duration;

use cmux_cloud_wire::automation;
use serde_json::Value;

use super::cloud_client_session::secure_origin;

/// The app's bound on one Cloud call.
const TIMEOUT: Duration = Duration::from_secs(20);

/// `Some(exit code)` when `args` is `cloud automation-relay`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "automation-relay" {
        return None;
    }
    let answer = if rest.is_empty() {
        let mut input = Vec::new();
        match std::io::stdin().read_to_end(&mut input) {
            Ok(_) => relay_blocking(&input),
            Err(_) => automation::refusal("invalid_params", "the request could not be read"),
        }
    } else {
        automation::refusal(
            "invalid_params",
            "cmux cloud automation-relay takes its request as JSON on stdin",
        )
    };
    let mut stdout = std::io::stdout().lock();
    let written = writeln!(stdout, "{answer}").and_then(|()| stdout.flush());
    Some(if written.is_ok() && answer.get("ok") == Some(&Value::Bool(true)) { 0 } else { 1 })
}

fn relay_blocking(input: &[u8]) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(relay(input)),
        Err(error) => automation::refusal("owner.unreachable", &error.to_string()),
    }
}

/// Forwards one stdin request.
pub(super) async fn relay(input: &[u8]) -> Value {
    let Ok(envelope) = serde_json::from_slice::<Value>(input) else {
        return automation::refusal("invalid_params", "the request is not a JSON object");
    };
    let request = envelope.get("request").cloned().unwrap_or(Value::Null);
    let routed = match automation::route(&request) {
        Ok(routed) => routed,
        Err(refusal) => return refusal,
    };
    let Some(credential) =
        envelope.get("credential").and_then(Value::as_str).filter(|c| !c.trim().is_empty())
    else {
        return automation::refusal(
            "automation.signed_out",
            "sign in to cmux to use Cloud automations",
        );
    };
    let api = match envelope.get("api").and_then(Value::as_str).map(|api| secure_origin(api.trim()))
    {
        Some(Ok(api)) => api,
        Some(Err(message)) => return automation::refusal("owner.unreachable", &message),
        None => return automation::refusal("owner.unreachable", "no cmux API origin"),
    };
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) =
        match cmux_cloud_client::http(&api, Some(credential.trim()), None, user_agent, TIMEOUT) {
            Ok(built) => built,
            Err(error) => return automation::refusal("owner.unreachable", &error.to_string()),
        };
    let sent = http.post(format!("{base}{}", routed.path)).json(&routed.body).send().await;
    let response = match sent {
        Ok(response) => response,
        Err(error) => {
            return automation::refusal("owner.unreachable", &error.without_url().to_string());
        }
    };
    let status = response.status().as_u16();
    match response.bytes().await {
        Ok(body) => automation::answer(status, &body),
        Err(error) => automation::refusal("owner.unreachable", &error.without_url().to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    /// A fake owner that answers every request with `reply` and keeps what it saw.
    fn owner(status: u16, reply: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&seen);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buffer = Vec::new();
                let mut chunk = [0_u8; 8192];
                loop {
                    let n = stream.read(&mut chunk).unwrap_or(0);
                    buffer.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&buffer).to_string();
                    if let Some(end) = text.find("\r\n\r\n") {
                        let length = text[..end]
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")
                                    .map(|v| v.trim().parse::<usize>().unwrap())
                            })
                            .unwrap_or(0);
                        if buffer.len() >= end + 4 + length {
                            break;
                        }
                    }
                    if n == 0 {
                        break;
                    }
                }
                log.lock().unwrap().push(String::from_utf8_lossy(&buffer).to_string());
                let _ = stream.write_all(
                    format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
                        .as_bytes(),
                );
            }
        });
        (origin, seen)
    }

    fn run(input: Value) -> Value {
        let _ = rustls::crypto::ring::default_provider().install_default();
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(relay(input.to_string().as_bytes()))
    }

    #[test]
    fn a_read_is_posted_to_v1_read_with_the_bearer() {
        let (api, seen) = owner(200, r#"{"ok":true,"value":{"automations":[]}}"#);
        let answer = run(
            json!({"api": api, "credential": "tok", "request": {"op": "automation.list", "params": {"limit": 50}}}),
        );
        assert_eq!(answer, json!({"ok": true, "value": {"automations": []}}));
        let seen = seen.lock().unwrap();
        assert!(seen[0].starts_with("POST /v1/read "), "{}", seen[0]);
        assert!(seen[0].to_ascii_lowercase().contains("authorization: bearer tok"));
    }

    #[test]
    fn signed_out_is_refused_before_any_call() {
        let (api, seen) = owner(200, "{}");
        let answer =
            run(json!({"api": api, "credential": null, "request": {"op": "automation.list"}}));
        assert_eq!(answer["error"]["code"], "automation.signed_out");
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn a_refused_op_never_reaches_the_owner() {
        let (api, seen) = owner(200, "{}");
        let answer = run(
            json!({"api": api, "credential": "tok", "request": {"op": "automation.deploy", "idempotency_key": "k"}}),
        );
        assert_eq!(answer["error"]["code"], "automation.op_not_allowed");
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn an_owner_that_does_not_answer_is_unreachable() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let api = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let answer =
            run(json!({"api": api, "credential": "tok", "request": {"op": "automation.list"}}));
        assert_eq!(answer["error"]["code"], "owner.unreachable");
    }

    #[test]
    fn plain_http_to_another_host_is_refused() {
        let answer = run(
            json!({"api": "http://example.com", "credential": "tok", "request": {"op": "automation.list"}}),
        );
        assert_eq!(answer["error"]["code"], "owner.unreachable");
    }
}
