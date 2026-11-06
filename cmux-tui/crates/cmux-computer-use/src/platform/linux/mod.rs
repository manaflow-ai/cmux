//! Linux desktops, chosen at run time so one binary runs on every
//! distribution and display server:
//!
//! - [`x11`]: any X11 window manager or desktop, and headless X servers
//!   (Xvfb, Xvnc) on cloud VMs. Windows from EWMH, pixels from the X server
//!   (the compositor's own pixmap when one runs), input through XTest or
//!   XSendEvent.
//! - [`wlroots`]: Sway, Hyprland, river, Wayfire and other wlroots
//!   compositors. Windows from the compositor's IPC (Sway, Hyprland) or
//!   wlr-foreign-toplevel, pixels from wlr-screencopy, input through
//!   wlr-virtual-pointer and zwp-virtual-keyboard.
//! - [`portal`]: GNOME (Mutter) and KDE Plasma on Wayland, through
//!   xdg-desktop-portal: RemoteDesktop + ScreenCast for input (the restore
//!   token is kept in the state dir, so the person is asked once) and the
//!   Screenshot portal for pixels. Windows come from AT-SPI.
//!
//! Every backend reads and acts on accessibility trees through [`atspi`]
//! (AT-SPI2 over D-Bus, the same on X11 and Wayland), and that is the
//! background route: an AT-SPI action, a text insert or a value set touches
//! only the target element, never the person's pointer or focus.
//!
//! Background delivery rules (desktop.rs rule 2), per server:
//!
//! - X11: XTest is global (it moves the real pointer and types into the
//!   focused window), so it is used only with `Delivery::Foreground` or on a
//!   headless X server, where no person shares the pointer. Otherwise a
//!   point the accessibility tree cannot resolve gets XSendEvent to the
//!   exact X window under it; that is window-scoped, but some apps ignore
//!   synthetic events (xterm without allowSendEvents), so the evidence says
//!   `delivered`, not `confirmed`.
//! - Wayland: virtual input is global too, so it is used only with
//!   `Delivery::Foreground` or on headless outputs; in the background a
//!   target the tree cannot resolve is refused, with what would work.
//!
//! Detection order in [`open`]: `CMUX_CU_LINUX_BACKEND` (x11, wlroots,
//! portal) when set; a Wayland session (`WAYLAND_DISPLAY`, or
//! `XDG_SESSION_TYPE=wayland` with the default socket) uses wlroots when the
//! compositor offers screencopy and virtual pointer, else the portals when
//! xdg-desktop-portal offers RemoteDesktop, else XWayland (only X11 apps);
//! otherwise `DISPLAY` is X11.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::cursor::CursorSink;
use crate::desktop::{Desktop, Rect};
use crate::engine::PersonActivity;

pub mod atspi;
pub mod cursor;
pub mod idle;
pub mod keysym;
pub mod portal;
pub mod wlroots;
pub mod x11;

/// Which Linux desktop this session is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SessionKind {
    X11 { display: String },
    Wlroots,
    Portal,
}

/// What the environment says, before connecting to anything.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Env {
    pub wayland_display: Option<String>,
    pub display: Option<String>,
    pub session_type: Option<String>,
    pub current_desktop: Option<String>,
    pub runtime_dir: Option<String>,
    pub forced: Option<String>,
}

impl Env {
    pub fn from_process() -> Self {
        let get = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        Self {
            wayland_display: get("WAYLAND_DISPLAY"),
            display: get("DISPLAY"),
            session_type: get("XDG_SESSION_TYPE"),
            current_desktop: get("XDG_CURRENT_DESKTOP"),
            runtime_dir: get("XDG_RUNTIME_DIR"),
            forced: get("CMUX_CU_LINUX_BACKEND"),
        }
    }

    /// The Wayland socket name to use, when this is a Wayland session.
    pub fn wayland_socket(&self) -> Option<String> {
        if let Some(name) = &self.wayland_display {
            return Some(name.clone());
        }
        if self.session_type.as_deref() == Some("wayland") {
            let dir = self.runtime_dir.as_deref()?;
            if Path::new(dir).join("wayland-0").exists() {
                return Some("wayland-0".into());
            }
        }
        None
    }

    /// GNOME or KDE, by `XDG_CURRENT_DESKTOP` (a `:`-separated list).
    pub fn desktop_names(&self) -> Vec<String> {
        self.current_desktop
            .as_deref()
            .unwrap_or("")
            .split(':')
            .filter(|s| !s.is_empty())
            .map(|s| s.to_ascii_lowercase())
            .collect()
    }
}

