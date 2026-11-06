//! UI Automation: the accessibility tree and semantic actions.
//!
//! All UIA work runs on one thread of its own (a COM multithreaded
//! apartment, as Microsoft recommends for UIA clients) that owns the
//! IUIAutomation object and the elements of each window's latest walk.
//! Element ids are `<generation>.<index>` into that walk: a new walk of a
//! window makes its older ids stale, so an id never silently names another
//! element. A call into a hung app cannot hang the desktop: each job has a
//! deadline, and a thread that misses one is abandoned for a fresh one.

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx,
};
use windows::Win32::UI::Accessibility::*;

use super::pure;
use super::win::{self, Hwnd};
use crate::desktop::{DResult, DesktopError, Element, Point, TreeOptions, UiTree};

pub use super::uia_act::TextTarget;

/// A tree walk stops here even when under its node budget.
const WALK_BUDGET: Duration = Duration::from_secs(8);
/// A job's deadline (a walk adds its budget).
const JOB_DEADLINE: Duration = Duration::from_secs(10);
/// Invoke is synchronous: on a button that opens a modal dialog it returns
/// only when the dialog closes. Past this, the press counts as delivered.
pub const INVOKE_DEADLINE: Duration = Duration::from_secs(3);

/// ExpandCollapseState and ToggleState values (UIAutomationCore.h), as
/// plain numbers so they can be match patterns.
pub const COLLAPSED: i32 = ExpandCollapseState_Collapsed.0;
pub const EXPANDED: i32 = ExpandCollapseState_Expanded.0;
pub const LEAF: i32 = ExpandCollapseState_LeafNode.0;
const TOGGLE_ON: i32 = ToggleState_On.0;
const TOGGLE_OFF: i32 = ToggleState_Off.0;

pub(super) struct State {
    pub automation: IUIAutomation,
    pub cache: IUIAutomationCacheRequest,
    walker: IUIAutomationTreeWalker,
    windows: HashMap<usize, (u64, Vec<IUIAutomationElement>)>,
    next_generation: u64,
}

type Job = Box<dyn FnOnce(&mut State) + Send>;

pub struct Uia {
    /// The live UIA thread and its serial number (a thread that missed a
    /// deadline is replaced, and only by the caller that saw it miss).
    worker: Mutex<Option<(u64, mpsc::Sender<Job>)>>,
    serial: std::sync::atomic::AtomicU64,
}

fn start() -> Result<mpsc::Sender<Job>, String> {
    let (tx, rx) = mpsc::channel::<Job>();
    let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
    std::thread::Builder::new()
        .name("cmux-cu-uia".into())
        .spawn(move || {
            let state = State::new();
            let mut state = match state {
                Ok(s) => {
                    let _ = ready_tx.send(Ok(()));
                    s
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
            };
            for job in rx {
                job(&mut state);
            }
        })
        .map_err(|e| format!("could not start the UI Automation thread: {e}"))?;
    ready_rx.recv().map_err(|_| "the UI Automation thread exited".to_string())??;
    Ok(tx)
}

impl State {
    fn new() -> Result<Self, String> {
        super::ensure_dpi_awareness();
        // SAFETY: this thread's own COM apartment, kept for its lifetime.
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
                    .or_else(|_| CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER))
                    .map_err(|e| format!("UI Automation is unavailable: {e}"))?;
            let cache = automation.CreateCacheRequest().map_err(|e| e.to_string())?;
            for p in [
                UIA_ControlTypePropertyId,
                UIA_NamePropertyId,
                UIA_BoundingRectanglePropertyId,
                UIA_IsEnabledPropertyId,
                UIA_HasKeyboardFocusPropertyId,
                UIA_IsKeyboardFocusablePropertyId,
                UIA_NativeWindowHandlePropertyId,
                UIA_ValueValuePropertyId,
                UIA_ValueIsReadOnlyPropertyId,
                UIA_RangeValueValuePropertyId,
                UIA_RangeValueIsReadOnlyPropertyId,
                UIA_ToggleToggleStatePropertyId,
                UIA_ExpandCollapseExpandCollapseStatePropertyId,
                UIA_LegacyIAccessibleDefaultActionPropertyId,
            ] {
                cache.AddProperty(p).map_err(|e| e.to_string())?;
            }
            for p in [
                UIA_InvokePatternId,
                UIA_TogglePatternId,
                UIA_ExpandCollapsePatternId,
                UIA_SelectionItemPatternId,
                UIA_ValuePatternId,
                UIA_RangeValuePatternId,
                UIA_LegacyIAccessiblePatternId,
            ] {
                cache.AddPattern(p).map_err(|e| e.to_string())?;
            }
            let walker = automation.ControlViewWalker().map_err(|e| e.to_string())?;
            Ok(Self { automation, cache, walker, windows: HashMap::new(), next_generation: 1 })
        }
    }

    /// The element `id` names in the latest walk of `hwnd`.
    pub fn element(&self, hwnd: Hwnd, id: &str) -> DResult<IUIAutomationElement> {
        let stale = || DesktopError::StaleElement(id.to_string());
        let (generation, index) = pure::parse_element_id(id).ok_or_else(stale)?;
        let (current, elements) = self.windows.get(&hwnd.0).ok_or_else(stale)?;
        if *current != generation {
            return Err(stale());
        }
        elements.get(index).cloned().ok_or_else(stale)
    }
}

