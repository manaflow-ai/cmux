//! AT-SPI2 over D-Bus: accessibility trees and semantic actions on X11 and
//! Wayland alike. This is the background route of every Linux backend: an
//! action, a text insert or a value set reaches one element of one app,
//! without the pointer, the keyboard focus or the window stack.
//!
//! Element ids are `"<bus name>|<object path>"`. Ids are scoped to the window
//! whose tree issued them: an id the latest `ui_tree` of that window did not
//! return is refused as stale, so an agent cannot act on another window's
//! element by reusing an id.

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::Duration;

use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::desktop::{DResult, DesktopError, Element, Point, Rect, TreeOptions, UiTree};

const ACC: &str = "org.a11y.atspi.Accessible";
const COMPONENT: &str = "org.a11y.atspi.Component";
const ACTION: &str = "org.a11y.atspi.Action";
const TEXT: &str = "org.a11y.atspi.Text";
const EDITABLE: &str = "org.a11y.atspi.EditableText";
const VALUE: &str = "org.a11y.atspi.Value";
const PROPS: &str = "org.freedesktop.DBus.Properties";

// AtspiStateType bits.
const ST_ACTIVE: u32 = 1;
const ST_EDITABLE: u32 = 7;
const ST_ENABLED: u32 = 8;
const ST_FOCUSABLE: u32 = 11;
const ST_FOCUSED: u32 = 12;
const ST_ICONIFIED: u32 = 15;
const ST_SENSITIVE: u32 = 24;
const ST_SHOWING: u32 = 25;

/// A remote accessible object.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Obj {
    pub bus: String,
    pub path: String,
}

impl Obj {
    pub fn id(&self) -> String {
        format!("{}|{}", self.bus, self.path)
    }
    pub fn parse(id: &str) -> Option<Self> {
        let (bus, path) = id.split_once('|')?;
        if bus.is_empty() || !path.starts_with('/') {
            return None;
        }
        Some(Self { bus: bus.into(), path: path.into() })
    }
    fn from_pair((bus, path): (String, OwnedObjectPath)) -> Self {
        Self { bus, path: path.as_str().to_string() }
    }
    fn is_null(&self) -> bool {
        self.path == "/org/a11y/atspi/null" || self.bus.is_empty()
    }
}

/// How element extents become global desktop points.
#[derive(Clone, Copy, Debug)]
pub enum Coords {
    /// The toolkit knows screen positions (X11).
    Screen,
    /// Window-relative positions offset by the window's origin (Wayland,
    /// where clients do not know where they are).
    Window(Point),
    /// No usable positions.
    None,
}

/// A top-level frame an app exposes.
#[derive(Clone, Debug)]
pub struct Frame {
    pub obj: Obj,
    pub pid: u32,
    pub name: String,
    pub role: String,
    pub extents: Option<Rect>,
    pub active: bool,
    pub iconified: bool,
    pub showing: bool,
}

pub struct Atspi {
    conn: Connection,
    pids: Mutex<HashMap<String, u32>>,
    /// window id -> element ids its latest tree issued.
    issued: Mutex<HashMap<String, HashSet<String>>>,
}

fn dbus_err(e: zbus::Error) -> DesktopError {
    if let zbus::Error::MethodError(name, msg, _) = &e {
        let n = name.as_str();
        if n.ends_with("UnknownObject") || n.ends_with("ServiceUnknown") || n.ends_with("NoReply") || n.ends_with("UnknownMethod") {
            return DesktopError::StaleElement(msg.clone().unwrap_or_else(|| n.to_string()));
        }
    }
    DesktopError::Failed(format!("accessibility (AT-SPI): {e}"))
}

