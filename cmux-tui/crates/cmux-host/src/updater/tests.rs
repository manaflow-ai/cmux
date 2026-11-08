use std::fs;
use std::path::Path;

use base64::Engine as _;
use serde_json::json;

use super::channel::{self, CHANNEL, PURPOSE, Payload};
use super::store;
use super::*;
use crate::config::Paths;

const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
const OLD_TUI: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const OLD_HOOK: &str = "2222222222222222222222222222222222222222222222222222222222222222";
const CLAUDE: &str = "3333333333333333333333333333333333333333333333333333333333333333";
const TARGET: &str = "x86_64-unknown-linux-musl";

fn key() -> ring::signature::Ed25519KeyPair {
    ring::signature::Ed25519KeyPair::from_seed_unchecked(&[7u8; 32]).unwrap()
}

fn keys() -> Vec<(String, [u8; 32])> {
    use ring::signature::KeyPair as _;
    let raw: [u8; 32] = key().public_key().as_ref().try_into().unwrap();
    vec![("test".to_owned(), raw)]
}

fn binary(name: &str, sha: &str) -> serde_json::Value {
    json!({"url": format!("https://files.cmux.com/cmux-tui/{COMMIT}/{name}-{TARGET}"), "sha256": sha, "size": 3})
}

fn payload_json(tui: &str, hook: &str) -> serde_json::Value {
    json!({
        "schema": 1, "purpose": PURPOSE, "channel": CHANNEL, "commit": COMMIT,
        "committed_at": 1_000, "published_at": 1_100, "expires_at": 10_000,
        "key": "k",
        "targets": {TARGET: {"cmux-tui": binary("cmux-tui", tui), "cmux-tui-hook": binary("cmux-tui-hook", hook)}},
    })
}

fn envelope(payload: &serde_json::Value, key_id: &str) -> Vec<u8> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = serde_json::to_vec(payload).unwrap();
    let sig = key().sign(&bytes);
    serde_json::to_vec(&json!({
        "schema": 1,
        "payload": b64.encode(&bytes),
        "signatures": [{"key_id": key_id, "sig": b64.encode(sig.as_ref())}],
    }))
    .unwrap()
}

#[test]
fn a_signed_payload_verifies() {
    let payload =
        channel::verify(&envelope(&payload_json(OLD_TUI, OLD_HOOK), "test"), &keys(), 5_000)
            .unwrap();
    assert_eq!(payload.commit, COMMIT);
    let (tui, hook) = payload.binaries_for(TARGET).unwrap();
    assert_eq!((tui.sha256.as_str(), hook.sha256.as_str()), (OLD_TUI, OLD_HOOK));
    assert!(payload.binaries_for("aarch64-unknown-linux-musl").is_err());
}

#[test]
fn refuses_tampering_other_keys_purposes_and_expiry() {
    let good = payload_json(OLD_TUI, OLD_HOOK);
    // Another key id: nothing covers it.
    assert!(channel::verify(&envelope(&good, "other"), &keys(), 5_000).is_err());
    // A changed payload under the old signature.
    let mut env: serde_json::Value = serde_json::from_slice(&envelope(&good, "test")).unwrap();
    let mut changed = good.clone();
    changed["commit"] = json!("f".repeat(40));
    env["payload"] = json!(
        base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&changed).unwrap())
    );
    assert!(channel::verify(&serde_json::to_vec(&env).unwrap(), &keys(), 5_000).is_err());
    // A web update pointer's payload (signed by the same key) is not a machine update.
    let mut web = good.clone();
    web["channel"] = json!("every-merge");
    assert!(channel::verify(&envelope(&web, "test"), &keys(), 5_000).is_err());
    let mut purpose = good.clone();
    purpose["purpose"] = json!("web");
    assert!(channel::verify(&envelope(&purpose, "test"), &keys(), 5_000).is_err());
    // Expired.
    assert!(channel::verify(&envelope(&good, "test"), &keys(), 10_000).is_err());
}

