//! Cloud chat repository actions shared by the CLI and MCP. The session
//! argument is a chat id; socket selection still uses the CLI's global route.

use std::io::{BufRead, BufReader, Read, Write};
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::mcp::{CallFailure, FailureKind};
use super::{GlobalArgs, UsageError};

const HELP: &str = "usage: cmux [--socket SOCK] cloud repo list --session CHAT [--query NAME]\n       cmux [--socket SOCK] cloud repo add --session CHAT --repo NAME [--ref REF]\n       cmux [--socket SOCK] cloud repo wait-github --session CHAT [--timeout-ms N]\n       cmux cloud repo local\n       cmux cloud repo sync --repos-json JSON [--recent-json JSON] [--install-url URL] [--complete true|false]\n       cmux cloud repo attached --session CHAT";
pub(super) const MAX_WAIT_MS: u64 = 60_000;
const MAX_REPLY: u64 = 4 * 1024 * 1024;

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [cloud, repo, rest @ ..] = words.as_slice() else { return None };
    if cloud != "cloud" || repo != "repo" {
        return None;
    }
    if rest.is_empty()
        || matches!(rest, [_, flag] if matches!(flag.as_str(), "--help" | "-h"))
        || matches!(rest, [flag] if matches!(flag.as_str(), "help" | "--help" | "-h"))
    {
        println!("{HELP}");
        return Some(0);
    }
    let request = match parse(rest) {
        Ok(request) => request,
        Err(error) => {
            return Some(super::app::failure("usage.invalid", &error.0, global.output, 2));
        }
    };
    Some(match call(&global, request.0, request.1) {
        Ok(value) => {
            println!("{value}");
            i32::from(value.get("code").is_some())
        }
        Err(failure) => {
            println!("{}", failure.error);
            1
        }
    })
}

fn parse(args: &[String]) -> Result<(&'static str, Value), UsageError> {
    let Some((verb, rest)) = args.split_first() else { return Err(UsageError::new(HELP)) };
    let action = match verb.as_str() {
        "list" | "ls" => "cloud.repo.list",
        "add" => "cloud.repo.add",
        "wait-github" => "cloud.repo.wait_github",
        "local" => "cloud.repo.local",
        "sync" => "cloud.repo.sync",
        "attached" => "cloud.repo.attached",
        _ => return Err(UsageError::new(HELP)),
    };
    let mut fields = Map::new();
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let (flag, value) = match flag.split_once('=') {
            Some(pair) => pair,
            None => (flag.as_str(), words.next().ok_or_else(|| UsageError::new(HELP))?.as_str()),
        };
        let key = match flag {
            "--session" => "session",
            "--query" => "query",
            "--repo" => "repo",
            "--ref" => "ref",
            "--timeout-ms" => "timeout_ms",
            "--repos-json" => "repos",
            "--recent-json" => "recent",
            "--install-url" => "install_url",
            "--complete" => "complete",
            _ => return Err(UsageError::new(HELP)),
        };
        let value = if matches!(key, "repos" | "recent") {
            serde_json::from_str(value)
                .map_err(|_| UsageError::new(format!("{flag} must be a JSON array")))?
        } else if key == "complete" {
            json!(
                value
                    .parse::<bool>()
                    .map_err(|_| UsageError::new("--complete must be true or false"))?
            )
        } else if key == "timeout_ms" {
            json!(value.parse::<u64>().map_err(|_| UsageError::new(HELP))?)
        } else {
            json!(value)
        };
        if fields.insert(key.to_owned(), value).is_some() {
            return Err(UsageError::new(format!("{flag} was given twice\n{HELP}")));
        }
    }
    validate(action, &fields).map_err(UsageError::new)?;
    Ok((action, Value::Object(fields)))
}

