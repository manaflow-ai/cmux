//! X11: any window manager or desktop, XWayland, and headless X servers.
//!
//! - Windows: EWMH `_NET_CLIENT_LIST` (stacking order where the WM keeps
//!   it), else the root's mapped children with `WM_STATE` or `WM_CLASS`
//!   (a bare Xvfb has no window manager). The id is the client window id.
//! - Pixels: [`capture`]. Input: [`input`].
//! - Trees and semantic actions: AT-SPI ([`super::atspi`]) with screen
//!   coordinates, which X11 toolkits report.
//!
//! Headless: an Xvfb server (its RandR monitor is named `screen`) or
//! `CMUX_CU_HEADLESS=1` (cmux cloud images set it) has no person sharing the
//! pointer, so XTest may be used for background input there, still only on
//! a window that is on top at the point or holds the keyboard focus. An
//! Xvnc server is treated as a person's desktop: someone may be watching
//! and using it over VNC. `CMUX_CU_HEADLESS=0` treats an Xvfb display the
//! same way (someone watches it).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use x11rb::connection::{Connection as _, RequestConnection as _};
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::res::{ClientIdMask, ClientIdSpec, ConnectionExt as _};
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, MapState, Window as XWindow, WindowClass,
};
use x11rb::rust_connection::RustConnection;

use super::atspi::{Atspi, Coords};
use super::{AppResolver, Memo};
use crate::desktop::*;
use crate::keys::KeyCombo;

pub(crate) mod capture;
mod input;

pub(crate) struct Atoms {
    pub net_client_list: Atom,
    pub net_client_list_stacking: Atom,
    pub net_active_window: Atom,
    pub net_wm_name: Atom,
    pub net_wm_pid: Atom,
    pub net_wm_state: Atom,
    pub net_wm_state_hidden: Atom,
    pub net_wm_desktop: Atom,
    pub net_current_desktop: Atom,
    pub net_wm_window_type: Atom,
    pub net_wm_window_type_desktop: Atom,
    pub net_wm_window_type_dock: Atom,
    pub net_supporting_wm_check: Atom,
    pub net_wm_cm_s0: Atom,
    pub wm_state: Atom,
    pub wm_protocols: Atom,
    pub wm_take_focus: Atom,
    pub net_wm_ping: Atom,
    pub xim_servers: Atom,
    pub utf8_string: Atom,
    pub overlay: Atom,
}

/// The property our agent cursor window carries.
pub(crate) const OVERLAY_ATOM: &str = "_CMUX_CU_OVERLAY";

impl Atoms {
    fn intern(conn: &RustConnection) -> Result<Self, String> {
        let get = |name: &str| -> Result<Atom, String> {
            conn.intern_atom(false, name.as_bytes())
                .map_err(|e| e.to_string())?
                .reply()
                .map(|r| r.atom)
                .map_err(|e| e.to_string())
        };
        Ok(Self {
            net_client_list: get("_NET_CLIENT_LIST")?,
            net_client_list_stacking: get("_NET_CLIENT_LIST_STACKING")?,
            net_active_window: get("_NET_ACTIVE_WINDOW")?,
            net_wm_name: get("_NET_WM_NAME")?,
            net_wm_pid: get("_NET_WM_PID")?,
            net_wm_state: get("_NET_WM_STATE")?,
            net_wm_state_hidden: get("_NET_WM_STATE_HIDDEN")?,
            net_wm_desktop: get("_NET_WM_DESKTOP")?,
            net_current_desktop: get("_NET_CURRENT_DESKTOP")?,
            net_wm_window_type: get("_NET_WM_WINDOW_TYPE")?,
            net_wm_window_type_desktop: get("_NET_WM_WINDOW_TYPE_DESKTOP")?,
            net_wm_window_type_dock: get("_NET_WM_WINDOW_TYPE_DOCK")?,
            net_supporting_wm_check: get("_NET_SUPPORTING_WM_CHECK")?,
            net_wm_cm_s0: get("_NET_WM_CM_S0")?,
            wm_state: get("WM_STATE")?,
            wm_protocols: get("WM_PROTOCOLS")?,
            wm_take_focus: get("WM_TAKE_FOCUS")?,
            net_wm_ping: get("_NET_WM_PING")?,
            xim_servers: get("XIM_SERVERS")?,
            utf8_string: get("UTF8_STRING")?,
            overlay: get(OVERLAY_ATOM)?,
        })
    }
}

