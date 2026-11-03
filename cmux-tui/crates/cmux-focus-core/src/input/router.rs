//! The router: every window's focus, the sinks' facts, the lanes, and the one
//! decision per key, made in the key's own call (DESIGN.md section 4.4).

use super::key::{Binding, KeyPhase, KeyRecord, Tier, WindowRole};
use super::sink::{FieldKind, Sink, TerminalKey};
use super::{
    ConsumeReason, DropReason, GoneReason, InputEffect, InputEvent, InputId, Via, WaitReason,
};
use crate::event::{FocusEffect, FocusEvent};
use crate::reducer;
use crate::state::{Expectation, ExpectationKey, FocusState, Resolved, Target};
use crate::topology::Kind;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

/// The most keys one sink's lane holds; a key past it is refused at key time.
pub const LANE_LIMIT: usize = 4096;

/// The actions DevTools runs itself before its frontend sees the key; they run
/// from a page, its address bar, its find bar and DevTools (the app's
/// `KeyRouter.devToolsActions`).
const DEV_TOOLS_ACTIONS: [&str; 3] =
    ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement"];

/// Page actions a browser's own chrome runs from its address bar and find bar
/// (R88; the app's `KeyRouter.browserChromeActions`).
const BROWSER_CHROME_ACTIONS: [&str; 7] = [
    "browserBack",
    "browserForward",
    "browserReload",
    "browserHardReload",
    "browserShowHistory",
    "browser.copyURL",
    "browser.findPrevious",
];

/// The system actions browser focus mode keeps from the page (the app's
/// `KeyRouter.focusModeKeptActions`).
const FOCUS_MODE_KEPT_ACTIONS: [&str; 2] = ["toggleBrowserFocusMode", "quit"];

/// A tab of a window's topology, as the router needs it.
struct TabInfo {
    kind: Kind,
    terminal: Option<Arc<str>>,
}

struct WindowInput {
    focus: FocusState,
    /// The tabs of the window's topology, by id (the first tab with an id).
    tabs: HashMap<Arc<str>, TabInfo>,
    /// The tab showing each daemon surface (the first one, in layout order).
    surfaces: HashMap<Arc<str>, Arc<str>>,
}

impl WindowInput {
    fn new() -> WindowInput {
        let mut focus = FocusState::default();
        focus.derive();
        WindowInput { focus, tabs: HashMap::new(), surfaces: HashMap::new() }
    }

    /// Rebuilds the tab index from the focus topology.
    fn reindex(&mut self) {
        self.tabs.clear();
        self.surfaces.clear();
        for pane in &self.focus.topology.panes {
            for tab in &pane.tabs {
                let id: Arc<str> = Arc::from(tab.id.as_str());
                if let Some(surface) = tab.surface.as_deref() {
                    self.surfaces.entry(Arc::from(surface)).or_insert_with(|| id.clone());
                }
                self.tabs.entry(id).or_insert_with(|| TabInfo {
                    kind: tab.kind,
                    terminal: tab.terminal.as_deref().map(Arc::from),
                });
            }
        }
    }

    /// The tab showing daemon surface `surface`.
    fn tab_of_surface(&self, surface: &str) -> Option<(&Arc<str>, &TabInfo)> {
        self.surfaces.get(surface).and_then(|tab| self.tabs.get_key_value(tab))
    }
}

/// The content sink of a tab: its terminal, or its content.
fn content_sink(tab: &Arc<str>, info: &TabInfo) -> Option<Sink> {
    match info.kind {
        Kind::Terminal => Some(Sink::Terminal(match &info.terminal {
            Some(terminal) => TerminalKey::Host(terminal.clone()),
            None => TerminalKey::Tab(tab.clone()),
        })),
        Kind::Browser | Kind::Agent | Kind::Page | Kind::Conversation => {
            Some(Sink::Content(tab.clone()))
        }
        Kind::Other => None,
    }
}

/// Where a press went, so its repeats and release follow it.
#[derive(Clone)]
enum Press {
    Sink(Sink),
    Platform,
    /// It ran an action, was consumed or dropped.
    Consumed,
}

/// One waiting entry of a lane, in typing order.
enum LaneEntry {
    /// A key; `text`: typed text (an input method may compose it).
    Key { id: InputId, text: bool },
    /// An action that edits this sink's input, typed after the keys before
    /// it (a Paste behind typing).
    Run { id: InputId, action: Arc<str>, tab: Option<Arc<str>> },
}

