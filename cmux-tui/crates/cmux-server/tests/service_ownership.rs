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

/// A unit systemd says is stopped (what uninstall checks after a stop).
/// Tests answer it for every unit; a test's one-time answer comes first.
fn stopped(runner: &RecordingRunner) {
    runner.answer_always("--property=ActiveState", shows("inactive\n"));
    runner.answer_always(
        "--property=ControlGroup,TasksCurrent",
        shows("ControlGroup=\nTasksCurrent=[not set]\n"),
    );
}

/// Services of the session service. Its binary is created when missing
/// and its home folder exists (tests of a missing home keep it missing):
/// uninstall needs it to end the session's terminals.
fn services<'a>(layout: &'a Layout, runner: &'a RecordingRunner, binary: &Path) -> Services<'a> {
    stopped(runner);
    // The sweep's `daemon ensure` starts a daemon (tests answer otherwise).
    runner.answer_always("daemon ensure", daemon_says("started", "main", 777));
    runner.answer_always("--end-terminals", daemon_says("stopped", "main", 777));
    let home = binary.ancestors().nth(3);
    if !binary.exists() && home.is_some_and(Path::is_dir) {
        session_binary_at(binary);
    }
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

/// What stops the service on each platform: the step after which uninstall
/// removes the unit files.
fn stop_step(platform: Platform) -> &'static str {
    match platform {
        Platform::MacOs => "launchctl bootout",
        _ => "disable --now",
    }
}

/// The CLI checks ownership, then takes its own steps (a final backup can
/// take minutes) before it calls uninstall. A unit systemd or launchd starts
/// loading from another file in that gap must stop uninstall before it stops,
/// disables or removes anything.
#[test]
fn uninstall_checks_the_unit_source_again_right_before_it_stops_anything() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        assert_eq!(svc.foreign_units().unwrap(), Vec::<PathBuf>::new(), "{platform:?}");
        // After that check: the manager now loads the unit from another file.
        runner.answer(
            "--property=LoadState",
            shows("LoadState=loaded\nFragmentPath=/etc/systemd/user/cmux-server.service\nTransient=no\n"),
        );
        runner.answer("launchctl print", shows("path = /Library/LaunchAgents/other.plist\n"));
        let before = runner.lines().len();
        let err = svc.uninstall().unwrap_err();
        let after = runner.lines()[before..].to_vec();
        assert!(
            !after.iter().any(|l| l.contains(stop_step(platform)) || l.contains(" kill ")),
            "{platform:?}: stopped a unit it no longer owns: {after:?} ({err})"
        );
        let (path, text) = svc.unit_files().unwrap().remove(0);
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}: removed it");
    }
}

/// A unit edited while uninstall stops the service is no longer cmux's:
/// uninstall must leave it in place, never remove what it did not check.
#[test]
fn uninstall_never_removes_a_unit_edited_while_it_stops_the_service() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        let edited = format!("{text}\n# edited while cmux stopped the service\n");
        let (at, body) = (path.clone(), edited.clone());
        runner.on_run(stop_step(platform), move || std::fs::write(&at, &body).unwrap());
        let err = svc.uninstall().unwrap_err();
        assert!(err.to_string().contains("changed"), "{platform:?}: {err}");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            edited,
            "{platform:?}: removed or changed the edited unit"
        );
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            // The service lock stays while a unit does.
            .filter(|name| name != ".cmux-server.lock")
            .collect();
        assert_eq!(names.len(), 1, "{platform:?}: left extra files: {names:?}");
    }
}

/// A Linux system layout whose store root and unit folder are under `tmp`
/// (this account's), and whose state folder is `state`.
fn system_layout(tmp: &Path, state: &str) -> Layout {
    use cmux_server_core::platform::HostPath;
    let mut layout = cmux_server_core::layout::layout(
        cmux_server_core::InstallMode::System,
        Platform::Linux,
        &env_for(tmp),
    )
    .unwrap();
    let at = |p: &Path| HostPath::new(Platform::Linux, &p.display().to_string()).unwrap();
    layout.root = at(&tmp.join("root"));
    layout.state = HostPath::new(Platform::Linux, state).unwrap();
    layout.service = cmux_server_core::layout::ServiceKind::SystemdSystem {
        unit_path: at(&tmp.join("units/cmux-server.service")),
    };
    layout
}

fn system_services<'a>(layout: &'a Layout, runner: &'a RecordingRunner) -> Services<'a> {
    stopped(runner);
    Services {
        layout,
        runner,
        uid: 0,
        user: "root".to_owned(),
        session: None,
        linger: false,
        announce: false,
    }
}

/// System mode: root runs install and uninstall, but the state folder
/// belongs to the service account `cmux` (the access policy). The ownership
/// record must not live there (that account could forge it), and its owner
/// must not make cmux refuse a correct system install.
#[test]
fn a_system_install_whose_state_folder_belongs_to_the_service_account_is_not_refused() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    // "/" stands for /var/lib/cmux: private, but owned by another account.
    let layout = system_layout(tmp.path(), "/");
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    let svc = system_services(&layout, &runner);
    assert_eq!(svc.foreign_units().unwrap(), Vec::<PathBuf>::new());
    svc.preflight().unwrap();
}

/// A launchctl that cannot say whether it runs the job (any failure but
/// "not found", exit 113) is no answer: cmux changes nothing.
#[test]
fn a_launchctl_that_cannot_answer_changes_nothing() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", Output { code: Some(5), ..Output::default() });
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    let err = svc.foreign_units().unwrap_err();
    assert!(err.to_string().contains("launchctl print"), "{err}");
}

/// Uninstall removes unit files by name: it must refuse when another
/// account can write the folder they are in (it could swap a file between
/// cmux's check and its removal).
#[cfg(unix)]
#[test]
fn uninstall_refuses_a_unit_folder_others_can_write() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let (path, text) = svc.unit_files().unwrap().remove(0);
    let dir = path.parent().unwrap();
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o777)).unwrap();
    let before = runner.lines().len();
    let err = svc.uninstall().unwrap_err();
    assert!(err.to_string().contains(&dir.display().to_string()), "{err}");
    assert!(
        !runner.lines()[before..].iter().any(|l| l.contains("disable --now")),
        "stopped the service anyway"
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
}

/// System uninstall stops the app server instances it listed and checked,
/// by name, never by a pattern that also matches one started since.
#[test]
fn system_uninstall_stops_only_the_app_instances_it_checked() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = system_layout(tmp.path(), &tmp.path().join("state").display().to_string());
    let template = tmp.path().join("units/cmux-app-server@.service");
    let runner = RecordingRunner::new();
    runner.answer_always(
        "list-units",
        shows("cmux-app-server@notes.service loaded active running cmux app server notes\n"),
    );
    runner.answer_always(
        "--property=FragmentPath --value",
        shows(&format!("{}\n", template.display())),
    );
    runner.answer_always("--property=LoadState", not_found());
    let svc = system_services(&layout, &runner);
    svc.uninstall().unwrap();
    let stops: Vec<String> = runner.lines().into_iter().filter(|l| l.contains(" stop ")).collect();
    assert!(stops.iter().any(|l| l.ends_with("stop cmux-app-server@notes.service")), "{stops:?}");
    assert!(!stops.iter().any(|l| l.contains('*')), "stopped by pattern: {stops:?}");
}

