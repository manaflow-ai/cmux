//! `cmux login` with no app: a fake cmux.com config, a fake Stack and a fake platform on one
//! loopback port, and the real flow against them.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use super::*;

const ACCESS: &str = "stack-access-7f1e";
const REFRESH: &str = "stack-refresh-3b9d";
const TOKEN: &str = "cmux_pat_fake_9c4a";

#[derive(Clone, Debug)]
struct Seen {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: String,
}

/// How the fakes answer.
#[derive(Clone)]
struct Script {
    /// The answers to each poll, in order; the last repeats.
    polls: Vec<(u16, Value)>,
    /// The platform's answer to `POST /v1/tokens`.
    mint: (u16, Value),
}

impl Default for Script {
    fn default() -> Self {
        Self {
            polls: vec![
                (200, json!({"status": "waiting"})),
                (503, json!({})),
                (200, json!({"status": "success", "refresh_token": REFRESH})),
            ],
            mint: (
                201,
                json!({"token": TOKEN, "tokenInfo": {"id": "tok_1", "expiresAt": "2027-02-24T00:00:00.000Z"}}),
            ),
        }
    }
}

struct Fake {
    origin: String,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Fake {
    fn start(script: Script) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::<Seen>::new()));
        let (log, me) = (seen.clone(), origin.clone());
        std::thread::spawn(move || {
            let mut polls = 0usize;
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let Some(request) = read(&mut stream) else { continue };
                let (status, body) = match (request.method.as_str(), request.path.as_str()) {
                    ("GET", "/api/cli/config") => (
                        200,
                        json!({"auth": {
                            "apiUrl": me,
                            "projectId": "proj_fake",
                            "publishableClientKey": "pck_fake",
                            "confirmUrl": format!("{me}/handler/cli-auth-confirm"),
                        }}),
                    ),
                    ("POST", "/api/v1/auth/cli") => (
                        200,
                        json!({"polling_code": "poll_1", "login_code": "LOGIN-42", "expires_at": "soon"}),
                    ),
                    ("POST", "/api/v1/auth/cli/poll") => {
                        let answer = script.polls[polls.min(script.polls.len() - 1)].clone();
                        polls += 1;
                        answer
                    }
                    ("POST", "/api/v1/auth/sessions/current/refresh") => {
                        (200, json!({"access_token": ACCESS}))
                    }
                    ("POST", "/v1/tokens") => script.mint.clone(),
                    _ => (404, json!({})),
                };
                log.lock().unwrap().push(request);
                let body = body.to_string();
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Self { origin, seen }
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }

    fn env(&self) -> impl Fn(&str) -> Option<String> + use<> {
        let config = format!("{}/api/cli/config", self.origin);
        move |key| (key == "CMUX_CLI_CONFIG_URL").then(|| config.clone())
    }

    fn options(&self) -> Options {
        Options { platform: Some(self.origin.clone()), ..Options::default() }
    }
}

fn read(stream: &mut std::net::TcpStream) -> Option<Seen> {
    let mut reader = BufReader::new(stream.try_clone().ok()?);
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_whitespace();
    let (method, path) = (parts.next()?.to_owned(), parts.next()?.to_owned());
    let mut headers = HashMap::new();
    loop {
        let mut header = String::new();
        reader.read_line(&mut header).ok()?;
        let header = header.trim_end();
        if header.is_empty() {
            break;
        }
        let (key, value) = header.split_once(':')?;
        headers.insert(key.trim().to_ascii_lowercase(), value.trim().to_owned());
    }
    let length = headers.get("content-length").and_then(|l| l.parse().ok()).unwrap_or(0);
    let mut body = vec![0; length];
    reader.read_exact(&mut body).ok()?;
    Some(Seen { method, path, headers, body: String::from_utf8_lossy(&body).into_owned() })
}

fn run(fake: &Fake, options: &Options) -> (Result<Minted, Failure>, Vec<String>) {
    let mut notices = Vec::new();
    let env = fake.env();
    let result = execute(options, &env, Some("devbox"), Duration::from_millis(1), &mut |line| {
        notices.push(line.to_owned())
    });
    (result, notices)
}