impl LaneEntry {
    fn id(&self) -> InputId {
        match self {
            LaneEntry::Key { id, .. } | LaneEntry::Run { id, .. } => *id,
        }
    }
}

/// The sink a key typed now is aimed at, and the tab it is for.
struct Aim {
    sink: Option<Sink>,
    tab: Option<Arc<str>>,
}

/// What the platform reported about the sinks.
#[derive(Default)]
struct Facts {
    /// What AppKit's dispatch of a key typed now reaches.
    reaches: Option<Sink>,
    /// Sinks that need readiness and reported it.
    ready: HashSet<Sink>,
    /// Sinks that ended, with why. One entry per ended sink of the session.
    gone: HashMap<Sink, GoneReason>,
    /// The input source composes text.
    composes: bool,
}

impl Facts {
    /// How a key reaches `sink` now (`reaches`: what AppKit's dispatch
    /// reaches), or why it waits.
    fn deliverable(
        &self,
        sink: &Sink,
        reaches: Option<&Sink>,
        text: bool,
    ) -> Result<Via, WaitReason> {
        if sink.needs_ready() && !self.ready.contains(sink) {
            return Err(WaitReason::NotReady);
        }
        if reaches == Some(sink) {
            return Ok(Via::Responder);
        }
        if !sink.has_direct_path() || (text && self.composes) {
            return Err(WaitReason::AwaitsResponder);
        }
        Ok(Via::Direct)
    }
}

/// The one input router (module docs).
pub struct InputRouter {
    windows: HashMap<Arc<str>, WindowInput>,
    /// Creations' sinks by the key their focus expectation waits for, until a
    /// window's topology shows them or they fail.
    creations: HashMap<ExpectationKey, Sink>,
    facts: Facts,
    lanes: HashMap<Sink, VecDeque<LaneEntry>>,
    presses: HashMap<(Arc<str>, u16), Press>,
    next_id: u64,
    effects: Vec<InputEffect>,
    focus_effects: Vec<FocusEffect>,
}

impl Default for InputRouter {
    fn default() -> InputRouter {
        InputRouter::new()
    }
}

impl InputRouter {
    pub fn new() -> InputRouter {
        InputRouter {
            windows: HashMap::new(),
            creations: HashMap::new(),
            facts: Facts::default(),
            lanes: HashMap::new(),
            presses: HashMap::new(),
            next_id: 1,
            effects: Vec::new(),
            focus_effects: Vec::new(),
        }
    }

    /// Handles one event; its effects, in the order the platform applies
    /// them, are valid until the next call.
    pub fn handle(&mut self, event: &InputEvent) -> &[InputEffect] {
        self.effects.clear();
        if let InputEvent::Key(key) = event {
            self.key(key);
        } else {
            self.apply(event);
            self.drop_left_lanes();
            self.drain();
        }
        &self.effects
    }

    /// `window`'s focus; none for a window that is not open.
    pub fn focus(&self, window: &str) -> Option<&FocusState> {
        self.windows.get(window).map(|w| &w.focus)
    }

    /// The sink a text key typed now in `window` is aimed at.
    pub fn aim(&self, window: &str) -> Option<Sink> {
        let (id, input) = self.windows.get_key_value(window)?;
        self.aim_in(id, input).sink
    }

    /// The keys waiting in each lane.
    pub fn waiting(&self) -> impl Iterator<Item = (&Sink, usize)> {
        self.lanes.iter().map(|(sink, lane)| (sink, lane.len()))
    }

    // MARK: Events

    fn apply(&mut self, event: &InputEvent) {
        match event {
            InputEvent::Key(_) => {}
            InputEvent::Focus { window, event } => self.focus_event(window, event),
            InputEvent::WindowOpened { window } => {
                self.windows.entry(window.clone()).or_insert_with(WindowInput::new);
            }
            InputEvent::WindowClosed { window } => self.close_window(window),
            InputEvent::Dispatch { reaches } => self.facts.reaches.clone_from(reaches),
            InputEvent::Ready { sink } => {
                if sink.needs_ready() && !self.facts.gone.contains_key(sink) {
                    self.facts.ready.insert(sink.clone());
                }
            }
            InputEvent::Pending { sink } => {
                self.facts.ready.remove(sink);
            }
            InputEvent::Gone { sink, reason } => self.end(sink, *reason),
            InputEvent::Creation { key, sink } => {
                if !self.facts.gone.contains_key(sink) {
                    self.creations.insert(key.clone(), sink.clone());
                }
            }
            InputEvent::CreationFailed { key } => {
                if let Some(sink) = self.creations.remove(key) {
                    self.end(&sink, GoneReason::CreationFailed);
                }
            }
            InputEvent::InputSource { composes } => self.facts.composes = *composes,
        }
    }

