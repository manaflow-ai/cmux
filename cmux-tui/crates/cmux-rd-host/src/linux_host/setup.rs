//! What `enable` sets up so this machine can be shared with nobody at it later: the capture
//! path for the desktop it has, and (`--non-interactive`, the join) the host's user units.
//!
//! - A Wayland desktop on a seat: the portal grant, once (portal.rs). Over ssh the join has no
//!   `WAYLAND_DISPLAY`, so the desktop is found through logind, not the environment.
//! - An X11 desktop: nothing; X11 capture needs no grant.
//! - No graphical session (a server, a VM): a virtual X display cmux owns, `Xvfb :N` in the user
//!   unit `cmux-screen-display.service`, and the host unit pointed at it.
//!
//! The lines the join prints are fixed (hq docs/design/remote-spin-up.md section 2.8):
//! [`virtual_display_line`], [`CANT_REMEMBER`] and [`VIEW_ONLY`].

use crate::Res;
use std::path::{Path, PathBuf};

/// The portal cannot keep a restore token (ScreenCast before version 4). Not fatal.
pub const CANT_REMEMBER: &str =
    "this desktop's screen-share portal can't remember a grant; each share will ask once on this machine";
/// No RemoteDesktop portal that can keep a grant (none, or version 1). Not fatal.
pub const VIEW_ONLY: &str = "view only: this desktop has no remote-input portal";

/// The line for a virtual display `enable` started.
pub fn virtual_display_line(display: u32) -> String {
    format!(
        "no graphical session on this machine; shares use a virtual display at :{display}, started when one is needed"
    )
}

/// The desktop this user has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Desktop {
    /// A Wayland session (shared through the portal).
    Wayland,
    /// An X11 session, its display when known.
    X11(Option<String>),
    /// No graphical session for this user.
    None,
}

/// One logind session's properties, as `loginctl show-session ID -p Type -p Class -p Display`
/// prints them (`Key=value` lines).
pub fn session_desktop(props: &str) -> Desktop {
    let get = |key: &str| {
        props.lines().find_map(|l| l.strip_prefix(key).and_then(|v| v.strip_prefix('=')))
    };
    if get("Class").is_some_and(|c| c != "user") {
        return Desktop::None;
    }
    match get("Type").map(str::trim) {
        Some("wayland") => Desktop::Wayland,
        Some("x11") => {
            Desktop::X11(get("Display").map(str::trim).filter(|d| !d.is_empty()).map(str::to_owned))
        }
        _ => Desktop::None,
    }
}

/// The desktop from this process's environment, else from the user's logind sessions (each
/// one's `show-session` text): Wayland wins over X11, which wins over none. A `DISPLAY` naming
/// `own_virtual`, the virtual display cmux runs here, is no desktop: the join puts it in the user
/// environment so apps land on the shared screen, and reading it as one made the daemon's next
/// `enable` install the desktop's host unit, which never starts without a graphical session.
pub fn choose_desktop(
    session_type: Option<&str>,
    wayland_display: Option<&str>,
    display: Option<&str>,
    own_virtual: Option<u32>,
    sessions: &[String],
) -> Desktop {
    fn set(v: Option<&str>) -> Option<&str> {
        v.map(str::trim).filter(|v| !v.is_empty())
    }
    if session_type.is_some_and(|t| t.trim().eq_ignore_ascii_case("wayland"))
        || set(wayland_display).is_some()
    {
        return Desktop::Wayland;
    }
    let own = |d: &&str| own_virtual.is_some() && display_number(d) == own_virtual;
    if let Some(d) = set(display).filter(|d| !own(d)) {
        return Desktop::X11(Some(d.to_owned()));
    }
    let found: Vec<Desktop> = sessions.iter().map(|s| session_desktop(s)).collect();
    if found.contains(&Desktop::Wayland) {
        return Desktop::Wayland;
    }
    found.into_iter().find(|d| matches!(d, Desktop::X11(_))).unwrap_or(Desktop::None)
}