/// An app server instance the supervisor starts while uninstall stops it
/// must be stopped too: uninstall lists the instances again after the
/// supervisor is down, not only before.
#[test]
fn system_uninstall_stops_an_app_instance_started_while_the_supervisor_stopped() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = system_layout(tmp.path(), &tmp.path().join("state").display().to_string());
    let template = tmp.path().join("units/cmux-app-server@.service");
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always(
        "--property=FragmentPath --value",
        shows(&format!("{}\n", template.display())),
    );
    runner.answer_always("--property=LoadState", not_found());
    // No instance until the supervisor stops; then one appears.
    let late = std::sync::Arc::downgrade(&runner);
    runner.on_run("disable --now cmux-server.service", move || {
        if let Some(runner) = late.upgrade() {
            runner.answer_always(
                "list-units",
                shows("cmux-app-server@late.service loaded active running cmux app server late\n"),
            );
        }
    });
    let svc = system_services(&layout, &runner);
    svc.uninstall().unwrap();
    let stops: Vec<String> = runner.lines().into_iter().filter(|l| l.contains(" stop ")).collect();
    assert!(stops.iter().any(|l| l.ends_with("stop cmux-app-server@late.service")), "{stops:?}");
}

/// A systemd answer: the unit loads from `fragment`.
fn loads_from(fragment: &Path) -> Output {
    shows(&format!("LoadState=loaded\nFragmentPath={}\nTransient=no\n", fragment.display()))
}

/// The manager is told to load the unit from another file between the
/// last check and a stop (R-005): uninstall checks the source again right
/// before each command that stops something by name, and stops nothing of
/// a unit that is no longer cmux's.
#[test]
fn uninstall_checks_the_unit_source_right_before_each_stop() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always("--property=LoadState", not_found());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let (path, text) = svc.unit_files().unwrap().remove(0);
    // While uninstall ends the unit's processes, the manager starts loading
    // the unit from another file.
    // Right after the kill (its own check after it still sees cmux's file),
    // before the stop: the manager now loads the unit from another file.
    let swap = std::sync::Arc::downgrade(&runner);
    let ours = path.clone();
    runner.on_run("kill --kill-whom=all", move || {
        if let Some(runner) = swap.upgrade() {
            runner.answer("--property=LoadState", loads_from(&ours));
            runner.answer(
                "--property=LoadState",
                loads_from(Path::new("/etc/systemd/user/cmux-server.service")),
            );
        }
    });
    let err = svc.uninstall().unwrap_err();
    // The session service stops its daemon before the kill (the kill's
    // SIGTERM does not end terminal hosts): nothing stops after the swap.
    let lines = runner.lines();
    let kill = lines.iter().position(|l| l.contains("kill --kill-whom=all")).unwrap();
    assert!(
        !lines[kill..].iter().any(|l| l.contains("disable --now cmux-server.service")),
        "stopped a unit that is no longer cmux's: {lines:?} ({err})"
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "removed the unit file");
}

/// The swap lands while the stop runs (R-005): the stop by name may have
/// hit the other unit. Uninstall checks the source right after each stop,
/// says so, and removes nothing.
#[test]
fn uninstall_checks_the_unit_source_right_after_each_stop() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always("--property=LoadState", not_found());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let (path, text) = svc.unit_files().unwrap().remove(0);
    let swap = std::sync::Arc::downgrade(&runner);
    runner.on_run("disable --now cmux-server.service", move || {
        if let Some(runner) = swap.upgrade() {
            runner.answer(
                "--property=LoadState",
                loads_from(Path::new("/etc/systemd/user/cmux-server.service")),
            );
        }
    });
    let err = svc.uninstall().unwrap_err();
    assert!(err.to_string().contains("/etc/systemd/user/cmux-server.service"), "{err}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "removed the unit file");
}

/// An app server instance that systemd starts loading from another file
/// after the list (R-005) is not stopped: each instance is checked right
/// before its own stop.
#[test]
fn system_uninstall_checks_each_app_instance_right_before_its_stop() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = system_layout(tmp.path(), &tmp.path().join("state").display().to_string());
    let template = tmp.path().join("units/cmux-app-server@.service");
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always(
        "list-units",
        shows(
            "cmux-app-server@a.service loaded active running cmux app server a\n\
             cmux-app-server@b.service loaded active running cmux app server b\n",
        ),
    );
    runner.answer_always(
        "--property=FragmentPath --value",
        shows(&format!("{}\n", template.display())),
    );
    runner.answer_always("--property=LoadState", not_found());
    let swap = std::sync::Arc::downgrade(&runner);
    // After `a` stopped (its own check after it still sees cmux's
    // template), systemd loads `b` from another file.
    runner.on_run("stop cmux-app-server@a.service", move || {
        if let Some(runner) = swap.upgrade() {
            runner.answer(
                "--property=FragmentPath --value cmux-app-server@b.service",
                shows("/etc/systemd/system/cmux-app-server@.service\n"),
            );
        }
    });
    let svc = system_services(&layout, &runner);
    let err = svc.uninstall().unwrap_err();
    assert!(
        !runner.lines().iter().any(|l| l.ends_with("stop cmux-app-server@b.service")),
        "stopped an instance that is no longer cmux's: {:?} ({err})",
        runner.lines()
    );
}

/// A stop that failed (the unit still runs, or launchd still has the job)
/// must not let uninstall remove what the service still uses: uninstall
/// checks it stopped and otherwise fails, removing nothing.
#[test]
fn uninstall_removes_nothing_when_the_service_did_not_stop() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = std::sync::Arc::new(RecordingRunner::new());
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        let still = std::sync::Arc::downgrade(&runner);
        let plist = path.clone();
        runner.on_run(stop_step(platform), move || {
            if let Some(runner) = still.upgrade() {
                runner.answer("--property=ActiveState", shows("active\n"));
                // launchd keeps the job for longer than uninstall waits
                // (5 s, 50 checks).
                for _ in 0..60 {
                    runner
                        .answer("launchctl print", shows(&format!("path = {}\n", plist.display())));
                }
            }
        });
        let err = svc.uninstall().unwrap_err();
        assert!(err.to_string().contains("removed nothing"), "{platform:?}: {err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}: removed it");
    }
}

/// `launchctl bootout` returns before launchd has dropped the job: on macOS
/// 27 `launchctl print` still finds it for a moment after (seen on a fleet
/// Mac: found right after the bootout, gone 2 s later). Uninstall waits for
/// the job to go, then removes the plist.
#[test]
fn uninstall_waits_for_launchd_to_drop_the_job_after_its_bootout() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let path = svc.unit_path().unwrap();
    let going = std::sync::Arc::downgrade(&runner);
    let plist = path.clone();
    runner.on_run("launchctl bootout", move || {
        if let Some(runner) = going.upgrade() {
            for _ in 0..3 {
                runner.answer(
                    "launchctl print",
                    shows(&format!("path = {}\n\tstate = not running\n", plist.display())),
                );
            }
        }
    });
    svc.uninstall().unwrap();
    assert!(!path.exists(), "the plist is left");
    let prints = runner
        .lines()
        .iter()
        .skip_while(|line| !line.contains("launchctl bootout"))
        .filter(|line| line.contains("launchctl print"))
        .count();
    assert_eq!(prints, 4, "uninstall asked launchd {prints} times after the bootout");
}

/// `KillMode=process` stops only the main process, and the kill that ends
/// the rest (terminal hosts) may fail: a unit that is inactive but still
/// has processes must not let uninstall remove what they use.
#[test]
fn uninstall_removes_nothing_while_processes_of_the_unit_still_run() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always("--property=LoadState", not_found());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let (path, text) = svc.unit_files().unwrap().remove(0);
    let left = std::sync::Arc::downgrade(&runner);
    // They stay for longer than uninstall waits (5 s, 50 checks).
    runner.on_run("disable --now cmux-server.service", move || {
        if let Some(runner) = left.upgrade() {
            for _ in 0..60 {
                runner.answer(
                    "--property=ControlGroup,TasksCurrent",
                    shows("ControlGroup=/app.slice/cmux-server.service\nTasksCurrent=2\n"),
                );
            }
        }
    });
    let err = svc.uninstall().unwrap_err();
    assert!(err.to_string().contains("still run"), "{err}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "removed the unit file");
}

