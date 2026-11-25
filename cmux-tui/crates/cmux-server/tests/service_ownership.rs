//! Which unit and plist files `cmux server install` and `uninstall` treat as
//! cmux's, where systemd loads them from, and the LaunchAgent log they point
//! at (Codex review F-003, F-004, F-006). Driven through `Services` with a
//! Linux or macOS layout, so both run on any host.

mod common;

use std::path::{Path, PathBuf};

use cmux_server::process::{Output, RecordingRunner};
use cmux_server::service::{Services, SessionHost};
use cmux_server_core::Platform;
use cmux_server_core::layout::Layout;
use common::*;

/// What `systemctl show` prints for a unit systemd does not know.
fn not_found() -> Output {
    Output {
        code: Some(0),
        stdout: b"LoadState=not-found\nFragmentPath=\nTransient=no\n".to_vec(),
        ..Output::default()
    }
}

/// What `launchctl print` does for a job launchd has not loaded.
fn not_loaded() -> Output {
    Output { code: Some(113), ..Output::default() }
}

fn shows(text: &str) -> Output {
    Output { code: Some(0), stdout: text.as_bytes().to_vec(), ..Output::default() }
}

fn services<'a>(layout: &'a Layout, runner: &'a RecordingRunner, binary: &Path) -> Services<'a> {
    Services {
        layout,
        runner,
        uid: uid(),
        user: "tester".to_owned(),
        session: Some(SessionHost {
            binary: binary.display().to_string(),
            session: "main".to_owned(),
        }),
        linger: false,
        announce: false,
    }
}

fn skip_as_root() -> bool {
    let root = cmux_server::sys::is_root();
    if root {
        eprintln!("skipped: the ownership checks compare against a non-root uid");
    }
    root
}

/// A unit or plist cmux renders for another binary: cmux-shaped (the old
/// marker, a session ExecStart), but not one cmux wrote here.
fn lookalike(layout: &Layout, home: &Path) -> (PathBuf, String) {
    let runner = RecordingRunner::new();
    let other = services(layout, &runner, &home.join("elsewhere/cmux-tui"));
    other.unit_files().unwrap().remove(0)
}

#[test]
fn a_unit_that_only_looks_like_cmux_is_left_alone() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let (path, text) = lookalike(&layout, tmp.path());
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &text).unwrap();
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        assert_eq!(svc.foreign_units().unwrap(), vec![path.clone()], "{platform:?}");
        let err = svc.install(false).unwrap_err();
        assert!(err.to_string().contains("not written by cmux"), "{platform:?}: {err}");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            text,
            "{platform:?}: install changed it"
        );
    }
}

#[test]
fn a_unit_cmux_wrote_stays_cmux_after_the_binary_moves() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let first = services(&layout, &runner, &tmp.path().join("a/cmux-tui"));
        first.install(false).unwrap();
        // Another binary renders another unit; the record says cmux wrote the old one.
        let second = services(&layout, &runner, &tmp.path().join("b/cmux-tui"));
        assert_eq!(second.foreign_units().unwrap(), Vec::<PathBuf>::new(), "{platform:?}");
        second.install(false).unwrap();
        let (path, text) = second.unit_files().unwrap().remove(0);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}");
        // A hand edit after that is not cmux's.
        std::fs::write(&path, format!("{text}\n# edited\n")).unwrap();
        assert_eq!(second.foreign_units().unwrap(), vec![path], "{platform:?}");
    }
}

#[test]
fn systemd_must_say_it_loads_the_unit_from_cmuxs_file() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let binary = tmp.path().join(".local/bin/cmux-tui");
    let ours = services(&layout, &RecordingRunner::new(), &binary).unit_path().unwrap();
    let cases: [(&str, Output); 5] = [
        // A transient unit (systemd-run --unit cmux-server): no file at all.
        ("transient", shows("LoadState=loaded\nFragmentPath=\nTransient=yes\n")),
        // A generator's unit.
        (
            "generated",
            shows(
                "LoadState=loaded\nFragmentPath=/run/systemd/generator/cmux-server.service\nTransient=no\n",
            ),
        ),
        // Masked from another place.
        ("masked", shows("LoadState=masked\nFragmentPath=/dev/null\nTransient=no\n")),
        // systemd cannot be asked: cmux cannot tell, so it changes nothing.
        ("no answer", Output { code: Some(1), ..Output::default() }),
        // An answer without a load state.
        ("empty answer", shows("")),
    ];
    for (what, answer) in cases {
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", answer);
        let svc = services(&layout, &runner, &binary);
        let err = svc.preflight().expect_err(what);
        assert!(err.to_string().contains("cmux-server.service"), "{what}: {err}");
        assert!(svc.install(false).is_err(), "{what}");
        assert!(!ours.exists(), "{what}: install wrote the unit");
        let lines = runner.lines().join("\n");
        assert!(!lines.contains(" enable ") && !lines.contains(" start "), "{what}: {lines}");
    }
    // Loaded from cmux's own file, or not known at all: cmux goes on.
    for answer in [
        not_found(),
        shows(&format!("LoadState=loaded\nFragmentPath={}\nTransient=no\n", ours.display())),
    ] {
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", answer);
        services(&layout, &runner, &binary).preflight().unwrap();
    }
}

