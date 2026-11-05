use std::collections::BTreeMap;

use base64::Engine as _;
use serde_json::json;
use zeroize::Zeroizing;

use super::plan::{self, State};
use super::pull;
use super::store::{MemoryStore, SecretStore, UNAVAILABLE};
use super::wire::{self, Answer, EnvItem};

const SECRET_A: &str = "sk-synthetic-AAAA-1111";
const SECRET_B: &str = "multi\nline 'quoted' \"value\" $HOME";
const CRED: &str = "cmm_synthetic-live";

/// The machine credential is still `CRED`.
fn live() -> Option<(String, bool)> {
    Some((CRED.to_owned(), false))
}

fn b64(value: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(value)
}

fn body(value: serde_json::Value) -> Vec<u8> {
    serde_json::to_vec(&value).unwrap()
}

fn active(name: &str, revision: u64, value: &str) -> EnvItem {
    EnvItem { name: name.into(), revision, value: Some(Zeroizing::new(value.into())), proxy: None }
}

fn salted() -> State {
    let mut state = State::parse(None);
    state.ensure_salt(|| [7; 16]);
    state
}

fn granted(answer: Answer) -> Vec<EnvItem> {
    match answer {
        Answer::Granted { env, .. } => env,
        other => panic!("not granted: {other:?}"),
    }
}

/// Every text a person or a log can see.
fn assert_no_value(text: &str) {
    for secret in [SECRET_A, SECRET_B, &b64(SECRET_A), &b64(SECRET_B)] {
        assert!(!text.contains(secret), "a value leaked into: {text}");
    }
}

#[test]
fn a_granted_answer_reads_env_only_and_refuses_unsafe_names() {
    let answer = wire::parse(
        200,
        &body(json!({
            "harnessCredentials": [{"harness": "claude", "state": "active", "revision": 1,
                "fingerprint": "x", "contentBase64": b64("{\"claudeAiOauth\":{}}")}],
            "env": [
                {"name": "OPENAI_API_KEY", "revision": 2, "state": "active", "valueBase64": b64(SECRET_A)},
                {"name": "OPENAI_API_KEY", "revision": 1, "state": "active", "valueBase64": b64("old")},
                {"name": "MULTI", "revision": 3, "state": "active", "valueBase64": b64(SECRET_B)},
                {"name": "GONE", "revision": 4, "state": "revoked"},
                {"name": "PATH", "revision": 1, "state": "active", "valueBase64": b64("/evil")},
                {"name": "LD_PRELOAD", "revision": 1, "state": "active", "valueBase64": b64("x")},
                {"name": "CLAUDE_CODE_OAUTH_TOKEN", "revision": 1, "state": "active", "valueBase64": b64("x")},
                {"name": "NO_VALUE", "revision": 1, "state": "active"},
                {"name": "BAD_B64", "revision": 1, "state": "active", "valueBase64": "!!!"},
                {"name": "NO_REVISION", "state": "active", "valueBase64": b64("x")},
            ],
        })),
    );
    assert_no_value(&format!("{answer:?}"));
    let Answer::Granted { env, refused } = answer else { panic!() };
    assert_eq!(refused, 6);
    let names: Vec<_> = env.iter().map(|e| (e.name.as_str(), e.revision)).collect();
    assert_eq!(names, [("GONE", 4), ("MULTI", 3), ("OPENAI_API_KEY", 2)]);
    assert!(env[0].value.is_none());
    assert_eq!(env[1].value.as_deref().map(String::as_str), Some(SECRET_B));
    assert_eq!(env[2].value.as_deref().map(String::as_str), Some(SECRET_A));
}

#[test]
fn hub_statuses_map_to_results() {
    let not_granted = body(json!({"error": {"code": "vault.not_granted"}}));
    assert!(matches!(wire::parse(403, &not_granted), Answer::NotGranted));
    let flat = body(json!({"code": "vault.not_granted"}));
    assert!(matches!(wire::parse(403, &flat), Answer::NotGranted));
    let other = body(json!({"code": "team.forbidden"}));
    assert!(matches!(wire::parse(403, &other), Answer::Refused(c) if c == "team.forbidden"));
    assert!(matches!(wire::parse(401, b"{}"), Answer::Revoked));
    assert!(matches!(wire::parse(404, b""), Answer::Off));
    assert!(matches!(wire::parse(503, b""), Answer::Retry(c) if c == "http.503"));
    assert!(matches!(wire::parse(200, b"{}"), Answer::Refused(c) if c == "vault.malformed"));
    // A free-text "code" is never echoed.
    let prose = body(json!({"code": "here is sk-synthetic text"}));
    assert!(matches!(wire::parse(400, &prose), Answer::Refused(c) if c == "http.400"));
}

#[test]
fn plan_stores_new_and_changed_keeps_current_and_deletes_revoked_and_gone() {
    let mut state = salted();
    let fp = state.fingerprint("KEEP", "same");
    state.env.insert(
        "KEEP".into(),
        plan::EnvRecord { revision: 1, fingerprint: fp, ..Default::default() },
    );
    let fp = state.fingerprint("CHANGED", "before");
    state.env.insert(
        "CHANGED".into(),
        plan::EnvRecord { revision: 1, fingerprint: fp, ..Default::default() },
    );
    state.env.insert(
        "REVOKED".into(),
        plan::EnvRecord { revision: 1, fingerprint: "f".into(), ..Default::default() },
    );
    state.env.insert(
        "GONE".into(),
        plan::EnvRecord { revision: 1, fingerprint: "f".into(), ..Default::default() },
    );
    let steps = plan::plan(
        &state,
        vec![
            active("KEEP", 1, "same"),
            active("CHANGED", 1, "after"),
            active("NEW", 5, SECRET_A),
            EnvItem { name: "REVOKED".into(), revision: 2, value: None, proxy: None },
            EnvItem { name: "NEVER_HAD".into(), revision: 2, value: None, proxy: None },
        ],
    );
    let text = format!("{steps:?}");
    assert_no_value(&text);
    assert_eq!(
        text,
        "[Keep(KEEP), Store(CHANGED r1), Store(NEW r5), Delete(REVOKED), Delete(GONE)]"
    );
    let wiped = format!("{:?}", plan::wipe(&state));
    assert_eq!(wiped, "[Delete(CHANGED), Delete(GONE), Delete(KEEP), Delete(REVOKED)]");
}

#[test]
fn fingerprints_are_salted_per_machine() {
    let a = salted();
    let mut b = State::parse(None);
    b.ensure_salt(|| [9; 16]);
    assert_ne!(a.fingerprint("K", SECRET_A), b.fingerprint("K", SECRET_A));
    assert_eq!(a.fingerprint("K", SECRET_A), a.fingerprint("K", SECRET_A));
    let mut kept = a.clone();
    kept.ensure_salt(|| [1; 16]);
    assert_eq!(kept.salt, a.salt, "the salt is made once");
}

