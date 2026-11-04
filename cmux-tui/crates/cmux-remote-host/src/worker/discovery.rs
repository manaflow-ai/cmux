//! Discovery before approval (docs/computer-use-approvals.md, "Discovery
//! before approval"; decision D21): under `ask`, and under `bounded` for apps
//! outside the owner's manifest, upstream refuses `list_apps` and an unscoped
//! `list_windows` (its manifest has `desktop.display: false`), so an agent
//! could never name the app it needs and reach the approval question. The
//! worker answers those calls itself, with metadata only: app name,
//! executable, pid and window id. No window title, no icon, no pixels; those
//! come from upstream once the person allowed the app.
//!
//! - Linux X11: `_NET_CLIENT_LIST` on the root window, `_NET_WM_PID` (else
//!   the X Resource extension's client pid) per window, `/proc/<pid>/exe`.
//!   Never `WM_NAME` or `_NET_WM_NAME`.
//! - Linux Wayland: no window list exists for a client; apps are this user's
//!   processes with a display in their environment, one per executable.
//! - Windows: `EnumWindows` (visible, unowned, not tool windows),
//!   `GetWindowThreadProcessId`, `QueryFullProcessImageNameW`. Never
//!   `GetWindowText`.
//!
//! Never-allowed apps ([`crate::policy::refusal`]) are left out entirely.

use serde_json::{Value, json};

use crate::approval::Target;
use crate::policy;

/// What the result tells the agent about the missing titles.
pub const TITLES_HIDDEN: &str = "hidden until you are allowed to use the app";
const HOW_TO_TARGET: &str = "Titles, screenshots and input need the person's approval of that app: \
call the tool you need with its pid (and window_id); the first call on an app asks the person (on a box set up by its owner, an app outside the owner's list is refused instead).";

/// One running app, as the OS names it (never the agent's words).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct App {
    pub pid: u32,
    pub executable: String,
    pub name: String,
}

impl App {
    pub fn target(&self) -> Target {
        Target { bundle_id: None, executable: Some(self.executable.clone()), name: self.name.clone() }
    }

    /// The app running `executable` as `pid`, named by its file stem.
    pub fn of(pid: u32, executable: &std::path::Path) -> Self {
        let name = executable
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_else(|| executable.display().to_string());
        Self { pid, executable: executable.display().to_string(), name }
    }
}

/// One top-level window: its id and owning pid, nothing else.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Window {
    pub pid: u32,
    pub window_id: u64,
}

/// The top-level windows, or why this desktop has no list (Wayland).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Windows {
    Listed(Vec<Window>),
    Unavailable(String),
}

/// How the worker enumerates the desktop (injected in tests).
pub trait Enumerator: Send + Sync {
    /// Running apps with a desktop presence; any order, duplicates allowed.
    fn apps(&self) -> Vec<App>;
    fn windows(&self) -> Windows;
    /// The app running as `pid` (its executable).
    fn app_for_pid(&self, pid: u32) -> Option<App>;
}

fn allowed_apps(apps: Vec<App>, allow_terminals: &[String]) -> Vec<App> {
    let mut kept: Vec<App> = Vec::new();
    for app in apps {
        if policy::refusal(&app.target(), allow_terminals).is_some() || kept.iter().any(|known| known.pid == app.pid) {
            continue;
        }
        kept.push(app);
    }
    kept.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()).then(left.pid.cmp(&right.pid)));
    kept
}

fn mcp(text: String, structured: Value) -> Value {
    json!({"content": [{"type": "text", "text": text}], "isError": false, "structuredContent": structured})
}

