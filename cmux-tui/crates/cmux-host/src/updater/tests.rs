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
    // A Linux release file (cmux-tui/<commit>/release.json, the same key) is not a machine update,
    // even one that names this channel.
    let mut release = good.clone();
    release["purpose"] = json!("cmux-linux-release");
    assert!(channel::verify(&envelope(&release, "test"), &keys(), 5_000).is_err());
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

fn with_url(name: &str, url: String) -> Payload {
    let mut p = payload_json(OLD_TUI, OLD_HOOK);
    p["targets"][TARGET][name]["url"] = json!(url);
    serde_json::from_value(p).unwrap()
}

#[test]
fn a_binary_may_come_from_its_commit_machine_copy() {
    // The Cloud machine channel's own (thin LTO) build of the commit: cmux-tui/<commit>/machine/.
    let machine =
        |name: &str| format!("https://files.cmux.com/cmux-tui/{COMMIT}/machine/{name}-{TARGET}");
    let mut p = payload_json(OLD_TUI, OLD_HOOK);
    p["targets"][TARGET]["cmux-tui"]["url"] = json!(machine("cmux-tui"));
    p["targets"][TARGET]["cmux-tui-hook"]["url"] = json!(machine("cmux-tui-hook"));
    let payload = channel::verify(&envelope(&p, "test"), &keys(), 5_000).unwrap();
    let (tui, hook) = payload.binaries_for(TARGET).unwrap();
    assert_eq!(tui.url, machine("cmux-tui"));
    assert_eq!(hook.url, machine("cmux-tui-hook"));
    // One of each kind is fine too: each binary is checked on its own.
    assert!(with_url("cmux-tui", machine("cmux-tui")).binaries_for(TARGET).is_ok());
    assert!(with_url("cmux-tui-hook", machine("cmux-tui-hook")).binaries_for(TARGET).is_ok());
}

#[test]
fn a_binary_url_must_equal_one_of_the_two_exactly() {
    let other = "f".repeat(40);
    let base = "https://files.cmux.com/cmux-tui";
    let near_misses = [
        // Another commit, in either place.
        format!("{base}/{other}/cmux-tui-{TARGET}"),
        format!("{base}/{other}/machine/cmux-tui-{TARGET}"),
        // Another commit's machine copy reached through this commit's directory.
        format!("{base}/{COMMIT}/../{other}/machine/cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/machine/../cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/machine/../../{other}/cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/machine/%2e%2e/cmux-tui-{TARGET}"),
        // Another name: the hook, another target, a suffix or a prefix.
        format!("{base}/{COMMIT}/machine/cmux-tui-hook-{TARGET}"),
        format!("{base}/{COMMIT}/machine/cmux-tui-aarch64-unknown-linux-musl"),
        format!("{base}/{COMMIT}/machine/cmux-tui-{TARGET}.old"),
        format!("{base}/{COMMIT}/machine/x-cmux-tui-{TARGET}"),
        // Another directory, a nested one, a doubled slash or a missing one.
        format!("{base}/{COMMIT}/machines/cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/machine/machine/cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/tree/cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}//cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/machine//cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}machine/cmux-tui-{TARGET}"),
        // A query, a fragment, another scheme or host, a case change.
        format!("{base}/{COMMIT}/machine/cmux-tui-{TARGET}?v=1"),
        format!("{base}/{COMMIT}/machine/cmux-tui-{TARGET}#x"),
        format!("http://files.cmux.com/cmux-tui/{COMMIT}/machine/cmux-tui-{TARGET}"),
        format!("https://files.cmux.com.evil/cmux-tui/{COMMIT}/machine/cmux-tui-{TARGET}"),
        format!("{base}/{COMMIT}/MACHINE/cmux-tui-{TARGET}"),
        format!(" {base}/{COMMIT}/machine/cmux-tui-{TARGET}"),
    ];
    for url in near_misses {
        let payload = with_url("cmux-tui", url.clone());
        assert!(payload.binaries_for(TARGET).is_err(), "{url} passed");
    }
    // And the two allowed ones pass, built from the payload's own commit.
    for url in channel::allowed_urls(COMMIT, &format!("cmux-tui-{TARGET}")) {
        assert!(with_url("cmux-tui", url.clone()).binaries_for(TARGET).is_ok(), "{url} refused");
    }
    // A signed payload of another commit cannot name this commit's machine copy.
    let mut p = payload_json(OLD_TUI, OLD_HOOK);
    p["commit"] = json!(other);
    p["targets"][TARGET]["cmux-tui-hook"]["url"] =
        json!(format!("{base}/{other}/cmux-tui-hook-{TARGET}"));
    p["targets"][TARGET]["cmux-tui"]["url"] =
        json!(format!("{base}/{COMMIT}/machine/cmux-tui-{TARGET}"));
    let payload = channel::verify(&envelope(&p, "test"), &keys(), 5_000).unwrap();
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
    held.hold(T0_MS, role::CONNECT_HOLD, gate::HoldKind::Connect);
    assert_eq!(held.held_left(T0_MS), Some(role::CONNECT_HOLD));
    assert_eq!(held.held_left(T0_MS + 60_000), Some(role::CONNECT_HOLD - Duration::from_secs(60)));
    let end = T0_MS + role::CONNECT_HOLD.as_millis() as u64;
    assert_eq!(held.held_left(end), None);
    // A later resume extends the hold; an earlier one never shortens it.
    held.hold(T0_MS + 120_000, role::CONNECT_HOLD, gate::HoldKind::Connect);
    assert_eq!(held.held_left(end), Some(Duration::from_secs(120)));
    held.hold(T0_MS, role::CONNECT_HOLD, gate::HoldKind::Connect);
    assert_eq!(held.held_left(end), Some(Duration::from_secs(120)));

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
    assert!(
        role::hold_connects(&paths, gate::HoldKind::Connect),
        "no restart pending: the bind goes"
    );
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
    assert_eq!(gate.held_left(at(65).1), None);
    // Paused 40 minutes in its pool, then claimed: the watch found it.
    watch.looked(at(65 + 2400).0, true);
    let resumed = at(65 + 2401);
    assert!(role::hold_if_paused(&paths, &watch, &handled, resumed));
    assert_eq!(gate.held_left(resumed.1), Some(role::CONNECT_HOLD));
    // Handled: the next look, with the watch fresh, holds no more.
    assert!(!role::hold_if_paused(&paths, &watch, &handled, at(65 + 2405)));
}

