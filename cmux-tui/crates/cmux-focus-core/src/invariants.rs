//! The global input invariants (plans/cmux-next/input-spec.md), as pure
//! checks: the model (F) and transition (T) rules over a window's focus, and
//! the world (W) rules that hold the focus against what the platform shows
//! (AppKit, Ghostty, WebKit and Chromium; spec section 2.5). The app's live
//! monitor, `debug.focus` and the input journal's replay call these, so a
//! rule has one definition. The key routing checks (K) read the app's key
//! router and stay in the app.
//!
//! The JSON shapes are the app's `Codable` shapes: [`Model`] reads the
//! app's focus read view (`FocusState`), [`Observation`] its
//! `InputObservation`, and [`Violation`] is its `InputViolation`. A
//! violation's `detail` is a diagnostic for people; the invariant and window
//! are the contract (the monitor de-duplicates on them).

use crate::event::{FocusEvent, Responder};
use crate::state::{Context, Expectation, ExpectationKey, FocusState, Overlay, Resolved, Target};
use crate::topology::{Kind, Topology};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};

/// The invariants these checks report, by spec id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Invariant {
    /// An open overlay is the keyboard target.
    #[serde(rename = "F1")]
    OverlayOnTop,
    /// Focus names a pane and tab that exist and are selected.
    #[serde(rename = "F2")]
    LivePane,
    /// A window with panes has a focused pane.
    #[serde(rename = "F3")]
    PaneWhenPanes,
    /// The target fits the selected tab's kind.
    #[serde(rename = "F4")]
    TargetKind,
    /// No pending focus survives a newer user intent.
    #[serde(rename = "F5")]
    NoStaleExpectation,
    /// Browser focus mode only names live tabs.
    #[serde(rename = "F6")]
    FocusModeLive,
    /// An expectation from an older intent never moves focus.
    #[serde(rename = "T1")]
    NoSteal,
    /// Key, activation, presentation and overlay events never retarget.
    #[serde(rename = "T2")]
    PassiveEvents,
    /// The intent generation never decreases.
    #[serde(rename = "T3")]
    MonotonicGeneration,
    /// The platform first responder matches the model target.
    #[serde(rename = "W1")]
    ResponderMatches,
    /// Layout focus matches the model pane.
    #[serde(rename = "W2")]
    LayoutMatches,
    /// Ghostty focus is the model terminal in the key window only.
    #[serde(rename = "W3")]
    GhosttyMatches,
    /// Chromium page focus matches the model.
    #[serde(rename = "W4")]
    ChromiumMatches,
    /// The key window belongs to the model target.
    #[serde(rename = "W5")]
    KeyWindowOwned,
    /// Open palettes and sheets match the overlay stacks.
    #[serde(rename = "W6")]
    OverlaysMatch,
    /// The window that owns the keyboard is active and its focus is the
    /// published context.
    #[serde(rename = "W7")]
    ContextMatches,
    /// Every shown pane shows its selected tab, and that tab is in the pane.
    #[serde(rename = "W8")]
    PresentedMatchesSelection,
}

/// One broken invariant.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Violation {
    pub invariant: Invariant,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
    pub detail: String,
}

fn none_resolved() -> Resolved {
    Resolved::None {}
}

fn content_target() -> Target {
    Target::Content {}
}

/// What the checks read of one window's focus: the app's read view of the
/// focus state (its `FocusState` JSON), or [`Model::of`] a machine's state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    #[serde(default)]
    pub window_key: bool,
    #[serde(default)]
    pub topology: Topology,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    #[serde(default = "content_target")]
    pub target: Target,
    #[serde(default)]
    pub overlays: Vec<Overlay>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expectation: Option<Expectation>,
    #[serde(default)]
    pub browser_focus_mode: BTreeSet<String>,
    #[serde(default)]
    pub generation: u64,
    /// The keyboard target, the top overlay first.
    #[serde(default = "none_resolved")]
    pub resolved: Resolved,
    /// The target below any overlay.
    #[serde(default = "none_resolved")]
    pub underlying: Resolved,
    #[serde(default)]
    pub context: Context,
}

