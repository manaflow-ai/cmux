//! The reference model the fuzz checks the router against: the same rules
//! (DESIGN.md sections 4.4-4.8) written as plainly as possible, with none of
//! the router's structure. It keeps every key in one list with its state,
//! finds tabs by scanning every window's topology, and after every event
//! settles the whole world from scratch: what ended, what left, and what can
//! go now, oldest key first.

use cmux_focus_core::event::{FocusEffect, FocusEvent};
use cmux_focus_core::input::{
    ConsumeReason, DropReason, FieldKind, GoneReason, InputEvent, KeyPhase, KeyRecord, LANE_LIMIT,
    Sink, TerminalKey, Tier, Via, WaitReason, WindowRole,
};
use cmux_focus_core::reducer;
use cmux_focus_core::state::{ExpectationKey, FocusState, Resolved, Target};
use cmux_focus_core::topology::{Kind, Tab};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// How a key ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ending {
    Delivered(Sink, Via),
    Ran,
    Consumed(ConsumeReason),
    Dropped(DropReason),
    Platform,
}

/// A key's state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    Waiting(Sink),
    Ended(Ending),
}

struct Key {
    id: u64,
    /// The sink it waits for while waiting.
    sink: Option<Sink>,
    text: bool,
    /// A waiting action (a Paste behind typing), not a key for the sink.
    action: bool,
    state: State,
}

#[derive(Clone)]
enum Pressed {
    Sink(Sink),
    Platform,
    Consumed,
}

pub struct Model {
    windows: Vec<(String, FocusState)>,
    reaches: Option<Sink>,
    ready: HashSet<Sink>,
    gone: HashMap<Sink, GoneReason>,
    composes: bool,
    creations: Vec<(ExpectationKey, Sink)>,
    keys: Vec<Key>,
    pressed: HashMap<(String, u16), Pressed>,
    /// Every sink's deliveries, in order.
    pub deliveries: HashMap<Sink, Vec<u64>>,
}

const DEV_TOOLS: [&str; 3] =
    ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement"];
const CHROME: [&str; 7] = [
    "browserBack",
    "browserForward",
    "browserReload",
    "browserHardReload",
    "browserShowHistory",
    "browser.copyURL",
    "browser.findPrevious",
];
const KEPT: [&str; 2] = ["toggleBrowserFocusMode", "quit"];

impl Default for Model {
    fn default() -> Model {
        Model::new()
    }
}

impl Model {
    pub fn new() -> Model {
        Model {
            windows: Vec::new(),
            reaches: None,
            ready: HashSet::new(),
            gone: HashMap::new(),
            composes: false,
            creations: Vec::new(),
            keys: Vec::new(),
            pressed: HashMap::new(),
            deliveries: HashMap::new(),
        }
    }

    /// Every key's state, by id.
    pub fn states(&self) -> HashMap<u64, State> {
        self.keys.iter().map(|key| (key.id, key.state.clone())).collect()
    }

    pub fn focus(&self, window: &str) -> Option<&FocusState> {
        self.windows.iter().find(|(id, _)| id == window).map(|(_, focus)| focus)
    }

    /// The sink a text key typed now in `window` is aimed at.
    pub fn aim(&self, window: &str) -> Option<Sink> {
        self.aim_tab(window).0
    }

