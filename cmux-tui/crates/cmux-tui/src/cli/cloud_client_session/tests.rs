use std::io::{Read, Write as _};
use std::net::TcpListener;
use std::sync::mpsc;

use super::*;

const VM: &str = "vm_abcdefghij0123456789";
const TOKEN: &str = "fs-identity-token-0123456789";

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

#[test]
fn parses_create_and_exec() {
    let create = parse(&strings(&[
        "create",
        "--target",
        &format!("machine:{VM}"),
        "--ttl",
        "120",
        "--token-file",
        "/tmp/t",
    ]))
    .unwrap();
    assert_eq!(create.machine, VM);
    assert_eq!(create.ttl, Some(120));
    assert_eq!(create.verb, Verb::Create { token_file: Some("/tmp/t".into()) });
    let exec = parse(&strings(&[
        "exec",
        &format!("--target={VM}"),
        "--timeout-ms",
        "5000",
        "--",
        "uname",
        "-a",
    ]))
    .unwrap();
    assert_eq!(exec.verb, Verb::Exec { command: "uname -a".into(), timeout_ms: 5000 });
    for bad in [
        vec!["create"],
        vec!["create", "--target", "machine:builder"],
        vec!["create", "--target", VM, "--ttl", "30"],
        vec!["create", "--target", VM, "--ttl", "901"],
        vec!["exec", "--target", VM],
        vec!["exec", "--target", VM, "--"],
        vec!["exec", "--target", VM, "--timeout-ms", "300001", "--", "true"],
        vec!["create", "--target", VM, "--timeout-ms", "10"],
        vec!["open", "--target", VM],
    ] {
        assert!(parse(&strings(&bad)).is_err(), "{bad:?}");
    }
}

#[test]
fn credential_and_api_come_from_flags_or_env_and_need_https() {
    let command = parse(&strings(&["create", "--target", VM])).unwrap();
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    assert_eq!(
        resolve(&command, env(&[(API_ENV, "https://api.example/"), (TOKEN_ENV, " cred \n")]))
            .unwrap(),
        ("https://api.example".into(), "cred".into())
    );
    assert!(resolve(&command, env(&[(TOKEN_ENV, "cred")])).is_err());
    assert!(resolve(&command, env(&[(API_ENV, "https://api.example")])).is_err());
    assert!(
        resolve(&command, env(&[(API_ENV, "http://api.example"), (TOKEN_ENV, "cred")])).is_err()
    );
    assert!(
        resolve(&command, env(&[(API_ENV, "http://127.0.0.1:8787"), (TOKEN_ENV, "cred")])).is_ok()
    );
}

/// A fake cmux API and provider on one port: the mint, then (for exec) the command.
fn fake(answers: usize) -> (String, mpsc::Receiver<String>) {
    fake_with(
        answers,
        json!({ "statusCode": 3, "stdout": "hello from the machine\n", "stderr": "warn\n" })
            .to_string(),
    )
}

fn fake_with(answers: usize, exec_body: String) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let base = origin.clone();
    let (sender, requests) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming().take(answers) {
            let mut stream = stream.unwrap();
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 4096];
            let request = loop {
                let n = stream.read(&mut chunk).unwrap();
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
                }
            };
            let body = if request
                .starts_with(&format!("POST /v1/cloud/machines/{VM}/client-session "))
            {
                json!({ "ok": true, "value": { "machine": VM, "vm_id": "fsvm-1", "linux_user": "cmux", "token": TOKEN, "expires_at": 1_800_000_000_000_u64, "api_base_url": base, "ssh": { "host": "ssh.test", "user": "fsvm-1+cmux" } } })
            .to_string()
            } else {
                exec_body.clone()
            };
            let _ = stream.write_all(format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).as_bytes());
            let _ = sender.send(request);
        }
    });
    (origin, requests)
}