#[test]
fn a_binary_must_come_from_its_commit_publication() {
    let mut p = payload_json(OLD_TUI, OLD_HOOK);
    p["targets"][TARGET]["cmux-tui"]["url"] = json!("https://example.com/cmux-tui");
    let payload: Payload = serde_json::from_value(p).unwrap();
    assert!(payload.binaries_for(TARGET).is_err());
}

#[test]
fn keys_match_the_web_update_keys() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../../Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json",
    );
    let Ok(text) = fs::read_to_string(&path) else { return };
    let file: serde_json::Value = serde_json::from_str(&text).unwrap();
    let web: Vec<(String, String)> = file["keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|k| (k["id"].as_str().unwrap().to_owned(), k["ed25519"].as_str().unwrap().to_owned()))
        .collect();
    for (id, b64) in channel::KEYS {
        assert!(
            web.contains(&((*id).to_owned(), (*b64).to_owned())),
            "{id} is not a web update key"
        );
    }
    assert_eq!(channel::trusted_keys().len(), channel::KEYS.len());
}

/// A baked image: profile 1 linking cmux-tui, its acpmux and cmux names,
/// the hook and one other program; the work user's link into `current`.
fn image(dir: &Path) -> Paths {
    let paths = Paths::new(dir);
    let bin = store::profile_dir(&paths, 1).join("bin");
    fs::create_dir_all(&bin).unwrap();
    for (name, sha, file) in [
        ("cmux-tui", OLD_TUI, "cmux-tui"),
        ("cmux", OLD_TUI, "cmux-tui"),
        ("acpmux", OLD_TUI, "cmux-tui"),
        ("cmux-tui-hook", OLD_HOOK, "cmux-tui-hook"),
        ("claude", CLAUDE, "claude"),
    ] {
        std::os::unix::fs::symlink(format!("/opt/cmux/store/{sha}/{file}"), bin.join(name))
            .unwrap();
    }
    std::os::unix::fs::symlink("profiles/1", paths.at(store::CURRENT_LINK)).unwrap();
    let link = paths.at(WORK_CMUX_TUI_LINK);
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(CURRENT_CMUX_TUI, &link).unwrap();
    paths
}

fn sha(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn decides_by_the_current_profile_and_the_record() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    let state = State::default();
    let same: Payload = serde_json::from_value(payload_json(OLD_TUI, OLD_HOOK)).unwrap();
    assert_eq!(decide(&paths, &state, &same, TARGET).unwrap(), Decision::Current);
    let new_tui = "a".repeat(64);
    let newer: Payload = serde_json::from_value(payload_json(&new_tui, OLD_HOOK)).unwrap();
    let Decision::Update(plan) = decide(&paths, &state, &newer, TARGET).unwrap() else {
        panic!("expected an update")
    };
    assert_eq!((plan.from, plan.to), (1, 2));
    assert_eq!(plan.replacements(), vec![(OLD_TUI.to_owned(), new_tui.clone())]);
    let applied = State { applied_committed_at: 2_000, ..State::default() };
    assert_eq!(decide(&paths, &applied, &newer, TARGET).unwrap(), Decision::Older);
    let rolled = State { rolled_back: vec![new_tui], ..State::default() };
    assert_eq!(decide(&paths, &rolled, &newer, TARGET).unwrap(), Decision::RolledBack);
}