/// `list_apps`, answered by the worker: every running app the policy may ask about.
pub fn list_apps(enumerator: &dyn Enumerator, allow_terminals: &[String]) -> Value {
    let apps = allowed_apps(enumerator.apps(), allow_terminals);
    let mut text = format!("Found {} running app(s). Window titles are {TITLES_HIDDEN}.\n", apps.len());
    for app in &apps {
        text.push_str(&format!("  pid={} {} ({})\n", app.pid, app.name, app.executable));
    }
    text.push_str(HOW_TO_TARGET);
    let entries: Vec<Value> = apps
        .iter()
        .map(|app| json!({"pid": app.pid, "name": app.name, "executable": app.executable, "running": true}))
        .collect();
    mcp(text, json!({"apps": entries, "titles": TITLES_HIDDEN, "source": "cmux"}))
}

/// `list_windows` without a pid, or with the pid of an app the session may not
/// use yet, answered by the worker: window ids and owners, no titles.
pub fn list_windows(enumerator: &dyn Enumerator, allow_terminals: &[String], pid: Option<u32>) -> Value {
    let windows = match enumerator.windows() {
        Windows::Listed(windows) => windows,
        Windows::Unavailable(reason) => {
            let text = format!(
                "This desktop does not list windows before an app is allowed ({reason}); titles are {TITLES_HIDDEN}. \
                 Use list_apps to find the app's pid. {HOW_TO_TARGET}"
            );
            return mcp(
                text,
                json!({"windows": [], "windows_unavailable": reason, "titles": TITLES_HIDDEN, "source": "cmux"}),
            );
        }
    };
    let mut apps: Vec<App> = Vec::new();
    let mut refused: Vec<u32> = Vec::new();
    let mut rows: Vec<(Window, App)> = Vec::new();
    for window in windows.into_iter().filter(|window| pid.is_none_or(|pid| window.pid == pid)) {
        if refused.contains(&window.pid) {
            continue;
        }
        let app = match apps.iter().find(|app| app.pid == window.pid) {
            Some(app) => app.clone(),
            None => match enumerator.app_for_pid(window.pid) {
                Some(app) if policy::refusal(&app.target(), allow_terminals).is_none() => {
                    apps.push(app.clone());
                    app
                }
                _ => {
                    refused.push(window.pid);
                    continue;
                }
            },
        };
        if !rows.iter().any(|(known, _)| known.window_id == window.window_id) {
            rows.push((window, app));
        }
    }
    let mut text = format!("Found {} window(s). Titles are {TITLES_HIDDEN}.\n", rows.len());
    for (window, app) in &rows {
        text.push_str(&format!("  window_id={} pid={} app={}\n", window.window_id, window.pid, app.name));
    }
    text.push_str(HOW_TO_TARGET);
    let entries: Vec<Value> = rows
        .iter()
        .map(|(window, app)| {
            json!({"window_id": window.window_id, "pid": window.pid, "app_name": app.name, "executable": app.executable})
        })
        .collect();
    mcp(text, json!({"windows": entries, "titles": TITLES_HIDDEN, "source": "cmux"}))
}

/// The pid owning `window_id`, from the worker's own window list.
pub fn pid_of_window(enumerator: &dyn Enumerator, window_id: u64) -> Option<u32> {
    match enumerator.windows() {
        Windows::Listed(windows) => windows.into_iter().find(|window| window.window_id == window_id).map(|window| window.pid),
        Windows::Unavailable(_) => None,
    }
}

/// This machine's enumerator.
pub fn live() -> std::sync::Arc<dyn Enumerator> {
    std::sync::Arc::new(Live)
}

struct Live;

impl Enumerator for Live {
    fn apps(&self) -> Vec<App> {
        platform::apps()
    }

    fn windows(&self) -> Windows {
        platform::windows()
    }