#[test]
#[cfg(unix)]
fn settle_stores_values_and_the_state_file_is_private_and_holds_no_value() {
    use std::os::unix::fs::PermissionsExt as _;
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted {
        env: vec![active("OPENAI_API_KEY", 2, SECRET_A), active("MULTI", 1, SECRET_B)],
        refused: 0,
    };
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 42).unwrap();
    assert_eq!(outcome.state, "ok");
    assert_eq!(outcome.env, ["MULTI", "OPENAI_API_KEY"]);
    assert_eq!(outcome.stored, ["OPENAI_API_KEY", "MULTI"]);
    assert_eq!(store.get("MULTI").unwrap().as_deref().map(String::as_str), Some(SECRET_B));

    let path = pull::state_path(home.path());
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    let text = std::fs::read_to_string(&path).unwrap();
    assert_no_value(&text);
    let saved: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert_eq!(saved["hub"], "https://hub.test");
    assert_eq!(saved["pulledAt"], 42);
    assert_eq!(saved["lastResult"], "ok");
    assert_eq!(saved["env"]["OPENAI_API_KEY"]["revision"], 2);

    let json = crate::cli::host_vault::outcome_json(&outcome).to_string();
    assert_no_value(&json);
    let state = pull::read_state(home.path());
    let status = crate::cli::host_vault::status_json(
        true,
        &state,
        "memory",
        crate::cli::host_vault::SignedIn::No,
        crate::cli::host_vault::SignedIn::Yes,
    );
    assert_no_value(&status.to_string());
    assert_eq!(status["harnesses"][0]["signedIn"], "no");
    assert_eq!(status["harnesses"][1]["signedIn"], "yes");

    // A second pull with the same answer writes nothing; a revoked entry goes.
    let again = Answer::Granted {
        env: vec![
            active("OPENAI_API_KEY", 2, SECRET_A),
            EnvItem { name: "MULTI".into(), revision: 2, value: None, proxy: None },
        ],
        refused: 0,
    };
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, again, &store, &live, 43).unwrap();
    assert!(outcome.stored.is_empty());
    assert_eq!(outcome.deleted, ["MULTI"]);
    assert_eq!(outcome.env, ["OPENAI_API_KEY"]);
    assert!(store.get("MULTI").unwrap().is_none());

    // Not granted any more: every entry goes, and that is not an error.
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 44)
            .unwrap();
    assert_eq!(outcome.state, "not_granted");
    assert!(outcome.env.is_empty());
    assert!(store.items.lock().unwrap().is_empty());
}

#[test]
#[cfg(unix)]
fn no_secret_store_refuses_env_storage_and_writes_no_file_value() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore { unavailable: true, ..MemoryStore::default() };
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap_err();
    assert_eq!(error.code, UNAVAILABLE);
    let text = std::fs::read_to_string(pull::state_path(home.path())).unwrap();
    assert_no_value(&text);
    assert!(pull::read_state(home.path()).env.is_empty());
    let shown = format!("{:#}", crate::cli::host_vault::failure_for_test(error));
    assert_no_value(&shown);
}

#[test]
#[cfg(unix)]
fn a_revoked_credential_removes_the_entries_and_forget_clears_state() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, Answer::Revoked, &store, &live, 2)
            .unwrap_err();
    assert_eq!(error.code, "vault.revoked");
    assert_eq!(error.deleted, ["API_TOKEN"]);
    assert!(store.items.lock().unwrap().is_empty());

    let answer = Answer::Granted { env: vec![active("API_TOKEN", 3, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 3).unwrap();
    let outcome = pull::forget(home.path(), &store).unwrap();
    assert_eq!(outcome.deleted, ["API_TOKEN"]);
    assert!(store.items.lock().unwrap().is_empty());
    assert!(!pull::state_path(home.path()).exists());
}

#[test]
fn the_daemon_loads_only_values_that_match_their_fingerprints() {
    let store = MemoryStore::default();
    let mut state = salted();
    for (name, value) in [("GOOD", SECRET_A), ("EDITED", "original"), ("MISSING", "x")] {
        let fingerprint = state.fingerprint(name, value);
        state.env.insert(
            name.into(),
            plan::EnvRecord { revision: 1, fingerprint, ..Default::default() },
        );
    }
    store.put("GOOD", SECRET_A).unwrap();
    store.put("EDITED", "changed by hand").unwrap();
    let (vars, skipped) = super::load_values(&state, &store);
    let names: Vec<_> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    assert_eq!(names, [("GOOD", SECRET_A)]);
    assert_eq!(
        skipped,
        [("EDITED".to_owned(), "vault.env_changed"), ("MISSING".to_owned(), "vault.env_missing")]
    );
}

#[test]
fn precedence_is_profile_then_machine_then_vault_then_daemon_then_login() {
    let pairs = |list: &[(&str, &str)]| -> Vec<(String, String)> {
        list.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
    };
    let login: BTreeMap<String, String> =
        pairs(&[("ONLY_LOGIN", "login"), ("KEY", "login")]).into_iter().collect();
    let machine: BTreeMap<String, String> =
        pairs(&[("MACHINE_KEY", "machine")]).into_iter().collect();
    let vault = pairs(&[("KEY", "vault"), ("MACHINE_KEY", "vault"), ("PROFILE_KEY", "vault")]);
    let local = crate::login_env::overlay(login, vault, machine);
    let daemon = pairs(&[("KEY", "daemon"), ("DAEMON_ONLY", "daemon")]);
    let profile: BTreeMap<String, String> =
        pairs(&[("PROFILE_KEY", "profile")]).into_iter().collect();
    let env = crate::login_env::layered(daemon, false, local, Vec::new(), &profile);
    assert_eq!(env["KEY"], "vault", "the vault beats the daemon and the login shell");
    assert_eq!(env["MACHINE_KEY"], "machine", "a machine's own declaration beats the vault");
    assert_eq!(env["PROFILE_KEY"], "profile", "profile, preset and session env beat the vault");
    assert_eq!(env["DAEMON_ONLY"], "daemon");
    assert_eq!(env["ONLY_LOGIN"], "login");
}

#[test]
fn outside_a_daemon_no_vault_env_is_given() {
    // The worker never starts in unit tests: a CLI process gives agents nothing.
    assert!(super::env_for_children().is_empty());
}

#[test]
fn backoff_doubles_up_to_the_pull_interval() {
    assert_eq!(super::backoff(1).as_secs(), 30);
    assert_eq!(super::backoff(2).as_secs(), 60);
    assert_eq!(super::backoff(3).as_secs(), 120);
    assert_eq!(super::backoff(40), super::EVERY);
}

/// One HTTP answer from a loopback "hub", and the request it saw.
async fn fake_hub(status: u16, reply: Vec<u8>) -> (String, tokio::task::JoinHandle<String>) {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut seen = Vec::new();
        let mut buf = [0u8; 4096];
        while !seen.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = socket.read(&mut buf).await.unwrap();
            if n == 0 {
                break;
            }
            seen.extend_from_slice(&buf[..n]);
        }
        let head = format!(
            "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
            reply.len()
        );
        socket.write_all(head.as_bytes()).await.unwrap();
        socket.write_all(&reply).await.unwrap();
        socket.shutdown().await.unwrap();
        String::from_utf8_lossy(&seen).into_owned()
    });
    (origin, task)
}