/// When systemd cannot say whether processes of the unit are left (the
/// query fails, or says nothing of its control group), uninstall cannot
/// tell they are gone: it removes nothing.
#[test]
fn uninstall_removes_nothing_when_it_cannot_tell_the_unit_has_no_processes() {
    if skip_as_root() {
        return;
    }
    for answer in [Output { code: Some(1), ..Output::default() }, shows("TasksCurrent=[not set]\n")]
    {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), Platform::Linux);
        let runner = std::sync::Arc::new(RecordingRunner::new());
        runner.answer_always("--property=LoadState", not_found());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        let unknown = std::sync::Arc::downgrade(&runner);
        runner.on_run("disable --now cmux-server.service", move || {
            if let Some(runner) = unknown.upgrade() {
                runner.answer("--property=ControlGroup,TasksCurrent", answer.clone());
            }
        });
        let err = svc.uninstall().unwrap_err();
        assert!(err.to_string().contains("cannot tell"), "{err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "removed the unit file");
    }
}

/// The kill does not wait: processes it signalled may still be ending
/// when uninstall checks. Uninstall waits for them and then goes on.
#[test]
fn uninstall_waits_for_processes_of_the_unit_that_are_ending() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = std::sync::Arc::new(RecordingRunner::new());
    runner.answer_always("--property=LoadState", not_found());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let (path, _) = svc.unit_files().unwrap().remove(0);
    let ending = std::sync::Arc::downgrade(&runner);
    runner.on_run("disable --now cmux-server.service", move || {
        if let Some(runner) = ending.upgrade() {
            for _ in 0..3 {
                runner.answer(
                    "--property=ControlGroup,TasksCurrent",
                    shows("ControlGroup=/app.slice/cmux-server.service\nTasksCurrent=1\n"),
                );
            }
        }
    });
    svc.uninstall().unwrap();
    assert!(!path.exists(), "the unit file stayed");
}

/// A unit file with cmux's bytes that another account can write (mode
/// 0666): that account could add a line (`PropagatesStopTo=`) that the
/// manager reads when uninstall stops the unit. Uninstall refuses before
/// it stops anything.
#[cfg(unix)]
#[test]
fn uninstall_refuses_a_unit_file_others_can_write_before_it_stops_anything() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).unwrap();
        let before = runner.lines().len();
        let err = svc.uninstall().unwrap_err();
        let after = runner.lines()[before..].to_vec();
        assert!(
            !after.iter().any(|l| l.contains(stop_step(platform)) || l.contains(" kill ")),
            "{platform:?}: stopped something: {after:?} ({err})"
        );
        assert!(err.to_string().contains(&path.display().to_string()), "{platform:?}: {err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}: removed it");
    }
}

/// A drop-in for the unit (`cmux-server.service.d/*.conf`) that another
/// account can write changes what systemd runs and stops just the same.
/// Uninstall refuses before it stops anything.
#[cfg(unix)]
#[test]
fn uninstall_refuses_a_drop_in_others_can_write_before_it_stops_anything() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let (path, text) = svc.unit_files().unwrap().remove(0);
    let dir = tmp.path().join("cmux-server.service.d");
    std::fs::create_dir(&dir).unwrap();
    let drop_in = dir.join("override.conf");
    std::fs::write(&drop_in, "[Service]\n").unwrap();
    std::fs::set_permissions(&drop_in, std::fs::Permissions::from_mode(0o666)).unwrap();
    runner.answer(
        "--property=LoadState",
        shows(&format!(
            "LoadState=loaded\nFragmentPath={}\nTransient=no\nDropInPaths={}\n",
            path.display(),
            drop_in.display()
        )),
    );
    let before = runner.lines().len();
    let err = svc.uninstall().unwrap_err();
    let after = runner.lines()[before..].to_vec();
    assert!(
        !after.iter().any(|l| l.contains("disable --now") || l.contains(" kill ")),
        "stopped something: {after:?} ({err})"
    );
    assert!(err.to_string().contains(&drop_in.display().to_string()), "{err}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "removed it");
}

/// Adds a macOS ACL entry (`chmod +a`) to `path`.
#[cfg(target_os = "macos")]
fn add_acl(path: &Path, entry: &str) {
    let status =
        std::process::Command::new("/bin/chmod").arg("+a").arg(entry).arg(path).status().unwrap();
    assert!(status.success(), "chmod +a {entry} {}", path.display());
}

/// macOS: an ACL entry can let another account write a folder or file whose
/// mode bits say 0700 or 0600 (Codex R-004). Install must refuse one on the
/// LaunchAgent log folder, on any folder above it, and on the log itself;
/// launchd writes the log by its path as this user.
#[cfg(target_os = "macos")]
#[test]
fn a_launchagent_log_others_can_write_through_an_acl_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let cases: [(&str, fn(&Path) -> PathBuf); 3] = [
        ("group:everyone allow add_file,delete_child", |logs| logs.to_path_buf()),
        ("group:everyone allow add_subdirectory,delete_child", |logs| {
            logs.parent().unwrap().parent().unwrap().to_path_buf()
        }),
        ("group:everyone allow write,append", |logs| logs.join("server.log")),
    ];
    for (entry, target) in cases {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), Platform::MacOs);
        let logs = cmux_server::fsx::local(&layout.logs());
        std::fs::create_dir_all(&logs).unwrap();
        for dir in logs.ancestors().take_while(|d| d.starts_with(tmp.path())) {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        std::fs::write(logs.join("server.log"), b"").unwrap();
        std::fs::set_permissions(logs.join("server.log"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let runner = RecordingRunner::new();
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.preflight().unwrap();
        let path = target(&logs);
        add_acl(&path, entry);
        let err = svc.preflight().unwrap_err();
        assert!(
            err.to_string().contains(&path.display().to_string())
                && err.to_string().contains("ACL"),
            "{entry} on {}: {err}",
            path.display()
        );
    }
}

/// launchd opens the LaunchAgent log by its path: a folder above the log
/// folder that another account can write (mode bits here) lets it rename
/// that folder and put its own in its place. Install refuses it.
#[cfg(unix)]
#[test]
fn a_folder_above_the_launchagent_log_others_can_write_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let logs = cmux_server::fsx::local(&layout.logs());
    std::fs::create_dir_all(&logs).unwrap();
    for dir in logs.ancestors().take_while(|d| d.starts_with(tmp.path())) {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.preflight().unwrap();
    // Two levels above the log folder: above the state folder cmux checks.
    let above = logs.parent().unwrap().parent().unwrap();
    std::fs::set_permissions(above, std::fs::Permissions::from_mode(0o777)).unwrap();
    let err = svc.preflight().unwrap_err();
    assert!(err.to_string().contains(&above.display().to_string()), "{err}");
}

/// A symlink on the log's path (`~/Library` pointing at a shared disk)
/// puts the log under folders the written path never names. When one of
/// them is writable by another account, install refuses it (Codex R-004).
#[cfg(unix)]
#[test]
fn a_folder_above_the_launchagent_log_through_a_symlink_others_can_write_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let shared = tmp.path().join("shared");
    let real = shared.join("home");
    std::fs::create_dir_all(&real).unwrap();
    let home = tmp.path().join("home");
    std::os::unix::fs::symlink(&real, &home).unwrap();
    let layout = layout_at(&home, Platform::MacOs);
    let logs = cmux_server::fsx::local(&layout.logs());
    std::fs::create_dir_all(&logs).unwrap();
    for dir in [tmp.path(), &shared, &real] {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &home.join(".local/bin/cmux-tui"));
    svc.preflight().unwrap();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
    let err = svc.preflight().unwrap_err();
    let shown = std::fs::canonicalize(&shared).unwrap();
    assert!(err.to_string().contains(&shown.display().to_string()), "{err}");
}

