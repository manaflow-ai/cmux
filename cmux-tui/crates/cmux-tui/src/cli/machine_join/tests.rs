use std::io::{Read, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex, mpsc};

use super::*;

pub(super) const CREDENTIAL: &str = "cmux-access-credential-0123456789";
pub(super) const TOKEN: &str = "cmj_AbCdEfGh0123456789_-xyz";
const MACHINE_CREDENTIAL: &str = "cmm_secret-machine-credential-0123";

pub(super) fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

pub(super) fn parsed(words: &[&str]) -> Option<Result<Command, UsageError>> {
    parse(&strings(words))
}

pub(super) fn command(words: &[&str]) -> Command {
    parsed(words).expect("ours").expect("parses")
}

/// One answer per request; the handler sees the request line plus headers and body.
pub(super) type Handler = Arc<dyn Fn(&str) -> (u16, String) + Send + Sync>;

/// A fake cmux platform on a loopback port: every request goes to `handler`
/// and is recorded, raw, on the returned channel.
pub(super) fn fake(handler: Handler) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let (sender, requests) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 4096];
            let request = loop {
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
                    if buffer.len() >= end + 4 + length || n == 0 {
                        break text;
                    }
                } else if n == 0 {
                    break text;
                }
            };
            let (status, body) = handler(&request);
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
            if sender.send(request).is_err() {
                return;
            }
        }
    });
    (origin, requests)
}

pub(super) fn platform(origin: &str) -> Platform {
    Platform::new(origin.to_owned(), CREDENTIAL.to_owned(), Duration::from_secs(5)).unwrap()
}

pub(super) fn mint_answer(expires_at_ms: u64) -> String {
    json!({
        "token": TOKEN,
        "joinTokenId": "jt_1",
        "expiresAt": expires_at_ms,
        "teamId": "team_1",
        "label": "lane-vm-3",
    })
    .to_string()
}

pub(super) fn entry(join_token_id: &str) -> Value {
    json!({
        "machineId": "m_1",
        "label": "lane-vm-3",
        "role": "member",
        "createdAt": "2026-10-29T03:00:00Z",
        "lastHeartbeat": now_ms(),
        "revoked": false,
        "joinTokenId": join_token_id,
        "meshPeerId": "inst_1",
        "platform": "linux",
        "hostname": "lane-vm-3.internal",
        "mintedBy": {"kind": "user", "name": "leo@example.com"},
    })
}

/// A platform that mints, then lists `listed` (each read pops one answer, the last repeats).
fn joining(listed: Vec<Value>, expires_at_ms: u64) -> Handler {
    let listed = Mutex::new(listed);
    Arc::new(move |request: &str| {
        if request.starts_with("POST /v1/machines/join-tokens ") {
            return (200, mint_answer(expires_at_ms));
        }
        if request.starts_with("GET /v1/machines/credentials ") {
            let mut listed = listed.lock().unwrap();
            let next = if listed.len() > 1 { listed.remove(0) } else { listed[0].clone() };
            return (200, next.to_string());
        }
        (404, json!({"code": "machine.not_found"}).to_string())
    })
}

pub(super) struct Ran {
    pub code: Result<i32, Failure>,
    pub out: String,
    pub asked: Vec<String>,
}

pub(super) fn run_with(
    words: &[&str],
    origin: &str,
    output: OutputMode,
    interactive: bool,
    answer: bool,
    interrupt: impl Future<Output = ()>,
) -> Ran {
    let command = command(words);
    let platform = platform(origin);
    let mut out = Vec::new();
    let mut asked = Vec::new();
    let mut confirm = |question: &str| {
        asked.push(question.to_owned());
        answer
    };
    let mut read_value = |_: &str| -> Result<zeroize::Zeroizing<String>, String> {
        Err("no value in this test".into())
    };
    let mut ssh =
        |_: &bootstrap::SshPlan| -> std::io::Result<i32> { panic!("no ssh in this test") };
    let mut hooks = Hooks { confirm: &mut confirm, read_value: &mut read_value, ssh: &mut ssh };
    let options = RunOptions { interactive, every: Duration::from_millis(20) };
    let code = run(&command, &platform, output, options, &mut out, &mut hooks, interrupt);
    Ran { code, out: String::from_utf8(out).unwrap(), asked }
}

pub(super) fn never() -> impl Future<Output = ()> {
    std::future::pending::<()>()
}

pub(super) fn far() -> u64 {
    now_ms() + 600_000
}

pub(super) fn no_secret(text: &str) {
    for secret in [TOKEN, CREDENTIAL, MACHINE_CREDENTIAL, "cmj_", "cmm_"] {
        assert!(!text.contains(secret), "{secret} leaked in {text:?}");
    }
}

#[test]
fn selected_team_uses_the_platform_team_header() {
    let (origin, requests) = fake(Arc::new(|_| (200, "[]".into())));
    let platform = platform(&origin).with_team(Some("team_0123456789abcdef0123".into()));
    platform.post("/v1/machines/credentials", json!({})).unwrap();
    let request = requests.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(
        request
            .lines()
            .any(|line| line.eq_ignore_ascii_case("x-cmux-team: team_0123456789abcdef0123"))
    );
    assert!(
        !request
            .lines()
            .any(|line| line.eq_ignore_ascii_case("x-cmux-team-id: team_0123456789abcdef0123"))
    );
}

