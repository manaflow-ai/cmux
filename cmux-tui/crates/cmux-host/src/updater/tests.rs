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
    use std::time::Duration;

    let gate_dir = tempfile::tempdir().unwrap();
    let held = gate::Gate::new(&Paths::new(gate_dir.path()));
    held.hold(T0_MS, role::CONNECT_HOLD).unwrap();
    assert_eq!(held.held_left(T0_MS).unwrap(), Some(role::CONNECT_HOLD));
    assert_eq!(
        held.held_left(T0_MS + 60_000).unwrap(),
        Some(role::CONNECT_HOLD - Duration::from_secs(60))
    );
    let end = T0_MS + role::CONNECT_HOLD.as_millis() as u64;
    assert_eq!(held.held_left(end).unwrap(), None);
    // A later resume extends the hold; an earlier one never shortens it.
    held.hold(T0_MS + 120_000, role::CONNECT_HOLD).unwrap();
    assert_eq!(held.held_left(end).unwrap(), Some(Duration::from_secs(120)));
    held.hold(T0_MS, role::CONNECT_HOLD).unwrap();
    assert_eq!(held.held_left(end).unwrap(), Some(Duration::from_secs(120)));

    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    let mut updater = role::UpdaterRole::new(paths.clone());
    cmux_server_core::role::Role::on_event(
        &mut updater,
        &cmux_server_core::role::HostEvent::Resumed,
    )
    .unwrap();
    let left = role::held_for(&paths).expect("a resume holds the next flip");
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
}

/// Review F1 of #37256: a resume while an update downloads or stages still
/// holds that update's flip, which looks at the hold right before it.
#[cfg(target_os = "linux")]
#[test]
fn a_hold_that_starts_during_staging_holds_the_flip() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    let mut updater = role::UpdaterRole::new(paths.clone());
    cmux_server_core::role::Role::on_event(
        &mut updater,
        &cmux_server_core::role::HostEvent::Resumed,
    )
    .unwrap();
    match role::held_outcome(&paths) {
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
    use std::time::Duration;

    let _shared = SHARED_CARRIER_HOLD.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    assert_eq!(role::carrier_busy_from(&paths, Ok(Vec::new())), None);
    let busy = role::carrier_busy_from(&paths, Ok(vec!["claimer/first-link".to_owned()]));
    assert!(busy.is_some(), "an attached session holds the update");
    let left = role::held_for(&paths).expect("a new carrier session holds the next flip");
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
    match role::held_outcome(&paths) {
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
    use std::time::Duration;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    assert!(role::hold_connects(&paths), "no restart pending: the bind goes");
    let left = role::held_for(&paths).expect("a bind holds the next flip");
    assert!(left > role::CONNECT_HOLD - Duration::from_secs(5), "{left:?}");
}

#[cfg(target_os = "linux")]
const SECOND_NS: i128 = 1_000_000_000;
/// A boot time of the pause tests (ns).
#[cfg(target_os = "linux")]
const B0: i128 = 5_000_000 * SECOND_NS;

/// The pause watch at `B0`, its last look, with no pause found yet.
#[cfg(target_os = "linux")]
fn watch_at_b0() -> crate::agent::PauseWatch {
    let watch = crate::agent::PauseWatch::new();
    watch.looked(B0, false);
    watch
}

/// The boot and wall clock `s` seconds after `B0` / `T0_MS`.
#[cfg(target_os = "linux")]
fn at(s: i128) -> (i128, u64) {
    (B0 + s * SECOND_NS, T0_MS + u64::try_from(s).unwrap() * 1000)
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

/// A claimed spare is a paused machine resumed, and on Freestyle the boot
/// clock runs through the pause (every production probe machine, 2026-11-07
/// to 11-08, reports one boot at 2026-10-31T03:02Z), so `realtime - boottime`
/// never moves. The worker's 60 s wait ends at once on the resume and its
/// hold ran out before the pause: 17 of 45 production chat runs flipped 1 to
/// 184 s after the create. The pause watch counted it: that holds the flip.
#[cfg(target_os = "linux")]
#[test]
fn a_pause_the_watch_found_starts_the_connect_hold() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let gate = gate::Gate::new(&paths);
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    // An ordinary minute, the watch looking every 10 s: no hold.
    watch.looked(at(60).0, false);
    assert!(!role::hold_if_paused(&paths, &watch, &handled, at(65)));
    assert_eq!(gate.held_left(at(65).1).unwrap(), None);
    // Paused 40 minutes in its pool, then claimed: the watch found it.
    watch.looked(at(65 + 2400).0, true);
    let resumed = at(65 + 2401);
    assert!(role::hold_if_paused(&paths, &watch, &handled, resumed));
    assert_eq!(gate.held_left(resumed.1).unwrap(), Some(role::CONNECT_HOLD));
    // Handled: the next look, with the watch fresh, holds no more.
    assert!(!role::hold_if_paused(&paths, &watch, &handled, at(65 + 2405)));
}

/// A wait or check that ends at the resume can look before the watch wakes
/// from the same pause: a watch that has not looked for longer than a pause
/// takes to find is still waking from one, and that holds too.
#[cfg(target_os = "linux")]
#[test]
fn a_pause_the_watch_has_not_woken_from_yet_holds() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    // 25 s since its last look: within a tick and its slack.
    assert!(!role::hold_if_paused(&paths, &watch, &handled, at(25)));
    // 3 minutes since: the machine was stopped.
    assert!(role::hold_if_paused(&paths, &watch, &handled, at(180)));
    assert!(gate::Gate::new(&paths).held_left(at(180).1).unwrap().is_some());
}

