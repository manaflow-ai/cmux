//! The reference model the fuzz checks the router against: the same rules
//! (DESIGN.md sections 4.4-4.8) written as plainly as possible, with none of
//! the router's structure. It keeps every key in one list with its state,
//! finds tabs by scanning every window's topology, and after every event
//! settles the whole world from scratch: what ended, what left, and what can
//! go now, oldest key first.

use cmux_focus_core::event::{FocusEffect, FocusEvent, Source};
use cmux_focus_core::input::{
    Binding, ConsumeReason, DialogScope, DropReason, FieldKind, GoneReason, InputEvent, KeyPhase,
    KeyRecord, LANE_LIMIT, SessionEnd, SessionKey, SessionKind, Sink, TerminalKey, Tier, Via,
    WaitReason, WindowRole,
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
    /// Delivered to its page first; a later `Ran` when the page left it unhandled.
    Offered(Sink),
    /// A key session took it.
    Session(SessionKey),
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
    Offered(Sink),
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
    /// The key session that runs, and its window.
    session: Option<(SessionKind, String)>,
    /// Every session end, in order.
    pub session_ends: Vec<(SessionKind, SessionEnd)>,
    /// The dialogs shown, oldest first.
    dialogs: Vec<(u64, DialogScope)>,
    /// The ids of the keys offered to their page whose report is awaited,
    /// oldest first (at most 16, as the router keeps).
    offers: Vec<u64>,
    /// Per window, the pane Escape in a field gives the keyboard back to.
    return_to: HashMap<String, String>,
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
            session: None,
            session_ends: Vec::new(),
            dialogs: Vec::new(),
            offers: Vec::new(),
            return_to: HashMap::new(),
        }
    }

    /// The ids of the keys offered to a page whose report is still awaited.
    pub fn offered(&self) -> &[u64] {
        &self.offers
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
            InputEvent::Focus { window, event } => self.focus_event(window, event),
            InputEvent::WindowOpened { window } => {
                if !self.windows.iter().any(|(id, _)| **id == **window) {
                    let mut focus = FocusState::default();
                    focus.derive();
                    self.windows.push((window.to_string(), focus));
                }
            }
            InputEvent::WindowClosed { window } => {
                if self.windows.iter().any(|(id, _)| **id == **window) {
                    if self.session.as_ref().is_some_and(|(_, w)| **w == **window) {
                        self.end_session(SessionEnd::WindowClosed);
                    }
                    self.windows.retain(|(id, _)| **id != **window);
                    self.return_to.remove(&**window);
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
            InputEvent::SessionStarted { kind, window } => {
                self.end_session(SessionEnd::Replaced);
                let open = self.focus(window).is_some();
                let on_page = match kind {
                    SessionKind::LinkHints { tab } => {
                        self.aim(window) == Some(Sink::Content(tab.clone()))
                    }
                    _ => true,
                };
                if !open {
                    self.session_ends.push((kind.clone(), SessionEnd::WindowClosed));
                } else if !on_page {
                    self.session_ends.push((kind.clone(), SessionEnd::FocusLeft));
                } else {
                    self.session = Some((kind.clone(), window.to_string()));
                }
            }
            InputEvent::SessionEnded => self.end_session(SessionEnd::Finished),
            InputEvent::DialogShown { id, scope } => {
                if !self.dialogs.iter().any(|(d, _)| d == id) {
                    self.dialogs.push((*id, scope.clone()));
                }
            }
            InputEvent::DialogDismissed { id } => {
                self.dialogs.retain(|(d, _)| d != id);
                for key in &mut self.keys {
                    if key.state == State::Waiting(Sink::Dialog(*id)) {
                        key.state =
                            State::Ended(Ending::Dropped(DropReason::SinkGone(GoneReason::Closed)));
                    }
                }
            }
            InputEvent::PageUnhandled { id } => {
                if let Some(index) = self.offers.iter().position(|o| o == &id.0) {
                    self.offers.drain(..=index);
                    if let Some(key) = self.keys.iter_mut().find(|k| k.id == id.0) {
                        key.state = State::Ended(Ending::Ran);
                    }
                }
            }
        }
        self.drop_left();
        self.settle();
    }

    /// A field or overlay the focus left keeps no key.
    fn drop_left(&mut self) {
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
    }

    fn focus_event(&mut self, window: &str, event: &FocusEvent) {
        let Some((_, focus)) = self.windows.iter_mut().find(|(id, _)| id == window) else { return };
        let before = focus.derived.resolved.clone();
        let mut effects: Vec<FocusEffect> = Vec::new();
        reducer::reduce(focus, event, &mut effects);
        let after = focus.derived.resolved.clone();
        if !matches!(after, Resolved::SidebarField {} | Resolved::TextField {}) {
            self.return_to.remove(window);
        } else if from_content(&before) && by_person(event) {
            match before.pane() {
                Some(pane) => {
                    self.return_to.insert(window.to_owned(), pane.to_owned());
                }
                None => {
                    self.return_to.remove(window);
                }
            }
        }
        if matches!(event, FocusEvent::Topology { .. }) {
            let windows = &self.windows;
            self.creations.retain(|(key, _)| {
                !windows.iter().any(|(_, focus)| find_tab(focus, key).is_some())
            });
        }
        // The running session ends when its target is gone.
        let ends = match &self.session {
            Some((SessionKind::LinkHints { tab }, w)) if w == window => {
                self.aim(window) != Some(Sink::Content(tab.clone()))
            }
            Some((SessionKind::WindowHints, w)) if w == window => {
                by_person(event) || matches!(event, FocusEvent::DragBegan { .. })
            }
            _ => false,
        };
        if ends {
            self.end_session(SessionEnd::FocusLeft);
        }
    }

    fn end_session(&mut self, reason: SessionEnd) {
        if let Some((kind, _)) = self.session.take() {
            self.session_ends.push((kind, reason));
        }
    }

    /// The dialog that blocks a key of `window` aimed at `sink`.
    fn dialog_for(&self, window: &str, sink: Option<&Sink>) -> Option<u64> {
        let chrome = matches!(sink, None | Some(Sink::Field { field: FieldKind::Sidebar, .. }));
        for (id, scope) in &self.dialogs {
            let blocks = match scope {
                DialogScope::Window(w) => {
                    **w == *window && !matches!(sink, Some(Sink::Overlay { .. }))
                }
                DialogScope::Tab { window: w, tab } => {
                    **w == *window
                        && (sink.is_some_and(|s| self.of_tab(w, tab, s))
                            || (chrome && self.shown_tab(w).as_deref() == Some(&**tab)))
                }
            };
            if blocks {
                return Some(*id);
            }
        }
        None
    }

    /// Whether a dialog blocks `sink`.
    fn blocked(&self, sink: &Sink) -> bool {
        if matches!(sink, Sink::Dialog(_) | Sink::Overlay { .. }) {
            return false;
        }
        self.dialogs.iter().any(|(_, scope)| match scope {
            DialogScope::Window(w) => match sink.window() {
                Some(own) => own == w,
                None => self.focus(w).is_some_and(|focus| {
                    focus
                        .topology
                        .panes
                        .iter()
                        .flat_map(|p| &p.tabs)
                        .any(|t| self.of_tab(w, &Arc::from(t.id.as_str()), sink))
                }),
            },
            DialogScope::Tab { window: w, tab } => self.of_tab(w, tab, sink),
        })
    }

    /// Whether `sink` is the content or developer tools of tab `tab` of `window`.
    fn of_tab(&self, window: &str, tab: &Arc<str>, sink: &Sink) -> bool {
        if *sink == Sink::DevTools(tab.clone()) {
            return true;
        }
        let Some(focus) = self.focus(window) else { return false };
        let shown = focus.topology.panes.iter().flat_map(|p| &p.tabs).find(|t| *t.id == **tab);
        shown.and_then(tab_sink).as_ref() == Some(sink)
    }

    /// The tab `window`'s focused pane shows.
    fn shown_tab(&self, window: &str) -> Option<String> {
        let focus = self.focus(window)?;
        let pane = focus.pane.as_ref()?;
        focus.topology.panes.iter().find(|p| p.id == *pane)?.selected.clone()
    }

    /// Why a key for `sink` reaches nothing.
    fn gone_reason(&self, sink: &Sink) -> Option<GoneReason> {
        if let Sink::Dialog(id) = sink {
            return (!self.dialogs.iter().any(|(d, _)| d == id)).then_some(GoneReason::Closed);
        }
        self.gone.get(sink).copied()
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
        let direct = matches!(
            sink,
            Sink::Terminal(_) | Sink::Content(_) | Sink::DevTools(_) | Sink::Dialog(_)
        );
        if self.blocked(sink) {
            Err(WaitReason::Blocked)
        } else if needs_ready && !self.ready.contains(sink) {
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
        if let State::Ended(Ending::Delivered(to, _) | Ending::Offered(to)) = &state {
            self.deliveries.entry(to.clone()).or_default().push(id);
        }
        self.keys.push(Key { id, sink, text, action, state });
    }

    fn key(&mut self, key: &KeyRecord) {
        let id = self.keys.last().map_or(1, |last| last.id + 1);
        let slot = (key.window.to_string(), key.code);
        match key.phase {
            KeyPhase::Up => match self.pressed.remove(&slot) {
                Some(Pressed::Sink(sink) | Pressed::Offered(sink)) => self.release(id, key, sink),
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
                Some(Pressed::Consumed | Pressed::Offered(_)) | None => {
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
        if let Some((kind, window)) = self.session.clone() {
            if key.role != WindowRole::Main || *window != *key.window {
                self.end_session(SessionEnd::OtherWindow);
            } else {
                let m = key.modifiers;
                let reading = match kind {
                    SessionKind::Recorder => Some(SessionKey::Any),
                    _ if key.code == 53 => Some(SessionKey::Escape),
                    _ if m.command || m.control || m.option => None,
                    _ if key.code == 51 => Some(SessionKey::Backspace),
                    _ => key.letter.map(|letter| SessionKey::Letter { letter, shift: m.shift }),
                };
                match reading {
                    Some(reading) => {
                        self.record(id, None, false, false, State::Ended(Ending::Session(reading)));
                        if reading == SessionKey::Escape {
                            self.end_session(SessionEnd::Escape);
                        }
                        return Pressed::Consumed;
                    }
                    None => self.end_session(SessionEnd::OtherKey),
                }
            }
        }
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
        let dialog = self.dialog_for(&key.window, aim.as_ref());
        if let Some(binding) = &key.binding
            && let Some(focus) = self.focus(&key.window)
        {
            let resolved = &focus.derived.resolved;
            let terminal = matches!(resolved, Resolved::Terminal { .. });
            let to_view = binding.ghostty
                && ((terminal && !key.terminal_copy_mode) || binding.tier == Tier::Content);
            if !to_view && runs(&binding.action, binding.tier, focus) {
                if dialog.is_none()
                    && let Some(page) = self.page_first(binding, key, focus)
                {
                    self.offers.push(id);
                    if self.offers.len() > 16 {
                        self.offers.remove(0);
                    }
                    self.record(
                        id,
                        None,
                        false,
                        false,
                        State::Ended(Ending::Offered(page.clone())),
                    );
                    return Pressed::Offered(page);
                }
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
        if let Some(dialog) = dialog {
            self.to(id, key, Sink::Dialog(dialog));
            return Pressed::Sink(Sink::Dialog(dialog));
        }
        let m = key.modifiers;
        let bare_escape = key.code == 53 && !(m.command || m.control || m.option || m.shift);
        let in_field = matches!(
            aim,
            Some(Sink::Field { field: FieldKind::SidebarField | FieldKind::TextField, .. })
        );
        let back =
            self.return_to.get(&*key.window).cloned().filter(|pane| {
                self.focus(&key.window).is_some_and(|f| f.topology.contains_pane(pane))
            });
        if bare_escape
            && in_field
            && !key.field_uses_escape
            && let Some(pane) = back
        {
            let event = FocusEvent::FocusPane { pane, workspace: None, source: Source::Keyboard };
            self.focus_event(&key.window, &event);
            // The field's waiting keys can no longer reach it.
            self.drop_left();
            self.record(
                id,
                None,
                false,
                false,
                State::Ended(Ending::Consumed(ConsumeReason::ReturnedFocus)),
            );
            return Pressed::Consumed;
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
        let state = if let Some(reason) = self.gone_reason(&sink) {
            State::Ended(Ending::Dropped(DropReason::SinkGone(reason)))
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
        let state = if let Some(reason) = self.gone_reason(&sink) {
            State::Ended(Ending::Dropped(DropReason::SinkGone(reason)))
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

impl Model {
    /// The page a bound chord goes to first (the app's `offersToPage`): the
    /// focused page, when its window has the keys and it takes them now.
    fn page_first(&self, binding: &Binding, key: &KeyRecord, focus: &FocusState) -> Option<Sink> {
        let Resolved::BrowserPage { tab, .. } = &focus.derived.resolved else { return None };
        let action: &str = &binding.action;
        if focus.derived.browser_focus_mode_active || binding.ghostty || DEV_TOOLS.contains(&action)
        {
            return None;
        }
        let page_may_own = match binding.tier {
            Tier::Content => true,
            Tier::Navigation => {
                ["find", "findNext", "findPrevious", "useSelectionForFind"].contains(&action)
                    || (key.page_editing_chord
                        && !["openBrowser", "openBrowser.chromium", "openBrowser.webkit"]
                            .contains(&action))
            }
            Tier::System => false,
        };
        let page = Sink::Content(Arc::from(tab.as_str()));
        let reached = key.reaches.as_ref() == Some(&page);
        let takes = self.waits(&page) == 0
            && self.via(&page, key.reaches.as_ref(), false) == Ok(Via::Responder);
        (page_may_own && reached && takes).then_some(page)
    }
}

/// A tab's content had the keyboard.
fn from_content(resolved: &Resolved) -> bool {
    matches!(
        resolved,
        Resolved::Terminal { .. }
            | Resolved::BrowserPage { .. }
            | Resolved::AgentPage { .. }
            | Resolved::Page { .. }
            | Resolved::Conversation { .. }
    )
}

/// The person moved the focus.
fn by_person(event: &FocusEvent) -> bool {
    match event {
        FocusEvent::FocusPane { source, .. }
        | FocusEvent::SelectTab { source, .. }
        | FocusEvent::FocusTarget { source, .. }
        | FocusEvent::Responder { source, .. } => source.is_user_intent(),
        _ => false,
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