/// This user's desktop now: the environment, then logind.
pub fn detect_desktop() -> Desktop {
    let env = |k: &str| std::env::var(k).ok();
    choose_desktop(
        env("XDG_SESSION_TYPE").as_deref(),
        env("WAYLAND_DISPLAY").as_deref(),
        env("DISPLAY").as_deref(),
        written_virtual_display(),
        &logind_sessions(),
    )
}

/// The number of a local X display name (`:N`, `:N.S`, `unix:N`); None for a `host:N` one.
pub fn display_number(display: &str) -> Option<u32> {
    let name = display.trim();
    let rest = name.strip_prefix("unix").unwrap_or(name).strip_prefix(':')?;
    rest.split('.').next()?.parse().ok()
}

/// The virtual display a written `cmux-screen-display.service` runs, whether or not the host is
/// set up for it now ([`virtual_display`] needs the host's drop-in, which a misread join removed).
fn written_virtual_display() -> Option<u32> {
    display_of_unit(&std::fs::read_to_string(user_unit_dir().ok()?.join(DISPLAY_UNIT)).ok()?)
}

/// The `show-session` text of each of this user's logind sessions (empty without loginctl).
fn logind_sessions() -> Vec<String> {
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() }.to_string();
    let Some(ids) = command_out("loginctl", &["show-user", &uid, "-p", "Sessions", "--value"])
    else {
        return Vec::new();
    };
    ids.split_whitespace()
        .filter_map(|id| {
            command_out(
                "loginctl",
                &["show-session", id, "-p", "Type", "-p", "Class", "-p", "Display"],
            )
        })
        .collect()
}

fn command_out(program: &str, args: &[&str]) -> Option<String> {
    let out = std::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The portal's interface versions, for the join's notes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PortalVersions {
    pub screen_cast: u32,
    pub remote_desktop: u32,
}

/// ScreenCast keeps restore tokens from version 4; RemoteDesktop from version 2 (portal.rs).
pub const SCREEN_CAST_PERSISTS: u32 = 4;
pub const REMOTE_DESKTOP_PERSISTS: u32 = 2;

/// The fixed lines for a portal of `versions`, when `control` is wanted.
pub fn portal_notes(versions: PortalVersions, control: bool) -> Vec<&'static str> {
    let mut notes = Vec::new();
    let remote = control && versions.remote_desktop >= REMOTE_DESKTOP_PERSISTS;
    // A RemoteDesktop session keeps its grant through its devices; a ScreenCast one needs v4.
    if !remote && versions.screen_cast < SCREEN_CAST_PERSISTS {
        notes.push(CANT_REMEMBER);
    }
    if control && !remote {
        notes.push(VIEW_ONLY);
    }
    notes
}

/// The lowest X display number from `from` with no socket in `socket_dir` and no lock file in
/// `lock_dir` (`/tmp/.X11-unix/XN`, `/tmp/.XN-lock`).
pub fn free_display(socket_dir: &Path, lock_dir: &Path, from: u32) -> Option<u32> {
    (from..from + 100).find(|n| {
        !socket_dir.join(format!("X{n}")).exists() && !lock_dir.join(format!(".X{n}-lock")).exists()
    })
}

/// The first display number virtual displays try.
pub const FIRST_VIRTUAL_DISPLAY: u32 = 99;

/// The user unit of the virtual display.
pub const DISPLAY_UNIT: &str = "cmux-screen-display.service";
/// The host's user unit (systemd/cmux-screen-host.service).
pub const HOST_UNIT: &str = "cmux-screen-host.service";
const HOST_UNIT_TEXT: &str = include_str!("../../systemd/cmux-screen-host.service");

