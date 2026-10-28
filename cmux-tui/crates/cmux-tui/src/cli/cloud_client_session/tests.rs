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
            let body = if request.starts_with(&format!("POST /v1/cloud/machines/{VM}/client-session ")) {
                json!({ "ok": true, "value": { "machine": VM, "vm_id": "fsvm-1", "linux_user": "cmux", "token": TOKEN, "expires_at": 1_800_000_000_000_u64, "api_base_url": base, "ssh": { "host": "ssh.test", "user": "fsvm-1+cmux" } } })
            } else {
                json!({ "statusCode": 3, "stdout": "hello from the machine\n", "stderr": "warn\n" })
            }
            .to_string();
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