impl Atspi {
    /// Connects to the accessibility bus and asks toolkits to expose their
    /// trees (`org.a11y.Status.IsEnabled`, what screen readers set; Qt,
    /// Chromium and Firefox only build trees when it is on).
    pub fn connect() -> Result<Self, String> {
        let session = Connection::session().map_err(|e| format!("D-Bus session bus: {e}"))?;
        let _ = session.call_method(
            Some("org.a11y.Bus"),
            "/org/a11y/bus",
            Some(PROPS),
            "Set",
            &("org.a11y.Status", "IsEnabled", Value::from(true)),
        );
        let reply = session
            .call_method(Some("org.a11y.Bus"), "/org/a11y/bus", Some("org.a11y.Bus"), "GetAddress", &())
            .map_err(|e| format!("no accessibility bus (install at-spi2-core): {e}"))?;
        let address: String = reply.body().deserialize().map_err(|e| e.to_string())?;
        let conn = zbus::blocking::connection::Builder::address(address.as_str())
            .map_err(|e| e.to_string())?
            .method_timeout(Duration::from_secs(3))
            .build()
            .map_err(|e| format!("accessibility bus {address}: {e}"))?;
        Ok(Self { conn, pids: Mutex::new(HashMap::new()), issued: Mutex::new(HashMap::new()) })
    }

    fn call<B, R>(&self, obj: &Obj, iface: &str, method: &str, body: &B) -> DResult<R>
    where
        B: serde::Serialize + zbus::zvariant::DynamicType,
        R: for<'d> serde::Deserialize<'d> + zbus::zvariant::Type,
    {
        let msg = self
            .conn
            .call_method(Some(obj.bus.as_str()), obj.path.as_str(), Some(iface), method, body)
            .map_err(dbus_err)?;
        msg.body().deserialize::<R>().map_err(|e| DesktopError::Failed(format!("AT-SPI {method}: {e}")))
    }

    fn prop(&self, obj: &Obj, iface: &str, name: &str) -> DResult<OwnedValue> {
        self.call(obj, PROPS, "Get", &(iface, name))
    }

    fn prop_string(&self, obj: &Obj, iface: &str, name: &str) -> String {
        self.prop(obj, iface, name).ok().and_then(|v| String::try_from(v).ok()).unwrap_or_default()
    }

    fn prop_i32(&self, obj: &Obj, iface: &str, name: &str) -> Option<i32> {
        self.prop(obj, iface, name).ok().and_then(|v| i32::try_from(v).ok())
    }

    fn prop_f64(&self, obj: &Obj, iface: &str, name: &str) -> Option<f64> {
        self.prop(obj, iface, name).ok().and_then(|v| f64::try_from(v).ok())
    }

    fn children(&self, obj: &Obj) -> DResult<Vec<Obj>> {
        let kids: Vec<(String, OwnedObjectPath)> = self.call(obj, ACC, "GetChildren", &())?;
        Ok(kids.into_iter().map(Obj::from_pair).filter(|o| !o.is_null()).collect())
    }

    fn states(&self, obj: &Obj) -> u64 {
        let words: Vec<u32> = self.call(obj, ACC, "GetState", &()).unwrap_or_default();
        let lo = u64::from(words.first().copied().unwrap_or(0));
        let hi = u64::from(words.get(1).copied().unwrap_or(0));
        lo | (hi << 32)
    }

    fn interfaces(&self, obj: &Obj) -> Vec<String> {
        self.call(obj, ACC, "GetInterfaces", &()).unwrap_or_default()
    }

    fn role(&self, obj: &Obj) -> String {
        let r: String = self.call(obj, ACC, "GetRoleName", &()).unwrap_or_default();
        r.replace(' ', "_")
    }

    pub fn extents(&self, obj: &Obj, coords: Coords) -> Option<Rect> {
        let (kind, off) = match coords {
            Coords::Screen => (0u32, Point::default()),
            Coords::Window(o) => (1u32, o),
            Coords::None => return None,
        };
        let (x, y, w, h): (i32, i32, i32, i32) = self.call(obj, COMPONENT, "GetExtents", &(kind,)).ok()?;
        if w <= 0 || h <= 0 || (x == i32::MIN) {
            return None;
        }
        Some(Rect { x: f64::from(x) + off.x, y: f64::from(y) + off.y, width: f64::from(w), height: f64::from(h) })
    }