#[test]
fn an_update_adds_a_profile_flips_and_rolls_back() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    assert_eq!(off_reason(&paths), None);
    let bytes = b"new";
    let new_tui = sha(bytes);
    let download = dir.path().join("dl");
    fs::write(&download, bytes).unwrap();
    // A file whose bytes are not the sha256 is refused.
    assert!(store::add_entry(&paths, &"b".repeat(64), "cmux-tui", &download).is_err());
    store::add_entry(&paths, &new_tui, "cmux-tui", &download).unwrap();
    assert!(store::has_entry(&paths, &new_tui, "cmux-tui"));
    store::build_profile(&paths, 1, 2, &[(OLD_TUI.to_owned(), new_tui.clone())]).unwrap();
    store::flip(&paths, 2).unwrap();
    assert_eq!(store::current_generation(&paths).unwrap(), 2);
    for name in ["cmux-tui", "cmux", "acpmux"] {
        assert_eq!(store::linked_package(&paths, 2, name).unwrap(), new_tui);
    }
    assert_eq!(store::linked_package(&paths, 2, "cmux-tui-hook").unwrap(), OLD_HOOK);
    assert_eq!(store::linked_package(&paths, 2, "claude").unwrap(), CLAUDE);
    // The baked profile is untouched, so a rollback is one flip.
    assert_eq!(store::linked_package(&paths, 1, "cmux").unwrap(), OLD_TUI);
    store::flip(&paths, 1).unwrap();
    assert_eq!(store::current_generation(&paths).unwrap(), 1);
}

#[test]
fn gc_keeps_the_baked_current_and_newest_profiles() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    let mut ours = Vec::new();
    for generation in 2..=6u64 {
        let bytes = format!("build {generation}");
        let entry = sha(bytes.as_bytes());
        let download = dir.path().join("dl");
        fs::write(&download, &bytes).unwrap();
        store::add_entry(&paths, &entry, "cmux-tui", &download).unwrap();
        let from = store::current_generation(&paths).unwrap();
        let old = store::linked_package(&paths, from, "cmux-tui").unwrap();
        store::build_profile(&paths, from, generation, &[(old, entry.clone())]).unwrap();
        store::flip(&paths, generation).unwrap();
        ours.push(entry);
    }
    let (profiles, packages) = store::gc(&paths, &[5], &ours);
    assert_eq!(profiles, vec![3, 2]);
    assert_eq!(store::generations(&paths), vec![1, 4, 5, 6]);
    assert_eq!(packages, vec![ours[0].clone(), ours[1].clone()]);
    assert!(!paths.at(store::STORE_DIR).join(&ours[0]).exists());
    assert!(paths.at(store::STORE_DIR).join(&ours[2]).exists());
}

#[test]
fn off_when_marked_or_when_the_app_replaced_the_link() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    fs::create_dir_all(paths.at("/etc/cmux")).unwrap();
    fs::write(paths.at(OFF_FILE), "").unwrap();
    assert!(off_reason(&paths).is_some());
    fs::remove_file(paths.at(OFF_FILE)).unwrap();
    let link = paths.at(WORK_CMUX_TUI_LINK);
    fs::remove_file(&link).unwrap();
    fs::write(&link, b"binary").unwrap();
    assert!(off_reason(&paths).is_some());
}

#[test]
fn a_profile_holding_a_regular_file_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    fs::write(store::profile_dir(&paths, 1).join("bin/stray"), b"x").unwrap();
    assert!(store::build_profile(&paths, 1, 2, &[]).is_err());
}

