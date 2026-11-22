use std::cell::RefCell;
use std::collections::VecDeque;
use std::time::Duration;

use acpmux::rpc::method;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::capture::{self, TokenFilter};
use super::{Chatgpt, Command, Daemon, Io, Keychain, parse, run};

const TOKEN: &str =
    "sk-ant-oat01-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789";

fn strings(args: &[&str]) -> Vec<String> {
    args.iter().map(|s| (*s).to_owned()).collect()
}

/// acpmux's connection calls, answered from a list.
#[derive(Default)]
struct FakeDaemon {
    calls: RefCell<Vec<(String, Value)>>,
    connections: RefCell<Vec<Value>>,
    refuse_add: bool,
    waits: RefCell<VecDeque<Option<Value>>>,
}

impl Daemon for FakeDaemon {
    fn call(&self, m: &str, params: Value) -> Result<Value, String> {
        self.calls.borrow_mut().push((m.to_owned(), params.clone()));
        let state = |list: &Vec<Value>| json!({ "connections": list, "spread": false, "order_explicit": false });
        match m {
            method::MUX_CONNECTIONS => Ok(state(&self.connections.borrow())),
            method::MUX_CONNECTIONS_KEY_ADD | method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD => {
                if self.refuse_add {
                    return Err("secret_unresolved: no such Keychain item".into());
                }
                let (id, kind, cloud) = if m == method::MUX_CONNECTIONS_KEY_ADD {
                    (format!("{}-key", params["provider"].as_str().unwrap()), "api-key", true)
                } else {
                    ("claude-token".to_owned(), "claude-token", true)
                };
                self.connections.borrow_mut().push(
                    json!({"id": id, "kind": kind, "serves_cloud": cloud, "signed_in": true}),
                );
                Ok(state(&self.connections.borrow()))
            }
            method::MUX_CONNECTIONS_CHATGPT_BEGIN => {
                Ok(json!({"attempt": "a1", "url": "https://auth.openai.com/oauth/authorize?x=1"}))
            }
            method::MUX_CONNECTIONS_CHATGPT_CANCEL => {
                Ok(json!({"attempt": params["attempt"], "status": "cancelled"}))
            }
            other => Err(format!("unexpected {other}")),
        }
    }

    fn call_or_interrupt(&self, m: &str, params: Value) -> Result<Option<Value>, String> {
        self.calls.borrow_mut().push((m.to_owned(), params));
        Ok(self.waits.borrow_mut().pop_front().unwrap_or(Some(json!({"status": "pending"}))))
    }
}

impl FakeDaemon {
    fn methods(&self) -> Vec<String> {
        self.calls.borrow().iter().map(|(m, _)| m.clone()).collect()
    }
}

#[derive(Default)]
struct FakeKeychain {
    stored: RefCell<Vec<(String, String, String)>>,
    deleted: RefCell<Vec<String>>,
}

impl Keychain for FakeKeychain {
    fn store(&self, account: &str, label: &str, value: &str) -> Result<(), String> {
        self.stored.borrow_mut().push((account.to_owned(), label.to_owned(), value.to_owned()));
        Ok(())
    }
    fn delete(&self, account: &str) {
        self.deleted.borrow_mut().push(account.to_owned());
    }
}

fn io<'a>(daemon: &'a FakeDaemon, keychain: &'a FakeKeychain) -> Io<'a> {
    Io {
        daemon,
        keychain,
        claude_token: &|| Ok(Zeroizing::new(TOKEN.to_owned())),
        api_key: &|_| Ok(Zeroizing::new("sk-proj-0123456789abcdef\n".to_owned())),
    }
}