    fn pid_of(&self, bus: &str) -> u32 {
        if let Some(p) = self.pids.lock().unwrap_or_else(|e| e.into_inner()).get(bus) {
            return *p;
        }
        let pid: u32 = self
            .conn
            .call_method(
                Some("org.freedesktop.DBus"),
                "/org/freedesktop/DBus",
                Some("org.freedesktop.DBus"),
                "GetConnectionUnixProcessID",
                &(bus,),
            )
            .ok()
            .and_then(|m| m.body().deserialize().ok())
            .unwrap_or(0);
        self.pids.lock().unwrap_or_else(|e| e.into_inner()).insert(bus.to_string(), pid);
        pid
    }

    /// Every app's top-level frames (windows, dialogs).
    pub fn frames(&self, coords_of: impl Fn(u32) -> Coords) -> DResult<Vec<Frame>> {
        let root = Obj { bus: "org.a11y.atspi.Registry".into(), path: "/org/a11y/atspi/accessible/root".into() };
        let mut out = Vec::new();
        for app in self.children(&root)? {
            let pid = self.pid_of(&app.bus);
            let Ok(kids) = self.children(&app) else { continue };
            for obj in kids {
                let role = self.role(&obj);
                if !matches!(role.as_str(), "frame" | "window" | "dialog" | "alert" | "file_chooser") {
                    continue;
                }
                let st = self.states(&obj);
                out.push(Frame {
                    name: self.prop_string(&obj, ACC, "Name"),
                    extents: self.extents(&obj, coords_of(pid)),
                    active: bit(st, ST_ACTIVE),
                    iconified: bit(st, ST_ICONIFIED),
                    showing: bit(st, ST_SHOWING),
                    role,
                    pid,
                    obj,
                });
            }
        }
        Ok(out)
    }

    /// The frame of an app's window: same pid, then same title, then same
    /// extents, then the only frame. Anything else is refused.
    pub fn frame_for(&self, pid: u32, title: &str, frame: Option<Rect>, coords: Coords) -> DResult<Frame> {
        let all = self.frames(|_| coords)?;
        let mine: Vec<Frame> = all.into_iter().filter(|f| pid != 0 && f.pid == pid).collect();
        pick_frame(mine, title, frame).ok_or_else(|| {
            DesktopError::Unsupported(format!(
                "no accessibility tree for this window (pid {pid}, {title:?}); the app may not support AT-SPI (Qt needs QT_ACCESSIBILITY=1 on old versions, GTK needs at-spi2-core)"
            ))
        })
    }

    /// The window's tree, remembering which ids it issued.
    pub fn tree(&self, window_id: &str, frame: &Obj, coords: Coords, options: TreeOptions) -> DResult<UiTree> {
        let mut walk = Walk { issued: HashSet::new(), count: 0, truncated: false, options, coords };
        let root = self.node(frame, 0, &mut walk)?;
        self.issued.lock().unwrap_or_else(|e| e.into_inner()).insert(window_id.to_string(), walk.issued);
        Ok(UiTree { window_id: window_id.to_string(), root, truncated: walk.truncated })
    }

