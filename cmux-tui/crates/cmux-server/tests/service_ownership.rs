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

fn services<'a>(layout: &'a Layout, runner: &'a RecordingRunner, binary: &Path) -> Services<'a> {
    stopped(runner);
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
    assert!(
        !runner.lines().iter().any(|l| l.contains("disable --now cmux-server.service")),
        "stopped a unit that is no longer cmux's: {:?} ({err})",
        runner.lines()
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
                runner.answer("launchctl print", shows(&format!("path = {}\n", plist.display())));
            }
        });
        let err = svc.uninstall().unwrap_err();
        assert!(err.to_string().contains("removed nothing"), "{platform:?}: {err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text, "{platform:?}: removed it");
    }
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