/// `cmux-screen-display.service` for display `:display` run by `xvfb` (an absolute path).
/// `-noreset`: the host's idle check ([`display_in_use`], every 30 s) is often the display's
/// only client, and without it Xvfb resets the server each time that check disconnects and
/// forks xkbcomp again on the next one, a new process in the unit's log every 30 s.
pub fn display_unit(xvfb: &Path, display: u32) -> String {
    format!(
        "# cmux virtual display: written by `cmux-rd linux-host enable` on a machine with no\n\
         # graphical session, so the screen host has a screen to share (src/linux_host/setup.rs).\n\
         [Unit]\n\
         Description=cmux virtual display :{display} for screen sharing\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart={} :{display} -screen 0 1920x1080x24 -nolisten tcp -noreset\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n",
        xvfb.display()
    )
}

/// The user unit of the desktop session on the virtual display: a window manager, and (its own
/// unit, [`TERMINAL_UNIT`]) a terminal when the display shows nothing else, so a viewer sees a
/// desktop to work in, never an empty root window that draws nothing (Leo, 2026-11-18: "i
/// should be able to see into any connected mac or linux machine").
pub const SESSION_UNIT: &str = "cmux-screen-session.service";
/// The session's terminal, started by [`ensure_virtual_display`] only while no app shows a
/// window there: started with the session unconditionally it opened over the app already on the
/// display (an agent's browser) and took the clicks aimed at it (cmuxterm-hq
/// goals/computer-use-click-lands.md: every take-over click missed, under a `cmux@cmux: ~` xterm).
pub const TERMINAL_UNIT: &str = "cmux-screen-terminal.service";
/// The X class of the session's own terminal: [`display_in_use`] does not count it as an app.
pub const SESSION_TERMINAL_CLASS: &str = "CmuxDesktop";

/// `cmux-screen-session.service` for display `:display`: `wm` (an absolute path, e.g.
/// openbox-session). It starts and stops with the display (`PartOf=`), so an idle display still
/// stops.
pub fn session_unit(wm: &Path, display: u32) -> String {
    format!(
        "# cmux desktop session: written by `cmux-rd linux-host enable` beside the virtual display,\n\
         # so a viewer sees a window manager (src/linux_host/setup.rs).\n\
         [Unit]\n\
         Description=cmux desktop session on :{display} (window manager)\n\
         PartOf={DISPLAY_UNIT}\n\
         After={DISPLAY_UNIT}\n\
         \n\
         [Service]\n\
         Type=simple\n\
         Environment=DISPLAY=:{display}\n\
         ExecStartPre=/bin/sh -c 'for i in $$(seq 1 100); do [ -S /tmp/.X11-unix/X{display} ] && exit 0; sleep 0.1; done; exit 1'\n\
         ExecStart={}\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         \n\
         [Install]\n\
         WantedBy={DISPLAY_UNIT}\n",
        wm.display()
    )
}

/// `cmux-screen-terminal.service` for display `:display`: `terminal` with class
/// [`SESSION_TERMINAL_CLASS`] and a login shell. Not enabled: [`ensure_virtual_display`] starts
/// it when the display has no app window; it stops with the display, and a closed terminal stays
/// closed until the display shows nothing again.
pub fn terminal_unit(terminal: &Path, display: u32) -> String {
    format!(
        "# cmux desktop session's terminal: written by `cmux-rd linux-host enable`, started by the\n\
         # host only while no app shows a window on :{display} (src/linux_host/setup.rs).\n\
         [Unit]\n\
         Description=cmux desktop terminal on :{display}\n\
         PartOf={DISPLAY_UNIT}\n\
         After={SESSION_UNIT}\n\
         \n\
         [Service]\n\
         Type=simple\n\
         Environment=DISPLAY=:{display}\n\
         ExecStartPre=/bin/sleep 1\n\
         ExecStart=/bin/sh -c 'exec {} -class {SESSION_TERMINAL_CLASS} -geometry 160x48+40+40 -e \"$${{SHELL:-/bin/bash}}\" -l'\n",
        terminal.display()
    )
}