    pub fn step(&mut self, event: &InputEvent) {
        match event {
            InputEvent::Key(key) => {
                self.reaches.clone_from(&key.reaches);
                self.settle();
                self.key(key);
                return;
            }
            InputEvent::Focus { window, event } => {
                let mut reduced = false;
                if let Some((_, focus)) = self.windows.iter_mut().find(|(id, _)| **id == **window) {
                    let mut effects: Vec<FocusEffect> = Vec::new();
                    reducer::reduce(focus, event, &mut effects);
                    reduced = true;
                }
                if reduced && matches!(event, FocusEvent::Topology { .. }) {
                    let windows = &self.windows;
                    self.creations.retain(|(key, _)| {
                        !windows.iter().any(|(_, focus)| find_tab(focus, key).is_some())
                    });
                }
            }
            InputEvent::WindowOpened { window } => {
                if !self.windows.iter().any(|(id, _)| **id == **window) {
                    let mut focus = FocusState::default();
                    focus.derive();
                    self.windows.push((window.to_string(), focus));
                }
            }
            InputEvent::WindowClosed { window } => {
                if self.windows.iter().any(|(id, _)| **id == **window) {
                    self.windows.retain(|(id, _)| **id != **window);
                    self.pressed.retain(|(pressed, _), _| **pressed != **window);
                    for key in &mut self.keys {
                        if let State::Waiting(sink) = &key.state
                            && sink.window().is_some_and(|w| **w == **window)
                        {
                            key.state = State::Ended(Ending::Dropped(DropReason::WindowClosed));
                        }
                    }
                }
            }
            InputEvent::Dispatch { reaches } => self.reaches.clone_from(reaches),
            InputEvent::Ready { sink } => {
                if sink.needs_ready() && !self.gone.contains_key(sink) {
                    self.ready.insert(sink.clone());
                }
            }
            InputEvent::Pending { sink } => {
                self.ready.remove(sink);
            }
            InputEvent::Gone { sink, reason } => self.end(sink, *reason),
            InputEvent::Creation { key, sink } => {
                if !self.gone.contains_key(sink) {
                    self.creations.retain(|(k, _)| k != key);
                    self.creations.push((key.clone(), sink.clone()));
                }
            }
            InputEvent::CreationFailed { key } => {
                if let Some(index) = self.creations.iter().position(|(k, _)| k == key) {
                    let (_, sink) = self.creations.remove(index);
                    self.end(&sink, GoneReason::CreationFailed);
                }
            }
            InputEvent::InputSource { composes } => self.composes = *composes,
        }
        // A field or overlay the focus left keeps no key.
        let left: Vec<usize> = self
            .keys
            .iter()
            .enumerate()
            .filter(|(_, key)| match &key.state {
                State::Waiting(sink) => {
                    sink.window().is_some_and(|window| self.aim(window).as_ref() != Some(sink))
                }
                State::Ended(_) => false,
            })
            .map(|(index, _)| index)
            .collect();
        for index in left {
            if let Some(key) = self.keys.get_mut(index) {
                key.state = State::Ended(Ending::Dropped(DropReason::TargetLeft));
            }
        }
        self.settle();
    }

    fn end(&mut self, sink: &Sink, reason: GoneReason) {
        self.ready.remove(sink);
        self.creations.retain(|(_, s)| s != sink);
        self.gone.insert(sink.clone(), reason);
        for key in &mut self.keys {
            if key.state == State::Waiting(sink.clone()) {
                key.state = State::Ended(Ending::Dropped(DropReason::SinkGone(reason)));
            }
        }
    }

    /// Ends every waiting key that can go now, oldest first.
    fn settle(&mut self) {
        loop {
            let mut fronts: HashSet<Sink> = HashSet::new();
            let mut chosen: Option<usize> = None;
            for (index, key) in self.keys.iter().enumerate() {
                let State::Waiting(sink) = &key.state else { continue };
                // Only the first waiting key of each sink may go.
                if !fronts.insert(sink.clone()) {
                    continue;
                }
                if key.action || self.via(sink, self.reaches.as_ref(), key.text).is_ok() {
                    chosen = Some(index);
                    break;
                }
            }
            let Some(index) = chosen else { return };
            let Some(sink) = self.keys[index].sink.clone() else { return };
            let ending = if self.keys[index].action {
                Ending::Ran
            } else {
                let Ok(via) = self.via(&sink, self.reaches.as_ref(), self.keys[index].text) else {
                    return;
                };
                self.deliveries.entry(sink.clone()).or_default().push(self.keys[index].id);
                Ending::Delivered(sink, via)
            };
            self.keys[index].state = State::Ended(ending);
        }
    }