/// UIA_E_ELEMENTNOTAVAILABLE: the element left the tree.
pub fn uia_error(e: windows::core::Error, id: &str, what: &str) -> DesktopError {
    if e.code().0 as u32 == 0x8004_0201 {
        DesktopError::StaleElement(id.to_string())
    } else {
        DesktopError::Failed(format!("{what} failed: {e}"))
    }
}

impl Uia {
    pub fn new() -> Self {
        Self { worker: Mutex::new(None), serial: std::sync::atomic::AtomicU64::new(0) }
    }

    /// Runs `job` on the UIA thread. Past `deadline` the thread is
    /// abandoned (a fresh one serves the next call) and `late` decides the
    /// answer.
    pub(super) fn run_with<T: Send + 'static>(
        &self,
        deadline: Duration,
        late: impl FnOnce() -> DResult<T>,
        job: impl FnOnce(&mut State) -> DResult<T> + Send + 'static,
    ) -> DResult<T> {
        let (serial, tx) = {
            let mut worker = self.worker.lock().unwrap_or_else(|e| e.into_inner());
            match worker.as_ref() {
                Some((serial, tx)) => (*serial, tx.clone()),
                None => {
                    let tx = start().map_err(DesktopError::Failed)?;
                    let serial = self.serial.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    *worker = Some((serial, tx.clone()));
                    (serial, tx)
                }
            }
        };
        let (done_tx, done_rx) = mpsc::channel();
        let sent = tx.send(Box::new(move |state: &mut State| {
            let _ = done_tx.send(job(state));
        }));
        if sent.is_err() {
            *self.worker.lock().unwrap_or_else(|e| e.into_inner()) = None;
            return Err(DesktopError::Failed("the UI Automation thread stopped; try again".into()));
        }
        match done_rx.recv_timeout(deadline) {
            Ok(result) => result,
            Err(_) => {
                let mut worker = self.worker.lock().unwrap_or_else(|e| e.into_inner());
                if worker.as_ref().is_some_and(|(s, _)| *s == serial) {
                    *worker = None;
                }
                late()
            }
        }
    }

    pub(super) fn run<T: Send + 'static>(
        &self,
        job: impl FnOnce(&mut State) -> DResult<T> + Send + 'static,
    ) -> DResult<T> {
        self.run_with(
            JOB_DEADLINE,
            || {
                Err(DesktopError::Failed(
                    "the app did not answer UI Automation in time (it may be busy or hung)".into(),
                ))
            },
            job,
        )
    }

    pub fn tree(&self, hwnd: Hwnd, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let window_id = window_id.to_string();
        self.run_with(
            JOB_DEADLINE + WALK_BUDGET,
            || {
                Err(DesktopError::Failed(
                    "the app did not answer UI Automation in time (it may be busy or hung)".into(),
                ))
            },
            move |state| {
                // SAFETY: COM calls on this thread's own objects.
                let root = unsafe {
                    state.automation.ElementFromHandleBuildCache(hwnd.get(), &state.cache)
                }
                .map_err(|e| {
                    DesktopError::Failed(format!(
                        "UI Automation cannot read window {}: {e}",
                        hwnd.0
                    ))
                })?;
                let generation = state.next_generation;
                state.next_generation += 1;
                let mut walk = Walk {
                    state,
                    generation,
                    elements: Vec::new(),
                    options,
                    deadline: Instant::now() + WALK_BUDGET,
                    truncated: false,
                };
                let root_node = walk.node(&root, 0);
                let elements = std::mem::take(&mut walk.elements);
                let truncated = walk.truncated;
                state.windows.insert(hwnd.0, (generation, elements));
                // Windows that closed keep no elements alive.
                state.windows.retain(|&h, _| Hwnd::parse(&h.to_string()).is_ok());
                Ok(UiTree { window_id, root: root_node, truncated })
            },
        )
    }

    /// The element's center now, in desktop pixels.
    pub fn center(&self, hwnd: Hwnd, id: &str) -> DResult<Point> {
        let id = id.to_string();
        self.run(move |state| {
            let el = state.element(hwnd, &id)?;
            center_of(&el, &id)
        })
    }
}

pub fn center_of(el: &IUIAutomationElement, id: &str) -> DResult<Point> {
    // SAFETY: a COM call on this thread's object.
    let r = unsafe { el.CurrentBoundingRectangle() }
        .map_err(|e| uia_error(e, id, "reading the element frame"))?;
    if r.right <= r.left || r.bottom <= r.top {
        return Err(DesktopError::Unsupported(format!(
            "element {id} is not on screen (it has no frame)"
        )));
    }
    Ok(Point { x: f64::from(r.left + r.right) / 2.0, y: f64::from(r.top + r.bottom) / 2.0 })
}