#[tokio::test]
async fn a_fake_hub_answers_200_403_and_401() {
    let credential = "cmm_synthetic-credential";
    let ok = body(json!({"env": [
        {"name": "API_TOKEN", "revision": 7, "state": "active", "valueBase64": b64(SECRET_A)},
    ]}));
    let (hub, seen) = fake_hub(200, ok).await;
    let env = granted(pull::fetch(&hub, credential).await);
    assert_eq!(env.len(), 1);
    assert_eq!(env[0].revision, 7);
    assert_eq!(env[0].value.as_deref().map(String::as_str), Some(SECRET_A));
    let request = seen.await.unwrap();
    assert!(
        request.starts_with("GET /v1/vault/machine?delivery=proxy.v1 HTTP/1.1\r\n"),
        "{request}"
    );
    assert!(request.to_ascii_lowercase().contains(&format!("authorization: bearer {credential}")));

    let (hub, _) = fake_hub(403, body(json!({"error": {"code": "vault.not_granted"}}))).await;
    assert!(matches!(pull::fetch(&hub, credential).await, Answer::NotGranted));

    let (hub, _) = fake_hub(401, body(json!({"code": "machine.revoked"}))).await;
    assert!(matches!(pull::fetch(&hub, credential).await, Answer::Revoked));
}

#[test]
#[cfg(unix)]
fn a_failed_delete_stops_delivery_at_once_and_is_retried() {
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();

    // Not granted any more, and the keychain refuses the delete.
    store.fail_delete.store(true, Ordering::SeqCst);
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 2)
            .unwrap_err();
    assert_eq!(error.code, pull::PARTIAL);
    let outcome = error.outcome.unwrap();
    assert_eq!(outcome.state, "not_granted");
    assert_eq!(outcome.failed, [("API_TOKEN".to_owned(), "vault.secret_store_delete_failed")]);
    let state = pull::read_state(home.path());
    assert!(state.env.is_empty(), "a revoked entry is never given to agents again");
    assert!(state.pending_delete.contains("API_TOKEN"));
    let (vars, _) = super::load_values(&state, &store);
    assert!(vars.is_empty());
    assert!(store.get("API_TOKEN").unwrap().is_some(), "still in the store");

    // The next pull deletes it, even with an empty answer.
    store.fail_delete.store(false, Ordering::SeqCst);
    let answer = Answer::Granted { env: Vec::new(), refused: 0 };
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 3).unwrap();
    assert_eq!(outcome.deleted, ["API_TOKEN"]);
    assert!(pull::read_state(home.path()).pending_delete.is_empty());
    assert!(store.get("API_TOKEN").unwrap().is_none());
}

#[test]
#[cfg(unix)]
fn a_revoked_credential_with_a_failed_delete_keeps_only_a_cleanup_record() {
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    store.fail_delete.store(true, Ordering::SeqCst);
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, Answer::Revoked, &store, &live, 2)
            .unwrap_err();
    assert_eq!(error.code, "vault.revoked");
    let state = pull::read_state(home.path());
    assert!(state.env.is_empty());
    assert!(state.pending_delete.contains("API_TOKEN"));
    assert_no_value(&std::fs::read_to_string(pull::state_path(home.path())).unwrap());
}

#[test]
fn an_answer_for_a_replaced_or_revoked_credential_is_dropped() {
    assert!(pull::still_current("cmm_a", Some(("cmm_a", false))));
    assert!(!pull::still_current("cmm_a", Some(("cmm_b", false))), "replaced while asking");
    assert!(!pull::still_current("cmm_a", Some(("cmm_a", true))), "revoked while asking");
    assert!(!pull::still_current("cmm_a", None), "unjoined while asking");
}

#[test]
#[cfg(unix)]
fn pulls_are_serialized_by_one_lock() {
    let home = tempfile::tempdir().unwrap();
    let held = pull::lock(home.path(), false).unwrap();
    assert_eq!(pull::lock(home.path(), false).err(), Some("vault.busy"));
    drop(held);
    assert!(pull::lock(home.path(), false).is_ok());
}

#[test]
#[cfg(unix)]
fn forget_without_a_store_fails_and_keeps_its_cleanup_records() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    // A shell without the desktop session's bus: the item cannot be reached.
    let away = MemoryStore { unavailable: true, ..MemoryStore::default() };
    assert_eq!(away.delete("API_TOKEN"), Err(UNAVAILABLE));
    let error = pull::forget(home.path(), &away).unwrap_err();
    assert_eq!(error.code, pull::PARTIAL);
    assert_eq!(error.outcome.unwrap().state, "partial");
    let state = pull::read_state(home.path());
    assert!(state.env.is_empty());
    assert!(state.pending_delete.contains("API_TOKEN"), "the record stays until deleted");
    // Back in the session: forget finishes.
    let outcome = pull::forget(home.path(), &store).unwrap();
    assert_eq!(outcome.deleted, ["API_TOKEN"]);
    assert!(!pull::state_path(home.path()).exists());
}

#[test]
#[cfg(unix)]
fn a_failed_write_fails_the_pull_and_keeps_the_rest() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore { fail_put: Some("BROKEN".into()), ..MemoryStore::default() };
    let answer = Answer::Granted {
        env: vec![active("GOOD", 1, SECRET_A), active("BROKEN", 1, SECRET_B)],
        refused: 0,
    };
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap_err();
    assert_eq!(error.code, pull::PARTIAL);
    let outcome = error.outcome.unwrap();
    assert_eq!(outcome.state, "partial");
    assert_eq!(outcome.stored, ["GOOD"]);
    assert_eq!(outcome.env, ["GOOD"]);
    assert_eq!(outcome.failed, [("BROKEN".to_owned(), "vault.secret_store_write_failed")]);
    let json = crate::cli::host_vault::outcome_json(&outcome);
    assert_eq!(json["state"], "partial");
    assert_eq!(json["failed"][0]["name"], "BROKEN");
    assert_no_value(&json.to_string());
    assert_eq!(pull::read_state(home.path()).last_result.as_deref(), Some(pull::PARTIAL));
}