/// Design review of #39049 (cloud-v0-lead): a spare paused 3 minutes during
/// a check and then claimed is held, whether the check returns early (its
/// busy look timed out across the pause) or goes on to its flip.
#[cfg(target_os = "linux")]
#[test]
fn a_three_minute_pause_during_a_check_that_returns_early_holds() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    let clock = || at(182);
    let outcome = role::check_step(&paths, &watch, &handled, &clock, || {
        // The busy look: paused 3 minutes, then the watch woke and found it.
        watch.looked(at(181).0, true);
        role::Outcome::Busy(vec!["acpmux: timed out".to_owned()])
    });
    assert!(matches!(outcome, role::Outcome::Busy(_)), "{outcome:?}");
    assert_eq!(gate::Gate::new(&paths).held_left(at(182).1).unwrap(), Some(role::CONNECT_HOLD));

    // A quick check that returns early holds nothing.
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    let quick = || at(2);
    role::check_step(&paths, &watch, &handled, &quick, || role::Outcome::Current("abc".to_owned()));
    assert_eq!(gate::Gate::new(&paths).held_left(at(2).1).unwrap(), None);
}

#[cfg(target_os = "linux")]
#[test]
fn a_three_minute_pause_during_a_check_holds_its_flip() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    // Paused 3 minutes during the staging download; the watch found it.
    watch.looked(at(181).0, true);
    let mut last = Some(0);
    assert!(role::flip_look(&paths, &watch, &handled, &mut last, 0, at(182)));
    let gate = gate::Gate::new(&paths);
    assert_eq!(gate.held_left(at(182).1).unwrap(), Some(role::CONNECT_HOLD));
    // The flip runs inside the gate, which refuses it while the hold is on.
    assert!(gate.run_test(at(182).1, true, |_| ()).is_err(), "the flip ran under the hold");
}