#[test]
fn busy_sessions_follow_acpmux_rules() {
    let ls = json!({"sessions": [
        {"name": "idle", "status": "idle", "turn": null, "starting": false},
        {"name": "turn", "status": "idle", "turn": {"id": 1}, "starting": false},
        {"name": "running", "status": "running", "starting": false},
        {"name": "asks", "status": "idle", "pendingPermissions": 1, "starting": false},
        {"name": "starting", "status": "idle", "turn": null, "starting": true},
        {"name": "started", "status": "ready", "turn": null, "starting": false},
        {"name": "peer", "status": "running", "peer": "mac"},
    ]});
    assert_eq!(
        busy_sessions_in(&ls.to_string()).unwrap(),
        vec!["turn".to_owned(), "running".to_owned(), "asks".to_owned(), "starting".to_owned()]
    );
    // An acpmux too old to send `starting` (the one a stale image runs): a session it made or
    // changed in the last two minutes may be starting and holds the update; an older one does not.
    let now = 10_000_000;
    let old = json!({"sessions": [
        {"name": "just-made", "status": "idle", "turn": null, "createdAt": now - 5_000, "updatedAt": now - 5_000},
        {"name": "long-idle", "status": "ready", "turn": null, "createdAt": 1, "updatedAt": now - UNREPORTED_START_MS},
    ]});
    assert_eq!(busy_sessions_at(&old.to_string(), now).unwrap(), vec!["just-made".to_owned()]);
    assert_eq!(busy_sessions_in("{\"sessions\": []}").unwrap(), Vec::<String>::new());
    assert!(busy_sessions_in("not json").is_none());
}