#[test]
#[cfg(unix)]
fn an_incomplete_load_is_read_again_without_a_state_change() {
    let _one = LOADED_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    super::reset_loaded();
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    let path = pull::state_path(home.path());
    let start = std::time::Instant::now();
    store.fail_get.store(true, Ordering::SeqCst); // a locked keychain
    super::refresh_at(&path, &store, start);
    assert!(super::loaded_names().is_empty());
    store.fail_get.store(false, Ordering::SeqCst); // unlocked
    super::refresh_at(&path, &store, start + std::time::Duration::from_secs(1));
    assert!(super::loaded_names().is_empty(), "no store read per spawn");
    super::refresh_at(&path, &store, start + super::RETRY_INCOMPLETE);
    assert_eq!(super::loaded_names(), ["API_TOKEN"]);
    let given = super::delivered(live(), false);
    assert_eq!(given.len(), 1);
    assert_eq!(given[0].1, SECRET_A);
    assert!(super::delivered(Some(("cmm_replaced".into(), false)), false).is_empty());
    assert!(super::delivered(Some((CRED.into(), true)), false).is_empty());
    assert!(super::delivered(live(), true).is_empty(), "a held removal delivers nothing");

    // Revoked: dropped from memory on the next spawn's check.
    pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 2)
        .unwrap();
    super::refresh_at(&path, &store, start + super::RETRY_INCOMPLETE);
    assert!(super::loaded_names().is_empty());
}

/// One test at a time touches the daemon's in-memory values.
static LOADED_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// A store whose first read lets a withdrawal run before it returns the
/// value it read: a `not_granted` pull racing the daemon's load.
struct RacingStore<'a> {
    inner: &'a MemoryStore,
    home: &'a std::path::Path,
    raced: std::sync::atomic::AtomicBool,
}

impl SecretStore for RacingStore<'_> {
    fn kind(&self) -> &'static str {
        "test"
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        self.inner.put(name, value)
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        let value = self.inner.get(name);
        if !self.raced.swap(true, std::sync::atomic::Ordering::SeqCst) {
            pull::settle(
                self.home,
                "https://hub.test",
                CRED,
                Answer::NotGranted,
                self.inner,
                &live,
                9,
            )
            .unwrap();
        }
        value
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        self.inner.delete(name)
    }
}

#[test]
#[cfg(unix)]
fn a_withdrawal_during_the_load_gives_the_next_spawn_nothing() {
    let _one = LOADED_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    let racing = RacingStore {
        inner: &store,
        home: home.path(),
        raced: std::sync::atomic::AtomicBool::new(false),
    };
    let at = std::time::Instant::now();
    super::reset_loaded();
    assert!(super::deliver_at(home.path(), &racing, &live, at).is_empty());
    assert!(racing.raced.load(std::sync::atomic::Ordering::SeqCst), "the race ran");
    // The next spawn reloads the saved state, which lists nothing.
    assert!(super::deliver_at(home.path(), &store, &live, at).is_empty());
    assert!(super::loaded_names().is_empty());

    // A grant again: the value is given.
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 2, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 10).unwrap();
    let given = super::deliver_at(home.path(), &store, &live, at);
    assert_eq!(given.len(), 1);
    // A held removal gives nothing, before any reload.
    pull::hold(home.path()).unwrap();
    assert!(super::deliver_at(home.path(), &store, &live, at).is_empty());
}

/// A store whose reads see the machine credential replaced or revoked
/// while they run (`machine join --replace` during the daemon's load).
struct SwitchingStore<'a> {
    inner: &'a MemoryStore,
    credential: &'a std::sync::Mutex<Option<(String, bool)>>,
    to: Option<(String, bool)>,
}

impl SecretStore for SwitchingStore<'_> {
    fn kind(&self) -> &'static str {
        "test"
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        self.inner.put(name, value)
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        *self.credential.lock().unwrap() = self.to.clone();
        self.inner.get(name)
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        self.inner.delete(name)
    }
}

#[test]
#[cfg(unix)]
fn a_credential_replaced_or_revoked_during_the_load_gives_nothing() {
    let _one = LOADED_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    for to in [Some(("cmm_replaced".to_owned(), false)), Some((CRED.to_owned(), true)), None] {
        let home = tempfile::tempdir().unwrap();
        let store = MemoryStore::default();
        let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
        let credential = std::sync::Mutex::new(live());
        let switching = SwitchingStore { inner: &store, credential: &credential, to };
        let read = || credential.lock().unwrap().clone();
        let at = std::time::Instant::now();
        super::reset_loaded();
        assert!(super::deliver_at(home.path(), &switching, &read, at).is_empty());
        assert_eq!(read(), switching.to, "the switch ran during the load");
    }
}

#[test]
#[cfg(unix)]
fn the_store_command_output_is_read_while_it_runs() {
    // Far more than a pipe holds: reading only after the exit would stall it.
    let mut cmd = std::process::Command::new("sh");
    cmd.args(["-c", "yes abcdefgh | head -c 400000"]);
    cmd.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
    let (status, out) = super::store::capture(cmd, false).unwrap();
    assert!(status.success());
    assert_eq!(out.len(), 400_000);
}

#[test]
#[cfg(unix)]
fn with_no_secret_store_removals_still_leave_the_delivered_set() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("REVOKE_ME", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    // Over ssh with no session bus: a new value cannot be stored, and the old one is revoked.
    let away = MemoryStore { unavailable: true, ..MemoryStore::default() };
    let answer = Answer::Granted {
        env: vec![
            EnvItem { name: "REVOKE_ME".into(), revision: 2, value: None, proxy: None },
            active("NEW_KEY", 1, SECRET_B),
        ],
        refused: 0,
    };
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &away, &live, 2).unwrap_err();
    assert_eq!(error.code, UNAVAILABLE);
    let state = pull::read_state(home.path());
    assert!(state.env.is_empty(), "the revoked key is no longer delivered");
    assert!(state.pending_delete.contains("REVOKE_ME"));
    assert!(!state.env.contains_key("NEW_KEY"));
    assert_no_value(&std::fs::read_to_string(pull::state_path(home.path())).unwrap());
}

/// A store whose writes wait until the test lets them through.
struct GatedStore {
    inner: MemoryStore,
    entered: std::sync::mpsc::SyncSender<()>,
    gate: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
}

impl SecretStore for GatedStore {
    fn kind(&self) -> &'static str {
        "test"
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        self.entered.send(()).unwrap();
        self.gate.lock().unwrap().recv().unwrap();
        self.inner.put(name, value)
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        self.inner.get(name)
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        self.inner.delete(name)
    }
}

#[test]
#[cfg(unix)]
fn a_credential_replaced_during_a_blocked_store_write_gets_nothing() {
    use std::sync::{Arc, Mutex, mpsc};
    let home = tempfile::tempdir().unwrap();
    let path = home.path().to_path_buf();
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (gate_tx, gate_rx) = mpsc::channel();
    let store = Arc::new(GatedStore {
        inner: MemoryStore::default(),
        entered: entered_tx,
        gate: Mutex::new(gate_rx),
    });
    let credential = Arc::new(Mutex::new((CRED.to_owned(), false)));
    let (worker_store, worker_cred) = (store.clone(), credential.clone());
    let worker = std::thread::spawn(move || {
        let current = move || Some(worker_cred.lock().unwrap().clone());
        let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
        pull::settle(&path, "https://hub.test", CRED, answer, worker_store.as_ref(), &current, 1)
    });
    // The write is in progress: `machine join --replace` lands now.
    entered_rx.recv().unwrap();
    *credential.lock().unwrap() = ("cmm_synthetic-replacement".to_owned(), false);
    gate_tx.send(()).unwrap();
    let error = worker.join().unwrap().unwrap_err();
    assert_eq!(error.code, pull::CREDENTIAL_CHANGED);
    let state = pull::read_state(home.path());
    assert!(state.env.is_empty(), "nothing of the old answer is published");
    assert!(state.pending_delete.contains("API_TOKEN"), "what it stored is cleaned up");
    assert!(state.delivered_names(Some(("cmm_synthetic-replacement", false))).is_empty());
}