/// Follow-up of #39049 (cloud-v0-lead): the pause record must reach the
/// processes that flip outside the service, the operator's `cmux host update
/// check`. The service's watch writes each look and pause to the record file,
/// and a watch loaded from it holds by the same rule: a pause it found, and a
/// watch still waking from one.
#[cfg(target_os = "linux")]
#[test]
fn another_process_reads_the_pause_record_and_holds() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let file = paths.at(PAUSE_FILE);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let service = crate::agent::PauseWatch::new();
    service.persist_to(file);
    service.looked(B0, false);

    // The operator's check, in its own process: no watch of its own.
    let check = role::OtherLook::start(&paths, 0);
    let looks = check.looks();
    assert!(looks.watch.has_looked(), "the record did not reach the other process");
    assert!(!role::hold_if_paused(&paths, looks.watch, looks.handled, at(5)));
    // Still waking from a 3-minute pause: held.
    assert!(role::hold_if_paused(&paths, looks.watch, looks.handled, at(180)));

    // The service's watch counts the pause after this check took its count:
    // held once, by the count the file carries.
    service.looked(at(181).0, true);
    assert!(role::hold_if_paused(&paths, looks.watch, looks.handled, at(182)));
    assert!(!role::hold_if_paused(&paths, looks.watch, looks.handled, at(183)));
    // A check that starts after it takes it as handled.
    let later = role::OtherLook::start(&paths, 0);
    let looks = later.looks();
    assert!(!role::hold_if_paused(&paths, looks.watch, looks.handled, at(184)));
    // No record at all: nothing to read, no hold.
    let none = crate::agent::PauseWatch::load(&dir.path().join("missing.json"));
    assert!(!none.has_looked());
}

/// The operator's check keeps its own restore look from its start: a restore
/// during it holds its flip, though the service's worker in another process
/// holds the baseline.
#[cfg(target_os = "linux")]
#[test]
fn another_process_keeps_its_own_restore_look() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let check = role::OtherLook::start(&paths, 0);
    let looks = check.looks();
    let mut last = looks.offset.lock().unwrap();
    assert!(role::flip_look(
        &paths,
        looks.watch,
        looks.handled,
        &mut last,
        3_600 * SECOND_NS,
        at(5),
    ));
    assert_eq!(gate::Gate::new(&paths).held_left(at(5).1).unwrap(), Some(role::CONNECT_HOLD));
}

/// Review F2 of #39049: a pause the watch found after the previous wait's
/// last look and before the next step began is still held. Comparing the
/// pause's time with the step's start missed it; the count the worker keeps
/// across steps does not.
#[cfg(target_os = "linux")]
#[test]
fn a_pause_found_between_two_steps_holds() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    // The wait's last look at 60 s found nothing.
    watch.looked(at(60).0, false);
    assert!(!role::hold_if_paused(&paths, &watch, &handled, at(60)));
    // Between the wait and the check: a 3-minute pause, which the watch found.
    watch.looked(at(250).0, true);
    // The check starts after that and returns early; its look still holds.
    let clock = || at(255);
    role::check_step(&paths, &watch, &handled, &clock, || role::Outcome::Current("abc".to_owned()));
    assert_eq!(gate::Gate::new(&paths).held_left(at(255).1).unwrap(), Some(role::CONNECT_HOLD));
}