/// A chain of symlinks (`~/Library` -> a link in a shared folder -> the
/// real folder): the middle link's folder is on the path too, though
/// neither the written path nor the resolved one names it. Another
/// account that can write it (mode or ACL) could repoint the middle link.
#[cfg(unix)]
#[test]
fn a_folder_of_a_middle_symlink_on_the_launchagent_log_path_others_can_write_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let shared = tmp.path().join("shared");
    let real = tmp.path().join("private").join("home");
    std::fs::create_dir_all(&real).unwrap();
    std::fs::create_dir(&shared).unwrap();
    std::os::unix::fs::symlink(&real, shared.join("hop")).unwrap();
    let home = tmp.path().join("home");
    std::os::unix::fs::symlink(shared.join("hop"), &home).unwrap();
    let layout = layout_at(&home, Platform::MacOs);
    let logs = cmux_server::fsx::local(&layout.logs());
    std::fs::create_dir_all(&logs).unwrap();
    for dir in [tmp.path(), &shared, &real, real.parent().unwrap()] {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &home.join(".local/bin/cmux-tui"));
    svc.preflight().unwrap();
    let shown = std::fs::canonicalize(&shared).unwrap().display().to_string();
    std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
    let err = svc.preflight().unwrap_err();
    assert!(err.to_string().contains(&shown), "{err}");
    #[cfg(target_os = "macos")]
    {
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o700)).unwrap();
        svc.preflight().unwrap();
        add_acl(&shared, "group:everyone allow add_file,delete_child");
        let err = svc.preflight().unwrap_err();
        assert!(err.to_string().contains(&shown) && err.to_string().contains("ACL"), "{err}");
    }
}

/// A name in the system's sticky `/tmp` that does not exist: a test home
/// or symlink target another account could make first.
#[cfg(unix)]
fn missing_in_tmp(tag: &str) -> PathBuf {
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let path = PathBuf::from(format!("/tmp/cmux-test-{tag}-{}-{nanos}", std::process::id()));
    assert!(std::fs::symlink_metadata(&path).is_err(), "{} exists", path.display());
    path
}

/// A folder of the log's path that does not exist yet, in a folder other
/// accounts can write (a home in `/tmp`): another account could make it
/// first and own it. Install refuses it and says to make it.
#[cfg(unix)]
#[test]
fn a_missing_folder_of_the_launchagent_log_under_a_shared_folder_is_refused() {
    if skip_as_root() {
        return;
    }
    let home = missing_in_tmp("home");
    let layout = layout_at(&home, Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &home.join(".local/bin/cmux-tui"));
    let err = svc.preflight().unwrap_err();
    let text = err.to_string();
    let shown = std::fs::canonicalize("/tmp").unwrap().join(home.file_name().unwrap());
    assert!(
        text.contains(&shown.display().to_string()) && text.contains("does not exist"),
        "{err}"
    );
}

/// A symlink on the log's path that points at a folder that does not
/// exist yet, in a folder other accounts can write: install would make
/// that folder there, and another account could make it first. Install
/// refuses it.
#[cfg(unix)]
#[test]
fn a_dangling_symlink_into_a_shared_folder_on_the_launchagent_log_path_is_refused() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let gone = missing_in_tmp("gone");
    let home = tmp.path().join("home");
    std::os::unix::fs::symlink(&gone, &home).unwrap();
    let layout = layout_at(&home, Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &home.join(".local/bin/cmux-tui"));
    let err = svc.preflight().unwrap_err();
    let shown = std::fs::canonicalize("/tmp").unwrap().join(gone.file_name().unwrap());
    let text = err.to_string();
    assert!(
        text.contains(&shown.display().to_string()) && text.contains("does not exist"),
        "{err}"
    );
}

/// A write handle another account opened on a unit file while it could
/// (a write grant since taken back, an ACL entry), kept open: install must
/// not keep that file as the unit, or the handle rewrites what the manager
/// loads at the next login or boot. The unit stays unchanged on disk as far
/// as the manager can tell (same bytes, same modification time).
#[cfg(unix)]
#[test]
fn install_never_keeps_a_unit_file_an_old_handle_can_write() {
    use std::io::Write as _;
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        let mut handle = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
        let report = svc.install(false).unwrap();
        assert!(!report.changed, "{platform:?}: the same unit counts as changed");
        handle.set_len(0).unwrap();
        handle.write_all(b"[Service]\nExecStart=/tmp/evil\n").unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            text,
            "{platform:?}: an old handle rewrote the unit install kept"
        );
        assert_eq!(
            std::fs::metadata(&path).unwrap().modified().unwrap(),
            modified,
            "{platform:?}: systemd would say the unit changed on disk"
        );
    }
}

/// The same handle at uninstall: the manager may read the unit file again
/// when it stops the service, so uninstall must stop it through a unit file
/// no old handle reaches. Bytes written through the handle then go nowhere,
/// and uninstall removes the unit it checked.
#[cfg(unix)]
#[test]
fn uninstall_stops_the_service_through_a_unit_file_no_old_handle_can_write() {
    use std::io::Write as _;
    use std::sync::{Arc, Mutex};
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        let handle = Mutex::new(std::fs::OpenOptions::new().write(true).open(&path).unwrap());
        let seen = Arc::new(Mutex::new(None::<String>));
        let (at, saw) = (path.clone(), seen.clone());
        runner.on_run(stop_step(platform), move || {
            let mut handle = handle.lock().unwrap();
            handle.set_len(0).unwrap();
            handle.write_all(b"[Service]\nExecStop=/tmp/evil\n").unwrap();
            *saw.lock().unwrap() = std::fs::read_to_string(&at).ok();
        });
        let removed = svc.uninstall();
        assert_eq!(
            seen.lock().unwrap().as_deref(),
            Some(text.as_str()),
            "{platform:?}: the manager would read what an old handle wrote at the stop"
        );
        assert_eq!(removed.unwrap(), vec![path.clone()], "{platform:?}");
        assert!(!path.exists(), "{platform:?}: the unit is left");
    }
}

/// Two `cmux server` commands at once (install while uninstall stops the
/// service) must not interleave: the second one refuses and changes
/// nothing, so uninstall never removes a unit the other just installed and
/// started, and install never reports a server that uninstall then removes.
#[test]
fn a_second_service_command_refuses_while_one_runs() {
    use std::sync::{Arc, Mutex};
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let binary = tmp.path().join(".local/bin/cmux-tui");
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        let second: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let (layout2, binary2, out) = (layout.clone(), binary.clone(), second.clone());
        runner.on_run(stop_step(platform), move || {
            // Another command: another thread (here) or another process.
            let (layout2, binary2) = (layout2.clone(), binary2.clone());
            let result = std::thread::spawn(move || {
                let other = RecordingRunner::new();
                other.answer_always("--property=LoadState", not_found());
                other.answer_always("launchctl print", not_loaded());
                let result = services(&layout2, &other, &binary2).install(true);
                let started = other.lines().iter().any(|l| {
                    l.contains("bootstrap") || l.contains(" start ") || l.contains("restart")
                });
                match result {
                    Ok(_) => format!("installed (started: {started})"),
                    Err(e) if !started => format!("refused: {e}"),
                    Err(e) => format!("failed after a start: {e}"),
                }
            })
            .join()
            .unwrap();
            *out.lock().unwrap() = Some(result);
        });
        svc.uninstall().unwrap();
        let second = second.lock().unwrap().clone().unwrap_or_default();
        assert!(
            second.starts_with("refused:") && second.contains("another"),
            "{platform:?}: the second command ran: {second}"
        );
        assert!(!svc.unit_path().unwrap().exists(), "{platform:?}");
    }
}