#[test]
fn parses_every_verb() {
    assert_eq!(parse("connections", &[]).unwrap(), Command::Connections);
    assert_eq!(parse("connect", &strings(&["claude"])).unwrap(), Command::Claude { label: None });
    assert_eq!(
        parse("connect", &strings(&["claude", "--label", " Work "])).unwrap(),
        Command::Claude { label: Some("Work".into()) }
    );
    assert_eq!(
        parse("connect", &strings(&["api-key", "--provider=openai"])).unwrap(),
        Command::ApiKey { provider: "openai".into(), label: None }
    );
    assert_eq!(
        parse("connect", &strings(&["chatgpt", "--no-wait"])).unwrap(),
        Command::Chatgpt(Chatgpt::Begin {
            id: None,
            wait: false,
            timeout: Duration::from_secs(600)
        })
    );
    assert_eq!(
        parse("connect", &strings(&["chatgpt", "--wait", "a1", "--timeout", "30"])).unwrap(),
        Command::Chatgpt(Chatgpt::Wait {
            attempt: "a1".into(),
            timeout: Duration::from_secs(30),
            keep: false
        })
    );
    assert_eq!(
        parse("connect", &strings(&["chatgpt", "--cancel", "a1"])).unwrap(),
        Command::Chatgpt(Chatgpt::Cancel { attempt: "a1".into() })
    );
    assert_eq!(parse("connect", &[]).unwrap(), Command::Help);
}

#[test]
fn refuses_bad_usage_and_never_takes_a_secret_in_argv() {
    for args in [
        &["api-key"][..],
        &["api-key", "--provider", "google"],
        &["api-key", "--provider", "openai", "--key", "sk-x"],
        &["claude", "sk-ant-oat01-x"],
        &["claude", "--token", "sk-ant-oat01-x"],
        &["chatgpt", "--timeout", "0"],
        &["chatgpt", "--cancel", "a1", "--id", "x"],
        &["codex"],
    ] {
        assert!(parse("connect", &strings(args)).is_err(), "{args:?}");
    }
    assert!(parse("connections", &strings(&["extra"])).is_err());
}

#[test]
fn run_if_requested_ignores_other_cloud_verbs() {
    assert_eq!(super::run_if_requested(&strings(&["cloud", "secret", "ls"])), None);
    assert_eq!(super::run_if_requested(&strings(&["cloud", "ls"])), None);
}

#[test]
fn claude_stores_the_token_and_adds_only_its_reference() {
    let daemon = FakeDaemon::default();
    let keychain = FakeKeychain::default();
    let command = Command::Claude { label: Some("Work".into()) };
    let value = run(&command, &io(&daemon, &keychain), &mut |_| {}).unwrap();
    let stored = keychain.stored.borrow();
    let (account, label, secret) = &stored[0];
    assert!(
        account.starts_with("claude-token-") && account.len() == "claude-token-".len() + 8,
        "{account}"
    );
    assert_eq!(label, "cmux claude-token API key");
    assert_eq!(secret, TOKEN);
    let calls = daemon.calls.borrow();
    let (m, params) =
        calls.iter().find(|(m, _)| m == method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD).unwrap();
    assert_eq!(m, method::MUX_CONNECTIONS_CLAUDE_TOKEN_ADD);
    assert_eq!(params["secret"], json!(format!("keychain:cmux-model-key/{account}")));
    assert_eq!(params["label"], json!("Work"));
    assert_eq!(value["connection"]["id"], json!("claude-token"));
    assert_eq!(value["keychain"], json!({"service": "cmux-model-key", "account": account}));
    // The token is nowhere in what the daemon got or what the verb answers.
    assert!(!format!("{calls:?}").contains("sk-ant-oat01"));
    assert!(!value.to_string().contains("sk-ant-oat01"));
    assert!(super::human(&command, &value).contains("It serves Cloud sessions."));
}

#[test]
fn a_refused_add_removes_the_keychain_item() {
    let daemon = FakeDaemon { refuse_add: true, ..FakeDaemon::default() };
    let keychain = FakeKeychain::default();
    let error =
        run(&Command::Claude { label: None }, &io(&daemon, &keychain), &mut |_| {}).unwrap_err();
    assert!(error.contains("Keychain item was removed"), "{error}");
    assert_eq!(*keychain.deleted.borrow(), vec![keychain.stored.borrow()[0].0.clone()]);
}

#[test]
fn claude_refuses_what_is_not_a_setup_token() {
    let daemon = FakeDaemon::default();
    let keychain = FakeKeychain::default();
    for bad in ["sk-ant-api03-abc", "sk-ant-oat01 with space", ""] {
        let io = Io {
            daemon: &daemon,
            keychain: &keychain,
            claude_token: &|| Ok(Zeroizing::new(bad.to_owned())),
            api_key: &|_| unreachable!(),
        };
        assert!(run(&Command::Claude { label: None }, &io, &mut |_| {}).is_err(), "{bad}");
    }
    assert!(keychain.stored.borrow().is_empty());
    assert!(daemon.calls.borrow().is_empty());
}