/// What a Wayland compositor offers, probed by [`wlroots::probe`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WaylandCaps {
    pub screencopy: bool,
    pub virtual_pointer: bool,
    pub virtual_keyboard: bool,
}

/// The decision of [`open`], kept pure so it is tested without a display.
pub fn choose(
    env: &Env,
    wayland: Option<WaylandCaps>,
    portal_remote_desktop: bool,
) -> Result<SessionKind, String> {
    if let Some(forced) = env.forced.as_deref() {
        return match forced {
            "x11" => env
                .display
                .clone()
                .map(|display| SessionKind::X11 { display })
                .ok_or_else(|| "CMUX_CU_LINUX_BACKEND=x11 but DISPLAY is not set".into()),
            "wlroots" => Ok(SessionKind::Wlroots),
            "portal" => Ok(SessionKind::Portal),
            other => Err(format!("CMUX_CU_LINUX_BACKEND={other:?}: use x11, wlroots or portal")),
        };
    }
    if env.wayland_socket().is_some() {
        if let Some(caps) = wayland
            && caps.screencopy
            && caps.virtual_pointer
        {
            return Ok(SessionKind::Wlroots);
        }
        if portal_remote_desktop {
            return Ok(SessionKind::Portal);
        }
        if let Some(display) = env.display.clone() {
            // XWayland only: X11 apps are reachable, Wayland-native ones are not.
            return Ok(SessionKind::X11 { display });
        }
        return Err(
            "this Wayland compositor offers neither wlr-screencopy with virtual input nor xdg-desktop-portal RemoteDesktop, and no XWayland DISPLAY is set"
                .into(),
        );
    }
    if let Some(display) = env.display.clone() {
        return Ok(SessionKind::X11 { display });
    }
    Err("no display: set DISPLAY (X11, Xvfb, Xvnc) or WAYLAND_DISPLAY".into())
}

/// The desktop for this session.
pub fn open() -> Result<Arc<dyn Desktop>, String> {
    let env = Env::from_process();
    let wayland = if env.forced.is_none() && env.wayland_socket().is_some() {
        wlroots::probe().ok()
    } else {
        None
    };
    let portal = env.forced.is_none()
        && env.wayland_socket().is_some()
        && !wayland.is_some_and(|c| c.screencopy && c.virtual_pointer)
        && portal::available();
    match choose(&env, wayland, portal)? {
        SessionKind::X11 { .. } => {
            let xwayland_only = env.wayland_socket().is_some();
            x11::X11Desktop::connect(xwayland_only).map(|d| Arc::new(d) as Arc<dyn Desktop>)
        }
        SessionKind::Wlroots => {
            wlroots::WlrootsDesktop::connect().map(|d| Arc::new(d) as Arc<dyn Desktop>)
        }
        SessionKind::Portal => {
            portal::PortalDesktop::connect(&env).map(|d| Arc::new(d) as Arc<dyn Desktop>)
        }
    }
}

/// The person's own input, for pause-on-takeover.
pub fn person_activity() -> Arc<dyn PersonActivity> {
    idle::open()
}

/// The cmux-blue agent cursor.
pub fn cursor_overlay() -> Arc<dyn CursorSink> {
    cursor::open()
}

// ---------------------------------------------------------------------------
// Our own synthetic input, so the idle monitors do not count it as the person.

static LAST_INJECTION_MS: AtomicU64 = AtomicU64::new(0);

pub(crate) fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Every route that sends input through the server marks it here.
pub(crate) fn mark_injection() {
    LAST_INJECTION_MS.store(now_ms(), Ordering::Relaxed);
}