#[test]
fn add_without_a_host_is_ours_and_with_one_is_the_apps_card() {
    assert_eq!(command(&["machine", "add"]).verb, Verb::Add(AddArgs::default()));
    assert_eq!(
        command(&["machine", "add", "--name", "lane-vm-3", "--ttl", "5m", "--no-wait"]).verb,
        Verb::Add(AddArgs {
            name: Some("lane-vm-3".into()),
            ttl: Some(300),
            wait: Some(false),
            ..AddArgs::default()
        })
    );
    assert_eq!(
        command(&["machine", "add", "--name=a", "--ttl=600", "--wait"]).verb,
        Verb::Add(AddArgs {
            name: Some("a".into()),
            ttl: Some(600),
            wait: Some(true),
            ..AddArgs::default()
        })
    );
    for host in [
        vec!["machine", "add", "mini-7"],
        vec!["machine", "add", "--name", "m", "user@mini-7"],
        vec!["machine", "add", "--destination", "mini-7"],
        vec!["machine", "add", "--destination=mini-7", "--name", "m"],
    ] {
        assert!(parsed(&host).is_none(), "{host:?} is the app's machine.add");
    }
    for other in [vec!["machine", "list"], vec!["machine", "doctor"], vec!["device", "add"]] {
        assert!(parsed(&other).is_none(), "{other:?}");
    }
    for bad in [
        vec!["machine", "add", "--ttl", "30s"],
        vec!["machine", "add", "--ttl", "2h"],
        vec!["machine", "add", "--ttl", "11m"],
        vec!["machine", "add", "--ttl"],
        vec!["machine", "add", "--yes"],
        vec!["machine", "add", "--name", ""],
        vec!["machine", "revoke"],
        vec!["machine", "revoke", "a", "b"],
        vec!["machine", "rotate", "a", "--yes"],
        vec!["machine", "rotate", "a", "--cloud-token-file", "f", "--cloud-token-stdin"],
    ] {
        assert!(parsed(&bad).is_some_and(|r| r.is_err()), "{bad:?}");
    }
    assert_eq!(
        command(&["machine", "revoke", "lane-vm-3", "-y", "--platform", "https://p.example"]),
        Command {
            verb: Verb::Revoke { machine: "lane-vm-3".into(), yes: true },
            auth: Auth { platform: Some("https://p.example".into()), ..Auth::default() },
        }
    );
}