/// Whether a client with these `WM_PROTOCOLS` keeps track of its keyboard
/// focus only from FocusIn and FocusOut events and drops keys while it
/// thinks it lacks focus: Tk, Xt/Motif and plain Xlib clients, which
/// speak neither `WM_TAKE_FOCUS` nor `_NET_WM_PING`. GTK, Qt and Chromium
/// speak both and take window-scoped keys without focus; a synthetic
/// FocusIn could make them act (Qt hands activation to a modal dialog,
/// GTK moves the input method), so they never get one.
pub(crate) fn tracks_focus_from_events(protocols: &[Atom], take_focus: Atom, ping: Atom) -> bool {
    !protocols.iter().any(|p| *p == take_focus || *p == ping)
}

/// A window's `WM_PROTOCOLS`: `Some` (possibly empty) when the read worked
/// and the property is absent or a list of atoms, `None` when it failed.
pub(crate) fn read_protocols(
    conn: &RustConnection,
    win: XWindow,
    wm_protocols: Atom,
) -> Option<Vec<Atom>> {
    let r =
        conn.get_property(false, win, wm_protocols, AtomEnum::ATOM, 0, 256).ok()?.reply().ok()?;
    if r.format == 0 {
        return Some(Vec::new());
    }
    Some(r.value32()?.collect())
}

/// One client window as X11 describes it.
#[derive(Clone, Debug)]
pub(crate) struct Client {
    pub win: XWindow,
    /// The root child that holds it (the WM frame, or itself).
    pub frame_win: XWindow,
    pub pid: u32,
    pub class: String,
    pub instance: String,
    pub title: String,
    pub rect: Rect,
    pub viewable: bool,
    pub hidden: bool,
    pub other_desktop: bool,
}

pub struct X11Desktop {
    pub(crate) conn: RustConnection,
    pub(crate) root: XWindow,
    pub(crate) atoms: Atoms,
    pub(crate) headless: bool,
    xwayland_only: bool,
    vendor: String,
    apps: AppResolver,
    atspi: Mutex<Option<Arc<Atspi>>>,
    clients: Memo<Vec<Client>>,
    pub(crate) has_xtest: bool,
    pub(crate) has_composite: bool,
    pub(crate) has_damage: bool,
}

pub(crate) fn xerr(e: impl std::fmt::Display) -> DesktopError {
    DesktopError::Failed(format!("X11: {e}"))
}

impl X11Desktop {
    /// Connects to `$DISPLAY`. `xwayland_only` marks a Wayland session where
    /// only X11 apps are reachable.
    pub fn connect(xwayland_only: bool) -> Result<Self, String> {
        let (conn, screen) =
            x11rb::connect(None).map_err(|e| format!("cannot open X display: {e}"))?;
        let root =
            conn.setup().roots.get(screen).map(|s| s.root).ok_or("X server has no screen")?;
        let vendor = String::from_utf8_lossy(&conn.setup().vendor).into_owned();
        let atoms = Atoms::intern(&conn)?;
        let has = |name: &'static str| conn.extension_information(name).ok().flatten().is_some();
        let has_xtest = has(x11rb::protocol::xtest::X11_EXTENSION_NAME);
        let has_composite = has(x11rb::protocol::composite::X11_EXTENSION_NAME);
        let has_damage = has(x11rb::protocol::damage::X11_EXTENSION_NAME);
        let mut me = Self {
            conn,
            root,
            atoms,
            headless: false,
            xwayland_only,
            vendor,
            apps: AppResolver::default(),
            atspi: Mutex::new(None),
            clients: Memo::new(Duration::from_millis(150)),
            has_xtest,
            has_composite,
            has_damage,
        };
        me.headless = super::headless_override()
            .unwrap_or_else(|| me.monitors().iter().any(|m| m.name == "screen"));
        Ok(me)
    }

    pub(crate) fn atspi(&self) -> Option<Arc<Atspi>> {
        let mut g = self.atspi.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_none() {
            *g = Atspi::connect().ok().map(Arc::new);
        }
        g.clone()
    }

    fn prop(&self, win: XWindow, atom: Atom, ty: impl Into<Atom>) -> Option<Vec<u8>> {
        let r = self.conn.get_property(false, win, atom, ty, 0, 1 << 16).ok()?.reply().ok()?;
        if r.format == 0 { None } else { Some(r.value) }
    }