#[test]
#[cfg(unix)]
fn delivery_follows_the_credential_the_state_was_pulled_with() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    let state = pull::read_state(home.path());
    assert_eq!(state.delivered_names(Some((CRED, false))), ["API_TOKEN"]);
    assert!(state.delivered_names(Some((CRED, true))).is_empty(), "revoked after the pull");
    assert!(state.delivered_names(Some(("cmm_other", false))).is_empty(), "replaced");
    assert!(state.delivered_names(None).is_empty(), "unjoined after the pull");
    assert!(!std::fs::read_to_string(pull::state_path(home.path())).unwrap().contains(CRED));
    // An answer asked with a credential that is no longer current is not applied at all.
    let gone = || Some(("cmm_other".to_owned(), false));
    let answer = Answer::Granted { env: vec![active("OTHER", 1, SECRET_B)], refused: 0 };
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &gone, 2).unwrap_err();
    assert_eq!(error.code, pull::CREDENTIAL_CHANGED);
    assert!(store.get("OTHER").unwrap().is_none());
}

#[test]
fn empty_and_multiline_values_go_through_the_real_store_commands() {
    for value in ["", SECRET_A, SECRET_B, "ünïcødé"] {
        let item = super::store::encode(value);
        assert!(!item.is_empty() && !item.contains(['\n', '\r', '\0']));
        assert_eq!(super::store::decode(&item).unwrap().as_str(), value);
        for os in ["macos", "linux"] {
            let cmd = super::store::put_command(os, "API_TOKEN", value).unwrap();
            let argv = cmd.argv.join(" ");
            assert!(argv.is_empty() || !argv.contains(item.as_str()), "the item is not in argv");
            if !value.is_empty() {
                assert!(!argv.contains(value));
                assert!(!cmd.stdin.contains(value), "only the encoded value reaches stdin");
            }
            assert!(cmd.stdin.contains(item.as_str()));
            assert_no_value(&format!("{cmd:?}"));
        }
        // What `security find-generic-password -g` prints for the item reads back.
        let stderr = format!("keychain: \"x\"\npassword: \"{}\"\n", item.as_str());
        let read = crate::config::profiles::parse_security_password(&stderr).unwrap();
        assert_eq!(super::store::decode(&read).unwrap().as_str(), value);
    }
    assert!(super::store::decode("plain-without-marker").is_none());
    let answer = wire::parse(
        200,
        &body(
            json!({"env": [{"name": "EMPTY", "revision": 1, "state": "active", "valueBase64": ""}]}),
        ),
    );
    let env = granted(answer);
    assert_eq!(env[0].value.as_deref().map(String::as_str), Some(""));
}

#[test]
#[cfg(unix)]
fn entries_of_a_replaced_credential_are_never_rebound_to_the_new_one() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("A_KEY", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();

    // `machine join --replace`: credential B's first pull finds no vault (404).
    const B: &str = "cmm_synthetic-b";
    let b_live = || Some((B.to_owned(), false));
    let outcome =
        pull::settle(home.path(), "https://hub.test", B, Answer::Off, &store, &b_live, 2).unwrap();
    assert_eq!(outcome.state, "off");
    assert!(outcome.env.is_empty(), "A's entry is not B's");
    let state = pull::read_state(home.path());
    assert!(state.delivered_names(Some((B, false))).is_empty());
    assert!(store.get("A_KEY").unwrap().is_none(), "A's item is deleted");
    assert!(!pull::held(home.path()));

    // Same with a store write that fails under B: nothing of A's carries over.
    let answer = Answer::Granted { env: vec![active("A_KEY", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 3).unwrap();
    let broken = MemoryStore { fail_put: Some("B_KEY".into()), ..MemoryStore::default() };
    broken.put("A_KEY", SECRET_A).unwrap();
    let answer = Answer::Granted { env: vec![active("B_KEY", 1, SECRET_B)], refused: 0 };
    let error =
        pull::settle(home.path(), "https://hub.test", B, answer, &broken, &b_live, 4).unwrap_err();
    assert_eq!(error.code, pull::PARTIAL);
    let state = pull::read_state(home.path());
    assert!(state.delivered_names(Some((B, false))).is_empty());
    assert!(!state.env.contains_key("A_KEY"));
}

#[test]
#[cfg(unix)]
fn a_removal_that_cannot_be_saved_stays_held_and_delivers_nothing() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    assert!(!pull::held(home.path()));

    // A full disk: the state file cannot be replaced after not_granted.
    pull::FAIL_STATE_WRITE.with(|f| f.set(true));
    let error =
        pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 2)
            .unwrap_err();
    pull::FAIL_STATE_WRITE.with(|f| f.set(false));
    assert_eq!(error.code, "vault.state_write_failed");
    // The old state still lists the entry, but the hold stops delivery.
    assert_eq!(pull::read_state(home.path()).delivered_names(Some((CRED, false))), ["API_TOKEN"]);
    assert!(pull::held(home.path()));
    assert!(super::delivered(live(), pull::held(home.path())).is_empty());

    // A failed request or a hub without a vault re-authorizes nothing: the
    // hold stays and nothing is delivered.
    for answer in [Answer::Retry("vault.hub_unreachable".into()), Answer::Off] {
        let _ = pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 3);
        assert!(pull::held(home.path()));
        assert!(super::delivered(live(), pull::held(home.path())).is_empty());
    }

    // The next pull saves; the hold is lifted with nothing left to give.
    pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 4)
        .unwrap();
    assert!(!pull::held(home.path()));
    assert!(pull::read_state(home.path()).env.is_empty());
}

#[test]
#[cfg(unix)]
fn a_missing_or_changed_store_item_is_rewritten_at_the_same_revision() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = || Answer::Granted {
        env: vec![active("A_KEY", 1, SECRET_A), active("B_KEY", 1, SECRET_B)],
        refused: 0,
    };
    pull::settle(home.path(), "https://hub.test", CRED, answer(), &store, &live, 1).unwrap();

    // Someone deletes one item and overwrites the other outside acpmux.
    store.delete("A_KEY").unwrap();
    store.put("B_KEY", "tampered").unwrap();
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer(), &store, &live, 2).unwrap();
    let mut stored = outcome.stored.clone();
    stored.sort();
    assert_eq!(stored, ["A_KEY", "B_KEY"]);
    assert_eq!(store.get("A_KEY").unwrap().as_deref().map(String::as_str), Some(SECRET_A));
    assert_eq!(store.get("B_KEY").unwrap().as_deref().map(String::as_str), Some(SECRET_B));

    // With both items intact, the same answer writes nothing.
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer(), &store, &live, 3).unwrap();
    assert!(outcome.stored.is_empty());
}

