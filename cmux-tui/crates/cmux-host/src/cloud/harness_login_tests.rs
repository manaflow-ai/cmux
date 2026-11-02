//! One sign-in per person for their Cloud machines (`harness_login.rs`,
//! `harness_login_thread.rs`): the decisions against a fake server with the
//! platform's rules, and the file writer in temp folders.

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde_json::{Value, json};

use super::harness_login::*;
use super::harness_login_thread::{
    Api, CHANGED_SINCE_READ, Pass, Setup, Syncer, read_login, write_atomic, write_login,
};
use super::trajectory::encode_base64;
use super::wire::Env;

fn claude(token: &str) -> Vec<u8> {
    json!({ "claudeAiOauth": { "accessToken": token, "refreshToken": "r", "expiresAt": 1 } })
        .to_string()
        .into_bytes()
}

fn codex(token: &str) -> Vec<u8> {
    json!({ "OPENAI_API_KEY": null, "tokens": { "id_token": token, "access_token": "a", "refresh_token": "r" } })
        .to_string()
        .into_bytes()
}

fn login(bytes: &[u8]) -> Local {
    Local::Login { bytes: bytes.to_vec(), fingerprint: fingerprint(bytes) }
}

fn active(id: &str, revision: u64, bytes: &[u8]) -> Saved {
    Saved {
        harness: id.to_owned(),
        revision,
        active: Some(Active { fingerprint: fingerprint(bytes), content: bytes.to_vec() }),
    }
}

fn revoked(id: &str, revision: u64) -> Saved {
    Saved { harness: id.to_owned(), revision, active: None }
}

fn no_log(_: &str) {}

// ---- the harness table and what is never sent ----

#[test]
fn the_table_keys_harnesses_by_a_generic_id() {
    let ids: Vec<&str> = HARNESSES.iter().map(|h| h.id).collect();
    assert_eq!(ids, ["claude", "codex"]);
    assert!(HARNESSES.iter().all(|h| harness_id_ok(h.id)));
    assert_eq!(harness("claude").unwrap().file, ".claude/.credentials.json");
    assert_eq!(harness("codex").unwrap().file, ".codex/auth.json");
    assert!(harness("gemini").is_none());
    let long = "a".repeat(33);
    for bad in ["", "Claude", "1x", "a_b", long.as_str()] {
        assert!(!harness_id_ok(bad), "{bad}");
    }
    assert!(harness_id_ok(&"a".repeat(32)));
    assert!(harness_id_ok("open-code2"));
}