/// The pause watch's hold is the machine's own wake, a resume hold: the
/// Scaler's refresh of the spare it just claimed
/// (`cmux host update check --skip-resume-hold`, no bind on it) flips past
/// it, and a plain check is held by it.
#[cfg(target_os = "linux")]
#[test]
fn a_pause_watch_hold_flips_with_the_flag_and_holds_without_it() {
    use std::sync::atomic::AtomicU64;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    watch.looked(at(65 + 2400).0, true);
    let resumed = at(65 + 2401);
    assert!(role::hold_if_paused(&paths, &watch, &handled, resumed));
    let now = resumed.1 + 1_000;

    let (gated, skipped) =
        role::flip_in_gate(&paths, || now, gate::Honor::All, || Ok(Vec::new()), || false, no_flip);
    assert!(matches!(gated, role::Gated::Held(_)), "{gated:?}");
    assert_eq!(skipped, None);

    let mut flipped = false;
    let (gated, skipped) = role::flip_in_gate(
        &paths,
        || now,
        gate::Honor::AllButResume,
        || Ok(Vec::new()),
        || false,
        |_| {
            flipped = true;
            Ok::<(), ()>(())
        },
    );
    assert!(matches!(gated, role::Gated::Flipped), "{gated:?}");
    assert!(flipped);
    assert_eq!(skipped, Some(gate::HoldKind::Resume));
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
    assert!(gate::Gate::new(&paths).held_left(at(180).1).is_some());
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
    assert_eq!(gate::Gate::new(&paths).held_left(at(182).1), Some(role::CONNECT_HOLD));

    // A quick check that returns early holds nothing.
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let watch = watch_at_b0();
    let handled = AtomicU64::new(watch.pause_seq());
    let quick = || at(2);
    role::check_step(&paths, &watch, &handled, &quick, || role::Outcome::Current("abc".to_owned()));
    assert_eq!(gate::Gate::new(&paths).held_left(at(2).1), None);
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
    assert!(role::flip_look(&paths, &watch, &handled, None, &mut last, 0, at(182)));
    let gate = gate::Gate::new(&paths);
    assert_eq!(gate.held_left(at(182).1), Some(role::CONNECT_HOLD));
    // The flip runs inside the gate, which refuses it while the hold is on.
    assert!(gate.run(at(182).1, gate::Honor::All, |_| ()).is_err(), "the flip ran under the hold");
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
        None,
        &mut last,
        3_600 * SECOND_NS,
        at(5),
    ));
    assert_eq!(gate::Gate::new(&paths).held_left(at(5).1), Some(role::CONNECT_HOLD));
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
    assert_eq!(gate::Gate::new(&paths).held_left(at(255).1), Some(role::CONNECT_HOLD));
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
    assert!(!role::flip_look(&paths, &watch, &handled, None, &mut last, offset + SECOND_NS, at(6)));
    // Restored after an hour stopped: realtime moved against the boot clock.
    assert!(role::flip_look(
        &paths,
        &watch,
        &handled,
        None,
        &mut last,
        offset + 3600 * SECOND_NS,
        at(7)
    ));
    assert_eq!(gate::Gate::new(&paths).held_left(at(7).1), Some(role::CONNECT_HOLD));
}

/// Review F2 of #38326: the health timeout's rollback waits while carrier
/// sessions are attached, looking again every BUSY_RETRY, and stops waiting when
/// the role stops.
#[cfg(target_os = "linux")]
#[test]
fn the_health_timeout_rollback_waits_for_carrier_sessions() {
    let mut looks =
        vec![None, Some("1 carrier session(s) attached".to_owned()), Some("1".to_owned())];
    let mut carrier = || looks.pop().flatten();
    // `wait` with no message times out after BUSY_RETRY: too slow for a test,
    // so a Check stands in for each look.
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
    use std::time::{Duration, Instant};

    use carrier::{CARRIER_MAX_HOLD, CarrierHold};

    let dir = tempfile::tempdir().unwrap();
    let held = gate::Gate::new(&Paths::new(dir.path()));
    let start = || {
        held.hold(T0_MS, role::CONNECT_HOLD, gate::HoldKind::Connect);
    };
    let t0 = Instant::now();
    let mut hold = CarrierHold::default();
    for minute in 0..=CARRIER_MAX_HOLD.as_secs() / 60 {
        let at = t0 + Duration::from_secs(minute * 60);
        let look = hold.look(at, Err("its admin channel answered exit status: 1".to_owned()));
        role::act_on_look(look, start);
    }
    assert_eq!(held.held_left(T0_MS), None, "failed reads start no connect hold");

    let at = t0 + CARRIER_MAX_HOLD + Duration::from_secs(120);
    let look = hold.look(at, Ok(vec!["mac/s1#1".to_owned()]));
    role::act_on_look(look, start);
    let left = held.held_left(T0_MS).expect("the first readable session starts the connect hold");
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
        service.hold(T0_MS, gate::CONNECT_HOLD, gate::HoldKind::Connect),
        "a bind with no restart pending goes"
    );
    let mut ran = false;
    let held = cli.run(T0_MS + 60_000, gate::Honor::All, |_| ran = true);
    assert!(held.is_err_and(|left| left == gate::CONNECT_HOLD - Duration::from_secs(60)));
    assert!(!ran, "the CLI flipped during the service's connect hold");
    assert_eq!(cli.held_left(T0_MS + 60_000), Some(gate::CONNECT_HOLD - Duration::from_secs(60)));

    let after = T0_MS + gate::CONNECT_HOLD.as_millis() as u64;
    assert_eq!(cli.held_left(after), None);
    assert!(cli.run(after, gate::Honor::All, |_| ran = true).is_ok());
    assert!(ran, "past the hold the CLI flips");
}

/// (b) A restart the CLI queued is pending for the service: a bind there
/// refuses until the restarted service clears the mark at its start.
#[test]
fn a_cli_queued_restart_refuses_binds_until_the_service_restarts() {
    let (_dir, service, cli) = gate_handles();
    assert!(cli.run(T0_MS, gate::Honor::All, |inside| inside.restart_queued(T0_MS)).is_ok());
    assert!(
        !service.hold(T0_MS + 1_000, gate::CONNECT_HOLD, gate::HoldKind::Connect),
        "a bind went out with a restart pending"
    );
    assert!(
        !service.hold(T0_MS + 30_000, gate::CONNECT_HOLD, gate::HoldKind::Connect),
        "still pending 30 s on"
    );
    // The restarted cmux-host clears the mark before it accepts binds.
    service.service_started();
    assert!(
        service.hold(T0_MS + 31_000, gate::CONNECT_HOLD, gate::HoldKind::Connect),
        "the restarted service binds"
    );
}

/// (c) The pending mark lasts at most RESTART_PENDING_FOR from when the
/// restart was queued (`restart_queued`'s `now_ms`, not the run's start): a
/// restart that never came can't block binds for ever.
#[test]
fn a_pending_restart_mark_expires_after_its_bound() {
    let (_dir, service, cli) = gate_handles();
    assert!(
        cli.run(T0_MS, gate::Honor::Nothing, |inside| inside.restart_queued(T0_MS)).is_ok(),
        "a rollback runs under no hold too"
    );
    let bound = gate::RESTART_PENDING_FOR.as_millis() as u64;
    assert!(!service.hold(T0_MS + bound - 1, gate::CONNECT_HOLD, gate::HoldKind::Connect));
    assert!(
        service.hold(T0_MS + bound, gate::CONNECT_HOLD, gate::HoldKind::Connect),
        "the mark outlived its bound"
    );
}

