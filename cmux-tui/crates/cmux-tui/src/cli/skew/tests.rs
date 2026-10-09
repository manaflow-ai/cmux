//! Version-skew re-exec: one test per refusal (plans/cmux-next/version-skew.md
//! step 3), plus the accepted case.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::*;

const PID: u32 = 4242;

/// A temporary `cmux DEV t.app/Contents/Resources/bin/cmux`, mode 0755.
fn bundle(app: &str) -> (tempfile::TempDir, PathBuf) {
    let root = tempfile::tempdir().unwrap();
    let bin = root.path().join(app).join("Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    let cli = bin.join("cmux");
    std::fs::write(&cli, b"#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    for dir in cli.ancestors().skip(1).take(4) {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    (root, cli)
}

fn daemon(cli: &Path) -> DaemonBuild {
    DaemonBuild { build_id: "daemon-build".into(), cli_path: cli.to_path_buf(), pid: PID }
}

fn uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

fn local() -> Route {
    Route::Local { peer_uid: uid(), peer_pid: Some(PID) }
}

fn same_team(_: &Path) -> Result<(), String> {
    Ok(())
}

const OWN_DEV: &str =
    "/Users/u/DerivedData/cmux-a/Build/Products/Debug/cmux DEV a.app/Contents/Resources/bin/cmux";
const OWN_RELEASE: &str = "/Applications/cmux.app/Contents/Resources/bin/cmux";

fn own(guard: Option<&str>) -> Own<'_> {
    Own { build_id: "cli-build", exe: Path::new(OWN_RELEASE), uid: uid(), guard, team: &same_team }
}

#[test]
fn a_local_daemon_of_another_build_runs_its_bundled_cli() {
    let (_root, cli) = bundle("cmux.app");
    assert_eq!(vet(&daemon(&cli), local(), &own(None)), Ok(cli));
    let (_dev, dev_cli) = bundle("cmux DEV t.app");
    let dev = Own { exe: Path::new(OWN_DEV), ..own(None) };
    assert_eq!(vet(&daemon(&dev_cli), local(), &dev), Ok(dev_cli));
}

#[test]
fn another_install_family_or_an_unbundled_cli_is_refused() {
    let (_dev, dev_cli) = bundle("cmux DEV t.app");
    assert_eq!(vet(&daemon(&dev_cli), local(), &own(None)), Err(Refusal::OtherInstallFamily));
    let (_release, release_cli) = bundle("cmux NIGHTLY.app");
    let dev = Own { exe: Path::new(OWN_DEV), ..own(None) };
    assert_eq!(vet(&daemon(&release_cli), local(), &dev), Err(Refusal::OtherInstallFamily));
    let loose = Own { exe: Path::new("/usr/local/bin/cmux"), ..own(None) };
    assert_eq!(vet(&daemon(&release_cli), local(), &loose), Err(Refusal::OtherInstallFamily));
}

#[test]
fn a_reexeced_cli_never_reexecs_again() {
    let (_root, cli) = bundle("cmux.app");
    assert_eq!(vet(&daemon(&cli), local(), &own(Some("daemon-build"))), Err(Refusal::LoopGuard));
}

#[test]
fn the_same_build_is_not_a_skew() {
    let (_root, cli) = bundle("cmux.app");
    let mut same = daemon(&cli);
    same.build_id = "cli-build".into();
    assert_eq!(vet(&same, local(), &own(None)), Err(Refusal::SameBuild));
}

#[test]
fn a_remote_daemon_is_never_probed() {
    let global = GlobalArgs { machine: Some("build-box".into()), ..GlobalArgs::default() };
    assert_eq!(probe(&global), None);
}

#[test]
fn a_daemon_of_another_user_is_refused() {
    let (_root, cli) = bundle("cmux.app");
    let route = Route::Local { peer_uid: uid() + 1, peer_pid: Some(PID) };
    assert_eq!(vet(&daemon(&cli), route, &own(None)), Err(Refusal::OtherUser { uid: uid() + 1 }));
}

#[test]
fn a_forwarded_socket_whose_peer_is_not_the_daemon_is_refused() {
    let (_root, cli) = bundle("cmux.app");
    for peer_pid in [Some(PID + 1), None] {
        let route = Route::Local { peer_uid: uid(), peer_pid };
        assert_eq!(vet(&daemon(&cli), route, &own(None)), Err(Refusal::NotTheDaemon));
    }
}

#[test]
fn a_relative_path_is_never_looked_up_on_path() {
    let relative = daemon(Path::new("cmux"));
    assert_eq!(vet(&relative, local(), &own(None)), Err(Refusal::NotAbsolute));
}

#[test]
fn a_symlink_or_directory_is_refused() {
    let (root, cli) = bundle("cmux.app");
    let link = cli.with_file_name("cmux-link");
    std::os::unix::fs::symlink(&cli, &link).unwrap();
    assert_eq!(vet(&daemon(&link), local(), &own(None)), Err(Refusal::NotRegularFile));
    let dir = cli.with_file_name("cmux-dir");
    std::fs::create_dir(&dir).unwrap();
    assert_eq!(vet(&daemon(&dir), local(), &own(None)), Err(Refusal::NotRegularFile));
    drop(root);
}

#[test]
fn a_path_outside_a_cmux_bundle_is_refused() {
    let (_other, other) = bundle("Other.app");
    assert_eq!(vet(&daemon(&other), local(), &own(None)), Err(Refusal::NotInCmuxBundle));
    let loose = tempfile::tempdir().unwrap();
    let file = loose.path().join("cmux");
    std::fs::write(&file, b"x").unwrap();
    assert_eq!(vet(&daemon(&file), local(), &own(None)), Err(Refusal::NotInCmuxBundle));
}

#[test]
fn a_group_or_other_writable_file_or_bundle_directory_is_refused() {
    let (_root, cli) = bundle("cmux.app");
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o775)).unwrap();
    assert_eq!(vet(&daemon(&cli), local(), &own(None)), Err(Refusal::Writable(cli.clone())));
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    let contents = cli.ancestors().nth(3).unwrap().to_path_buf();
    std::fs::set_permissions(&contents, std::fs::Permissions::from_mode(0o757)).unwrap();
    assert_eq!(vet(&daemon(&cli), local(), &own(None)), Err(Refusal::Writable(contents)));
}

