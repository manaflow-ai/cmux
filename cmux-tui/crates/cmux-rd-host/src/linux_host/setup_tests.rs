use super::*;

#[test]
fn the_join_lines_are_the_contract() {
    assert_eq!(
        virtual_display_line(99),
        "no graphical session on this machine; shares use a virtual display at :99, started when one is needed"
    );
    assert_eq!(
        CANT_REMEMBER,
        "this desktop's screen-share portal can't remember a grant; each share will ask once on this machine"
    );
    assert_eq!(VIEW_ONLY, "view only: this desktop has no remote-input portal");
}

#[test]
fn logind_finds_a_desktop_the_environment_of_ssh_does_not_have() {
    let wayland = "Type=wayland\nClass=user\nDisplay=\n".to_owned();
    let x11 = "Type=x11\nClass=user\nDisplay=:0\n".to_owned();
    let ssh = "Type=tty\nClass=user\nDisplay=\n".to_owned();
    let greeter = "Type=wayland\nClass=greeter\n".to_owned();
    // Over ssh: no WAYLAND_DISPLAY or DISPLAY, a tty session of its own.
    assert_eq!(
        choose_desktop(Some("tty"), None, None, None, &[ssh.clone(), wayland.clone()]),
        Desktop::Wayland
    );
    assert_eq!(
        choose_desktop(None, None, None, None, &[ssh.clone(), x11.clone()]),
        Desktop::X11(Some(":0".into()))
    );
    assert_eq!(choose_desktop(None, None, None, None, &[x11, wayland]), Desktop::Wayland);
    // The login screen is not this user's desktop.
    assert_eq!(choose_desktop(None, None, None, None, &[ssh.clone(), greeter]), Desktop::None);
    assert_eq!(choose_desktop(None, None, None, None, &[ssh]), Desktop::None);
    assert_eq!(choose_desktop(None, None, None, None, &[]), Desktop::None);
    // The environment of a session on the desktop wins.
    assert_eq!(choose_desktop(Some("wayland"), None, None, None, &[]), Desktop::Wayland);
    assert_eq!(choose_desktop(None, Some("wayland-0"), None, None, &[]), Desktop::Wayland);
    assert_eq!(
        choose_desktop(Some("x11"), None, Some(":1"), None, &[]),
        Desktop::X11(Some(":1".into()))
    );
    assert_eq!(choose_desktop(None, Some(""), Some(" "), None, &[]), Desktop::None);
}

#[test]
fn the_virtual_display_cmux_runs_here_is_no_desktop() {
    // The join's environment.d puts DISPLAY=:99 in the user manager; the daemon's next
    // `enable` read it as an X11 desktop and installed a host unit that never started.
    assert_eq!(choose_desktop(None, None, Some(":99"), Some(99), &[]), Desktop::None);
    assert_eq!(choose_desktop(None, None, Some(":99.0"), Some(99), &[]), Desktop::None);
    // Another display is still the person's desktop, and so is :99 with no virtual display.
    assert_eq!(
        choose_desktop(None, None, Some(":0"), Some(99), &[]),
        Desktop::X11(Some(":0".into()))
    );
    assert_eq!(
        choose_desktop(None, None, Some(":99"), None, &[]),
        Desktop::X11(Some(":99".into()))
    );
    // A logind desktop still wins over the virtual display.
    let x11 = "Type=x11\nClass=user\nDisplay=:0\n".to_owned();
    assert_eq!(
        choose_desktop(None, None, Some(":99"), Some(99), &[x11]),
        Desktop::X11(Some(":0".into()))
    );
}

