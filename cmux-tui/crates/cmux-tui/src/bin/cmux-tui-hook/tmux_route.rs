use std::collections::HashMap;
use std::path::PathBuf;
#[cfg(target_os = "linux")]
use std::time::{Duration, Instant};

/// Bound on both tmux queries together. It comes out of the provider's
/// hook budget, and codex kills SessionEnd hooks at 3s.
#[cfg(target_os = "linux")]
const TMUX_BUDGET: Duration = Duration::from_millis(500);

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Route {
    pub(super) socket: PathBuf,
    pub(super) terminal: String,
}

#[cfg(target_os = "linux")]
pub(super) fn attached_terminal() -> Option<Route> {
    std::env::var_os("TMUX").filter(|value| !value.is_empty())?;
    let deadline = Instant::now() + TMUX_BUDGET;
    let pane = std::env::var("TMUX_PANE").ok().filter(|value| !value.is_empty());
    let mut display = vec!["display-message", "-p"];
    if let Some(pane) = pane.as_deref() {
        display.extend(["-t", pane]);
    }
    display.push(PANE_FORMAT);
    let pane_line = run_tmux(&display, deadline)?;
    let clients = run_tmux(&["list-clients", "-F", CLIENT_FORMAT], deadline)?;
    select(&pane_line, &clients, proc_environ)
}

#[cfg(not(target_os = "linux"))]
pub(super) fn attached_terminal() -> Option<Route> {
    None
}

pub(super) const PANE_FORMAT: &str = "#{session_id}\t#{session_group}\t#{window_id}";
pub(super) const CLIENT_FORMAT: &str =
    "#{client_pid}\t#{client_activity}\t#{session_id}\t#{session_group}\t#{window_id}";

/// Picks the route from `display-message` output for the pane and
/// `list-clients` output, reading each candidate's environment.
pub(super) fn select(
    pane_line: &str,
    clients: &str,
    environ: impl Fn(u32) -> Option<HashMap<String, String>>,
) -> Option<Route> {
    let pane_line = pane_line.strip_suffix('\n').unwrap_or(pane_line);
    let pane: Vec<&str> = pane_line.split('\t').collect();
    let [session, group, window] = pane[..] else { return None };
    if session.is_empty() {
        return None;
    }
    let mut candidates: Vec<(bool, i64, u32)> = clients
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            let [pid, activity, client_session, client_group, client_window] = fields[..] else {
                return None;
            };
            let same_session =
                client_session == session || (!group.is_empty() && client_group == group);
            let pid = pid.parse::<u32>().ok().filter(|pid| *pid > 1)?;
            same_session.then(|| {
                let shows_pane = !window.is_empty() && client_window == window;
                (shows_pane, activity.parse().unwrap_or(0), pid)
            })
        })
        .collect();
    candidates.sort_by(|left, right| right.0.cmp(&left.0).then(right.1.cmp(&left.1)));
    candidates.into_iter().find_map(|(_, _, pid)| {
        let environment = environ(pid)?;
        let value = |key: &str| environment.get(key).filter(|value| !value.is_empty()).cloned();
        Some(Route {
            socket: value("CMUX_TUI_SOCKET")?.into(),
            terminal: value("CMUX_TUI_TERMINAL_ID")?,
        })
    })
}

/// A same-user process environment; other users' are unreadable.
#[cfg(target_os = "linux")]
fn proc_environ(pid: u32) -> Option<HashMap<String, String>> {
    let data = std::fs::read(format!("/proc/{pid}/environ")).ok()?;
    Some(
        data.split(|byte| *byte == 0)
            .filter_map(|entry| {
                let entry = std::str::from_utf8(entry).ok()?;
                let (key, value) = entry.split_once('=')?;
                (!key.is_empty()).then(|| (key.to_owned(), value.to_owned()))
            })
            .collect(),
    )
}

/// Runs tmux against the server named by `$TMUX`, killed at `deadline`.
#[cfg(target_os = "linux")]
fn run_tmux(args: &[&str], deadline: Instant) -> Option<String> {
    use std::io::Read;
    use std::process::{Command, Stdio};

    let mut child = Command::new("tmux")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(5));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let mut output = String::new();
    child.stdout.take()?.read_to_string(&mut output).ok()?;
    Some(output)
}
