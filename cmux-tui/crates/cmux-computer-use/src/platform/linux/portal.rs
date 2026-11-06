//! GNOME (Mutter), KDE Plasma and other Wayland desktops through
//! xdg-desktop-portal.
//!
//! - Windows: AT-SPI frames (the portals list none). Their ids are the
//!   frame's accessible (`a11y:<bus>|<path>`).
//! - Pixels: the Screenshot portal (non-interactive), for the whole desktop.
//!   Window shots are refused: these compositors do not tell an outside
//!   process where a window is.
//! - Input: AT-SPI first (actions, text insert, values: the background
//!   route). Keys go through a RemoteDesktop session
//!   (`NotifyKeyboardKeysym`), which is global, so only with
//!   `Delivery::Foreground` and only while the target window is the active
//!   one. The person approves the session once: the restore token
//!   (persist mode 2) is kept in the state dir and offered on every later
//!   start, so the portal does not ask again.
//! - Pointer at a point: refused (no window positions); element actions work.
//!
//! libei (`ConnectToEIS`) would avoid the D-Bus round trip per event; the
//! Notify* methods are enough for agent-speed input and work on every
//! RemoteDesktop portal version.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use super::atspi::{Atspi, Coords, Frame};
use super::{AppResolver, Env, keysym};
use crate::desktop::*;
use crate::keys::{KeyCombo, Modifier};

const DEST: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const RD: &str = "org.freedesktop.portal.RemoteDesktop";
const SC: &str = "org.freedesktop.portal.ScreenCast";
const SHOT: &str = "org.freedesktop.portal.Screenshot";
const TOKEN_FILE: &str = "portal-remote-desktop.token";

/// True when the session bus has a RemoteDesktop portal.
pub fn available() -> bool {
    let Ok(conn) = Connection::session() else { return false };
    conn.call_method(Some(DEST), PATH, Some("org.freedesktop.DBus.Properties"), "Get", &(RD, "version"))
        .is_ok()
}

type Results = HashMap<String, OwnedValue>;

/// The portal request pattern: call with a handle_token, wait for the
/// Response signal on the predicted request path.
fn request(conn: &Connection, iface: &str, method: &str, build: impl FnOnce(String) -> Result<zbus::Message, zbus::Error>, wait: Duration) -> DResult<Results> {
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);
    let token = format!("cmux{}_{}", std::process::id(), NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
    let sender = conn.unique_name().map(|n| n.trim_start_matches(':').replace('.', "_")).unwrap_or_default();
    let path = format!("{PATH}/request/{sender}/{token}");
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .interface("org.freedesktop.portal.Request")
        .and_then(|b| b.member("Response"))
        .and_then(|b| b.path(path.clone()))
        .map_err(|e| perr(iface, method, e))?
        .build();
    let iter = zbus::blocking::MessageIterator::for_match_rule(rule, conn, Some(4)).map_err(|e| perr(iface, method, e))?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for msg in iter {
            let Ok(msg) = msg else { continue };
            let body: Result<(u32, Results), _> = msg.body().deserialize();
            let _ = tx.send(body.map_err(|e| e.to_string()));
            return;
        }
    });
    let msg = build(token).map_err(|e| perr(iface, method, e))?;
    conn.send(&msg).map_err(|e| perr(iface, method, e))?;
    let (code, results) = rx
        .recv_timeout(wait)
        .map_err(|_| DesktopError::Failed(format!("{iface}.{method}: no answer from the portal")))?
        .map_err(DesktopError::Failed)?;
    match code {
        0 => Ok(results),
        1 => Err(DesktopError::PermissionMissing("input".into())),
        _ => Err(DesktopError::Failed(format!("{iface}.{method} failed in the portal"))),
    }
}

fn perr(iface: &str, method: &str, e: impl std::fmt::Display) -> DesktopError {
    DesktopError::Failed(format!("{iface}.{method}: {e}"))
}

