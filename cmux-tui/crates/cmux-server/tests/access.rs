//! Directory modes (decision SV-R4): the shared macOS root may be 0755, the
//! state subfolder is created 0700, a wider state folder is refused and
//! never changed, and no existing directory is ever chmodded.

#![cfg(unix)]

mod common;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use cmux_server::error::ExitKind;
use cmux_server::process::RecordingRunner;
use cmux_server::{access, fsx};
use cmux_server_core::Platform;
use cmux_server_core::access::access_policy;
use common::*;

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o7777
}

fn make_dir(path: &Path, mode: u32) {
    fs::create_dir_all(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

#[test]
fn user_mode_accepts_a_shared_0755_root_and_creates_the_state_0700() {
    // macOS (SV-R4) and Linux (decision D2).
    for (platform, root_ends) in [
        (Platform::MacOs, "Library/Application Support/cmux"),
        (Platform::Linux, ".local/share/cmux"),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let root = fsx::local(&layout.root);
        let state = fsx::local(&layout.state);
        assert!(root.ends_with(root_ends), "{platform:?}");
        // The app or cmux-tui created the shared folder first.
        make_dir(&root, 0o755);
        let runner = RecordingRunner::new();
        access::ensure(&access_policy(&layout), &runner).unwrap();
        assert_eq!(mode(&root), 0o755, "{platform:?}: the shared root is left unchanged");
        assert_eq!(mode(&state), 0o700, "{platform:?}: the state folder is created 0700");
        assert!(runner.commands().is_empty(), "no chown or chgrp in user mode");
        // A second run is a no-op.
        access::ensure(&access_policy(&layout), &runner).unwrap();
        assert_eq!((mode(&root), mode(&state)), (0o755, 0o700));
    }
}

#[test]
fn user_mode_creates_a_missing_root_0755() {
    for platform in [Platform::MacOs, Platform::Linux] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        access::ensure(&access_policy(&layout), &RecordingRunner::new()).unwrap();
        assert_eq!(mode(&fsx::local(&layout.root)), 0o755, "{platform:?}");
        assert_eq!(mode(&fsx::local(&layout.state)), 0o700, "{platform:?}");
    }
}

#[test]
fn a_wider_state_folder_is_refused_and_left_unchanged() {
    for platform in [Platform::MacOs, Platform::Linux] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let root = fsx::local(&layout.root);
        let state = fsx::local(&layout.state);
        make_dir(&root, 0o755);
        make_dir(&state, 0o755);
        let err = access::ensure(&access_policy(&layout), &RecordingRunner::new()).unwrap_err();
        assert_eq!(err.kind, ExitKind::Rejected, "{platform:?}: {err}");
        assert!(err.message.contains("wider than 700"), "{err}");
        assert_eq!(mode(&state), 0o755, "{platform:?}: refused, never tightened");
    }
}

#[test]
fn a_shared_root_writable_by_others_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let root = fsx::local(&layout.root);
    make_dir(&root, 0o775);
    let err = access::ensure(&access_policy(&layout), &RecordingRunner::new()).unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert_eq!(mode(&root), 0o775);
    assert!(!fsx::local(&layout.state).exists(), "nothing was created under it");
}

#[test]
fn ensure_dir_never_changes_an_existing_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let existing = tmp.path().join("existing");
    make_dir(&existing, 0o751);
    fsx::ensure_dir(&existing, 0o700).unwrap();
    assert_eq!(mode(&existing), 0o751);
    // Every missing component is created with the mode, not the umask.
    let nested = tmp.path().join("a/b/c");
    fsx::ensure_dir(&nested, 0o700).unwrap();
    for dir in ["a", "a/b", "a/b/c"] {
        assert_eq!(mode(&tmp.path().join(dir)), 0o700, "{dir}");
    }
}

#[test]
fn install_refuses_a_wider_state_folder_before_it_writes_anything() {
    use cmux_server::cli::{Context, dispatch, parse};
    if cmux_server::sys::is_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), cmux_server::host::platform());
    let state = fsx::local(&layout.state);
    make_dir(&fsx::local(&layout.root), 0o755);
    make_dir(&state, 0o755);
    let runner = RecordingRunner::new();
    let fetcher = MapFetcher::default();
    let exec = cmux_server::exec::RecordingExec::default();
    let ctx = Context {
        runner: &runner,
        fetcher: Some(&fetcher),
        exec: &exec,
        keys: vec![Signer::new(1).key("current")],
        running_cmux: "1.0.0".to_owned(),
        reexec_guard: None,
        env: env_for(tmp.path()),
        now_ms: NOW_MS,
    };
    let args: Vec<String> =
        ["install", "--channel-url", "https://chan.example.test"].map(String::from).to_vec();
    let err = dispatch(&ctx, &parse(&args).unwrap()).err().unwrap();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert_eq!(mode(&state), 0o755);
    assert_eq!(fs::read_dir(&state).unwrap().count(), 0, "nothing was written into it");
    assert_eq!(fetcher.hit_count(), 0, "no manifest was fetched");
}