impl Model {
    /// The focus is on its way to a tab other than the focused one (a
    /// creation's new tab the window does not show yet). The app's
    /// `FocusState.awaitsOtherTab`.
    pub fn awaits_other_tab(&self) -> bool {
        match &self.expectation {
            Some(Expectation { key: ExpectationKey::Tab { id }, .. }) => {
                self.resolved.tab() != Some(id.as_str())
            }
            Some(Expectation { key: ExpectationKey::Surface { .. }, .. }) => true,
            None => false,
        }
    }
}

impl Default for Model {
    fn default() -> Model {
        Model {
            window_key: false,
            topology: Topology::default(),
            pane: None,
            target: Target::Content {},
            overlays: Vec::new(),
            expectation: None,
            browser_focus_mode: BTreeSet::new(),
            generation: 0,
            resolved: Resolved::None {},
            underlying: Resolved::None {},
            context: Context::default(),
        }
    }
}

impl Model {
    /// The view of a machine's state, with its derived targets.
    pub fn of(state: &FocusState) -> Model {
        Model {
            window_key: state.window_key,
            topology: state.topology.clone(),
            pane: state.pane.clone(),
            target: state.target,
            overlays: state.overlays.clone(),
            expectation: state.expectation.clone(),
            browser_focus_mode: state.browser_focus_mode.clone(),
            generation: state.generation,
            resolved: state.derived.resolved.clone(),
            underlying: state.derived.underlying.clone(),
            context: state.derived.context,
        }
    }
}

fn or_nil(text: Option<&str>) -> &str {
    text.unwrap_or("nil")
}

fn kind_name(kind: Option<Kind>) -> &'static str {
    match kind {
        Some(Kind::Terminal) => "terminal",
        Some(Kind::Browser) => "browser",
        Some(Kind::Agent) => "agent",
        Some(Kind::Page) => "page",
        Some(Kind::Conversation) => "conversation",
        Some(Kind::Other) => "other",
        None => "missing",
    }
}

fn context_name(context: Context) -> String {
    format!(
        "Context(terminal: {}, browser: {}, agent: {})",
        context.terminal, context.browser, context.agent
    )
}

fn overlays_name(overlays: &[Overlay]) -> String {
    let names: Vec<&str> = overlays.iter().map(|o| o.name()).collect();
    format!("{names:?}")
}

fn violation(invariant: Invariant, window: Option<&str>, detail: String) -> Violation {
    Violation { invariant, window: window.map(str::to_owned), detail }
}

// MARK: Model (F)