struct Session {
    handle: OwnedObjectPath,
    /// (node, x, y, w, h) of each monitor stream.
    streams: Vec<(u32, Rect)>,
}

pub struct PortalDesktop {
    conn: Connection,
    desktop: String,
    apps: AppResolver,
    atspi: Mutex<Option<Arc<Atspi>>>,
    session: Mutex<Option<Session>>,
}

impl PortalDesktop {
    pub fn connect(env: &Env) -> Result<Self, String> {
        let conn = Connection::session().map_err(|e| format!("D-Bus session bus: {e}"))?;
        let desktop = env.desktop_names().join(":");
        Ok(Self { conn, desktop, apps: AppResolver::default(), atspi: Mutex::new(None), session: Mutex::new(None) })
    }

    fn atspi(&self) -> DResult<Arc<Atspi>> {
        let mut g = self.atspi.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_none() {
            *g = Atspi::connect().ok().map(Arc::new);
        }
        g.clone().ok_or_else(|| DesktopError::Unsupported("the accessibility bus (AT-SPI) is not running".into()))
    }

    fn frames(&self) -> DResult<Vec<Frame>> {
        self.atspi()?.frames(|_| Coords::Screen)
    }

    fn frame(&self, window_id: &str) -> DResult<(Arc<Atspi>, Frame)> {
        let id = window_id.strip_prefix("a11y:").unwrap_or(window_id);
        let a = self.atspi()?;
        let f = a
            .frames(|_| Coords::Screen)?
            .into_iter()
            .find(|f| f.obj.id() == id)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("window {window_id} is gone; call list_windows")))?;
        Ok((a, f))
    }

    fn call(&self, iface: &str, method: &str, body: &(impl serde::Serialize + zbus::zvariant::DynamicType)) -> DResult<()> {
        self.conn.call_method(Some(DEST), PATH, Some(iface), method, body).map_err(|e| perr(iface, method, e))?;
        Ok(())
    }

    fn token_path() -> Option<std::path::PathBuf> {
        super::state_dir().map(|d| d.join(TOKEN_FILE))
    }

    /// Starts (or reuses) the RemoteDesktop session.
    fn session(&self) -> DResult<std::sync::MutexGuard<'_, Option<Session>>> {
        let mut g = self.session.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_none() {
            *g = Some(self.start_session()?);
        }
        Ok(g)
    }

    fn start_session(&self) -> DResult<Session> {
        let short = Duration::from_secs(10);
        let created = request(&self.conn, RD, "CreateSession", |t| {
            let opts = opts(&[("handle_token", Value::from(t)), ("session_handle_token", Value::from("cmuxcu"))]);
            msg(RD, "CreateSession", &(opts,))
        }, short)?;
        let handle: String = created
            .get("session_handle")
            .and_then(|v| String::try_from(v.clone()).ok())
            .ok_or_else(|| DesktopError::Failed("the portal gave no session".into()))?;
        let handle = OwnedObjectPath::try_from(handle).map_err(|e| DesktopError::Failed(e.to_string()))?;
        let restore = Self::token_path().and_then(|p| std::fs::read_to_string(p).ok()).map(|s| s.trim().to_string());
        request(&self.conn, RD, "SelectDevices", |t| {
            let mut o = vec![
                ("handle_token", Value::from(t)),
                ("types", Value::from(3u32)),
                ("persist_mode", Value::from(2u32)),
            ];
            if let Some(r) = restore.clone().filter(|r| !r.is_empty()) {
                o.push(("restore_token", Value::from(r)));
            }
            msg(RD, "SelectDevices", &(handle.as_ref(), opts(&o)))
        }, short)?;
        // A monitor stream gives absolute pointer positions; optional.
        let _ = request(&self.conn, SC, "SelectSources", |t| {
            let o = opts(&[("handle_token", Value::from(t)), ("types", Value::from(1u32)), ("multiple", Value::from(true))]);
            msg(SC, "SelectSources", &(handle.as_ref(), o))
        }, short);
        // The person may be asked here (first time only): wait for them.
        let started = request(&self.conn, RD, "Start", |t| {
            msg(RD, "Start", &(handle.as_ref(), "", opts(&[("handle_token", Value::from(t))])))
        }, Duration::from_secs(120))?;
        if let (Some(tok), Some(path)) = (started.get("restore_token").and_then(|v| String::try_from(v.clone()).ok()), Self::token_path()) {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(&path, tok);
        }
        let streams = started.get("streams").map(parse_streams).unwrap_or_default();
        Ok(Session { handle, streams })
    }

    fn keysym(&self, sym: u32, press: bool) -> DResult<()> {
        let g = self.session()?;
        let s = g.as_ref().ok_or_else(|| DesktopError::Failed("no portal session".into()))?;
        super::mark_injection();
        let empty: HashMap<&str, Value> = HashMap::new();
        let r = self.call(RD, "NotifyKeyboardKeysym", &(s.handle.as_ref(), empty, sym as i32, u32::from(press)));
        drop(g);
        if r.is_err() {
            // The session may have been closed by the person; start anew next time.
            *self.session.lock().unwrap_or_else(|e| e.into_inner()) = None;
        }
        r
    }

    /// Keys only into the active window, and only when asked for.
    fn keys(&self, window_id: &str, delivery: Delivery, plan: &[(u32, bool)]) -> DResult<ActionOutcome> {
        if delivery != Delivery::Foreground {
            return Err(DesktopError::Unsupported(
                "on this Wayland desktop keys go to whatever has focus; use type_text into an editable element, set_value, or delivery foreground".into(),
            ));
        }
        let (a, f) = self.frame(window_id)?;
        if !a.is_active(&f.obj) {
            return Err(DesktopError::Unsupported(
                "the window is not the active one, and this desktop lets no outside process raise it".into(),
            ));
        }
        for (sym, press) in plan {
            self.keysym(*sym, *press)?;
        }
        Ok(ActionOutcome::delivered("portal_remote_desktop"))
    }

    fn screenshot(&self) -> DResult<RawFrame> {
        let results = request(&self.conn, SHOT, "Screenshot", |t| {
            let o = opts(&[("handle_token", Value::from(t)), ("interactive", Value::from(false))]);
            msg(SHOT, "Screenshot", &("", o))
        }, Duration::from_secs(60))?;
        let uri: String = results
            .get("uri")
            .and_then(|v| String::try_from(v.clone()).ok())
            .ok_or_else(|| DesktopError::Failed("the Screenshot portal returned no file".into()))?;
        let path = uri_path(&uri).ok_or_else(|| DesktopError::Failed(format!("unexpected screenshot uri {uri}")))?;
        let bytes = std::fs::read(&path).map_err(|e| DesktopError::Failed(format!("{path}: {e}")))?;
        // The portal saves into the person's Pictures; this copy is ours.
        let _ = std::fs::remove_file(&path);
        let (rgba, w, h) = decode_png(&bytes)?;
        let layout = self.session.lock().ok().and_then(|g| {
            g.as_ref().and_then(|s| super::union(&s.streams.iter().map(|(_, r)| *r).collect::<Vec<_>>()))
        });
        let scale = layout.filter(|l| l.width > 0.0).map(|l| f64::from(w) / l.width).unwrap_or(1.0);
        Ok(RawFrame { width: w, height: h, rgba, scale, origin: Point::default() })
    }
}

