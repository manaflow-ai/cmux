//! The sudo card (`hub/elevation.rs`) end to end on the real daemon binary: an agent-side client
//! asks to run a command as root, cannot answer its own card, the person's connection approves
//! with a known sentinel password, and the agent gets only the command's output. Then nothing the
//! daemon wrote holds the password: every file under the daemon's home and the test's HOME (the
//! event store, which is the transcript, daemon.log at trace level, panics.jsonl, crash and
//! report folders, session temp folders) is scanned for it, and so is every frame each client
//! received. sudo is a stand-in script (`ACPMUX_ELEVATION_SUDO`, read by debug builds only) that
//! checks the password on its stdin and records each call's arguments.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";
/// The password the person types. Distinct enough that no other byte run matches it.
const SENTINEL: &str = "elevation-sentinel-pw-7Q2xK9";

fn person_proof(key: &str, nonce: &str, connection: &str) -> String {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).unwrap();
    let mut message = b"acpmux-person-v1\0unix\0".to_vec();
    message.extend_from_slice(nonce.as_bytes());
    message.push(0);
    message.extend_from_slice(connection.as_bytes());
    hex(&hmac_sha256(&key, &message))
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
    notes: Vec<Value>,
    /// Every line this client received, for the scan.
    seen: String,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        let mut c = Self {
            lines: tokio::io::BufReader::new(rd).lines(),
            wr,
            next: 0,
            notes: Vec::new(),
            seen: String::new(),
        };
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        assert!(r.get("error").is_none(), "initialize: {r}");
        c.notes.push(r);
        c
    }

    async fn person(path: &Path) -> Self {
        let mut c = Self::connect(path).await;
        let challenge =
            c.notes.pop().unwrap()["result"]["_meta"]["acpmux"]["personChallenge"].clone();
        let proof = person_proof(
            KEY,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        );
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "person_prove: {r}");
        c
    }

    async fn line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
            .await
            .expect("daemon answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        self.seen.push_str(&line);
        self.seen.push('\n');
        serde_json::from_str(&line).unwrap()
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        self.next
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        self.reply(id).await
    }

    async fn reply(&mut self, id: i64) -> Value {
        loop {
            let v = self.line().await;
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return v;
            }
            self.notes.push(v);
        }
    }

    async fn note(&mut self, method: &str, pick: impl Fn(&Value) -> bool) -> Value {
        if let Some(i) = self.notes.iter().position(|n| n["method"] == method && pick(&n["params"]))
        {
            return self.notes.remove(i)["params"].clone();
        }
        loop {
            let v = self.line().await;
            if v["method"] == method && pick(&v["params"]) {
                return v["params"].clone();
            }
            self.notes.push(v);
        }
    }
}

