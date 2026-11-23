//! A joined machine's ask through a stub hub (a std `TcpListener` speaking HTTP/1.1), checked
//! against what the Cloud agent path answers for the same reply.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixListener;
use std::path::Path;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::*;
use crate::github_cli::{ask_agent, ask_here, gh_ask};

const SECRET: &str = "ghs_fake_installation_token_0000000000";
const CREDENTIAL: &str = "cmm_fake_machine_credential_0000";
const NO_AGENT: &str = "/nonexistent/cmux-agent.sock";

/// What the stub hub saw: the request line, the headers (lowercased names) and the body.
struct Seen {
    request_line: String,
    headers: Vec<(String, String)>,
    body: Value,
}

/// A hub that answers one request with `status` and `body`.
fn stub_hub(status: u16, body: Value) -> (String, std::thread::JoinHandle<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let mut headers = Vec::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let line = line.trim_end();
            if line.is_empty() {
                break;
            }
            let (k, v) = line.split_once(':').unwrap();
            headers.push((k.trim().to_ascii_lowercase(), v.trim().to_owned()));
        }
        let len: usize = headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .map_or(0, |(_, v)| v.parse().unwrap());
        let mut raw = vec![0; len];
        reader.read_exact(&mut raw).unwrap();
        let text = body.to_string();
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
            text.len()
        )
        .unwrap();
        Seen {
            request_line: request_line.trim_end().to_owned(),
            headers,
            body: serde_json::from_slice(&raw).unwrap(),
        }
    });
    (origin, thread)
}

/// The test POST: `JsonPoster` as production uses it, allowing the stub's `http://`.
fn post(url: &str, body: &Value, bearer: &str) -> Result<(u16, Value), String> {
    cmux_server::cloud_http::JsonPoster::allowing_http()?.post(url, body, Some(bearer))
}

fn joined(origin: &str) -> JoinedMachine {
    JoinedMachine { hub_origin: origin.to_owned(), credential: Zeroizing::new(CREDENTIAL.into()) }
}

/// The Cloud agent's reply line for the same API answer (`cloud::github::reply_for`), asked
/// over a fake agent socket: what the agent path gives.
fn agent_path(ask: &TokenAsk, status: u16, body: Value) -> Result<Minted, Refused> {
    let reply = reply_for(ask, &Answer::Http { status, body });
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("agent.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let agent = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let mut stream = stream;
        stream.write_all(format!("{reply}\n").as_bytes()).unwrap();
    });
    let out = ask_agent(&socket, ask);
    agent.join().unwrap();
    out
}

fn minted_body() -> Value {
    json!({
        "token": SECRET,
        "expires_at": "2026-11-23T03:00:00Z",
        "repo": "o/r",
        "permissions": gh_ask("o/r", false).permissions,
        "token_id": "0000000000000001",
    })
}

#[test]
fn a_joined_machine_with_no_agent_gets_the_token_the_agent_path_gives() {
    let ask = gh_ask("o/r", false);
    let (origin, hub) = stub_hub(200, minted_body());
    let machine = joined(&origin);
    let got = ask_here(Path::new(NO_AGENT), &ask, &|| Some(joined(&origin)), &post).unwrap();
    let seen = hub.join().unwrap();
    assert_eq!(got.token, SECRET);
    assert_eq!(got.token, agent_path(&ask, 200, minted_body()).unwrap().token);
    assert!(!format!("{machine:?}").contains(CREDENTIAL), "Debug redacts the credential");

    // The request: the machine route, the machine credential as the bearer, JSON, the ask's
    // fields and no team.
    assert_eq!(seen.request_line, format!("POST {MACHINE_TOKEN_PATH} HTTP/1.1"));
    let header = |name: &str| {
        seen.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str()).unwrap_or("")
    };
    assert_eq!(header("authorization"), format!("Bearer {CREDENTIAL}"));
    assert!(header("content-type").starts_with("application/json"));
    assert_eq!(seen.body["repo"], "o/r");
    assert_eq!(seen.body["permissions"], json!(ask.permissions));
    assert!(seen.body.get("team").is_none(), "never a team field: {}", seen.body);
}

#[test]
fn a_hub_policy_refusal_keeps_its_configure_page_and_reason_as_the_agent_path_does() {
    let ask = gh_ask("o/r", true);
    let body = json!({"error": {
        "code": "policy.denied",
        "message": "not granted",
        "reason": "repo_not_granted",
        "configure_url": "https://github.com/settings/installations/9",
    }});
    let (origin, hub) = stub_hub(403, body.clone());
    let got = ask_hub(&joined(&origin), &ask, &post).unwrap_err();
    hub.join().unwrap();
    let agent = agent_path(&ask, 403, body).unwrap_err();
    assert_eq!(got, agent);
    assert_eq!(got.explain("o/r"), agent.explain("o/r"));
    assert_eq!(got.code, "policy.denied");
    assert_eq!(got.reason.as_deref(), Some("repo_not_granted"));
    assert_eq!(got.configure_url.as_deref(), Some("https://github.com/settings/installations/9"));
}

#[test]
fn a_refused_join_credential_is_an_auth_error_that_says_to_join_again() {
    let ask = gh_ask("o/r", false);
    let body = json!({"error": {"code": "auth.unauthenticated", "message": "unknown credential"}});
    let (origin, hub) = stub_hub(401, body);
    let got = ask_hub(&joined(&origin), &ask, &post).unwrap_err();
    hub.join().unwrap();
    assert_eq!(got.code, "auth.unauthenticated");
    assert!(got.message.starts_with("unknown credential ("), "{}", got.message);
    assert!(got.message.contains("join this machine again"), "{}", got.message);
    assert!(!got.message.contains(CREDENTIAL));
    assert!(!crate::github_cli::retryable(&got.code));
}

#[test]
fn a_machine_neither_cloud_nor_joined_keeps_agent_unreachable() {
    let never = |_: &str, _: &Value, _: &str| -> Result<(u16, Value), String> {
        panic!("no join: nothing is posted")
    };
    let got = ask_here(Path::new(NO_AGENT), &gh_ask("o/r", false), &|| None, &never).unwrap_err();
    assert_eq!(got.code, "vm.agent_unreachable");
    // No reader installed in this process: the production reader answers no join.
    assert!(joined_now().is_none());
}

#[test]
fn an_unreachable_hub_is_a_transport_refusal() {
    let ask = gh_ask("o/r", false);
    let down = |_: &str, _: &Value, _: &str| -> Result<(u16, Value), String> { Err("down".into()) };
    let got = ask_hub(&joined("https://hub.example"), &ask, &down).unwrap_err();
    assert_eq!(got.code, "integration.unreachable");
}