    fn app_for_pid(&self, pid: u32) -> Option<App> {
        crate::platform::process_exe(pid).map(|executable| App::of(pid, &executable))
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use super::{App, Window, Windows};

    /// A Wayland session (its own clients cannot list windows).
    fn wayland() -> bool {
        std::env::var("XDG_SESSION_TYPE").is_ok_and(|kind| kind.eq_ignore_ascii_case("wayland"))
            || (std::env::var_os("WAYLAND_DISPLAY").is_some_and(|value| !value.is_empty())
                && std::env::var_os("DISPLAY").is_none_or(|value| value.is_empty()))
    }

    pub fn windows() -> Windows {
        if wayland() {
            return Windows::Unavailable("Wayland has no window list for clients".into());
        }
        match x11::windows() {
            Ok(windows) => Windows::Listed(windows),
            Err(error) => Windows::Unavailable(format!("X11: {error}")),
        }
    }

    pub fn apps() -> Vec<App> {
        if wayland() {
            return wayland_apps();
        }
        let Ok(windows) = x11::windows() else { return Vec::new() };
        let mut apps: Vec<App> = Vec::new();
        for window in windows {
            if apps.iter().any(|app| app.pid == window.pid) {
                continue;
            }
            if let Some(executable) = crate::platform::process_exe(window.pid) {
                apps.push(App::of(window.pid, &executable));
            }
        }
        apps
    }

    /// This user's processes with a Wayland or X display in their
    /// environment, one per executable (the lowest pid).
    fn wayland_apps() -> Vec<App> {
        let me = crate::platform::my_uid();
        let mut pids: Vec<u32> = std::fs::read_dir("/proc")
            .map(|entries| entries.filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok()).collect())
            .unwrap_or_default();
        pids.sort_unstable();
        let mut apps: Vec<App> = Vec::new();
        for pid in pids {
            if pid == std::process::id() || crate::platform::process_uid(pid) != Some(me) {
                continue;
            }
            let Ok(environment) = std::fs::read(format!("/proc/{pid}/environ")) else { continue };
            let has_display = environment
                .split(|byte| *byte == 0)
                .any(|entry| entry.starts_with(b"WAYLAND_DISPLAY=") || entry.starts_with(b"DISPLAY="));
            if !has_display {
                continue;
            }
            let Some(executable) = crate::platform::process_exe(pid) else { continue };
            let app = App::of(pid, &executable);
            if !apps.iter().any(|known| known.executable == app.executable) {
                apps.push(app);
            }
        }
        apps
    }

    mod x11 {
        use x11rb::connection::Connection;
        use x11rb::protocol::res::{ClientIdMask, ClientIdSpec, ConnectionExt as _};
        use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _};

        use super::Window;

        /// This machine's host name, as X clients write it in `WM_CLIENT_MACHINE`.
        #[allow(unsafe_code)]
        fn local_host_name() -> Option<String> {
            let mut buffer = [0_u8; 256];
            // SAFETY: gethostname writes at most `buffer.len()` bytes into the buffer.
            let status = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
            if status != 0 {
                return None;
            }
            let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
            buffer.get(..end).map(|name| String::from_utf8_lossy(name).into_owned())
        }