pub(crate) fn last_injection_ms() -> u64 {
    LAST_INJECTION_MS.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// State dir (the portal restore token lives here).

static STATE_DIR: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// The worker calls this with its state dir (the same one it gives the
/// engine). Without it: `$CMUX_COMPUTER_USE_STATE_DIR`, then
/// `$XDG_STATE_HOME/cmux/computer-use`, then `~/.local/state/cmux/computer-use`.
pub fn set_state_dir(dir: PathBuf) {
    *STATE_DIR.get_or_init(|| Mutex::new(None)).lock().unwrap_or_else(|e| e.into_inner()) =
        Some(dir);
}

pub(crate) fn state_dir() -> Option<PathBuf> {
    if let Some(dir) = STATE_DIR.get().and_then(|m| m.lock().ok().and_then(|g| g.clone())) {
        return Some(dir);
    }
    if let Ok(dir) = std::env::var("CMUX_COMPUTER_USE_STATE_DIR")
        && !dir.is_empty()
    {
        return Some(PathBuf::from(dir));
    }
    let base =
        std::env::var("XDG_STATE_HOME").ok().filter(|v| !v.is_empty()).map(PathBuf::from).or_else(
            || std::env::var("HOME").ok().map(|h| PathBuf::from(h).join(".local/state")),
        )?;
    Some(base.join("cmux").join("computer-use"))
}

// ---------------------------------------------------------------------------
// App identity: the desktop file id where one can be found, else the
// executable name. Policy matches on it (`org.gnome.Terminal`, `1password`).

#[derive(Clone, Debug, Default)]
pub(crate) struct DesktopEntry {
    pub id: String,
    pub name: String,
    pub exec: String,
    pub startup_wm_class: Option<String>,
}

#[derive(Default)]
pub(crate) struct DesktopIndex {
    pub entries: Vec<DesktopEntry>,
}

impl DesktopIndex {
    pub fn load() -> Self {
        let mut dirs: Vec<PathBuf> = Vec::new();
        let home_data = std::env::var("XDG_DATA_HOME")
            .ok()
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var("HOME").ok().map(|h| PathBuf::from(h).join(".local/share")));
        if let Some(d) = home_data {
            dirs.push(d);
        }
        let data_dirs = std::env::var("XDG_DATA_DIRS")
            .ok()
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
        dirs.extend(data_dirs.split(':').filter(|s| !s.is_empty()).map(PathBuf::from));
        for extra in ["/var/lib/flatpak/exports/share", "/var/lib/snapd/desktop"] {
            dirs.push(PathBuf::from(extra));
        }
        let mut seen = std::collections::HashSet::new();
        let mut entries = Vec::new();
        for dir in dirs {
            let apps = dir.join("applications");
            let Ok(read) = std::fs::read_dir(&apps) else { continue };
            for entry in read.flatten() {
                let path = entry.path();
                let Some(file) = path.file_name().and_then(|f| f.to_str()) else { continue };
                let Some(id) = file.strip_suffix(".desktop") else { continue };
                if !seen.insert(id.to_string()) {
                    continue;
                }
                if let Ok(text) = std::fs::read_to_string(&path)
                    && let Some(e) = parse_desktop_entry(id, &text)
                {
                    entries.push(e);
                }
            }
        }
        Self { entries }
    }

    pub fn by_id(&self, id: &str) -> Option<&DesktopEntry> {
        let id = id.strip_suffix(".desktop").unwrap_or(id);
        self.entries
            .iter()
            .find(|e| e.id == id)
            .or_else(|| self.entries.iter().find(|e| e.id.eq_ignore_ascii_case(id)))
    }

    /// The entry for an X11 WM_CLASS (class, instance) or a Wayland app_id.
    pub fn for_class(&self, class: &str, instance: &str) -> Option<&DesktopEntry> {
        if class.is_empty() && instance.is_empty() {
            return None;
        }
        let wm = |e: &&DesktopEntry| {
            e.startup_wm_class
                .as_deref()
                .is_some_and(|w| w == class || (!instance.is_empty() && w == instance))
        };
        self.entries
            .iter()
            .find(wm)
            .or_else(|| self.by_id(class))
            .or_else(|| self.by_id(instance))
            .or_else(|| {
                // `org.gnome.TextEditor` for class `gnome-text-editor` is not
                // derivable; a reverse-DNS id ending in the class is.
                let lower = class.to_ascii_lowercase();
                self.entries.iter().find(|e| {
                    e.id.rsplit('.').next().is_some_and(|last| last.eq_ignore_ascii_case(&lower))
                })
            })
    }
}

pub(crate) fn parse_desktop_entry(id: &str, text: &str) -> Option<DesktopEntry> {
    let mut in_main = false;
    let mut e = DesktopEntry { id: id.to_string(), ..DesktopEntry::default() };
    let mut hidden = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_main = line == "[Desktop Entry]";
            continue;
        }
        if !in_main {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else { continue };
        match k.trim() {
            "Name" => e.name = v.trim().to_string(),
            "Exec" => e.exec = v.trim().to_string(),
            "StartupWMClass" => e.startup_wm_class = Some(v.trim().to_string()),
            "Hidden" => hidden = v.trim() == "true",
            "Type" if v.trim() != "Application" => return None,
            _ => {}
        }
    }
    if hidden {
        return None;
    }
    Some(e)
}