/// A bind in the service that lands while the CLI's gate runs waits on the
/// flock until the CLI queued its restart, then refuses; a rollback (which
/// the hold doesn't stop) and a `--skip-resume-hold` check are serialized
/// the same way.
#[test]
fn a_bind_waits_for_another_process_gate_and_sees_its_restart() {
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    for honor in [gate::Honor::All, gate::Honor::AllButResume, gate::Honor::Nothing] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_owned();
        let (in_window, window) = mpsc::channel::<()>();
        let cli = std::thread::spawn(move || {
            gate::Gate::new(&Paths::new(&root)).run(T0_MS, honor, |inside| {
                in_window.send(()).unwrap();
                std::thread::sleep(Duration::from_millis(200));
                inside.restart_queued(T0_MS);
                Instant::now()
            })
        });
        window.recv().unwrap();
        let may_bind = gate::Gate::new(&Paths::new(dir.path())).hold(
            T0_MS + 100,
            gate::CONNECT_HOLD,
            gate::HoldKind::Connect,
        );
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

/// The flip a held check must never make.
#[cfg(target_os = "linux")]
fn no_flip(_: &gate::Inside) -> Result<(), ()> {
    panic!("flipped while a hold the check honors was on")
}

/// The Scaler's spare refresh (`cmux host update check --skip-resume-hold`)
/// after the resume it made: the resume's hold alone no longer stops the
/// flip, and the answer names the hold it went past.
#[cfg(target_os = "linux")]
#[test]
fn a_resume_hold_alone_flips_with_the_flag() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let gate = gate::Gate::new(&paths);
    gate.hold(T0_MS, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let mut flipped = false;
    let (gated, skipped) = role::flip_in_gate(
        &paths,
        || T0_MS + 1_000,
        gate::Honor::AllButResume,
        || Ok(Vec::new()),
        || false,
        |_| {
            flipped = true;
            Ok::<(), ()>(())
        },
    );
    assert!(matches!(gated, role::Gated::Flipped), "{gated:?}");
    assert!(flipped);
    assert_eq!(skipped, Some(gate::HoldKind::Resume));

    // With no hold on, nothing was skipped.
    let past = T0_MS + gate::CONNECT_HOLD.as_millis() as u64;
    let ran = gate.run(past, gate::Honor::AllButResume, |inside| inside.skipped());
    assert_eq!(ran, Ok(None));

    let updating = role::Outcome::Updating(COMMIT.to_owned()).json(skipped);
    assert_eq!(updating["state"], "updating");
    assert_eq!(updating["skipped_hold"], "resume");
    let busy = role::Outcome::Busy(vec!["1 carrier session(s) attached".to_owned()]).json(skipped);
    assert_eq!(
        (busy["state"].as_str(), busy["skipped_hold"].as_str()),
        (Some("busy"), Some("resume"))
    );
    let plain = role::Outcome::Updating(COMMIT.to_owned()).json(None);
    assert_eq!(plain, json!({"state": "updating", "detail": format!("updating to {COMMIT}")}));
}

/// Without the flag (a plain `check`, the service's own loop) a resume hold
/// holds the flip exactly as before. The service's `Resumed` takes a resume
/// hold, its `Bound` a connect hold.
#[cfg(target_os = "linux")]
#[test]
fn a_resume_hold_without_the_flag_is_busy() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    gate::Gate::new(&paths).hold(T0_MS, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let (gated, skipped) = role::flip_in_gate(
        &paths,
        || T0_MS + 1_000,
        gate::Honor::All,
        || Ok(Vec::new()),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Held(_)), "{gated:?}");
    assert_eq!(skipped, None);

    let image_dir = tempfile::tempdir().unwrap();
    let paths = image(image_dir.path());
    let mut updater = role::UpdaterRole::new(paths.clone());
    let now = role::wall_ms();
    cmux_server_core::role::Role::on_event(
        &mut updater,
        &cmux_server_core::role::HostEvent::Resumed,
    )
    .unwrap();
    let gate = gate::Gate::new(&paths);
    assert!(gate.run(now, gate::Honor::All, |_| ()).is_err(), "a resume holds a plain check");
    assert_eq!(
        gate.run(now, gate::Honor::AllButResume, |inside| inside.skipped()),
        Ok(Some(gate::HoldKind::Resume)),
        "a resume's hold is a resume hold"
    );
}

/// With the flag, every hold but a resume hold still holds the flip: a bind
/// (`hold_then_bind`, a `Bound`) and a new carrier session's connect hold,
/// also when it extends an earlier resume hold.
#[cfg(target_os = "linux")]
#[test]
fn a_bind_or_carrier_connect_hold_with_the_flag_is_busy() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    gate::Gate::new(&paths).hold(T0_MS, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    assert!(gate::hold_connects(&paths, T0_MS + 60_000, gate::HoldKind::Connect), "the bind goes");
    let end = T0_MS + 60_000 + gate::CONNECT_HOLD.as_millis() as u64;
    let (gated, skipped) = role::flip_in_gate(
        &paths,
        || end - 1_000,
        gate::Honor::AllButResume,
        || Ok(Vec::new()),
        || false,
        no_flip,
    );
    assert!(
        matches!(gated, role::Gated::Held(left) if left == std::time::Duration::from_secs(1)),
        "{gated:?}"
    );
    assert_eq!(skipped, None);

    // A new carrier session (`carrier_busy_from`, the check's look before it stages).
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let now = role::wall_ms();
    gate::Gate::new(&paths).hold(now, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let id = format!("claimer/{}#1", T0_MS + 7);
    assert!(role::carrier_busy_from(&paths, Ok(vec![id])).is_some());
    let (gated, _) = role::flip_in_gate(
        &paths,
        || now + 1_000,
        gate::Honor::AllButResume,
        || Ok(Vec::new()),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Held(_)), "{gated:?}");

    // A connect hold first, a later resume hold past it: once the connect
    // hold ends, the rest is the resume's and the flag skips it.
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let gate = gate::Gate::new(&paths);
    gate.hold(T0_MS, gate::CONNECT_HOLD, gate::HoldKind::Connect);
    gate.hold(T0_MS + 120_000, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let connect_end = T0_MS + gate::CONNECT_HOLD.as_millis() as u64;
    assert!(gate.run(connect_end - 1, gate::Honor::AllButResume, |_| ()).is_err());
    assert_eq!(
        gate.run(connect_end, gate::Honor::AllButResume, |inside| inside.skipped()),
        Ok(Some(gate::HoldKind::Resume))
    );
    assert!(gate.run(connect_end, gate::Honor::All, |_| ()).is_err());
}

/// With the flag, carrier sessions attached at the check (read live inside
/// the gate) still hold the update.
#[cfg(target_os = "linux")]
#[test]
fn an_attached_carrier_session_with_the_flag_is_busy() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let now = role::wall_ms();
    gate::Gate::new(&paths).hold(now, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let id = format!("mac/{}#1", T0_MS + 11);
    // Seen by an earlier look (its connect hold went to another root), so
    // this look finds it attached, not new.
    let other = tempfile::tempdir().unwrap();
    role::carrier_busy_from(&Paths::new(other.path()), Ok(vec![id.clone()]));
    let (gated, skipped) = role::flip_in_gate(
        &paths,
        || now + 1_000,
        gate::Honor::AllButResume,
        || Ok(vec![id]),
        || false,
        no_flip,
    );
    match gated {
        role::Gated::Busy(why) => assert!(why.contains("attached"), "{why}"),
        other => panic!("not busy: {other:?}"),
    }
    assert_eq!(skipped, Some(gate::HoldKind::Resume), "the answer names the hold it went past");
}

/// The updater owner's ask: a carrier session that attaches after the gate
/// read the hold, before the flip, is still seen. The look runs under the
/// gate's flock (no other process can take a hold meanwhile), and a new
/// session takes its connect hold there, so the next check is held too.
#[cfg(target_os = "linux")]
#[test]
fn a_carrier_session_attaching_before_the_flip_is_seen_inside_the_gate() {
    use std::os::unix::io::AsRawFd as _;

    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let now = role::wall_ms();
    gate::Gate::new(&paths).hold(now, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let lock_path = paths.at(gate::GATE_LOCK);
    let id = format!("claimer/{}#1", T0_MS + 13);
    let (gated, _) = role::flip_in_gate(
        &paths,
        || now + 1_000,
        gate::Honor::AllButResume,
        || {
            let other = fs::OpenOptions::new().write(true).open(&lock_path).unwrap();
            // SAFETY: flock on a descriptor this closure owns.
            let free = unsafe { libc::flock(other.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            assert_eq!(free, -1, "the carrier look ran outside the gate's flock");
            Ok(vec![id])
        },
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Busy(_)), "{gated:?}");
    assert!(
        gate::Gate::new(&paths).run(now + 2_000, gate::Honor::AllButResume, |_| ()).is_err(),
        "the new session's connect hold does not hold the next check"
    );
}

/// With the flag, [`OFF_FILE`] still stops the flip, read inside the gate.
#[cfg(target_os = "linux")]
#[test]
fn the_off_file_with_the_flag_stops_the_flip() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    gate::Gate::new(&paths).hold(T0_MS, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    let off = paths.at(OFF_FILE);
    fs::create_dir_all(off.parent().unwrap()).unwrap();
    fs::write(&off, "").unwrap();
    let (gated, _) = role::flip_in_gate(
        &paths,
        || T0_MS + 1_000,
        gate::Honor::AllButResume,
        || Ok(Vec::new()),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Off(_)), "{gated:?}");
}

/// A pause or restore during the carrier look (its query can take 20 s)
/// stops the flip, with the flag too: the look after the query starts a
/// resume hold under the gate's flock, so the next plain check honors it. The
/// hold starts when the stop is seen, not at the run's start: a pause longer
/// than the hold during the query still leaves a whole hold.
#[cfg(target_os = "linux")]
#[test]
fn a_stop_during_the_carrier_look_stops_the_flip() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let seen = T0_MS + 2 * gate::CONNECT_HOLD.as_millis() as u64;
    let reads = std::cell::Cell::new(0);
    let clock = || {
        reads.set(reads.get() + 1);
        if reads.get() == 1 { T0_MS } else { seen }
    };
    let mut flipped = false;
    let (gated, _) = role::flip_in_gate(
        &paths,
        clock,
        gate::Honor::AllButResume,
        || Ok(Vec::new()),
        || true,
        |_| {
            flipped = true;
            Ok::<(), ()>(())
        },
    );
    assert!(matches!(gated, role::Gated::Held(_)), "{gated:?}");
    assert!(!flipped, "flipped across a stop");
    let (gated, _) = role::flip_in_gate(
        &paths,
        || seen + 1_000,
        gate::Honor::All,
        || Ok(Vec::new()),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Held(_)), "the stop's hold did not last: {gated:?}");
}

