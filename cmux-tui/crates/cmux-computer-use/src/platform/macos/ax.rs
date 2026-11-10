//! The Accessibility API: elements, the window lookup by CGWindowID, the
//! bounded tree walk and the per-window element cache that maps element ids
//! back to `AXUIElementRef`s.

use std::collections::{HashMap, VecDeque};
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use super::roles;
use super::sys::*;
use crate::desktop::{DResult, DesktopError, Element, Rect, TreeOptions, UiTree};

/// How long one AX message to an app may take before it fails with
/// `cannot complete` (a hung app must not hang the worker).
const MESSAGE_TIMEOUT_SECONDS: f32 = 1.5;
/// The longest value text kept per element.
const MAX_VALUE_CHARS: usize = 2000;
/// Windows whose element cache is kept.
const MAX_CACHED_WINDOWS: usize = 32;

/// One accessibility element (retained).
#[derive(Clone)]
pub struct Ax(Cf);

pub fn ax_error(e: AXError, what: &str) -> DesktopError {
    match e {
        AX_INVALID_ELEMENT => DesktopError::StaleElement(what.to_string()),
        AX_API_DISABLED => DesktopError::PermissionMissing("accessibility".into()),
        AX_CANNOT_COMPLETE => {
            DesktopError::Failed(format!("{what}: the app did not answer (busy or hung)"))
        }
        AX_ATTRIBUTE_UNSUPPORTED | AX_ACTION_UNSUPPORTED => {
            DesktopError::Unsupported(format!("{what} is not supported by this element"))
        }
        other => DesktopError::Failed(format!("{what}: accessibility error {other}")),
    }
}

type GetWindowFn = unsafe extern "C" fn(CFTypeRef, *mut u32) -> AXError;

/// `_AXUIElementGetWindow`, the private call every macOS automation tool
/// uses to pair an AX window with its CGWindowID.
fn get_window_fn() -> Option<GetWindowFn> {
    static F: OnceLock<Option<GetWindowFn>> = OnceLock::new();
    *F.get_or_init(|| {
        let p = symbol(c"_AXUIElementGetWindow")?;
        // SAFETY: the symbol has this signature on every macOS since 10.6.
        Some(unsafe { std::mem::transmute::<*mut c_void, GetWindowFn>(p) })
    })
}

/// Sets the process-wide AX messaging timeout once.
pub fn init() {
    static DONE: OnceLock<()> = OnceLock::new();
    DONE.get_or_init(|| {
        // SAFETY: the system-wide element is a plain CF object we release.
        unsafe {
            if let Some(sys) = Cf::created(AXUIElementCreateSystemWide()) {
                AXUIElementSetMessagingTimeout(sys.ptr(), MESSAGE_TIMEOUT_SECONDS);
            }
        }
    });
}

pub fn trusted() -> bool {
    // SAFETY: no arguments.
    unsafe { AXIsProcessTrusted() != 0 }
}

impl Ax {
    pub fn application(pid: i32) -> Option<Ax> {
        init();
        // SAFETY: returns a +1 element (or null).
        let app = Cf::created(unsafe { AXUIElementCreateApplication(pid) })?;
        Some(Ax(app))
    }

    fn from_cf(cf: Cf) -> Option<Ax> {
        // SAFETY: plain type id read.
        (cf.type_id() == unsafe { AXUIElementGetTypeID() }).then_some(Ax(cf))
    }

    pub fn ptr(&self) -> CFTypeRef {
        self.0.ptr()
    }

    /// An attribute's value. `Ok(None)` when the element has no value or
    /// does not support the attribute.
    pub fn attr(&self, name: &str) -> Result<Option<Cf>, AXError> {
        let Some(key) = Cf::string(name) else { return Ok(None) };
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: self and key are live; out receives a +1 reference.
        let err = unsafe { AXUIElementCopyAttributeValue(self.ptr(), key.ptr(), &mut out) };
        match err {
            AX_OK => Ok(Cf::created(out)),
            AX_NO_VALUE | AX_ATTRIBUTE_UNSUPPORTED => Ok(None),
            e => Err(e),
        }
    }

    pub fn string(&self, name: &str) -> Option<String> {
        self.attr(name).ok().flatten().and_then(|v| v.as_string())
    }

    pub fn bool(&self, name: &str) -> Option<bool> {
        self.attr(name).ok().flatten().and_then(|v| v.as_bool())
    }

    pub fn element(&self, name: &str) -> Option<Ax> {
        self.attr(name).ok().flatten().and_then(Ax::from_cf)
    }

    pub fn elements(&self, name: &str) -> Vec<Ax> {
        match self.attr(name) {
            Ok(Some(v)) => v.items().into_iter().filter_map(Ax::from_cf).collect(),
            _ => Vec::new(),
        }
    }