        /// The window manager's client list with each window's pid. Reads no
        /// title property.
        pub fn windows() -> Result<Vec<Window>, String> {
            let (connection, screen) = x11rb::connect(None).map_err(|error| error.to_string())?;
            let root = connection.setup().roots.get(screen).ok_or("no X screen")?.root;
            let atom = |name: &[u8]| -> Result<u32, String> {
                Ok(connection
                    .intern_atom(false, name)
                    .map_err(|error| error.to_string())?
                    .reply()
                    .map_err(|error| error.to_string())?
                    .atom)
            };
            let client_list = atom(b"_NET_CLIENT_LIST")?;
            let wm_pid = atom(b"_NET_WM_PID")?;
            let wm_client_machine = atom(b"WM_CLIENT_MACHINE")?;
            let host = local_host_name();
            let clients: Vec<u32> = connection
                .get_property(false, root, client_list, AtomEnum::WINDOW, 0, 16_384)
                .map_err(|error| error.to_string())?
                .reply()
                .map_err(|error| error.to_string())?
                .value32()
                .map(Iterator::collect)
                .unwrap_or_default();
            let mut windows = Vec::new();
            for window in clients {
                // The X server's own record of the connection's pid first: a client cannot
                // write it, and a remote (ssh -X) client has none.
                let server = {
                    let spec = ClientIdSpec { client: window, mask: ClientIdMask::LOCAL_CLIENT_PID };
                    connection
                        .res_query_client_ids(&[spec])
                        .ok()
                        .and_then(|cookie| cookie.reply().ok())
                        .and_then(|reply| reply.ids.first().and_then(|id| id.value.first().copied()))
                };
                // `_NET_WM_PID` is what the client says about itself: trusted only when the
                // window also says it runs on this machine. A forwarded window carries a pid of
                // another machine, which could name an app this session may use (review 3 #1).
                let declared = || {
                    let machine = connection
                        .get_property(false, window, wm_client_machine, AtomEnum::STRING, 0, 256)
                        .ok()
                        .and_then(|cookie| cookie.reply().ok())
                        .map(|reply| String::from_utf8_lossy(&reply.value).trim_end_matches('\0').to_owned())?;
                    if host.as_deref() != Some(machine.as_str()) {
                        return None;
                    }
                    connection
                        .get_property(false, window, wm_pid, AtomEnum::CARDINAL, 0, 1)
                        .ok()
                        .and_then(|cookie| cookie.reply().ok())
                        .and_then(|reply| reply.value32().and_then(|mut values| values.next()))
                };
                if let Some(pid) = server.filter(|pid| *pid > 0).or_else(|| declared().filter(|pid| *pid > 0)) {
                    windows.push(Window { pid, window_id: u64::from(window) });
                }
            }
            Ok(windows)
        }
    }
}

#[cfg(windows)]
#[allow(unsafe_code)]
mod platform {
    use windows_sys::Win32::Foundation::{BOOL, HWND, LPARAM, TRUE};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GW_OWNER, GWL_EXSTYLE, GetWindow, GetWindowLongW, GetWindowThreadProcessId, IsWindowVisible,
        WS_EX_TOOLWINDOW,
    };

    use super::{App, Window, Windows};

    unsafe extern "system" fn collect(window: HWND, context: LPARAM) -> BOOL {
        // SAFETY: `context` is the Vec `top_level` passes, alive for the whole EnumWindows call.
        let found = unsafe { &mut *(context as *mut Vec<Window>) };
        // SAFETY: a window handle EnumWindows passed; these calls only read it.
        unsafe {
            if IsWindowVisible(window) == 0 || !GetWindow(window, GW_OWNER).is_null() {
                return TRUE;
            }
            if (GetWindowLongW(window, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW != 0 {
                return TRUE;
            }
            let mut pid = 0_u32;
            GetWindowThreadProcessId(window, &mut pid);
            if pid != 0 {
                found.push(Window { pid, window_id: window as usize as u64 });
            }
        }
        TRUE
    }

    /// Visible, unowned, non-tool top-level windows. Reads no window text.
    fn top_level() -> Vec<Window> {
        let mut found: Vec<Window> = Vec::new();
        // SAFETY: `collect` only uses the pointer during this call.
        unsafe { EnumWindows(Some(collect), &mut found as *mut Vec<Window> as LPARAM) };
        found
    }

    pub fn windows() -> Windows {
        Windows::Listed(top_level())
    }

    pub fn apps() -> Vec<App> {
        let mut apps: Vec<App> = Vec::new();
        for window in top_level() {
            if apps.iter().any(|app| app.pid == window.pid) {
                continue;
            }
            if let Some(executable) = crate::platform::process_exe(window.pid) {
                apps.push(App::of(window.pid, &executable));
            }
        }
        apps
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use super::{App, Windows};

    pub fn windows() -> Windows {
        Windows::Unavailable("this OS has no cmux-remote-host window list".into())
    }

    pub fn apps() -> Vec<App> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests;