/// A carrier session the flip's last look finds takes its connect hold from
/// when the look answered, not from the run's start.
#[cfg(target_os = "linux")]
#[test]
fn a_session_found_by_a_slow_carrier_look_holds_from_the_answer() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let seen = T0_MS + 2 * gate::CONNECT_HOLD.as_millis() as u64;
    let reads = std::cell::Cell::new(0);
    let clock = || {
        reads.set(reads.get() + 1);
        if reads.get() == 1 { T0_MS } else { seen }
    };
    let (gated, _) = role::flip_in_gate(
        &paths,
        clock,
        gate::Honor::All,
        || Ok(vec![format!("claimer/{}#1", T0_MS + 17)]),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Busy(_)), "{gated:?}");
    assert!(
        gate::Gate::new(&paths).run(seen + 1_000, gate::Honor::AllButResume, |_| ()).is_err(),
        "the connect hold started before the look answered"
    );
}

/// A gate file from before the hold kinds (no `connect_until_ms`) reads as
/// connect holds only: the flag skips none of it, also once a resume hold
/// extends it.
#[test]
fn an_old_gate_file_is_a_full_hold() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let file = paths.at(gate::GATE_FILE);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let until = T0_MS + 60_000;
    fs::write(&file, json!({"held_until_ms": until}).to_string()).unwrap();
    let gate = gate::Gate::new(&paths);
    assert!(gate.run(T0_MS, gate::Honor::AllButResume, |_| ()).is_err());
    gate.hold(T0_MS + 30_000, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    assert!(gate.run(until - 1, gate::Honor::AllButResume, |_| ()).is_err(), "the old hold shrank");
    assert_eq!(
        gate.run(until, gate::Honor::AllButResume, |inside| inside.skipped()),
        Ok(Some(gate::HoldKind::Resume))
    );
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
    assert_eq!(gate::Gate::new(&paths).held_left(at(181).1), Some(role::CONNECT_HOLD));
}

/// A spare paused 40 minutes in its pool (its watch's last look at `B0`),
/// then resumed by the Scaler at 2400 s, before the service's watch woke:
/// the record the operator's check reads, and the service's `Resumed` hold
/// (the resume hold `--skip-resume-hold` skips).
#[cfg(target_os = "linux")]
fn resumed_spare() -> (tempfile::TempDir, Paths, crate::agent::PauseWatch) {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let file = paths.at(PAUSE_FILE);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let service = crate::agent::PauseWatch::new();
    service.persist_to(file);
    service.looked(B0, false);
    gate::Gate::new(&paths).hold(at(2400).1, gate::CONNECT_HOLD, gate::HoldKind::Resume);
    (dir, paths, service)
}

/// The refresh's flip step at `now`, its stop look inside the gate after
/// `carrier` with `offset_now`.
#[cfg(target_os = "linux")]
fn refresh_flip(
    paths: &Paths,
    stops: &role::Stops<'_, '_>,
    carrier: impl FnOnce() -> Result<Vec<String>, role::Unread>,
    offset_now: i128,
    now: (i128, u64),
) -> role::Gated<()> {
    let (gated, skipped) = role::flip_in_gate(
        paths,
        || now.1,
        gate::Honor::AllButResume,
        carrier,
        || stops.in_gate(offset_now, now),
        |_| Ok::<(), ()>(()),
    );
    assert_eq!(skipped, Some(gate::HoldKind::Resume), "the flag went past the resume's hold");
    gated
}

/// Review F1 of #39032 at 51f0d38f: the Scaler's refresh
/// (`--skip-resume-hold`) runs right after the resume it made, so the pause
/// watch can still be waking from that resume when the check starts, and
/// count it during the check. That is the wake whose hold the flag skips:
/// neither stops the flip, before the gate or inside it. A plain check at the
/// same point is held by it.
#[cfg(target_os = "linux")]
#[test]
fn the_refresh_own_resume_does_not_stop_its_flip() {
    // Still waking through the whole check, or counted during it.
    for counted_during in [false, true] {
        let (_dir, paths, service) = resumed_spare();
        let check = role::OtherLook::start(&paths, 0);
        let looks = check.looks();
        let stops = role::Stops::new(&looks, gate::Honor::AllButResume, at(2400).0);
        assert!(!stops.before_gate(&paths, 0, at(2401)), "counted_during {counted_during}");
        if counted_during {
            service.looked(at(2402).0, true);
        }
        assert!(!stops.recount(&paths, at(2403)), "counted_during {counted_during}");
        let gated = refresh_flip(&paths, &stops, || Ok(Vec::new()), 0, at(2404));
        assert!(
            matches!(gated, role::Gated::Flipped),
            "counted_during {counted_during}: {gated:?}"
        );

        let plain = role::OtherLook::start(&paths, 0);
        let looks = plain.looks();
        let stops = role::Stops::new(&looks, gate::Honor::All, at(2405).0);
        assert_eq!(
            stops.before_gate(&paths, 0, at(2405)),
            !counted_during,
            "a plain check is held by a wake it found, and not by one counted before it started"
        );
    }
}