    /// AXPosition + AXSize, in global top-left points.
    pub fn frame(&self) -> Option<Rect> {
        let pos = self.attr("AXPosition").ok().flatten()?;
        let size = self.attr("AXSize").ok().flatten()?;
        frame_of(&pos, &size)
    }

    pub fn actions(&self) -> Vec<String> {
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: out receives a +1 CFArray.
        let err = unsafe { AXUIElementCopyActionNames(self.ptr(), &mut out) };
        if err != AX_OK {
            return Vec::new();
        }
        Cf::created(out)
            .map(|a| a.items().iter().filter_map(Cf::as_string).collect())
            .unwrap_or_default()
    }

    pub fn perform(&self, action: &str) -> Result<(), AXError> {
        let Some(name) = Cf::string(action) else { return Err(AX_ACTION_UNSUPPORTED) };
        // SAFETY: both live.
        match unsafe { AXUIElementPerformAction(self.ptr(), name.ptr()) } {
            AX_OK => Ok(()),
            e => Err(e),
        }
    }

    pub fn set(&self, name: &str, value: &Cf) -> Result<(), AXError> {
        let Some(key) = Cf::string(name) else { return Err(AX_ATTRIBUTE_UNSUPPORTED) };
        // SAFETY: all live.
        match unsafe { AXUIElementSetAttributeValue(self.ptr(), key.ptr(), value.ptr()) } {
            AX_OK => Ok(()),
            e => Err(e),
        }
    }

    pub fn settable(&self, name: &str) -> bool {
        let Some(key) = Cf::string(name) else { return false };
        let mut out = 0u8;
        // SAFETY: all live; out is a Boolean.
        let err = unsafe { AXUIElementIsAttributeSettable(self.ptr(), key.ptr(), &mut out) };
        err == AX_OK && out != 0
    }

    /// The CGWindowID of a window element.
    pub fn window_id(&self) -> Option<u32> {
        let f = get_window_fn()?;
        let mut id = 0u32;
        // SAFETY: f is _AXUIElementGetWindow; self is live.
        (unsafe { f(self.ptr(), &mut id) } == AX_OK && id != 0).then_some(id)
    }

    /// Whether the element still exists (its role can be read).
    pub fn alive(&self) -> Result<(), AXError> {
        self.attr("AXRole").map(|_| ())
    }

    /// The element's value as text (strings, numbers, booleans).
    pub fn value_text(&self) -> Option<String> {
        self.attr("AXValue").ok().flatten().and_then(|v| value_text(&v))
    }

    /// The process that owns the element.
    pub fn pid(&self) -> Option<i32> {
        let mut pid = 0i32;
        // SAFETY: self is live; pid is an out parameter.
        (unsafe { AXUIElementGetPid(self.ptr(), &mut pid) } == AX_OK && pid > 0).then_some(pid)
    }

    /// The app's frontmost element at a global point (`self` is an app element).
    pub fn element_at(&self, x: f64, y: f64) -> Option<Ax> {
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: self is live; out receives a +1 element.
        let err =
            unsafe { AXUIElementCopyElementAtPosition(self.ptr(), x as f32, y as f32, &mut out) };
        if err != AX_OK {
            return None;
        }
        Cf::created(out).and_then(Ax::from_cf)
    }

    /// The system-wide element (where the keyboard focus is).
    pub fn system_wide() -> Option<Ax> {
        init();
        // SAFETY: returns a +1 element (or null).
        Cf::created(unsafe { AXUIElementCreateSystemWide() }).map(Ax)
    }

    pub fn same(&self, other: &Ax) -> bool {
        unsafe extern "C" {
            fn CFEqual(a: CFTypeRef, b: CFTypeRef) -> u8;
        }
        // SAFETY: both live.
        unsafe { CFEqual(self.ptr(), other.ptr()) != 0 }
    }
}

fn frame_of(pos: &Cf, size: &Cf) -> Option<Rect> {
    let mut p = CGPoint::default();
    let mut s = CGSize::default();
    // SAFETY: each value is checked to be an AXValue of the expected type
    // before it is read into a struct of that type.
    unsafe {
        if pos.type_id() != AXValueGetTypeID() || size.type_id() != AXValueGetTypeID() {
            return None;
        }
        if AXValueGetType(pos.ptr()) != AX_VALUE_CGPOINT
            || AXValueGetType(size.ptr()) != AX_VALUE_CGSIZE
        {
            return None;
        }
        if AXValueGetValue(pos.ptr(), AX_VALUE_CGPOINT, (&raw mut p).cast()) == 0
            || AXValueGetValue(size.ptr(), AX_VALUE_CGSIZE, (&raw mut s).cast()) == 0
        {
            return None;
        }
    }
    Some(Rect { x: p.x, y: p.y, width: s.width, height: s.height })
}