/// macOS: install keeps no ACL entry that lets another account write the
/// plist it leaves in place (the mode bits do not reach those entries).
#[cfg(target_os = "macos")]
#[test]
fn install_leaves_no_acl_write_grant_on_a_plist_it_keeps() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let path = svc.unit_path().unwrap();
    add_acl(&path, "group:everyone allow write");
    assert!(cmux_server::acl::write_grants(&path).unwrap());
    svc.install(false).unwrap();
    assert!(!cmux_server::acl::write_grants(&path).unwrap(), "the plist keeps the grant");
}

/// macOS: the record of the unit files cmux wrote decides what uninstall
/// removes. One another account can write through an ACL entry is refused
/// like one it can write through its mode.
#[cfg(target_os = "macos")]
#[test]
fn a_unit_record_others_can_write_through_an_acl_is_refused() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    svc.install(false).unwrap();
    let record = cmux_server::fsx::local(&layout.state).join("service-units.json");
    assert!(record.is_file());
    add_acl(&record, "group:everyone allow write");
    let err = svc.foreign_units().unwrap_err();
    assert!(err.to_string().contains("service-units.json"), "{err}");
}

/// The CLI holds the service lock for a whole verb and calls the steps that
/// take it again: the same thread may. Once the verb ends, it is free.
#[test]
fn a_command_holding_the_service_lock_runs_its_own_steps() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        {
            let _verb = svc.lock().unwrap();
            svc.install(false).unwrap();
            svc.uninstall().unwrap();
            // `uninstall --purge` removes the state folder while it holds
            // the lock: the lock must outlive that.
            std::fs::remove_dir_all(cmux_server::fsx::local(&layout.state)).unwrap();
            // Another thread is another command: refused while the verb runs.
            let (layout2, home) = (layout.clone(), tmp.path().to_path_buf());
            let other = std::thread::spawn(move || {
                let runner = RecordingRunner::new();
                services(&layout2, &runner, &home.join(".local/bin/cmux-tui"))
                    .lock()
                    .map(|_| ())
                    .map_err(|e| e.to_string())
            })
            .join()
            .unwrap();
            assert!(other.unwrap_err().contains("another"), "{platform:?}");
        }
        svc.install(false).unwrap();
    }
}

/// Old write handles on both the unit and the ownership record (Codex r28):
/// through them another account can write any unit bytes and a record hash
/// that matches them. What the manager may read at the stop must still be
/// text cmux renders, never those bytes.
#[cfg(unix)]
#[test]
fn uninstall_stops_through_cmuxs_own_text_even_with_a_forged_record() {
    use std::io::Write as _;
    use std::sync::{Arc, Mutex};
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        // Installed by an older binary path: its unit is cmux's by the record.
        services(&layout, &runner, &tmp.path().join("a/cmux-tui")).install(false).unwrap();
        let svc = services(&layout, &runner, &tmp.path().join("b/cmux-tui"));
        let (path, rendered) = svc.unit_files().unwrap().remove(0);
        let record = cmux_server::fsx::local(&layout.state).join("service-units.json");
        let mut unit = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        let mut forged = std::fs::OpenOptions::new().write(true).open(&record).unwrap();
        let evil = b"[Service]\nExecStop=/tmp/evil\n";
        unit.set_len(0).unwrap();
        unit.write_all(evil).unwrap();
        let json = serde_json::json!({ path.display().to_string(): sha_hex(evil) });
        forged.set_len(0).unwrap();
        forged.write_all(json.to_string().as_bytes()).unwrap();
        let seen = Arc::new(Mutex::new(None::<String>));
        let (at, saw) = (path.clone(), seen.clone());
        runner.on_run(stop_step(platform), move || {
            *saw.lock().unwrap() = std::fs::read_to_string(&at).ok();
        });
        svc.uninstall().unwrap();
        assert_eq!(
            seen.lock().unwrap().as_deref(),
            Some(rendered.as_str()),
            "{platform:?}: the manager could read forged bytes at the stop"
        );
        assert!(!path.exists(), "{platform:?}: the unit is left");
    }
}

/// Uninstall checks every unit file before it renews any (Codex r28): one
/// that is no longer cmux's leaves all of them as they were.
#[cfg(unix)]
#[test]
fn uninstall_renews_no_unit_when_one_is_no_longer_cmuxs() {
    use std::os::unix::fs::MetadataExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = system_layout(tmp.path(), &tmp.path().join("state").display().to_string());
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    runner.answer_always("list-units", shows(""));
    let svc = system_services(&layout, &runner);
    let units = svc.unit_files().unwrap();
    assert!(units.len() > 2);
    for (path, text) in &units {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    let first = std::fs::metadata(&units[0].0).unwrap().ino();
    // A later unit is edited after the ownership check, before the renewal.
    let (late, text) = units[2].clone();
    let edit = late.clone();
    runner.on_run("--property=LoadState", move || {
        std::fs::write(&edit, format!("{text}\n# edited\n")).unwrap();
    });
    let before = runner.lines().len();
    let err = svc.uninstall().unwrap_err();
    assert!(err.to_string().contains(&late.display().to_string()), "{err}");
    assert_eq!(std::fs::metadata(&units[0].0).unwrap().ino(), first, "renewed a unit");
    let after = runner.lines()[before..].to_vec();
    assert!(
        !after.iter().any(|l| l.contains(" kill ") || l.contains("disable --now")),
        "stopped something: {after:?}"
    );
}

/// Another account can open a folder it may read (`/etc/systemd/system`,
/// most `~/.config/systemd/user`) and hold a `flock` on it (Codex r28b):
/// that must not stop cmux's service commands. The lock is a file of this
/// account's that no one else can open, kept while a unit is installed and
/// removed with the last one.
#[cfg(unix)]
#[test]
fn the_service_lock_is_a_private_file_no_other_account_can_hold() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
        let dir = svc.unit_path().unwrap().parent().unwrap().to_path_buf();
        std::fs::create_dir_all(&dir).unwrap();
        // What any account that can read the folder could do.
        let folder = std::fs::File::open(&dir).unwrap();
        folder.try_lock().unwrap();
        svc.install(false).unwrap();
        let lock = dir.join(".cmux-server.lock");
        let mode = std::fs::metadata(&lock).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "{platform:?}");
        svc.uninstall().unwrap();
        assert!(!lock.exists(), "{platform:?}: the lock file outlived the last unit");
        folder.unlock().unwrap();
    }
}