pub(super) fn validate(action: &str, fields: &Map<String, Value>) -> Result<(), String> {
    let allowed: &[&str] = match action {
        "cloud.repo.list" => &["session", "query"],
        "cloud.repo.add" => &["session", "repo", "ref"],
        "cloud.repo.wait_github" => &["session", "timeout_ms"],
        "cloud.repo.attached" => &["session"],
        "cloud.repo.local" => &[],
        "cloud.repo.sync" => &["repos", "recent", "install_url", "complete"],
        _ => return Err("unknown Cloud repo action".into()),
    };
    for (key, value) in fields {
        if !allowed.contains(&key.as_str()) {
            return Err(format!("{action} does not accept {key}"));
        }
        if matches!(key.as_str(), "repos" | "recent") {
            if !value.is_array() {
                return Err(format!("{key} must be a JSON array"));
            }
        } else if key == "complete" {
            if !value.is_boolean() {
                return Err("complete must be true or false".into());
            }
        } else if key == "timeout_ms" {
            if value.as_u64().is_none_or(|ms| ms > MAX_WAIT_MS) {
                return Err(format!("timeout_ms must be an integer from 0 to {MAX_WAIT_MS}"));
            }
        } else if value.as_str().is_none_or(|value| value.trim().is_empty()) {
            return Err(format!("{key} must be a nonempty string"));
        }
    }
    let required: &[&str] = match action {
        "cloud.repo.add" => &["session", "repo"],
        "cloud.repo.local" => &[],
        "cloud.repo.sync" => &["repos"],
        _ => &["session"],
    };
    for key in required {
        if !fields.contains_key(*key) {
            return Err(format!("{action} requires {key}"));
        }
    }
    Ok(())
}