/// The line `enable` prints when the machine has no window manager to put on the display.
pub const NO_DESKTOP: &str = "no window manager here (install openbox and xterm): a viewer would see an empty screen until an app opens a window";

/// The display a written `cmux-screen-display.service` runs, so `enable` run again keeps it.
pub fn display_of_unit(text: &str) -> Option<u32> {
    let exec = text.lines().find_map(|l| l.strip_prefix("ExecStart="))?;
    exec.split_whitespace().find_map(|w| w.strip_prefix(':')?.parse().ok())
}

/// The host unit for a machine with no graphical session: the repository's unit without its
/// ties to `graphical-session.target`, which never starts there, so the user manager starts it.
/// A drop-in cannot do this: systemd ignores an empty `Requisite=` or `PartOf=` in one, and
/// every start of the host failed with "Dependency failed".
pub fn headless_host_unit() -> String {
    let mut text = String::new();
    for line in HOST_UNIT_TEXT.lines() {
        if ["PartOf=", "Requisite=", "After="].iter().any(|key| line.starts_with(key)) {
            continue;
        }
        text.push_str(if line == "WantedBy=graphical-session.target" {
            "WantedBy=default.target"
        } else {
            line
        });
        text.push('\n');
    }
    text
}

/// The host unit's drop-in for a virtual display: the host captures the virtual display, which
/// it starts when a share or an app needs it ([`ensure_virtual_display`]), not with itself.
pub fn host_virtual_drop_in(display: u32) -> String {
    format!(
        "# Written by `cmux-rd linux-host enable`: this machine has no graphical session, so the\n\
         # host shares the virtual display :{display} (cmux-screen-display.service), started\n\
         # when a share or an app launch needs it.\n\
         [Service]\n\
         Environment=DISPLAY=:{display} XDG_SESSION_TYPE=x11 {VIRTUAL_DISPLAY_ENV}=:{display}\n"
    )
}

/// Set in the host's environment by [`host_virtual_drop_in`]: the virtual display this host
/// starts on demand.
pub const VIRTUAL_DISPLAY_ENV: &str = "CMUX_VIRTUAL_DISPLAY";

/// The virtual display this machine's host owns: from the host's environment, else (a command
/// run outside the unit, such as `linux-host display`) from the display unit `enable` wrote.
pub fn virtual_display() -> Option<u32> {
    if let Ok(value) = std::env::var(VIRTUAL_DISPLAY_ENV) {
        return value.trim().strip_prefix(':')?.parse().ok();
    }
    let dir = user_unit_dir().ok()?;
    // Only while the host is set up for it: a desktop's join removes the drop-in.
    if !dir.join(format!("{HOST_UNIT}.d")).join("virtual-display.conf").exists() {
        return None;
    }
    display_of_unit(&std::fs::read_to_string(dir.join(DISPLAY_UNIT)).ok()?)
}