#[test]
fn exec_mints_then_runs_the_command_with_the_identity_token_and_never_prints_it() {
    let (origin, requests) = fake(2);
    let command = parse(&strings(&[
        "exec", "--target", VM, "--ttl", "60", "--team", "team_x", "--", "echo", "hi",
    ]))
    .unwrap();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code =
        run(&command, &origin, "cmux-credential", OutputMode::Human, &mut out, &mut err).unwrap();
    assert_eq!(code, 3);
    assert_eq!(String::from_utf8(out).unwrap(), "hello from the machine\n");
    assert_eq!(String::from_utf8(err).unwrap(), "warn\n");
    let mint = requests.recv().unwrap().to_ascii_lowercase();
    assert!(mint.contains("authorization: bearer cmux-credential"), "{mint}");
    assert!(mint.contains("x-cmux-team: team_x"), "{mint}");
    assert!(mint.ends_with("{\"ttl_seconds\":60}"), "{mint}");
    let run = requests.recv().unwrap();
    assert!(run.starts_with("POST /v5/vms/fsvm-1/exec-await "), "{run}");
    assert!(
        run.to_ascii_lowercase().contains(&format!("x-freestyle-identity-access-token: {TOKEN}")),
        "{run}"
    );
    assert!(!run.to_ascii_lowercase().contains("authorization:"), "{run}");
    let body: Value = serde_json::from_str(run.split("\r\n\r\n").nth(1).unwrap()).unwrap();
    assert_eq!(body, json!({ "command": "echo hi", "linuxUser": "cmux", "timeoutMs": 30000 }));
}

#[test]
fn create_writes_the_token_to_a_new_private_file_and_prints_the_ssh_line() {
    use std::os::unix::fs::PermissionsExt;
    let (origin, _requests) = fake(1);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("token");
    let command =
        parse(&strings(&["create", "--target", VM, "--token-file", path.to_str().unwrap()]))
            .unwrap();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&command, &origin, "cred", OutputMode::Human, &mut out, &mut err).unwrap(), 0);
    let printed = String::from_utf8(out).unwrap();
    assert!(printed.contains("ssh fsvm-1+cmux@ssh.test"), "{printed}");
    assert!(!printed.contains(TOKEN), "{printed}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("{TOKEN}\n"));
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    // An existing file is never overwritten.
    let (origin, _requests) = fake(1);
    assert!(
        run(&command, &origin, "cred", OutputMode::Human, &mut Vec::new(), &mut Vec::new())
            .is_err()
    );
}

#[test]
fn errors_print_only_known_codes() {
    assert_eq!(known_code(Some("cloud.machine.not_found")), "cloud.machine.not_found");
    assert_eq!(known_code(Some("cloud.plan.required")), "cloud.plan.required");
    for echoed in
        [TOKEN, "secret", "SECRET", "Bearer abc", "eyJhbGciOi.eyJzdWIi.sig", "NOT_FOUND", ""]
    {
        assert_eq!(known_code(Some(echoed)), "", "{echoed}");
    }
    assert_eq!(known_code(None), "");
}

#[test]
fn exec_answers_are_checked_against_freestyles_schema() {
    let ok = |exit_code, stdout: &str, stderr: &str| {
        Ok(ExecAnswer { exit_code, stdout: stdout.into(), stderr: stderr.into() })
    };
    assert_eq!(
        exec_answer(Some(json!({ "statusCode": 2, "stdout": "o", "stderr": "e" }))),
        ok(2, "o", "e")
    );
    // Every field is optional and nullable; no status means killed at the deadline.
    assert_eq!(exec_answer(Some(json!({ "stdout": null, "statusCode": null }))), ok(124, "", ""));
    assert_eq!(exec_answer(Some(json!({}))), ok(124, "", ""));
    let unreadable = Err("the machine's answer is not readable".to_owned());
    assert_eq!(exec_answer(Some(json!({ "statusCode": 0, "stdout": 5 }))), unreadable);
    assert_eq!(exec_answer(Some(json!({ "statusCode": 0, "stderr": ["x"] }))), unreadable);
    assert_eq!(exec_answer(Some(json!([1]))), unreadable);
    assert_eq!(exec_answer(None), unreadable);
    let no_status = Err("the machine's answer has no readable exit status".to_owned());
    assert_eq!(exec_answer(Some(json!({ "statusCode": 4_294_967_296_i64 }))), no_status);
    assert_eq!(exec_answer(Some(json!({ "statusCode": "0" }))), no_status);
    assert_eq!(exec_answer(Some(json!({ "statusCode": 1.5 }))), no_status);
}