/// macOS: a folder ACL entry that passes read on to new files (Codex r28c)
/// would let another account open the lock file and hold a shared lock on
/// it, even if the entry were taken away right after the file was made. The
/// command refuses, leaves no such lock file and says how to fix the folder;
/// once the folder passes nothing on, it works.
#[cfg(target_os = "macos")]
#[test]
fn a_service_lock_file_others_could_open_is_refused_and_removed() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    let dir = svc.unit_path().unwrap().parent().unwrap().to_path_buf();
    std::fs::create_dir_all(&dir).unwrap();
    add_acl(&dir, "group:everyone allow read,file_inherit");
    let err = svc.install(false).unwrap_err().to_string();
    assert!(err.contains("chmod -N"), "{err}");
    assert!(!dir.join(".cmux-server.lock").exists(), "left a lock file others can open");
    assert!(!svc.unit_path().unwrap().exists(), "installed anyway");
    let status = std::process::Command::new("/bin/chmod").arg("-N").arg(&dir).status().unwrap();
    assert!(status.success());
    svc.install(false).unwrap();
    let listed = std::process::Command::new("/bin/ls")
        .arg("-le")
        .arg(dir.join(".cmux-server.lock"))
        .output()
        .unwrap();
    let listed = String::from_utf8_lossy(&listed.stdout);
    assert!(!listed.contains(" allow "), "{listed}");
}

/// macOS: a lock file with an ACL entry is removed only while cmux holds it
/// itself and it is still the file at the name (Codex r28e): one that
/// another descriptor holds stays, and the command says to remove it.
#[cfg(target_os = "macos")]
#[test]
fn a_held_service_lock_file_with_an_acl_entry_is_left_for_the_user() {
    use std::os::unix::fs::PermissionsExt as _;
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let svc = services(&layout, &runner, &tmp.path().join(".local/bin/cmux-tui"));
    let dir = svc.unit_path().unwrap().parent().unwrap().to_path_buf();
    std::fs::create_dir_all(&dir).unwrap();
    let lock = dir.join(".cmux-server.lock");
    std::fs::write(&lock, b"").unwrap();
    std::fs::set_permissions(&lock, std::fs::Permissions::from_mode(0o600)).unwrap();
    add_acl(&lock, "group:everyone allow read");
    // What another account that opened it could hold.
    let other = std::fs::File::open(&lock).unwrap();
    other.lock_shared().unwrap();
    let err = svc.install(false).unwrap_err().to_string();
    assert!(err.contains(&format!("rm {}", lock.display())), "{err}");
    assert!(lock.exists(), "removed a lock file another descriptor holds");
    other.unlock().unwrap();
    let err = svc.install(false).unwrap_err().to_string();
    assert!(err.contains("chmod -N") && !err.contains("`rm "), "{err}");
    assert!(!lock.exists(), "kept a lock file others can open");
    svc.install(false).unwrap();
}

/// A session binary file where install places it (`.local/bin/cmux-tui`).
fn session_binary(home: &Path) -> PathBuf {
    let binary = home.join(".local/bin/cmux-tui");
    session_binary_at(&binary);
    binary
}

fn session_binary_at(binary: &Path) {
    std::fs::create_dir_all(binary.parent().unwrap()).unwrap();
    std::fs::write(binary, b"#!/bin/sh\n").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(binary, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

/// Terminal hosts run in sessions of their own and ignore a SIGTERM that is
/// not from PID 1, so launchd's bootout and `systemctl --user kill` both left
/// the shells (seen on a fleet Mac and a Linux runner: a later install's
/// daemon adopted them). Once the manager stopped the service, uninstall
/// starts the session's daemon outside it, which adopts them, and stops it
/// with `--end-terminals`; then it removes the unit file.
#[test]
fn uninstall_ends_the_sessions_terminals_after_the_service_stopped() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let binary = session_binary(tmp.path());
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        let path = svc.unit_path().unwrap();
        svc.uninstall().unwrap();
        assert!(!path.exists(), "{platform:?}: the unit file is left");
        let lines = runner.lines();
        let at = |needle: &str| {
            lines.iter().position(|l| l.contains(needle)).unwrap_or_else(|| {
                panic!("{platform:?}: no `{needle}` in {lines:#?}");
            })
        };
        let stopped = at(stop_step(platform));
        let ensure = at(&format!("{} daemon ensure --session main", binary.display()));
        let stop = at(&format!("{} daemon stop --session main --end-terminals", binary.display()));
        assert!(stopped < ensure && ensure < stop, "{platform:?}: {lines:#?}");
        if platform == Platform::Linux {
            // Whatever is left is signalled after, then checked to be gone.
            let kill = at("kill --kill-whom=all");
            assert!(stop < kill, "{lines:#?}");
        }
        // With the HOME the manager gives the service (the user database's),
        // not this process's: the daemon's state, and so its terminals, live
        // under it.
        let home = cmux_server::sys::home_dir(uid()).unwrap();
        for at in [ensure, stop] {
            let cmd = &runner.commands()[at];
            assert!(
                cmd.env.iter().any(|(k, v)| k == "HOME" && Path::new(v) == home),
                "{}: {:?}",
                cmd.display(),
                cmd.env
            );
        }
    }
}

/// A stop that could not end the terminals leaves the unit file: the shells
/// may still run, and the next uninstall must still know the session to end
/// them.
#[test]
fn uninstall_removes_nothing_when_the_terminals_did_not_end() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let binary = session_binary(tmp.path());
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        runner.answer("--end-terminals", Output { code: Some(1), ..Output::default() });
        let err = svc.uninstall().unwrap_err();
        assert!(err.to_string().contains("removed nothing"), "{platform:?}: {err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}: it went");
        // Run again, it ends them and removes the unit file.
        svc.uninstall().unwrap();
        assert!(!path.exists(), "{platform:?}");
    }
}

/// A session binary that is gone cannot start the daemon that ends the
/// terminals (the hosts may run on from the deleted file): uninstall refuses
/// before it stops anything, and says how to put it back.
#[test]
fn uninstall_changes_nothing_when_the_session_binary_is_gone() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let binary = session_binary(tmp.path());
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        let (path, text) = svc.unit_files().unwrap().remove(0);
        let inode = std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(&path).unwrap());
        std::fs::remove_file(&binary).unwrap();
        let before = runner.lines().len();
        let err = svc.uninstall().unwrap_err().to_string();
        assert!(err.contains("is gone") && err.contains("cmux server install"), "{err}");
        assert!(err.contains("nothing was changed"), "{platform:?}: {err}");
        let lines = &runner.lines()[before..];
        assert!(
            !lines.iter().any(|l| l.contains(stop_step(platform)) || l.contains("kill")),
            "{platform:?}: stopped something: {lines:#?}"
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}");
        // Not even renewed: the refusal comes before every change.
        let now = std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(&path).unwrap());
        assert_eq!(now, inode, "{platform:?}: the unit file was rewritten");
    }
}

/// Another account that may write the folder of the session binary could
/// swap the file uninstall runs: uninstall refuses before it stops anything.
#[test]
fn uninstall_changes_nothing_when_the_session_binary_folder_is_shared() {
    if skip_as_root() {
        return;
    }
    use std::os::unix::fs::PermissionsExt as _;
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        let binary = session_binary(tmp.path());
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        let path = svc.unit_path().unwrap();
        let folder = binary.parent().unwrap();
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o777)).unwrap();
        let before = runner.lines().len();
        let err = svc.uninstall().unwrap_err().to_string();
        assert!(err.contains("nothing was changed") && err.contains("mode 777"), "{err}");
        let lines = &runner.lines()[before..];
        assert!(
            !lines.iter().any(|l| l.contains(stop_step(platform)) || l.contains("daemon ensure")),
            "{platform:?}: {lines:#?}"
        );
        assert!(path.exists(), "{platform:?}");
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
}