/// Review F1 of #39032 at 51f0d38f, the other half: a new pause or restore
/// during the refresh still stops its flip. One found before the gate starts
/// a resume hold the flag would skip, so the check keeps the stop and the
/// gate holds on it; one during the carrier query is seen inside the gate.
#[cfg(target_os = "linux")]
#[test]
fn a_new_stop_during_the_refresh_stops_its_flip() {
    let refresh = |paths: &Paths| {
        let check = role::OtherLook::start(paths, 0);
        assert!(check.looks().start.waking(at(2400).0));
        check
    };

    // A new 3-minute pause after the watch counted the resume, found before the gate.
    let (_dir, paths, service) = resumed_spare();
    let check = refresh(&paths);
    let looks = check.looks();
    let stops = role::Stops::new(&looks, gate::Honor::AllButResume, at(2400).0);
    service.looked(at(2402).0, true);
    service.looked(at(2582).0, true);
    assert!(stops.before_gate(&paths, 0, at(2583)));
    let gated = refresh_flip(&paths, &stops, || Ok(Vec::new()), 0, at(2584));
    assert!(matches!(gated, role::Gated::Held(_)), "a pause before the gate: {gated:?}");

    // The watch counted the resume, then is waking again: stopped once more.
    let (_dir, paths, service) = resumed_spare();
    let check = refresh(&paths);
    let looks = check.looks();
    let stops = role::Stops::new(&looks, gate::Honor::AllButResume, at(2400).0);
    service.looked(at(2402).0, true);
    assert!(!stops.recount(&paths, at(2403)));
    let gated = refresh_flip(&paths, &stops, || Ok(Vec::new()), 0, at(2402 + 60));
    assert!(matches!(gated, role::Gated::Held(_)), "waking from a new pause: {gated:?}");

    // Review F1 on ffbe82dc (#39366): the watch's first look since the check
    // started counts nothing, then a real pause is counted. It is one count
    // past the start and the watch is awake, but the pause came after a later
    // look than the start's, so it is a new stop, not the refresh's own wake.
    let (_dir, paths, service) = resumed_spare();
    let check = refresh(&paths);
    let looks = check.looks();
    let stops = role::Stops::new(&looks, gate::Honor::AllButResume, at(2400).0);
    service.looked(at(2402).0, false);
    service.looked(at(2582).0, true);
    assert!(stops.recount(&paths, at(2583)), "a pause after a look since the start");
    let gated = refresh_flip(&paths, &stops, || Ok(Vec::new()), 0, at(2584));
    assert!(matches!(gated, role::Gated::Held(_)), "a pause after a later look: {gated:?}");

    // A pause during the carrier query, inside the gate.
    let (_dir, paths, service) = resumed_spare();
    let check = refresh(&paths);
    let looks = check.looks();
    let stops = role::Stops::new(&looks, gate::Honor::AllButResume, at(2400).0);
    assert!(!stops.recount(&paths, at(2401)));
    let carrier = || {
        service.looked(at(2402).0, true);
        service.looked(at(2582).0, true);
        Ok(Vec::new())
    };
    let gated = refresh_flip(&paths, &stops, carrier, 0, at(2583));
    assert!(matches!(gated, role::Gated::Held(_)), "a pause during the query: {gated:?}");

    // A restore found before the gate, and one during the carrier query.
    for before in [true, false] {
        let (_dir, paths, _service) = resumed_spare();
        let check = refresh(&paths);
        let looks = check.looks();
        let stops = role::Stops::new(&looks, gate::Honor::AllButResume, at(2400).0);
        let jump = 3_600 * SECOND_NS;
        if before {
            assert!(stops.before_gate(&paths, jump, at(2401)));
        }
        let gated = refresh_flip(&paths, &stops, || Ok(Vec::new()), jump, at(2402));
        assert!(matches!(gated, role::Gated::Held(_)), "a restore, before {before}: {gated:?}");
    }
}

/// The pause record names the look each counted pause came after, written
/// and read back across processes; a record without the field (an older
/// build's) names none, so its counts are never a refresh's own wake.
#[test]
fn the_pause_record_names_the_look_a_pause_came_after() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pauses.json");
    let watch = crate::agent::PauseWatch::new();
    watch.persist_to(path.clone());
    watch.looked(1_000, false);
    watch.looked(9_000, true);
    let read = crate::agent::PauseWatch::load(&path).seen();
    assert_eq!((read.pauses, read.last_look_ns, read.pause_from_ns), (1, 9_000, 1_000));
    watch.found();
    let read = crate::agent::PauseWatch::load(&path).seen();
    assert_eq!(
        read.pause_from_ns,
        i128::from(crate::agent::PAUSE_FROM_NONE),
        "a clock set names no look"
    );

    fs::write(&path, r#"{"last_look_ns": 9000, "pauses": 1}"#).unwrap();
    let old = crate::agent::PauseWatch::load(&path).seen();
    assert_eq!(old.pause_from_ns, i128::from(crate::agent::PAUSE_FROM_NONE));
}

/// The flip's carrier read inside the gate holds the gate's flock, so it is
/// bounded tighter ([`role::CARRIER_READ_IN_GATE`], 3 to 5 s) than the read
/// outside it (20 s). A read past the bound (`timeout`'s 124) is busy: no
/// flip, and no carrier look, so it never reads as no sessions, also past
/// the carrier hold's bound.
#[cfg(target_os = "linux")]
#[test]
fn a_carrier_read_that_times_out_inside_the_gate_is_busy() {
    use std::os::unix::process::ExitStatusExt as _;
    use std::process::ExitStatus;

    let limit = role::CARRIER_READ_IN_GATE;
    assert!((3..=5).contains(&limit.as_secs()), "{limit:?}");
    let timed_out =
        std::process::Command::new("timeout").args(["1", "sleep", "5"]).status().unwrap();
    assert_eq!(role::Unread::of(timed_out, limit), role::Unread::TimedOut(limit));
    assert!(matches!(
        role::Unread::of(ExitStatus::from_raw(1 << 8), limit),
        role::Unread::Failed(_)
    ));

    // The hard deadline: a child that ignores `timeout`'s SIGTERM, and a
    // grandchild that keeps stdout open, are killed with their group at
    // limit + READ_KILL_AFTER, not waited for (review F1 on #39366).
    for script in ["trap '' TERM; sleep 30", "sleep 30 & wait"] {
        let mut cmd = std::process::Command::new("timeout");
        cmd.args(["1", "sh", "-c", script]);
        let started = std::time::Instant::now();
        let read = role::output_within(cmd, std::time::Duration::from_secs(1));
        let took = started.elapsed();
        assert_eq!(
            read,
            Err(role::Unread::TimedOut(std::time::Duration::from_secs(1))),
            "{script}"
        );
        assert!(
            took < std::time::Duration::from_secs(1)
                + role::READ_KILL_AFTER
                + std::time::Duration::from_secs(2),
            "{script}: {took:?}"
        );
    }
    let mut cmd = std::process::Command::new("timeout");
    cmd.args(["2", "echo", "ok"]);
    assert_eq!(role::output_within(cmd, std::time::Duration::from_secs(2)), Ok(b"ok\n".to_vec()));

    for honor in [gate::Honor::All, gate::Honor::AllButResume] {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::new(dir.path());
        let (gated, _) = role::flip_in_gate(
            &paths,
            || T0_MS,
            honor,
            || Err(role::Unread::TimedOut(limit)),
            || false,
            no_flip,
        );
        assert!(matches!(gated, role::Gated::Busy(_)), "{honor:?}: {gated:?}");
        assert_eq!(gate::Gate::new(&paths).held_left(T0_MS), None, "a timeout is no new session");
    }
}