/// One bounded request on the selected daemon connection. Never retries a
/// partially sent add: the next explicit call consults the daemon's ledger.
pub(super) fn call(global: &GlobalArgs, action: &str, args: Value) -> Result<Value, CallFailure> {
    let fail = |kind, code, message| CallFailure::local(kind, code, message);
    if global.machine.is_some() {
        return Err(fail(
            FailureKind::NotRun,
            "usage.invalid",
            "Use --socket with the Cloud machine daemon connection for repository actions.".into(),
        ));
    }
    let mut request = args.as_object().cloned().ok_or_else(|| {
        fail(FailureKind::NotRun, "usage.invalid", "repo arguments must be an object".into())
    })?;
    validate(action, &request)
        .map_err(|message| fail(FailureKind::NotRun, "usage.invalid", message))?;
    let (socket, derived) =
        super::wire::resolve_socket_with_origin(global).map_err(|error| CallFailure {
            kind: FailureKind::NotRun,
            error: super::wire::resolve_failure(&error),
            idempotency_key: None,
        })?;
    let mut stream =
        cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
            fail(
                FailureKind::NotRun,
                "repo.unavailable",
                format!("Connect to the Cloud machine and retry: {error}"),
            )
        })?;
    let timeout =
        if action == "cloud.repo.add" { Duration::from_secs(610) } else { Duration::from_secs(70) };
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_read_timeout(Some(timeout));
    request.insert("cmd".into(), json!(action));
    request.insert("id".into(), json!("cloud-repo"));
    let mut bytes = Value::Object(request).to_string().into_bytes();
    bytes.push(b'\n');
    let sent_kind = if matches!(action, "cloud.repo.add" | "cloud.repo.sync") {
        FailureKind::InProgress
    } else {
        FailureKind::NotRun
    };
    stream.write_all(&bytes).map_err(|error| {
        fail(
            sent_kind,
            "transport.failed",
            format!("Reconnect to the Cloud machine and retry: {error}"),
        )
    })?;
    let mut line = String::new();
    BufReader::new(stream).take(MAX_REPLY + 1).read_line(&mut line).map_err(|error| {
        fail(
            sent_kind,
            "transport.failed",
            format!("Read the repository status and retry: {error}"),
        )
    })?;
    if line.len() as u64 > MAX_REPLY || !line.ends_with('\n') {
        return Err(fail(
            sent_kind,
            "transport.failed",
            "The machine reply was incomplete; reconnect and retry.".into(),
        ));
    }
    let reply: Value = serde_json::from_str(&line).map_err(|_| {
        fail(
            sent_kind,
            "transport.failed",
            "The machine reply was invalid; reconnect and retry.".into(),
        )
    })?;
    if reply.get("id").and_then(Value::as_str) != Some("cloud-repo") {
        return Err(fail(
            sent_kind,
            "transport.failed",
            "The machine answered another request; reconnect and retry.".into(),
        ));
    }
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        return reply.get("data").cloned().ok_or_else(|| {
            fail(
                sent_kind,
                "transport.failed",
                "The machine returned no repository result; retry.".into(),
            )
        });
    }
    Err(fail(
        FailureKind::Rejected,
        reply.get("error_code").and_then(Value::as_str).unwrap_or("repo.unavailable"),
        reply
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Reconnect to the Cloud machine and retry.")
            .to_owned(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(words: &[&str]) -> Vec<String> {
        words.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn cloud_repo_chat_session_is_not_daemon_routing() {
        let (global, args) = super::super::parse_globals(&words(&[
            "--socket",
            "/tmp/repo-test.sock",
            "cloud",
            "repo",
            "add",
            "--session",
            "chat-1",
            "--repo",
            "cmux-platform",
            "--ref",
            "main",
        ]))
        .unwrap();
        assert_eq!(global.socket.unwrap().to_str(), Some("/tmp/repo-test.sock"));
        assert_eq!(global.session, None);
        assert_eq!(
            parse(&args[2..]).unwrap(),
            ("cloud.repo.add", json!({"session":"chat-1","repo":"cmux-platform","ref":"main"}))
        );
    }

    #[test]
    fn cloud_repo_rejects_mixed_verbs_and_unbounded_waits() {
        assert!(parse(&words(&["list", "--session", "chat", "--repo", "owner/name"])).is_err());
        assert!(parse(&words(&["add", "--repo", "name"])).is_err());
        assert!(
            parse(&words(&["wait-github", "--session", "chat", "--timeout-ms", "60001"])).is_err()
        );
        assert_eq!(
            parse(&words(&["list", "--session=chat", "--query=name"])).unwrap().1,
            json!({"session":"chat","query":"name"})
        );
    }
    #[test]
    fn cloud_repo_socket_sends_shared_action_and_preserves_recovery() {
        use std::os::unix::net::UnixListener;
        let scratch = tempfile::tempdir().unwrap();
        let socket = scratch.path().join("repo.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let result = json!({"code":"repo.needs_github", "message":"Connect GitHub; this add will retry automatically.",
            "install_url":"https://github.com/apps/cmux/installations/new",
            "retry":{"action":"cloud.repo.add","args":{"session":"chat","repo":"project"},"wait_action":"cloud.repo.wait_github"}});
        let response = result.clone();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(
                request,
                json!({"id":"cloud-repo","cmd":"cloud.repo.add","session":"chat","repo":"project"})
            );
            writeln!(reader.get_mut(), "{}", json!({"id":"cloud-repo","ok":true,"data":response}))
                .unwrap();
        });
        let global = GlobalArgs { socket: Some(socket), ..GlobalArgs::default() };
        assert_eq!(
            call(&global, "cloud.repo.add", json!({"session":"chat","repo":"project"})).unwrap(),
            result
        );
        server.join().unwrap();
    }
    #[test]
    fn cloud_repo_catalog_and_attachment_commands_use_the_shared_contract() {
        assert_eq!(parse(&words(&["local"])).unwrap(), ("cloud.repo.local", json!({})));
        assert_eq!(
            parse(&words(&["attached", "--session", "chat"])).unwrap(),
            ("cloud.repo.attached", json!({"session":"chat"}))
        );
        assert_eq!(
            parse(&words(&[
                "sync",
                "--repos-json",
                "[]",
                "--complete",
                "false",
                "--install-url",
                "https://github.com/apps/cmux"
            ]))
            .unwrap(),
            (
                "cloud.repo.sync",
                json!({"repos":[],"complete":false,"install_url":"https://github.com/apps/cmux"})
            )
        );
        for args in [
            words(&["local", "--session", "chat"]),
            words(&["sync", "--repos-json", "{}"]),
            words(&["sync", "--repos-json", "[]", "--complete", "yes"]),
        ] {
            assert!(parse(&args).is_err());
        }
    }
    #[test]
    fn cloud_repo_sync_accepts_recent_array_and_rejects_other_json() {
        assert_eq!(
            parse(&words(&[
                "sync",
                "--repos-json",
                "[]",
                "--recent-json",
                r#"[{"fullName":"o/r","private":true,"source":"recent"}]"#
            ]))
            .unwrap(),
            (
                "cloud.repo.sync",
                json!({"repos":[],"recent":[{"fullName":"o/r","private":true,"source":"recent"}]})
            )
        );
        assert!(parse(&words(&["sync", "--repos-json", "[]", "--recent-json", "{}"])).is_err());
    }
}