#[test]
fn a_claude_login_needs_an_oauth_object() {
    let h = harness("claude").unwrap();
    assert_eq!(h.check(&claude("sk-ant-oat01-x")), Ok(()));
    assert_eq!(h.check(br#"{"claudeAiOauth": null}"#), Err(Refusal::NoLogin));
    assert_eq!(h.check(br#"{"claudeAiOauth": {}}"#), Err(Refusal::NoLogin));
    assert_eq!(h.check(br#"{"claudeAiOauth": "x"}"#), Err(Refusal::NoLogin));
    assert_eq!(h.check(br#"{"other": {}}"#), Err(Refusal::NoLogin));
    assert_eq!(h.check(br#"[1]"#), Err(Refusal::NotJson));
    assert_eq!(h.check(b"not json"), Err(Refusal::NotJson));
    assert_eq!(h.check(b""), Err(Refusal::Size));
    let big = format!(r#"{{"claudeAiOauth": {{"a": "{}"}}}}"#, "x".repeat(CONTENT_MAX_BYTES));
    assert_eq!(h.check(big.as_bytes()), Err(Refusal::Size));
}

#[test]
fn a_codex_login_needs_chatgpt_tokens_never_an_api_key_alone() {
    let h = harness("codex").unwrap();
    assert_eq!(h.check(&codex("eyJ")), Ok(()));
    assert_eq!(h.check(br#"{"OPENAI_API_KEY": "sk-proj-1"}"#), Err(Refusal::ApiKeyOnly));
    assert_eq!(
        h.check(br#"{"OPENAI_API_KEY": "sk-proj-1", "tokens": null}"#),
        Err(Refusal::ApiKeyOnly)
    );
    assert_eq!(
        h.check(br#"{"auth_mode": "apikey", "OPENAI_API_KEY": "sk-1", "tokens": {"a": "b"}}"#),
        Err(Refusal::ApiKeyOnly)
    );
    assert_eq!(h.check(br#"{"tokens": null}"#), Err(Refusal::NoLogin));
    assert_eq!(h.check(br#"{"tokens": {}}"#), Err(Refusal::NoLogin));
}

/// CodeRouter signs agents in with the public placeholder key the machine's
/// edge swaps (`agent-auth.sh`) or a `crt_` route token (`agent-config.sh`);
/// such a file is CodeRouter's and is never sent, wherever it sits.
#[test]
fn a_coderouter_login_is_never_sent() {
    let claude_h = harness("claude").unwrap();
    let codex_h = harness("codex").unwrap();
    let placeholder = json!({ "claudeAiOauth": { "accessToken": CODEROUTER_PLACEHOLDER } });
    assert_eq!(claude_h.check(placeholder.to_string().as_bytes()), Err(Refusal::CodeRouter));
    let route = json!({ "tokens": { "access_token": "crt_abc.def" } });
    assert_eq!(codex_h.check(route.to_string().as_bytes()), Err(Refusal::CodeRouter));
    let key = json!({ "OPENAI_API_KEY": CODEROUTER_PLACEHOLDER });
    assert_eq!(codex_h.check(key.to_string().as_bytes()), Err(Refusal::CodeRouter));
    let nested =
        json!({ "tokens": { "a": ["x", { "b": format!("Bearer {CODEROUTER_PLACEHOLDER}") }] } });
    assert_eq!(codex_h.check(nested.to_string().as_bytes()), Err(Refusal::CodeRouter));
    // A route token anywhere in a string, or in a key, is refused too.
    for embedded in [
        json!({ "tokens": { "access_token": "Bearer crt_secret" } }),
        json!({ "tokens": { "access_token": "x", "url": "https://r.example/?k=crt_secret" } }),
        json!({ "tokens": { "access_token": "x", "crt_secret": true } }),
    ] {
        assert_eq!(codex_h.check(embedded.to_string().as_bytes()), Err(Refusal::CodeRouter));
    }
    // A refused file is never sent and never replaced.
    let mut state = SyncState::default();
    let local = Local::from_bytes(claude_h, Some(placeholder.to_string().into_bytes()));
    assert_eq!(local, Local::Refused(Refusal::CodeRouter));
    assert_eq!(state.observe("claude", &local).0, None);
    assert_eq!(state.saved(&local, &active("claude", 3, &claude("mine"))).0, None);
}

/// The shared-machine CodeRouter homes (`~/.config/cmux/claude-team`,
/// `codex-team`) are not in the table: only the CLIs' own default homes are.
#[test]
fn the_coderouter_team_homes_are_never_read() {
    for h in HARNESSES {
        assert!(!h.file.contains("cmux"), "{}", h.file);
    }
}

#[test]
fn only_a_personal_machine_syncs() {
    assert!(personal_machine(Some("owner\n"), false));
    assert!(!personal_machine(Some("owner"), true));
    assert!(!personal_machine(Some("team"), false));
    assert!(!personal_machine(None, false));
    assert!(!personal_machine(Some(""), false));
}

#[test]
fn setup_personal_reads_the_kind_and_team_files() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    assert!(!setup.personal(), "no kind recorded is shared");
    fs::write(&setup.vm_kind_file, "owner\n").unwrap();
    assert!(setup.personal());
    fs::write(&setup.team_files[0], "{}").unwrap();
    assert!(!setup.personal());
    fs::remove_file(&setup.team_files[0]).unwrap();
    fs::write(&setup.vm_kind_file, "team\n").unwrap();
    assert!(!setup.personal());
}

#[test]
fn only_development_has_a_platform_origin() {
    assert_eq!(
        Env::Dev.harness_login_origin(),
        Some("https://cmux-platform-development.debussy.workers.dev")
    );
    assert_eq!(Env::Stg.harness_login_origin(), None);
    assert_eq!(Env::Prod.harness_login_origin(), None);
}

// ---- wire shapes ----

#[test]
fn a_list_keeps_only_whole_entries_of_known_harnesses() {
    let mine = claude("sk-ant-oat01-mine");
    let body = json!({ "credentials": [
        { "harness": "claude", "state": "active", "revision": 4, "fingerprint": fingerprint(&mine), "contentBase64": encode_base64(&mine) },
        { "harness": "codex", "state": "revoked", "revision": 2, "fingerprint": "0".repeat(64) },
        { "harness": "gemini", "state": "active", "revision": 1, "fingerprint": fingerprint(b"x"), "contentBase64": encode_base64(b"x") },
        { "harness": "claude", "state": "active", "revision": 5, "fingerprint": "0".repeat(64), "contentBase64": encode_base64(&mine) },
        { "harness": "claude", "state": "active", "revision": 6, "fingerprint": fingerprint(&mine) },
        { "harness": "claude", "state": "odd", "revision": 7 },
        { "harness": "claude", "state": "active" },
    ]});
    let Listed::Saved(saved) = parse_list(200, &body) else { panic!() };
    assert_eq!(saved, vec![active("claude", 4, &mine), revoked("codex", 2)]);
    assert_eq!(parse_list(404, &json!({})), Listed::Off);
    assert!(matches!(parse_list(503, &json!({})), Listed::Retry(_)));
    assert!(matches!(parse_list(429, &json!({})), Listed::Retry(_)));
    assert!(matches!(parse_list(400, &json!({})), Listed::Refused(_)));
}

#[test]
fn a_put_answer_reads_saved_revoked_off_and_retry() {
    let fp = fingerprint(b"x");
    assert_eq!(
        parse_put(
            200,
            &json!({ "harness": "claude", "state": "active", "revision": 3, "fingerprint": fp })
        ),
        Put::Saved { revision: 3, fingerprint: fp.clone() }
    );
    assert_eq!(parse_put(409, &json!({ "error": { "code": REVOKED_CODE } })), Put::Revoked);
    assert_eq!(parse_put(409, &json!({ "code": REVOKED_CODE })), Put::Revoked);
    assert!(matches!(
        parse_put(409, &json!({ "code": "harness_credential.conflict" })),
        Put::Refused(_)
    ));
    assert_eq!(parse_put(404, &json!({})), Put::Off);
    assert!(matches!(parse_put(503, &json!({})), Put::Retry(_)));
    assert!(matches!(parse_put(200, &json!({ "revision": 3 })), Put::Refused(_)));
    let report = Report {
        harness: "codex".to_owned(),
        fingerprint: fp.clone(),
        base_revision: 7,
        content: b"x".to_vec(),
    };
    assert_eq!(
        report.body(),
        json!({ "contentBase64": "eA==", "fingerprint": fp, "baseRevision": 7 })
    );
    assert_eq!(put_path("codex"), "/v1/harness-credentials/machine/codex");
}

#[test]
fn debug_output_never_shows_a_login() {
    let saved = active("claude", 1, &claude("sk-ant-oat01-secret"));
    let report = Report {
        harness: "claude".to_owned(),
        fingerprint: fingerprint(b"x"),
        base_revision: 1,
        content: claude("sk-ant-oat01-secret"),
    };
    for text in [format!("{saved:?}"), format!("{report:?}")] {
        assert!(!text.contains("secret"), "{text}");
        assert!(!text.contains(&fingerprint(b"x")), "{text}");
    }
}

#[test]
fn the_state_holds_no_login() {
    let mine = claude("sk-ant-oat01-secret");
    let mut state = SyncState::default();
    let saved = active("claude", 2, &mine);
    state.saved(&Local::Absent, &saved);
    state.written(&saved);
    let text = state.to_text();
    assert!(!text.contains("secret"));
    assert_eq!(SyncState::parse(Some(&text)), state);
    assert_eq!(SyncState::parse(Some("garbage")), SyncState::default());
}

// ---- decisions ----

#[test]
fn boot_writes_a_saved_login_when_the_machine_has_none() {
    let mine = claude("mine");
    let mut state = SyncState::default();
    let saved = active("claude", 3, &mine);
    let (write, _) = state.saved(&Local::Absent, &saved);
    assert_eq!(write, Some(mine.clone()));
    state.written(&saved);
    // No echo: the written login is what was last synced.
    assert_eq!(state.observe("claude", &login(&mine)).0, None);
    // The same list again writes nothing.
    assert_eq!(state.saved(&login(&mine), &saved).0, None);
}

#[test]
fn boot_never_replaces_a_login_the_machine_already_has() {
    let theirs = claude("from-another-machine");
    let here = claude("signed-in-here");
    let mut state = SyncState::default();
    let (write, _) = state.saved(&login(&here), &active("claude", 3, &theirs));
    assert_eq!(write, None);
    // It is sent instead, on base 0 (this machine never synced): the server
    // decides.
    let (report, _) = state.observe("claude", &login(&here));
    assert_eq!(report.unwrap().base_revision, 0);
}

#[test]
fn a_new_login_is_sent_once() {
    let mine = codex("t1");
    let mut state = SyncState::default();
    let (report, _) = state.observe("codex", &login(&mine));
    let report = report.unwrap();
    assert_eq!((report.base_revision, report.fingerprint.clone()), (0, fingerprint(&mine)));
    state.answered(&report, &Put::Saved { revision: 1, fingerprint: fingerprint(&mine) });
    assert_eq!(state.observe("codex", &login(&mine)).0, None);
    // A failed send is tried again.
    let next = codex("t2");
    let report = state.observe("codex", &login(&next)).0.unwrap();
    assert_eq!(report.base_revision, 1);
    state.answered(&report, &Put::Retry("HTTP 503".to_owned()));
    assert!(state.observe("codex", &login(&next)).0.is_some());
    // A final refusal is not.
    state.answered(&report, &Put::Refused("bad".to_owned()));
    assert_eq!(state.observe("codex", &login(&next)).0, None);
}

#[test]
fn a_rotation_is_written_while_the_local_file_is_unchanged() {
    let one = claude("one");
    let two = claude("two");
    let mut state = SyncState::default();
    let first = active("claude", 1, &one);
    state.saved(&Local::Absent, &first);
    state.written(&first);
    let rotated = active("claude", 2, &two);
    assert_eq!(state.saved(&login(&one), &rotated).0, Some(two.clone()));
    state.written(&rotated);
    assert_eq!(state.of("claude").revision, 2);
    assert_eq!(state.observe("claude", &login(&two)).0, None);
    // An older or equal revision is never written.
    assert_eq!(state.saved(&login(&two), &active("claude", 2, &one)).0, None);
    assert_eq!(state.saved(&login(&two), &active("claude", 1, &one)).0, None);
}

#[test]
fn a_local_change_wins_over_a_rotation_and_is_sent() {
    let one = claude("one");
    let local_edit = claude("refreshed-here");
    let mut state = SyncState::default();
    let first = active("claude", 1, &one);
    state.saved(&Local::Absent, &first);
    state.written(&first);
    assert_eq!(state.saved(&login(&local_edit), &active("claude", 2, &claude("two"))).0, None);
    let report = state.observe("claude", &login(&local_edit)).0.unwrap();
    assert_eq!(report.base_revision, 1);
}

#[test]
fn a_login_that_already_matches_the_saved_one_is_adopted() {
    let mine = claude("mine");
    let mut state = SyncState::default();
    let (write, changed) = state.saved(&login(&mine), &active("claude", 4, &mine));
    assert_eq!((write, changed), (None, true));
    assert_eq!(state.of("claude").revision, 4);
    assert_eq!(state.observe("claude", &login(&mine)).0, None);
}

#[test]
fn a_deleted_saved_login_keeps_the_local_file_and_the_base() {
    let mine = claude("mine");
    let mut state = SyncState::default();
    let first = active("claude", 3, &mine);
    state.saved(&Local::Absent, &first);
    state.written(&first);
    let (write, changed) = state.saved(&login(&mine), &revoked("claude", 4));
    assert_eq!((write, changed), (None, true));
    let s = state.of("claude");
    assert_eq!((s.revision, s.revoked_at, s.newest_seen), (3, Some(4), 4));
    // The unchanged local login is not sent back.
    assert_eq!(state.observe("claude", &login(&mine)).0, None);
    // A change here is sent on the old base; the server answers 409.
    let edit = claude("refreshed");
    let report = state.observe("claude", &login(&edit)).0.unwrap();
    assert_eq!(report.base_revision, 3);
    state.answered(&report, &Put::Revoked);
    assert!(state.of("claude").stopped);
    // Stopped: nothing is sent, not even another change.
    assert_eq!(state.observe("claude", &login(&claude("again"))).0, None);
    // The person signs out here: the base moves past the deletion.
    let (_, changed) = state.observe("claude", &Local::Absent);
    assert!(changed);
    let s = state.of("claude");
    assert_eq!((s.revision, s.fingerprint.clone(), s.stopped), (4, None, false));
    // A fresh sign-in is sent on the newest base, which the server accepts.
    let fresh = claude("fresh");
    let report = state.observe("claude", &login(&fresh)).0.unwrap();
    assert_eq!(report.base_revision, 4);
}

#[test]
fn a_deletion_seen_with_no_local_login_makes_the_next_sign_in_fresh() {
    let mut state = SyncState::default();
    state.saved(&Local::Absent, &revoked("codex", 5));
    let report = state.observe("codex", &login(&codex("new"))).0.unwrap();
    assert_eq!(report.base_revision, 5);
}

#[test]
fn a_saved_login_after_a_deletion_is_written_once_signed_out() {
    let mine = claude("mine");
    let mut state = SyncState::default();
    let first = active("claude", 1, &mine);
    state.saved(&Local::Absent, &first);
    state.written(&first);
    state.saved(&login(&mine), &revoked("claude", 2));
    state.observe("claude", &Local::Absent);
    // Another machine signs in fresh: revision 3 is written here.
    let other = claude("other");
    let saved = active("claude", 3, &other);
    assert_eq!(state.saved(&Local::Absent, &saved).0, Some(other));
}

// ---- the syncer over files and a fake server ----

/// The platform's rules in memory, per harness: revision, state, content.
#[derive(Default)]
struct FakePlatform {
    saved: BTreeMap<String, (u64, Option<Vec<u8>>)>,
    puts: Vec<(String, u64)>,
    off: bool,
    lists: usize,
}

impl FakePlatform {
    fn delete(&mut self, id: &str) {
        let entry = self.saved.entry(id.to_owned()).or_default();
        entry.0 += 1;
        entry.1 = None;
    }
}

impl Api for FakePlatform {
    fn list(&mut self) -> Listed {
        self.lists += 1;
        if self.off {
            return Listed::Off;
        }
        let items: Vec<Value> = self
            .saved
            .iter()
            .map(|(id, (rev, content))| match content {
                Some(c) => json!({ "harness": id, "state": "active", "revision": rev, "fingerprint": fingerprint(c), "contentBase64": encode_base64(c) }),
                None => json!({ "harness": id, "state": "revoked", "revision": rev, "fingerprint": "0".repeat(64) }),
            })
            .collect();
        parse_list(200, &json!({ "credentials": items }))
    }

    fn put(&mut self, report: &Report) -> Put {
        self.puts.push((report.harness.clone(), report.base_revision));
        if self.off {
            return Put::Off;
        }
        let entry = self.saved.entry(report.harness.clone()).or_default();
        if entry.1.is_none() && entry.0 > report.base_revision {
            return parse_put(409, &json!({ "error": { "code": REVOKED_CODE } }));
        }
        entry.0 += 1;
        entry.1 = Some(report.content.clone());
        parse_put(
            200,
            &json!({ "harness": report.harness, "state": "active", "revision": entry.0, "fingerprint": report.fingerprint }),
        )
    }
}

fn setup_in(root: &Path) -> Setup {
    Setup {
        home: root.join("home"),
        state_file: root.join("var/harness-login-sync.json"),
        vm_kind_file: root.join("vm-kind"),
        team_files: vec![root.join("team-enroll.json")],
        fs_identity: None,
    }
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn a_new_machine_starts_signed_in_and_does_not_echo() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    fs::create_dir_all(&setup.home).unwrap();
    fs::create_dir_all(setup.state_file.parent().unwrap()).unwrap();
    let mut server = FakePlatform::default();
    let mine = claude("mine");
    server.saved.insert("claude".to_owned(), (2, Some(mine.clone())));
    let mut sync = Syncer::new(setup.clone(), no_log);
    assert_eq!(sync.pull(&mut server), Pass::Done);
    let file = setup.home.join(".claude/.credentials.json");
    assert_eq!(fs::read(&file).unwrap(), mine);
    assert_eq!(mode(&file), 0o600);
    assert_eq!(mode(file.parent().unwrap()), 0o700);
    assert_eq!(mode(&setup.state_file), 0o600);
    assert!(!fs::read_to_string(&setup.state_file).unwrap().contains("mine"));
    // No temp file is left beside it.
    let names: Vec<_> =
        fs::read_dir(file.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, [".credentials.json"]);
    assert_eq!(sync.scan(&mut server), Pass::Done);
    assert!(server.puts.is_empty(), "the boot write is not sent back");
    // A restart keeps the state.
    let mut again = Syncer::new(setup, no_log);
    assert_eq!(again.scan(&mut server), Pass::Done);
    assert!(server.puts.is_empty());
}

#[test]
fn a_sign_in_here_is_sent_and_reaches_the_next_machine() {
    let dir = tempfile::tempdir().unwrap();
    let first = setup_in(&dir.path().join("a"));
    let second = setup_in(&dir.path().join("b"));
    let mut server = FakePlatform::default();
    let mut a = Syncer::new(first.clone(), no_log);
    assert_eq!(a.pull(&mut server), Pass::Done);
    let mine = codex("signed-in-on-a");
    write_atomic(&first.home.join(".codex/auth.json"), &mine, 0o600).unwrap();
    // A CodeRouter file beside it is not sent.
    write_atomic(
        &first.home.join(".claude/.credentials.json"),
        br#"{"claudeAiOauth": {"accessToken": "cmux-vm-edge-placeholder"}}"#,
        0o600,
    )
    .unwrap();
    assert_eq!(a.scan(&mut server), Pass::Done);
    assert_eq!(server.puts, [("codex".to_owned(), 0)]);
    assert_eq!(a.scan(&mut server), Pass::Done);
    assert_eq!(server.puts.len(), 1, "sent once");
    let mut b = Syncer::new(second.clone(), no_log);
    assert_eq!(b.pull(&mut server), Pass::Done);
    assert_eq!(fs::read(second.home.join(".codex/auth.json")).unwrap(), mine);
    assert_eq!(b.scan(&mut server), Pass::Done);
    assert_eq!(server.puts.len(), 1, "machine b does not echo it");
    // A rotation on b reaches a, whose file is unchanged since its sync.
    let rotated = codex("rotated-on-b");
    write_atomic(&second.home.join(".codex/auth.json"), &rotated, 0o600).unwrap();
    assert_eq!(b.scan(&mut server), Pass::Done);
    assert_eq!(server.puts.last(), Some(&("codex".to_owned(), 1)));
    assert_eq!(a.pull(&mut server), Pass::Done);
    assert_eq!(fs::read(first.home.join(".codex/auth.json")).unwrap(), rotated);
    assert_eq!(a.scan(&mut server), Pass::Done);
    assert_eq!(server.puts.len(), 2);
}

#[test]
fn deleted_then_409_then_sign_out_then_fresh_sign_in() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    let mut server = FakePlatform::default();
    let mine = claude("mine");
    server.saved.insert("claude".to_owned(), (1, Some(mine.clone())));
    let mut sync = Syncer::new(setup.clone(), no_log);
    sync.pull(&mut server);
    let file = setup.home.join(".claude/.credentials.json");
    server.delete("claude");
    assert_eq!(sync.pull(&mut server), Pass::Done);
    assert_eq!(fs::read(&file).unwrap(), mine, "the local login stays");
    assert_eq!(sync.state().of("claude").revision, 1, "the base does not move");
    // A refresh here is refused: the person deleted the saved login.
    write_atomic(&file, &claude("refreshed"), 0o600).unwrap();
    assert_eq!(sync.scan(&mut server), Pass::Done);
    assert_eq!(server.puts, [("claude".to_owned(), 1)]);
    assert!(sync.state().of("claude").stopped);
    assert!(sync.pull_soon);
    write_atomic(&file, &claude("refreshed-again"), 0o600).unwrap();
    sync.scan(&mut server);
    assert_eq!(server.puts.len(), 1, "stopped");
    // Signed out, then in again: sent on the newest base and accepted.
    fs::remove_file(&file).unwrap();
    sync.scan(&mut server);
    write_atomic(&file, &claude("fresh"), 0o600).unwrap();
    sync.scan(&mut server);
    assert_eq!(server.puts.last(), Some(&("claude".to_owned(), 2)));
    assert_eq!(server.saved["claude"], (3, Some(claude("fresh"))));
}

#[test]
fn a_deployment_without_saved_logins_is_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    let mut server = FakePlatform { off: true, ..FakePlatform::default() };
    let mut sync = Syncer::new(setup.clone(), no_log);
    assert_eq!(sync.pull(&mut server), Pass::Off);
    write_atomic(&setup.home.join(".claude/.credentials.json"), &claude("x"), 0o600).unwrap();
    assert_eq!(sync.scan(&mut server), Pass::Off);
    // Asked again later, the login is still sent.
    server.off = false;
    assert_eq!(sync.scan(&mut server), Pass::Done);
    assert_eq!(server.puts.len(), 2);
    assert!(server.saved.contains_key("claude"));
}

#[test]
fn invalid_files_are_ignored_and_never_overwritten() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    let mut server = FakePlatform::default();
    let api_key = br#"{"OPENAI_API_KEY": "sk-proj-mine"}"#;
    let codex_file = setup.home.join(".codex/auth.json");
    write_atomic(&codex_file, api_key, 0o600).unwrap();
    write_atomic(&setup.home.join(".claude/.credentials.json"), b"{not json", 0o600).unwrap();
    let mut sync = Syncer::new(setup, no_log);
    sync.scan(&mut server);
    assert!(server.puts.is_empty());
    server.saved.insert("codex".to_owned(), (1, Some(codex("saved"))));
    sync.pull(&mut server);
    assert_eq!(fs::read(&codex_file).unwrap(), api_key);
}

#[test]
fn a_link_is_never_followed() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    let target = dir.path().join("elsewhere.json");
    fs::write(&target, claude("not-theirs")).unwrap();
    let file = setup.home.join(".claude/.credentials.json");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&target, &file).unwrap();
    let (local, _) = read_login(harness("claude").unwrap(), &setup.home);
    assert_eq!(local, Local::Unreadable);
    let mut server = FakePlatform::default();
    let mut sync = Syncer::new(setup, no_log);
    sync.scan(&mut server);
    assert!(server.puts.is_empty());
}

/// A `.claude` folder that is a link (to a team home, say) is never read
/// through, and a saved login is never written through it.
#[test]
fn a_linked_folder_is_never_followed() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    fs::create_dir_all(&setup.home).unwrap();
    fs::create_dir_all(setup.state_file.parent().unwrap()).unwrap();
    let team = dir.path().join("claude-team");
    fs::create_dir_all(&team).unwrap();
    std::os::unix::fs::symlink(&team, setup.home.join(".claude")).unwrap();
    // A team login behind the link is neither read nor sent.
    fs::write(team.join(".credentials.json"), claude("team")).unwrap();
    let (local, _) = read_login(harness("claude").unwrap(), &setup.home);
    assert_eq!(local, Local::Unreadable);
    let mut server = FakePlatform::default();
    let mut sync = Syncer::new(setup, no_log);
    sync.scan(&mut server);
    assert!(server.puts.is_empty());
    // A saved login is not written into the linked folder.
    fs::remove_file(team.join(".credentials.json")).unwrap();
    server.saved.insert("claude".to_owned(), (1, Some(claude("mine"))));
    sync.pull(&mut server);
    assert!(fs::read_dir(&team).unwrap().next().is_none());
}

/// A saved login the platform answers is held to the local checks: a
/// CodeRouter or API-key-only file is never written to the machine.
#[test]
fn a_saved_login_that_fails_the_checks_is_never_written() {
    let dir = tempfile::tempdir().unwrap();
    let setup = setup_in(dir.path());
    fs::create_dir_all(&setup.home).unwrap();
    fs::create_dir_all(setup.state_file.parent().unwrap()).unwrap();
    let mut server = FakePlatform::default();
    server.saved.insert("claude".to_owned(), (1, Some(claude(CODEROUTER_PLACEHOLDER))));
    server.saved.insert(
        "codex".to_owned(),
        (1, Some(json!({ "OPENAI_API_KEY": "sk-x" }).to_string().into_bytes())),
    );
    let mut sync = Syncer::new(setup.clone(), no_log);
    assert_eq!(sync.pull(&mut server), Pass::Done);
    assert!(!setup.home.join(".claude/.credentials.json").exists());
    assert!(!setup.home.join(".codex/auth.json").exists());
}

/// A sign-in or token refresh between the pull's read and its write wins:
/// the saved login is not written over it.
#[test]
fn a_login_changed_after_the_read_is_not_overwritten() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let claude_h = harness("claude").unwrap();
    let file = home.join(".claude/.credentials.json");
    write_atomic(&file, &claude("old"), 0o600).unwrap();
    let (_, read) = read_login(claude_h, &home);
    assert!(read.is_some());
    write_atomic(&file, &claude("refreshed"), 0o600).unwrap();
    let err = write_login(&home, claude_h, &claude("saved"), read).unwrap_err();
    assert_eq!(err.to_string(), CHANGED_SINCE_READ);
    assert_eq!(fs::read(&file).unwrap(), claude("refreshed"));
    // Read as absent, then a sign-in lands: not overwritten either.
    let fresh = dir.path().join("fresh");
    let (local, read) = read_login(claude_h, &fresh);
    assert_eq!((local, read), (Local::Absent, None));
    write_atomic(&fresh.join(".claude/.credentials.json"), &claude("signed-in"), 0o600).unwrap();
    assert!(write_login(&fresh, claude_h, &claude("saved"), read).is_err());
    assert_eq!(fs::read(fresh.join(".claude/.credentials.json")).unwrap(), claude("signed-in"));
    // Unchanged since the read: written, with no temp file left.
    let (_, read) = read_login(claude_h, &home);
    write_login(&home, claude_h, &claude("saved"), read).unwrap();
    assert_eq!(fs::read(&file).unwrap(), claude("saved"));
    let names: Vec<_> =
        fs::read_dir(file.parent().unwrap()).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, [".credentials.json"]);
}

#[test]
fn the_writer_replaces_atomically_with_its_mode() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("new/dir/file.json");
    write_atomic(&path, b"one", 0o600).unwrap();
    assert_eq!(mode(dir.path().join("new/dir").as_path()), 0o700);
    assert_eq!(mode(&path), 0o600);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    write_atomic(&path, b"two", 0o600).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"two");
    assert_eq!(mode(&path), 0o600);
    // An existing folder keeps its mode.
    let open = dir.path().join("open");
    fs::create_dir(&open).unwrap();
    fs::set_permissions(&open, fs::Permissions::from_mode(0o755)).unwrap();
    write_atomic(&open.join("f"), b"x", 0o600).unwrap();
    assert_eq!(mode(&open), 0o755);
}