struct Walk<'a> {
    state: &'a State,
    generation: u64,
    elements: Vec<IUIAutomationElement>,
    options: TreeOptions,
    deadline: Instant,
    truncated: bool,
}

/// What the element can do, in the shared action vocabulary.
fn actions_of(el: &IUIAutomationElement) -> Vec<String> {
    let mut out: Vec<&str> = Vec::new();
    // SAFETY: COM calls on cached data of this thread's element.
    unsafe {
        let has = |id: UIA_PATTERN_ID| el.GetCachedPattern(id).is_ok();
        if has(UIA_InvokePatternId) || has(UIA_TogglePatternId) {
            out.push("press");
        }
        if has(UIA_SelectionItemPatternId) {
            out.push("select");
        }
        if let Ok(p) =
            el.GetCachedPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId)
        {
            match p.CachedExpandCollapseState().map(|s| s.0) {
                Ok(COLLAPSED) => out.push("expand"),
                Ok(EXPANDED) => out.push("collapse"),
                Ok(LEAF) | Err(_) => {}
                Ok(_) => out.extend(["expand", "collapse"]),
            }
        }
        if let Ok(p) =
            el.GetCachedPatternAs::<IUIAutomationRangeValuePattern>(UIA_RangeValuePatternId)
            && !p.CachedIsReadOnly().is_ok_and(|r| r.as_bool())
        {
            out.extend(["increment", "decrement"]);
        }
        if !out.contains(&"press")
            && let Ok(p) = el.GetCachedPatternAs::<IUIAutomationLegacyIAccessiblePattern>(
                UIA_LegacyIAccessiblePatternId,
            )
            && p.CachedDefaultAction().is_ok_and(|a| !a.is_empty())
        {
            out.push("press");
        }
    }
    out.into_iter().map(String::from).collect()
}

fn value_of(el: &IUIAutomationElement) -> String {
    // SAFETY: COM calls on cached data of this thread's element.
    unsafe {
        if let Ok(p) = el.GetCachedPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
            && let Ok(v) = p.CachedValue()
        {
            return v.to_string();
        }
        if let Ok(p) =
            el.GetCachedPatternAs::<IUIAutomationRangeValuePattern>(UIA_RangeValuePatternId)
            && let Ok(v) = p.CachedValue()
        {
            return format!("{v}");
        }
        if let Ok(p) = el.GetCachedPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId)
            && let Ok(s) = p.CachedToggleState()
        {
            return match s.0 {
                TOGGLE_ON => "on",
                TOGGLE_OFF => "off",
                _ => "mixed",
            }
            .into();
        }
    }
    String::new()
}

impl Walk<'_> {
    fn node(&mut self, el: &IUIAutomationElement, depth: usize) -> Element {
        let index = self.elements.len();
        self.elements.push(el.clone());
        // SAFETY: COM calls on cached data of this thread's element.
        let (role, name, frame, focused, disabled) = unsafe {
            let role = el
                .CachedControlType()
                .map(|t| pure::role_for_control_type(t.0))
                .unwrap_or("unknown");
            let name = el.CachedName().map(|n| n.to_string()).unwrap_or_default();
            let frame = el
                .CachedBoundingRectangle()
                .ok()
                .filter(|r| r.right > r.left && r.bottom > r.top)
                .map(win::rect);
            let focused = el.CachedHasKeyboardFocus().is_ok_and(|b| b.as_bool());
            let disabled = el.CachedIsEnabled().is_ok_and(|b| !b.as_bool());
            (role, name, frame, focused, disabled)
        };
        let mut node = Element {
            id: pure::element_id(self.generation, index),
            role: role.into(),
            name,
            value: value_of(el),
            frame,
            actions: actions_of(el),
            focused,
            disabled,
            children: Vec::new(),
        };
        if depth + 1 >= self.options.max_depth {
            // SAFETY: a COM call on this thread's objects.
            if unsafe { self.state.walker.GetFirstChildElementBuildCache(el, &self.state.cache) }
                .is_ok()
            {
                self.truncated = true;
            }
            return node;
        }
        // SAFETY: COM calls on this thread's objects.
        let mut child =
            unsafe { self.state.walker.GetFirstChildElementBuildCache(el, &self.state.cache) }.ok();
        while let Some(c) = child {
            if self.elements.len() >= self.options.max_nodes || Instant::now() >= self.deadline {
                self.truncated = true;
                break;
            }
            node.children.push(self.node(&c, depth + 1));
            // SAFETY: as above.
            child =
                unsafe { self.state.walker.GetNextSiblingElementBuildCache(&c, &self.state.cache) }
                    .ok();
        }
        node
    }
}