    fn node(&self, obj: &Obj, depth: usize, walk: &mut Walk) -> DResult<Element> {
        walk.count += 1;
        walk.issued.insert(obj.id());
        let ifaces = self.interfaces(obj);
        let has = |i: &str| ifaces.iter().any(|x| x == i);
        let st = self.states(obj);
        let role = self.role(obj);
        let mut actions: Vec<String> = Vec::new();
        if has(ACTION) {
            let list: Vec<(String, String, String)> = self.call(obj, ACTION, "GetActions", &()).unwrap_or_default();
            actions.extend(list.into_iter().map(|(n, _, _)| n.to_ascii_lowercase()).filter(|n| !n.is_empty()));
        }
        if has(EDITABLE) || has(VALUE) {
            actions.push("set_value".into());
        }
        if bit(st, ST_FOCUSABLE) {
            actions.push("focus".into());
        }
        let value = self.value_text(obj, &role, has(TEXT), has(VALUE));
        let mut el = Element {
            id: obj.id(),
            role,
            name: self.prop_string(obj, ACC, "Name"),
            value,
            frame: if has(COMPONENT) { self.extents(obj, walk.coords) } else { None },
            actions,
            focused: bit(st, ST_FOCUSED),
            disabled: !bit(st, ST_ENABLED) && !bit(st, ST_SENSITIVE),
            children: Vec::new(),
        };
        if depth + 1 >= walk.options.max_depth {
            walk.truncated |= self.prop_i32(obj, ACC, "ChildCount").unwrap_or(0) > 0;
            return Ok(el);
        }
        for kid in self.children(obj).unwrap_or_default() {
            if walk.count >= walk.options.max_nodes {
                walk.truncated = true;
                break;
            }
            // Closed menus and hidden pages are not on screen; skip them.
            if !bit(self.states(&kid), ST_SHOWING) {
                continue;
            }
            if let Ok(child) = self.node(&kid, depth + 1, walk) {
                el.children.push(child);
            }
        }
        Ok(el)
    }

    fn value_text(&self, obj: &Obj, role: &str, text: bool, value: bool) -> String {
        if value && let Some(v) = self.prop_f64(obj, VALUE, "CurrentValue") {
            return format!("{v}");
        }
        if text && !matches!(role, "label" | "push_button" | "menu_item" | "page_tab") {
            let n = self.prop_i32(obj, TEXT, "CharacterCount").unwrap_or(0).clamp(0, 2000);
            if n > 0 {
                return self.call::<_, String>(obj, TEXT, "GetText", &(0i32, n)).unwrap_or_default();
            }
        }
        String::new()
    }

    /// The element `id`, refused unless the window's latest tree issued it.
    pub fn element(&self, window_id: &str, id: &str) -> DResult<Obj> {
        let issued = self.issued.lock().unwrap_or_else(|e| e.into_inner());
        let known = issued.get(window_id).is_some_and(|s| s.contains(id));
        drop(issued);
        if !known {
            return Err(DesktopError::StaleElement(id.to_string()));
        }
        Obj::parse(id).ok_or_else(|| DesktopError::StaleElement(id.to_string()))
    }

    pub fn center(&self, obj: &Obj, coords: Coords) -> Option<Point> {
        self.extents(obj, coords).map(|r| Point { x: r.x + r.width / 2.0, y: r.y + r.height / 2.0 })
    }

    /// Presses the element through its own action (click, press, activate).
    pub fn press(&self, obj: &Obj) -> DResult<String> {
        let list: Vec<(String, String, String)> = self.call(obj, ACTION, "GetActions", &()).map_err(|_| {
            DesktopError::Unsupported("this element has no accessibility action; click it by point".into())
        })?;
        let names: Vec<String> = list.iter().map(|(n, _, _)| n.to_ascii_lowercase()).collect();
        let index = ["click", "press", "activate", "jump", "toggle", "open", "select"]
            .iter()
            .find_map(|want| names.iter().position(|n| n == want))
            .or(if names.is_empty() { None } else { Some(0) })
            .ok_or_else(|| DesktopError::Unsupported("this element has no accessibility action".into()))?;
        self.do_action(obj, index)?;
        Ok(names[index].clone())
    }

    fn do_action(&self, obj: &Obj, index: usize) -> DResult<()> {
        let ok: bool = self.call(obj, ACTION, "DoAction", &(index as i32,))?;
        if ok { Ok(()) } else { Err(DesktopError::Failed("the app refused the accessibility action".into())) }
    }