    fn via(&self, sink: &Sink, reaches: Option<&Sink>, text: bool) -> Result<Via, WaitReason> {
        let needs_ready = matches!(sink, Sink::Content(_) | Sink::DevTools(_));
        let direct = matches!(sink, Sink::Terminal(_) | Sink::Content(_) | Sink::DevTools(_));
        if needs_ready && !self.ready.contains(sink) {
            Err(WaitReason::NotReady)
        } else if reaches == Some(sink) {
            Ok(Via::Responder)
        } else if !direct || (text && self.composes) {
            Err(WaitReason::AwaitsResponder)
        } else {
            Ok(Via::Direct)
        }
    }

    fn waits(&self, sink: &Sink) -> usize {
        self.keys.iter().filter(|key| key.state == State::Waiting(sink.clone())).count()
    }

    fn record(&mut self, id: u64, sink: Option<Sink>, text: bool, action: bool, state: State) {
        if let State::Ended(Ending::Delivered(to, _)) = &state {
            self.deliveries.entry(to.clone()).or_default().push(id);
        }
        self.keys.push(Key { id, sink, text, action, state });
    }

    fn key(&mut self, key: &KeyRecord) {
        let id = self.keys.last().map_or(1, |last| last.id + 1);
        let slot = (key.window.to_string(), key.code);
        match key.phase {
            KeyPhase::Up => match self.pressed.remove(&slot) {
                Some(Pressed::Sink(sink)) => self.release(id, key, sink),
                Some(Pressed::Consumed) => {
                    self.record(
                        id,
                        None,
                        false,
                        false,
                        State::Ended(Ending::Consumed(ConsumeReason::FollowsConsumedPress)),
                    );
                }
                Some(Pressed::Platform) | None => {
                    self.record(id, None, false, false, State::Ended(Ending::Platform));
                }
            },
            KeyPhase::Repeat => match self.pressed.get(&slot).cloned() {
                Some(Pressed::Sink(sink)) => self.to(id, key, sink),
                Some(Pressed::Platform) => {
                    self.record(id, None, false, false, State::Ended(Ending::Platform));
                }
                Some(Pressed::Consumed) | None => {
                    let pressed = self.decide(id, key);
                    self.pressed.insert(slot, pressed);
                }
            },
            KeyPhase::Down => {
                let pressed = self.decide(id, key);
                self.pressed.insert(slot, pressed);
            }
        }
    }

    fn decide(&mut self, id: u64, key: &KeyRecord) -> Pressed {
        let known = self.windows.iter().any(|(w, _)| **w == *key.window);
        if key.role != WindowRole::Main || !known {
            self.record(id, None, false, false, State::Ended(Ending::Platform));
            return Pressed::Platform;
        }
        if key.composing && !key.modifiers.command {
            return match key.reaches.clone() {
                Some(sink) => {
                    self.to(id, key, sink.clone());
                    Pressed::Sink(sink)
                }
                None => {
                    self.record(id, None, false, false, State::Ended(Ending::Platform));
                    Pressed::Platform
                }
            };
        }
        let (aim, _) = self.aim_tab(&key.window);
        if let Some(binding) = &key.binding
            && let Some(focus) = self.focus(&key.window)
        {
            let resolved = &focus.derived.resolved;
            let terminal = matches!(resolved, Resolved::Terminal { .. });
            let to_view = binding.ghostty
                && ((terminal && !key.terminal_copy_mode) || binding.tier == Tier::Content);
            if !to_view && runs(&binding.action, binding.tier, focus) {
                match &aim {
                    Some(sink) if binding.edits_input && self.waits(sink) > 0 => {
                        let state = if self.waits(sink) >= LANE_LIMIT {
                            State::Ended(Ending::Dropped(DropReason::LaneFull))
                        } else {
                            State::Waiting(sink.clone())
                        };
                        self.record(id, Some(sink.clone()), false, true, state);
                    }
                    _ => self.record(id, None, false, false, State::Ended(Ending::Ran)),
                }
                return Pressed::Consumed;
            }
        }
        match aim {
            Some(sink) => {
                self.to(id, key, sink.clone());
                Pressed::Sink(sink)
            }
            None => {
                self.record(
                    id,
                    None,
                    false,
                    false,
                    State::Ended(Ending::Consumed(ConsumeReason::NoTarget)),
                );
                Pressed::Consumed
            }
        }
    }