struct Daemon {
    child: std::process::Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(sudo: &Path, dir: &Path) -> Self {
        std::fs::write(
            dir.join("config.json"),
            json!({
                "harnesses": {"fake": {"argv": ["python3", FAKE]}},
                "defaultHarness": "fake",
                "permissionPolicy": "ask",
            })
            .to_string(),
        )
        .unwrap();
        // The daemon refuses a home or config another user could write (a umask of 002).
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(dir.join("config.json"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let socket = dir.join("s.sock");
        let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
        // On disk, not --memory: the store is what the scan reads. The most verbose log.
        cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "trace", "--person-key-fd", "3"])
            .env("ACPMUX_HOME", dir)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_ELEVATION_SUDO", sudo)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::fs::File::create(dir.join("daemon.stderr")).unwrap());
        let mut fds = [-1i32; 2];
        // SAFETY: a fresh pipe; both ends are owned here.
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
        let line = format!("{KEY}\n");
        // SAFETY: the write end is open; the line fits the pipe buffer.
        let n = unsafe { libc::write(fds[1], line.as_ptr().cast(), line.len()) };
        assert_eq!(n as usize, line.len());
        // SAFETY: closing our own write end.
        unsafe { libc::close(fds[1]) };
        let read_end = fds[0];
        // SAFETY: only dup2 between fork and exec (async-signal-safe).
        unsafe {
            cmd.pre_exec(move || {
                if libc::dup2(read_end, 3) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = cmd.spawn().unwrap();
        // SAFETY: the child has its own copy on fd 3.
        unsafe { libc::close(read_end) };
        let ready = BufReader::new(child.stdout.take().unwrap())
            .lines()
            .map_while(Result::ok)
            .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
        assert!(
            ready,
            "the daemon exited before its ready line: {}",
            std::fs::read_to_string(dir.join("daemon.stderr")).unwrap_or_default()
        );
        Daemon { child, socket, dir: dir.to_owned() }
    }

    /// SIGTERM and wait: the daemon flushes its store and log as it exits.
    fn stop(&mut self) {
        // SAFETY: the pid of the child this test spawned and still owns.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.stop();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A stand-in sudo: the run prints its `-p` prompt to stderr, reads one password line, refuses a wrong one, and runs the argv
/// after `--`; every call's arguments go to `calls`.
fn fake_sudo(dir: &Path) -> PathBuf {
    let path = dir.join("bin").join("sudo");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(
        &path,
        format!(
            r#"#!/bin/sh
echo "$*" >> '{calls}'
[ "$1" = "-k" ] && exit 0
if [ "$1" = "-n" ]; then echo "sudo: a password is required" >&2; exit 1; fi
printf '%s' "$4" >&2
IFS= read -r pw
if [ "$pw" != '{SENTINEL}' ]; then echo "sudo: incorrect password" >&2; exit 1; fi
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
"#,
            calls = dir.join("calls").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// Every file under `root` whose bytes hold `needle`.
fn files_holding(root: &Path, needle: &[u8]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_owned()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                stack.push(path);
            } else if kind.is_file()
                && std::fs::read(&path).is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle))
            {
                found.push(path);
            }
        }
    }
    found
}

#[tokio::test]
async fn the_password_reaches_sudo_and_no_persisted_surface() {
    let dir = std::env::temp_dir().join(format!("amp-elev-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("work")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    // The stand-in and its call log live outside the daemon's home so the scan below reads only
    // what the daemon wrote (the stand-in's own script holds the sentinel to compare with).
    let tools = std::env::temp_dir().join(format!("amp-elev-sudo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tools);
    std::fs::create_dir_all(&tools).unwrap();
    let sudo = fake_sudo(&tools);
    let mut d = Daemon::start(&sudo, &dir);

    let mut person = Rpc::person(&d.socket).await;
    let s = person.call("session/new", json!({"cwd": dir.join("work"), "mcpServers": []})).await;
    let id = s["result"]["sessionId"].as_str().expect("session").to_owned();
    let attached = person.call("_acpmux/attach", json!({"sessionId": id})).await;
    assert!(attached.get("error").is_none(), "{attached}");

    // The agent's tool asks over the unix socket; the call waits for the card.
    let mut agent = Rpc::connect(&d.socket).await;
    let asked = agent
        .send(
            "_acpmux/elevation_request",
            json!({"sessionId": id, "argv": ["sh", "-c", "echo root-output; cat"], "reason": "leak test", "timeoutSecs": 20}),
        )
        .await;
    let card = person.note("_acpmux/event", |p| p["kind"] == "elevation_request").await;
    assert_eq!(card["msg"]["argv"], json!(["sh", "-c", "echo root-output; cat"]));
    assert_eq!(card["msg"]["reason"], "leak test");
    let card_id = card["msg"]["secretId"].as_str().unwrap().to_owned();

    // The agent cannot answer its own card.
    let forged = agent
        .call(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": card_id, "value": "forged"}),
        )
        .await;
    assert!(forged.get("error").is_some(), "the agent approved its own card: {forged}");

    // A value sudo cannot take (two lines) is refused and the card stays open: no decision is
    // recorded for it (review F2).
    let two_lines = person
        .call(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": card_id, "value": "a\nb"}),
        )
        .await;
    assert!(two_lines.get("error").is_some(), "{two_lines}");
    let approved = person
        .call(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": card_id, "value": SENTINEL}),
        )
        .await;
    assert!(approved.get("error").is_none(), "{approved}");
    let result = agent.reply(asked).await;
    let result = &result["result"];
    assert_eq!(result["outcome"], "approved", "{result}");
    assert_eq!(result["exitCode"], 0, "{result}");
    // `cat` echoed what was left on stdin: nothing, as sudo consumed the password line. Even a
    // command that printed it would have it masked.
    assert_eq!(result["stdout"].as_str().unwrap().trim_end(), "root-output", "{result}");
    let calls = std::fs::read_to_string(tools.join("calls")).unwrap();
    assert_eq!(calls.lines().next(), Some("-n -k -l"), "{calls}");
    let first = calls.lines().find(|l| l.starts_with("-S")).unwrap();
    assert!(first.starts_with("-S -k -p [acpmux-sudo-") && first.contains("] -- sh -c"), "{calls}");
    assert_eq!(calls.lines().last(), Some("-k"), "no `sudo -k` after the run: {calls}");
    person.note("_acpmux/event", |p| p["kind"] == "elevation_decision").await;

    // A second card, denied: final, and the agent is told so.
    let asked = agent
        .send(
            "_acpmux/elevation_request",
            json!({"sessionId": id, "argv": ["id"], "reason": "deny test"}),
        )
        .await;
    let card = person.note("_acpmux/event", |p| p["kind"] == "elevation_request").await;
    let card_id = card["msg"]["secretId"].as_str().unwrap().to_owned();
    person.call("_acpmux/secret_submit", json!({"sessionId": id, "secretId": card_id})).await;
    let denied = agent.reply(asked).await;
    assert_eq!(denied["result"]["outcome"], "denied", "{denied}");
    let late = person
        .call(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": card_id, "value": SENTINEL}),
        )
        .await;
    assert!(late.get("error").is_some(), "a denied card took an approval: {late}");

    // The event store as a client reads it (the transcript), then every file on disk.
    let page = person.call("_acpmux/events", json!({"sessionId": id, "limit": 10000})).await;
    let decisions: Vec<&Value> = page["result"]["events"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|e| e["kind"] == "elevation_decision")
        .collect();
    assert_eq!(decisions.len(), 2, "one decision per card: {decisions:?}");
    let page = page.to_string();
    assert!(page.contains("elevation_run"), "no run record: {page}");
    assert!(!page.contains(SENTINEL), "an event holds the password");
    assert!(!agent.seen.contains(SENTINEL), "the agent's connection carried the password");
    d.stop();
    assert!(dir.join("daemon.log").is_file() || dir.join("daemon.stderr").is_file());
    let leaks = files_holding(&dir, SENTINEL.as_bytes());
    assert!(leaks.is_empty(), "the password is on disk in {leaks:?}");
    let _ = std::fs::remove_dir_all(&tools);
}

/// What a phone signs (`hub/approvers.rs` `message`), written out to state the wire contract.
#[allow(clippy::too_many_arguments)]
fn phone_signature(
    key: &ring::signature::EcdsaKeyPair,
    instance: &str,
    session: &str,
    card: &str,
    option: &str,
    nonce: &str,
    expires: u64,
) -> String {
    let expires = expires.to_string();
    let mut message = b"acpmux-approver-decision-v1".to_vec();
    for part in [instance, "mac-1", "phone-1", session, card, option, nonce, expires.as_str(), ""] {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    let sig = key.sign(&ring::rand::SystemRandom::new(), &message).unwrap();
    sig.as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// The phone answers the sudo card with its enrolled approver key: a connection that is not the
/// person (the phone reaches the daemon through the app's Web connection) counts only with a
/// signature over this card's id, its answer and its nonce, and only once. A secret card stays
/// the person's own even with a signature.
#[tokio::test]
async fn a_phone_approves_a_sudo_card_with_its_signature_once() {
    use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    let key =
        EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
    let dir = std::env::temp_dir().join(format!("amp-elevp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("work")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    let tools = std::env::temp_dir().join(format!("amp-elevp-sudo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tools);
    std::fs::create_dir_all(&tools).unwrap();
    let d = Daemon::start(&fake_sudo(&tools), &dir);

    let mut person = Rpc::person(&d.socket).await;
    let public = key.public_key().as_ref().iter().map(|b| format!("{b:02x}")).collect::<String>();
    let set = person
        .call(
            "_acpmux/approvers_set",
            json!({"macDevice": "mac-1", "approvers": [{"id": "phone-1", "publicKey": public, "name": "iPhone"}]}),
        )
        .await;
    assert!(set.get("error").is_none(), "{set}");
    let s = person.call("session/new", json!({"cwd": dir.join("work"), "mcpServers": []})).await;
    let id = s["result"]["sessionId"].as_str().unwrap().to_owned();
    person.call("_acpmux/attach", json!({"sessionId": id})).await;

    let mut agent = Rpc::connect(&d.socket).await;
    let mut phone = Rpc::connect(&d.socket).await;
    // The phone attaches with the kinds the iPhone app asks for (`AcpmuxHub.chatKinds`), so the
    // card reaches it live, not only the Mac (review F2 of e4f5ef1).
    phone
        .call(
            "_acpmux/attach",
            json!({"sessionId": id, "kinds": ["transcript", "elevation_request", "elevation_decision"],
                   "eventStream": true}),
        )
        .await;
    let asked = agent
        .send(
            "_acpmux/elevation_request",
            json!({"sessionId": id, "argv": ["echo", "ok"], "reason": "phone"}),
        )
        .await;
    let card = person.note("_acpmux/event", |p| p["kind"] == "elevation_request").await;
    let seen = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        phone.note("_acpmux/event", |p| p["kind"] == "elevation_request"),
    )
    .await
    .expect("the phone's attach got no elevation card");
    assert_eq!(seen["msg"]["secretId"], card["msg"]["secretId"], "{seen}");
    let card_id = card["msg"]["secretId"].as_str().unwrap().to_owned();
    let nonce = card["msg"]["decisionNonce"].as_str().unwrap().to_owned();
    let instance = card["msg"]["personInstance"].as_str().unwrap().to_owned();
    let expires =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() + 60;
    let answer = |option: &str, value: Option<&str>, nonce: &str| {
        let sig = phone_signature(&key, &instance, &id, &card_id, option, nonce, expires);
        let mut p = json!({"sessionId": id, "secretId": card_id,
            "_meta": {"acpmux": {"decisionNonce": nonce,
                "approverDecision": {"approver": "phone-1", "expiresAt": expires, "signature": sig}}}});
        if let Some(v) = value {
            p["value"] = json!(v);
        }
        p
    };
    // No signature, or a signature over another option or another nonce: no approval.
    let unsigned = phone
        .call(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": card_id, "value": SENTINEL}),
        )
        .await;
    assert!(unsigned.get("error").is_some(), "an unsigned approval counted: {unsigned}");
    let swapped =
        phone.call("_acpmux/secret_submit", answer("allow_once", Some(SENTINEL), &nonce)).await;
    assert!(swapped.get("error").is_some(), "another option's signature approved: {swapped}");
    let wrong =
        phone.call("_acpmux/secret_submit", answer("card_provide", Some(SENTINEL), "0000")).await;
    assert!(wrong.get("error").is_some(), "{wrong}");
    // A validly signed value the card refuses (two lines) leaves the signature unspent, so the
    // phone's corrected retry below still approves (review F2 of 9357a53).
    let bad =
        phone.call("_acpmux/secret_submit", answer("card_provide", Some("a\nb"), &nonce)).await;
    assert!(bad.get("error").is_some(), "a two-line password was taken: {bad}");
    let ok =
        phone.call("_acpmux/secret_submit", answer("card_provide", Some(SENTINEL), &nonce)).await;
    assert!(ok.get("error").is_none(), "{ok}");
    let result = agent.reply(asked).await;
    assert_eq!(result["result"]["outcome"], "approved", "{result}");
    assert_eq!(result["result"]["stdout"].as_str().unwrap().trim_end(), "ok", "{result}");

    // The same signature on the next card: refused (its nonce and id are the old card's).
    let asked = agent
        .send(
            "_acpmux/elevation_request",
            json!({"sessionId": id, "argv": ["id"], "reason": "again"}),
        )
        .await;
    let next = person.note("_acpmux/event", |p| p["kind"] == "elevation_request").await;
    let mut replay = answer("card_provide", Some(SENTINEL), &nonce);
    replay["secretId"] = next["msg"]["secretId"].clone();
    let replayed = phone.call("_acpmux/secret_submit", replay).await;
    assert!(replayed.get("error").is_some(), "a replayed signature approved: {replayed}");
    // The phone's Deny needs no signature: it only narrows.
    let deny = phone
        .call(
            "_acpmux/secret_submit",
            json!({"sessionId": id, "secretId": next["msg"]["secretId"]}),
        )
        .await;
    assert!(deny.get("error").is_none(), "{deny}");
    assert_eq!(agent.reply(asked).await["result"]["outcome"], "denied");

    // A secret card has no nonce: a phone never fills it.
    agent
        .send("_acpmux/secret_request", json!({"sessionId": id, "name": "API_KEY", "reason": "x"}))
        .await;
    let secret = person.note("_acpmux/event", |p| p["kind"] == "secret_request").await;
    assert!(secret["msg"].get("decisionNonce").is_none(), "{secret}");
    let mut fill = answer("card_provide", Some("v"), &nonce);
    fill["secretId"] = secret["msg"]["secretId"].clone();
    let filled = phone.call("_acpmux/secret_submit", fill).await;
    assert!(filled.get("error").is_some(), "a phone filled a secret card: {filled}");
    drop(d);
    let _ = std::fs::remove_dir_all(&tools);
}