    pub(crate) fn prop32(&self, win: XWindow, atom: Atom, ty: impl Into<Atom>) -> Vec<u32> {
        let Ok(Ok(r)) = self.conn.get_property(false, win, atom, ty, 0, 1 << 16).map(|c| c.reply())
        else {
            return Vec::new();
        };
        r.value32().map(|v| v.collect()).unwrap_or_default()
    }

    fn title(&self, win: XWindow) -> String {
        if let Some(v) = self.prop(win, self.atoms.net_wm_name, self.atoms.utf8_string) {
            return String::from_utf8_lossy(&v).into_owned();
        }
        self.prop(win, AtomEnum::WM_NAME.into(), AtomEnum::ANY)
            .map(|v| v.iter().map(|b| *b as char).collect())
            .unwrap_or_default()
    }

    fn wm_class(&self, win: XWindow) -> Option<(String, String)> {
        let v = self.prop(win, AtomEnum::WM_CLASS.into(), AtomEnum::STRING)?;
        let mut parts = v.split(|b| *b == 0).map(|s| String::from_utf8_lossy(s).into_owned());
        let instance = parts.next().unwrap_or_default();
        let class = parts.next().unwrap_or_default();
        Some((class, instance))
    }

    fn pid(&self, win: XWindow) -> u32 {
        if let Some(p) = self.prop32(win, self.atoms.net_wm_pid, AtomEnum::CARDINAL).first() {
            return *p;
        }
        // XRes knows the pid of local clients even without _NET_WM_PID.
        let spec = ClientIdSpec { client: win, mask: ClientIdMask::LOCAL_CLIENT_PID };
        self.conn
            .res_query_client_ids(&[spec])
            .ok()
            .and_then(|c| c.reply().ok())
            .and_then(|r| r.ids.into_iter().find_map(|id| id.value.first().copied()))
            .unwrap_or(0)
    }

    /// The root child that holds `win`.
    pub(crate) fn top_of(&self, win: XWindow) -> XWindow {
        let mut cur = win;
        for _ in 0..16 {
            let Ok(Ok(t)) = self.conn.query_tree(cur).map(|c| c.reply()) else { return cur };
            if t.parent == self.root || t.parent == 0 {
                return cur;
            }
            cur = t.parent;
        }
        cur
    }

    /// True for a mapped root child that takes part in stacking (not our
    /// own click-through cursor).
    pub(crate) fn stacks(&self, win: XWindow) -> bool {
        let mapped = self
            .conn
            .get_window_attributes(win)
            .ok()
            .and_then(|q| q.reply().ok())
            .is_some_and(|a| a.map_state == MapState::VIEWABLE);
        mapped && self.prop(win, self.atoms.overlay, AtomEnum::ANY).is_none()
    }

    pub(crate) fn rect_of(&self, win: XWindow) -> Option<Rect> {
        let g = self.conn.get_geometry(win).ok()?.reply().ok()?;
        let t = self.conn.translate_coordinates(win, self.root, 0, 0).ok()?.reply().ok()?;
        Some(Rect {
            x: f64::from(t.dst_x),
            y: f64::from(t.dst_y),
            width: f64::from(g.width),
            height: f64::from(g.height),
        })
    }

    fn is_skipped_type(&self, win: XWindow) -> bool {
        let types = self.prop32(win, self.atoms.net_wm_window_type, AtomEnum::ATOM);
        types.iter().any(|t| {
            *t == self.atoms.net_wm_window_type_desktop || *t == self.atoms.net_wm_window_type_dock
        })
    }

    /// Client windows, bottom to top where the WM tells the stacking order.
    fn client_ids(&self) -> Vec<XWindow> {
        let stacking =
            self.prop32(self.root, self.atoms.net_client_list_stacking, AtomEnum::WINDOW);
        if !stacking.is_empty() {
            return stacking;
        }
        let list = self.prop32(self.root, self.atoms.net_client_list, AtomEnum::WINDOW);
        if !list.is_empty() {
            return list;
        }
        let Ok(Ok(tree)) = self.conn.query_tree(self.root).map(|c| c.reply()) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for child in tree.children {
            if self.prop(child, self.atoms.wm_state, AtomEnum::ANY).is_some()
                || self.wm_class(child).is_some()
            {
                out.push(child);
                continue;
            }
            // A reparenting WM without EWMH: the client is one level down.
            if let Ok(Ok(sub)) = self.conn.query_tree(child).map(|c| c.reply()) {
                out.extend(
                    sub.children
                        .into_iter()
                        .filter(|c| self.prop(*c, self.atoms.wm_state, AtomEnum::ANY).is_some()),
                );
            }
        }
        out
    }