#[test]
fn signs_in_by_link_and_mints_a_token_named_for_the_host() {
    let fake = Fake::start(Script::default());
    let options = Options { team: Some("team_42".into()), ..fake.options() };
    let (result, notices) = run(&fake, &options);
    let minted = result.unwrap();
    assert_eq!(
        minted,
        Minted {
            token: TOKEN.into(),
            name: "cmux login on devbox".into(),
            platform: fake.origin.clone(),
            expires_at: Some("2027-02-24T00:00:00.000Z".into()),
        }
    );
    // The confirm link is cmux.com's (the config's confirm origin), with Stack's login code.
    assert_eq!(notices.len(), 1, "{notices:?}");
    assert!(
        notices[0]
            .contains(&format!("{}/handler/cli-auth-confirm?login_code=LOGIN-42", fake.origin)),
        "{notices:?}"
    );

    let seen = fake.seen();
    let paths: Vec<_> = seen.iter().map(|s| format!("{} {}", s.method, s.path)).collect();
    assert_eq!(
        paths,
        [
            "GET /api/cli/config",
            "POST /api/v1/auth/cli",
            "POST /api/v1/auth/cli/poll",
            "POST /api/v1/auth/cli/poll",
            "POST /api/v1/auth/cli/poll",
            "POST /api/v1/auth/sessions/current/refresh",
            "POST /v1/tokens",
        ]
    );
    let start = &seen[1];
    assert_eq!(start.headers["x-stack-project-id"], "proj_fake");
    assert_eq!(start.headers["x-stack-publishable-client-key"], "pck_fake");
    assert_eq!(seen[5].headers["x-stack-refresh-token"], REFRESH);

    // The token is minted with the Stack session, for the team asked, with every scope.
    let mint = &seen[6];
    assert_eq!(mint.headers["authorization"], format!("Bearer {ACCESS}"));
    assert_eq!(mint.headers["x-cmux-team"], "team_42");
    let body: Value = serde_json::from_str(&mint.body).unwrap();
    assert_eq!(
        body,
        json!({"name": "cmux login on devbox", "scopes": ["machines", "chats", "usage"], "expiresInDays": 90})
    );
    // Neither Stack credential goes anywhere but its one header.
    for request in &seen {
        let elsewhere = format!("{} {} {}", request.path, request.body, {
            let mut h: Vec<_> = request
                .headers
                .iter()
                .filter(|(k, _)| !matches!(k.as_str(), "authorization" | "x-stack-refresh-token"))
                .map(|(k, v)| format!("{k}={v}"))
                .collect();
            h.sort();
            h.join(" ")
        });
        assert!(!elsewhere.contains(ACCESS) && !elsewhere.contains(REFRESH), "{elsewhere}");
    }
    assert!(seen[..6].iter().all(|s| !s.headers.contains_key("authorization")));
}

#[test]
fn no_team_sends_no_team_header_and_name_overrides_the_host() {
    let fake = Fake::start(Script::default());
    let options = Options { name: Some("ci runner".into()), ..fake.options() };
    let minted = run(&fake, &options).0.unwrap();
    assert_eq!(minted.name, "ci runner");
    let mint = fake.seen().into_iter().find(|s| s.path == "/v1/tokens").unwrap();
    assert!(!mint.headers.contains_key("x-cmux-team"));
    assert!(mint.body.contains("\"ci runner\""));
}

#[test]
fn an_expired_code_ends_the_sign_in_before_any_token() {
    let fake = Fake::start(Script {
        polls: vec![(200, json!({"status": "expired"}))],
        ..Script::default()
    });
    let failure = run(&fake, &fake.options()).0.unwrap_err();
    assert_eq!(failure.code, "auth.sign_in_ended");
    assert!(failure.message.contains("expired"), "{}", failure.message);
    assert!(fake.seen().iter().all(|s| s.path != "/v1/tokens" && !s.path.ends_with("/refresh")));
}

#[test]
fn polling_stops_at_its_bound() {
    let fake = Fake::start(Script {
        polls: vec![(200, json!({"status": "waiting"}))],
        ..Script::default()
    });
    let http = Http::new().unwrap();
    let project = Project {
        stack_base_url: fake.origin.clone(),
        project_id: "p".into(),
        publishable_client_key: "k".into(),
    };
    let failure = http
        .stack_login(
            &project,
            &fake.origin,
            Duration::from_millis(5),
            Duration::from_millis(60),
            &mut |_| {},
        )
        .unwrap_err();
    assert_eq!(failure.code, "auth.sign_in_ended");
    assert!(failure.message.contains("in time"), "{}", failure.message);
}

#[test]
fn a_platform_without_session_tokens_says_so() {
    let fake = Fake::start(Script {
        mint: (401, json!({"error": {"code": "auth.invalid", "message": "bad session"}})),
        ..Script::default()
    });
    let failure = run(&fake, &fake.options()).0.unwrap_err();
    assert_eq!(failure.code, "auth.invalid");
    assert!(failure.message.contains("did not accept your sign-in"), "{}", failure.message);
}

#[test]
fn an_answer_without_a_pat_is_not_a_token() {
    let fake =
        Fake::start(Script { mint: (201, json!({"token": "sk_other"})), ..Script::default() });
    let failure = run(&fake, &fake.options()).0.unwrap_err();
    assert_eq!(failure.code, "api.invalid_response");
}