#[test]
fn a_headless_machine_with_its_virtual_display_in_display_gets_the_headless_unit() {
    // set_up_for_join: `virtual_display = desktop == Desktop::None`, then install_host.
    let desktop = choose_desktop(None, None, Some(":99"), Some(99), &[]);
    let unit = host_unit_text(desktop == Desktop::None);
    assert!(!unit.contains("graphical-session"), "{unit}");
    assert!(unit.contains("\nWantedBy=default.target\n"), "{unit}");
    // A person's desktop keeps the unit tied to its graphical session.
    let desktop = choose_desktop(None, None, Some(":0"), Some(99), &[]);
    assert!(
        host_unit_text(desktop == Desktop::None).contains("\nRequisite=graphical-session.target\n")
    );
}

#[test]
fn display_numbers_are_read_from_local_names_only() {
    assert_eq!(display_number(":99"), Some(99));
    assert_eq!(display_number(":1.0"), Some(1));
    assert_eq!(display_number("unix:7"), Some(7));
    assert_eq!(display_number("remote:3"), None);
    assert_eq!(display_number(""), None);
}

#[test]
fn portal_notes_name_what_the_portal_cannot_do() {
    let v = |screen_cast, remote_desktop| PortalVersions { screen_cast, remote_desktop };
    assert!(portal_notes(v(5, 2), true).is_empty());
    assert!(portal_notes(v(5, 0), false).is_empty());
    // Control through a persistent RemoteDesktop grant needs no ScreenCast persistence.
    assert!(portal_notes(v(3, 2), true).is_empty());
    assert_eq!(portal_notes(v(3, 2), false), [CANT_REMEMBER]);
    assert_eq!(portal_notes(v(5, 0), true), [VIEW_ONLY]);
    // Version 1 cannot keep a grant: control would ask every share, so it is view only.
    assert_eq!(portal_notes(v(5, 1), true), [VIEW_ONLY]);
    assert_eq!(portal_notes(v(3, 0), true), [CANT_REMEMBER, VIEW_ONLY]);
}

