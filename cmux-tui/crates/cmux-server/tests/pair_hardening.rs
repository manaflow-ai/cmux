//! `cmux server pair` hardening (review of the first pass): folder and
//! key-file checks, collecting an approved code near its expiry, stored
//! pairing and pending-code bindings, frame limits and display hygiene.

mod common;
mod pair_fake;

use std::time::Duration;

use cmux_server::error::ExitKind;
use cmux_server::host;
use cmux_server::pair::identity::INSTALL_KEY_FILE;
use cmux_server::pair::{
    ApiTarget, CREDENTIALS_FILE, HostInfo, PENDING_FILE, PairOutcome, PairRequest, Started,
    pairing_dir, run,
};
use cmux_server_core::layout::Layout;
use common::layout_at;
use pair_fake::{FakeApi, Script};

const ENV: &str = "test";

fn info() -> HostInfo {
    HostInfo {
        name: "Studio".into(),
        platform: "linux".into(),
        os_version: "Ubuntu 24.04".into(),
        arch: "x86_64".into(),
        cmux_version: "0.1.0".into(),
    }
}

fn target(api: &FakeApi) -> ApiTarget {
    ApiTarget { base: api.base.clone(), environment: ENV.into(), allow_http: true }
}

fn layout(home: &tempfile::TempDir) -> Layout {
    layout_at(home.path(), host::platform())
}

fn pair(
    layout: &Layout,
    api: &ApiTarget,
    wait: bool,
) -> (cmux_server::Result<PairOutcome>, Vec<Started>) {
    let req = PairRequest {
        layout,
        api,
        info: info(),
        wait,
        timeout: wait.then(|| Duration::from_secs(20)),
        now_ms: host::now_ms(),
    };
    let mut shown = Vec::new();
    let out = run(&req, &mut |s: &Started| shown.push(s.clone()));
    (out, shown)
}

fn read_json(path: &std::path::Path) -> serde_json::Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

fn write_json(path: &std::path::Path, value: &serde_json::Value) {
    use std::io::Write;
    // Replace in place so the 0600 mode stays.
    let mut f = std::fs::OpenOptions::new().write(true).truncate(true).open(path).unwrap();
    f.write_all(value.to_string().as_bytes()).unwrap();
}

#[cfg(unix)]
mod folders {
    use super::*;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn state(layout: &Layout) -> std::path::PathBuf {
        std::path::PathBuf::from(layout.state.as_str())
    }

    #[test]
    fn a_symlinked_pairing_folder_is_refused() {
        let fake = FakeApi::start(ENV, Script::Paired);
        let home = tempfile::tempdir().unwrap();
        let layout = layout(&home);
        let elsewhere = home.path().join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::fs::set_permissions(&elsewhere, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::create_dir_all(state(&layout)).unwrap();
        std::fs::set_permissions(state(&layout), std::fs::Permissions::from_mode(0o700)).unwrap();
        symlink(&elsewhere, pairing_dir(&layout)).unwrap();
        let err = pair(&layout, &target(&fake), false).0.unwrap_err();
        assert_eq!(err.kind, ExitKind::Rejected, "{err}");
        assert_eq!(fake.begin_count(), 0);
        assert!(std::fs::read_dir(&elsewhere).unwrap().next().is_none(), "nothing written");
    }

    #[test]
    fn a_world_writable_pairing_folder_is_refused() {
        let fake = FakeApi::start(ENV, Script::Paired);
        let home = tempfile::tempdir().unwrap();
        let layout = layout(&home);
        let dir = pairing_dir(&layout);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::set_permissions(state(&layout), std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o777)).unwrap();
        let err = pair(&layout, &target(&fake), false).0.unwrap_err();
        assert_eq!(err.kind, ExitKind::Rejected, "{err}");
        assert!(!dir.join(INSTALL_KEY_FILE).exists());
    }

    #[test]
    fn a_wide_state_folder_is_refused() {
        let fake = FakeApi::start(ENV, Script::Paired);
        let home = tempfile::tempdir().unwrap();
        let layout = layout(&home);
        std::fs::create_dir_all(state(&layout)).unwrap();
        std::fs::set_permissions(state(&layout), std::fs::Permissions::from_mode(0o755)).unwrap();
        let err = pair(&layout, &target(&fake), false).0.unwrap_err();
        assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    }