/// Review F1 of #39049: where a restore stops the boot clock, the pause watch
/// stays fresh and the supervisor counts the restore only when its clock-set
/// dispatch runs. A flip that looks before that dispatch is still held by
/// its own `realtime - boottime` look.
#[cfg(target_os = "linux")]
#[test]
fn a_restore_the_supervisor_has_not_dispatched_holds_the_flip() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    // The watch looked a moment ago and counted nothing: no found() yet.
    watch.looked(at(5).0, false);
    let offset = 1_000 * SECOND_NS;
    let mut last = Some(offset);
    // A sync's drift: no hold.
    assert!(!role::flip_look(&paths, &watch, &handled, &mut last, offset + SECOND_NS, at(6)));
    // Restored after an hour stopped: realtime moved against the boot clock.
    assert!(role::flip_look(&paths, &watch, &handled, &mut last, offset + 3600 * SECOND_NS, at(7)));
    assert_eq!(gate::Gate::new(&paths).held_left(at(7).1).unwrap(), Some(role::CONNECT_HOLD));
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
    assert!(
        role::timeout_rollback_waits(&mut carrier, || None, &rx_checks),
        "it rolls back once idle"
    );
    assert!(looks.is_empty(), "it looked until the sessions left");

    let mut attached = || Some("1 carrier session(s) attached".to_owned());
    tx.send(role::Msg::Stop).unwrap();
    assert!(
        !role::timeout_rollback_waits(&mut attached, || None, &rx_checks),
        "a stop ends the wait"
    );
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
    role::guard_rollback_waits(
        &mut carrier,
        || None,
        |d| {
            slept += d;
            clock.set(clock.get() + d);
        },
    );
    assert!(slept >= carrier::CARRIER_MAX_HOLD, "it rolled back after {slept:?}");
    assert!(slept < carrier::CARRIER_MAX_HOLD + Duration::from_secs(120), "{slept:?}");

    let mut idle = || None;
    let mut slept = Duration::ZERO;
    role::guard_rollback_waits(&mut idle, || None, |d| slept += d);
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
    use std::time::{Duration, Instant};

    use carrier::{CARRIER_MAX_HOLD, CarrierHold};

    let dir = tempfile::tempdir().unwrap();
    let held = gate::Gate::new(&Paths::new(dir.path()));
    let start = || {
        held.hold(T0_MS, role::CONNECT_HOLD).unwrap();
    };
    let t0 = Instant::now();
    let mut hold = CarrierHold::default();
    for minute in 0..=CARRIER_MAX_HOLD.as_secs() / 60 {
        let at = t0 + Duration::from_secs(minute * 60);
        let look = hold.look(at, Err("its admin channel answered exit status: 1".to_owned()));
        role::act_on_look(look, start);
    }
    assert_eq!(held.held_left(T0_MS).unwrap(), None, "failed reads start no connect hold");

    let at = t0 + CARRIER_MAX_HOLD + Duration::from_secs(120);
    let look = hold.look(at, Ok(vec!["mac/s1#1".to_owned()]));
    role::act_on_look(look, start);
    let left =
        held.held_left(T0_MS).unwrap().expect("the first readable session starts the connect hold");
    assert_eq!(left, role::CONNECT_HOLD);
}

/// Review P1s of #38483 at b82f2bf1: the connect hold and the pending
/// restart live in the state dir (`gate::Gate`, one flock-guarded file), not
/// in a process's memory, so `cmux host update check` (its own process),
/// the guard and the service all see them. Two handles on one root stand in
/// for the service and the CLI.
fn gate_handles() -> (tempfile::TempDir, gate::Gate, gate::Gate) {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    (dir, gate::Gate::new(&paths), gate::Gate::new(&paths))
}

const T0_MS: u64 = 1_794_000_000_000;

/// (a) The CLI's check sees the service's connect hold and doesn't flip;
/// once the hold ends it does.
#[test]
fn a_cli_check_sees_the_service_connect_hold_and_does_not_flip() {
    use std::time::Duration;

    let (_dir, service, cli) = gate_handles();
    assert!(
        service.hold(T0_MS, gate::CONNECT_HOLD).unwrap(),
        "a bind with no restart pending goes"
    );
    let mut ran = false;
    let held = cli.run_test(T0_MS + 60_000, true, |_| ran = true);
    assert!(
        matches!(held, Err(gate::Refused::Held(left)) if left == gate::CONNECT_HOLD - Duration::from_secs(60))
    );
    assert!(!ran, "the CLI flipped during the service's connect hold");
    assert_eq!(
        cli.held_left(T0_MS + 60_000).unwrap(),
        Some(gate::CONNECT_HOLD - Duration::from_secs(60))
    );

    let after = T0_MS + gate::CONNECT_HOLD.as_millis() as u64;
    assert_eq!(cli.held_left(after).unwrap(), None);
    assert!(cli.run_test(after, true, |_| ran = true).is_ok());
    assert!(ran, "past the hold the CLI flips");
}