#[test]
fn api_key_stores_under_the_provider_and_calls_key_add() {
    let daemon = FakeDaemon::default();
    let keychain = FakeKeychain::default();
    let command = Command::ApiKey { provider: "anthropic".into(), label: None };
    let value = run(&command, &io(&daemon, &keychain), &mut |_| {}).unwrap();
    let (account, label, secret) = keychain.stored.borrow()[0].clone();
    assert!(account.starts_with("anthropic-"), "{account}");
    assert_eq!(label, "cmux anthropic API key");
    assert_eq!(secret, "sk-proj-0123456789abcdef", "the trailing line break is trimmed");
    let calls = daemon.calls.borrow();
    let (_, params) = calls.iter().find(|(m, _)| m == method::MUX_CONNECTIONS_KEY_ADD).unwrap();
    assert_eq!(
        params,
        &json!({"provider": "anthropic", "secret": format!("keychain:cmux-model-key/{account}")})
    );
    assert_eq!(value["connection"]["id"], json!("anthropic-key"));
}

#[test]
fn chatgpt_prints_the_link_then_waits_until_done() {
    let daemon = FakeDaemon::default();
    daemon.waits.borrow_mut().extend([
        Some(json!({"status": "pending"})),
        Some(
            json!({"status": "done", "connection": {"id": "codex-chatgpt", "serves_cloud": true}}),
        ),
    ]);
    let keychain = FakeKeychain::default();
    let mut notices = Vec::new();
    let command =
        Command::Chatgpt(Chatgpt::Begin { id: None, wait: true, timeout: Duration::from_secs(60) });
    let value = run(&command, &io(&daemon, &keychain), &mut |v| notices.push(v.clone())).unwrap();
    assert_eq!(
        notices,
        vec![
            json!({"attempt": "a1", "url": "https://auth.openai.com/oauth/authorize?x=1", "status": "pending"})
        ]
    );
    assert_eq!(value["status"], json!("done"));
    assert_eq!(value["connection"]["id"], json!("codex-chatgpt"));
    assert_eq!(
        daemon.methods(),
        [
            method::MUX_CONNECTIONS_CHATGPT_BEGIN,
            method::MUX_CONNECTIONS_CHATGPT_WAIT,
            method::MUX_CONNECTIONS_CHATGPT_WAIT
        ]
    );
}

#[test]
fn chatgpt_cancels_on_ctrl_c_and_on_the_timeout() {
    let keychain = FakeKeychain::default();
    let interrupted = FakeDaemon::default();
    interrupted.waits.borrow_mut().push_back(None);
    let command = Command::Chatgpt(Chatgpt::Wait {
        attempt: "a1".into(),
        timeout: Duration::from_secs(60),
        keep: false,
    });
    let error = run(&command, &io(&interrupted, &keychain), &mut |_| {}).unwrap_err();
    assert!(error.contains("interrupted"), "{error}");
    assert_eq!(interrupted.methods().last().unwrap(), method::MUX_CONNECTIONS_CHATGPT_CANCEL);

    let slow = FakeDaemon::default();
    let command = Command::Chatgpt(Chatgpt::Wait {
        attempt: "a1".into(),
        timeout: Duration::ZERO,
        keep: false,
    });
    let error = run(&command, &io(&slow, &keychain), &mut |_| {}).unwrap_err();
    assert!(error.contains("no sign-in"), "{error}");
    assert_eq!(slow.methods().last().unwrap(), method::MUX_CONNECTIONS_CHATGPT_CANCEL);
}

#[test]
fn chatgpt_no_wait_answers_the_attempt_and_a_failure_names_its_error() {
    let daemon = FakeDaemon::default();
    let keychain = FakeKeychain::default();
    let command = Command::Chatgpt(Chatgpt::Begin {
        id: Some("codex-chatgpt".into()),
        wait: false,
        timeout: Duration::from_secs(1),
    });
    let value = run(&command, &io(&daemon, &keychain), &mut |_| panic!("no wait")).unwrap();
    assert_eq!(value["attempt"], json!("a1"));
    assert_eq!(daemon.calls.borrow()[0].1, json!({"id": "codex-chatgpt"}));
    assert!(super::human(&command, &value).contains("--wait a1"));

    let failed = FakeDaemon::default();
    failed
        .waits
        .borrow_mut()
        .push_back(Some(json!({"status": "failed", "error": "state mismatch"})));
    let command = Command::Chatgpt(Chatgpt::Wait {
        attempt: "a1".into(),
        timeout: Duration::from_secs(5),
        keep: false,
    });
    assert!(
        run(&command, &io(&failed, &keychain), &mut |_| {}).unwrap_err().contains("state mismatch")
    );
}

