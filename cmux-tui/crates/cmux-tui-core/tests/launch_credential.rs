#![cfg(unix)]
//! P8 slice 3 over a real session socket (plans/cmux-next/identity.md
//! sections 2 and 3): a terminal child gets `CMUX_LAUNCH_CREDENTIAL`, the
//! daemon verifies it per request and names the terminal as the actor, a
//! forged or stale credential is refused, a caller can never send an actor,
//! and `credential.mint | verify | rotate` keep their rules. Every key here is
//! a throwaway made by the daemon under a temporary directory.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_local_auth::frontend_proof::hmac_sha256;
use cmux_tui_core::{Actor, Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const KEY_FILE: [&str; 2] = ["identity", "launch-keys.json"];

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(unique(name));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn serve(mux: &Arc<Mux>, dir: &Path) -> PathBuf {
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    socket
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// One `cmux.protocol/2` request; `extra` adds envelope members.
    fn v2(&mut self, operation: &str, params: Value, extra: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        for (key, value) in extra.as_object().into_iter().flatten() {
            request[key] = value.clone();
        }
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value["id"] == id {
                return value;
            }
        }
    }

    fn verify(&mut self, credential: &str) -> Value {
        let reply = self.v2("credential.verify", json!({"credential": credential}), json!({}));
        assert_eq!(reply["ok"], true, "{reply}");
        reply["result"].clone()
    }

    /// An empty workspace, as a durable mutation; `credential` rides in the envelope.
    fn create_workspace(&mut self, key: &str, credential: Option<&str>) -> Value {
        let mut extra = json!({"idempotency_key": key});
        if let Some(credential) = credential {
            extra["credential"] = json!(credential);
        }
        self.v2("workspace.create", json!({"name": key, "initial_content": "empty"}), extra)
    }

    fn mint(&mut self, acp_session: &str, extra: Value) -> Value {
        self.v2("credential.mint", json!({"acp_session": acp_session}), extra)
    }

    fn rotate(&mut self, key: &str, extra: Value) -> Value {
        let mut extra = extra;
        extra["idempotency_key"] = json!(key);
        self.v2("credential.rotate", json!({}), extra)
    }
}

fn refusal(reply: &Value) -> (String, String) {
    assert_eq!(reply["ok"], false, "{reply}");
    let error = &reply["error"];
    (
        error["code"].as_str().unwrap_or_default().to_string(),
        error["details"]["reason"].as_str().unwrap_or_default().to_string(),
    )
}

fn wait_for_file(path: &Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        if let Ok(text) = std::fs::read_to_string(path) {
            return text;
        }
        assert!(Instant::now() < deadline, "{} never appeared", path.display());
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The same credential with its last MAC character changed.
fn tampered(credential: &str) -> String {
    let mut bytes = credential.as_bytes().to_vec();
    let last = bytes.last_mut().unwrap();
    *last = if *last == b'A' { b'B' } else { b'A' };
    String::from_utf8(bytes).unwrap()
}

#[test]
fn a_terminal_child_gets_a_credential_that_names_its_terminal() {
    let dir = temp_dir("lc-terminal");
    let out = dir.join("credential");
    let script = format!(
        "printf %s \"$CMUX_LAUNCH_CREDENTIAL\" > '{0}.tmp' && mv '{0}.tmp' '{0}'; exec sleep 60",
        out.display()
    );
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), script]),
        ..Default::default()
    };
    let mux = Mux::new(unique("lc-terminal"), options);
    let surface = mux.new_workspace_as(&Actor::Daemon, None, Some((80, 24))).unwrap();
    let terminal = surface.terminal_public_id().unwrap().to_string();
    let socket = serve(&mux, &dir);
    let credential = wait_for_file(&out);
    assert!(credential.starts_with("cmuxlc1."), "the child got no launch credential");

    let mut client = Client::connect(&socket);
    let verified = client.verify(&credential);
    assert_eq!(verified["valid"], true, "{verified}");
    assert_eq!(verified["actor"], format!("terminal:{terminal}"), "{verified}");
    let created = client.create_workspace("lc-terminal-ok", Some(&credential));
    assert_eq!(created["ok"], true, "{created}");

    // A forged MAC is refused before any owner sees the request.
    let forged = tampered(&credential);
    let refused = client.create_workspace("lc-terminal-forged", Some(&forged));
    assert_eq!(refusal(&refused), ("validation.invalid".into(), "credential_invalid".into()));
    assert_eq!(refused["error"]["details"]["field"], "credential", "{refused}");
    assert_eq!(client.verify(&forged)["valid"], false);

    // Closing the terminal revokes its credential.
    mux.close_surface_as(&Actor::Daemon, surface.id).unwrap();
    let closed = client.verify(&credential);
    assert_eq!(closed["valid"], false, "{closed}");
    assert_eq!(closed["reason"], "credential_closed", "{closed}");
    let refused = client.create_workspace("lc-terminal-closed", Some(&credential));
    assert_eq!(refusal(&refused), ("validation.invalid".into(), "credential_closed".into()));

    mux.shutdown();
    server::cleanup(&socket);
}

#[test]
fn a_caller_can_never_send_an_actor() {
    let dir = temp_dir("lc-claim");
    let mux = Mux::new(unique("lc-claim"), SurfaceOptions::default());
    let socket = serve(&mux, &dir);
    let mut client = Client::connect(&socket);
    let claims = [
        json!({"idempotency_key": "lc-claim-1", "actor": "terminal:term_forged"}),
        json!({"idempotency_key": "lc-claim-2", "credential": "not-a-launch-credential"}),
        json!({"idempotency_key": "lc-claim-3", "credential": ""}),
    ];
    for extra in claims {
        let reply = client.v2(
            "workspace.create",
            json!({"name": "claim", "initial_content": "empty"}),
            extra.clone(),
        );
        assert_eq!(reply["ok"], false, "{extra} was accepted: {reply}");
    }
    let in_params = client.v2(
        "workspace.create",
        json!({"name": "claim", "initial_content": "empty", "actor": "terminal:term_forged"}),
        json!({"idempotency_key": "lc-claim-4"}),
    );
    assert_eq!(in_params["ok"], false, "{in_params}");
    mux.shutdown();
    server::cleanup(&socket);
}