    fn focus_event(&mut self, window: &Arc<str>, event: &FocusEvent) {
        let Some(input) = self.windows.get_mut(window) else { return };
        reducer::reduce(&mut input.focus, event, &mut self.focus_effects);
        for effect in self.focus_effects.drain(..) {
            self.effects.push(InputEffect::Focus { window: window.clone(), effect });
        }
        if matches!(event, FocusEvent::Topology { .. }) {
            input.reindex();
            self.forget_shown_creations();
        }
    }

    fn close_window(&mut self, window: &Arc<str>) {
        if self.windows.remove(window).is_none() {
            return;
        }
        self.presses.retain(|(pressed, _), _| pressed != window);
        let closed: Vec<Sink> =
            self.lanes.keys().filter(|sink| sink.window() == Some(window)).cloned().collect();
        self.drop_lanes(closed, DropReason::WindowClosed);
    }

    /// `sink` ended: its waiting keys are dropped, and so is every key aimed
    /// at it later (a sink never comes back: terminal and tab ids are not
    /// reused).
    fn end(&mut self, sink: &Sink, reason: GoneReason) {
        self.facts.ready.remove(sink);
        self.creations.retain(|_, created| *created != *sink);
        self.facts.gone.insert(sink.clone(), reason);
        self.drop_lanes(vec![sink.clone()], DropReason::SinkGone(reason));
    }

    /// A creation a window's topology shows now is known from that topology.
    fn forget_shown_creations(&mut self) {
        let windows = &self.windows;
        self.creations.retain(|key, _| {
            !windows.values().any(|window| match key {
                ExpectationKey::Tab { id } => window.tabs.contains_key(id.as_str()),
                ExpectationKey::Surface { id } => window.tab_of_surface(id).is_some(),
            })
        });
    }

    // MARK: Keys

    fn next_id(&mut self) -> InputId {
        let id = InputId(self.next_id);
        self.next_id = self.next_id.wrapping_add(1);
        id
    }

    fn key(&mut self, key: &KeyRecord) {
        let id = self.next_id();
        // The key's own moment says what AppKit's dispatch reaches: keys that
        // waited for that go first, in typing order.
        self.facts.reaches.clone_from(&key.reaches);
        self.drain();
        let slot = (key.window.clone(), key.code);
        match key.phase {
            KeyPhase::Up => match self.presses.remove(&slot) {
                Some(Press::Sink(sink)) => self.release_to(id, key, sink),
                Some(Press::Consumed) => self.push(InputEffect::Consumed {
                    id,
                    reason: ConsumeReason::FollowsConsumedPress,
                }),
                Some(Press::Platform) | None => self.push(InputEffect::Platform { id }),
            },
            KeyPhase::Repeat => match self.presses.get(&slot).cloned() {
                Some(Press::Sink(sink)) => self.to_sink(id, key, sink),
                Some(Press::Platform) => self.push(InputEffect::Platform { id }),
                // A repeat of a press that ran its binding runs it again.
                Some(Press::Consumed) | None => {
                    let press = self.decide(id, key);
                    self.presses.insert(slot, press);
                }
            },
            KeyPhase::Down => {
                let press = self.decide(id, key);
                self.presses.insert(slot, press);
            }
        }
    }