#[cfg(unix)]
#[test]
fn the_launchagent_log_is_private_and_a_plain_file_of_yours() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let mode = |p: &Path| std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o777;
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let binary = tmp.path().join(".local/bin/cmux-tui");
    let logs = cmux_server::fsx::local(&layout.logs());
    let log = logs.join("server.log");
    // A log folder and log others can read: install makes both private.
    std::fs::create_dir_all(&logs).unwrap();
    std::fs::set_permissions(&logs, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(&log, b"old line\n").unwrap();
    std::fs::set_permissions(&log, std::fs::Permissions::from_mode(0o644)).unwrap();
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    services(&layout, &runner, &binary).install(false).unwrap();
    assert_eq!(mode(&logs), 0o700);
    assert_eq!(mode(&log), 0o600);
    assert_eq!(std::fs::read(&log).unwrap(), b"old line\n", "the log is kept");
    // A second name for another file of yours (a hard link): launchd would
    // write the log into that file.
    let other = tmp.path().join("notes.txt");
    std::fs::write(&other, b"mine\n").unwrap();
    std::fs::remove_file(&log).unwrap();
    std::fs::hard_link(&other, &log).unwrap();
    let err = services(&layout, &runner, &binary).preflight().unwrap_err();
    assert!(err.to_string().contains("server.log"), "{err}");
    std::fs::remove_file(&log).unwrap();
    // A log folder that is a symlink to another folder of yours.
    let real = tmp.path().join("real-logs");
    std::fs::create_dir_all(&real).unwrap();
    std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::remove_dir(&logs).unwrap();
    std::os::unix::fs::symlink(&real, &logs).unwrap();
    let err = services(&layout, &runner, &binary).preflight().unwrap_err();
    assert!(err.to_string().contains("log"), "{err}");
}

/// What `launchctl print` shows for a job loaded from `plist`.
fn launchd_job(plist: &Path) -> Output {
    shows(&format!(
        "gui/501/com.cmux.server = {{\n\tactive count = 1\n\tpath = {}\n\tstate = running\n}}\n",
        plist.display()
    ))
}

#[test]
fn a_launchagent_job_loaded_from_another_plist_is_left_alone() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let binary = tmp.path().join(".local/bin/cmux-tui");
    let elsewhere = tmp.path().join("Library/LaunchAgents/someone-else.plist");
    // No plist at cmux's path, but launchd runs com.cmux.server from another one.
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", launchd_job(&elsewhere));
    let svc = services(&layout, &runner, &binary);
    let err = svc.foreign_units().unwrap_err();
    assert!(err.to_string().contains("someone-else.plist"), "{err}");
    assert!(svc.install(false).is_err());
    let lines = runner.lines().join("\n");
    assert!(!lines.contains("bootout") && !lines.contains("bootstrap"), "{lines}");
    // Loaded from cmux's own plist, or not loaded: fine.
    let ours = svc.unit_path().unwrap();
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", launchd_job(&ours));
    services(&layout, &runner, &binary).foreign_units().unwrap();
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    services(&layout, &runner, &binary).foreign_units().unwrap();
}

#[cfg(unix)]
#[test]
fn uninstall_trusts_no_record_in_a_folder_others_can_write() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let binary = tmp.path().join(".local/bin/cmux-tui");
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &binary);
    svc.install(false).unwrap();
    let state = cmux_server::fsx::local(&layout.state);
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o777)).unwrap();
    // foreign_units is what uninstall asks; it must not read a record another
    // account could have replaced.
    let err = svc.foreign_units().unwrap_err();
    assert!(err.to_string().contains(&state.display().to_string()), "{err}");
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
    svc.foreign_units().unwrap();
}

#[cfg(unix)]
#[test]
fn write_if_changed_replaces_a_symlink_even_to_the_same_bytes() {
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("target");
    let link = tmp.path().join("unit");
    std::fs::write(&target, b"same\n").unwrap();
    std::os::unix::fs::symlink(&target, &link).unwrap();
    let wrote = cmux_server::fsx::write_if_changed(&link, b"same\n", 0o644).unwrap();
    assert!(wrote, "a symlink is never kept as the file cmux wrote");
    assert!(std::fs::symlink_metadata(&link).unwrap().is_file());
    assert_eq!(std::fs::read(&target).unwrap(), b"same\n", "the link's target is left alone");
}

#[test]
fn system_app_server_instances_must_come_from_cmuxs_template() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = cmux_server_core::layout::layout(
        cmux_server_core::InstallMode::System,
        Platform::Linux,
        &env_for(tmp.path()),
    )
    .unwrap();
    let runner = RecordingRunner::new();
    runner.answer(
        "list-units",
        shows("cmux-app-server@notes.service loaded active running cmux app server notes\n"),
    );
    runner.answer(
        "cmux-app-server@notes.service",
        shows("LoadState=loaded\nFragmentPath=/usr/lib/systemd/system/cmux-app-server@.service\nTransient=no\n"),
    );
    runner.answer_always("--property=LoadState", not_found());
    runner.answer_always("launchctl print", not_loaded());
    let svc = Services {
        layout: &layout,
        runner: &runner,
        uid: 0,
        user: "root".to_owned(),
        session: None,
        linger: false,
        announce: false,
    };
    let err = svc.foreign_units().unwrap_err();
    assert!(err.to_string().contains("cmux-app-server@notes.service"), "{err}");
}