#[test]
fn adopt_relinks_a_work_link_the_app_replaced_and_keeps_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let paths = image(dir.path());
    // Already the store link: nothing changes.
    assert_eq!(relink_work_link(&paths).unwrap(), Relinked::Unchanged);
    let link = paths.at(WORK_CMUX_TUI_LINK);
    // The Mac app's in-place update left a file of its own (cmuxterm-hq#7086).
    fs::remove_file(&link).unwrap();
    fs::write(&link, b"the app's build").unwrap();
    assert!(off_reason(&paths).is_some());
    assert_eq!(relink_work_link(&paths).unwrap(), Relinked::KeptFile);
    assert_eq!(fs::read_link(&link).unwrap(), Path::new(CURRENT_CMUX_TUI));
    assert_eq!(fs::read(paths.at(WORK_CMUX_TUI_KEPT)).unwrap(), b"the app's build");
    assert!(off_reason(&paths).is_none());
    // A link elsewhere is pointed back too.
    fs::remove_file(&link).unwrap();
    std::os::unix::fs::symlink("/tmp/elsewhere", &link).unwrap();
    assert_eq!(relink_work_link(&paths).unwrap(), Relinked::Linked);
    assert_eq!(fs::read_link(&link).unwrap(), Path::new(CURRENT_CMUX_TUI));
    // No link at all: made.
    fs::remove_file(&link).unwrap();
    assert_eq!(relink_work_link(&paths).unwrap(), Relinked::Linked);
    assert!(off_reason(&paths).is_none());
    // Restoring after a run that kept no file leaves an earlier `.pre-adopt` alone.
    restore_work_link(&paths, Relinked::Linked);
    assert_eq!(fs::read_link(&link).unwrap(), Path::new(CURRENT_CMUX_TUI));
    assert!(paths.at(WORK_CMUX_TUI_KEPT).exists());
    // After a run that kept one, it goes back.
    fs::remove_file(&link).unwrap();
    fs::write(&link, b"a newer app build").unwrap();
    assert_eq!(relink_work_link(&paths).unwrap(), Relinked::KeptFile);
    restore_work_link(&paths, Relinked::KeptFile);
    assert_eq!(fs::read(&link).unwrap(), b"a newer app build");
}

/// Goal cloud-fix-to-machine (channel published -> first seen on a production
/// machine): the worker looks at the channel again within 20 s of any check,
/// idle or busy, so a channel move reaches an idle machine within about 20 s
/// and a busy one within about 20 s of its turn ending, not a minute. Never
/// sooner than 10 s (a tight loop), and the jitter keeps machines out of step.
#[cfg(target_os = "linux")]
#[test]
fn the_updater_looks_again_within_20_s_idle_or_busy() {
    use std::collections::BTreeSet;
    use std::time::Duration;
    let outcomes = [
        role::Outcome::Busy(vec!["1 carrier session(s) attached".to_owned()]),
        role::Outcome::Current("c".to_owned()),
        role::Outcome::Failed("reading the channel: timeout".to_owned()),
        role::Outcome::Off("off".to_owned()),
    ];
    for outcome in &outcomes {
        for draw in [0, 1, 1_875, 3_750, 3_751, 123_456_789, u64::MAX] {
            let wait = role::next_look(outcome, draw);
            assert!(
                (Duration::from_secs(10)..=Duration::from_secs(20)).contains(&wait),
                "{outcome:?} with draw {draw}: next look in {wait:?}"
            );
        }
    }
    let spread: BTreeSet<_> = (0..64u64).map(|i| role::next_look(&outcomes[1], i * 977)).collect();
    assert!(spread.len() > 8, "the jitter spreads the looks: {spread:?}");
}

#[test]
fn parse_response_reads_status_validators_and_body() {
    let raw = b"HTTP/2 200 \r\netag: \"abc\"\r\nLast-Modified: Fri, 13 Nov 2026 15:03:58 GMT\r\n\r\n{\"x\":1}";
    assert_eq!(
        channel::parse_response(raw).unwrap(),
        channel::Answer::Full {
            body: b"{\"x\":1}".to_vec(),
            etag: Some("\"abc\"".to_owned()),
            last_modified: Some("Fri, 13 Nov 2026 15:03:58 GMT".to_owned()),
        }
    );
    assert_eq!(
        channel::parse_response(b"HTTP/1.1 304 Not Modified\r\nETag: \"abc\"\r\n\r\n").unwrap(),
        channel::Answer::NotModified
    );
    // An earlier block (a 1xx, a retried 503) is skipped; the last one answers.
    let retried =
        b"HTTP/1.1 503 Busy\r\n\r\nHTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 304 Not Modified\r\n\r\n";
    assert_eq!(channel::parse_response(retried).unwrap(), channel::Answer::NotModified);
    // No validators: nothing to send back. A value with a control byte is not one.
    let bare = b"HTTP/1.1 200 OK\r\nETag: \"a\x01b\"\r\n\r\n{}";
    assert_eq!(
        channel::parse_response(bare).unwrap(),
        channel::Answer::Full { body: b"{}".to_vec(), etag: None, last_modified: None }
    );
    assert!(channel::parse_response(b"HTTP/1.1 302 Found\r\nLocation: x\r\n\r\n").is_err());
    assert!(channel::parse_response(b"{\"not\": \"a response\"}").is_err());
}

fn full(body: Vec<u8>, etag: &str) -> channel::Answer {
    channel::Answer::Full { body, etag: Some(etag.to_owned()), last_modified: None }
}

#[test]
fn a_304_is_trusted_only_with_a_kept_file_that_verifies_now() {
    let good = envelope(&payload_json(OLD_TUI, OLD_HOOK), "test");
    // No file kept: a 304 is refused, and nothing is sent conditionally.
    let mut cache = channel::Cache::new();
    assert_eq!(cache.validators(), (None, None));
    assert!(cache.take(channel::Answer::NotModified, &keys(), 5_000).is_err());
    // A verified 200 is kept with its validator; a 304 then answers its payload.
    assert_eq!(cache.take(full(good.clone(), "\"v1\""), &keys(), 5_000).unwrap().commit, COMMIT);
    assert_eq!(cache.validators(), (Some("\"v1\"".to_owned()), None));
    assert_eq!(cache.take(channel::Answer::NotModified, &keys(), 5_000).unwrap().commit, COMMIT);
    // The kept file's expiry is checked against now on every 304, and an
    // expired one is dropped, so the next read is unconditional.
    assert!(cache.take(channel::Answer::NotModified, &keys(), 10_000).is_err());
    assert_eq!(cache.validators(), (None, None));
    // A 200 that does not verify is not kept and drops the kept file.
    cache.take(full(good.clone(), "\"v1\""), &keys(), 5_000).unwrap();
    assert!(
        cache
            .take(
                full(envelope(&payload_json(OLD_TUI, OLD_HOOK), "other"), "\"v2\""),
                &keys(),
                5_000
            )
            .is_err()
    );
    assert_eq!(cache.validators(), (None, None));
    assert!(cache.take(channel::Answer::NotModified, &keys(), 5_000).is_err());
    // A 200 with no validator verifies but is not kept: nothing to send back.
    let bare = channel::Answer::Full { body: good, etag: None, last_modified: None };
    cache.take(bare, &keys(), 5_000).unwrap();
    assert_eq!(cache.validators(), (None, None));
}