#[test]
fn store_accounts_are_scoped_to_their_daemon_home() {
    let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let account = super::store::account_in(a.path(), "API_TOKEN");
    assert_eq!(account, super::store::account_in(a.path(), "API_TOKEN"), "stable");
    assert_ne!(account, super::store::account_in(b.path(), "API_TOKEN"));
    let id = super::store::home_id(a.path());
    assert_eq!(account, format!("env/{id}/API_TOKEN"));
    assert_eq!(id.len(), 16);
}

#[test]
#[cfg(unix)]
fn the_pool_stamp_changes_on_every_vault_change() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let first = super::stamp_in(home.path(), live());
    let answer = Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    let granted = super::stamp_in(home.path(), live());
    assert_ne!(first, granted, "a pull");
    assert_no_value(&granted);
    assert!(!granted.contains(CRED), "the credential is digested");
    assert_eq!(granted, super::stamp_in(home.path(), live()), "stable");
    pull::hold(home.path()).unwrap();
    assert_ne!(granted, super::stamp_in(home.path(), live()), "a hold");
    pull::release(home.path());
    assert_ne!(granted, super::stamp_in(home.path(), Some((CRED.into(), true))), "a revocation");
    assert_ne!(granted, super::stamp_in(home.path(), Some(("cmm_new".into(), false))), "a rejoin");
    std::thread::sleep(std::time::Duration::from_millis(20));
    pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 2)
        .unwrap();
    assert_ne!(granted, super::stamp_in(home.path(), live()), "a withdrawal");
}

#[test]
fn a_new_join_pulls_before_the_first_spawn() {
    assert!(super::needs_initial_pull(false, true));
    assert!(!super::needs_initial_pull(true, true), "a cached state serves the first spawn");
    assert!(!super::needs_initial_pull(false, false), "not joined: nothing to pull");
}

#[tokio::test(start_paused = true)]
async fn the_initial_pull_is_bounded() {
    let slow = async {
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        "late"
    };
    assert_eq!(super::bounded(super::INITIAL_WAIT, slow).await, None);
    assert_eq!(super::bounded(super::INITIAL_WAIT, async { "ok" }).await, Some("ok"));
}

#[test]
fn entries_a_spawn_cannot_carry_are_refused() {
    let item = |name: &str, len: usize| json!({"name": name, "revision": 1, "state": "active", "valueBase64": b64(&"x".repeat(len))});
    // One string over Linux's per-string limit with its `NAME=`: E2BIG.
    let answer =
        wire::parse(200, &body(json!({"env": [item("BIG_VALUE", 131_070), item("OK", 10)]})));
    let Answer::Granted { env, refused } = answer else { panic!("not granted") };
    assert_eq!(refused, 1);
    assert_eq!(env.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["OK"]);
    assert_eq!(wire::env_string_bytes("OK", "abc"), 7);

    // Together over the vault's share of the exec space: the last by name goes.
    let answer = wire::parse(
        200,
        &body(
            json!({"env": [item("A_KEY", 100_000), item("B_KEY", 100_000), item("C_KEY", 100_000)]}),
        ),
    );
    let Answer::Granted { env, refused } = answer else { panic!("not granted") };
    assert_eq!(refused, 1);
    assert_eq!(env.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["A_KEY", "B_KEY"]);
    let total: usize = env
        .iter()
        .map(|e| wire::env_string_bytes(&e.name, e.value.as_deref().map_or("", String::as_str)))
        .sum();
    assert!(total <= wire::MAX_VAULT_ENV_BYTES);
}

#[test]
#[cfg(unix)]
fn a_refused_oversize_entry_is_removed_from_the_store() {
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let answer = Answer::Granted { env: vec![active("BIG", 1, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    // The hub now sends a value too large to spawn with: parse refuses it,
    // so the answer no longer lists it and the stored one goes.
    let big = json!({"name": "BIG", "revision": 2, "state": "active",
        "valueBase64": b64(&"x".repeat(131_070))});
    let answer = wire::parse(200, &body(json!({"env": [big]})));
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 2).unwrap();
    assert_eq!(outcome.deleted, ["BIG"]);
    assert!(store.get("BIG").unwrap().is_none());
}

#[test]
fn a_load_reads_nothing_past_its_deadline() {
    let mut state = salted();
    let store = MemoryStore::default();
    store.put("API_TOKEN", SECRET_A).unwrap();
    state.env.insert(
        "API_TOKEN".into(),
        plan::EnvRecord {
            revision: 1,
            fingerprint: state.fingerprint("API_TOKEN", SECRET_A),
            ..Default::default()
        },
    );
    let past = std::time::Instant::now();
    let (vars, skipped) = super::load_values_by(&state, &store, past);
    assert!(vars.is_empty());
    assert_eq!(skipped, [("API_TOKEN".to_owned(), "vault.load_timeout")]);
    let (vars, skipped) = super::load_values(&state, &store);
    assert_eq!(vars.len(), 1);
    assert!(skipped.is_empty());
}

#[test]
fn the_store_probe_needs_a_write_a_read_and_a_delete() {
    use super::store::{probe, probe_as, probe_name};
    let usable = MemoryStore::default();
    assert!(probe(&usable));
    assert!(usable.items.lock().unwrap().is_empty(), "the probe item is removed");
    // A headless Mac over ssh: the store is there but takes no write.
    let name = probe_name();
    let no_write = MemoryStore { fail_put: Some(name.clone()), ..MemoryStore::default() };
    assert!(!probe_as(&no_write, &name));
    let none = MemoryStore { unavailable: true, ..MemoryStore::default() };
    assert!(!probe(&none));
    assert!(!crate::login_env::machine_env_name_allowed(&name), "never a vault name");
    // Each probe has an item of its own: concurrent probes never collide.
    assert_ne!(probe_name(), probe_name());
}

#[test]
#[cfg(unix)]
fn the_daemon_memory_store_keeps_and_drops_values_like_the_os_store() {
    use super::store::ProcessMemory;
    let home = tempfile::tempdir().unwrap();
    let store = ProcessMemory;
    assert_eq!(store.kind(), "memory");
    let answer = Answer::Granted { env: vec![active("MEMORY_ONLY_KEY", 1, SECRET_A)], refused: 0 };
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    assert_eq!(outcome.env, ["MEMORY_ONLY_KEY"]);
    assert_eq!(
        store.get("MEMORY_ONLY_KEY").unwrap().as_deref().map(String::as_str),
        Some(SECRET_A)
    );
    // No value on disk: only the state file, which holds none.
    for entry in std::fs::read_dir(home.path()).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            assert_no_value(&std::fs::read_to_string(&path).unwrap_or_default());
        }
    }
    // The CLI's reply from the daemon: names and `store`, never a value.
    let reply = crate::server::vault_reply("memory", &Ok(outcome));
    assert_eq!(reply["store"], "memory");
    assert_eq!(reply["outcome"]["env"][0], "MEMORY_ONLY_KEY");
    assert_no_value(&reply.to_string());

    // A withdrawal drops it from memory too.
    pull::settle(home.path(), "https://hub.test", CRED, Answer::NotGranted, &store, &live, 2)
        .unwrap();
    assert!(store.get("MEMORY_ONLY_KEY").unwrap().is_none());

    // A restarted daemon has an empty memory: a grant at the same revision
    // puts the value back (the entry is checked, not trusted).
    let answer = Answer::Granted { env: vec![active("MEMORY_ONLY_KEY", 3, SECRET_A)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 3).unwrap();
    store.delete("MEMORY_ONLY_KEY").unwrap();
    let answer = Answer::Granted { env: vec![active("MEMORY_ONLY_KEY", 3, SECRET_A)], refused: 0 };
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 4).unwrap();
    assert_eq!(outcome.stored, ["MEMORY_ONLY_KEY"]);
    pull::forget(home.path(), &store).unwrap();
    assert!(store.get("MEMORY_ONLY_KEY").unwrap().is_none());
}