    /// Runs a named action (`focus` grabs keyboard focus inside the app).
    pub fn perform(&self, obj: &Obj, action: &str) -> DResult<()> {
        let want = action.to_ascii_lowercase();
        if want == "focus" {
            let ok: bool = self.call(obj, COMPONENT, "GrabFocus", &())?;
            return if ok { Ok(()) } else { Err(DesktopError::Failed("the app refused focus".into())) };
        }
        let list: Vec<(String, String, String)> = self.call(obj, ACTION, "GetActions", &()).unwrap_or_default();
        let index = list
            .iter()
            .position(|(n, _, _)| n.eq_ignore_ascii_case(&want))
            .ok_or_else(|| {
                let names: Vec<&str> = list.iter().map(|(n, _, _)| n.as_str()).collect();
                DesktopError::Unsupported(format!("no action {action:?}; this element has {names:?}"))
            })?;
        self.do_action(obj, index)
    }

    /// Sets text (EditableText) or a number (Value); reads it back.
    pub fn set_value(&self, obj: &Obj, value: &str) -> DResult<bool> {
        let ifaces = self.interfaces(obj);
        if ifaces.iter().any(|i| i == EDITABLE) {
            let ok: bool = self.call(obj, EDITABLE, "SetTextContents", &(value,))?;
            if !ok {
                return Err(DesktopError::Failed("the app refused the text".into()));
            }
            return Ok(self.text(obj).is_some_and(|t| t == value));
        }
        if ifaces.iter().any(|i| i == VALUE) {
            let n: f64 = value
                .trim()
                .parse()
                .map_err(|_| DesktopError::Unsupported(format!("this element takes a number, not {value:?}")))?;
            let _: () = self.call(obj, PROPS, "Set", &(VALUE, "CurrentValue", Value::from(n)))?;
            return Ok(self.prop_f64(obj, VALUE, "CurrentValue").is_some_and(|v| (v - n).abs() < 1e-9));
        }
        Err(DesktopError::Unsupported("this element takes no value (no EditableText or Value)".into()))
    }

    pub fn text(&self, obj: &Obj) -> Option<String> {
        let n = self.prop_i32(obj, TEXT, "CharacterCount")?;
        self.call(obj, TEXT, "GetText", &(0i32, n)).ok()
    }

    /// Inserts `text` at the caret of an editable element; true when the
    /// element's text shows it afterwards.
    pub fn insert_text(&self, obj: &Obj, text: &str) -> DResult<bool> {
        if !self.interfaces(obj).iter().any(|i| i == EDITABLE) {
            return Err(DesktopError::Unsupported("the element is not editable text".into()));
        }
        let caret = self.prop_i32(obj, TEXT, "CaretOffset").unwrap_or(-1);
        let pos = if caret < 0 { self.prop_i32(obj, TEXT, "CharacterCount").unwrap_or(0) } else { caret };
        let len = text.chars().count() as i32;
        let ok: bool = self.call(obj, EDITABLE, "InsertText", &(pos, text, len))?;
        if !ok {
            return Err(DesktopError::Failed("the app refused the text".into()));
        }
        Ok(self.text(obj).is_some_and(|t| t.contains(text)))
    }

    /// The element typing goes to in a window: the focused one, else the
    /// only editable one. Several editable elements and none focused is
    /// refused (pass element_id).
    pub fn typing_target(&self, frame: &Obj) -> DResult<Option<Obj>> {
        let mut focused = None;
        let mut editable = Vec::new();
        self.scan(frame, 0, &mut 0, &mut |obj, st| {
            if bit(st, ST_FOCUSED) && focused.is_none() {
                focused = Some(obj.clone());
            }
            if bit(st, ST_EDITABLE) && bit(st, ST_SHOWING) {
                editable.push(obj.clone());
            }
        });
        if let Some(f) = focused {
            return Ok(Some(f));
        }
        match editable.len() {
            0 => Ok(None),
            1 => Ok(editable.pop()),
            n => Err(DesktopError::Unsupported(format!(
                "no element has keyboard focus and {n} are editable; pass element_id from get_ui_tree"
            ))),
        }
    }