#[cfg(target_os = "linux")]
/// A local origin for the channel file over plain HTTP: answers a matching
/// If-None-Match with 304 and no body, counting whole files and 304s.
struct Origin {
    url: String,
    file: std::sync::Arc<std::sync::Mutex<(String, Vec<u8>)>>,
    full: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    not_modified: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    body_bytes: std::sync::Arc<std::sync::atomic::AtomicUsize>,
}

#[cfg(target_os = "linux")]
impl Origin {
    fn serve(etag: &str, body: Vec<u8>, always_304: bool) -> Origin {
        use std::io::{Read as _, Write as _};
        use std::sync::atomic::Ordering::SeqCst;
        use std::sync::{Arc, Mutex};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://{}/cmux-tui/channels/cloud-machine.json",
            listener.local_addr().unwrap()
        );
        let origin = Origin {
            url,
            file: Arc::new(Mutex::new((etag.to_owned(), body))),
            full: Arc::default(),
            not_modified: Arc::default(),
            body_bytes: Arc::default(),
        };
        let (file, full, not_modified, body_bytes) = (
            origin.file.clone(),
            origin.full.clone(),
            origin.not_modified.clone(),
            origin.body_bytes.clone(),
        );
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut request = Vec::new();
                let mut buf = [0u8; 1024];
                while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => request.extend_from_slice(&buf[..n]),
                    }
                }
                let request = String::from_utf8_lossy(&request).into_owned();
                let sent = request.lines().find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.eq_ignore_ascii_case("if-none-match").then(|| value.trim().to_owned())
                });
                let (etag, body) = file.lock().unwrap().clone();
                let response = if always_304 || sent.as_deref() == Some(etag.as_str()) {
                    not_modified.fetch_add(1, SeqCst);
                    format!(
                        "HTTP/1.1 304 Not Modified\r\nETag: {etag}\r\nConnection: close\r\n\r\n"
                    )
                    .into_bytes()
                } else {
                    full.fetch_add(1, SeqCst);
                    body_bytes.fetch_add(body.len(), SeqCst);
                    let mut response = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
                         ETag: {etag}\r\nLast-Modified: Fri, 13 Nov 2026 15:03:58 GMT\r\n\
                         Connection: close\r\n\r\n",
                        body.len()
                    )
                    .into_bytes();
                    response.extend_from_slice(&body);
                    response
                };
                let _ = stream.write_all(&response);
            }
        });
        origin
    }

    fn counts(&self) -> (usize, usize) {
        use std::sync::atomic::Ordering::SeqCst;
        (self.full.load(SeqCst), self.not_modified.load(SeqCst))
    }
}

#[cfg(target_os = "linux")]
/// The 15 s poll's origin load: N checks of an unchanged channel read the
/// whole file once, then are answered 304 with no body, and every check
/// still returns the verified payload. A changed channel is read whole again.
#[test]
fn an_unchanged_channel_is_read_whole_once_then_answered_304() {
    use std::sync::atomic::Ordering::SeqCst;
    const POLLS: usize = 20;
    let origin = Origin::serve("\"v1\"", envelope(&payload_json(OLD_TUI, OLD_HOOK), "test"), false);
    let cache = std::sync::Mutex::new(channel::Cache::new());
    for _ in 0..POLLS {
        let payload =
            role::read_channel_from(&cache, &origin.url, "=http", &keys(), 5_000).unwrap();
        assert_eq!(payload.binaries_for(TARGET).unwrap().0.sha256, OLD_TUI);
    }
    let one = origin.body_bytes.load(SeqCst);
    eprintln!(
        "{POLLS} polls of an unchanged channel: (whole files, 304s) = {:?}, body bytes {one}",
        origin.counts()
    );
    assert_eq!(
        origin.counts(),
        (1, POLLS - 1),
        "an unchanged channel was read whole more than once"
    );

    // The channel moves: the next check reads the new file whole and returns it.
    *origin.file.lock().unwrap() =
        ("\"v2\"".to_owned(), envelope(&payload_json(CLAUDE, OLD_HOOK), "test"));
    let payload = role::read_channel_from(&cache, &origin.url, "=http", &keys(), 5_000).unwrap();
    assert_eq!(payload.binaries_for(TARGET).unwrap().0.sha256, CLAUDE);
    assert_eq!(origin.counts(), (2, POLLS - 1));
    let payload = role::read_channel_from(&cache, &origin.url, "=http", &keys(), 5_000).unwrap();
    assert_eq!(payload.binaries_for(TARGET).unwrap().0.sha256, CLAUDE);
    assert_eq!(origin.counts(), (2, POLLS));
}

#[cfg(target_os = "linux")]
/// An origin that answers 304 to a check that kept no file is refused, never
/// taken as "nothing changed".
#[test]
fn a_304_to_an_unconditional_read_is_refused() {
    let origin = Origin::serve("\"v1\"", envelope(&payload_json(OLD_TUI, OLD_HOOK), "test"), true);
    let cache = std::sync::Mutex::new(channel::Cache::new());
    let err = role::read_channel_from(&cache, &origin.url, "=http", &keys(), 5_000).unwrap_err();
    assert!(err.contains("no verified file is kept"), "{err}");
}

/// `realtime - boottime` at the own-flip tests' flip.
#[cfg(target_os = "linux")]
const FLIP_OFFSET_NS: i128 = 1_794_000_000 * SECOND_NS - 86_400 * SECOND_NS;

/// An update's flip at `at_ms` (its last step inside the gate, with no
/// carrier session), the service's restart `restart_after_ms` later and the
/// restarted updater's start hold: true when the start took no hold.
#[cfg(target_os = "linux")]
fn own_flip_then_restart(paths: &Paths, at_ms: u64, restart_after_ms: u64) -> bool {
    let (gated, _) = role::flip_in_gate(
        paths,
        || at_ms,
        gate::Honor::All,
        || Ok(Vec::new()),
        || false,
        |inside| {
            inside.flip_restart_queued(at_ms, FLIP_OFFSET_NS);
            Ok::<(), ()>(())
        },
    );
    assert!(matches!(gated, role::Gated::Flipped), "{gated:?}");
    let gate = gate::Gate::new(paths);
    gate.service_started();
    role::start_hold(paths, at_ms + restart_after_ms, FLIP_OFFSET_NS + SECOND_NS / 10)
}

/// Builds merging less than 5 min apart: the machine that took the first
/// restarts into it and, with no carrier session or bind since, keeps looking
/// at the channel during what was the connect hold. A build the channel
/// shows at any time in those 5 minutes flips at the worker's next look, one
/// poll interval later, not after the hold.
#[cfg(target_os = "linux")]
#[test]
fn an_own_flip_restart_with_no_session_picks_up_a_build_within_one_poll_interval() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let restart = T0_MS + 4_000;
    assert!(own_flip_then_restart(&paths, T0_MS, 4_000), "the own flip's restart took a hold");
    let gate = gate::Gate::new(&paths);
    let poll = role::next_look(&role::Outcome::Current(COMMIT.to_owned()), u64::MAX);
    assert!(poll <= std::time::Duration::from_secs(20), "{poll:?}");
    let poll_ms = poll.as_millis() as u64;
    let hold_ms = gate::CONNECT_HOLD.as_millis() as u64;
    for published in [restart, restart + 30_000, restart + 120_000, restart + hold_ms - poll_ms] {
        // The worker's loop waits out `held_for` before it looks: nothing here.
        let look = published + poll_ms;
        assert_eq!(gate.held_left(published), None, "a hold at {} s", (published - restart) / 1000);
        let mut flipped = false;
        let (gated, _) = role::flip_in_gate(
            &paths,
            || look,
            gate::Honor::All,
            || Ok(Vec::new()),
            || false,
            |_| {
                flipped = true;
                Ok::<(), ()>(())
            },
        );
        assert!(
            matches!(gated, role::Gated::Flipped) && flipped,
            "a build published {} s after the restart did not flip at the next look: {gated:?}",
            (published - restart) / 1000
        );
    }
}