/// (b) A restart the CLI queued is pending for the service: a bind there
/// refuses until the restarted service clears the mark at its start.
#[test]
fn a_cli_queued_restart_refuses_binds_until_the_service_restarts() {
    let (_dir, service, cli) = gate_handles();
    assert!(cli.run_test(T0_MS, true, |queued| queued()).is_ok());
    assert!(
        !service.hold(T0_MS + 1_000, gate::CONNECT_HOLD).unwrap(),
        "a bind went out with a restart pending"
    );
    assert!(!service.hold(T0_MS + 30_000, gate::CONNECT_HOLD).unwrap(), "still pending 30 s on");
    // The restarted cmux-host clears the mark before it accepts binds.
    service.service_started(T0_MS + 31_000).unwrap();
    assert!(
        service.hold(T0_MS + 31_000, gate::CONNECT_HOLD).unwrap(),
        "the restarted service binds"
    );
}

/// (c) The pending mark lasts at most RESTART_PENDING_FOR: a restart that
/// never came can't block binds for ever.
#[test]
fn a_pending_restart_mark_expires_after_its_bound() {
    let (_dir, service, cli) = gate_handles();
    assert!(
        cli.run_test(T0_MS, false, |queued| queued()).is_ok(),
        "a rollback runs under no hold too"
    );
    let bound = gate::RESTART_PENDING_FOR.as_millis() as u64;
    assert!(!service.hold(T0_MS + bound - 1, gate::CONNECT_HOLD).unwrap());
    assert!(
        service.hold(T0_MS + bound, gate::CONNECT_HOLD).unwrap(),
        "the mark outlived its bound"
    );
}

/// A bind in the service that lands while the CLI's gate runs waits on the
/// flock until the CLI queued its restart, then refuses; a rollback (which
/// the hold doesn't stop) is serialized the same way.
#[test]
fn a_bind_waits_for_another_process_gate_and_sees_its_restart() {
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    for honor_hold in [true, false] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_owned();
        let (in_window, window) = mpsc::channel::<()>();
        let cli = std::thread::spawn(move || {
            gate::Gate::new(&Paths::new(&root)).run_test(T0_MS, honor_hold, |queued| {
                in_window.send(()).unwrap();
                std::thread::sleep(Duration::from_millis(200));
                queued();
                Instant::now()
            })
        });
        window.recv().unwrap();
        let may_bind =
            gate::Gate::new(&Paths::new(dir.path())).hold(T0_MS + 100, gate::CONNECT_HOLD).unwrap();
        let bind_done = Instant::now();
        let queued_at = cli.join().unwrap().unwrap();
        assert!(bind_done >= queued_at, "the bind did not wait for the gate");
        assert!(!may_bind, "a bind went out between the flip and the restart");
    }
}

/// Review F1 of #38326's P2s: the connection list fails closed. An entry
/// that is not a session object, an unknown state or a missing field makes
/// the whole list unreadable (`None`, which holds the update), never an
/// empty list that lets a restart cut an attached session.
#[test]
fn a_malformed_connection_list_fails_closed() {
    let row = |state: &str| {
        json!({"device_id": "d", "session_id": "s", "generation": 1, "state": state,
               "resume_lease_remaining_ms": null, "lane_bindings": [], "physical_link_count": 1})
    };
    assert_eq!(carrier::attached_sessions_in("[null]"), None, "[null]");
    assert_eq!(carrier::attached_sessions_in("[1, \"x\"]"), None);
    let unknown = json!([row("connected"), row("half-open")]);
    assert_eq!(carrier::attached_sessions_in(&unknown.to_string()), None, "an unknown state");
    for field in ["device_id", "session_id", "generation", "state"] {
        let mut entry = row("connected");
        entry.as_object_mut().unwrap().remove(field);
        let list = json!([entry]).to_string();
        assert_eq!(carrier::attached_sessions_in(&list), None, "missing {field}");
    }
    let mut wrong = row("connected");
    wrong["generation"] = json!("1");
    assert_eq!(
        carrier::attached_sessions_in(&json!([wrong]).to_string()),
        None,
        "a string generation"
    );
    // Known states still read.
    let fine = json!([row("connected"), row("closed")]).to_string();
    assert_eq!(carrier::attached_sessions_in(&fine), Some(vec!["d/s#1".to_owned()]));
}