#[test]
fn a_virtual_display_takes_the_first_free_number() {
    let root = std::env::temp_dir().join(format!("cmux-rd-setup-{}", std::process::id()));
    let sockets = root.join(".X11-unix");
    std::fs::create_dir_all(&sockets).unwrap();
    assert_eq!(free_display(&sockets, &root, 99), Some(99));
    std::fs::write(sockets.join("X99"), "").unwrap();
    std::fs::write(root.join(".X100-lock"), "").unwrap();
    assert_eq!(free_display(&sockets, &root, 99), Some(101));
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn the_session_unit_puts_a_desktop_on_the_display_and_stops_with_it() {
    let unit = session_unit(Path::new("/usr/bin/openbox-session"), 99);
    assert!(unit.contains("PartOf=cmux-screen-display.service\n"));
    assert!(unit.contains("WantedBy=cmux-screen-display.service\n"));
    assert!(unit.contains("Environment=DISPLAY=:99\n"));
    assert!(unit.contains("ExecStart=/usr/bin/openbox-session\n"));
    // systemd turns $$ into $; a bare $( it would expand or refuse.
    assert!(unit.contains("$$(seq 1 100)"));
    assert!(unit.contains("/tmp/.X11-unix/X99"));
    // The terminal is its own unit, started only on a display with no app window: started with
    // the session it opened over the agent's browser and took its clicks.
    assert!(!unit.contains("ExecStartPost") && !unit.contains("xterm"));
}

#[test]
fn the_terminal_unit_is_started_on_demand_and_stops_with_the_display() {
    let unit = terminal_unit(Path::new("/usr/bin/xterm"), 99);
    assert!(unit.contains("PartOf=cmux-screen-display.service\n"));
    assert!(unit.contains("After=cmux-screen-session.service\n"));
    assert!(unit.contains("Environment=DISPLAY=:99\n"));
    assert!(unit.contains("exec /usr/bin/xterm -class CmuxDesktop "));
    assert!(unit.contains("$${SHELL:-/bin/bash}"));
    // Not enabled with the display: the host starts it when the display shows nothing else.
    assert!(!unit.contains("[Install]") && !unit.contains("WantedBy="));
}

#[test]
fn only_the_session_terminal_reads_as_the_session() {
    assert!(wm_class_is_session(b"xterm\0CmuxDesktop\0"));
    assert!(!wm_class_is_session(b"xterm\0XTerm\0"));
    assert!(!wm_class_is_session(b"CmuxDesktop\0"));
    assert!(!wm_class_is_session(b""));
}

#[test]
fn the_display_unit_round_trips_its_number_and_the_host_drop_in_points_at_it() {
    let unit = display_unit(Path::new("/usr/bin/Xvfb"), 101);
    assert!(unit
        .contains("ExecStart=/usr/bin/Xvfb :101 -screen 0 1920x1080x24 -nolisten tcp -noreset\n"));
    assert!(unit.contains("WantedBy=default.target"));
    assert_eq!(display_of_unit(&unit), Some(101));
    assert_eq!(display_of_unit("[Service]\nExecStart=/usr/bin/Xvfb\n"), None);
    let drop_in = host_virtual_drop_in(101);
    // Started on demand, not with the host.
    assert!(!drop_in.contains("Requires="), "{drop_in}");
    assert!(drop_in
        .contains("Environment=DISPLAY=:101 XDG_SESSION_TYPE=x11 CMUX_VIRTUAL_DISPLAY=:101\n"));
}

/// On a real Xvfb: an empty display is idle, a mapped app window keeps it in use, an
/// unmapped one does not, and a display nobody serves is never called idle.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn a_mapped_app_window_keeps_the_virtual_display_in_use() {
    use std::io::BufRead as _;
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{ConnectionExt as _, CreateWindowAux, WindowClass};
    use x11rb::wrapper::ConnectionExt as _;
    let mut xvfb = std::process::Command::new("Xvfb")
        .args(["-displayfd", "1", "-screen", "0", "640x480x24", "-nolisten", "tcp"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("Xvfb");
    let mut line = String::new();
    std::io::BufReader::new(xvfb.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let n: u32 = line.trim().parse().expect("Xvfb printed its display");
    assert!(!display_in_use(n), "an empty display is idle");
    let (app, screen) = x11rb::connect(Some(&format!(":{n}"))).unwrap();
    let root = app.setup().roots[screen].root;
    let win = app.generate_id().unwrap();
    app.create_window(
        0,
        win,
        root,
        0,
        0,
        100,
        100,
        0,
        WindowClass::INPUT_OUTPUT,
        0,
        &CreateWindowAux::new(),
    )
    .unwrap();
    app.sync().unwrap();
    assert!(!display_in_use(n), "an unmapped window shows nothing");
    app.map_window(win).unwrap();
    app.sync().unwrap();
    assert!(display_in_use(n), "an app's window is on it");
    drop(app);
    let _ = xvfb.kill();
    let _ = xvfb.wait();
    assert!(display_in_use(n), "a display that does not answer is never stopped");
}

#[test]
fn a_headless_host_unit_needs_no_graphical_session() {
    let unit = headless_host_unit();
    // systemd ignores an empty dependency in a drop-in, so the unit itself must not have them.
    assert!(!unit.contains("graphical-session"), "{unit}");
    assert!(unit.contains("\nWantedBy=default.target\n"), "{unit}");
    assert!(unit.contains("\nExecStart=%h/.local/bin/cmux-rd linux-host run\n"));
    assert!(unit.contains("\nRestartPreventExitStatus=78\n"));
    // A desktop's host stays part of its session.
    assert!(HOST_UNIT_TEXT.contains("\nRequisite=graphical-session.target\n"));
}

#[test]
fn the_installed_host_unit_is_the_repositorys() {
    assert!(HOST_UNIT_TEXT.contains("ExecStart=%h/.local/bin/cmux-rd linux-host run"));
    assert!(HOST_UNIT_TEXT.contains("RestartPreventExitStatus=78"));
}
