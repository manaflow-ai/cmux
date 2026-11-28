use super::*;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// One request the stub received.
#[derive(Debug, Clone)]
pub(crate) struct Seen {
    pub(crate) method: String,
    pub(crate) path: String,
    pub(crate) headers: Vec<(String, String)>,
    pub(crate) body: String,
}

impl Seen {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }
}

/// A loopback HTTP server answering each request with `route(origin, request)`; the
/// origin and every request it saw.
pub(crate) fn stub(
    route: impl Fn(&str, &Seen) -> (u16, Value) + Send + 'static,
) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let (log, at) = (seen.clone(), origin.clone());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut raw = Vec::new();
            let mut buf = [0u8; 4096];
            let request = loop {
                let n = stream.read(&mut buf).unwrap_or(0);
                if n == 0 {
                    break None;
                }
                raw.extend_from_slice(&buf[..n]);
                let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") else {
                    continue;
                };
                let head = String::from_utf8_lossy(&raw[..end]).into_owned();
                let mut lines = head.split("\r\n");
                let mut first = lines.next().unwrap_or("").split(' ');
                let (method, path) =
                    (first.next().unwrap_or("").to_owned(), first.next().unwrap_or("").to_owned());
                let headers: Vec<(String, String)> = lines
                    .filter_map(|l| l.split_once(':'))
                    .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_owned()))
                    .collect();
                let length = headers
                    .iter()
                    .find(|(k, _)| k == "content-length")
                    .and_then(|(_, v)| v.parse::<usize>().ok())
                    .unwrap_or(0);
                if raw.len() < end + 4 + length {
                    continue;
                }
                let body = String::from_utf8_lossy(&raw[end + 4..end + 4 + length]).into_owned();
                break Some(Seen { method, path, headers, body });
            };
            let Some(request) = request else { continue };
            log.lock().unwrap().push(request.clone());
            let (status, body) = route(&at, &request);
            let body = body.to_string();
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
        }
    });
    (origin, seen)
}

fn config(origin: &str, key: Option<&str>) -> Value {
    let mut auth = json!({
        "apiUrl": format!("{origin}/api/v1"),
        "projectId": "project-1",
        "confirmUrl": "https://sign-in.example/handler/cli-auth-confirm",
    });
    if let Some(key) = key {
        auth["publishableClientKey"] = json!(key);
    }
    json!({ "version": 4, "auth": auth })
}

/// The Stack side of a login: config, start, `waiting` polls, then `last`, then refresh.
fn stack(
    key: Option<&'static str>,
    waiting: usize,
    last: Value,
    refresh: (u16, Value),
) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let polls = AtomicUsize::new(0);
    stub(move |origin, r| match (r.method.as_str(), r.path.as_str()) {
        ("GET", "/api/cli/config") => (200, config(origin, key)),
        ("POST", "/api/v1/auth/cli") => {
            (200, json!({ "polling_code": "poll-1", "login_code": "a/b&c+" }))
        }
        ("POST", "/api/v1/auth/cli/poll") => {
            if polls.fetch_add(1, Ordering::SeqCst) < waiting {
                (200, json!({ "status": "waiting" }))
            } else {
                (200, last.clone())
            }
        }
        ("POST", "/api/v1/auth/sessions/current/refresh") => refresh.clone(),
        _ => (404, json!({ "error": "no route" })),
    })
}

const FAST: Duration = Duration::from_millis(1);
const LONG: Duration = Duration::from_secs(30);

#[test]
fn signs_in_through_the_browser_and_returns_an_access_token() {
    let (origin, seen) = stack(
        Some("pck_key"),
        2,
        json!({ "status": "success", "refresh_token": "refresh-1" }),
        (200, json!({ "access_token": "access-1" })),
    );
    let mut shown = None;
    let token = sign_in(&format!("{origin}/api/cli/config"), FAST, LONG, |url| {
        shown = Some(url.to_owned())
    })
    .unwrap();
    assert_eq!(token, "access-1");
    assert_eq!(
        shown.as_deref(),
        Some("https://sign-in.example/handler/cli-auth-confirm?login_code=a%2Fb%26c%2B")
    );
    let seen = seen.lock().unwrap().clone();
    let paths: Vec<&str> = seen.iter().map(|r| r.path.as_str()).collect();
    assert_eq!(
        paths,
        [
            "/api/cli/config",
            "/api/v1/auth/cli",
            "/api/v1/auth/cli/poll",
            "/api/v1/auth/cli/poll",
            "/api/v1/auth/cli/poll",
            "/api/v1/auth/sessions/current/refresh",
        ]
    );
    assert!(seen[0].header("x-stack-project-id").is_none());
    for r in &seen[1..] {
        assert_eq!(r.header("x-stack-project-id"), Some("project-1"), "{r:?}");
        assert_eq!(r.header("x-stack-access-type"), Some("client"), "{r:?}");
        assert_eq!(r.header("x-stack-publishable-client-key"), Some("pck_key"), "{r:?}");
    }
    let start: Value = serde_json::from_str(&seen[1].body).unwrap();
    assert_eq!(start["expires_in_millis"], json!(LONG.as_millis() as u64));
    let poll: Value = serde_json::from_str(&seen[2].body).unwrap();
    assert_eq!(poll, json!({ "polling_code": "poll-1" }));
    assert_eq!(seen[5].header("x-stack-refresh-token"), Some("refresh-1"));
}