#[test]
fn an_unreadable_exec_answer_is_an_error_not_a_timeout() {
    let (origin, _requests) = fake_with(2, "not json".into());
    let command = parse(&strings(&["exec", "--target", VM, "--", "true"])).unwrap();
    let error = run(&command, &origin, "cred", OutputMode::Human, &mut Vec::new(), &mut Vec::new());
    assert_eq!(error, Err("the machine's answer is not readable".into()));
}

fn session(api_base_url: &str) -> Session {
    serde_json::from_value(json!({ "machine": VM, "vm_id": "fsvm-1", "linux_user": "cmux", "token": TOKEN, "expires_at": 1_u64, "api_base_url": api_base_url, "ssh": { "host": "beta-ssh.freestyle.sh", "user": "fsvm-1+cmux" } })).unwrap()
}

#[test]
fn the_token_goes_only_to_the_providers_api_for_the_asked_machine() {
    for ok in [
        "https://api.freestyle.sh",
        "https://api.freestyle.sh/",
        "http://127.0.0.1:9",
        "https://localhost",
    ] {
        assert!(checked_session(session(ok), VM, "cred").is_ok(), "{ok}");
    }
    for bad in [
        "https://evil.example",
        "http://api.freestyle.sh",
        "https://freestyle.sh.evil.example",
        "https://user:pw@api.freestyle.sh",
        "https://api.freestyle.sh/?x=1",
        "https://api.freestyle.sh/#f",
        "https://api.freestyle.sh/v5",
        "http://10.0.0.1",
    ] {
        assert!(checked_session(session(bad), VM, "cred").is_err(), "{bad}");
    }
    // Another machine's session is refused.
    assert!(
        checked_session(session("https://api.freestyle.sh"), "vm_zzzzzzzzzzzzzzzzzzzz", "cred")
            .is_err()
    );
}

#[test]
fn printed_fields_are_plain_and_never_carry_a_secret() {
    let with = |key: &str, value: Value| {
        let mut v = serde_json::to_value(json!({ "machine": VM, "vm_id": "fsvm-1", "linux_user": "cmux", "token": TOKEN, "expires_at": 1_u64, "api_base_url": "https://api.freestyle.sh", "ssh": { "host": "beta-ssh.freestyle.sh", "user": "fsvm-1+cmux" } })).unwrap();
        v[key] = value;
        serde_json::from_value::<Session>(v).unwrap()
    };
    assert!(checked_session(with("vm_id", json!(TOKEN)), VM, "cred").is_err());
    assert!(checked_session(with("vm_id", json!("a b")), VM, "cred").is_err());
    assert!(checked_session(with("vm_id", json!("credential-x")), VM, "credential-x").is_err());
    assert!(checked_session(with("linux_user", json!("Root")), VM, "cred").is_err());
    assert!(
        checked_session(with("ssh", json!({ "host": TOKEN, "user": "fsvm-1+cmux" })), VM, "cred")
            .is_err()
    );
    assert!(
        checked_session(
            with("ssh", json!({ "host": "beta-ssh.freestyle.sh", "user": TOKEN })),
            VM,
            "cred"
        )
        .is_err()
    );
    assert!(checked_session(with("ssh", Value::Null), VM, "cred").is_ok());
    assert!(checked_session(with("token", json!("")), VM, "cred").is_err());
    // The token is never the credential, and neither secret is in a printed field.
    assert!(checked_session(with("token", json!("xx-cred-xx")), VM, "cred").is_err());
    assert!(checked_session(with("token", json!(VM)), VM, "cred").is_err());
    assert!(checked_session(with("token", json!("fsvm-1+cmux")), VM, "cred").is_err());
    assert!(checked_session(with("token", json!("https://api.freestyle.sh")), VM, "cred").is_err());
    assert!(checked_session(session("https://api.freestyle.sh"), VM, VM).is_err());
}