    /// The route of a press, from the state of its own call.
    fn decide(&mut self, id: InputId, key: &KeyRecord) -> Press {
        if key.role != WindowRole::Main {
            self.push(InputEffect::Platform { id });
            return Press::Platform;
        }
        let Some((window_id, window)) = self.windows.get_key_value(&key.window) else {
            self.push(InputEffect::Platform { id });
            return Press::Platform;
        };
        // An input method composing gets every key but a Command chord, where it composes
        // (behind keys that wait for that view).
        if key.composing && !key.modifiers.command {
            return match key.reaches.clone() {
                Some(sink) => {
                    self.to_sink(id, key, sink.clone());
                    Press::Sink(sink)
                }
                None => {
                    self.push(InputEffect::Platform { id });
                    Press::Platform
                }
            };
        }
        let aim = self.aim_in(window_id, window);
        if let Some(binding) = &key.binding {
            let focus = &window.focus;
            // A focused terminal runs its own Ghostty keybinds (in copy mode the
            // routed action runs), and a Ghostty keybind never runs a content
            // action from elsewhere.
            let to_view = binding.ghostty
                && ((matches!(focus.derived.resolved, Resolved::Terminal { .. })
                    && !key.terminal_copy_mode)
                    || binding.tier == Tier::Content);
            if !to_view && allows(binding, focus) {
                self.run(id, binding, aim);
                return Press::Consumed;
            }
        }
        match aim.sink {
            Some(sink) => {
                self.to_sink(id, key, sink.clone());
                Press::Sink(sink)
            }
            None => {
                self.push(InputEffect::Consumed { id, reason: ConsumeReason::NoTarget });
                Press::Consumed
            }
        }
    }

    /// Runs `binding` for key `id` now, or, when it edits an input whose lane
    /// holds keys typed before it, after them.
    fn run(&mut self, id: InputId, binding: &Binding, aim: Aim) {
        let action = binding.action.clone();
        if binding.edits_input
            && let Some(sink) = aim.sink
            && self.lanes.get(&sink).is_some_and(|lane| !lane.is_empty())
        {
            let entry = LaneEntry::Run { id, action, tab: aim.tab };
            self.enqueue(sink, entry, WaitReason::BehindQueued);
            return;
        }
        self.push(InputEffect::Run { id, action, tab: aim.tab });
    }

    /// Key `id` (a press or a repeat) goes to `sink`, or waits in its lane.
    fn to_sink(&mut self, id: InputId, key: &KeyRecord, sink: Sink) {
        if let Some(reason) = self.facts.gone.get(&sink) {
            let reason = DropReason::SinkGone(*reason);
            self.push(InputEffect::Dropped { id, reason });
            return;
        }
        let text = key.is_text();
        if self.lanes.get(&sink).is_some_and(|lane| !lane.is_empty()) {
            self.enqueue(sink, LaneEntry::Key { id, text }, WaitReason::BehindQueued);
            return;
        }
        match self.facts.deliverable(&sink, key.reaches.as_ref(), text) {
            Ok(via) => self.push(InputEffect::Deliver { id, sink, via }),
            Err(reason) => self.enqueue(sink, LaneEntry::Key { id, text }, reason),
        }
    }

    /// The release `id` of a press that went to `sink`: after its press when
    /// that still waits, else to the sink when it can take it now; a sink
    /// that cannot take it now needs no release.
    fn release_to(&mut self, id: InputId, key: &KeyRecord, sink: Sink) {
        if let Some(reason) = self.facts.gone.get(&sink) {
            let reason = DropReason::SinkGone(*reason);
            self.push(InputEffect::Dropped { id, reason });
            return;
        }
        if self.lanes.get(&sink).is_some_and(|lane| !lane.is_empty()) {
            self.enqueue(sink, LaneEntry::Key { id, text: false }, WaitReason::BehindQueued);
            return;
        }
        match self.facts.deliverable(&sink, key.reaches.as_ref(), false) {
            Ok(via) => self.push(InputEffect::Deliver { id, sink, via }),
            Err(_) => {
                self.push(InputEffect::Consumed { id, reason: ConsumeReason::ReleaseNotTaken });
            }
        }
    }

    fn enqueue(&mut self, sink: Sink, entry: LaneEntry, reason: WaitReason) {
        let id = entry.id();
        let lane = self.lanes.entry(sink.clone()).or_default();
        if lane.len() >= LANE_LIMIT {
            self.push(InputEffect::Dropped { id, reason: DropReason::LaneFull });
            return;
        }
        lane.push_back(entry);
        self.push(InputEffect::Queued { id, sink, reason });
    }

    fn push(&mut self, effect: InputEffect) {
        self.effects.push(effect);
    }

    // MARK: Aim