    fn scan(&self, obj: &Obj, depth: usize, count: &mut usize, f: &mut dyn FnMut(&Obj, u64)) {
        *count += 1;
        if *count > 3000 || depth > 40 {
            return;
        }
        let st = self.states(obj);
        f(obj, st);
        for kid in self.children(obj).unwrap_or_default() {
            if bit(self.states(&kid), ST_SHOWING) {
                self.scan(&kid, depth + 1, count, f);
            }
        }
    }

    /// The deepest element at a global point.
    pub fn at_point(&self, frame: &Obj, p: Point, coords: Coords) -> Option<Obj> {
        let (x, y, kind) = match coords {
            Coords::Screen => (p.x, p.y, 0u32),
            Coords::Window(o) => (p.x - o.x, p.y - o.y, 1u32),
            Coords::None => return None,
        };
        let mut cur = frame.clone();
        for _ in 0..64 {
            let next: (String, OwnedObjectPath) =
                self.call(&cur, COMPONENT, "GetAccessibleAtPoint", &(x as i32, y as i32, kind)).ok()?;
            let next = Obj::from_pair(next);
            if next.is_null() || next == cur {
                break;
            }
            cur = next;
        }
        if &cur == frame { None } else { Some(cur) }
    }

    /// True when the element (or an ancestor up to the frame) has an action.
    pub fn actionable_ancestor(&self, obj: &Obj, frame: &Obj) -> Option<Obj> {
        let mut cur = obj.clone();
        for _ in 0..8 {
            if self.interfaces(&cur).iter().any(|i| i == ACTION) {
                let n = self.prop_i32(&cur, ACTION, "NActions").unwrap_or(0);
                if n > 0 {
                    return Some(cur);
                }
            }
            if &cur == frame {
                return None;
            }
            let parent: OwnedValue = self.prop(&cur, ACC, "Parent").ok()?;
            let (bus, path): (String, OwnedObjectPath) = parent.try_into().ok()?;
            cur = Obj { bus, path: path.as_str().to_string() };
            if cur.is_null() {
                return None;
            }
        }
        None
    }

    /// Whether the window's frame is the active one (has keyboard focus).
    pub fn is_active(&self, frame: &Obj) -> bool {
        bit(self.states(frame), ST_ACTIVE)
    }
}

struct Walk {
    issued: HashSet<String>,
    count: usize,
    truncated: bool,
    options: TreeOptions,
    coords: Coords,
}

fn bit(states: u64, n: u32) -> bool {
    states & (1u64 << n) != 0
}

/// Picks one frame for a window from the app's frames.
pub fn pick_frame(mut mine: Vec<Frame>, title: &str, frame: Option<Rect>) -> Option<Frame> {
    if mine.len() <= 1 {
        return mine.pop();
    }
    let by_title: Vec<&Frame> = mine.iter().filter(|f| !title.is_empty() && f.name == title).collect();
    if by_title.len() == 1 {
        return Some(by_title[0].clone());
    }
    let near = |a: &Rect, b: &Rect| {
        (a.x - b.x).abs() <= 2.0 && (a.y - b.y).abs() <= 2.0 && (a.width - b.width).abs() <= 2.0 && (a.height - b.height).abs() <= 2.0
    };
    if let Some(want) = frame {
        let by_rect: Vec<&Frame> = mine.iter().filter(|f| f.extents.is_some_and(|e| near(&e, &want))).collect();
        if by_rect.len() == 1 {
            return Some(by_rect[0].clone());
        }
    }
    let showing: Vec<&Frame> = mine.iter().filter(|f| f.showing && !f.iconified).collect();
    if showing.len() == 1 {
        return Some(showing[0].clone());
    }
    None
}