#[test]
fn a_credential_that_spells_a_known_code_is_not_printed() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut chunk = [0_u8; 4096];
        let _ = stream.read(&mut chunk);
        let body = json!({ "ok": false, "error": { "code": "auth.forbidden" } }).to_string();
        let _ = stream.write_all(format!("HTTP/1.1 403 Forbidden\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).as_bytes());
    });
    let command = parse(&strings(&["exec", "--target", VM, "--", "true"])).unwrap();
    let error =
        run(&command, &origin, "forbidden", OutputMode::Human, &mut Vec::new(), &mut Vec::new())
            .unwrap_err();
    // A credential inside a known code blanks the code.
    assert!(!error.contains("forbidden"), "{error}");
}

#[test]
fn the_configured_api_url_carries_no_secret_and_is_never_echoed() {
    for bad in [
        "https://api.example/?token=s3cret",
        "https://u:s3cret@api.example",
        "https://api.example/#s3cret",
        "http://api.example/s3cret",
        "https://api.example/s3cret",
    ] {
        let error = secure_origin(bad).unwrap_err();
        assert!(!error.contains("s3cret"), "{error}");
    }
    assert_eq!(secure_origin("https://api.example/"), Ok("https://api.example".to_owned()));
}

#[test]
fn a_numeric_secret_in_the_expiry_is_refused() {
    let with_expiry = |expires_at: u64, token: &str| {
        serde_json::from_value::<Session>(json!({ "machine": VM, "vm_id": "fsvm-1", "linux_user": "cmux", "token": token, "expires_at": expires_at, "api_base_url": "https://api.freestyle.sh", "ssh": null })).unwrap()
    };
    // The credential 1800000000 is the printed expiry in seconds of 1800000000000 ms.
    assert!(checked_session(with_expiry(1_800_000_000_000, TOKEN), VM, "1800000000").is_err());
    // A numeric token in the expiry, in either unit.
    assert!(checked_session(with_expiry(1_800_000_000_000, "1800000000000"), VM, "cred").is_err());
    assert!(checked_session(with_expiry(1_800_000_000_000, "1800000000"), VM, "cred").is_err());
    assert!(checked_session(with_expiry(1_800_000_000_000, TOKEN), VM, "cred").is_ok());
}