    /// The sink a key typed now in `window` is aimed at: an open overlay, else
    /// the tab the focus is on its way to (a creation's, a drop's), else the
    /// focused target.
    fn aim_in(&self, window_id: &Arc<str>, window: &WindowInput) -> Aim {
        let focus = &window.focus;
        if let Some(top) = focus.overlays.last() {
            return Aim {
                sink: Some(Sink::Overlay { window: window_id.clone(), overlay: *top }),
                tab: None,
            };
        }
        if let Some(expectation) = &focus.expectation
            && expectation.generation == focus.generation
            && let Some(aim) = self.expected(window_id, expectation)
        {
            return aim;
        }
        self.resolved_aim(window_id, window, &focus.derived.resolved)
    }

    /// The sink of the tab an expectation waits for: in any window's
    /// topology (a tab moving between windows), else its creation's.
    fn expected(&self, window_id: &Arc<str>, expectation: &Expectation) -> Option<Aim> {
        let shown = self.windows.get(window_id).into_iter().chain(self.windows.values()).find_map(
            |window| match &expectation.key {
                ExpectationKey::Tab { id } => window.tabs.get_key_value(id.as_str()),
                ExpectationKey::Surface { id } => window.tab_of_surface(id),
            },
        );
        let (tab, content) = match shown {
            Some((tab, info)) => (Some(tab.clone()), content_sink(tab, info)?),
            None => {
                let sink = self.creations.get(&expectation.key)?.clone();
                let tab = match &expectation.key {
                    ExpectationKey::Tab { id } => Some(Arc::<str>::from(id.as_str())),
                    ExpectationKey::Surface { .. } => None,
                };
                (tab, sink)
            }
        };
        let field = |kind| Sink::Field { window: window_id.clone(), field: kind };
        // A chrome target only on a tab with content of its own (a browser tab).
        let chrome = matches!(content, Sink::Content(_));
        let sink = match (expectation.target, tab.as_ref()) {
            (Target::AddressBar {}, Some(tab)) if chrome => {
                field(FieldKind::AddressBar { tab: tab.clone() })
            }
            (Target::FindBar {}, Some(tab)) if chrome => {
                field(FieldKind::FindBar { tab: tab.clone() })
            }
            (Target::DevTools {}, Some(tab)) if chrome => Sink::DevTools(tab.clone()),
            (Target::Sidebar { .. }, _) => field(FieldKind::Sidebar),
            (Target::SidebarField {}, _) => field(FieldKind::SidebarField),
            (Target::TextField {}, _) => field(FieldKind::TextField),
            _ => content,
        };
        Some(Aim { sink: Some(sink), tab })
    }

    fn resolved_aim(&self, window_id: &Arc<str>, window: &WindowInput, resolved: &Resolved) -> Aim {
        let tab = resolved.tab().map(|tab| match window.tabs.get_key_value(tab) {
            Some((shared, _)) => shared.clone(),
            None => Arc::<str>::from(tab),
        });
        let field = |kind| Some(Sink::Field { window: window_id.clone(), field: kind });
        let sink = match (resolved, &tab) {
            (Resolved::Terminal { .. }, Some(tab)) => match window.tabs.get(tab) {
                Some(info) => content_sink(tab, info),
                None => Some(Sink::Terminal(TerminalKey::Tab(tab.clone()))),
            },
            (
                Resolved::BrowserPage { .. }
                | Resolved::AgentPage { .. }
                | Resolved::Page { .. }
                | Resolved::Conversation { .. },
                Some(tab),
            ) => Some(Sink::Content(tab.clone())),
            (Resolved::AddressBar { .. }, Some(tab)) => {
                field(FieldKind::AddressBar { tab: tab.clone() })
            }
            (Resolved::FindBar { .. }, Some(tab)) => field(FieldKind::FindBar { tab: tab.clone() }),
            (Resolved::DevTools { .. }, Some(tab)) => Some(Sink::DevTools(tab.clone())),
            (Resolved::Sidebar {}, _) => field(FieldKind::Sidebar),
            (Resolved::SidebarField {}, _) => field(FieldKind::SidebarField),
            (Resolved::TextField {}, _) => field(FieldKind::TextField),
            (Resolved::Overlay { overlay }, _) => {
                Some(Sink::Overlay { window: window_id.clone(), overlay: *overlay })
            }
            _ => None,
        };
        Aim { sink, tab }
    }