/// The service's daemon got the state variables of its manager (or of a
/// unit drop-in), not of the shell that runs uninstall (a
/// `CMUX_TUI_STATE_DIR` exported there would point the sweep at other,
/// empty state). With no daemon running, the sweep takes them as the
/// manager now gives a service, byte for byte: systemd quotes a value with
/// special characters (`$'...'`), launchd ends it with a newline.
#[test]
fn uninstall_ends_the_terminals_with_the_state_env_of_the_service_manager() {
    if skip_as_root() {
        return;
    }
    let want = "/srv/cmux state's ";
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        runner.answer_always(
            "show-environment",
            shows("PATH=/usr/bin\nCMUX_TUI_STATE_DIR=$'/srv/cmux state\\'s '\n"),
        );
        runner.answer_always("launchctl getenv CMUX_TUI_STATE_DIR", shows(&format!("{want}\n")));
        let binary = session_binary(tmp.path());
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        svc.uninstall().unwrap();
        let commands = runner.commands();
        let sweeps: Vec<_> = commands.iter().filter(|c| c.display().contains(" daemon ")).collect();
        assert_eq!(sweeps.len(), 2, "{platform:?}: {:#?}", runner.lines());
        let home = cmux_server::sys::home_dir(uid()).unwrap();
        for cmd in sweeps {
            let env = |key: &str| cmd.env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
            assert_eq!(env("CMUX_TUI_STATE_DIR"), Some(want.into()), "{platform:?}");
            assert_eq!(env("HOME"), Some(home.clone().into()), "{platform:?}");
            assert!(
                cmd.env_remove.iter().any(|k| k == "XDG_STATE_HOME")
                    && env("XDG_STATE_HOME").is_none(),
                "{platform:?} {}: an unset variable must not come from this shell: {:?}",
                cmd.display(),
                cmd.env_remove
            );
        }
    }
}

/// The pid the service manager names for the session daemon, and what
/// `daemon status` answers on the session's socket.
fn run_daemon(runner: &RecordingRunner, svc: &Services<'_>, platform: Platform, pid: u32) {
    match platform {
        Platform::MacOs => {
            let print = shows(&format!(
                "gui/501/com.cmux.server = {{\n\tpath = {}\n\tstate = running\n\tpid = {pid}\n}}\n",
                svc.unit_path().unwrap().display()
            ));
            // The source checks, then the pid (one spare is read by the wait
            // for the bootout, which then sees the job gone).
            for _ in 0..3 {
                runner.answer("launchctl print", print.clone());
            }
        }
        _ => runner.answer("--property=MainPID", shows(&format!("{pid}\n"))),
    }
}

fn daemon_says(status: &str, session: &str, pid: u32) -> Output {
    shows(&format!("{{\"status\":\"{status}\",\"session\":\"{session}\",\"pid\":{pid}}}\n"))
}

/// While the service's daemon runs, it ends its own terminals: uninstall
/// asks it over the session's socket (`daemon status` must answer with the
/// pid the manager names), has it stop with `--end-terminals`, and only then
/// has the manager stop the service. The daemon knows its own state, so
/// uninstall reads nothing of its process (no process scanning:
/// plans/cmux-next/pty-holder.md section 4) and sets no state variable.
#[test]
fn uninstall_has_the_running_daemon_end_its_terminals_before_the_service_stops() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        let tmp = tempfile::tempdir().unwrap();
        let layout = layout_at(tmp.path(), platform);
        let runner = RecordingRunner::new();
        runner.answer_always("--property=LoadState", not_found());
        runner.answer_always("launchctl print", not_loaded());
        runner.answer_always("show-environment", shows("CMUX_TUI_STATE_DIR=/srv/manager\n"));
        runner.answer_always("launchctl getenv CMUX_TUI_STATE_DIR", shows("/srv/manager\n"));
        let binary = session_binary(tmp.path());
        let svc = services(&layout, &runner, &binary);
        svc.install(false).unwrap();
        let path = svc.unit_path().unwrap();
        run_daemon(&runner, &svc, platform, 4242);
        runner.answer("daemon status --session main", daemon_says("running", "main", 4242));
        runner.answer("--end-terminals", daemon_says("stopped", "main", 4242));
        svc.uninstall().unwrap();
        assert!(!path.exists(), "{platform:?}: the unit file is left");
        let lines = runner.lines();
        let at = |needle: &str| {
            lines.iter().position(|l| l.contains(needle)).unwrap_or_else(|| {
                panic!("{platform:?}: no `{needle}` in {lines:#?}");
            })
        };
        let status = at(&format!("{} daemon status --session main --json", binary.display()));
        let end =
            at(&format!("{} daemon stop --session main --end-terminals --json", binary.display()));
        let stopped = at(stop_step(platform));
        assert!(status < end && end < stopped, "{platform:?}: {lines:#?}");
        // Then what a daemon the manager restarted meanwhile started ends
        // too (launchd restarts a KeepAlive job at once), with the manager's
        // state variables: the ones that daemon got.
        let ensure = at(&format!("{} daemon ensure --session main", binary.display()));
        let sweep = lines
            .iter()
            .rposition(|l| l.contains("--end-terminals"))
            .filter(|&i| i > ensure)
            .unwrap_or_else(|| panic!("{platform:?}: no sweep after the stop: {lines:#?}"));
        assert!(stopped < ensure, "{platform:?}: {lines:#?}");
        let cmd = &runner.commands()[sweep];
        assert!(
            cmd.env.iter().any(|(k, v)| k == "CMUX_TUI_STATE_DIR" && v == "/srv/manager"),
            "{platform:?}: {:?}",
            cmd.env
        );
        for at in [status, end] {
            let cmd = &runner.commands()[at];
            // The daemon's own state: none set here, and no socket of a
            // terminal this command may run in.
            assert!(
                !cmd.env.iter().any(|(k, _)| k == "CMUX_TUI_STATE_DIR" || k == "HOME"),
                "{platform:?} {}: {:?}",
                cmd.display(),
                cmd.env
            );
            assert!(
                ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"]
                    .iter()
                    .all(|k| cmd.env_remove.iter().any(|r| r == k)),
                "{platform:?} {}: {:?}",
                cmd.display(),
                cmd.env_remove
            );
        }
    }
}

/// The daemon that answers on the session's socket must be the one the
/// manager runs for the service: another pid (a daemon of the session the
/// app started, or the service's daemon behind a socket of its own), another
/// session, or no answer (this shell reaches another socket folder) would
/// leave the service's terminals or end others. Uninstall refuses before it
/// changes anything.
#[test]
fn uninstall_changes_nothing_when_the_running_daemon_does_not_answer_as_the_services() {
    if skip_as_root() {
        return;
    }
    let unavailable = Output {
        code: Some(3),
        stdout: br#"{"code":"server.unavailable","message":"no daemon"}"#.to_vec(),
        ..Output::default()
    };
    let answers = [
        ("another pid", daemon_says("running", "main", 999)),
        ("another session", daemon_says("running", "other", 4242)),
        ("not running", daemon_says("not_running", "main", 0)),
        ("unavailable", unavailable),
    ];
    for platform in [Platform::Linux, Platform::MacOs] {
        for (case, answer) in &answers {
            let tmp = tempfile::tempdir().unwrap();
            let layout = layout_at(tmp.path(), platform);
            let runner = RecordingRunner::new();
            runner.answer_always("--property=LoadState", not_found());
            runner.answer_always("launchctl print", not_loaded());
            let binary = session_binary(tmp.path());
            let svc = services(&layout, &runner, &binary);
            svc.install(false).unwrap();
            let (path, text) = svc.unit_files().unwrap().remove(0);
            run_daemon(&runner, &svc, platform, 4242);
            runner.answer("daemon status", answer.clone());
            let before = runner.lines().len();
            let err = svc.uninstall().unwrap_err().to_string();
            assert!(
                err.contains("pid 4242") && err.contains("nothing was changed"),
                "{platform:?} {case}: {err}"
            );
            let lines = &runner.lines()[before..];
            assert!(
                !lines.iter().any(|l| l.contains(stop_step(platform))
                    || l.contains("--end-terminals")
                    || l.contains("daemon ensure")),
                "{platform:?} {case}: {lines:#?}"
            );
            assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?} {case}");
        }
    }
}