#[test]
fn mint_verify_and_rotate_keep_their_rules() {
    let dir = temp_dir("lc-rotate");
    let mux = Mux::new(unique("lc-rotate"), SurfaceOptions::default());
    let socket = serve(&mux, &dir);
    let mut owner = Client::connect(&socket);

    let minted = owner.mint("acp-test-1", json!({}));
    assert_eq!(minted["ok"], true, "{minted}");
    let first = minted["result"]["credential"].as_str().unwrap().to_string();
    let verified = owner.verify(&first);
    assert_eq!(verified["valid"], true, "{verified}");
    assert_eq!(verified["actor"], "acp_session:acp-test-1", "{verified}");

    // An agent (any request that carries a credential) mints and rotates nothing.
    let by_agent = owner.mint("acp-test-2", json!({"credential": first}));
    assert_eq!(refusal(&by_agent).0, "origin.forbidden");
    let by_agent = owner.rotate("lc-rotate-agent", json!({"credential": first}));
    assert_eq!(refusal(&by_agent).0, "origin.forbidden");

    // One rotation keeps the previous key; a retry of the same key rotates once.
    let rotated = owner.rotate("lc-rotate-1", json!({}));
    assert_eq!(rotated["ok"], true, "{rotated}");
    let kid = rotated["result"]["value"]["kid"].as_str().unwrap().to_string();
    assert_eq!(rotated["result"]["replayed"], false, "{rotated}");
    let retried = owner.rotate("lc-rotate-1", json!({}));
    assert_eq!(retried["result"]["value"]["kid"], kid, "{retried}");
    assert_eq!(retried["result"]["replayed"], true, "{retried}");
    assert_eq!(owner.verify(&first)["valid"], true, "one previous key still verifies");

    // A second rotation drops the first key: its credential counts as absent.
    let again = owner.rotate("lc-rotate-2", json!({}));
    assert_eq!(again["ok"], true, "{again}");
    assert_ne!(again["result"]["value"]["kid"], kid, "{again}");
    let stale = owner.verify(&first);
    assert_eq!(stale["valid"], false, "{stale}");
    assert_eq!(stale["reason"], "unknown_key", "{stale}");
    let as_user = owner.create_workspace("lc-rotate-stale", Some(&first));
    assert_eq!(as_user["ok"], true, "a dropped key falls back to the user: {as_user}");

    mux.shutdown();
    server::cleanup(&socket);
}

fn registry_session_dir(root: &Path) -> PathBuf {
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
                return dir;
            }
            if path.is_dir() {
                pending.push(path);
            }
        }
    }
    panic!("no workspace registry under {}", root.display());
}

fn mode(path: &Path) -> u32 {
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

/// `credential` re-signed with `key` under `kid` (a credential an attacker
/// who read a leaked key file could make).
fn resign(credential: &str, kid: &str, key: &[u8]) -> String {
    let claims = credential.split('.').nth(2).unwrap();
    let signed = format!("cmuxlc1.{kid}.{claims}");
    let mac = URL_SAFE_NO_PAD.encode(hmac_sha256(key, signed.as_bytes()));
    format!("{signed}.{mac}")
}

#[test]
fn the_key_file_is_private_and_a_readable_one_is_replaced() {
    let session = unique("lc-keys");
    let first_root = temp_dir("lc-keys-a");
    let mux = Mux::open_persistent(session.clone(), SurfaceOptions::default(), &first_root).unwrap();
    let session_dir = registry_session_dir(&first_root);
    let key_file = session_dir.join(KEY_FILE[0]).join(KEY_FILE[1]);
    assert_eq!(mode(&key_file), 0o600, "{}", key_file.display());
    assert_eq!(mode(key_file.parent().unwrap()), 0o700);
    mux.shutdown();

    // A key file that others could read is never trusted: the daemon makes
    // new keys, so a credential signed with the leaked key does not verify.
    let second_root = temp_dir("lc-keys-b");
    let planted_dir = second_root.join(session_dir.file_name().unwrap()).join(KEY_FILE[0]);
    std::fs::create_dir_all(&planted_dir).unwrap();
    let planted = planted_dir.join(KEY_FILE[1]);
    let leaked = [7u8; 32];
    let contents = json!({"current": "kleaked", "keys": {"kleaked": URL_SAFE_NO_PAD.encode(leaked)}});
    std::fs::write(&planted, contents.to_string()).unwrap();
    std::fs::set_permissions(&planted, std::fs::Permissions::from_mode(0o644)).unwrap();
    let mux = Mux::open_persistent(session, SurfaceOptions::default(), &second_root).unwrap();
    assert_eq!(registry_session_dir(&second_root).join(KEY_FILE[0]), planted_dir);
    assert_eq!(mode(&planted), 0o600);
    assert!(!std::fs::read_to_string(&planted).unwrap().contains("kleaked"), "the key was kept");
    let socket = serve(&mux, &second_root);
    let mut owner = Client::connect(&socket);
    let minted = owner.mint("acp-keys", json!({}));
    let real = minted["result"]["credential"].as_str().unwrap().to_string();
    let forged = owner.verify(&resign(&real, "kleaked", &leaked));
    assert_eq!(forged["valid"], false, "{forged}");
    mux.shutdown();
    server::cleanup(&socket);
}