#[test]
fn daemon_status_replies() {
    assert_eq!(daemon_running(r#"{"pid": 41, "build": "91d3ea019"}"#), Some(true));
    assert_eq!(daemon_running(r#"{"running": false, "error": "daemon not running"}"#), Some(false));
    assert_eq!(daemon_running(r#"{"running": false}"#), Some(false));
    assert_eq!(daemon_running(r#"{"pid": null}"#), None);
    assert_eq!(daemon_running("{}"), None);
    assert_eq!(daemon_running(""), None);
    assert_eq!(daemon_running("not json"), None);
}

#[test]
fn state_and_pending_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let mut state = State::default();
    let pending = Pending {
        from: 1,
        to: 2,
        commit: COMMIT.to_owned(),
        committed_at: 5,
        cmux_tui: "a".repeat(64),
        cmux_tui_hook: OLD_HOOK.to_owned(),
        old_cmux_tui: OLD_TUI.to_owned(),
        started_at: 9,
    };
    record_rollback(&mut state, &pending);
    record_rollback(&mut state, &pending);
    assert_eq!(state.rolled_back, vec!["a".repeat(64)]);
    save_state(&paths, &state).unwrap();
    assert_eq!(load_state(&paths), state);
    save_pending(&paths, &pending).unwrap();
    assert_eq!(load_pending(&paths), Some(pending));
    clear_pending(&paths);
    assert_eq!(load_pending(&paths), None);
}

// `role` is Linux only (updater/mod.rs), the tests module every unix: on macOS this did not compile.
#[cfg(target_os = "linux")]
#[test]
fn a_log_line_shortens_a_hash_without_slicing_past_its_end() {
    assert_eq!(role::short_hex(OLD_TUI), "111111111111");
    assert_eq!(role::short_hex(COMMIT), "0123456789ab");
    assert_eq!(role::short_hex("abc"), "abc");
    assert_eq!(role::short_hex(""), "");
    // 11 ASCII bytes then a 2-byte character: byte 12 is inside it, so the whole text is logged.
    assert_eq!(role::short_hex("0123456789aé"), "0123456789aé");
}

#[test]
fn a_file_hash_covers_every_byte_past_one_read_buffer() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("big");
    let bytes: Vec<u8> = (0..(1usize << 16) * 3 + 17).map(|i| (i % 251) as u8).collect();
    fs::write(&path, &bytes).unwrap();
    assert_eq!(store::sha256_file(&path).unwrap(), sha(&bytes));
}

/// A claimed spare resumed at 21:28:35 and its updater restarted the services
/// at 21:28:41, killing the Mac's first dial (nightly 8d8fc7a, 2026-11-06): no
/// flip within the connect hold of a start, a bind or a resume.
#[cfg(target_os = "linux")]
#[test]
fn a_resume_holds_the_restart_while_the_first_link_comes_up() {
    use std::time::{Duration, Instant};

    let t0 = Instant::now();
    let held = role::extended_hold(None, t0);
    assert_eq!(role::hold_left(Some(held), t0), Some(role::CONNECT_HOLD));
    assert_eq!(
        role::hold_left(Some(held), t0 + Duration::from_secs(60)),
        Some(role::CONNECT_HOLD - Duration::from_secs(60))
    );
    assert_eq!(role::hold_left(Some(held), t0 + role::CONNECT_HOLD), None);
    assert_eq!(role::hold_left(None, t0), None);
    // A later resume extends the hold; an earlier one never shortens it.
    let later = role::extended_hold(Some(held), t0 + Duration::from_secs(120));
    assert_eq!(later, t0 + Duration::from_secs(120) + role::CONNECT_HOLD);
    assert_eq!(role::extended_hold(Some(later), t0), later);

    let dir = tempfile::tempdir().unwrap();
    let mut updater = role::UpdaterRole::new(image(dir.path()));
    let before = Instant::now();
    cmux_server_core::role::Role::on_event(
        &mut updater,
        &cmux_server_core::role::HostEvent::Resumed,
    )
    .unwrap();
    let left = role::held_for(before).expect("a resume holds the next flip");
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
}

/// Review F1 of #37256: a resume while an update downloads or stages still
/// holds that update's flip, which looks at the hold right before it.
#[cfg(target_os = "linux")]
#[test]
fn a_hold_that_starts_during_staging_holds_the_flip() {
    let dir = tempfile::tempdir().unwrap();
    let mut updater = role::UpdaterRole::new(image(dir.path()));
    cmux_server_core::role::Role::on_event(
        &mut updater,
        &cmux_server_core::role::HostEvent::Resumed,
    )
    .unwrap();
    match role::held_outcome(std::time::Instant::now()) {
        Some(role::Outcome::Busy(why)) => assert!(why[0].contains("connect hold"), "{why:?}"),
        other => panic!("the flip is not held: {other:?}"),
    }
}

/// A new machine is a restore of the bake's snapshot: `realtime - boottime`
/// jumps by the stopped time, which starts the connect hold before the
/// supervisor's `Resumed` arrives; a clock sync's drift does not.
#[cfg(target_os = "linux")]
#[test]
fn a_snapshot_restore_counts_from_the_clock_offset_not_a_sync() {
    let second = 1_000_000_000_i128;
    assert!(!role::restored_between(None, 50 * second));
    assert!(!role::restored_between(Some(50 * second), 50 * second + second / 2));
    assert!(role::restored_between(Some(50 * second), 50 * second + 3 * 24 * 3600 * second));
}

/// Attached carrier sessions hold an update, an unreadable list too, and only
/// for [`carrier::CARRIER_MAX_HOLD`]: then the update goes at the next idle
/// gap of the agent turns, and the bound is reported once. No sessions ends
/// the hold, so the next attach gets a whole one.
#[test]
fn carrier_sessions_hold_the_flip_up_to_the_bound() {
    use std::time::{Duration, Instant};

    use carrier::{CARRIER_MAX_HOLD, CarrierHold};

    let t0 = Instant::now();
    let mut hold = CarrierHold::default();
    let idle = hold.look(t0, Ok(Vec::new()));
    assert_eq!(idle.busy, None);
    assert!(!idle.new_session);

    let mac = vec!["device-a/s1".to_owned()];
    let attached = hold.look(t0 + Duration::from_secs(60), Ok(mac.clone()));
    assert!(attached.busy.as_deref().is_some_and(|why| why.contains("1 carrier session")));
    assert!(attached.new_session, "a session the last look did not see is a new connect");

    let later = hold.look(t0 + Duration::from_secs(60) + CARRIER_MAX_HOLD / 2, Ok(mac.clone()));
    assert!(later.busy.is_some(), "still inside the bound");
    assert!(!later.new_session);

    let unknown = hold.look(
        t0 + Duration::from_secs(60) + CARRIER_MAX_HOLD / 2,
        Err("its admin channel answered exit status: 1".to_owned()),
    );
    assert!(unknown.busy.as_deref().is_some_and(|why| why.contains("unknown")), "{unknown:?}");

    let passed = hold.look(t0 + Duration::from_secs(60) + CARRIER_MAX_HOLD, Ok(mac.clone()));
    assert_eq!(passed.busy, None, "a stuck session holds no update past the bound");
    assert!(passed.bound_passed);
    let again = hold.look(t0 + Duration::from_secs(120) + CARRIER_MAX_HOLD, Ok(mac));
    assert_eq!(again.busy, None);
    assert!(!again.bound_passed, "the bound is reported once");

    // The Mac leaves; its next attach is held from that look on.
    let t1 = t0 + 2 * CARRIER_MAX_HOLD;
    assert_eq!(hold.look(t1, Ok(Vec::new())).busy, None);
    let back = hold.look(t1 + Duration::from_secs(5), Ok(vec!["device-a/s2".to_owned()]));
    assert!(back.busy.is_some());
    assert!(back.new_session);
}

/// The admin channel's list: connected and reconnecting (inside the resume
/// lease) sessions are attached, a restart would end both; closed ones are not.
#[test]
fn attached_carrier_sessions_are_connected_or_reconnecting() {
    let list = json!([
        {"device_id": "d1", "session_id": "a", "generation": 1, "state": "connected",
         "resume_lease_remaining_ms": null, "lane_bindings": [], "physical_link_count": 1},
        {"device_id": "d1", "session_id": "b", "generation": 2, "state": "reconnecting",
         "resume_lease_remaining_ms": 9000, "lane_bindings": [], "physical_link_count": 0},
        {"device_id": "d2", "session_id": "c", "generation": 1, "state": "closed",
         "resume_lease_remaining_ms": null, "lane_bindings": [], "physical_link_count": 0},
        {"device_id": "d2", "session_id": "d", "generation": 1, "state": "disconnected",
         "resume_lease_remaining_ms": null, "lane_bindings": [], "physical_link_count": 0},
    ]);
    assert_eq!(
        carrier::attached_sessions_in(&list.to_string()),
        Some(vec!["d1/a".to_owned(), "d1/b".to_owned()])
    );
    assert_eq!(carrier::attached_sessions_in("[]"), Some(Vec::new()));
    assert_eq!(carrier::attached_sessions_in("{\"error\": \"no daemon\"}"), None);
    assert_eq!(carrier::attached_sessions_in("remote daemon is not running"), None);
}

/// A claimed spare raises neither `Resumed` nor `Bound`; what its updater
/// sees is the person's first carrier session. A session the last look did
/// not see starts the connect hold, so the flip waits through that first
/// connect even once the carrier hold's bound has passed.
#[cfg(target_os = "linux")]
#[test]
fn a_new_carrier_session_starts_the_connect_hold() {
    use std::time::{Duration, Instant};

    assert_eq!(role::carrier_busy_from(Ok(Vec::new())), None);
    let before = Instant::now();
    let busy = role::carrier_busy_from(Ok(vec!["claimer/first-link".to_owned()]));
    assert!(busy.is_some(), "an attached session holds the update");
    let left = role::held_for(before).expect("a new carrier session holds the next flip");
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
    match role::held_outcome(Instant::now()) {
        Some(role::Outcome::Busy(why)) => assert!(why[0].contains("connect hold"), "{why:?}"),
        other => panic!("the flip is not held: {other:?}"),
    }
}

/// The Cloud role's bind commit (a fresh machine bound to its person) starts
/// the connect hold through the same call, which the supervisor's `Bound`
/// (an instance id change) does not cover.
#[cfg(target_os = "linux")]
#[test]
fn a_bind_commit_starts_the_connect_hold() {
    use std::time::{Duration, Instant};

    let before = Instant::now();
    role::hold_connects();
    let left = role::held_for(before).expect("a bind holds the next flip");
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
}