/// Review F2 of #38483: a gate state that can't be read (here, unparsable)
/// fails closed. No update flips on it, a bind that would go out is refused,
/// and the gate replaces it with a held, restart-pending state that lapses
/// on its own, so a machine never wedges on a bad file.
#[test]
fn an_unreadable_gate_state_fails_closed_then_recovers() {
    let (dir, service, cli) = gate_handles();
    let paths = Paths::new(dir.path());
    std::fs::create_dir_all(paths.at(gate::GATE_FILE).parent().unwrap()).unwrap();
    std::fs::write(paths.at(gate::GATE_FILE), b"{not json").unwrap();
    let mut flipped = false;
    assert!(cli.run_test(T0_MS, true, |_| flipped = true).is_err());
    assert!(!flipped, "an update flipped on an unreadable gate state");
    assert!(
        !service.hold(T0_MS, gate::CONNECT_HOLD).unwrap(),
        "a bind went out on an unreadable gate state"
    );
    let later = T0_MS + gate::CONNECT_HOLD.as_millis() as u64 + 1;
    assert!(service.hold(later, gate::CONNECT_HOLD).unwrap(), "the gate never recovered");
    let mut ran = false;
    let after_hold = later + gate::CONNECT_HOLD.as_millis() as u64 + 1;
    assert!(cli.run_test(after_hold, true, |_| ran = true).is_ok());
    assert!(ran);
}

/// Review F1 of #38483: a rollback refused by a bind in flight looks at
/// carrier sessions again (the bound machine's first link may be one) and
/// retries; it rolls back once the bind is done and no session holds it.
#[cfg(target_os = "linux")]
#[test]
fn a_rollback_refused_by_a_bind_in_flight_looks_again_and_retries() {
    use std::time::Duration;

    let mut looks = vec![None, Some("1 carrier session(s) attached".to_owned()), None];
    let mut carrier = || looks.pop().flatten();
    let mut tries = vec![None, Some(Duration::from_secs(5))];
    let mut waited = Vec::new();
    assert!(role::rollback_when_clear(
        &mut carrier,
        || tries.pop().flatten(),
        |d| {
            waited.push(d);
            true
        }
    ));
    assert!(tries.is_empty(), "it did not retry after the bind");
    assert!(looks.is_empty(), "it did not look at carrier sessions again");
    assert_eq!(waited, [Duration::from_secs(5), role::BUSY_RETRY]);
}

/// Review F1 of #38483: a rollback the gate refused for a bind in flight
/// marks the restart pending, so no new bind starts and the wait is bounded
/// by the one in flight.
#[test]
fn a_rollback_refused_by_a_bind_in_flight_stops_new_binds() {
    let (_dir, service, cli) = gate_handles();
    assert!(service.begin_bind(T0_MS).unwrap());
    let mut ran = false;
    let refused = cli.run_test(T0_MS + 1_000, false, |_| ran = true);
    assert!(matches!(refused, Err(gate::Refused::BindInFlight(_))), "{refused:?}");
    assert!(!ran);
    assert!(!service.begin_bind(T0_MS + 2_000).unwrap(), "a new bind started under the rollback");
    service.end_bind(T0_MS + 3_000).unwrap();
    assert!(cli.run_test(T0_MS + 4_000, false, |_| ran = true).is_ok());
    assert!(ran, "the rollback did not go once the bind was done");
    // A bind whose process died before clearing its mark holds for the bound only.
    let (_dir, service, cli) = gate_handles();
    assert!(service.begin_bind(T0_MS).unwrap());
    let lapsed = T0_MS + gate::BIND_IN_FLIGHT_FOR.as_millis() as u64;
    assert!(cli.run_test(lapsed, false, |_| ()).is_ok(), "a dead bind's mark outlived its bound");
}