    fn describe(&self, win: XWindow, current_desktop: Option<u32>) -> Option<Client> {
        let attrs = self.conn.get_window_attributes(win).ok()?.reply().ok()?;
        if attrs.override_redirect
            || attrs.class == WindowClass::INPUT_ONLY
            || self.is_skipped_type(win)
        {
            return None;
        }
        let (class, instance) = self.wm_class(win).unwrap_or_default();
        let rect = self.rect_of(win)?;
        let frame_win = self.top_of(win);
        let frame_viewable = frame_win == win
            || self.conn.get_window_attributes(frame_win).ok()?.reply().ok()?.map_state
                == MapState::VIEWABLE;
        let states = self.prop32(win, self.atoms.net_wm_state, AtomEnum::ATOM);
        let desktop =
            self.prop32(win, self.atoms.net_wm_desktop, AtomEnum::CARDINAL).first().copied();
        let other_desktop =
            matches!((desktop, current_desktop), (Some(d), Some(c)) if d != c && d != u32::MAX);
        Some(Client {
            win,
            frame_win,
            pid: self.pid(win),
            title: self.title(win),
            class,
            instance,
            rect,
            viewable: attrs.map_state == MapState::VIEWABLE && frame_viewable,
            hidden: states.contains(&self.atoms.net_wm_state_hidden),
            other_desktop,
        })
    }

    pub(crate) fn clients(&self) -> DResult<Vec<Client>> {
        self.clients.get_or(|| {
            let current = self
                .prop32(self.root, self.atoms.net_current_desktop, AtomEnum::CARDINAL)
                .first()
                .copied();
            let ids = self.client_ids();
            Ok(ids.into_iter().filter_map(|w| self.describe(w, current)).collect())
        })
    }

    pub(crate) fn client(&self, window_id: &str) -> DResult<Client> {
        let win = parse_window_id(window_id)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("window {window_id:?}")))?;
        self.clients()?.into_iter().find(|c| c.win == win).ok_or_else(|| {
            DesktopError::TargetNotFound(format!("window {window_id} is gone; call list_windows"))
        })
    }

    pub(crate) fn active_window(&self) -> Option<XWindow> {
        if let Some(w) =
            self.prop32(self.root, self.atoms.net_active_window, AtomEnum::WINDOW).first()
            && *w != 0
        {
            return Some(*w);
        }
        let focus = self.conn.get_input_focus().ok()?.reply().ok()?.focus;
        if focus <= 1 { None } else { Some(focus) }
    }

    pub(crate) fn invalidate(&self) {
        self.clients.clear();
    }

    pub(crate) fn monitors(&self) -> Vec<Monitor> {
        let Ok(Ok(r)) = self.conn.randr_get_monitors(self.root, true).map(|c| c.reply()) else {
            return Vec::new();
        };
        r.monitors
            .into_iter()
            .map(|m| Monitor {
                name: self
                    .conn
                    .get_atom_name(m.name)
                    .ok()
                    .and_then(|c| c.reply().ok())
                    .map(|n| String::from_utf8_lossy(&n.name).into_owned())
                    .unwrap_or_default(),
                primary: m.primary,
                rect: Rect {
                    x: f64::from(m.x),
                    y: f64::from(m.y),
                    width: f64::from(m.width),
                    height: f64::from(m.height),
                },
            })
            .collect()
    }

    fn app_of(&self, c: &Client) -> (String, String) {
        self.apps.resolve(&c.class, &c.instance)
    }

    pub(crate) fn frame_obj(&self, c: &Client) -> DResult<(Arc<Atspi>, super::atspi::Frame)> {
        let a = self.atspi().ok_or_else(|| {
            DesktopError::Unsupported(
                "the accessibility bus (AT-SPI) is not running in this session".into(),
            )
        })?;
        let f = a.frame_for(c.pid, &c.title, Some(c.rect), Coords::Screen)?;
        Ok((a, f))
    }

    fn wm_name(&self) -> String {
        let check = self.prop32(self.root, self.atoms.net_supporting_wm_check, AtomEnum::WINDOW);
        check
            .first()
            .map(|w| self.title(*w))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| "no window manager".into())
    }
}

#[derive(Clone, Debug)]
pub(crate) struct Monitor {
    pub name: String,
    pub primary: bool,
    pub rect: Rect,
}