#[test]
fn another_team_signature_is_refused() {
    let (_root, cli) = bundle("cmux.app");
    let other_team = |_: &Path| Err("team check returned -67050".to_owned());
    let own = Own { team: &other_team, ..own(None) };
    assert_eq!(
        vet(&daemon(&cli), local(), &own),
        Err(Refusal::TeamId("team check returned -67050".into()))
    );
}

#[test]
fn identify_without_the_capability_or_fields_gives_no_daemon_build() {
    let full =
        json!({"capabilities":["daemon-build-v1"],"build_id":"b","cli_path":"/x/cmux","pid":7});
    assert_eq!(
        DaemonBuild::from_identity(&full),
        Some(DaemonBuild { build_id: "b".into(), cli_path: "/x/cmux".into(), pid: 7 })
    );
    let old = json!({"capabilities":[],"build_id":"b","cli_path":"/x/cmux","pid":7});
    assert_eq!(DaemonBuild::from_identity(&old), None);
    let unresolved =
        json!({"capabilities":["daemon-build-v1"],"build_id":"b","cli_path":null,"pid":7});
    assert_eq!(DaemonBuild::from_identity(&unresolved), None);
}

#[test]
fn each_reexec_logs_one_line_and_a_refusal_prints_one_exact_command() {
    let cli = PathBuf::from("/Applications/cmux.app/Contents/Resources/bin/cmux");
    let line = reexec_line(&daemon(&cli), "cli-build");
    assert_eq!(line.lines().count(), 1);
    assert!(line.contains("daemon-build") && line.contains(cli.to_str().unwrap()), "{line}");
    let fix = fix_command(Path::new("/opt/it's/cmux"), Path::new("/tmp/s.sock"));
    assert_eq!(
        fix,
        "'/opt/it'\\''s/cmux' daemon stop --socket '/tmp/s.sock' && '/opt/it'\\''s/cmux' daemon ensure --socket '/tmp/s.sock'"
    );
}