/// Review of #38731: repairing an unparsable gate state keeps the bind
/// barrier. The bind that was in flight when the file broke may still be,
/// so a rollback waits for a fresh in-flight bound before it flips.
#[test]
fn a_repaired_gate_state_keeps_a_bind_in_flight() {
    let (dir, _service, cli) = gate_handles();
    let paths = Paths::new(dir.path());
    std::fs::create_dir_all(paths.at(gate::GATE_FILE).parent().unwrap()).unwrap();
    std::fs::write(paths.at(gate::GATE_FILE), b"{not json").unwrap();
    let mut ran = false;
    let refused = cli.run_test(T0_MS, false, |_| ran = true);
    assert!(matches!(refused, Err(gate::Refused::BindInFlight(_))), "{refused:?}");
    assert!(!ran, "a rollback flipped over a repaired gate state");
    let lapsed = T0_MS + gate::BIND_IN_FLIGHT_FOR.as_millis() as u64;
    assert!(cli.run_test(lapsed, false, |_| ran = true).is_ok());
    assert!(ran, "the repaired barrier outlived its bound");
}

/// The tests that drive the forward update's carrier hold (a global) take
/// this, so they never see each other's sessions.
#[cfg(target_os = "linux")]
static SHARED_CARRIER_HOLD: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Review of #38483 (P2): a rollback's wait has its own carrier hold, started
/// when the wait begins. Past the forward update's 30-minute bound, a
/// session that just reconnected still holds the rollback, for the
/// rollback's own bound.
#[cfg(target_os = "linux")]
#[test]
fn a_rollback_wait_after_the_forward_hold_expired_still_holds_a_new_session() {
    use std::time::{Duration, Instant};

    let _shared = SHARED_CARRIER_HOLD.lock().unwrap_or_else(|e| e.into_inner());
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let t0 = Instant::now();
    let past_bound = t0 + carrier::CARRIER_MAX_HOLD + Duration::from_secs(60);
    // The forward update held for a stuck session until its bound passed.
    assert!(role::carrier_busy_at(&paths, t0, Ok(vec!["d1/a#1".to_owned()])).is_some());
    assert_eq!(role::carrier_busy_at(&paths, past_bound, Ok(vec!["d1/a#1".to_owned()])), None);

    // The rollback's wait begins; the session just reconnected.
    let mut rollback = role::RollbackCarrier::default();
    let reconnected = || Ok(vec!["d1/a#2".to_owned()]);
    assert!(
        rollback.look(&paths, past_bound, reconnected()).is_some(),
        "the rollback restarted under a session that just reconnected"
    );
    let later = past_bound + carrier::CARRIER_MAX_HOLD - Duration::from_secs(60);
    assert!(rollback.look(&paths, later, reconnected()).is_some(), "held under its own bound");
    let after = past_bound + carrier::CARRIER_MAX_HOLD + Duration::from_secs(1);
    assert_eq!(rollback.look(&paths, after, reconnected()), None, "its own bound passed");
    assert_eq!(rollback.look(&paths, after, Err("unreadable".to_owned())), None);
}

/// Review P1 of #39049: the watch publishes a look that found a pause in the
/// middle of the updater's read. The read sees the old count and the old
/// look, or the new count and the new look, never the old count with the
/// new look (which reads as a current watch and no new pause).
#[cfg(target_os = "linux")]
#[test]
fn a_pause_published_during_the_read_still_holds() {
    use std::sync::Arc;
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = Arc::new(crate::agent::PauseWatch::new());
    watch.looked(B0, false);
    let handled = AtomicU64::new(watch.pause_seq());
    // The watch's look after a 3-minute pause lands between the read's two fields.
    let publisher = Arc::clone(&watch);
    crate::agent::BETWEEN_READS.with(|hook| {
        *hook.borrow_mut() = Some(Box::new(move || publisher.looked(at(180).0, true)));
    });
    assert!(
        role::hold_if_paused(&paths, &watch, &handled, at(181)),
        "a pause published during the read was missed"
    );
    assert_eq!(gate::Gate::new(&paths).held_left(at(181).1).unwrap(), Some(role::CONNECT_HOLD));
}