/// Invariants every focus state must satisfy.
pub fn model(state: &Model, window: Option<&str>) -> Vec<Violation> {
    let mut out = Vec::new();
    let mut fail = |invariant, detail| out.push(violation(invariant, window, detail));
    let resolved = &state.resolved;
    if let Some(top) = state.overlays.last()
        && *resolved != (Resolved::Overlay { overlay: *top })
    {
        fail(
            Invariant::OverlayOnTop,
            format!("resolved {} with overlay {} open", resolved.kind(), top.name()),
        );
    }
    if let Some(pane) = state.pane.as_deref()
        && !state.topology.contains_pane(pane)
    {
        fail(Invariant::LivePane, format!("focused pane {pane} is not in the topology"));
    }
    if let Some(pane) = resolved.pane() {
        if Some(pane) != state.pane.as_deref() {
            fail(
                Invariant::LivePane,
                format!("resolved pane {pane} != focused pane {}", or_nil(state.pane.as_deref())),
            );
        }
        if let Some(tab) = resolved.tab()
            && state.topology.pane(pane).and_then(|p| p.selected.as_deref()) != Some(tab)
        {
            fail(Invariant::LivePane, format!("resolved tab {tab} is not the selection of {pane}"));
        }
    }
    if state.pane.is_none() && state.target.is_pane_scoped() && !state.topology.panes.is_empty() {
        fail(
            Invariant::PaneWhenPanes,
            format!("{} panes and no focused pane", state.topology.panes.len()),
        );
    }
    let selected = state.topology.selected_kind(state.pane.as_deref());
    let fits = match resolved {
        Resolved::Terminal { .. } => selected == Some(Kind::Terminal),
        Resolved::BrowserPage { .. } | Resolved::AddressBar { .. } | Resolved::FindBar { .. } => {
            selected == Some(Kind::Browser)
        }
        Resolved::AgentPage { .. } => selected == Some(Kind::Agent),
        Resolved::Page { .. } => selected == Some(Kind::Page),
        Resolved::Conversation { .. } => selected == Some(Kind::Conversation),
        _ => true,
    };
    if !fits {
        fail(
            Invariant::TargetKind,
            format!("{} on a {} tab", resolved.kind(), kind_name(selected)),
        );
    }
    if matches!(state.target, Target::AddressBar {} | Target::FindBar {})
        && selected != Some(Kind::Browser)
    {
        fail(
            Invariant::TargetKind,
            format!("target {} kept on a {} tab", state.target.describe(), kind_name(selected)),
        );
    }
    if let Some(expectation) = &state.expectation
        && expectation.generation != state.generation
    {
        fail(
            Invariant::NoStaleExpectation,
            format!(
                "expectation {} from generation {} at {}",
                expectation.key.describe(),
                expectation.generation,
                state.generation
            ),
        );
    }
    let all = state.topology.all_tab_ids();
    let dead: Vec<&String> =
        state.browser_focus_mode.iter().filter(|t| !all.contains(*t)).collect();
    if !dead.is_empty() {
        fail(Invariant::FocusModeLive, format!("focus mode on missing tabs {dead:?}"));
    }
    out
}

// MARK: Transitions (T)

/// The event's case name, as the diagnostics show it.
fn event_name(event: &FocusEvent) -> String {
    match event {
        FocusEvent::WindowKey { key } => format!("windowKey({key})"),
        FocusEvent::AppActive { active } => format!("appActive({active})"),
        FocusEvent::OverlayOpened { overlay } => format!("overlayOpened({})", overlay.name()),
        FocusEvent::OverlayClosed { overlay } => format!("overlayClosed({})", overlay.name()),
        FocusEvent::ContentPresented { pane } => format!("contentPresented(pane: {pane:?})"),
        // Only the passive events above are named in a report.
        _ => String::new(),
    }
}

/// Rules about how one event may change the state.
pub fn transition(
    old: &Model,
    event: &FocusEvent,
    new: &Model,
    window: Option<&str>,
) -> Vec<Violation> {
    let mut out = Vec::new();
    let mut fail = |invariant, detail| out.push(violation(invariant, window, detail));
    let moved = old.pane != new.pane || old.target != new.target;
    match event {
        FocusEvent::Expect { generation, .. }
            if *generation != old.generation && (moved || new.expectation != old.expectation) =>
        {
            fail(
                Invariant::NoSteal,
                format!("stale expect ({generation} at {}) changed focus", old.generation),
            );
        }
        FocusEvent::WindowKey { .. }
        | FocusEvent::AppActive { .. }
        | FocusEvent::OverlayOpened { .. }
        | FocusEvent::OverlayClosed { .. }
        | FocusEvent::ContentPresented { .. }
            if moved =>
        {
            fail(
                Invariant::PassiveEvents,
                format!(
                    "{} moved focus {}/{} -> {}/{}",
                    event_name(event),
                    or_nil(old.pane.as_deref()),
                    old.target.describe(),
                    or_nil(new.pane.as_deref()),
                    new.target.describe()
                ),
            );
        }
        FocusEvent::Responder { .. } if !old.overlays.is_empty() && moved => {
            fail(
                Invariant::PassiveEvents,
                "responder report under an overlay moved focus".to_owned(),
            );
        }
        _ => {}
    }
    if new.generation < old.generation && old.generation != u64::MAX {
        fail(
            Invariant::MonotonicGeneration,
            format!("generation {} -> {}", old.generation, new.generation),
        );
    }
    out
}