    fn to(&mut self, id: u64, key: &KeyRecord, sink: Sink) {
        let text = !(key.modifiers.command || key.modifiers.control);
        let state = if let Some(reason) = self.gone.get(&sink) {
            State::Ended(Ending::Dropped(DropReason::SinkGone(*reason)))
        } else if self.waits(&sink) >= LANE_LIMIT {
            State::Ended(Ending::Dropped(DropReason::LaneFull))
        } else if self.waits(&sink) > 0 {
            State::Waiting(sink.clone())
        } else {
            match self.via(&sink, key.reaches.as_ref(), text) {
                Ok(via) => State::Ended(Ending::Delivered(sink.clone(), via)),
                Err(_) => State::Waiting(sink.clone()),
            }
        };
        self.record(id, Some(sink), text, false, state);
    }

    fn release(&mut self, id: u64, key: &KeyRecord, sink: Sink) {
        let state = if let Some(reason) = self.gone.get(&sink) {
            State::Ended(Ending::Dropped(DropReason::SinkGone(*reason)))
        } else if self.waits(&sink) >= LANE_LIMIT {
            State::Ended(Ending::Dropped(DropReason::LaneFull))
        } else if self.waits(&sink) > 0 {
            State::Waiting(sink.clone())
        } else {
            match self.via(&sink, key.reaches.as_ref(), false) {
                Ok(via) => State::Ended(Ending::Delivered(sink.clone(), via)),
                Err(_) => State::Ended(Ending::Consumed(ConsumeReason::ReleaseNotTaken)),
            }
        };
        self.record(id, Some(sink), false, false, state);
    }