pub(crate) fn parse_window_id(id: &str) -> Option<XWindow> {
    let id = id.trim();
    match id.strip_prefix("0x") {
        Some(hex) => u32::from_str_radix(hex, 16).ok(),
        None => id.parse().ok(),
    }
}

pub(crate) fn window_id(win: XWindow) -> String {
    format!("0x{win:x}")
}

impl Desktop for X11Desktop {
    fn info(&self) -> PlatformInfo {
        let server = if self.headless { "headless-x11" } else { "x11" };
        let de = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
        let mut detail = format!("{}; {}", self.vendor, self.wm_name());
        if !de.is_empty() {
            detail.push_str(&format!("; {de}"));
        }
        if self.xwayland_only {
            detail.push_str("; XWayland only (Wayland-native windows are not reachable)");
        }
        PlatformInfo { os: "linux".into(), display_server: server.into(), detail }
    }

    fn permissions(&self) -> Permissions {
        let accessibility = if self.atspi().is_some() { Grant::Granted } else { Grant::Unknown };
        let input = if self.has_xtest { Grant::NotNeeded } else { Grant::Denied };
        Permissions { accessibility, screen_capture: Grant::NotNeeded, input }
    }

    fn list_apps(&self) -> DResult<Vec<App>> {
        let clients = self.clients()?;
        let active = self.active_window();
        let mut apps: Vec<App> = Vec::new();
        for c in &clients {
            let (id, name) = self.app_of(c);
            let front = active == Some(c.win);
            if let Some(a) = apps.iter_mut().find(|a| a.id == id && a.pid == c.pid) {
                a.frontmost |= front;
                a.hidden &= c.hidden || !c.viewable;
                continue;
            }
            apps.push(App {
                id,
                name,
                pid: c.pid,
                frontmost: front,
                hidden: c.hidden || !c.viewable,
            });
        }
        Ok(apps)
    }

    fn list_windows(&self) -> DResult<Vec<Window>> {
        let active = self.active_window();
        let mut out: Vec<Window> = self
            .clients()?
            .iter()
            .map(|c| Window {
                id: window_id(c.win),
                app_id: self.app_of(c).0,
                pid: c.pid,
                title: c.title.clone(),
                frame: c.rect,
                on_screen: c.viewable && !c.hidden && !c.other_desktop,
                focused: active == Some(c.win),
                minimized: c.hidden || (!c.viewable && !c.other_desktop),
            })
            .collect();
        // Top-most first, as on the other platforms.
        out.reverse();
        Ok(out)
    }

    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        match target {
            CaptureTarget::Window(id) => self.capture_window(&self.client(id)?),
            CaptureTarget::Display(name) => self.capture_display(name.as_deref()),
        }
    }

    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let c = self.client(window_id)?;
        let (a, f) = self.frame_obj(&c)?;
        a.tree(window_id, &f.obj, Coords::Screen, options)
    }

    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        self.click_impl(target, spec)
    }

    fn type_text(
        &self,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        self.type_impl(window_id, element_id, text, delivery)
    }

    fn press_keys(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        self.keys_impl(window_id, combo, delivery)
    }

    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome> {
        self.scroll_impl(target, dx, dy)
    }

    fn drag(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        button: Button,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        self.drag_impl(window_id, from, to, button, delivery)
    }

    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome> {
        let c = self.client(window_id)?;
        let (a, _) = self.frame_obj(&c)?;
        let obj = a.element(window_id, element_id)?;
        let at = a.center(&obj, Coords::Screen);
        let confirmed = a.set_value(&obj, value)?;
        let out = if confirmed {
            ActionOutcome::confirmed("atspi_set_value")
        } else {
            ActionOutcome::delivered("atspi_set_value")
        };
        Ok(match at {
            Some(p) => out.at(p),
            None => out,
        })
    }

    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome> {
        let c = self.client(window_id)?;
        let (a, _) = self.frame_obj(&c)?;
        let obj = a.element(window_id, element_id)?;
        let at = a.center(&obj, Coords::Screen);
        a.perform(&obj, action)?;
        let out = ActionOutcome::delivered("atspi_action");
        Ok(match at {
            Some(p) => out.at(p),
            None => out,
        })
    }

    fn launch_app(&self, app_id: &str) -> DResult<App> {
        self.invalidate();
        super::launch(&self.apps, app_id)
    }

    fn launch_identities(&self, app_id: &str) -> DResult<Vec<String>> {
        super::launch_identities(&self.apps, app_id)
    }
}