/// How long a started Xvfb may take to open its socket.
const DISPLAY_START_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// Starts the virtual display `display` (its user unit) unless its socket is already there,
/// and waits for the socket; `:N`.
pub fn ensure_virtual_display(display: u32) -> Res<String> {
    let socket = PathBuf::from(format!("/tmp/.X11-unix/X{display}"));
    if !socket.exists() {
        systemctl(&["start", DISPLAY_UNIT])?;
        let deadline = std::time::Instant::now() + DISPLAY_START_WAIT;
        while !socket.exists() {
            if std::time::Instant::now() >= deadline {
                return Err(format!(
                    "the virtual display :{display} did not start within {} s ({DISPLAY_UNIT})",
                    DISPLAY_START_WAIT.as_secs()
                )
                .into());
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }
    // The desktop on it (a display started before the session unit existed has none yet).
    let dir = user_unit_dir().ok();
    // A session unit written by an earlier `enable` still opens its terminal with the session,
    // over any app: rewrite it to the split units before starting it.
    if let Some(dir) = dir.as_deref() {
        if let Err(e) = heal_session_unit(dir, display) {
            eprintln!("linux-host: the desktop session unit was not rewritten: {e}");
        }
    }
    if dir.as_ref().is_some_and(|dir| dir.join(SESSION_UNIT).exists()) {
        if let Err(e) = systemctl(&["start", SESSION_UNIT]) {
            eprintln!("linux-host: the desktop session did not start: {e}");
        }
    }
    // Its terminal only on a display that shows nothing else: over an app it would take the
    // person's and the agent's clicks aimed at that app.
    if dir.is_some_and(|dir| dir.join(TERMINAL_UNIT).exists()) && !display_in_use(display) {
        if let Err(e) = systemctl(&["start", TERMINAL_UNIT]) {
            eprintln!("linux-host: the desktop terminal did not start: {e}");
        }
    }
    Ok(format!(":{display}"))
}

/// The window manager and terminal of a session unit from before [`TERMINAL_UNIT`] (one whose
/// `ExecStartPost` opens the terminal with the session), else None.
pub fn old_session_parts(text: &str) -> Option<(PathBuf, PathBuf)> {
    let post = text.lines().find_map(|l| l.strip_prefix("ExecStartPost="))?;
    let before_class = post.split(&format!(" -class {SESSION_TERMINAL_CLASS}")).next()?;
    if before_class.len() == post.len() {
        return None;
    }
    let terminal = before_class.split_whitespace().last()?;
    let wm = text.lines().find_map(|l| l.strip_prefix("ExecStart="))?.trim();
    (terminal.starts_with('/') && wm.starts_with('/'))
        .then(|| (PathBuf::from(wm), PathBuf::from(terminal)))
}

/// Rewrites an old session unit in `dir` ([`old_session_parts`]) to [`session_unit`] and
/// [`terminal_unit`]; nothing to do for a current one or none.
fn heal_session_unit(dir: &Path, display: u32) -> Res<()> {
    let session = dir.join(SESSION_UNIT);
    let Some((wm, terminal)) =
        std::fs::read_to_string(&session).ok().as_deref().and_then(old_session_parts)
    else {
        return Ok(());
    };
    write_if_changed(&dir.join(TERMINAL_UNIT), &terminal_unit(&terminal, display))?;
    write_if_changed(&session, &session_unit(&wm, display))?;
    systemctl(&["daemon-reload"])
}

/// Stops the virtual display.
pub fn stop_virtual_display() -> Res<()> {
    systemctl(&["stop", DISPLAY_UNIT])
}

/// Whether an app shows a window on the virtual display: the session's window manager's client
/// list less the session's own terminal, else (no window manager) the root's mapped top-level
/// windows, where an app's window is one. A display that does not answer counts as in use, so it is never stopped by mistake.
pub fn display_in_use(display: u32) -> bool {
    use x11rb::connection::Connection as _;
    use x11rb::protocol::xproto::{ConnectionExt as _, MapState};
    let Ok((conn, screen)) = x11rb::connect(Some(&format!(":{display}"))) else { return true };
    let Some(root) = conn.setup().roots.get(screen).map(|s| s.root) else { return true };
    // With the session's window manager: its client list, less the session's own terminal.
    if let Some(clients) = net_client_list(&conn, root) {
        return clients.iter().any(|&window| !is_session_terminal(&conn, window));
    }
    let Some(tree) = conn.query_tree(root).ok().and_then(|c| c.reply().ok()) else { return true };
    tree.children.iter().any(|&window| {
        conn.get_window_attributes(window)
            .ok()
            .and_then(|c| c.reply().ok())
            .is_none_or(|a| a.map_state == MapState::VIEWABLE)
    })
}

/// The window manager's `_NET_CLIENT_LIST` on `root`: None when no window manager keeps one.
fn net_client_list(conn: &impl x11rb::connection::Connection, root: u32) -> Option<Vec<u32>> {
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _};
    let atom = conn.intern_atom(true, b"_NET_CLIENT_LIST").ok()?.reply().ok()?.atom;
    if atom == 0 {
        return None;
    }
    let reply =
        conn.get_property(false, root, atom, AtomEnum::WINDOW, 0, 4096).ok()?.reply().ok()?;
    if reply.type_ == 0 {
        return None;
    }
    // Collected into a local first: as the tail expression, the iterator's temporary outlives
    // `reply` and the release build fails to compile (E0597).
    let clients: Vec<u32> = reply.value32()?.collect();
    Some(clients)
}

/// Whether `window`'s `WM_CLASS` names the session's terminal ([`SESSION_TERMINAL_CLASS`]).
fn is_session_terminal(conn: &impl x11rb::connection::Connection, window: u32) -> bool {
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _};
    conn.get_property(false, window, AtomEnum::WM_CLASS, AtomEnum::STRING, 0, 256)
        .ok()
        .and_then(|c| c.reply().ok())
        .is_some_and(|r| wm_class_is_session(&r.value))
}