/// Model and transition checks for one reduction (the app adds its key
/// routing checks).
pub fn step(old: &Model, event: &FocusEvent, new: &Model, window: Option<&str>) -> Vec<Violation> {
    let mut out = model(new, window);
    out.extend(transition(old, event, new, window));
    out
}

// MARK: World (W)

/// Which window has the keyboard at the platform level.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum KeyWindow {
    None {},
    /// A cmux window itself.
    Window {
        #[serde(rename = "_0")]
        id: String,
    },
    /// A Chromium page window over cmux window `window`.
    ChildPage {
        window: String,
    },
    /// A panel over cmux window `window` (palette, group editor), or an
    /// app-wide panel when `window` is none.
    Panel {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        window: Option<String>,
        kind: String,
    },
    Sheet {
        window: String,
    },
    /// Settings, alerts, anything that is not over a cmux window.
    Other {
        #[serde(rename = "_0")]
        name: String,
    },
}

impl KeyWindow {
    fn describe(&self) -> String {
        match self {
            KeyWindow::None {} => "none".into(),
            KeyWindow::Window { id } => format!("window({id:?})"),
            KeyWindow::ChildPage { window } => format!("childPage(window: {window:?})"),
            KeyWindow::Panel { window, kind } => match window {
                Some(window) => format!("panel(window: Optional({window:?}), kind: {kind:?})"),
                None => format!("panel(window: nil, kind: {kind:?})"),
            },
            KeyWindow::Sheet { window } => format!("sheet(window: {window:?})"),
            KeyWindow::Other { name } => format!("other({name:?})"),
        }
    }
}

fn no_responder() -> Responder {
    Responder::WindowOrNone {}
}

/// One window's focus model next to what the platform shows for it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservedWindow {
    pub id: String,
    pub model: Model,
    /// The first responder the platform reports, classified.
    #[serde(default = "no_responder")]
    pub responder: Responder,
    /// Class name of the first responder, for reports.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub responder_class: Option<String>,
    #[serde(default)]
    pub is_key: bool,
    /// The layout's focused pane.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_focus: Option<String>,
    /// Tabs of this window whose Ghostty surface has focus.
    #[serde(default)]
    pub ghostty_focused: Vec<String>,
    /// The page the applier gave Chromium focus to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub child_page: Option<String>,
    /// The tab each pane shows right now.
    #[serde(default)]
    pub presented: HashMap<String, String>,
    /// Tabs whose page lives in a child window (Chromium).
    #[serde(default)]
    pub child_window_tabs: Vec<String>,
    /// A sheet is attached to the window.
    #[serde(default)]
    pub has_sheet: bool,
    /// A top page (History, Settings, the App Store) covers the workspace:
    /// the model still names the parked workspace's pane, which nothing
    /// presents. Absent in old journals.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_page: Option<bool>,
}

/// A snapshot of the combined input state: each window's focus model next
/// to what the platform shows (input-spec.md section 2).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Observation {
    pub windows: Vec<ObservedWindow>,
    pub key_window: KeyWindow,
    /// The palette is open (the registry context).
    #[serde(default)]
    pub palette_open: bool,
    /// The window that publishes the registry context.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_window: Option<String>,
    /// The published context bits.
    #[serde(default)]
    pub context: Context,
}