/// The argv of a desktop entry's `Exec`, with field codes removed.
pub(crate) fn exec_argv(exec: &str) -> Vec<String> {
    let mut args = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut chars = exec.chars().peekable();
    let mut any = false;
    while let Some(c) = chars.next() {
        match c {
            '"' => {
                in_quotes = !in_quotes;
                any = true;
            }
            '\\' if in_quotes => {
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
            }
            ' ' | '\t' if !in_quotes => {
                if any || !cur.is_empty() {
                    args.push(std::mem::take(&mut cur));
                    any = false;
                }
            }
            '%' => {
                if chars.next() == Some('%') {
                    cur.push('%');
                }
            }
            c => cur.push(c),
        }
    }
    if any || !cur.is_empty() {
        args.push(cur);
    }
    args.retain(|a| !a.is_empty());
    args
}

/// Resolves app ids and names, caching the desktop file index.
#[derive(Default)]
pub(crate) struct AppResolver {
    index: Mutex<Option<(std::time::Instant, Arc<DesktopIndex>)>>,
}

impl AppResolver {
    pub fn index(&self) -> Arc<DesktopIndex> {
        let mut g = self.index.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, idx)) = g.as_ref()
            && at.elapsed() < std::time::Duration::from_secs(60)
        {
            return idx.clone();
        }
        let idx = Arc::new(DesktopIndex::load());
        *g = Some((std::time::Instant::now(), idx.clone()));
        idx
    }

    /// (app id, display name) for a window, from what the window system
    /// reports about it: its X11 WM_CLASS (class, instance), Wayland app_id or
    /// accessibility app name. cmux-next never reads another process
    /// (plans/cmux-next/pty-holder.md), so no /proc lookup.
    pub fn resolve(&self, class: &str, instance: &str) -> (String, String) {
        let index = self.index();
        if let Some(e) = index.by_id(class).or_else(|| index.for_class(class, instance)) {
            let name = if e.name.is_empty() { e.id.clone() } else { e.name.clone() };
            return (e.id.clone(), name);
        }
        if !class.is_empty() {
            return (class.to_string(), class.to_string());
        }
        if !instance.is_empty() {
            return (instance.to_string(), instance.to_string());
        }
        ("unknown".into(), "unknown".into())
    }
}

/// Compositor and shell apps whose own accessible frames (panels, overlays)
/// are not app windows, by their accessibility app name.
pub(crate) fn is_shell_app(app_name: &str) -> bool {
    matches!(
        app_name,
        "gnome-shell"
            | "kwin_wayland"
            | "kwin_x11"
            | "plasmashell"
            | "mutter"
            | "gnome-shell-calendar-server"
    )
}

/// What `launch(app_id)` would start, as policy ids: the desktop-file id, the
/// program's file name, and every desktop entry that runs that program (so
/// `konsole` is also `org.kde.konsole`).
pub(crate) fn launch_identities(
    resolver: &AppResolver,
    app_id: &str,
) -> crate::desktop::DResult<Vec<String>> {
    use crate::desktop::DesktopError;
    let index = resolver.index();
    let program = if let Some(e) = index.by_id(app_id) {
        exec_argv(&e.exec).into_iter().next()
    } else if !app_id.contains('/') && which(app_id).is_some() {
        Some(app_id.to_string())
    } else {
        return Err(DesktopError::TargetNotFound(format!(
            "no desktop file or executable named {app_id:?}"
        )));
    };
    let mut ids = vec![app_id.to_string()];
    if let Some(e) = index.by_id(app_id) {
        ids.push(e.id.clone());
    }
    if let Some(program) = program {
        let base = Path::new(&program)
            .file_name()
            .and_then(|f| f.to_str())
            .unwrap_or(program.as_str())
            .to_string();
        for e in index.entries.iter() {
            let runs = exec_argv(&e.exec).into_iter().next().is_some_and(|p| {
                Path::new(&p).file_name().and_then(|f| f.to_str()) == Some(base.as_str())
            });
            if runs {
                ids.push(e.id.clone());
            }
        }
        ids.push(base);
    }
    // The first id is the one approvals are saved under: the desktop id when
    // the agent named one, else the program; the rest only widen the check.
    let primary = index.by_id(app_id).map(|e| e.id.clone()).unwrap_or_else(|| app_id.to_string());
    ids.retain(|id| *id != primary);
    ids.sort();
    ids.dedup();
    ids.insert(0, primary);
    Ok(ids)
}