/// `WM_CLASS` is two NUL-ended strings, instance then class.
fn wm_class_is_session(value: &[u8]) -> bool {
    value.split(|&b| b == 0).nth(1) == Some(SESSION_TERMINAL_CLASS.as_bytes())
}

/// `~/.config/systemd/user` (or under `XDG_CONFIG_HOME`).
fn user_unit_dir() -> Res<PathBuf> {
    let base = match std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(std::env::var_os("HOME").ok_or("HOME is not set")?).join(".config"),
    };
    Ok(base.join("systemd").join("user"))
}

fn write_if_changed(path: &Path, text: &str) -> Res<()> {
    if std::fs::read_to_string(path).ok().as_deref() == Some(text) {
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

fn systemctl(args: &[&str]) -> Res<()> {
    let out = std::process::Command::new("systemctl")
        .arg("--user")
        .args(args)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| format!("systemctl --user {}: {e}", args.join(" ")))?;
    if out.status.success() {
        return Ok(());
    }
    Err(format!(
        "systemctl --user {}: {}",
        args.join(" "),
        String::from_utf8_lossy(&out.stderr).trim()
    )
    .into())
}

/// `name` on `PATH`, as an absolute path.
fn on_path(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(name))
        .find(|p| p.is_absolute() && p.is_file())
}

/// Writes the virtual display's unit (keeping the display number of one written before) and
/// the host's drop-in; the display number. The display is not started here: the host starts
/// it when a share or an app needs it, and stops it when idle.
pub fn set_up_virtual_display() -> Res<u32> {
    let xvfb = on_path("Xvfb").ok_or(
        "no graphical session on this machine, and no Xvfb to start a virtual display (install the xvfb package, then run enable again)",
    )?;
    let dir = user_unit_dir()?;
    let unit = dir.join(DISPLAY_UNIT);
    let display = match std::fs::read_to_string(&unit).ok().as_deref().and_then(display_of_unit) {
        Some(n) => n,
        None => free_display(Path::new("/tmp/.X11-unix"), Path::new("/tmp"), FIRST_VIRTUAL_DISPLAY)
            .ok_or("no free X display number from :99")?,
    };
    write_if_changed(&unit, &display_unit(&xvfb, display))?;
    let session = dir.join(SESSION_UNIT);
    let terminal_path = dir.join(TERMINAL_UNIT);
    match on_path("openbox-session").or_else(|| on_path("openbox")) {
        Some(wm) => {
            write_if_changed(&session, &session_unit(&wm, display))?;
            match on_path("xterm").or_else(|| on_path("x-terminal-emulator")) {
                Some(terminal) => {
                    write_if_changed(&terminal_path, &terminal_unit(&terminal, display))?
                }
                None => {
                    let _ = std::fs::remove_file(&terminal_path);
                }
            }
        }
        None => {
            println!("{NO_DESKTOP}");
            let _ = std::fs::remove_file(&session);
            let _ = std::fs::remove_file(&terminal_path);
        }
    }
    write_if_changed(
        &dir.join(format!("{HOST_UNIT}.d")).join("virtual-display.conf"),
        &host_virtual_drop_in(display),
    )?;
    systemctl(&["daemon-reload"])?;
    // An earlier join enabled it at boot; it now starts on demand. A running one keeps running.
    let _ = systemctl(&["disable", DISPLAY_UNIT]);
    // The desktop comes up with the display, every time it starts.
    if session.exists() {
        systemctl(&["enable", SESSION_UNIT])?;
    }
    Ok(display)
}

