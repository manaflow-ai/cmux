//! Service units are written from core renderers, registered through the
//! service manager (recorded), and removed on uninstall while state stays.

mod common;

use std::fs;

use cmux_server::process::{Output, RecordingRunner};
use cmux_server::service::Services;
use cmux_server_core::Platform;
use cmux_server_core::units::{launch_agent_plist, systemd_user_unit};
use common::*;

fn services<'a>(
    layout: &'a cmux_server_core::layout::Layout,
    runner: &'a RecordingRunner,
) -> Services<'a> {
    Services { layout, runner, uid: 4242, user: "ana".to_owned() }
}

fn yes() -> Output {
    Output { code: Some(0), stdout: b"yes\n".to_vec(), stderr: Vec::new() }
}

#[test]
fn systemd_user_install_writes_core_unit_and_starts_it() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    runner.answer("loginctl show-user ana", yes());
    runner.answer("is-active", Output { code: Some(3), ..Output::default() });
    let report = services(&layout, &runner).install(false).unwrap();
    let unit = tmp.path().join(".config/systemd/user/cmux-server.service");
    assert_eq!(report.unit, unit);
    assert!(report.changed);
    assert_eq!(report.linger, Some(true));
    assert_eq!(fs::read_to_string(&unit).unwrap(), systemd_user_unit(&layout).unwrap());
    let lines = runner.lines();
    let systemctl: Vec<&String> = lines.iter().filter(|l| l.starts_with("systemctl")).collect();
    assert_eq!(
        systemctl,
        [
            "systemctl --user daemon-reload",
            "systemctl --user enable cmux-server.service",
            "systemctl --user is-active --quiet cmux-server.service",
            "systemctl --user start cmux-server.service"
        ]
    );
    assert!(lines.iter().all(|l| !l.contains("sudo")), "never sudo: {lines:?}");

    // A second install with the same unit does not reload; a restart
    // request restarts the active unit.
    let runner = RecordingRunner::new();
    runner.answer("loginctl show-user ana", yes());
    let report = services(&layout, &runner).install(true).unwrap();
    assert!(!report.changed && report.restarted);
    let lines = runner.lines();
    assert!(!lines.iter().any(|l| l.contains("daemon-reload")), "{lines:?}");
    assert!(lines.iter().any(|l| l == "systemctl --user restart cmux-server.service"), "{lines:?}");

    // A changed unit restarts a running server even without a new
    // generation (daemon-reload alone does not apply it).
    fs::write(&unit, "stale").unwrap();
    let runner = RecordingRunner::new();
    let report = services(&layout, &runner).install(false).unwrap();
    assert!(report.changed && report.restarted);
    assert_eq!(fs::read_to_string(&unit).unwrap(), systemd_user_unit(&layout).unwrap());
}

#[test]
fn system_uninstall_stops_app_servers_without_prompting() {
    use cmux_server_core::InstallMode;
    use cmux_server_core::layout::layout;
    let system = layout(InstallMode::System, Platform::Linux, &Default::default()).unwrap();
    let runner = RecordingRunner::new();
    services(&system, &runner).uninstall().unwrap();
    let lines = runner.lines();
    let stop = lines
        .iter()
        .position(|l| l == "systemctl --no-ask-password stop cmux-app-server@*.service")
        .unwrap_or_else(|| panic!("{lines:?}"));
    let reload = lines.iter().position(|l| l.ends_with("daemon-reload")).unwrap();
    assert!(stop < reload, "{lines:?}");
    assert!(lines.iter().all(|l| l.starts_with("systemctl --no-ask-password")), "{lines:?}");
}

#[test]
fn linger_refused_reports_the_sudo_command_and_never_runs_it() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    let no = Output { code: Some(0), stdout: b"no\n".to_vec(), stderr: Vec::new() };
    runner.answer("loginctl show-user ana", no.clone());
    runner.answer("loginctl enable-linger ana", Output { code: Some(1), ..Output::default() });
    runner.answer("loginctl show-user ana", no);
    let report = services(&layout, &runner).install(false).unwrap();
    assert_eq!(report.linger, Some(false));
    assert!(
        report.warnings[0].contains("sudo loginctl enable-linger ana"),
        "{:?}",
        report.warnings
    );
    assert!(runner.lines().iter().all(|l| !l.starts_with("sudo")));
}

#[test]
fn uninstall_removes_units_and_keeps_state() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::Linux);
    let runner = RecordingRunner::new();
    let svc = services(&layout, &runner);
    svc.install(false).unwrap();
    let state = tmp.path().join(".local/state/cmux/server");
    fs::create_dir_all(state.join("postgres")).unwrap();
    fs::write(state.join("postgres/admin.pgpass"), "secret").unwrap();
    let removed = svc.uninstall().unwrap();
    assert_eq!(removed, [tmp.path().join(".config/systemd/user/cmux-server.service")]);
    assert!(state.join("postgres/admin.pgpass").is_file(), "state is kept");
    let lines = runner.lines();
    assert!(lines.iter().any(|l| l == "systemctl --user kill --kill-whom=all cmux-server.service"));
    assert!(lines.iter().any(|l| l == "systemctl --user disable --now cmux-server.service"));
    // Uninstall twice is fine.
    assert!(svc.uninstall().unwrap().is_empty());
}

#[test]
fn launch_agent_install_bootstraps_gui_domain() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = layout_at(tmp.path(), Platform::MacOs);
    let runner = RecordingRunner::new();
    runner.answer("launchctl print", Output { code: Some(113), ..Output::default() });
    let svc = services(&layout, &runner);
    let report = svc.install(false).unwrap();
    let plist = tmp.path().join("Library/LaunchAgents/com.cmux.server.plist");
    assert_eq!(report.unit, plist);
    assert_eq!(fs::read_to_string(&plist).unwrap(), launch_agent_plist(&layout).unwrap());
    let lines = runner.lines();
    assert!(
        lines.iter().any(|l| l == &format!("launchctl bootstrap gui/4242 {}", plist.display())),
        "{lines:?}"
    );
    let runner = RecordingRunner::new();
    let removed = services(&layout, &runner).uninstall().unwrap();
    assert_eq!(removed, [plist]);
    assert_eq!(runner.lines()[0], "launchctl bootout gui/4242/com.cmux.server");
}

#[test]
fn system_layouts_render_all_units() {
    use cmux_server_core::InstallMode;
    use cmux_server_core::layout::layout;
    let system = layout(InstallMode::System, Platform::Linux, &Default::default()).unwrap();
    let runner = RecordingRunner::new();
    let svc = services(&system, &runner);
    let names: Vec<String> = svc
        .unit_files()
        .unwrap()
        .into_iter()
        .map(|(p, _)| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        names,
        [
            "cmux-server.service",
            "cmux-update.path",
            "cmux-update.service",
            "cmux-app-server@.service"
        ]
    );
}