fn value_text(v: &Cf) -> Option<String> {
    if let Some(s) = v.as_string() {
        return Some(s);
    }
    if v.is_number() {
        let n = v.as_f64()?;
        return Some(if n.fract() == 0.0 && n.abs() < 1e15 {
            format!("{}", n as i64)
        } else {
            format!("{n}")
        });
    }
    None
}

/// Whether a value from CopyMultipleAttributeValues is an error placeholder.
fn is_error_value(v: &Cf) -> bool {
    // SAFETY: type checked before reading the AXValue type.
    unsafe { v.type_id() == AXValueGetTypeID() && AXValueGetType(v.ptr()) == AX_VALUE_ERROR }
}

/// Finds the AX window of `pid` whose CGWindowID is `id`. When the private
/// lookup is missing, a window whose frame (and title, when known) matches.
pub fn find_window(pid: i32, id: u32, frame: &Rect, title: &str) -> DResult<(Ax, Ax)> {
    let app = Ax::application(pid)
        .ok_or_else(|| DesktopError::Failed(format!("no accessibility element for pid {pid}")))?;
    if !trusted() {
        return Err(DesktopError::PermissionMissing("accessibility".into()));
    }
    let windows = app.elements("AXWindows");
    if get_window_fn().is_some() {
        if let Some(w) = windows.iter().find(|w| w.window_id() == Some(id)) {
            return Ok((app, w.clone()));
        }
    } else if let Some(w) = windows.iter().find(|w| {
        let same_frame = w.frame().is_some_and(|f| {
            (f.x - frame.x).abs() < 1.0
                && (f.y - frame.y).abs() < 1.0
                && (f.width - frame.width).abs() < 1.0
                && (f.height - frame.height).abs() < 1.0
        });
        same_frame && (title.is_empty() || w.string("AXTitle").as_deref() == Some(title))
    }) {
        return Ok((app, w.clone()));
    }
    Err(DesktopError::TargetNotFound(format!(
        "window {id} has no accessibility element (it may be on another Space or not a standard window)"
    )))
}

/// Per-window AX state: CGWindowID -> (title, minimized), one AX pass for
/// one app. Empty without the Accessibility grant.
pub fn window_states(pid: i32) -> HashMap<u32, (String, bool)> {
    let mut out = HashMap::new();
    if !trusted() || get_window_fn().is_none() {
        return out;
    }
    let Some(app) = Ax::application(pid) else { return out };
    for w in app.elements("AXWindows") {
        if let Some(id) = w.window_id() {
            let title = w.string("AXTitle").unwrap_or_default();
            let minimized = w.bool("AXMinimized").unwrap_or(false);
            out.insert(id, (title, minimized));
        }
    }
    out
}

const NODE_ATTRS: [&str; 12] = [
    "AXRole",
    "AXSubrole",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXPosition",
    "AXSize",
    "AXFocused",
    "AXEnabled",
    "AXChildren",
    "AXPlaceholderValue",
    "AXHelp",
];

struct Walk {
    attrs: Cf,
    options: TreeOptions,
    generation: u64,
    elements: Vec<Ax>,
    truncated: bool,
}

impl Walk {
    fn read(&self, ax: &Ax) -> Result<Vec<Option<Cf>>, AXError> {
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: ax and the attribute array are live; out receives a +1 CFArray.
        let err = unsafe {
            AXUIElementCopyMultipleAttributeValues(ax.ptr(), self.attrs.ptr(), 0, &mut out)
        };
        if err != AX_OK {
            return Err(err);
        }
        let values = Cf::created(out).map(|a| a.items()).unwrap_or_default();
        let mut slots: Vec<Option<Cf>> =
            values.into_iter().map(|v| (!is_error_value(&v)).then_some(v)).collect();
        slots.resize_with(NODE_ATTRS.len(), || None);
        Ok(slots)
    }

    /// One element's own fields (no children) and its AXChildren value.
    fn describe(&self, ax: &Ax, index: usize) -> Result<(Element, Option<Cf>), AXError> {
        let mut v = self.read(ax)?;
        let text = |slot: &Option<Cf>| slot.as_ref().and_then(Cf::as_string).unwrap_or_default();
        let role = text(&v[0]);
        let subrole = v[1].as_ref().and_then(Cf::as_string);
        let secure = roles::is_secure(&role, subrole.as_deref());
        let name = [&v[2], &v[3], &v[10], &v[11]]
            .into_iter()
            .map(text)
            .find(|s| !s.trim().is_empty())
            .unwrap_or_default();
        let value = if secure {
            String::new()
        } else {
            let mut s = v[4].as_ref().and_then(value_text).unwrap_or_default();
            if s.chars().count() > MAX_VALUE_CHARS {
                s = s.chars().take(MAX_VALUE_CHARS).collect();
                s.push('\u{2026}');
            }
            s
        };
        let frame = match (&v[5], &v[6]) {
            (Some(p), Some(s)) => frame_of(p, s),
            _ => None,
        };
        let actions = ax
            .actions()
            .iter()
            .filter(|a| !roles::is_foreground_action(a))
            .map(|a| roles::action_name(a))
            .collect();
        let element = Element {
            id: roles::element_id(self.generation, index),
            role: roles::role_name(&role, subrole.as_deref()),
            name,
            value,
            frame,
            actions,
            focused: v[7].as_ref().and_then(Cf::as_bool).unwrap_or(false),
            disabled: v[8].as_ref().and_then(Cf::as_bool).is_some_and(|enabled| !enabled),
            children: Vec::new(),
        };
        Ok((element, v[9].take()))
    }