/// Stops the host unit (`systemctl --user stop`) before this desktop's identity changes; a unit
/// that was never installed is already stopped. Ok only once no host of this desktop runs (the
/// unit's, or one started by hand): it is checked gone by its pid file's lock, and killed with
/// its process group when `systemctl` did not stop it in time (review F1 of #45369).
pub fn stop_host() -> Res<()> {
    use cmux_hub_host::{host_process, identity};
    let stopped = match systemctl(&["stop", HOST_UNIT]) {
        Err(e) if e.to_string().contains("not loaded") => Ok(()),
        other => other,
    };
    let dir = identity::config_dir()?;
    match host_process::ensure_gone(&dir, host_process::STOP_WAIT) {
        Ok(()) => Ok(()),
        Err(pid) => Err(format!(
            "the screen host is still running ({}{}); stop it with: {}",
            pid.map_or("its pid is unknown: a host of an older build records none".into(), |pid| {
                format!("pid {pid}")
            }),
            stopped.err().map(|e| format!("; {e}")).unwrap_or_default(),
            pid.map_or(format!("systemctl --user kill --signal=KILL {HOST_UNIT}"), |pid| {
                format!("kill -KILL {pid}")
            })
        )
        .into()),
    }
}

/// Installs the host's user unit (when missing or older) and starts it: with a desktop, as part
/// of its graphical session; on a virtual display, from the user manager itself. Turns on
/// lingering for a virtual display, so the host outlives the ssh session (warns if it cannot).
/// The host unit `install_host` writes: the headless one for a virtual display (no ties to
/// `graphical-session.target`, which never starts there), else the desktop's.
pub fn host_unit_text(virtual_display: bool) -> String {
    if virtual_display {
        headless_host_unit()
    } else {
        HOST_UNIT_TEXT.to_owned()
    }
}

pub fn install_host(virtual_display: bool) -> Res<()> {
    let dir = user_unit_dir()?;
    let text = host_unit_text(virtual_display);
    write_if_changed(&dir.join(HOST_UNIT), &text)?;
    systemctl(&["daemon-reload"])?;
    // Drops the links of the other unit's [Install], such as graphical-session.target's.
    let _ = systemctl(&["disable", HOST_UNIT]);
    systemctl(&["enable", HOST_UNIT])?;
    if !virtual_display {
        // A desktop now: the virtual display an earlier join started is no longer the host's.
        let drop_in = dir.join(format!("{HOST_UNIT}.d")).join("virtual-display.conf");
        if drop_in.exists() {
            std::fs::remove_file(&drop_in)?;
            systemctl(&["daemon-reload"])?;
            let _ = systemctl(&["disable", "--now", DISPLAY_UNIT]);
        }
    }
    if virtual_display {
        let user = std::env::var("USER").unwrap_or_default();
        let linger = std::process::Command::new("loginctl")
            .args(["enable-linger", &user])
            .stdin(std::process::Stdio::null())
            .status();
        if !linger.is_ok_and(|s| s.success()) {
            eprintln!(
                "cmux-rd linux-host: could not keep the user manager running after logout (loginctl enable-linger {user}); sharing stops when the last session of this user ends"
            );
        }
    }
    systemctl(&["restart", HOST_UNIT])
}

#[cfg(test)]
#[path = "setup_tests.rs"]
mod tests;
