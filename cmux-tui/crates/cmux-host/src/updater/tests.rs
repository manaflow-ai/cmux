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
        Some(vec!["d1/a#1".to_owned(), "d1/b#2".to_owned()])
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

/// Review F1 of #38280: each look at `realtime - boottime` compares with the
/// look just before it, so many clock syncs, each below a restore's jump,
/// never start the connect hold however far they move the clock in total.
/// One real jump still does.
#[cfg(target_os = "linux")]
#[test]
fn many_small_clock_syncs_never_start_a_restore_hold() {
    let step = crate::agent::RESUME_CLOCK_JUMP_NS - 1;
    let mut last = None;
    let mut offset = 0_i128;
    assert!(!role::restore_look(&mut last, offset), "the first look has nothing to compare");
    for _ in 0..1000 {
        offset += step;
        assert!(!role::restore_look(&mut last, offset), "a sync started a hold at {offset}");
    }
    assert!(offset > 1000 * crate::agent::RESUME_CLOCK_JUMP_NS / 2, "the syncs added up");
    assert!(role::restore_look(&mut last, offset + 3600 * 1_000_000_000), "a restore");
    assert!(!role::restore_look(&mut last, offset + 3600 * 1_000_000_000 + step));
}

/// A bind that lands while a gated flip (`update`) or rollback runs: it
/// waits for the restart to be queued, then learns of it and doesn't bind.
#[cfg(target_os = "linux")]
fn bind_during_gate(honor_hold: bool) {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    let held = Arc::new(Mutex::new(None::<Instant>));
    let restarting = Arc::new(AtomicBool::new(false));
    let (in_window, window) = mpsc::channel::<()>();
    let (restarted, restart_done) = mpsc::channel::<Instant>();
    let flipper = {
        let held = Arc::clone(&held);
        let restarting = Arc::clone(&restarting);
        std::thread::spawn(move || {
            let mark = || restarting.store(true, Ordering::SeqCst);
            role::gate(&held, Instant::now(), honor_hold, &mark, |queued| {
                in_window.send(()).unwrap();
                // The flip takes a moment, then the restarts are queued.
                std::thread::sleep(Duration::from_millis(200));
                queued();
                restarted.send(Instant::now()).unwrap();
            })
        })
    };
    window.recv().unwrap();
    // The bind lands inside the window.
    let may_bind = role::hold_in(&held, Instant::now(), || restarting.load(Ordering::SeqCst));
    let bind_held_at = Instant::now();
    let restart_queued_at = restart_done.recv().unwrap();
    assert!(flipper.join().unwrap().is_ok(), "the gate had looked before the bind");
    assert!(bind_held_at >= restart_queued_at, "the bind landed before the restart was queued");
    assert!(!may_bind, "a bind went out with this host's restart queued");
}

/// Review F1 of #38326: a bind that takes the connect hold while the flip is
/// between its last look and its restarts waits for them, and a hold taken
/// before the flip's look wins: nothing flips.
#[cfg(target_os = "linux")]
#[test]
fn a_bind_in_the_flip_window_never_lands_between_the_look_and_the_restart() {
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    bind_during_gate(true);

    let held = Mutex::new(None);
    assert!(role::hold_in(&held, Instant::now(), || false), "no restart queued: the bind goes");
    let mut ran = false;
    let outcome = role::gate(&held, Instant::now(), true, &|| {}, |_| ran = true);
    assert!(outcome.is_err_and(|left| left > role::CONNECT_HOLD - Duration::from_secs(5)));
    assert!(!ran, "a flip ran under a hold taken before it");
}

/// Review P1 of #38483: a rollback's flip and restart go through the same
/// gate, so a bind that lands during a rollback waits for its restart and
/// doesn't bind. A rollback is not stopped by the hold (a build that never
/// proved itself is not kept), only serialized with it.
#[cfg(target_os = "linux")]
#[test]
fn a_bind_during_a_rollback_never_lands_between_its_flip_and_restart() {
    use std::sync::Mutex;
    use std::time::Instant;

    bind_during_gate(false);

    let held = Mutex::new(None);
    role::hold_in(&held, Instant::now(), || false);
    let mut ran = false;
    assert!(role::gate(&held, Instant::now(), false, &|| {}, |_| ran = true).is_ok());
    assert!(ran, "a rollback runs under the hold");
}

/// The restart marker refuses binds only in the process it names, and only
/// within the grace: the restarted host (another pid) binds at once, and a
/// restart that never came frees binds again.
#[cfg(target_os = "linux")]
#[test]
fn the_restart_marker_names_one_process_for_a_while() {
    assert!(role::marker_names("4242 1000\n", 4242, 1000));
    assert!(role::marker_names("4242 1000", 4242, 1119));
    assert!(!role::marker_names("4242 1000", 4242, 1120), "past the grace");
    assert!(!role::marker_names("4242 1000", 4243, 1000), "the restarted host");
    assert!(!role::marker_names("0 1000", 0, 1000), "no host ran");
    assert!(!role::marker_names("", 4242, 1000));
    assert!(!role::marker_names("x 1000", 4242, 1000));
}

/// Review F2 of #38326: the health timeout's rollback waits while carrier
/// sessions are attached, looking again every minute, and stops waiting when
/// the role stops.
#[cfg(target_os = "linux")]
#[test]
fn the_health_timeout_rollback_waits_for_carrier_sessions() {
    let mut looks =
        vec![None, Some("1 carrier session(s) attached".to_owned()), Some("1".to_owned())];
    let mut carrier = || looks.pop().flatten();
    // `wait` with no message times out after BUSY_RETRY: too slow for a test,
    // so a Check stands in for each minute.
    let (tx, rx_checks) = std::sync::mpsc::channel();
    tx.send(role::Msg::Check).unwrap();
    tx.send(role::Msg::Check).unwrap();
    assert!(role::timeout_rollback_waits(&mut carrier, &rx_checks), "it rolls back once idle");
    assert!(looks.is_empty(), "it looked until the sessions left");

    let mut attached = || Some("1 carrier session(s) attached".to_owned());
    tx.send(role::Msg::Stop).unwrap();
    assert!(!role::timeout_rollback_waits(&mut attached, &rx_checks), "a stop ends the wait");
}

