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
pub(super) const MESSAGE_TIMEOUT_SECONDS: f32 = 1.5;
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

    pub(super) fn from_cf(cf: Cf) -> Option<Ax> {
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

    /// Several attributes in one round trip, each as [`Ax::attr`] reads it
    /// (Ok(None) for a missing value, Err for one that could not be read).
    pub fn attrs(&self, names: &[&str]) -> Result<Vec<Result<Option<Cf>, AXError>>, AXError> {
        let keys: Vec<Cf> = names.iter().filter_map(|n| Cf::string(n)).collect();
        let ptrs: Vec<CFTypeRef> = keys.iter().map(Cf::ptr).collect();
        let list = Cf::array(&ptrs).ok_or(AX_CANNOT_COMPLETE)?;
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: self and the list are live; out receives a +1 CFArray.
        let err =
            unsafe { AXUIElementCopyMultipleAttributeValues(self.ptr(), list.ptr(), 0, &mut out) };
        if err != AX_OK {
            return Err(err);
        }
        let values = Cf::created(out).map(|a| a.items()).unwrap_or_default();
        let mut read: Vec<Result<Option<Cf>, AXError>> = values
            .into_iter()
            .map(|v| {
                if failed_read(&v) {
                    Err(AX_CANNOT_COMPLETE)
                } else if is_error_value(&v) {
                    Ok(None)
                } else {
                    Ok(Some(v))
                }
            })
            .collect();
        read.resize_with(names.len(), || Err(AX_CANNOT_COMPLETE));
        Ok(read)
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

    /// The text selection (`AXSelectedTextRange`): location and length.
    pub fn selected_range(&self) -> Option<(i64, i64)> {
        let v = self.attr("AXSelectedTextRange").ok().flatten()?;
        let mut r = [0isize; 2];
        // SAFETY: checked to be an AXValue holding a CFRange (two CFIndex)
        // before it is read into one.
        unsafe {
            if v.type_id() != AXValueGetTypeID() || AXValueGetType(v.ptr()) != AX_VALUE_CFRANGE {
                return None;
            }
            if AXValueGetValue(v.ptr(), AX_VALUE_CFRANGE, r.as_mut_ptr().cast()) == 0 {
                return None;
            }
        }
        Some((r[0] as i64, r[1] as i64))
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

    /// The app's AXWindows that are windows (role AXWindow).
    pub fn windows(&self) -> Vec<Ax> {
        self.elements("AXWindows")
            .into_iter()
            .filter(|w| w.string("AXRole").as_deref() == Some("AXWindow"))
            .collect()
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

    /// How long messages to this element may take (a press that runs a
    /// menu-tracking loop answers only when the menu closes).
    pub fn set_timeout(&self, seconds: f32) {
        // SAFETY: self is a live element.
        unsafe { AXUIElementSetMessagingTimeout(self.ptr(), seconds) };
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
    // Only real windows: some apps list other elements in AXWindows (Safari
    // lists an image and a text area of its Start Page), and
    // _AXUIElementGetWindow answers the containing window's id for any
    // element, so the first of those "matched" and every call acted on it.
    let windows = app.windows();
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
    for w in app.windows() {
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
    /// One element's attributes (NODE_ATTRS order, None for a missing or
    /// unreadable one), and which slots failed with an error other than "no
    /// value" or "unsupported" (a value that exists but could not be read).
    fn read_checked(&self, ax: &Ax) -> Result<(Vec<Option<Cf>>, Vec<bool>), AXError> {
        let mut out: CFTypeRef = std::ptr::null();
        // SAFETY: ax and the attribute array are live; out receives a +1 CFArray.
        let err = unsafe {
            AXUIElementCopyMultipleAttributeValues(ax.ptr(), self.attrs.ptr(), 0, &mut out)
        };
        if err != AX_OK {
            return Err(err);
        }
        let values = Cf::created(out).map(|a| a.items()).unwrap_or_default();
        let mut failed: Vec<bool> = values.iter().map(failed_read).collect();
        let mut slots: Vec<Option<Cf>> =
            values.into_iter().map(|v| (!is_error_value(&v)).then_some(v)).collect();
        slots.resize_with(NODE_ATTRS.len(), || None);
        failed.resize(NODE_ATTRS.len(), false);
        Ok((slots, failed))
    }

    /// One element's own fields (no children) and its AXChildren value.
    fn describe(&self, ax: &Ax, index: usize) -> Result<(Element, Option<Cf>), AXError> {
        self.describe_raw(ax, index).map(|(e, c, _)| (e, c))
    }

    /// [`Walk::describe`], with the raw role and title as read (for the deny
    /// list in menus, with no second read).
    fn describe_raw(
        &self,
        ax: &Ax,
        index: usize,
    ) -> Result<(Element, Option<Cf>, RawNode), AXError> {
        let (mut v, failed) = self.read_checked(ax)?;
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
        let raw = RawNode {
            role: if failed[0] { None } else { Some(role) },
            title: if failed[2] { None } else { Some(text(&v[2])) },
        };
        Ok((element, v[9].take(), raw))
    }

    /// The menu bar, breadth-first (every top menu's items before any
    /// submenu's), at most `budget` nodes and MENU_DEPTH levels
    /// ([`roles::breadth_first`]); items `blocked` says reach a denied app are
    /// left out. Sets `truncated` when the budget or depth cuts it short.
    fn menu_bar(
        &mut self,
        bar: Ax,
        budget: usize,
        blocked: &dyn Fn(&roles::MenuItemContext) -> bool,
    ) -> Result<Element, AXError> {
        struct Node {
            ax: Ax,
            top_index: Option<usize>,
            menus: usize,
            siblings: std::rc::Rc<Vec<String>>,
        }
        let mut described: Vec<Element> = Vec::new();
        let mut failure: Option<AXError> = None;
        let root =
            Node { ax: bar, top_index: None, menus: 0, siblings: std::rc::Rc::new(Vec::new()) };
        let first = self.elements.len();
        let mut kept = 0usize;
        let (slots, truncated) = roles::breadth_first(root, budget, MENU_DEPTH, |n, depth| {
            // The element id is its index in self.elements: kept nodes are
            // pushed below, in this same order.
            let index = first + kept;
            let (element, children) = match self.describe(&n.ax, index) {
                Ok(v) => v,
                Err(e) => {
                    if depth == 0 {
                        failure = Some(e);
                    }
                    return None;
                }
            };
            let role = n.ax.string("AXRole").unwrap_or_default();
            if role == "AXMenuItem" {
                let title = n.ax.string("AXTitle").unwrap_or_default();
                let ctx = roles::MenuItemContext {
                    title: &title,
                    top_index: n.top_index,
                    depth: n.menus,
                    siblings: &n.siblings,
                    launch: None,
                };
                if blocked(&ctx) {
                    return None;
                }
            }
            kept += 1;
            described.push(element);
            let children: Vec<Ax> = children
                .map(|c| c.items().into_iter().filter_map(Ax::from_cf).collect())
                .unwrap_or_default();
            let is_menu = role == "AXMenu";
            let siblings = if is_menu {
                std::rc::Rc::new(
                    children.iter().map(|c| c.string("AXTitle").unwrap_or_default()).collect(),
                )
            } else {
                n.siblings.clone()
            };
            Some(
                children
                    .into_iter()
                    .enumerate()
                    .map(|(i, ax)| Node {
                        ax,
                        top_index: if depth == 0 { Some(i) } else { n.top_index },
                        menus: n.menus + usize::from(is_menu),
                        siblings: siblings.clone(),
                    })
                    .collect(),
            )
        });
        if let Some(e) = failure {
            return Err(e);
        }
        if truncated {
            self.truncated = true;
        }
        let mut parents: Vec<Option<usize>> = Vec::with_capacity(slots.len());
        for slot in slots {
            self.elements.push(slot.node.ax);
            parents.push(slot.parent);
        }
        // Children come after their parents: attach from the end.
        while described.len() > 1 {
            let i = described.len() - 1;
            let Some(element) = described.pop() else { break };
            if let Some(p) = parents[i] {
                described[p].children.insert(0, element);
            }
        }
        described.pop().ok_or(AX_INVALID_ELEMENT)
    }

    /// One element and its subtree, or None when it is a menu item `f` hides.
    /// Inside a menu (an open pop-up's, one a closed pop-up lists, or one this
    /// desktop opened) every item is held to the deny list from what this
    /// walk already read: its own role and title, how many menus enclose it,
    /// the titles above it, and (only when `f` needs them) its menu's titles.
    fn node(
        &mut self,
        ax: Ax,
        depth: usize,
        f: &MenuFilter<'_>,
        place: Option<&MenuPlace>,
        launch: bool,
    ) -> Result<Option<Element>, AXError> {
        let index = self.elements.len();
        self.elements.push(ax.clone());
        let (mut element, children, raw) = self.describe_raw(&ax, index)?;
        let role = raw.role.as_deref();
        // An item of a menu, or a child of a menu whose role cannot be read.
        if let Some(place) = place
            && place.in_menu
            && (role == Some("AXMenuItem") || role.is_none())
        {
            let item = OpenedItem {
                title: raw.title.as_deref().unwrap_or(""),
                title_failed: raw.title.is_none(),
                depth: place.depth,
                path: place.path.as_deref(),
                launch,
            };
            if (f.blocked)(&ax, &item) {
                self.elements.truncate(index);
                return Ok(None);
            }
        }
        let children: Vec<Ax> = children
            .map(|c| c.items().into_iter().filter_map(Ax::from_cf).collect())
            .unwrap_or_default();
        if children.is_empty() {
            return Ok(Some(element));
        }
        if depth + 1 >= self.options.max_depth {
            self.truncated = true;
            return Ok(Some(element));
        }
        // Where this node's children are: a menu (an unreadable role counts
        // as one: its items are checked), an item's submenu, or as before.
        let next = MenuPlace::below(place, role, raw.title.as_deref());
        let child_launch = match &next {
            Some(n) if n.in_menu && (f.needs_siblings)(n.depth) => {
                // A title that cannot be read leaves the siblings unknown.
                let titles: Option<Vec<String>> = children
                    .iter()
                    .map(|c| {
                        c.attr("AXTitle").map(|v| v.and_then(|v| v.as_string()).unwrap_or_default())
                    })
                    .collect::<Result<Vec<_>, _>>()
                    .ok();
                (f.launch_list)(titles.as_deref())
            }
            _ => false,
        };
        for child in children {
            if self.elements.len() >= self.options.max_nodes {
                self.truncated = true;
                break;
            }
            match self.node(child, depth + 1, f, next.as_ref(), child_launch) {
                Ok(Some(e)) => element.children.push(e),
                Ok(None) => {}
                // A child that vanished mid-walk is skipped; the rest stands.
                Err(AX_INVALID_ELEMENT) => {}
                Err(e) => return Err(e),
            }
        }
        Ok(Some(element))
    }
}

/// An element's role and title as one read returned them: None when the
/// value exists but could not be read.
struct RawNode {
    role: Option<String>,
    title: Option<String>,
}

/// Whether an attribute value is an error other than "no value" or
/// "unsupported" (the attribute is there, and reading it failed).
fn failed_read(v: &Cf) -> bool {
    if !is_error_value(v) {
        return false;
    }
    let mut code: AXError = 0;
    // SAFETY: an AXValue of the error type holds an AXError.
    let ok =
        unsafe { AXValueGetValue(v.ptr(), AX_VALUE_ERROR, (&mut code as *mut AXError).cast()) };
    ok == 0 || !matches!(code, AX_NO_VALUE | AX_ATTRIBUTE_UNSUPPORTED)
}

/// Where a walk is relative to menus: whether the next elements are a
/// menu's children, how many menus enclose them, and the titles of the
/// items above (None when one could not be read).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuPlace {
    pub in_menu: bool,
    pub depth: usize,
    pub path: Option<Vec<String>>,
}

impl MenuPlace {
    /// The place of the children of an element with `role` and `title`
    /// that sits at `place`.
    pub fn below(
        place: Option<&MenuPlace>,
        role: Option<&str>,
        title: Option<&str>,
    ) -> Option<Self> {
        match role {
            Some("AXMenu") | None => {
                let mut p = place
                    .cloned()
                    .unwrap_or(MenuPlace { path: Some(vec![]), ..Default::default() });
                p.in_menu = true;
                p.depth += 1;
                Some(p)
            }
            Some("AXMenuItem") => place.map(|p| MenuPlace {
                in_menu: false,
                depth: p.depth,
                path: match (&p.path, title) {
                    (Some(path), Some(t)) => {
                        Some(path.iter().cloned().chain([t.to_string()]).collect())
                    }
                    _ => None,
                },
            }),
            _ => place.map(|p| MenuPlace { in_menu: false, ..p.clone() }),
        }
    }
}

/// A menu item a walk reached, as it read it.
pub struct OpenedItem<'a> {
    pub title: &'a str,
    /// The title could not be read.
    pub title_failed: bool,
    /// How many menus enclose it.
    pub depth: usize,
    /// The titles of the items above it, outermost first (None: one could
    /// not be read).
    pub path: Option<&'a [String]>,
    /// Its menu is a launch list by its items (most name installed apps),
    /// worked out once per menu when [`MenuFilter::needs_siblings`] asked.
    pub launch: bool,
}

/// How a walk holds menu items to the deny list.
pub struct MenuFilter<'a> {
    pub blocked: &'a dyn Fn(&Ax, &OpenedItem) -> bool,
    /// Whether items at this menu depth need their menu's titles (read once
    /// per menu, only then).
    pub needs_siblings: &'a dyn Fn(usize) -> bool,
    /// Whether a menu with these titles is a launch list (once per menu);
    /// None when a title could not be read.
    pub launch_list: &'a dyn Fn(Option<&[String]>) -> bool,
}

/// The menu bar's own node budget in a tree, and its depth: bar, top menu,
/// its menu, an item, a submenu, its items.
const MENU_NODES: usize = 600;
const MENU_DEPTH: usize = 6;

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
    /// With `options.menus`, the app's menu bar follows the window: every
    /// menu's items while the menus stay closed, so an agent presses a menu
    /// item (click or perform_action) and it runs with no menu opening over
    /// the person's screen. `blocked` hides items that would reach a denied app.
    /// `extra` elements outside the window that belong to it (a menu this
    /// desktop opened for it) are walked as more children of the root, once;
    /// their menu items `menu_filter` says reach a denied app are left out.
    pub fn tree(
        &self,
        window_id: &str,
        window: Ax,
        extra: Vec<Ax>,
        options: TreeOptions,
        blocked: &dyn Fn(&roles::MenuItemContext) -> bool,
        menu_filter: &MenuFilter<'_>,
    ) -> DResult<UiTree> {
        let names: Vec<Cf> = NODE_ATTRS.iter().filter_map(|n| Cf::string(n)).collect();
        let ptrs: Vec<CFTypeRef> = names.iter().map(Cf::ptr).collect();
        let attrs = Cf::array(&ptrs)
            .ok_or_else(|| DesktopError::Failed("could not build the attribute list".into()))?;
        let max_nodes = options.max_nodes.max(1);
        let bar = options
            .menus
            .then(|| {
                window.pid().and_then(Ax::application).and_then(|app| app.element("AXMenuBar"))
            })
            .flatten();
        // The menu bar's share of max_nodes is kept back from the window walk,
        // so a large window never crowds the menus out (and the reverse).
        let menu_share = if bar.is_some() { (max_nodes / 4).min(MENU_NODES) } else { 0 };
        let mut walk = Walk {
            attrs,
            options: TreeOptions {
                max_nodes: (max_nodes - menu_share).max(1),
                max_depth: options.max_depth.max(1),
                menus: options.menus,
            },
            generation: self.next_generation(),
            elements: Vec::new(),
            truncated: false,
        };
        let mut root = walk
            .node(window, 0, menu_filter, None, false)
            .map_err(|e| ax_error(e, &format!("window {window_id}")))?
            .ok_or_else(|| DesktopError::Failed(format!("window {window_id} could not be read")))?;
        for more in extra {
            if walk.elements.iter().any(|seen| seen.same(&more)) {
                continue;
            }
            if walk.elements.len() >= walk.options.max_nodes {
                walk.truncated = true;
                break;
            }
            if let Ok(Some(node)) = walk.node(more, 1, menu_filter, None, false) {
                root.children.push(node);
            }
        }
        if let Some(bar) = bar {
            let budget = max_nodes.saturating_sub(walk.elements.len()).min(MENU_NODES);
            if let Ok(menus) = walk.menu_bar(bar, budget, blocked) {
                root.children.push(menus);
            }
        }
        let truncated = walk.truncated;
        self.store(window_id, walk.generation, walk.elements);
        Ok(UiTree { window_id: window_id.to_string(), root, truncated })
    }
}

/// Where a menu item sits: the index of the menu bar item it is under, how
/// many menus it is inside, and the titles of the items of its own menu
/// (None when one of them cannot be read: the siblings are unknown, which
/// is not the item's place).
pub type MenuContext = (Option<usize>, usize, Option<Vec<String>>);

pub fn menu_context(item: &Ax) -> Option<MenuContext> {
    // A read on the item's own chain that fails is None (the caller fails
    // closed); a sibling's title that fails only leaves the siblings unknown.
    let role = |n: &Ax| n.attr("AXRole").map(|v| v.and_then(|v| v.as_string()));
    let kids = |n: &Ax| -> Option<Vec<Ax>> {
        n.attr("AXChildren").ok().map(|v| {
            v.map(|l| l.items().into_iter().filter_map(Ax::from_cf).collect()).unwrap_or_default()
        })
    };
    let parent = item.attr("AXParent").ok()?.and_then(Ax::from_cf);
    let siblings = match &parent {
        Some(p) if role(p).ok()?.as_deref() == Some("AXMenu") => kids(p).and_then(|k| {
            k.iter()
                .map(|c| {
                    c.attr("AXTitle").map(|v| v.and_then(|v| v.as_string()).unwrap_or_default())
                })
                .collect::<Result<Vec<_>, _>>()
                .ok()
        }),
        _ => Some(Vec::new()),
    };
    let mut menus = 0usize;
    let mut top_item: Option<Ax> = None;
    let mut current = parent;
    for _ in 0..16 {
        let Some(node) = current else { break };
        match role(&node).ok()?.as_deref() {
            Some("AXMenu") => menus += 1,
            Some("AXMenuBarItem") => top_item = Some(node.clone()),
            Some("AXMenuBar") => {
                let index = top_item
                    .as_ref()
                    .and_then(|t| kids(&node).and_then(|k| k.iter().position(|c| c.same(t))));
                return Some((index, menus, siblings));
            }
            _ => {}
        }
        current = node.attr("AXParent").ok()?.and_then(Ax::from_cf);
    }
    Some((None, menus, siblings))
}

/// Whether the element is a menu item (or menu bar item) of an app's menu bar.
pub fn in_menu_bar(el: &Ax) -> bool {
    let mut current = Some(el.clone());
    for _ in 0..16 {
        let Some(node) = current else { return false };
        match node.string("AXRole").as_deref() {
            Some("AXMenuBar") => return true,
            Some("AXWindow") | Some("AXApplication") | None => return false,
            _ => {}
        }
        current = node.element("AXParent");
    }
    false
}

/// CFRunLoopRunInMode's kCFRunLoopRunFinished.
const RUN_LOOP_FINISHED: i32 = 1;

/// Waits until `pid` is the active app (`is_front` says so), up to `limit`:
/// an AXObserver for the app's kAXApplicationActivatedNotification, its
/// source on this thread's run loop in a private mode, run until a wake
/// finds the app in front or the time is up. True when it is in front.
///
/// An app that takes no AX observer (some non-AppKit apps) gets one check
/// right after it was asked to activate, which can come too early: callers
/// see a refusal they can retry. No polling replaces the notification.
pub fn wait_activated(pid: i32, limit: std::time::Duration, is_front: &dyn Fn() -> bool) -> bool {
    if is_front() {
        return true;
    }
    unsafe extern "C" fn on_activated(
        _observer: CFTypeRef,
        _element: CFTypeRef,
        _notification: CFTypeRef,
        _refcon: *mut c_void,
    ) {
        // The wake itself is the signal: the loop below reads the front app.
    }
    let deadline = std::time::Instant::now() + limit;
    let (Some(app), Some(note), Some(mode)) = (
        Ax::application(pid),
        Cf::string("AXApplicationActivated"),
        Cf::string("com.cmuxterm.cu.raise"),
    ) else {
        return is_front();
    };
    let mut raw: CFTypeRef = std::ptr::null();
    // SAFETY: out-parameter; a +1 observer on success.
    if unsafe { AXObserverCreate(pid, on_activated, &mut raw) } != AX_OK {
        return is_front();
    }
    let Some(observer) = Cf::created(raw) else { return is_front() };
    // SAFETY: live observer, element and string; refcon unused.
    let added = unsafe {
        AXObserverAddNotification(observer.ptr(), app.ptr(), note.ptr(), std::ptr::null_mut())
    } == AX_OK;
    // SAFETY: a borrowed source of the live observer.
    let source = unsafe { AXObserverGetRunLoopSource(observer.ptr()) };
    // SAFETY: the current thread's run loop (borrowed).
    let run_loop = unsafe { CFRunLoopGetCurrent() };
    if added && !source.is_null() {
        // SAFETY: live run loop, source and mode.
        unsafe { CFRunLoopAddSource(run_loop, source, mode.ptr()) };
    }
    let mut front = is_front();
    while !front {
        let now = std::time::Instant::now();
        if now >= deadline {
            break;
        }
        if added && !source.is_null() {
            // SAFETY: runs this thread's loop in the private mode until a
            // source fires or the remaining time passes.
            let result =
                unsafe { CFRunLoopRunInMode(mode.ptr(), (deadline - now).as_secs_f64(), 1) };
            // kCFRunLoopRunFinished: no source left in the mode (the observer's
            // was invalidated); nothing more can wake it.
            if result == RUN_LOOP_FINISHED {
                front = is_front();
                break;
            }
        } else {
            // No observer (the app does not take one): one last look at the
            // deadline, no polling.
            break;
        }
        front = is_front();
    }
    if added && !source.is_null() {
        // SAFETY: as above.
        unsafe {
            CFRunLoopRemoveSource(run_loop, source, mode.ptr());
            AXObserverRemoveNotification(observer.ptr(), app.ptr(), note.ptr());
        }
    }
    front || is_front()
}