    #[test]
    fn a_key_file_that_is_a_symlink_is_refused() {
        let fake = FakeApi::start(ENV, Script::Paired);
        let home = tempfile::tempdir().unwrap();
        let layout = layout(&home);
        pair(&layout, &target(&fake), false).0.unwrap();
        let key = pairing_dir(&layout).join(INSTALL_KEY_FILE);
        let moved = home.path().join("moved-key");
        std::fs::rename(&key, &moved).unwrap();
        symlink(&moved, &key).unwrap();
        let err = pair(&layout, &target(&fake), false).0.unwrap_err();
        assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    }
}

#[test]
fn an_approved_code_near_expiry_is_collected_not_replaced() {
    // 30 s left: the old code may be approved already, so --wait collects it.
    let fake = FakeApi::with(ENV, 30_000, &[Script::Paired]);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    let PairOutcome::Pending(first) = pair(&layout, &api, false).0.unwrap() else {
        panic!("expected Pending")
    };
    // Without --wait the old code is shown again until it expires.
    let PairOutcome::Pending(again) = pair(&layout, &api, false).0.unwrap() else {
        panic!("expected Pending")
    };
    assert_eq!(again.code, first.code);
    assert!(again.resumed);
    let (out, shown) = pair(&layout, &api, true);
    assert!(matches!(out.unwrap(), PairOutcome::Paired(_)));
    assert_eq!(fake.begin_count(), 1, "no second begin for a live code");
    assert_eq!(shown[0].code, first.code);
}

#[test]
fn an_expired_stored_code_is_replaced_after_the_worker_says_so() {
    // The first wait ends with 4408; only then is a new code begun.
    let fake = FakeApi::with(ENV, 600_000, &[Script::Expired, Script::Paired]);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    pair(&layout, &api, false).0.unwrap();
    let (out, shown) = pair(&layout, &api, true);
    assert!(matches!(out.unwrap(), PairOutcome::Paired(_)), "{shown:?}");
    assert_eq!(fake.begin_count(), 2);
    assert_eq!(fake.waits.lock().unwrap().len(), 2);
    assert_eq!(shown.len(), 2, "both codes were shown");
}

#[test]
fn a_pending_code_for_another_environment_is_not_reused() {
    let fake = FakeApi::start(ENV, Script::Paired);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    pair(&layout, &api, false).0.unwrap();
    let path = pairing_dir(&layout).join(PENDING_FILE);
    let mut pending = read_json(&path);
    pending["environment"] = "other".into();
    write_json(&path, &pending);
    let PairOutcome::Pending(second) = pair(&layout, &api, false).0.unwrap() else {
        panic!("expected Pending")
    };
    assert!(!second.resumed);
    assert_eq!(fake.begin_count(), 2);
}

#[test]
fn a_stored_pairing_for_another_api_or_key_is_reported() {
    let fake = FakeApi::start(ENV, Script::Paired);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    pair(&layout, &api, true).0.unwrap();
    let path = pairing_dir(&layout).join(CREDENTIALS_FILE);
    let good = read_json(&path);
    let mut other_api = good.clone();
    other_api["api"] = "https://elsewhere.example".into();
    write_json(&path, &other_api);
    let err = pair(&layout, &api, true).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    let mut other_key = good.clone();
    other_key["thumbprint"] = "AAAA".into();
    write_json(&path, &other_key);
    let err = pair(&layout, &api, true).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    write_json(&path, &good);
    assert!(matches!(pair(&layout, &api, true).0.unwrap(), PairOutcome::AlreadyPaired(_)));
}

#[test]
fn an_oversized_frame_ends_the_wait() {
    let fake = FakeApi::start(ENV, Script::Huge);
    let home = tempfile::tempdir().unwrap();
    let err = pair(&layout(&home), &target(&fake), true).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Unreachable, "{err}");
}

#[test]
fn host_and_team_are_shown_without_control_characters() {
    let fake = FakeApi::start(ENV, Script::PairedDirty);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let PairOutcome::Paired(p) = pair(&layout, &target(&fake), true).0.unwrap() else {
        panic!("expected Paired")
    };
    assert!(!p.host.chars().any(char::is_control), "{:?}", p.host);
    assert!(!p.team.chars().any(char::is_control), "{:?}", p.team);
}

#[test]
fn the_host_name_fits_80_utf16_units() {
    let name = "\u{1F600}".repeat(60); // 120 UTF-16 units
    let cleaned = cmux_server::pair::info::clean(&name, "x");
    assert!(cleaned.encode_utf16().count() <= 80, "{}", cleaned.encode_utf16().count());
    assert_eq!(cleaned.chars().count(), 40);
}