/// A running daemon that did not end its terminals (its stop failed, or
/// another daemon answered it): the service is left as it is, unit files
/// included, so the command can run again.
#[test]
fn uninstall_removes_nothing_when_the_running_daemon_did_not_end_its_terminals() {
    if skip_as_root() {
        return;
    }
    let failed = Output { code: Some(1), ..Output::default() };
    for platform in [Platform::Linux, Platform::MacOs] {
        for answer in [failed.clone(), daemon_says("stopped", "main", 999)] {
            let tmp = tempfile::tempdir().unwrap();
            let layout = layout_at(tmp.path(), platform);
            let runner = RecordingRunner::new();
            runner.answer_always("--property=LoadState", not_found());
            runner.answer_always("launchctl print", not_loaded());
            let binary = session_binary(tmp.path());
            let svc = services(&layout, &runner, &binary);
            svc.install(false).unwrap();
            let (path, text) = svc.unit_files().unwrap().remove(0);
            run_daemon(&runner, &svc, platform, 4242);
            runner.answer("daemon status", daemon_says("running", "main", 4242));
            runner.answer("--end-terminals", answer.clone());
            let before = runner.lines().len();
            let err = svc.uninstall().unwrap_err().to_string();
            assert!(err.contains("removed nothing"), "{platform:?}: {err}");
            let lines = &runner.lines()[before..];
            assert!(
                !lines.iter().any(|l| l.contains(stop_step(platform))),
                "{platform:?}: {lines:#?}"
            );
            assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}");
        }
    }
}

/// `disable --now` that left the daemon running (it failed, or the unit
/// restarted): a daemon still running could start terminals after the
/// sweep, which the kill then cannot end. Uninstall stops there and removes
/// nothing.
#[test]
fn uninstall_ends_no_terminals_while_systemd_still_runs_the_daemon() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    let binary = session_binary(tmp.path());
    let svc = services(&layout, &runner, &binary);
    svc.install(false).unwrap();
    let path = svc.unit_path().unwrap();
    runner.answer("--property=ActiveState", shows("active\n"));
    let err = svc.uninstall().unwrap_err().to_string();
    assert!(err.contains("did not stop") && err.contains("removed nothing"), "{err}");
    assert!(!runner.lines().iter().any(|l| l.contains("daemon ensure")), "{:#?}", runner.lines());
    assert!(path.exists());
}

/// launchd could not say whether it runs the daemon (`launchctl print`
/// failed once, after the source check passed): that must not read as "no
/// daemon runs", or the sweep would take the manager's environment for the
/// state of a daemon that has its own. Uninstall refuses before it changes
/// anything.
#[test]
fn uninstall_changes_nothing_when_launchd_cannot_say_whether_the_daemon_runs() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer_always("launchctl print", not_loaded());
    let binary = session_binary(tmp.path());
    let svc = services(&layout, &runner, &binary);
    svc.install(false).unwrap();
    let path = svc.unit_path().unwrap();
    let inode = std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(&path).unwrap());
    // The source check, then the pid.
    runner.answer("launchctl print", not_loaded());
    runner.answer("launchctl print", Output { code: Some(5), ..Output::default() });
    let before = runner.lines().len();
    let err = svc.uninstall().unwrap_err().to_string();
    assert!(
        err.contains("cannot tell whether launchd runs") && err.contains("nothing was changed"),
        "{err}"
    );
    let lines = &runner.lines()[before..];
    assert!(!lines.iter().any(|l| l.contains("bootout") || l.contains(" daemon ")), "{lines:#?}");
    let now = std::os::unix::fs::MetadataExt::ino(&std::fs::metadata(&path).unwrap());
    assert_eq!(now, inode, "the unit file was rewritten");
}

/// `daemon ensure` swaps in, and first runs, a build staged beside the
/// session binary: one another account may write is refused like the
/// binary, before anything changes.
#[test]
fn uninstall_changes_nothing_when_a_staged_build_is_shared() {
    if skip_as_root() {
        return;
    }
    use std::os::unix::fs::PermissionsExt as _;
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    let binary = session_binary(tmp.path());
    let svc = services(&layout, &runner, &binary);
    svc.install(false).unwrap();
    let staged = binary.with_file_name("cmux-tui.staged");
    std::fs::write(&staged, b"#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o777)).unwrap();
    let before = runner.lines().len();
    let err = svc.uninstall().unwrap_err().to_string();
    assert!(err.contains("staged") && err.contains("nothing was changed"), "{err}");
    let lines = &runner.lines()[before..];
    assert!(
        !lines.iter().any(|l| l.contains("disable --now") || l.contains(" daemon ")),
        "{lines:#?}"
    );
}

/// The sweep's `daemon ensure` found a daemon of the session it did not
/// start (one the app started outside the service, or a wedged one it
/// replaced): that daemon holds the terminals as its own, so the sweep
/// leaves it and them, and uninstall goes on.
#[test]
fn uninstall_leaves_a_daemon_of_the_session_it_did_not_start() {
    if skip_as_root() {
        return;
    }
    for platform in [Platform::Linux, Platform::MacOs] {
        for status in ["running", "replaced"] {
            let tmp = tempfile::tempdir().unwrap();
            let layout = layout_at(tmp.path(), platform);
            let runner = RecordingRunner::new();
            runner.answer_always("--property=LoadState", not_found());
            runner.answer_always("launchctl print", not_loaded());
            let binary = session_binary(tmp.path());
            let svc = services(&layout, &runner, &binary);
            svc.install(false).unwrap();
            let path = svc.unit_path().unwrap();
            runner.answer("daemon ensure", daemon_says(status, "main", 555));
            let before = runner.lines().len();
            svc.uninstall().unwrap();
            let lines = &runner.lines()[before..];
            assert!(
                lines.iter().any(|l| l.contains("daemon ensure"))
                    && !lines.iter().any(|l| l.contains("--end-terminals")),
                "{platform:?} {status}: {lines:#?}"
            );
            assert!(!path.exists(), "{platform:?} {status}");
        }
    }
}

/// A state path relative to the daemon's working folder cannot be followed
/// from another: with no daemon running, uninstall refuses a relative path
/// the manager gives before it changes anything.
#[test]
fn uninstall_ends_no_terminals_with_a_relative_state_path() {
    if skip_as_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    runner.answer_always("--property=LoadState", not_found());
    runner.answer_always("show-environment", shows("CMUX_TUI_STATE_DIR=srv/state\n"));
    let binary = session_binary(tmp.path());
    let svc = services(&layout, &runner, &binary);
    svc.install(false).unwrap();
    let before = runner.lines().len();
    let err = svc.uninstall().unwrap_err().to_string();
    assert!(err.contains("relative path") && err.contains("nothing was changed"), "{err}");
    let lines = &runner.lines()[before..];
    assert!(
        !lines.iter().any(|l| l.contains("disable --now") || l.contains(" daemon ")),
        "{lines:#?}"
    );
}