#[test]
fn a_failed_reply_carries_the_code_and_no_value() {
    let failure = pull::Failure {
        code: "vault.revoked".into(),
        deleted: vec!["A_KEY".into()],
        outcome: None,
    };
    let reply = crate::server::vault_reply("memory", &Err(failure));
    assert_eq!(reply["failure"]["code"], "vault.revoked");
    assert_eq!(reply["failure"]["deleted"][0], "A_KEY");
    assert!(reply["outcome"].is_null());
}

#[test]
#[cfg(unix)]
fn switching_to_memory_keeps_cleaning_up_the_os_store() {
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap();
    // A headless Mac over ssh: the OS store's deletes fail too.
    let os = MemoryStore { fail_delete: true.into(), ..MemoryStore::default() };
    let mem =
        MemoryStore { memory_mode: true, leftovers: Some(Box::new(os)), ..MemoryStore::default() };
    let os = mem.os_leftovers().unwrap();
    let answer = || Answer::Granted { env: vec![active("API_TOKEN", 1, SECRET_A)], refused: 0 };
    // Pulled while the OS store took writes.
    pull::settle(home.path(), "https://hub.test", CRED, answer(), os, &live, 1).unwrap();
    assert!(os.get("API_TOKEN").unwrap().is_some());

    // Now the daemon keeps values in memory: the OS item is tracked for
    // cleanup, and the entry is stored again in memory.
    let outcome =
        pull::settle(home.path(), "https://hub.test", CRED, answer(), &mem, &live, 2).unwrap();
    assert_eq!(outcome.stored, ["API_TOKEN"]);
    assert!(mem.get("API_TOKEN").unwrap().is_some());
    let state = pull::read_state(home.path());
    assert_eq!(state.backend, "memory");
    assert!(state.os_pending.contains("API_TOKEN"));
    assert_eq!(state.delivered_names(Some((CRED, false))), ["API_TOKEN"]);

    // Forget can't delete the OS item yet: it fails and keeps the state file.
    let failure = pull::forget(home.path(), &mem).unwrap_err();
    assert_eq!(failure.code, pull::PARTIAL);
    assert!(mem.get("API_TOKEN").unwrap().is_none(), "the memory value goes at once");
    assert!(pull::state_path(home.path()).exists());
    assert!(pull::read_state(home.path()).os_pending.contains("API_TOKEN"));
    assert!(pull::read_state(home.path()).env.is_empty());

    // Once the OS store takes the delete, forget finishes.
    mem.leftovers.as_ref().unwrap().fail_delete.store(false, Ordering::SeqCst);
    pull::forget(home.path(), &mem).unwrap();
    assert!(os.get("API_TOKEN").unwrap().is_none());
    assert!(!pull::state_path(home.path()).exists());
}

#[test]
fn back_on_the_os_store_leftovers_become_cleanup_records() {
    let mut state = salted();
    state.backend = "memory".into();
    state.os_pending.insert("OLD_KEY".into());
    state.env.insert("MEM_KEY".into(), plan::EnvRecord::default());
    state.switch_backend("keychain");
    assert_eq!(state.backend, "os");
    assert!(state.env.is_empty(), "values in another process's memory are gone");
    assert!(state.os_pending.is_empty());
    assert!(state.pending_delete.contains("OLD_KEY"));
    assert!(!state.pending_delete.contains("MEM_KEY"), "never in the OS store");

    // A state from before `backend` was saved is the OS store's.
    let mut legacy = salted();
    legacy.env.insert("A_KEY".into(), plan::EnvRecord::default());
    legacy.switch_backend("memory");
    assert!(legacy.os_pending.contains("A_KEY"));
    assert!(legacy.env.is_empty());
}

/// Reads of `fail` fail; every read's deadline is recorded.
#[derive(Default)]
struct PickyStore {
    inner: MemoryStore,
    fail: std::sync::Mutex<Option<String>>,
    deadlines: std::sync::Mutex<Vec<std::time::Instant>>,
}

impl SecretStore for PickyStore {
    fn kind(&self) -> &'static str {
        "test"
    }
    fn put(&self, name: &str, value: &str) -> Result<(), &'static str> {
        self.inner.put(name, value)
    }
    fn get(&self, name: &str) -> Result<Option<Zeroizing<String>>, &'static str> {
        if self.fail.lock().unwrap().as_deref() == Some(name) {
            return Err("vault.secret_store_read_failed");
        }
        self.inner.get(name)
    }
    fn get_by(
        &self,
        name: &str,
        deadline: std::time::Instant,
    ) -> Result<Option<Zeroizing<String>>, &'static str> {
        self.deadlines.lock().unwrap().push(deadline);
        self.get(name)
    }
    fn delete(&self, name: &str) -> Result<(), &'static str> {
        self.inner.delete(name)
    }
}

#[test]
#[cfg(unix)]
fn a_retry_reads_only_what_was_missing_and_keeps_the_rest() {
    let _one = LOADED_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    super::reset_loaded();
    let home = tempfile::tempdir().unwrap();
    let store = PickyStore::default();
    let answer = Answer::Granted {
        env: vec![active("A_KEY", 1, SECRET_A), active("B_KEY", 1, SECRET_B)],
        refused: 0,
    };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    let path = pull::state_path(home.path());
    let start = std::time::Instant::now();
    *store.fail.lock().unwrap() = Some("B_KEY".into());
    super::refresh_at(&path, &store, start);
    assert_eq!(super::loaded_names(), ["A_KEY"]);
    // Now A cannot be read, B can: the retry reads B only and keeps A.
    *store.fail.lock().unwrap() = Some("A_KEY".into());
    store.deadlines.lock().unwrap().clear();
    super::refresh_at(&path, &store, start + super::RETRY_INCOMPLETE);
    let mut names = super::loaded_names();
    names.sort();
    assert_eq!(names, ["A_KEY", "B_KEY"]);
    assert_eq!(store.deadlines.lock().unwrap().len(), 1, "one read: B");
}