    fn node(&mut self, ax: Ax, depth: usize) -> Result<Element, AXError> {
        let index = self.elements.len();
        self.elements.push(ax.clone());
        let (mut element, children) = self.describe(&ax, index)?;
        let children: Vec<Ax> = children
            .map(|c| c.items().into_iter().filter_map(Ax::from_cf).collect())
            .unwrap_or_default();
        if children.is_empty() {
            return Ok(element);
        }
        if depth + 1 >= self.options.max_depth {
            self.truncated = true;
            return Ok(element);
        }
        for child in children {
            if self.elements.len() >= self.options.max_nodes {
                self.truncated = true;
                break;
            }
            match self.node(child, depth + 1) {
                Ok(e) => element.children.push(e),
                // A child that vanished mid-walk is skipped; the rest stands.
                Err(AX_INVALID_ELEMENT) => {}
                Err(e) => return Err(e),
            }
        }
        Ok(element)
    }
}

struct WindowCache {
    generation: u64,
    elements: Vec<Ax>,
}

/// Element ids of the latest tree of each window. A new tree of a window
/// replaces its ids; an id of an older tree is stale.
#[derive(Default)]
pub struct ElementCache {
    inner: Mutex<CacheInner>,
}

#[derive(Default)]
struct CacheInner {
    next_generation: u64,
    windows: HashMap<String, WindowCache>,
    order: VecDeque<String>,
}

impl ElementCache {
    fn next_generation(&self) -> u64 {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.next_generation += 1;
        inner.next_generation
    }

    fn store(&self, window_id: &str, generation: u64, elements: Vec<Ax>) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.order.retain(|w| w != window_id);
        inner.order.push_back(window_id.to_string());
        inner.windows.insert(window_id.to_string(), WindowCache { generation, elements });
        while inner.order.len() > MAX_CACHED_WINDOWS {
            if let Some(old) = inner.order.pop_front() {
                inner.windows.remove(&old);
            }
        }
    }

    /// The element behind `element_id` of `window_id`'s latest tree.
    pub fn lookup(&self, window_id: &str, element_id: &str) -> DResult<Ax> {
        let (generation, index) = roles::parse_element_id(element_id).ok_or_else(|| {
            DesktopError::TargetNotFound(format!("element {element_id} (not an element id)"))
        })?;
        let ax = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            let cache = inner
                .windows
                .get(window_id)
                .filter(|c| c.generation == generation)
                .ok_or_else(|| DesktopError::StaleElement(element_id.to_string()))?;
            cache
                .elements
                .get(index)
                .cloned()
                .ok_or_else(|| DesktopError::StaleElement(element_id.to_string()))?
        };
        match ax.alive() {
            Ok(()) => Ok(ax),
            Err(AX_INVALID_ELEMENT) => Err(DesktopError::StaleElement(element_id.to_string())),
            Err(e) => Err(ax_error(e, &format!("element {element_id}"))),
        }
    }

    /// Walks `window` (the AX element of `window_id`) and caches its ids.
    pub fn tree(&self, window_id: &str, window: Ax, options: TreeOptions) -> DResult<UiTree> {
        let names: Vec<Cf> = NODE_ATTRS.iter().filter_map(|n| Cf::string(n)).collect();
        let ptrs: Vec<CFTypeRef> = names.iter().map(Cf::ptr).collect();
        let attrs = Cf::array(&ptrs)
            .ok_or_else(|| DesktopError::Failed("could not build the attribute list".into()))?;
        let mut walk = Walk {
            attrs,
            options: TreeOptions {
                max_nodes: options.max_nodes.max(1),
                max_depth: options.max_depth.max(1),
            },
            generation: self.next_generation(),
            elements: Vec::new(),
            truncated: false,
        };
        let root = walk.node(window, 0).map_err(|e| ax_error(e, &format!("window {window_id}")))?;
        let truncated = walk.truncated;
        self.store(window_id, walk.generation, walk.elements);
        Ok(UiTree { window_id: window_id.to_string(), root, truncated })
    }
}