    // MARK: Lanes

    /// A field's or an overlay's lane whose window's focus left it: its keys
    /// can never reach it (the person moved on), so they are dropped.
    fn drop_left_lanes(&mut self) {
        let left: Vec<Sink> = self
            .lanes
            .keys()
            .filter(|sink| match sink.window() {
                Some(window) => match self.windows.get_key_value(window) {
                    Some((id, input)) => self.aim_in(id, input).sink.as_ref() != Some(*sink),
                    None => true,
                },
                None => false,
            })
            .cloned()
            .collect();
        self.drop_lanes(left, DropReason::TargetLeft);
    }

    /// Drops every entry of the lanes of `sinks`, in typing order.
    fn drop_lanes(&mut self, sinks: Vec<Sink>, reason: DropReason) {
        let mut dropped: Vec<InputId> = Vec::new();
        for sink in sinks {
            if let Some(lane) = self.lanes.remove(&sink) {
                dropped.extend(lane.iter().map(LaneEntry::id));
            }
        }
        dropped.sort_unstable();
        for id in dropped {
            self.push(InputEffect::Dropped { id, reason });
        }
    }

    /// Delivers every waiting entry whose sink can take it now, oldest first:
    /// a lane's entries in order, each lane up to its first entry that must
    /// still wait.
    fn drain(&mut self) {
        loop {
            // The oldest lane front that can go now, and how (none for an action).
            let mut next: Option<(InputId, &Sink, Option<Via>)> = None;
            for (sink, lane) in &self.lanes {
                let Some(front) = lane.front() else { continue };
                let takes = match front {
                    LaneEntry::Key { text, .. } => self
                        .facts
                        .deliverable(sink, self.facts.reaches.as_ref(), *text)
                        .ok()
                        .map(Some),
                    LaneEntry::Run { .. } => Some(None),
                };
                if let Some(via) = takes
                    && next.as_ref().is_none_or(|(oldest, _, _)| front.id() < *oldest)
                {
                    next = Some((front.id(), sink, via));
                }
            }
            let Some((_, sink, via)) = next else { return };
            let sink = sink.clone();
            let Some(lane) = self.lanes.get_mut(&sink) else { return };
            // The effect is made from the front before it leaves the lane, so no
            // entry is ever taken without its effect.
            let effect = match (lane.front(), via) {
                (Some(LaneEntry::Key { id, .. }), Some(via)) => {
                    InputEffect::Deliver { id: *id, sink: sink.clone(), via }
                }
                (Some(LaneEntry::Run { id, action, tab }), _) => {
                    InputEffect::Run { id: *id, action: action.clone(), tab: tab.clone() }
                }
                (Some(LaneEntry::Key { .. }), None) | (None, _) => return,
            };
            lane.pop_front();
            if lane.is_empty() {
                self.lanes.remove(&sink);
            }
            self.push(effect);
        }
    }
}

/// Whether binding `binding`'s action may take a key from `focus` (its tier
/// rule; plans/cmux-next/focus.md section 5).
fn allows(binding: &Binding, focus: &FocusState) -> bool {
    let mode = focus.derived.browser_focus_mode_active;
    let resolved = &focus.derived.resolved;
    let action: &str = &binding.action;
    if mode && binding.tier == Tier::System {
        return FOCUS_MODE_KEPT_ACTIONS.contains(&action);
    }
    if binding.tier == Tier::Content {
        if DEV_TOOLS_ACTIONS.contains(&action) && is_browser_context(resolved) && !mode {
            return true;
        }
        if BROWSER_CHROME_ACTIONS.contains(&action)
            && matches!(resolved, Resolved::AddressBar { .. } | Resolved::FindBar { .. })
        {
            return true;
        }
    }
    match binding.tier {
        Tier::System => true,
        Tier::Navigation => !mode,
        Tier::Content => {
            !mode && !resolved.is_text_input() && !matches!(resolved, Resolved::DevTools { .. })
        }
    }
}

/// A page, its address bar, its find bar or its DevTools has the keyboard.
fn is_browser_context(resolved: &Resolved) -> bool {
    matches!(
        resolved,
        Resolved::BrowserPage { .. }
            | Resolved::AddressBar { .. }
            | Resolved::FindBar { .. }
            | Resolved::DevTools { .. }
    )
}