#[test]
fn the_credential_comes_from_stdin_a_file_or_the_env_and_errors_name_neither() {
    let env =
        |key: &str| -> Option<String> { (key == TOKEN_ENV).then(|| format!(" {CREDENTIAL}\n")) };
    let none = |_: &str| -> Option<String> { None };
    let mut empty = std::io::empty();
    assert_eq!(
        read_credential(&Auth::default(), &env, &mut empty).unwrap().as_deref(),
        Some(CREDENTIAL)
    );
    assert_eq!(read_credential(&Auth::default(), &none, &mut empty).unwrap(), None);
    let stdin = Auth { token_stdin: true, ..Auth::default() };
    let mut piped = std::io::Cursor::new(format!("{CREDENTIAL}\nmore\n"));
    assert_eq!(read_credential(&stdin, &none, &mut piped).unwrap().as_deref(), Some(CREDENTIAL));
    assert!(read_credential(&stdin, &env, &mut std::io::Cursor::new("\n")).is_err());
    let dir = std::env::temp_dir().join(format!("cmux-join-cred-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join(CREDENTIAL);
    std::fs::write(&file, format!("{CREDENTIAL}\n")).unwrap();
    let from_file = Auth { token_file: Some(file), ..Auth::default() };
    assert_eq!(
        read_credential(&from_file, &none, &mut empty).unwrap().as_deref(),
        Some(CREDENTIAL)
    );
    let missing =
        Auth { token_file: Some(dir.join(format!("{CREDENTIAL}-missing"))), ..Auth::default() };
    let error = read_credential(&missing, &none, &mut empty).unwrap_err();
    no_secret(&error);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_platform_is_https_and_defaults_to_production() {
    let none = |_: &str| -> Option<String> { None };
    assert_eq!(platform_origin(None, &none).unwrap(), DEFAULT_ORIGIN);
    assert_eq!(DEFAULT_ORIGIN, "https://cmux-platform-production.debussy.workers.dev");
    let env = |key: &str| -> Option<String> {
        (key == "CMUX_PLATFORM_URL").then(|| "https://platform.example/".to_owned())
    };
    assert_eq!(platform_origin(None, &env).unwrap(), "https://platform.example");
    assert_eq!(platform_origin(Some("http://127.0.0.1:9"), &env).unwrap(), "http://127.0.0.1:9");
    assert!(platform_origin(Some("http://platform.example"), &none).is_err());
    let error =
        platform_origin(Some(format!("https://x.example/?t={TOKEN}").as_str()), &none).unwrap_err();
    no_secret(&error);
}

#[test]
fn add_json_prints_the_env_form_line_and_the_token_only_in_line_and_token() {
    let (origin, requests) = fake(joining(vec![json!([])], far()));
    let ran = run_with(
        &["machine", "add", "--name", "lane-vm-3", "--ttl", "10m"],
        &origin,
        OutputMode::Json,
        true,
        true,
        never(),
    );
    assert_eq!(ran.code, Ok(0));
    let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
    let line = value["line"].as_str().unwrap();
    assert_eq!(line, format!(" curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN={TOKEN} sh"));
    assert_eq!(value["token"], TOKEN);
    assert_eq!(value["joinTokenId"], "jt_1");
    assert_eq!(value["teamId"], "team_1");
    assert_eq!(value["name"], "lane-vm-3");
    assert_eq!(value["scriptUrl"], format!("{origin}/v1/machines/join.sh"));
    assert_eq!(
        value["windowsLine"],
        format!(" $env:CMUX_JOIN='{TOKEN}'; irm {origin}/v1/machines/join.ps1 | iex")
    );
    assert_eq!(value["windowsScriptUrl"], format!("{origin}/v1/machines/join.ps1"));
    assert_eq!(value["joined"], Value::Null, "json does not wait unless asked");
    let mut holding: Vec<&String> = value
        .as_object()
        .unwrap()
        .iter()
        .filter(|(_, v)| v.to_string().contains(TOKEN))
        .map(|(k, _)| k)
        .collect();
    holding.sort();
    assert_eq!(holding, vec!["line", "token", "windowsLine"]);
    let mint = requests.recv().unwrap();
    let (head, body) = mint.split_once("\r\n\r\n").unwrap();
    assert!(head.starts_with("POST /v1/machines/join-tokens HTTP/1.1"), "{head}");
    assert!(head.to_ascii_lowercase().contains(&format!("authorization: bearer {CREDENTIAL}")));
    assert_eq!(
        serde_json::from_str::<Value>(body).unwrap(),
        json!({"label": "lane-vm-3", "ttlSeconds": 600})
    );
    assert!(requests.try_recv().is_err(), "no wait, no list read");
}

#[test]
fn add_human_prints_the_line_and_waits_on_a_terminal_until_it_joins() {
    let (origin, _requests) = fake(joining(
        vec![json!([entry("jt_other")]), json!({"credentials": [entry("jt_1")]})],
        far(),
    ));
    let ran = run_with(&["machine", "add"], &origin, OutputMode::Human, true, true, never());
    assert_eq!(ran.code, Ok(0));
    let mut lines = ran.out.lines();
    let first = lines.next().unwrap();
    assert!(
        first.starts_with("Run this on the new machine. It works once and expires at "),
        "{first}"
    );
    assert!(first.ends_with(" UTC (10 min):"), "{first}");
    assert_eq!(lines.next(), Some(""));
    assert_eq!(
        lines.next().unwrap(),
        format!(" curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN={TOKEN} sh")
    );
    assert_eq!(lines.next(), Some(""));
    assert_eq!(lines.next(), Some("On a Windows PC, in PowerShell:"));
    assert_eq!(lines.next(), Some(""));
    assert_eq!(
        lines.next().unwrap(),
        format!(" $env:CMUX_JOIN='{TOKEN}'; irm {origin}/v1/machines/join.ps1 | iex")
    );
    assert!(ran.out.contains("Waiting for it to join…"), "{}", ran.out);
    assert!(
        ran.out.trim_end().ends_with("lane-vm-3 joined (machine m_1). Screen sharing and control stay off until it allows them."),
        "{}",
        ran.out
    );
    // Not on a terminal, a person's run prints the line and returns.
    let (origin, requests) = fake(joining(vec![json!([])], far()));
    let ran = run_with(&["machine", "add"], &origin, OutputMode::Human, false, true, never());
    assert_eq!(ran.code, Ok(0));
    assert!(
        ran.out.trim_end().ends_with("It shows in `cmux machine list` once it joins."),
        "{}",
        ran.out
    );
    requests.recv().unwrap();
    assert!(requests.try_recv().is_err());
}

#[test]
fn add_jsonl_prints_minted_then_joined_events() {
    let (origin, _requests) = fake(joining(vec![json!([]), json!([entry("jt_1")])], far()));
    let ran = run_with(
        &["machine", "add", "--wait"],
        &origin,
        OutputMode::JsonLines,
        false,
        true,
        never(),
    );
    assert_eq!(ran.code, Ok(0));
    let events: Vec<Value> = ran.out.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(events.len(), 2, "{}", ran.out);
    assert_eq!(events[0]["event"], "minted");
    assert_eq!(events[0]["token"], TOKEN);
    assert!(events[0].get("joined").is_none());
    assert_eq!(events[1]["event"], "joined");
    assert_eq!(events[1]["machineId"], "m_1");
    assert_eq!(events[1]["name"], "lane-vm-3");
    no_secret(&events[1].to_string());
    // --json --wait prints one object, with the joined machine.
    let (origin, _requests) = fake(joining(vec![json!([entry("jt_1")])], far()));
    let ran =
        run_with(&["machine", "add", "--wait"], &origin, OutputMode::Json, false, true, never());
    assert_eq!(ran.code, Ok(0));
    let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
    assert_eq!(value["joined"]["machineId"], "m_1");
}

#[test]
fn the_wait_stops_at_expiry_and_on_interrupt() {
    let soon = now_ms() + 150;
    let (origin, _requests) = fake(joining(vec![json!([])], soon));
    let ran = run_with(
        &["machine", "add", "--wait"],
        &origin,
        OutputMode::JsonLines,
        false,
        true,
        never(),
    );
    assert_eq!(ran.code, Ok(3));
    assert_eq!(ran.out.lines().last().unwrap(), r#"{"event":"expired"}"#);
    let (origin, _requests) = fake(joining(vec![json!([])], soon));
    let ran =
        run_with(&["machine", "add", "--wait"], &origin, OutputMode::Human, false, true, never());
    assert_eq!(ran.code, Ok(3));
    assert!(ran.out.trim_end().ends_with("Make a new one: cmux machine add"), "{}", ran.out);
    let (origin, _requests) = fake(joining(vec![json!([])], far()));
    let ran =
        run_with(&["machine", "add", "--wait"], &origin, OutputMode::Human, false, true, async {});
    assert_eq!(ran.code, Ok(130));
    assert!(
        ran.out.contains("Stopped waiting. The line still works; it expires at "),
        "{}",
        ran.out
    );
    let (origin, _requests) = fake(joining(vec![json!([])], far()));
    let ran = run_with(
        &["machine", "add", "--wait"],
        &origin,
        OutputMode::JsonLines,
        false,
        true,
        async {},
    );
    assert_eq!(ran.code, Ok(130));
    assert_eq!(ran.out.lines().last().unwrap(), r#"{"event":"interrupted"}"#);
}

#[test]
fn quiet_add_mints_and_prints_nothing() {
    let (origin, requests) = fake(joining(vec![json!([])], far()));
    let ran = run_with(&["machine", "add"], &origin, OutputMode::Quiet, true, true, never());
    assert_eq!(ran.code, Ok(0));
    assert!(ran.out.is_empty(), "{}", ran.out);
    assert!(requests.recv().unwrap().starts_with("POST /v1/machines/join-tokens "));
    assert!(requests.try_recv().is_err(), "quiet does not wait unless asked");
    // --quiet --wait waits and says how it ended only by its exit code.
    let (origin, _requests) = fake(joining(vec![json!([entry("jt_1")])], far()));
    let ran =
        run_with(&["machine", "add", "--wait"], &origin, OutputMode::Quiet, false, true, never());
    assert_eq!(ran.code, Ok(0));
    assert!(ran.out.is_empty(), "{}", ran.out);
}

#[test]
fn a_404_says_joining_is_not_available_and_errors_never_carry_a_secret() {
    let gate = Arc::new(|_: &str| {
        (404, json!({"_tag": "MachineNotFound", "code": "machine.not_found", "message": "no such machine"}).to_string())
    });
    let (origin, _requests) = fake(gate);
    for words in [
        vec!["machine", "add"],
        vec!["machine", "revoke", "x", "--yes"],
        vec!["machine", "rotate", "x"],
    ] {
        let failure =
            run_with(&words, &origin, OutputMode::Human, false, true, never()).code.unwrap_err();
        assert_eq!(
            failure.message,
            format!("joining isn't available on {origin} yet (it answered 404)"),
            "{words:?}"
        );
        assert_eq!(failure.code, "machine_join.unavailable");
    }
    // A server that echoes the secrets back: none of it reaches the message.
    let echo = Arc::new(|request: &str| {
        let body =
            json!({"code": format!("{CREDENTIAL} {TOKEN}"), "message": request, "token": TOKEN});
        (401, body.to_string())
    });
    let (origin, _requests) = fake(echo);
    let failure = run_with(&["machine", "add"], &origin, OutputMode::Json, false, true, never())
        .code
        .unwrap_err();
    assert_eq!(failure.message, "the cmux platform did not accept your sign-in (401)");
    no_secret(&failure.message);
    let refused = Arc::new(|_: &str| (403, json!({"code": "auth.forbidden"}).to_string()));
    let (origin, _requests) = fake(refused);
    let failure = run_with(&["machine", "add"], &origin, OutputMode::Json, false, true, never())
        .code
        .unwrap_err();
    assert_eq!(failure.message, "the cmux platform refused the join token: 403 auth.forbidden");
}

#[test]
fn an_unusable_token_is_refused_without_printing_it() {
    let tokens =
        ["cmj_short", "cmj_has space in it", "cmj_quote'or;semicolon", "notcmj_0123456789"]
            .map(str::to_owned)
            .into_iter()
            .chain([format!("cmj_{CREDENTIAL}")]);
    for token in tokens {
        let answer = Arc::new(move |_: &str| {
            (
                200,
                json!({"token": token.clone(), "joinTokenId": "jt_1", "expiresAt": far()})
                    .to_string(),
            )
        });
        let (origin, _requests) = fake(answer);
        let ran = run_with(&["machine", "add"], &origin, OutputMode::Human, false, true, never());
        let failure = ran.code.unwrap_err();
        assert!(ran.out.is_empty(), "{}", ran.out);
        assert_eq!(failure.message, "the cmux platform's join token has an unusable token");
    }
    // A field printed beside the token that holds it is refused too.
    let answer = Arc::new(|_: &str| {
        (200, json!({"token": TOKEN, "joinTokenId": "jt_1", "label": TOKEN}).to_string())
    });
    let (origin, _requests) = fake(answer);
    let ran = run_with(&["machine", "add"], &origin, OutputMode::Json, false, true, never());
    assert!(ran.code.is_err());
    no_secret(&ran.out);
}

fn listed_platform() -> (String, mpsc::Receiver<String>) {
    let mut revoked = entry("jt_0");
    revoked["machineId"] = json!("m_0");
    revoked["revoked"] = json!(true);
    let list = json!([entry("jt_1"), revoked]);
    fake(Arc::new(move |request: &str| {
        if request.starts_with("GET /v1/machines/credentials ") {
            (200, list.to_string())
        } else if request.starts_with("POST /v1/machines/credentials/m_1/revoke ") {
            (200, json!({"machineId": "m_1", "revoked": true}).to_string())
        } else if request.starts_with("POST /v1/machines/credentials/m_1/rotate ") {
            (200, json!({"machineId": "m_1", "credential": MACHINE_CREDENTIAL}).to_string())
        } else {
            (404, json!({"code": "machine.not_found"}).to_string())
        }
    }))
}

#[test]
fn revoke_by_name_in_every_output_mode() {
    let expected = [
        (OutputMode::Human, "lane-vm-3 revoked: access ends within 30 seconds.\n".to_owned()),
        (
            OutputMode::Json,
            format!(
                "{}\n",
                json!({"machineId": "m_1", "name": "lane-vm-3", "revoked": true, "accessEndsWithin": "30 seconds"})
            ),
        ),
        (
            OutputMode::JsonLines,
            format!(
                "{}\n",
                json!({"machineId": "m_1", "name": "lane-vm-3", "revoked": true, "accessEndsWithin": "30 seconds"})
            ),
        ),
        (OutputMode::Quiet, String::new()),
    ];
    for (output, printed) in expected {
        let (origin, requests) = listed_platform();
        let ran = run_with(
            &["machine", "revoke", "lane-vm-3", "--yes"],
            &origin,
            output,
            false,
            false,
            never(),
        );
        assert_eq!(ran.code, Ok(0), "{output:?}");
        assert_eq!(ran.out, printed, "{output:?}");
        assert!(ran.asked.is_empty(), "--yes asks nothing");
        assert!(requests.recv().unwrap().starts_with("GET /v1/machines/credentials "));
        assert!(requests.recv().unwrap().starts_with("POST /v1/machines/credentials/m_1/revoke "));
    }
}

#[test]
fn revoke_without_yes_asks_and_a_no_revokes_nothing() {
    let (origin, requests) = listed_platform();
    let ran =
        run_with(&["machine", "revoke", "m_1"], &origin, OutputMode::Human, false, false, never());
    assert_eq!(ran.code.unwrap_err().exit, 2);
    assert_eq!(ran.asked, vec!["Revoke lane-vm-3? It leaves your team's machines."]);
    assert!(ran.out.is_empty());
    requests.recv().unwrap();
    assert!(requests.try_recv().is_err(), "no revoke was sent");
    let (origin, _requests) = listed_platform();
    let ran =
        run_with(&["machine", "revoke", "m_1"], &origin, OutputMode::Human, false, true, never());
    assert_eq!(ran.code, Ok(0));
    let (origin, _requests) = listed_platform();
    let failure = run_with(
        &["machine", "revoke", "nobody", "--yes"],
        &origin,
        OutputMode::Human,
        false,
        true,
        never(),
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine.not_found");
}

#[test]
fn rotate_never_prints_the_new_credential() {
    for output in [OutputMode::Human, OutputMode::Json, OutputMode::JsonLines, OutputMode::Quiet] {
        let (origin, requests) = listed_platform();
        let ran =
            run_with(&["machine", "rotate", "lane-vm-3"], &origin, output, false, true, never());
        assert_eq!(ran.code, Ok(0), "{output:?}");
        no_secret(&ran.out);
        match output {
            OutputMode::Human => assert_eq!(ran.out, "lane-vm-3: credential rotated.\n"),
            OutputMode::Quiet => assert!(ran.out.is_empty()),
            _ => assert_eq!(
                serde_json::from_str::<Value>(ran.out.trim()).unwrap(),
                json!({"machineId": "m_1", "name": "lane-vm-3", "rotated": true})
            ),
        }
        requests.recv().unwrap();
        assert!(requests.recv().unwrap().starts_with("POST /v1/machines/credentials/m_1/rotate "));
    }
    let (origin, _requests) = listed_platform();
    let failure =
        run_with(&["machine", "rotate", "m_0"], &origin, OutputMode::Human, false, true, never())
            .code
            .unwrap_err();
    assert_eq!(failure.code, "machine.revoked");
}

#[test]
fn a_name_on_two_machines_needs_its_id() {
    let mut other = entry("jt_2");
    other["machineId"] = json!("m_2");
    let entries = vec![entry("jt_1"), other];
    let failure = find(&entries, "lane-vm-3").unwrap_err();
    assert_eq!(failure.message, "that name fits 2 machines; use its id: m_1, m_2");
    assert_eq!(find(&entries, "m_2").unwrap().machine_id, "m_2");
    assert_eq!(find(&entries, "lane-vm-3.internal").unwrap_err().code, "machine.ambiguous");
}

#[test]
fn joined_online_follows_the_platform_and_falls_back_to_the_heartbeat() {
    let now = now_ms();
    // The platform's `online` wins over the local clock either way: it follows the hub's row TTL.
    let fresh_but_down =
        joined(&json!({"machineId": "m_1", "lastHeartbeat": now, "online": false})).unwrap();
    assert_eq!(fresh_but_down.state(now), "offline");
    let old_but_up =
        joined(&json!({"machineId": "m_2", "lastHeartbeat": now - 600_000, "online": true}))
            .unwrap();
    assert_eq!(old_but_up.state(now), "online");
    let revoked = joined(&json!({"machineId": "m_3", "online": true, "revoked": true})).unwrap();
    assert_eq!(revoked.state(now), "revoked");
    // A platform without the field: the heartbeat within the legacy window.
    let legacy =
        |ago: u64| joined(&json!({"machineId": "m_4", "lastHeartbeat": now - ago})).unwrap();
    assert_eq!(legacy(LEGACY_ONLINE_WITHIN_MS - 1_000).state(now), "online");
    assert_eq!(legacy(LEGACY_ONLINE_WITHIN_MS + 1_000).state(now), "offline");
}

#[test]
fn joined_rows_degrade_when_optional_fields_are_missing() {
    let now = now_ms();
    let full = joined(&entry("jt_1")).unwrap();
    let row = full.row(now);
    assert_eq!(
        row,
        json!({
            "kind": "joined", "id": "m_1", "name": "lane-vm-3", "state": "online",
            "lastHeartbeat": full.last_heartbeat, "platform": "linux",
            "hostname": "lane-vm-3.internal", "meshPeerId": "inst_1",
            "mintedBy": "leo@example.com", "role": "member",
            "createdAt": "2026-10-29T03:00:00Z", "joinTokenId": "jt_1",
        })
    );
    let bare = joined(&json!({"machineId": "m_9"})).unwrap();
    assert_eq!(bare.name, "m_9");
    assert_eq!(bare.state(now), "offline");
    assert_eq!(bare.row(now)["mintedBy"], Value::Null);
    let by_host = joined(&json!({"machineId": "m_8", "hostname": "box\u{1b}[31m"})).unwrap();
    assert_eq!(by_host.name, "box[31m", "control characters are dropped");
    let stale = joined(&json!({"machineId": "m_7", "lastHeartbeat": "2026-10-01T00:00:00Z", "mintedBy": "chief:leo"})).unwrap();
    assert_eq!(stale.state(now), "offline");
    assert_eq!(stale.minted_by.as_deref(), Some("chief:leo"));
    let seconds = joined(&json!({"machineId": "m_6", "lastHeartbeat": now / 1000})).unwrap();
    assert_eq!(seconds.state(now), "online", "epoch seconds read as seconds");
    let revoked = joined(&json!({"machineId": "m_5", "revoked": "2026-10-29T00:00:00Z"})).unwrap();
    assert_eq!(revoked.state(now), "revoked");
    for unusable in [
        json!({}),
        json!({"machineId": ""}),
        json!({"machineId": "../etc"}),
        json!({"machineId": "a/b"}),
    ] {
        assert!(joined(&unusable).is_none(), "{unusable}");
    }
}

#[test]
fn list_rows_merge_into_an_array_or_items_and_fail_open() {
    let rows = vec![json!({"kind": "joined", "id": "m_1"})];
    let (merged, note) = merge_rows(json!([{"id": "machine_a"}]), Ok(rows.clone()));
    assert_eq!(merged, json!([{"id": "machine_a"}, {"kind": "joined", "id": "m_1"}]));
    assert!(note.is_none());
    let (merged, _) = merge_rows(json!({"items": []}), Ok(rows));
    assert_eq!(merged, json!({"items": [{"kind": "joined", "id": "m_1"}]}));
    let (merged, note) =
        merge_rows(json!([{"id": "machine_a"}]), Err("joining isn't available".into()));
    assert_eq!(merged, json!([{"id": "machine_a"}]));
    assert_eq!(note.as_deref(), Some("joining isn't available"));
}

/// hq#11835 row 2: `cmux machine list` showed this machine and the Cloud VMs but not the
/// machines added with `acpmux machine add`, which `cmux chat --on NAME` now takes. They are
/// rows now (`kind: "peer"`), each once: a joined machine with that hostname, or a daemon row
/// of that name, is the same machine; the hub's own rows are the joined list's.
#[test]
fn acpmuxs_own_machines_join_the_machine_list_once() {
    let peers = vec![
        json!({"name": "gcp-agent-lane-3", "carrier": "ssh", "connected": true}),
        json!({"name": "cosmic-gray", "carrier": "ssh", "connected": false}),
        // Joined too: the joined row lists it.
        json!({"name": "gcp-agent-lane-6", "carrier": "ssh", "connected": true}),
        json!({"name": "Box", "carrier": "ssh", "connected": true}),
        json!({"name": "studio", "via": "hub", "connected": true}),
        json!({"name": "\u{1b}[31m", "connected": true}),
        json!({"connected": true}),
    ];
    let listed = json!([
        {"id": "machine_mac", "name": "local", "origin": "local"},
        {"id": "machine_box", "name": "box", "origin": "ssh"},
        {"kind": "joined", "id": "m_6", "name": "lane six", "hostname": "gcp-agent-lane-6"},
    ]);
    let merged = merge_peer_rows(listed, &peers);
    let added: Vec<&Value> = merged.as_array().unwrap()[3..].iter().collect();
    let names: Vec<&str> = added.iter().map(|row| row["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["gcp-agent-lane-3", "cosmic-gray", "[31m"]);
    assert_eq!(
        *added[0],
        json!({"kind": "peer", "id": "gcp-agent-lane-3", "name": "gcp-agent-lane-3",
               "hostname": "gcp-agent-lane-3", "origin": "acpmux", "status": "connected",
               "state": "online", "connectable": true, "carrier": "ssh",
               "target": "gcp-agent-lane-3"})
    );
    assert_eq!(
        (added[1]["status"].as_str(), added[1]["connectable"].as_bool()),
        (Some("offline"), Some(false))
    );
    // `{"items": [...]}` too; anything else is left as it was.
    let merged = merge_peer_rows(json!({"items": []}), &peers[..1]);
    assert_eq!(merged["items"][0]["id"], "gcp-agent-lane-3");
    assert_eq!(merge_peer_rows(json!("x"), &peers), json!("x"));
}

#[test]
fn credentials_answers_in_every_list_shape_are_read() {
    let (origin, _requests) =
        fake(Arc::new(|_: &str| (200, json!({"machines": [entry("jt_1")]}).to_string())));
    assert_eq!(platform(&origin).credentials().unwrap().len(), 1);
    let (origin, _requests) = fake(Arc::new(|_: &str| (200, json!({"nope": 1}).to_string())));
    assert_eq!(platform(&origin).credentials().unwrap_err(), CallError::Unreadable(200));
}

#[test]
fn the_platforms_row_shape_reads_with_mesh_identity_and_a_null_label() {
    // MachineCredentialRow as cmux-platform#35 declares it.
    let row = json!({
        "machineId": "m_3", "joinTokenId": "jt_3", "teamId": "team_1", "label": null, "role": null,
        "createdAt": "2026-10-29T03:00:00Z", "lastHeartbeat": null, "revoked": false,
        "platform": "macos", "hostname": "mini-9.local", "name": "mini-9", "meshIdentity": "inst_9",
        "mintedBy": "user_1",
    });
    let machine = joined(&row).unwrap();
    assert_eq!(machine.name, "mini-9");
    assert_eq!(machine.mesh_peer_id.as_deref(), Some("inst_9"));
    assert_eq!(machine.minted_by.as_deref(), Some("user_1"));
    assert_eq!(machine.state(now_ms()), "offline");
    assert_eq!(entries(json!({"machines": [row]})).map(|rows| rows.len()), Some(1));
    // Its unavailable store answers 503 machine.join.unavailable: joining is off there too.
    let failure = CallError::Status {
        status: 503,
        code: known_code(Some("machine.join.unavailable")),
        facts: None,
    }
    .failure("the join token");
    assert_eq!(failure.message, "joining isn't available on this server yet (it answered 503)");
}

/// A plan refusal keeps its code through the reserve, the bind and a workspace's machine, so the
/// pane can say the team has no Cloud plan instead of a generic refusal.
#[test]
fn a_plan_refusal_keeps_its_code() {
    assert_eq!(known_code(Some("cloud.plan.required")), "cloud.plan.required");
}

/// Every code of cmux-platform's refusal table (cmux-platform#1192) is one this CLI keeps, so a
/// cap, a rate limit or a machine's state reaches the person by name, not as a bare status.
#[test]
fn every_platform_refusal_code_is_known() {
    for row in refusals::PLATFORM {
        assert_eq!(known_code(Some(row.code)), row.code);
    }
    // A cap's refusal names its limit and what holds it.
    let facts = refusals::Facts { limit: Some(20), used: Some(20), ..Default::default() };
    let failure =
        CallError::Status { status: 403, code: "cloud.quota.vm_limit", facts: Some(facts) }
            .failure("the machine");
    assert!(
        failure.message.contains(
            "403 cloud.quota.vm_limit: this team is at its Cloud machine limit (20 of 20 machines)"
        ),
        "{}",
        failure.message
    );
}

#[test]
fn machine_lists_platform_flags_are_taken_out_before_the_daemon_reads_them() {
    let (auth, kept) = split_auth(&strings(&[
        "machine",
        "list",
        "--json",
        "--cloud-token-file",
        "/t",
        "--platform=https://p.example",
        "--catalog",
    ]));
    assert_eq!(kept, strings(&["machine", "list", "--json", "--catalog"]));
    assert_eq!(auth.token_file, Some(PathBuf::from("/t")));
    assert_eq!(auth.platform.as_deref(), Some("https://p.example"));
    let (auth, kept) =
        split_auth(&strings(&["machine", "list", "--cloud-token-stdin", "--", "--platform", "x"]));
    assert!(auth.token_stdin);
    assert_eq!(kept, strings(&["machine", "list", "--", "--platform", "x"]));
    assert!(take_list_auth(&strings(&["machine", "list", "--json"])).is_none(), "nothing to take");
    assert!(
        take_list_auth(&strings(&["workspace", "list", "--platform", "x"])).is_none(),
        "not machine list"
    );
}

#[test]
fn a_list_read_still_running_at_expiry_ends_the_wait_at_expiry() {
    // A platform that never answers the list: the wait still ends at expiresAt.
    let soon = now_ms() + 300;
    let hang = Arc::new(move |request: &str| {
        if request.starts_with("GET ") {
            std::thread::sleep(Duration::from_secs(4));
            return (200, "[]".to_owned());
        }
        (200, mint_answer(soon))
    });
    let (origin, _requests) = fake(hang);
    let started = std::time::Instant::now();
    let ran = run_with(
        &["machine", "add", "--wait"],
        &origin,
        OutputMode::JsonLines,
        false,
        true,
        never(),
    );
    assert_eq!(ran.code, Ok(3));
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
}

#[test]
fn quiet_revoke_without_yes_refuses_before_any_call() {
    let (origin, requests) = listed_platform();
    let ran = run_with(
        &["machine", "revoke", "lane-vm-3"],
        &origin,
        OutputMode::Quiet,
        false,
        true,
        never(),
    );
    assert_eq!(ran.code.unwrap_err().exit, 2);
    assert!(ran.asked.is_empty(), "quiet never asks");
    assert!(ran.out.is_empty());
    assert!(requests.try_recv().is_err(), "nothing was read or revoked");
}

#[test]
fn expires_at_reads_the_platforms_iso_string_with_milliseconds() {
    // The platform sends `new Date().toISOString()`: RFC 3339 UTC, milliseconds, `Z`.
    assert_eq!(epoch_ms(&json!("2026-10-29T03:10:00.250Z")), Some(1_793_243_400_250));
    assert_eq!(epoch_ms(&json!(1_793_243_400_250_u64)), Some(1_793_243_400_250));
    assert_eq!(epoch_ms(&json!("not a time")), None);
}

/// Door A timing run (huge-blue/doora-timing, 2026-11-16): with only `CMUX_PLATFORM_ORIGIN`
/// set (the name acpmux reads), acpmux joined the staging hub while this CLI's account read went
/// to production and got a 401. `CMUX_PLATFORM_ORIGIN` is the name, `CMUX_PLATFORM_URL` its
/// alias, read the way acpmux reads them.
#[test]
fn the_platform_reads_acpmuxs_variable_first_and_the_old_name_as_its_alias() {
    let staging = "https://cmux-platform-staging.example";
    let only_origin = |key: &str| -> Option<String> {
        (key == "CMUX_PLATFORM_ORIGIN").then(|| staging.to_owned())
    };
    assert_eq!(platform_origin(None, &only_origin).unwrap(), staging);
    let both = |key: &str| -> Option<String> {
        match key {
            "CMUX_PLATFORM_ORIGIN" => Some(staging.to_owned()),
            "CMUX_PLATFORM_URL" => Some("https://other.example".to_owned()),
            _ => None,
        }
    };
    assert_eq!(platform_origin(None, &both).unwrap(), staging);
    assert_eq!(
        platform_origin(Some("https://flag.example"), &both).unwrap(),
        "https://flag.example"
    );
}

/// `cmux machine add|revoke|rotate|vault --help` prints the verb's own usage (the Cloud and remote
/// command matrix); without the flag the verb parses as before.
#[test]
fn each_join_verb_has_its_own_help() {
    let words = |text: &str| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    let revoke = verb_help(&words("machine revoke --help")).unwrap();
    assert!(revoke.starts_with("usage: cmux machine revoke ID|NAME [--yes]\n"), "{revoke}");
    assert!(revoke.contains("--cloud-token-file PATH"), "{revoke}");
    assert!(!revoke.contains("rotate") && !revoke.contains("machine add"), "{revoke}");
    let add = verb_help(&words("machine add -h")).unwrap();
    assert!(add.starts_with("usage: cmux machine add [--name NAME]"), "{add}");
    assert!(add.contains("\n       cmux machine add --usb PATH"), "{add}");
    assert!(add.contains("opens the app's Add Machine card"), "{add}");
    assert!(!add.contains("revoke"), "{add}");
    let rotate = verb_help(&words("machine rotate box --help")).unwrap();
    assert!(rotate.starts_with("usage: cmux machine rotate ID|NAME\n"), "{rotate}");
    assert_eq!(verb_help(&words("machine vault --help")).unwrap(), vault::USAGE);
    assert!(verb_help(&words("machine revoke box")).is_none());
    assert!(verb_help(&words("machine list --help")).is_none());
}

#[test]
fn placement_parses_on_off_status_and_nothing_else() {
    assert_eq!(command(&["machine", "placement", "on"]).verb, Verb::Placement(Some(true)));
    assert_eq!(command(&["machine", "placement", "off"]).verb, Verb::Placement(Some(false)));
    assert_eq!(command(&["machine", "placement", "status"]).verb, Verb::Placement(None));
    for words in [
        vec!["machine", "placement"],
        vec!["machine", "placement", "maybe"],
        vec!["machine", "placement", "on", "off"],
        vec!["machine", "placement", "on", "--yes"],
    ] {
        assert!(parsed(&words).expect("ours").is_err(), "{words:?}");
    }
    let flagged = command(&["machine", "placement", "on", "--platform", "https://p.example"]);
    assert_eq!(flagged.auth.platform.as_deref(), Some("https://p.example"));
}

/// No credential: a plain `machine add` is still the app's card; `--app-session` and every other
/// verb sign in with the app's session, so the caller never holds a token.
#[test]
fn without_a_credential_only_a_plain_add_opens_the_card() {
    assert_eq!(command(&["machine", "add"]).without_credential(), NoCredential::Card);
    assert_eq!(
        command(&["machine", "add", "--no-wait", "--name", "a"]).without_credential(),
        NoCredential::Card
    );
    for words in [
        vec!["machine", "add", "--app-session"],
        vec!["machine", "add", "--app-session", "--no-wait", "--name", "a"],
        vec!["machine", "placement", "status"],
        vec!["machine", "placement", "on"],
        vec!["machine", "revoke", "m_1", "--yes"],
        vec!["machine", "rotate", "m_1"],
    ] {
        assert_eq!(command(&words).without_credential(), NoCredential::AppSession, "{words:?}");
    }
    let add = command(&["machine", "add", "--app-session"]);
    assert!(add.auth.app_session);
    assert_eq!(add.verb, Verb::Add(AddArgs::default()));
    for words in [
        vec!["machine", "add", "--app-session", "--cloud-token-stdin"],
        vec!["machine", "placement", "on", "--app-session", "--cloud-token-file", "/x"],
        vec!["machine", "add", "--app-session=yes"],
    ] {
        assert!(parsed(&words).expect("ours").is_err(), "{words:?}");
    }
}

/// `--app-session` and `--cloud-token-stdin` take no value, so a `--json` after them is the
/// global output switch.
#[test]
fn placement_and_app_session_switches_take_no_value() {
    let words = strings(&["machine", "placement"]);
    assert!(own_switch(&words, "--cloud-token-stdin"));
    assert!(own_switch(&words, "--app-session"));
    assert!(own_switch(&strings(&["machine", "add"]), "--app-session"));
    assert!(!own_switch(&strings(&["machine", "list"]), "--app-session"));
}

fn placement_platform(enabled: bool, status: u16) -> (String, mpsc::Receiver<String>) {
    fake(Arc::new(move |request: &str| {
        if status != 200 {
            return (status, json!({"code": "machine.forbidden", "message": "no"}).to_string());
        }
        let on = if request.starts_with("PUT ") {
            request.contains(r#""enabled":true"#)
        } else {
            enabled
        };
        (
            200,
            json!({"enabled": on, "updated_at": if on { 1_764_000_000_000_u64 } else { 0 }})
                .to_string(),
        )
    }))
}

#[test]
fn placement_status_reads_and_on_off_put_the_setting_in_every_output_mode() {
    let (origin, requests) = placement_platform(false, 200);
    let ran = run_with(
        &["machine", "placement", "status"],
        &origin,
        OutputMode::Human,
        false,
        false,
        never(),
    );
    assert_eq!(ran.code, Ok(0));
    assert_eq!(ran.out, "joined placement: off (never set)\n");
    let request = requests.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(request.starts_with("GET /v1/machines/joined/placement "), "{request}");
    assert!(request.to_ascii_lowercase().contains(&format!("authorization: bearer {CREDENTIAL}")));

    let ran =
        run_with(&["machine", "placement", "on"], &origin, OutputMode::Json, false, false, never());
    assert_eq!(ran.code, Ok(0));
    let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
    assert_eq!(value, json!({"enabled": true, "updated_at": 1_764_000_000_000_u64}));
    let request = requests.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(request.starts_with("PUT /v1/machines/joined/placement "), "{request}");
    assert!(request.ends_with(r#"{"enabled":true}"#), "{request}");
    no_secret(&ran.out);

    let ran = run_with(
        &["machine", "placement", "off"],
        &origin,
        OutputMode::Human,
        false,
        false,
        never(),
    );
    assert_eq!(ran.out, "joined placement: off (never set)\n");
    let request = requests.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(request.ends_with(r#"{"enabled":false}"#), "{request}");

    let ran = run_with(
        &["machine", "placement", "on"],
        &origin,
        OutputMode::Quiet,
        false,
        false,
        never(),
    );
    assert_eq!((ran.code, ran.out.as_str()), (Ok(0), ""));
}

#[test]
fn placement_refusals_name_the_role_and_a_404_and_never_a_secret() {
    let (origin, _requests) = placement_platform(false, 403);
    let ran = run_with(
        &["machine", "placement", "on"],
        &origin,
        OutputMode::Human,
        false,
        false,
        never(),
    );
    let failure = ran.code.unwrap_err();
    assert_eq!(failure.code, "machine_join.forbidden");
    assert!(failure.message.contains("owner or admin"), "{}", failure.message);
    no_secret(&failure.message);

    let (origin, _requests) = placement_platform(false, 404);
    let failure = run_with(
        &["machine", "placement", "status"],
        &origin,
        OutputMode::Human,
        false,
        false,
        never(),
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine_join.unavailable");
    // It names the platform it asked: staging's 404 read as production's.
    assert_eq!(
        failure.message,
        format!("joined placement isn't available on {origin} (it answered 404)")
    );

    let (origin, _requests) = placement_platform(false, 401);
    let failure = run_with(
        &["machine", "placement", "status"],
        &origin,
        OutputMode::Human,
        false,
        false,
        never(),
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine_join.unauthorized");
    no_secret(&failure.message);

    let (origin, _requests) = fake(Arc::new(|_| (200, json!({"on": true}).to_string())));
    let failure = run_with(
        &["machine", "placement", "status"],
        &origin,
        OutputMode::Human,
        false,
        false,
        never(),
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine_join.unreadable");
}

#[test]
fn placement_has_its_own_help() {
    let words = |text: &str| text.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    let help = verb_help(&words("machine placement --help")).unwrap();
    assert!(help.starts_with("usage: cmux machine placement on|off|status\n"), "{help}");
    assert!(help.contains("owner or admin"), "{help}");
    assert!(help.contains("--app-session"), "{help}");
    let revoke = verb_help(&words("machine revoke --help")).unwrap();
    assert!(!revoke.contains("placement"), "{revoke}");
}