/// Review F2 of #38326: the guard's rollback waits for carrier sessions too,
/// and the bound ends that wait: past CARRIER_MAX_HOLD a stuck session no
/// longer keeps a build that never proved itself.
#[cfg(target_os = "linux")]
#[test]
fn the_guard_rollback_waits_for_carrier_sessions_up_to_the_bound() {
    use std::cell::Cell;
    use std::time::{Duration, Instant};

    let t0 = Instant::now();
    let clock = Cell::new(t0);
    let mut hold = carrier::CarrierHold::default();
    let mut carrier = || hold.look(clock.get(), Ok(vec!["stuck/session".to_owned()])).busy;
    let mut slept = Duration::ZERO;
    role::guard_rollback_waits(&mut carrier, |d| {
        slept += d;
        clock.set(clock.get() + d);
    });
    assert!(slept >= carrier::CARRIER_MAX_HOLD, "it rolled back after {slept:?}");
    assert!(slept < carrier::CARRIER_MAX_HOLD + Duration::from_secs(120), "{slept:?}");

    let mut idle = || None;
    let mut slept = Duration::ZERO;
    role::guard_rollback_waits(&mut idle, |d| slept += d);
    assert_eq!(slept, Duration::ZERO, "no session, no wait");
}

/// Review F1 of #38326 (P2): a reconnect inside the resume lease keeps its
/// device and session ids and bumps only the generation. It is a new connect:
/// past the carrier hold's bound it still starts the connect hold.
#[test]
fn a_reconnect_in_the_resume_lease_is_a_new_session_past_the_bound() {
    use std::time::Duration;

    use carrier::{CARRIER_MAX_HOLD, CarrierHold};

    let row = |generation: u64| {
        json!([{"device_id": "mac", "session_id": "s1", "generation": generation,
                "state": "connected", "resume_lease_remaining_ms": null,
                "lane_bindings": [], "physical_link_count": 1}])
        .to_string()
    };
    let t0 = std::time::Instant::now();
    let mut hold = CarrierHold::default();
    let first = carrier::attached_sessions_in(&row(1)).unwrap();
    assert!(hold.look(t0, Ok(first.clone())).new_session);
    let past = hold.look(t0 + CARRIER_MAX_HOLD, Ok(first));
    assert_eq!(past.busy, None, "past the bound");
    assert!(!past.new_session);

    let reconnected = carrier::attached_sessions_in(&row(2)).unwrap();
    let look = hold.look(t0 + CARRIER_MAX_HOLD + Duration::from_secs(60), Ok(reconnected));
    assert!(look.new_session, "a reconnect that bumped the generation is a new connect");
}

/// Review F2 of #38326 (P2): when every read failed (here past the bound),
/// the first list that reads holds the update as a new connect: its
/// sessions were never seen, so they start the connect hold.
#[test]
fn the_first_read_after_failed_reads_counts_its_sessions_as_new() {
    use std::time::Duration;

    use carrier::{CARRIER_MAX_HOLD, CarrierHold};

    let t0 = std::time::Instant::now();
    let mut hold = CarrierHold::default();
    let unknown = || Err("its admin channel answered exit status: 1".to_owned());
    assert!(hold.look(t0, unknown()).busy.is_some(), "an unreadable list holds");
    let past = hold.look(t0 + CARRIER_MAX_HOLD, unknown());
    assert_eq!(past.busy, None, "the unreadable list's hold is bounded");
    assert!(!past.new_session);

    let read =
        hold.look(t0 + CARRIER_MAX_HOLD + Duration::from_secs(60), Ok(vec!["mac/s1#1".to_owned()]));
    assert!(read.new_session, "sessions never seen before are new");
    // The first look with nothing to compare counts its sessions too.
    let mut fresh = CarrierHold::default();
    assert!(fresh.look(t0, Ok(vec!["mac/s1#1".to_owned()])).new_session);
    assert!(!CarrierHold::default().look(t0, Ok(Vec::new())).new_session);
}

/// Review F2 of #38326, the exact sequence: reads of the session list fail
/// (past the carrier hold's bound), then the first one that reads shows an
/// attached session, and that look starts the 5-minute connect hold.
#[cfg(target_os = "linux")]
#[test]
fn failed_reads_then_an_attached_session_start_the_connect_hold() {
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    use carrier::{CARRIER_MAX_HOLD, CarrierHold};

    let held = Mutex::new(None::<Instant>);
    let start = || {
        role::hold_in(&held, Instant::now(), || false);
    };
    let t0 = Instant::now();
    let mut hold = CarrierHold::default();
    for minute in 0..=CARRIER_MAX_HOLD.as_secs() / 60 {
        let at = t0 + Duration::from_secs(minute * 60);
        let look = hold.look(at, Err("its admin channel answered exit status: 1".to_owned()));
        role::act_on_look(look, start);
    }
    assert_eq!(*held.lock().unwrap(), None, "failed reads start no connect hold");

    let at = t0 + CARRIER_MAX_HOLD + Duration::from_secs(120);
    let look = hold.look(at, Ok(vec!["mac/s1#1".to_owned()]));
    role::act_on_look(look, start);
    let until = held.lock().unwrap().expect("the first readable session starts the connect hold");
    let left = until.saturating_duration_since(Instant::now());
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
}