impl Observation {
    pub fn window(&self, id: &str) -> Option<&ObservedWindow> {
        self.windows.iter().find(|w| w.id == id)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorldResult {
    pub violations: Vec<Violation>,
    /// Windows skipped because content was still being presented.
    pub unsettled: Vec<String>,
}

/// Every model and world check over one observation. Valid only once
/// effects and presentation settled; a window whose focused pane does not
/// present the targeted tab yet is reported as unsettled and its content
/// checks are skipped.
pub fn world(observation: &Observation) -> WorldResult {
    let mut result = WorldResult::default();
    for window in &observation.windows {
        result.violations.extend(model(&window.model, Some(&window.id)));
        // Under a top page the parked workspace presents nothing; its
        // content checks wait for the page to hide.
        if window.top_page == Some(true) {
            continue;
        }
        if is_settled(window) {
            result.violations.extend(content(window));
        } else {
            result.unsettled.push(window.id.clone());
        }
    }
    result.violations.extend(key_window(observation));
    result.violations.extend(overlays(observation));
    result.violations.extend(context(observation));
    result
}

/// The focused pane shows the tab the model targets, and the focus is not on
/// its way to another tab (a creation's new tab not shown yet: the page the
/// person left gives up the keys meanwhile, P0 INVERSE-KEY).
pub fn is_settled(window: &ObservedWindow) -> bool {
    if window.model.awaits_other_tab() {
        return false;
    }
    let underlying = &window.model.underlying;
    let (Some(pane), Some(tab)) = (underlying.pane(), underlying.tab()) else { return true };
    window.presented.get(pane).map(String::as_str) == Some(tab)
}

/// The responder's name in reports.
pub fn describe_responder(responder: &Responder) -> String {
    match responder {
        Responder::Content { pane } => format!("content:{pane}"),
        Responder::AddressBar { pane } => format!("addressBar:{pane}"),
        Responder::FindBar { pane } => format!("findBar:{pane}"),
        Responder::DevTools { pane } => format!("devTools:{pane}"),
        Responder::Sidebar {} => "sidebar".into(),
        Responder::SidebarField {} => "sidebarField".into(),
        Responder::TextField {} => "textField".into(),
        Responder::WindowOrNone {} => "windowOrNone".into(),
    }
}

/// The pane a pane-scoped responder is in.
pub fn responder_pane(responder: &Responder) -> Option<&str> {
    match responder {
        Responder::Content { pane }
        | Responder::AddressBar { pane }
        | Responder::FindBar { pane }
        | Responder::DevTools { pane } => Some(pane),
        _ => None,
    }
}

/// The responder the platform should report for `resolved` (W1; the app's
/// `debug.focus` uses the same table). `child_page` names the tab whose
/// Chromium page window has the keys. None when nothing is expected.
pub fn expected_responder(resolved: &Resolved, child_page: Option<&str>) -> Option<Responder> {
    let content = |pane: &str| Responder::Content { pane: pane.to_owned() };
    match resolved {
        Resolved::Terminal { pane, .. } | Resolved::Conversation { pane, .. } => {
            Some(content(pane))
        }
        // A Chromium page has the keys in its own window; this window keeps
        // no responder.
        Resolved::BrowserPage { pane, .. }
        | Resolved::Page { pane, .. }
        | Resolved::AgentPage { pane, .. } => Some(match child_page {
            None => content(pane),
            Some(_) => Responder::WindowOrNone {},
        }),
        Resolved::AddressBar { pane, .. } => Some(Responder::AddressBar { pane: pane.clone() }),
        Resolved::FindBar { pane, .. } => Some(Responder::FindBar { pane: pane.clone() }),
        // A docked DevTools has the keys in its own child window, like a page.
        Resolved::DevTools { .. } => Some(Responder::WindowOrNone {}),
        Resolved::Sidebar {} => Some(Responder::Sidebar {}),
        Resolved::SidebarField {} => Some(Responder::SidebarField {}),
        Resolved::TextField {} => Some(Responder::TextField {}),
        Resolved::EmptyPane { .. } | Resolved::Overlay { .. } | Resolved::None {} => None,
    }
}

/// W1-W4 and W8 for one settled window.
fn content(window: &ObservedWindow) -> Vec<Violation> {
    let mut out = Vec::new();
    let id = Some(window.id.as_str());
    let mut fail = |invariant, detail| out.push(violation(invariant, id, detail));
    let model = &window.model;
    if let Some(pane) = model.pane.as_deref()
        && window.layout_focus.as_deref() != Some(pane)
    {
        fail(
            Invariant::LayoutMatches,
            format!("layout {} != model {pane}", or_nil(window.layout_focus.as_deref())),
        );
    }
    for pane in &model.topology.panes {
        let Some(shown) = window.presented.get(&pane.id) else { continue };
        if let Some(selected) = pane.selected.as_deref()
            && pane.tab(selected).is_none()
        {
            fail(
                Invariant::PresentedMatchesSelection,
                format!("pane {} selects {selected}, which it does not hold", pane.id),
            );
        } else if Some(shown) != pane.selected.as_ref() {
            fail(
                Invariant::PresentedMatchesSelection,
                format!(
                    "pane {} shows {shown} but selects {}",
                    pane.id,
                    or_nil(pane.selected.as_deref())
                ),
            );
        }
    }
    let resolved = &model.resolved;
    // A Chromium browser tab or a cmux page in Chromium: its page window has
    // the keys.
    let child_page = match resolved {
        Resolved::BrowserPage { tab, .. }
        | Resolved::Page { tab, .. }
        | Resolved::AgentPage { tab, .. }
            if window.child_window_tabs.contains(tab) =>
        {
            Some(tab.as_str())
        }
        _ => None,
    };
    if let Some(expected) = expected_responder(resolved, child_page)
        && expected != window.responder
    {
        fail(
            Invariant::ResponderMatches,
            format!(
                "appkit {} ({}) != model {}",
                describe_responder(&window.responder),
                or_nil(window.responder_class.as_deref()),
                resolved.kind()
            ),
        );
    }
    if matches!(resolved, Resolved::EmptyPane { .. }) && responder_pane(&window.responder).is_some()
    {
        fail(
            Invariant::ResponderMatches,
            format!(
                "appkit {} inside a pane while the focused pane is empty",
                describe_responder(&window.responder)
            ),
        );
    }
    let key_terminal = match resolved {
        Resolved::Terminal { tab, .. } if window.is_key => Some(tab),
        _ => None,
    };
    if let Some(tab) = key_terminal {
        if window.ghostty_focused != [tab.as_str()] {
            fail(
                Invariant::GhosttyMatches,
                format!("ghostty {:?} != [{tab}]", window.ghostty_focused),
            );
        }
    } else if !window.ghostty_focused.is_empty() {
        let key = if window.is_key { "" } else { ", window not key" };
        fail(
            Invariant::GhosttyMatches,
            format!("ghostty {:?} while model is {}{key}", window.ghostty_focused, resolved.kind()),
        );
    }
    // Under an overlay the applier leaves page focus alone (keys go to the
    // overlay); closing it re-applies.
    if model.overlays.is_empty() && window.child_page.as_deref() != child_page {
        fail(
            Invariant::ChromiumMatches,
            format!(
                "chromium page {} != model {}",
                or_nil(window.child_page.as_deref()),
                or_nil(child_page)
            ),
        );
    }
    out
}

/// W5: exactly the window the platform made key believes it has the
/// keyboard, and whatever is key belongs to that window's target.
fn key_window(observation: &Observation) -> Vec<Violation> {
    let mut out = Vec::new();
    let mut fail = |window: Option<&str>, detail| {
        out.push(violation(Invariant::KeyWindowOwned, window, detail));
    };
    let owner = match &observation.key_window {
        KeyWindow::Window { id } => Some(id.as_str()),
        _ => None,
    };
    for window in &observation.windows {
        if window.model.window_key != (Some(window.id.as_str()) == owner) {
            fail(
                Some(&window.id),
                format!(
                    "model windowKey {} but AppKit key window is {}",
                    window.model.window_key,
                    observation.key_window.describe()
                ),
            );
        }
    }
    match &observation.key_window {
        KeyWindow::ChildPage { window: id } => {
            if let Some(window) = observation.window(id) {
                let underlying = &window.model.underlying;
                // The page's window, or its docked DevTools window.
                let is_child_page = match underlying {
                    Resolved::BrowserPage { tab, .. }
                    | Resolved::DevTools { tab, .. }
                    | Resolved::Page { tab, .. }
                    | Resolved::AgentPage { tab, .. } => window.child_window_tabs.contains(tab),
                    _ => false,
                };
                if !is_child_page && window.model.overlays.is_empty() {
                    fail(
                        Some(id),
                        format!(
                            "a Chromium page window has the keys while the model targets {}",
                            underlying.kind()
                        ),
                    );
                }
            }
        }
        KeyWindow::Panel { window: Some(id), kind } => {
            if observation.window(id).is_some_and(|w| w.model.overlays.is_empty()) {
                fail(
                    Some(id),
                    format!("panel {kind} has the keys but the window's overlay stack is empty"),
                );
            }
        }
        KeyWindow::Panel { window: None, kind } => {
            if !observation.windows.iter().any(|w| !w.model.overlays.is_empty()) {
                fail(None, format!("panel {kind} has the keys but no window has an overlay"));
            }
        }
        KeyWindow::Sheet { window: id } => {
            if observation.window(id).is_some_and(|w| !w.model.overlays.contains(&Overlay::Sheet)) {
                fail(Some(id), "a sheet has the keys but the window has no sheet overlay".into());
            }
        }
        KeyWindow::None {} | KeyWindow::Window { .. } | KeyWindow::Other { .. } => {}
    }
    out
}

/// W6: the palette and sheets agree with the overlay stacks.
fn overlays(observation: &Observation) -> Vec<Violation> {
    let mut out = Vec::new();
    let palettes: Vec<&String> = observation
        .windows
        .iter()
        .filter(|w| w.model.overlays.contains(&Overlay::Palette))
        .map(|w| &w.id)
        .collect();
    let wrong = if observation.palette_open { palettes.len() != 1 } else { !palettes.is_empty() };
    if wrong {
        out.push(violation(
            Invariant::OverlaysMatch,
            None,
            format!("palette open {}, overlay in {palettes:?}", observation.palette_open),
        ));
    }
    for window in &observation.windows {
        if window.has_sheet != window.model.overlays.contains(&Overlay::Sheet) {
            out.push(violation(
                Invariant::OverlaysMatch,
                Some(&window.id),
                format!(
                    "sheet attached {}, overlay {}",
                    window.has_sheet,
                    overlays_name(&window.model.overlays)
                ),
            ));
        }
    }
    out
}

/// W7: menus, the palette and the registry context act on the window that
/// owns the keyboard (itself, its Chromium page window, its panel or sheet),
/// so that window is the active one and publishes.
fn context(observation: &Observation) -> Vec<Violation> {
    let mut out = Vec::new();
    let owner = match &observation.key_window {
        KeyWindow::Window { id }
        | KeyWindow::ChildPage { window: id }
        | KeyWindow::Sheet { window: id } => Some(id.as_str()),
        KeyWindow::Panel { window, .. } => window.as_deref(),
        KeyWindow::None {} | KeyWindow::Other { .. } => None,
    };
    if let Some(owner) = owner
        && observation.active_window.as_deref() != Some(owner)
    {
        out.push(violation(
            Invariant::ContextMatches,
            Some(owner),
            format!(
                "active window {} while the keys go to {owner}",
                or_nil(observation.active_window.as_deref())
            ),
        ));
    }
    if let Some(publisher) =
        owner.or(observation.active_window.as_deref()).and_then(|id| observation.window(id))
        && publisher.model.context != observation.context
    {
        out.push(violation(
            Invariant::ContextMatches,
            Some(&publisher.id),
            format!(
                "published {} != model {}",
                context_name(observation.context),
                context_name(publisher.model.context)
            ),
        ));
    }
    out
}