#[test]
fn exec_output_and_the_token_file_path_never_carry_a_secret() {
    assert_eq!(redact("a TOKEN b cred c", "TOKEN", "cred"), "a [redacted] b [redacted] c");
    assert_eq!(redact("plain", "TOKEN", "cred"), "plain");
    // The provider echoes the token in stdout and the credential in stderr: both are redacted.
    let echoed =
        json!({ "statusCode": 0, "stdout": format!("x{TOKEN}y"), "stderr": "the cred-secret" })
            .to_string();
    let (origin, _requests) = fake_with(2, echoed);
    let command = parse(&strings(&["exec", "--target", VM, "--", "true"])).unwrap();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&command, &origin, "cred-secret", OutputMode::Human, &mut out, &mut err), Ok(0));
    let (out, err) = (String::from_utf8(out).unwrap(), String::from_utf8(err).unwrap());
    assert!(!out.contains(TOKEN) && !err.contains("cred-secret"), "{out} {err}");
    // A token file path holding the credential is refused before anything is written.
    let dir = std::env::temp_dir().join(format!("cs-path-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cred-secret.token");
    let command =
        parse(&strings(&["create", "--target", VM, "--token-file", path.to_str().unwrap()]))
            .unwrap();
    let (origin, _requests) = fake(1);
    let error =
        run(&command, &origin, "cred-secret", OutputMode::Human, &mut Vec::new(), &mut Vec::new())
            .unwrap_err();
    assert!(!error.contains("cred-secret"), "{error}");
    assert!(!path.exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_unreadable_credential_file_is_not_named() {
    let command = parse(&strings(&[
        "exec",
        "--target",
        VM,
        "--cloud-api",
        "https://api.example",
        "--cloud-token-file",
        "/nonexistent/s3cret-cred",
        "--",
        "true",
    ]))
    .unwrap();
    let error = resolve(&command, |_| None).unwrap_err();
    assert!(!error.contains("s3cret"), "{error}");
}

#[test]
fn quiet_prints_nothing_and_jsonl_prints_one_json_line() {
    // --quiet: create prints nothing, so the minted token never reaches stdout.
    let (origin, _requests) = fake(1);
    let command = parse(&strings(&["create", "--target", VM])).unwrap();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&command, &origin, "cred", OutputMode::Quiet, &mut out, &mut err), Ok(0));
    assert!(out.is_empty() && err.is_empty(), "{out:?} {err:?}");
    // --jsonl: create prints the same single JSON object as --json.
    let (origin, _requests) = fake(1);
    let mut out = Vec::new();
    assert_eq!(
        run(&command, &origin, "cred", OutputMode::JsonLines, &mut out, &mut Vec::new()),
        Ok(0)
    );
    let printed = String::from_utf8(out).unwrap();
    assert_eq!(printed.lines().count(), 1, "{printed}");
    let value: Value = serde_json::from_str(printed.trim_end()).unwrap();
    assert_eq!(value["token"], json!(TOKEN));
    // --quiet exec: no stdout, stderr and the exit code still pass through.
    let (origin, _requests) = fake(2);
    let command = parse(&strings(&["exec", "--target", VM, "--", "true"])).unwrap();
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&command, &origin, "cred", OutputMode::Quiet, &mut out, &mut err), Ok(3));
    assert!(out.is_empty(), "{out:?}");
    assert_eq!(String::from_utf8(err).unwrap(), "warn\n");
    // --jsonl exec: one JSON object.
    let (origin, _requests) = fake(2);
    let mut out = Vec::new();
    assert_eq!(
        run(&command, &origin, "cred", OutputMode::JsonLines, &mut out, &mut Vec::new()),
        Ok(3)
    );
    let value: Value = serde_json::from_str(String::from_utf8(out).unwrap().trim_end()).unwrap();
    assert_eq!(value["exit_code"], json!(3));
}

#[test]
fn quiet_create_still_writes_the_token_file_and_refuses_a_secret_path() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    // The file is written, private, while nothing is printed.
    let path = dir.path().join("token");
    let command =
        parse(&strings(&["create", "--target", VM, "--token-file", path.to_str().unwrap()]))
            .unwrap();
    let (origin, _requests) = fake(1);
    let (mut out, mut err) = (Vec::new(), Vec::new());
    assert_eq!(run(&command, &origin, "cred", OutputMode::Quiet, &mut out, &mut err), Ok(0));
    assert!(out.is_empty() && err.is_empty(), "{out:?} {err:?}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), format!("{TOKEN}\n"));
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    // A path that holds the credential is refused under --quiet too, before anything is written.
    let secret = dir.path().join("cred-secret.token");
    let command =
        parse(&strings(&["create", "--target", VM, "--token-file", secret.to_str().unwrap()]))
            .unwrap();
    let (origin, _requests) = fake(1);
    let error =
        run(&command, &origin, "cred-secret", OutputMode::Quiet, &mut Vec::new(), &mut Vec::new())
            .unwrap_err();
    assert!(!error.contains("cred-secret"), "{error}");
    assert!(!secret.exists());
}