/// The own flip's restart skips the start hold only until a person's link
/// shows up: a bind (also one queued while the restart was pending) or a new
/// carrier session takes the full connect hold, and no flip goes inside it.
#[cfg(target_os = "linux")]
#[test]
fn an_own_flip_restart_with_a_connect_inside_the_hold_does_not_swap() {
    let hold_ms = gate::CONNECT_HOLD.as_millis() as u64;

    // A bind 60 s after the restart (`hold_then_bind`).
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    assert!(own_flip_then_restart(&paths, T0_MS, 4_000), "the own flip's restart took a hold");
    let gate = gate::Gate::new(&paths);
    assert!(gate.run(T0_MS + 10_000, gate::Honor::All, |_| ()).is_ok(), "no connect yet: it flips");
    let bind = T0_MS + 64_000;
    assert!(gate::hold_connects(&paths, bind, gate::HoldKind::Connect), "the bind goes");
    for look in [bind + 15_000, T0_MS + 4_000 + hold_ms, bind + hold_ms - 1] {
        let (gated, _) = role::flip_in_gate(
            &paths,
            || look,
            gate::Honor::All,
            || Ok(Vec::new()),
            || false,
            no_flip,
        );
        assert!(matches!(gated, role::Gated::Held(_)), "{gated:?}");
    }
    assert_eq!(gate.held_left(bind), Some(gate::CONNECT_HOLD), "the bind's hold is a full one");

    // A bind that came while the flip's restart was pending (it waits for the
    // restarted service, but its hold is on before the restart).
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let gate = gate::Gate::new(&paths);
    let (gated, _) = role::flip_in_gate(
        &paths,
        || T0_MS,
        gate::Honor::All,
        || Ok(Vec::new()),
        || false,
        |inside| {
            inside.flip_restart_queued(T0_MS, FLIP_OFFSET_NS);
            Ok::<(), ()>(())
        },
    );
    assert!(matches!(gated, role::Gated::Flipped), "{gated:?}");
    assert!(!gate::hold_connects(&paths, T0_MS + 1_000, gate::HoldKind::Connect));
    gate.service_started();
    role::start_hold(&paths, T0_MS + 4_000, FLIP_OFFSET_NS);
    assert!(gate.run(T0_MS + 20_000, gate::Honor::All, |_| ()).is_err(), "it flipped");

    // A carrier session that attaches after the restart: the flip's look
    // inside the gate finds it, takes the full hold and never flips; nor
    // does a look after it detached.
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let now = role::wall_ms();
    let gate = gate::Gate::new(&paths);
    assert!(own_flip_then_restart(&paths, now, 4_000), "the own flip's restart took a hold");
    let id = format!("own-flip/{}#1", T0_MS + 11);
    let (gated, _) = role::flip_in_gate(
        &paths,
        || now + 30_000,
        gate::Honor::All,
        || Ok(vec![id.clone()]),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Busy(_)), "{gated:?}");
    assert_eq!(gate.held_left(now + 30_000), Some(gate::CONNECT_HOLD), "a full hold");
    let (gated, _) = role::flip_in_gate(
        &paths,
        || now + 45_000,
        gate::Honor::All,
        || Ok(Vec::new()),
        || false,
        no_flip,
    );
    assert!(matches!(gated, role::Gated::Held(_)), "{gated:?}");
}

/// A start that is not the own flip's restart takes the 5 min hold: a cold
/// boot, a start whose mark is older than the restart's bound, from the
/// future, from before a reboot or a snapshot restore, or already taken by
/// an earlier start, and the restart a rollback queued. The own flip's
/// restart, from the same marks, takes none.
#[cfg(target_os = "linux")]
#[test]
fn a_cold_start_keeps_the_five_minute_hold() {
    let flip_dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(flip_dir.path());
    assert!(own_flip_then_restart(&paths, T0_MS, 4_000), "the own flip's restart took a hold");
    assert_eq!(gate::Gate::new(&paths).held_left(T0_MS + 4_000), None);
    // The next start takes it no more: the mark is gone.
    assert!(!role::start_hold(&paths, T0_MS + 9_000, FLIP_OFFSET_NS));
    assert_eq!(gate::Gate::new(&paths).held_left(T0_MS + 9_000), Some(gate::CONNECT_HOLD));

    let cold = |mark: Option<(u64, i128)>, start_ms: u64, offset_ns: i128, what: &str| {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::new(dir.path());
        let gate = gate::Gate::new(&paths);
        if let Some((at_ms, at_offset)) = mark {
            assert!(
                gate.run(at_ms, gate::Honor::All, |i| i.flip_restart_queued(at_ms, at_offset))
                    .is_ok()
            );
            gate.service_started();
        }
        assert!(!role::start_hold(&paths, start_ms, offset_ns), "{what}: no start hold");
        assert_eq!(gate.held_left(start_ms), Some(gate::CONNECT_HOLD), "{what}");
        let (gated, _) = role::flip_in_gate(
            &paths,
            || start_ms + 299_000,
            gate::Honor::All,
            || Ok(Vec::new()),
            || false,
            no_flip,
        );
        assert!(matches!(gated, role::Gated::Held(_)), "{what}: {gated:?}");
    };
    let pending_ms = gate::RESTART_PENDING_FOR.as_millis() as u64;
    cold(None, T0_MS, FLIP_OFFSET_NS, "a cold boot");
    cold(
        Some((T0_MS, FLIP_OFFSET_NS)),
        T0_MS + pending_ms + 1,
        FLIP_OFFSET_NS,
        "a mark past the restart's bound",
    );
    cold(Some((T0_MS + 60_000, FLIP_OFFSET_NS)), T0_MS, FLIP_OFFSET_NS, "a mark from the future");
    cold(
        Some((T0_MS, FLIP_OFFSET_NS)),
        T0_MS + 30_000,
        FLIP_OFFSET_NS + 3_600 * SECOND_NS,
        "a reboot since the mark",
    );
    cold(
        Some((T0_MS, FLIP_OFFSET_NS)),
        T0_MS + 30_000,
        FLIP_OFFSET_NS + 5 * SECOND_NS,
        "a snapshot restore since the mark",
    );

    // A rollback's restart leaves no mark.
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let gate = gate::Gate::new(&paths);
    assert!(gate.run(T0_MS, gate::Honor::Nothing, |i| i.restart_queued(T0_MS)).is_ok());
    gate.service_started();
    assert!(!role::start_hold(&paths, T0_MS + 4_000, FLIP_OFFSET_NS), "a rollback's restart");
    assert_eq!(gate.held_left(T0_MS + 4_000), Some(gate::CONNECT_HOLD));
}