#[test]
fn connections_lists_which_serve_cloud() {
    let daemon = FakeDaemon::default();
    daemon.connections.borrow_mut().extend([
        json!({"id": "claude-login", "kind": "claude-login", "email": "a@b.c", "signed_in": true, "serves_cloud": false}),
        json!({"id": "claude-token", "kind": "claude-token", "label": "Work\u{1b}[2J", "signed_in": true, "serves_cloud": true}),
    ]);
    let keychain = FakeKeychain::default();
    let value = run(&Command::Connections, &io(&daemon, &keychain), &mut |_| {}).unwrap();
    let table = super::human(&Command::Connections, &value);
    let lines: Vec<&str> = table.lines().collect();
    assert!(lines[0].starts_with("ID") && lines[0].ends_with("CLOUD"), "{table}");
    assert!(
        lines[1].starts_with("claude-login")
            && lines[1].contains("a@b.c")
            && lines[1].ends_with("no"),
        "{table}"
    );
    assert!(lines[2].starts_with("claude-token") && lines[2].ends_with("yes"), "{table}");
    assert!(!table.contains('\u{1b}'));
    let empty = super::human(&Command::Connections, &json!({"connections": []}));
    assert!(empty.contains("cmux cloud connect claude"));
}

fn filtered(chunks: &[&[u8]]) -> (Vec<u8>, Option<String>) {
    let mut filter = TokenFilter::default();
    let mut shown = Vec::new();
    for chunk in chunks {
        shown.extend(filter.push(chunk));
    }
    let (rest, token) = filter.finish();
    shown.extend(rest);
    (shown, token.map(|t| t.to_string()))
}

#[test]
fn the_filter_takes_the_token_out_at_every_chunk_boundary() {
    let text = format!(
        "Visit https://claude.ai/oauth?code=1\r\nPaste code here: CODE\r\n\x1b[32m{TOKEN}\x1b[0m\r\nStore this token\r\n"
    );
    let bytes = text.as_bytes();
    let before = text.find(TOKEN).unwrap();
    for split in 0..bytes.len() {
        let (shown, token) = filtered(&[&bytes[..split], &bytes[split..]]);
        assert_eq!(token.as_deref(), Some(TOKEN), "split {split}");
        assert_eq!(shown, &bytes[..before], "split {split}");
    }
    let singles: Vec<&[u8]> = bytes.chunks(1).collect();
    assert_eq!(filtered(&singles).1.as_deref(), Some(TOKEN));
}

#[test]
fn the_filter_shows_everything_when_no_token_comes() {
    let text = b"Error: not signed in. sk-ant- is not it, s";
    let (shown, token) = filtered(&[&text[..20], &text[20..]]);
    assert_eq!(shown, text);
    assert_eq!(token, None);
}

/// A stand-in for `claude setup-token`: prints a link and a prompt, reads the code, prints a token.
fn fake_claude(dir: &std::path::Path, body: &str) -> String {
    let path = dir.join("claude");
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    path.to_string_lossy().into_owned()
}

fn pipe_with(input: &[u8]) -> std::os::fd::RawFd {
    let mut fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    assert_eq!(
        unsafe { libc::write(fds[1], input.as_ptr().cast(), input.len()) },
        input.len() as isize
    );
    unsafe { libc::close(fds[1]) };
    fds[0]
}

