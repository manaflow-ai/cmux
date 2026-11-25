//! `cmux-projection s3-push` against a local bucket: it puts every blob of a commit's tree, skips
//! the ones the bucket holds, and prints one JSON line.
#![cfg(target_os = "linux")]

use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::TcpListener;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

type Objects = Arc<Mutex<HashMap<String, Vec<u8>>>>;

/// A bucket that keeps what is `PUT`, answers `HEAD` from it and refuses an unsigned request.
fn bucket() -> (String, Objects, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}/blobs/objects", listener.local_addr().unwrap());
    let objects: Objects = Arc::default();
    let methods: Arc<Mutex<Vec<String>>> = Arc::default();
    let (held, seen) = (Arc::clone(&objects), Arc::clone(&methods));
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            let (objects, methods) = (Arc::clone(&held), Arc::clone(&seen));
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                let mut reader = BufReader::new(stream);
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 {
                        return;
                    }
                    let mut headers = HashMap::new();
                    loop {
                        let mut header = String::new();
                        if reader.read_line(&mut header).unwrap_or(0) == 0
                            || header.trim().is_empty()
                        {
                            break;
                        }
                        if let Some((name, value)) = header.split_once(':') {
                            headers
                                .insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
                        }
                    }
                    let mut words = line.split_whitespace();
                    let method = words.next().unwrap_or_default().to_owned();
                    let oid = words
                        .next()
                        .and_then(|path| path.strip_prefix("/blobs/objects/"))
                        .unwrap_or_default()
                        .to_owned();
                    methods.lock().unwrap().push(method.clone());
                    let length =
                        headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
                    let mut body = vec![0u8; length];
                    if reader.read_exact(&mut body).is_err() {
                        return;
                    }
                    let status = if !headers.contains_key("authorization") {
                        "403 Forbidden"
                    } else if method == "PUT" {
                        objects.lock().unwrap().insert(oid, body);
                        "200 OK"
                    } else if objects.lock().unwrap().contains_key(&oid) {
                        "200 OK"
                    } else {
                        "404 Not Found"
                    };
                    let head = format!(
                        "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
                    );
                    if writer.write_all(head.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    (base, objects, methods)
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn push(git_dir: &Path, base: &str, extra: &[&str], stdin: &str) -> (bool, serde_json::Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-projection"))
        .args(["s3-push", "--git-dir"])
        .arg(git_dir)
        .args(["--to", base])
        .args(extra)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("AWS_ACCESS_KEY_ID", "id")
        .env("AWS_SECRET_ACCESS_KEY", "secret")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(stdin.as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "one JSON line: {text:?}");
    (output.status.success(), serde_json::from_str(lines[0]).unwrap())
}

#[test]
fn s3_push_puts_a_commits_blobs_once() {
    let repo = tempfile::tempdir().unwrap();
    let dir = repo.path();
    git(dir, &["init", "-q"]);
    std::fs::create_dir(dir.join("src")).unwrap();
    for (path, text) in [("a.txt", "alpha\n"), ("src/b.rs", "fn main() {}\n"), ("c.txt", "alpha\n")]
    {
        std::fs::write(dir.join(path), text).unwrap();
    }
    git(dir, &["add", "-A"]);
    git(dir, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "t"]);
    let git_dir = dir.join(".git");
    let (base, objects, methods) = bucket();

    let (ok, line) = push(&git_dir, &base, &["--commit", "HEAD"], "");
    assert!(ok, "{line}");
    // a.txt and c.txt are one blob.
    assert_eq!((line["blobs"].as_u64(), line["stored"].as_u64()), (Some(2), Some(2)), "{line}");
    assert_eq!((line["had"].as_u64(), line["failed"].as_u64()), (Some(0), Some(0)), "{line}");
    assert_eq!(line["bytes"].as_u64(), Some(19));
    let alpha = git(dir, &["rev-parse", "HEAD:a.txt"]);
    assert_eq!(objects.lock().unwrap().get(&alpha).map(Vec::as_slice), Some(&b"alpha\n"[..]));

    // Again: one HEAD each, nothing sent.
    methods.lock().unwrap().clear();
    let (ok, line) = push(&git_dir, &base, &["--commit", "HEAD"], "");
    assert!(ok, "{line}");
    assert_eq!((line["had"].as_u64(), line["stored"].as_u64()), (Some(2), Some(0)), "{line}");
    assert_eq!(*methods.lock().unwrap(), ["HEAD", "HEAD"]);

    // Ids on stdin; one the mirror lacks fails the push and is counted.
    let lacking = "0123456789abcdef0123456789abcdef01234567";
    let (ok, line) = push(&git_dir, &base, &[], &format!("{alpha}\n\n{lacking}\n"));
    assert!(!ok);
    assert_eq!((line["blobs"].as_u64(), line["had"].as_u64()), (Some(2), Some(1)), "{line}");
    assert_eq!(line["failed"].as_u64(), Some(1), "{line}");
}