    /// The sink a key typed now in `window` is aimed at, and its tab.
    fn aim_tab(&self, window: &str) -> (Option<Sink>, Option<String>) {
        let Some(focus) = self.focus(window) else { return (None, None) };
        let w: Arc<str> = Arc::from(window);
        if let Some(top) = focus.overlays.last() {
            return (Some(Sink::Overlay { window: w, overlay: *top }), None);
        }
        if let Some(expectation) = &focus.expectation
            && expectation.generation == focus.generation
        {
            let own = std::iter::once(focus);
            let shown = own
                .chain(self.windows.iter().map(|(_, f)| f))
                .find_map(|f| find_tab(f, &expectation.key));
            let found = match shown {
                Some(tab) => tab_sink(&tab).map(|sink| (Some(tab.id.clone()), sink)),
                None => {
                    self.creations.iter().find(|(k, _)| *k == expectation.key).map(|(_, sink)| {
                        let tab = match &expectation.key {
                            ExpectationKey::Tab { id } => Some(id.clone()),
                            ExpectationKey::Surface { .. } => None,
                        };
                        (tab, sink.clone())
                    })
                }
            };
            if let Some((tab, sink)) = found {
                let field = |kind| Sink::Field { window: w.clone(), field: kind };
                let page = matches!(sink, Sink::Content(_));
                let sink = match (expectation.target, tab.as_deref()) {
                    (Target::AddressBar {}, Some(t)) if page => {
                        field(FieldKind::AddressBar { tab: Arc::from(t) })
                    }
                    (Target::FindBar {}, Some(t)) if page => {
                        field(FieldKind::FindBar { tab: Arc::from(t) })
                    }
                    (Target::DevTools {}, Some(t)) if page => Sink::DevTools(Arc::from(t)),
                    (Target::Sidebar { .. }, _) => field(FieldKind::Sidebar),
                    (Target::SidebarField {}, _) => field(FieldKind::SidebarField),
                    (Target::TextField {}, _) => field(FieldKind::TextField),
                    _ => sink,
                };
                return (Some(sink), tab);
            }
        }
        let field = |kind| Some(Sink::Field { window: w.clone(), field: kind });
        let tab = |id: &str| Arc::<str>::from(id);
        let sink = match &focus.derived.resolved {
            Resolved::Terminal { tab: id, .. } => {
                let shown = focus.topology.panes.iter().flat_map(|p| &p.tabs).find(|t| t.id == *id);
                match shown {
                    Some(t) => tab_sink(t),
                    None => Some(Sink::Terminal(TerminalKey::Tab(tab(id.as_str())))),
                }
            }
            Resolved::BrowserPage { tab: id, .. }
            | Resolved::AgentPage { tab: id, .. }
            | Resolved::Page { tab: id, .. }
            | Resolved::Conversation { tab: id, .. } => Some(Sink::Content(tab(id.as_str()))),
            Resolved::AddressBar { tab: id, .. } => {
                field(FieldKind::AddressBar { tab: tab(id.as_str()) })
            }
            Resolved::FindBar { tab: id, .. } => {
                field(FieldKind::FindBar { tab: tab(id.as_str()) })
            }
            Resolved::DevTools { tab: id, .. } => Some(Sink::DevTools(tab(id.as_str()))),
            Resolved::Sidebar {} => field(FieldKind::Sidebar),
            Resolved::SidebarField {} => field(FieldKind::SidebarField),
            Resolved::TextField {} => field(FieldKind::TextField),
            Resolved::Overlay { overlay } => {
                Some(Sink::Overlay { window: w.clone(), overlay: *overlay })
            }
            Resolved::EmptyPane { .. } | Resolved::None {} => None,
        };
        (sink, focus.derived.resolved.tab().map(str::to_owned))
    }
}

/// The tab `key` names in `focus`'s topology.
fn find_tab(focus: &FocusState, key: &ExpectationKey) -> Option<Tab> {
    focus.topology.panes.iter().flat_map(|pane| &pane.tabs).find_map(|tab| {
        let hit = match key {
            ExpectationKey::Tab { id } => tab.id == *id,
            ExpectationKey::Surface { id } => tab.surface.as_deref() == Some(id.as_str()),
        };
        hit.then(|| tab.clone())
    })
}

fn tab_sink(tab: &Tab) -> Option<Sink> {
    match tab.kind {
        Kind::Terminal => Some(Sink::Terminal(match &tab.terminal {
            Some(host) => TerminalKey::Host(Arc::from(host.as_str())),
            None => TerminalKey::Tab(Arc::from(tab.id.as_str())),
        })),
        Kind::Browser | Kind::Agent | Kind::Page | Kind::Conversation => {
            Some(Sink::Content(Arc::from(tab.id.as_str())))
        }
        Kind::Other => None,
    }
}

/// The tier rule (plans/cmux-next/focus.md section 5), as the app's
/// `KeyRouter.allows` states it.
fn runs(action: &str, tier: Tier, focus: &FocusState) -> bool {
    let mode = focus.derived.browser_focus_mode_active;
    let resolved = &focus.derived.resolved;
    let chrome_field = matches!(resolved, Resolved::AddressBar { .. } | Resolved::FindBar { .. });
    let browser = chrome_field
        || matches!(resolved, Resolved::BrowserPage { .. } | Resolved::DevTools { .. });
    match tier {
        Tier::System if mode => KEPT.contains(&action),
        Tier::System => true,
        Tier::Navigation => !mode,
        Tier::Content if DEV_TOOLS.contains(&action) && browser && !mode => true,
        Tier::Content if CHROME.contains(&action) && chrome_field => true,
        Tier::Content => {
            !mode && !resolved.is_text_input() && !matches!(resolved, Resolved::DevTools { .. })
        }
    }
}