#[test]
fn the_pty_run_shows_the_link_and_prompt_and_captures_the_token() {
    let dir = tempfile::tempdir().unwrap();
    let program = fake_claude(
        dir.path(),
        &format!(
            "[ \"$1\" = setup-token ] || exit 9\nprintf 'Browser: https://claude.ai/oauth/authorize?x=1\\n'\nprintf 'Paste code here if prompted > '\nread code\nprintf 'got %s\\n' \"$code\"\nprintf '{TOKEN}\\n'\nprintf 'Store this token securely\\n'\nsleep 30"
        ),
    );
    let input = pipe_with(b"CODE-123\n");
    let mut out = Vec::new();
    let started = std::time::Instant::now();
    let token = capture::run(&program, &["setup-token"], Some(input), 200, &mut out).unwrap();
    unsafe { libc::close(input) };
    assert_eq!(&*token, TOKEN);
    let shown = String::from_utf8_lossy(&out);
    assert!(shown.contains("https://claude.ai/oauth/authorize?x=1"), "{shown}");
    assert!(shown.contains("Paste code here if prompted"), "{shown}");
    assert!(shown.contains("got CODE-123"), "{shown}");
    assert!(!shown.contains("sk-ant-oat"), "{shown}");
    assert!(!shown.contains("Store this token"), "{shown}");
    // The child that keeps running after the token is stopped, not waited for.
    assert!(started.elapsed() < Duration::from_secs(20));
}

#[test]
fn the_pty_run_fails_with_no_token_and_names_a_missing_claude() {
    let dir = tempfile::tempdir().unwrap();
    let program = fake_claude(dir.path(), "echo 'Error: login failed'\nexit 1");
    let mut out = Vec::new();
    let error = capture::run(&program, &["setup-token"], None, 200, &mut out).unwrap_err();
    assert!(error.contains("without printing a token"), "{error}");
    assert!(String::from_utf8_lossy(&out).contains("login failed"));

    let missing = dir.path().join("no-such-claude");
    let error =
        capture::run(missing.to_str().unwrap(), &["setup-token"], None, 200, &mut out).unwrap_err();
    assert!(error.contains("not installed"), "{error}");
}

#[test]
fn chatgpt_wait_with_keep_answers_pending_and_leaves_the_attempt() {
    assert_eq!(
        parse("connect", &strings(&["chatgpt", "--wait", "a1", "--keep", "--timeout=5"])).unwrap(),
        Command::Chatgpt(Chatgpt::Wait {
            attempt: "a1".into(),
            timeout: Duration::from_secs(5),
            keep: true
        })
    );
    assert!(parse("connect", &strings(&["chatgpt", "--keep"])).is_err());
    let daemon = FakeDaemon::default();
    let keychain = FakeKeychain::default();
    let command = Command::Chatgpt(Chatgpt::Wait {
        attempt: "a1".into(),
        timeout: Duration::ZERO,
        keep: true,
    });
    let value = run(&command, &io(&daemon, &keychain), &mut |_| {}).unwrap();
    assert_eq!(value, json!({"attempt": "a1", "status": "pending"}));
    assert!(!daemon.methods().iter().any(|m| m == method::MUX_CONNECTIONS_CHATGPT_CANCEL));
}

/// The MODEL CONNECTIONS lines of `cmux cloud --help` (#48924) parse here, each provider of `api-key`'s
/// `anthropic|openai` included, with no optional `[...]` part.
#[test]
fn the_help_connect_lines_parse() {
    for japanese in [false, true] {
        let help = crate::cli::cloud_help::overview(japanese);
        let lines = help
            .lines()
            .map(str::trim)
            .filter(|line| line.starts_with("cmux vm connect"))
            .collect::<Vec<_>>();
        assert_eq!(lines.len(), 4, "{lines:?}");
        for line in lines {
            let required = line.split(" [").next().unwrap_or(line);
            let words = required.split_whitespace().skip(2).collect::<Vec<_>>();
            let (verb, rest) = words.split_first().expect("a verb");
            let alternatives = rest
                .iter()
                .find_map(|word| word.contains('|').then(|| word.split('|').collect::<Vec<_>>()))
                .unwrap_or_else(|| vec![""]);
            for pick in alternatives {
                let args = rest
                    .iter()
                    .map(|word| if word.contains('|') { pick } else { word })
                    .map(str::to_owned)
                    .collect::<Vec<_>>();
                let parsed = parse(verb, &args);
                assert!(
                    matches!(parsed, Ok(ref command) if !matches!(command, Command::Help)),
                    "{line}: {pick} parsed as {parsed:?}"
                );
            }
        }
    }
}