#[test]
fn plain_http_off_this_machine_is_refused_before_any_request() {
    let env = |key: &str| {
        (key == "CMUX_CLI_CONFIG_URL").then(|| "http://cmux.example/api/cli/config".to_owned())
    };
    let failure =
        execute(&Options::default(), &env, None, Duration::ZERO, &mut |_| {}).unwrap_err();
    assert_eq!((failure.code.as_str(), failure.exit), ("cli.invalid_args", 2));
    let env = |_: &str| None;
    let options =
        Options { platform: Some("http://platform.example".into()), ..Options::default() };
    let failure = execute(&options, &env, None, Duration::ZERO, &mut |_| {}).unwrap_err();
    assert!(failure.message.contains("cmux platform"), "{}", failure.message);
}

#[test]
fn parse_takes_only_its_own_flags() {
    let words = |text: &str| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    assert_eq!(parse(&words("")).unwrap(), Options::default());
    assert_eq!(
        parse(&words("--device --name=box --team team_1 --platform https://p.example")).unwrap(),
        Options {
            device: true,
            help: false,
            name: Some("box".into()),
            team: Some("team_1".into()),
            platform: Some("https://p.example".into()),
        }
    );
    assert!(parse(&words("--help")).unwrap().help);
    assert!(parse(&words("--name")).is_err());
    assert!(parse(&words("--browser")).is_err());
    // Not ours: `vm sign-in` keeps them.
    assert_eq!(run_if_requested(&words("login --browser")), None);
    assert_eq!(run_if_requested(&words("logout")), None);
    assert_eq!(run_if_requested(&words("whoami")), None);
}

#[test]
fn names_and_export_lines() {
    let options = Options::default();
    assert_eq!(token_name(&options, Some("devbox")), "cmux login on devbox");
    assert_eq!(token_name(&options, Some("  ")), "cmux login on this machine");
    assert_eq!(token_name(&options, None), "cmux login on this machine");
    assert_eq!(token_name(&options, Some(&"h".repeat(200))).len(), "cmux login on ".len() + 64);
    assert_eq!(export_line("cmux_pat_abc-1.2"), "export CMUX_TOKEN=cmux_pat_abc-1.2");
    assert_eq!(export_line("cmux_pat_a'b $x"), "export CMUX_TOKEN='cmux_pat_a'\\''b $x'");
    let minted =
        Minted { token: TOKEN.into(), name: "n".into(), platform: "p".into(), expires_at: None };
    assert_eq!(
        json_answer(&minted),
        json!({"ok": true, "token": TOKEN, "name": "n", "platform": "p", "expiresAt": null})
    );
}

/// Seeded secrets on the wire (cmux_egress::capture): the Stack session rides only in
/// `Authorization` to the platform, the refresh token only in `x-stack-refresh-token` to Stack, the
/// team only in `x-cmux-team`. tests/egress_seeded.json names this test for
/// `cmux_tui::cli::device_login`.
#[test]
fn seeded_secrets_ride_only_in_their_headers() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    cmux_egress::capture::install().unwrap();
    let access = "SEEDdeviceLoginAccess-41c2";
    let refresh = "SEEDdeviceLoginRefresh-8e07";
    let team = "SEEDdeviceLoginTeam-d5a9";
    let http = Http::new().unwrap();
    // The capture server answers `200 {}`: no token, but the request went out whole.
    let platform = cmux_cloud_environment::PRODUCTION_PLATFORM;
    assert!(http.mint(platform, access, Some(team), "seeded").is_err());
    let project = Project {
        stack_base_url: cmux_cloud_environment::STACK_ORIGIN.into(),
        project_id: "proj".into(),
        publishable_client_key: "pck".into(),
    };
    let _ = http.send(&cli_sign_in::token_request(&project, refresh));

    let sent = cmux_egress::capture::requests_to("cmux-platform-production.debussy.workers.dev");
    assert!(sent.iter().any(|r| r.target == "/v1/tokens"), "{sent:?}");
    let sent = cmux_egress::capture::requests_to("api.stack-auth.com");
    assert!(sent.iter().any(|r| r.target.ends_with("/auth/sessions/current/refresh")), "{sent:?}");
    for (secret, place) in [
        (access, ": header authorization"),
        (refresh, ": header x-stack-refresh-token"),
        (team, ": header x-cmux-team"),
    ] {
        let places = cmux_egress::capture::leaks(secret);
        assert!(!places.is_empty(), "{secret}");
        assert!(places.iter().all(|p| p.ends_with(place)), "{secret}: {places:?}");
    }
}