fn opts<'a>(pairs: &[(&'a str, Value<'a>)]) -> HashMap<&'a str, Value<'a>> {
    pairs.iter().map(|(k, v)| (*k, v.try_clone().unwrap_or(Value::from(0u32)))).collect()
}

fn msg(iface: &str, method: &str, body: &(impl serde::Serialize + zbus::zvariant::DynamicType)) -> Result<zbus::Message, zbus::Error> {
    zbus::Message::method_call(PATH, method)?.destination(DEST)?.interface(iface)?.build(body)
}

fn parse_streams(v: &OwnedValue) -> Vec<(u32, Rect)> {
    let Ok(list) = <Vec<(u32, HashMap<String, OwnedValue>)>>::try_from(v.clone()) else { return Vec::new() };
    list.into_iter()
        .map(|(node, props)| {
            let pair = |k: &str| props.get(k).and_then(|v| <(i32, i32)>::try_from(v.clone()).ok()).unwrap_or((0, 0));
            let (x, y) = pair("position");
            let (w, h) = pair("size");
            (node, Rect { x: f64::from(x), y: f64::from(y), width: f64::from(w), height: f64::from(h) })
        })
        .collect()
}

pub(crate) fn uri_path(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("file://")?;
    let mut out = Vec::new();
    let b = rest.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn decode_png(bytes: &[u8]) -> DResult<(Vec<u8>, u32, u32)> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().map_err(|e| DesktopError::Failed(format!("screenshot png: {e}")))?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).map_err(|e| DesktopError::Failed(format!("screenshot png: {e}")))?;
    let (w, h) = (info.width, info.height);
    let px = (w * h) as usize;
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf[..px * 4].to_vec(),
        png::ColorType::Rgb => buf[..px * 3].chunks_exact(3).flat_map(|c| [c[0], c[1], c[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => buf[..px * 2].chunks_exact(2).flat_map(|c| [c[0], c[0], c[0], 255]).collect(),
        png::ColorType::Grayscale => buf[..px].iter().flat_map(|g| [*g, *g, *g, 255]).collect(),
        png::ColorType::Indexed => return Err(DesktopError::Failed("indexed screenshot png".into())),
    };
    Ok((rgba, w, h))
}

impl Desktop for PortalDesktop {
    fn info(&self) -> PlatformInfo {
        let detail = format!("{}; xdg-desktop-portal RemoteDesktop + Screenshot; windows from AT-SPI", if self.desktop.is_empty() { "wayland" } else { &self.desktop });
        PlatformInfo { os: "linux".into(), display_server: "wayland-portal".into(), detail }
    }

    fn permissions(&self) -> Permissions {
        let saved = Self::token_path().is_some_and(|p| p.exists());
        Permissions {
            accessibility: if self.atspi().is_ok() { Grant::Granted } else { Grant::Unknown },
            screen_capture: Grant::Unknown,
            input: if saved || self.session.lock().map(|g| g.is_some()).unwrap_or(false) { Grant::Granted } else { Grant::Unknown },
        }
    }

    fn request_permission(&self, which: &str) -> DResult<()> {
        match which {
            "input" => self.session().map(|_| ()),
            "screen_capture" => self.screenshot().map(|_| ()),
            other => Err(DesktopError::Unsupported(format!("no prompt for {other} on this desktop"))),
        }
    }

    fn list_apps(&self) -> DResult<Vec<App>> {
        let mut apps: Vec<App> = Vec::new();
        for f in self.frames()? {
            let (id, name) = self.apps.resolve(f.pid, "", "");
            if let Some(a) = apps.iter_mut().find(|a| a.pid == f.pid) {
                a.frontmost |= f.active;
                continue;
            }
            apps.push(App { id, name, pid: f.pid, frontmost: f.active, hidden: f.iconified });
        }
        Ok(apps)
    }

    fn list_windows(&self) -> DResult<Vec<Window>> {
        Ok(self
            .frames()?
            .into_iter()
            .map(|f| Window {
                id: format!("a11y:{}", f.obj.id()),
                app_id: self.apps.resolve(f.pid, "", "").0,
                pid: f.pid,
                title: f.name,
                // Wayland clients report positions relative to themselves.
                frame: f.extents.map(|e| Rect { x: 0.0, y: 0.0, ..e }).unwrap_or_default(),
                on_screen: f.showing && !f.iconified,
                focused: f.active,
                minimized: f.iconified,
            })
            .collect())
    }

    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        match target {
            CaptureTarget::Display(None) => self.screenshot(),
            CaptureTarget::Display(Some(_)) => Err(DesktopError::Unsupported("the Screenshot portal captures the whole desktop only; omit display".into())),
            CaptureTarget::Window(_) => Err(DesktopError::Unsupported(
                "this Wayland desktop does not say where windows are; take a display screenshot and use get_ui_tree".into(),
            )),
        }
    }

    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let (a, f) = self.frame(window_id)?;
        a.tree(window_id, &f.obj, Coords::None, options)
    }

    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        let PointerTarget::Element { window_id, element_id } = target else {
            return Err(DesktopError::Unsupported(
                "this Wayland desktop does not say where windows are; click an element_id from get_ui_tree".into(),
            ));
        };
        if spec.button != Button::Left || spec.count != 1 || !spec.modifiers.is_empty() {
            return Err(DesktopError::Unsupported("only a plain left click (an element action) works here".into()));
        }
        let (a, _) = self.frame(window_id)?;
        let obj = a.element(window_id, element_id)?;
        let name = a.press(&obj)?;
        let mut out = ActionOutcome::delivered("atspi_action");
        out.note = format!("accessibility action {name:?}");
        Ok(out)
    }

    fn type_text(&self, window_id: &str, element_id: Option<&str>, text: &str, delivery: Delivery) -> DResult<ActionOutcome> {
        let (a, f) = self.frame(window_id)?;
        let obj = match element_id {
            Some(id) => Some(a.element(window_id, id)?),
            None => a.typing_target(&f.obj)?,
        };
        if let Some(obj) = obj {
            match a.insert_text(&obj, text) {
                Ok(true) => return Ok(ActionOutcome::confirmed("atspi_insert_text")),
                Ok(false) => return Ok(ActionOutcome::delivered("atspi_insert_text")),
                Err(DesktopError::Unsupported(_)) => {}
                Err(e) => return Err(e),
            }
        }
        let plan: Vec<(u32, bool)> = text.chars().flat_map(|c| [(keysym::of_char(c), true), (keysym::of_char(c), false)]).collect();
        self.keys(window_id, delivery, &plan)
    }

    fn press_keys(&self, window_id: &str, combo: &KeyCombo, delivery: Delivery) -> DResult<ActionOutcome> {
        let mut syms: Vec<u32> = combo.modifiers.iter().filter(|m| **m != Modifier::Fn).filter_map(|m| keysym::of_modifier(*m)).collect();
        syms.push(keysym::of_key(&combo.key));
        let mut plan: Vec<(u32, bool)> = syms.iter().map(|s| (*s, true)).collect();
        plan.extend(syms.iter().rev().map(|s| (*s, false)));
        self.keys(window_id, delivery, &plan)
    }

    fn scroll(&self, _target: &PointerTarget, _dx: f64, _dy: f64) -> DResult<ActionOutcome> {
        Err(DesktopError::Unsupported("scrolling by point needs window positions, which this Wayland desktop does not give; use keys (Page_Down) with delivery foreground".into()))
    }

    fn drag(&self, _w: &str, _from: Point, _to: Point, _b: Button, _d: Delivery) -> DResult<ActionOutcome> {
        Err(DesktopError::Unsupported("dragging needs window positions, which this Wayland desktop does not give".into()))
    }

    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome> {
        let (a, _) = self.frame(window_id)?;
        let obj = a.element(window_id, element_id)?;
        Ok(if a.set_value(&obj, value)? { ActionOutcome::confirmed("atspi_set_value") } else { ActionOutcome::delivered("atspi_set_value") })
    }

    fn perform_action(&self, window_id: &str, element_id: &str, action: &str) -> DResult<ActionOutcome> {
        let (a, _) = self.frame(window_id)?;
        let obj = a.element(window_id, element_id)?;
        a.perform(&obj, action)?;
        Ok(ActionOutcome::delivered("atspi_action"))
    }

    fn launch_app(&self, app_id: &str) -> DResult<App> {
        super::launch(&self.apps, app_id)
    }
}