#[test]
fn every_store_read_gets_the_load_deadline() {
    let mut state = salted();
    let store = PickyStore::default();
    store.put("API_TOKEN", SECRET_A).unwrap();
    state.env.insert(
        "API_TOKEN".into(),
        plan::EnvRecord {
            revision: 1,
            fingerprint: state.fingerprint("API_TOKEN", SECRET_A),
            ..Default::default()
        },
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    let (vars, _) = super::load_values_by(&state, &store, deadline);
    assert_eq!(vars.len(), 1);
    assert_eq!(*store.deadlines.lock().unwrap(), [deadline]);
}

#[test]
#[cfg(unix)]
fn a_store_command_crossing_the_deadline_is_stopped_there() {
    let mut cmd = std::process::Command::new("sh");
    cmd.args(["-c", "sleep 5"]).stdout(std::process::Stdio::piped());
    let start = std::time::Instant::now();
    let deadline = start + std::time::Duration::from_millis(200);
    let result = super::store::capture_until(cmd, false, deadline);
    assert_eq!(result.err(), Some("vault.secret_store_timeout"));
    assert!(start.elapsed() < std::time::Duration::from_secs(3), "stopped at the deadline");
}

#[test]
#[cfg(unix)]
fn a_store_command_whose_child_keeps_the_pipe_stops_at_the_deadline() {
    // The command exits at once; the `sleep` it started holds stdout open.
    let mut cmd = std::process::Command::new("sh");
    cmd.args(["-c", "sleep 20 & exit 0"]).stdout(std::process::Stdio::piped());
    let start = std::time::Instant::now();
    let deadline = start + std::time::Duration::from_millis(300);
    let result = super::store::capture_until(cmd, false, deadline);
    assert_eq!(result.err(), Some("vault.secret_store_timeout"));
    assert!(start.elapsed() < std::time::Duration::from_secs(3), "stopped at the deadline");
}

#[test]
#[cfg(unix)]
fn a_store_command_that_exits_gives_its_whole_output() {
    let mut cmd = std::process::Command::new("sh");
    cmd.args(["-c", "printf done"]).stdout(std::process::Stdio::piped());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let (status, out) = super::store::capture_until(cmd, false, deadline).expect("ran");
    assert!(status.success());
    assert_eq!(out.as_slice(), b"done");
}

#[test]
fn an_older_daemon_is_told_apart_and_the_refusal_says_to_restart_it() {
    use crate::cli::host_vault::{DAEMON_OUTDATED, method_not_found};
    let old: anyhow::Error =
        crate::client::DaemonError(crate::rpc::RpcError::method_not_found("_acpmux/vault_pull"))
            .into();
    assert!(method_not_found(&old));
    let other: anyhow::Error =
        crate::client::DaemonError(crate::rpc::RpcError::new(-32000, "busy")).into();
    assert!(!method_not_found(&other));
    assert!(!method_not_found(&anyhow::anyhow!("connection closed")));
    let shown = format!(
        "{:#}",
        crate::cli::host_vault::failure_for_test(pull::Failure {
            code: DAEMON_OUTDATED.into(),
            deleted: Vec::new(),
            outcome: None,
        })
    );
    assert!(shown.contains("acpmux daemon restart"), "{shown}");
}

#[test]
fn delivery_and_allowed_hosts_are_read_and_withheld_entries_are_not_delivered() {
    let answer = wire::parse(
        200,
        &body(json!({"env": [
            {"name": "PROXIED", "revision": 3, "state": "active", "valueBase64": b64(SECRET_A),
             "delivery": "proxy", "allowedHosts": ["api.github.com", "*.example.com:8443", "API.EVIL", "https://x.y", "api.github.com"]},
            {"name": "OPTED_OUT", "revision": 4, "state": "active", "valueBase64": b64(SECRET_A),
             "delivery": "env", "allowedHosts": []},
            {"name": "OLD_HUB", "revision": 5, "state": "active", "valueBase64": b64(SECRET_A)},
            {"name": "WITHHELD", "revision": 6, "state": "withheld", "delivery": "proxy", "allowedHosts": []},
            {"name": "ODD", "revision": 7, "state": "active", "valueBase64": b64(SECRET_A), "delivery": "mail"},
        ]})),
    );
    let Answer::Granted { env, refused } = answer else { panic!("not granted") };
    assert_eq!(refused, 2, "withheld and an unknown delivery are refused");
    let by: BTreeMap<_, _> = env.iter().map(|e| (e.name.as_str(), e)).collect();
    assert_eq!(
        by["PROXIED"].proxy.as_deref(),
        Some(&["api.github.com".to_owned(), "*.example.com:8443".to_owned()][..])
    );
    assert_eq!(by["OPTED_OUT"].proxy, None);
    assert_eq!(by["OLD_HUB"].proxy, None, "a hub before delivery means env");
    assert_no_value(&format!("{env:?}"));
}

#[test]
#[cfg(unix)]
fn a_policy_change_at_the_same_revision_reaches_the_next_spawn() {
    let _one = LOADED_TESTS.lock().unwrap_or_else(|e| e.into_inner());
    let home = tempfile::tempdir().unwrap();
    let store = MemoryStore::default();
    let item = |proxy: Option<Vec<String>>| EnvItem { proxy, ..active("API_TOKEN", 1, SECRET_A) };
    let answer = Answer::Granted { env: vec![item(None)], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 1).unwrap();
    super::reset_loaded();
    let at = std::time::Instant::now();
    let given = super::deliver_at(home.path(), &store, &live, at);
    assert_eq!(given.len(), 1);
    assert_eq!(given[0].proxy, None);

    // env -> proxy without a new revision: the record and the next spawn follow.
    let hosts = vec!["api.github.com".to_owned()];
    let answer = Answer::Granted { env: vec![item(Some(hosts.clone()))], refused: 0 };
    pull::settle(home.path(), "https://hub.test", CRED, answer, &store, &live, 2).unwrap();
    assert_eq!(pull::read_state(home.path()).env["API_TOKEN"].proxy, Some(hosts.clone()));
    let given = super::deliver_at(home.path(), &store, &live, at);
    assert_eq!(given[0].proxy, Some(hosts));
    let env = super::egress::child_env_with(given, None, &|_| None);
    assert_eq!(env, vec![("API_TOKEN".to_owned(), "cmux-secret://API_TOKEN".to_owned())]);

    // The state file names the delivery, never a value.
    let saved = std::fs::read_to_string(pull::state_path(home.path())).unwrap();
    assert!(saved.contains("api.github.com"));
    assert_no_value(&saved);
}