/// Starts an app by desktop file id or executable name, detached from us.
pub(crate) fn launch(
    resolver: &AppResolver,
    app_id: &str,
) -> crate::desktop::DResult<crate::desktop::App> {
    use crate::desktop::{App, DesktopError};
    let index = resolver.index();
    let (argv, id, name) = if let Some(e) = index.by_id(app_id) {
        (
            exec_argv(&e.exec),
            e.id.clone(),
            if e.name.is_empty() { e.id.clone() } else { e.name.clone() },
        )
    } else if !app_id.contains('/') && which(app_id).is_some() {
        (vec![app_id.to_string()], app_id.to_string(), app_id.to_string())
    } else {
        return Err(DesktopError::TargetNotFound(format!(
            "no desktop file or executable named {app_id:?}"
        )));
    };
    let Some((prog, rest)) = argv.split_first() else {
        return Err(DesktopError::Failed(format!("{app_id}: empty Exec line")));
    };
    let mut cmd = std::process::Command::new(prog);
    cmd.args(rest)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .env("GIO_LAUNCHED_DESKTOP_FILE", format!("{id}.desktop"));
    {
        use std::os::unix::process::CommandExt;
        // Its own session, so it outlives the worker and gets no signals from it.
        // SAFETY: setsid is async-signal-safe and touches no Rust state.
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }
    let child = cmd.spawn().map_err(|e| DesktopError::Failed(format!("start {prog}: {e}")))?;
    Ok(App { id, name, pid: child.id(), frontmost: false, hidden: false })
}

pub(crate) fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file())
}

/// Bounds of several rects (the layout box).
pub(crate) fn union(rects: &[Rect]) -> Option<Rect> {
    let first = rects.first()?;
    let (mut x0, mut y0, mut x1, mut y1) =
        (first.x, first.y, first.x + first.width, first.y + first.height);
    for r in rects.iter().skip(1) {
        x0 = x0.min(r.x);
        y0 = y0.min(r.y);
        x1 = x1.max(r.x + r.width);
        y1 = y1.max(r.y + r.height);
    }
    Some(Rect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 })
}

pub(crate) fn contains(r: &Rect, x: f64, y: f64) -> bool {
    x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height
}

/// Crops an RGBA frame to `rect` (in the frame's own pixels).
pub(crate) fn crop_rgba(
    rgba: &[u8],
    width: u32,
    height: u32,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
) -> Option<(Vec<u8>, u32, u32, i64, i64)> {
    let x0 = x.clamp(0, width as i64);
    let y0 = y.clamp(0, height as i64);
    let x1 = (x + w).clamp(0, width as i64);
    let y1 = (y + h).clamp(0, height as i64);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let (cw, ch) = ((x1 - x0) as usize, (y1 - y0) as usize);
    let mut out = Vec::with_capacity(cw * ch * 4);
    for row in y0 as usize..y1 as usize {
        let start = (row * width as usize + x0 as usize) * 4;
        out.extend_from_slice(&rgba[start..start + cw * 4]);
    }
    Some((out, cw as u32, ch as u32, x0, y0))
}

/// Short-lived memo for expensive listings the engine asks for several
/// times per call.
pub(crate) struct Memo<T: Clone> {
    ttl: std::time::Duration,
    slot: Mutex<Option<(std::time::Instant, T)>>,
}

impl<T: Clone> Memo<T> {
    pub fn new(ttl: std::time::Duration) -> Self {
        Self { ttl, slot: Mutex::new(None) }
    }
    pub fn get_or<E>(&self, f: impl FnOnce() -> Result<T, E>) -> Result<T, E> {
        let mut g = self.slot.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, v)) = g.as_ref()
            && at.elapsed() < self.ttl
        {
            return Ok(v.clone());
        }
        let v = f()?;
        *g = Some((std::time::Instant::now(), v.clone()));
        Ok(v)
    }
    pub fn clear(&self) {
        *self.slot.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

#[cfg(test)]
mod tests;