#[test]
fn a_project_without_a_publishable_key_sends_none() {
    let (origin, seen) = stack(
        None,
        0,
        json!({ "status": "success", "refresh_token": "refresh-1" }),
        (200, json!({ "access_token": "access-1" })),
    );
    assert_eq!(
        sign_in(&format!("{origin}/api/cli/config"), FAST, LONG, |_| {}).unwrap(),
        "access-1"
    );
    assert!(seen
        .lock()
        .unwrap()
        .iter()
        .all(|r| r.header("x-stack-publishable-client-key").is_none()));
}

#[test]
fn an_expired_or_used_login_stops_with_its_status() {
    for status in ["expired", "used"] {
        let (origin, _) =
            stack(None, 1, json!({ "status": status }), (200, json!({ "access_token": "a" })));
        let e = sign_in(&format!("{origin}/api/cli/config"), FAST, LONG, |_| {}).unwrap_err();
        assert!(e.to_string().contains(status), "{e}");
    }
}

#[test]
fn an_unconfirmed_login_gives_up_at_its_deadline() {
    let (origin, _) = stack(
        None,
        usize::MAX,
        json!({ "status": "waiting" }),
        (200, json!({ "access_token": "a" })),
    );
    let e = sign_in(
        &format!("{origin}/api/cli/config"),
        Duration::from_millis(5),
        Duration::from_millis(40),
        |_| {},
    )
    .unwrap_err();
    assert!(e.to_string().contains("not confirmed"), "{e}");
}

#[test]
fn a_refused_refresh_or_a_success_without_a_token_is_an_error() {
    let (origin, _) = stack(
        None,
        0,
        json!({ "status": "success", "refresh_token": "refresh-1" }),
        (401, json!({ "code": "REFRESH_TOKEN_NOT_FOUND", "error": "gone" })),
    );
    let e = sign_in(&format!("{origin}/api/cli/config"), FAST, LONG, |_| {}).unwrap_err();
    assert!(e.to_string().contains("401") && e.to_string().contains("gone"), "{e}");
    let (origin, _) =
        stack(None, 0, json!({ "status": "success" }), (200, json!({ "access_token": "a" })));
    let e = sign_in(&format!("{origin}/api/cli/config"), FAST, LONG, |_| {}).unwrap_err();
    assert!(e.to_string().contains("refresh_token"), "{e}");
}

#[test]
fn the_configuration_must_name_tls_urls_and_header_safe_values() {
    for (field, bad) in [
        ("apiUrl", "http://stack.example/api/v1"),
        ("confirmUrl", "javascript:alert(1)"),
        ("projectId", "p\r\nx-evil: 1"),
        ("publishableClientKey", "k k"),
    ] {
        let (origin, _) = stub(move |origin, _| {
            let mut c = config(origin, Some("pck_key"));
            c["auth"][field] = json!(bad);
            (200, c)
        });
        assert!(load_config(&format!("{origin}/api/cli/config")).is_err(), "{field}={bad}");
    }
    let (origin, _) = stub(|_, _| (503, json!({ "error": "cli_auth_unavailable" })));
    let e = load_config(&format!("{origin}/api/cli/config")).unwrap_err();
    assert!(e.to_string().contains("cli_auth_unavailable"), "{e}");
}

#[test]
fn the_login_code_is_appended_to_the_confirmation_query() {
    assert_eq!(
        confirmation_url("https://a.example/c?x=1", "k/1+").unwrap(),
        "https://a.example/c?x=1&login_code=k%2F1%2B"
    );
    assert!(confirmation_url("https://a.example/c#f", "k").is_err());
}

#[test]
fn without_a_token_file_the_token_comes_from_the_browser_sign_in() {
    let signed_in = access_token_or(None, || Ok("from-browser".into())).unwrap();
    assert_eq!(signed_in, "from-browser");
    // A token file is still read, and then no sign-in starts.
    let dir =
        std::env::temp_dir().join(format!("cmux-screen-host-token-file-{}", std::process::id()));
    let path = dir.join("token");
    cmux_hub_host::identity::write_private(&path, b" tok-1\n").unwrap();
    let token =
        access_token_or(Some(path.to_str().unwrap()), || panic!("signed in despite a token file"))
            .unwrap();
    assert_eq!(token, "tok-1");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_default_configuration_is_the_cmux_web_deployment_over_tls() {
    assert!(Url::parse(CONFIG_URL).unwrap().tls);
}
