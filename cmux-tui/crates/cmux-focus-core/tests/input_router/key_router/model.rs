//! The reference model the fuzz checks the router against: the same rules
//! (DESIGN.md sections 4.3-4.8) written as plainly as possible, with none of
//! the router's structure. It keeps every key in one list with its state,
//! finds tabs by scanning every window's topology, and after every event
//! settles the whole world from scratch: what ended, what left, and what can
//! go now, oldest key first.

use cmux_focus_core::event::{FocusEffect, FocusEvent, Source};
use cmux_focus_core::input::{
    Binding, ConsumeReason, DialogScope, DropReason, FieldKind, GoneReason, InputEvent, KeyPhase,
    KeyRecord, OfferEnd, SessionEnd, SessionKey, SessionKind, Sink, TerminalKey, Tier, Via,
    WaitReason, WindowRole,
};
use cmux_focus_core::state::{ExpectationKey, FocusState, Resolved, Target};
use cmux_focus_core::topology::{Kind, Tab};
use cmux_focus_core::window::WindowFocus;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// How a key ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ending {
    Delivered(Sink, Via),
    /// Its binding's action ran, aimed at `tab`.
    Ran {
        action: Arc<str>,
        tab: Option<Arc<str>>,
    },
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
    /// A waiting action (a Paste waiting for its input): the action and its tab.
    action: Option<(Arc<str>, Option<Arc<str>>)>,
    state: State,
}

#[derive(Clone)]
enum Pressed {
    /// To this sink; the key-down's id.
    Sink(Sink, u64),
    Platform,
    /// It ran its binding, or a session took it.
    Consumed,
    /// It reached nothing.
    Nothing,
    Offered(Sink),
}

/// A creation, until its reply and a window shows its tab.
struct Made {
    key: ExpectationKey,
    sink: Sink,
    kind: Kind,
    /// Its reply came: done.
    replied: bool,
    /// It restarts an exited sink: a failure leaves the dead tab, exited.
    restart: bool,
}

/// A key offered to its page, whose answer has not come.
struct Offered {
    id: u64,
    page: Sink,
    action: Arc<str>,
    tab: Option<Arc<str>>,
}

/// What the binding rules see of a key's target.
#[derive(Clone, Copy)]
struct Seen {
    terminal: bool,
    text_input: bool,
    dev_tools: bool,
    /// A browser page, its address bar, find bar or developer tools.
    browser: bool,
    /// A browser's address bar or find bar.
    chrome_field: bool,
}

/// Where a key typed now goes: the sink, the tab it is for, what the binding
/// rules see, and whether the focus is on its way to it (an expectation).
struct Aimed {
    sink: Option<Sink>,
    tab: Option<Arc<str>>,
    seen: Seen,
    expected: bool,
}

pub struct Model {
    limit: usize,
    /// Each window's focus, reduced as the app's focus handle reduces it.
    windows: Vec<(String, WindowFocus)>,
    reaches: Option<Sink>,
    ready: HashSet<Sink>,
    /// Tab sinks that ended: why, and whether no window showed them since.
    gone: HashMap<Sink, (GoneReason, bool)>,
    composes: bool,
    creations: Vec<Made>,
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
    /// The keys offered to a page whose answer has not come, oldest first.
    offers: Vec<Offered>,
    /// Every offer that ended with no action, in order.
    pub offer_ends: Vec<(u64, OfferEnd)>,
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

impl Model {
    /// A model whose lanes (and each page's waiting offers) hold `limit`
    /// entries at most.
    pub fn new(limit: usize) -> Model {
        Model {
            limit,
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
            offer_ends: Vec::new(),
            return_to: HashMap::new(),
        }
    }

    /// The ids of the keys offered to a page whose answer has not come.
    pub fn offered(&self) -> Vec<u64> {
        self.offers.iter().map(|offer| offer.id).collect()
    }

    /// Every key's state, by id.
    pub fn states(&self) -> HashMap<u64, State> {
        self.keys.iter().map(|key| (key.id, key.state.clone())).collect()
    }

    pub fn focus(&self, window: &str) -> Option<&FocusState> {
        self.windows.iter().find(|(id, _)| id == window).map(|(_, focus)| focus.state())
    }

    /// The sink a text key typed now in `window` is aimed at.
    pub fn aim(&self, window: &str) -> Option<Sink> {
        self.aimed(window).sink
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
                    self.windows.push((window.to_string(), WindowFocus::new()));
                }
            }
            InputEvent::WindowClosed { window } => self.close(window),
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
            InputEvent::Creation { key, sink, kind } => {
                let was = self.gone.remove(sink);
                if was.is_some() {
                    self.renew(sink);
                }
                let restart = was.is_some_and(|(reason, _)| reason == GoneReason::Exited);
                self.creations.retain(|made| made.key != *key);
                let (key, sink, kind) = (key.clone(), sink.clone(), *kind);
                self.creations.push(Made { key, sink, kind, replied: false, restart });
            }
            InputEvent::Created { key } => {
                for made in &mut self.creations {
                    if made.key == *key {
                        made.replied = true;
                    }
                }
                self.forget_shown_creations();
            }
            InputEvent::CreationFailed { key } => {
                // One reply a creation: a failure after "done" changes nothing.
                let failed = self.creations.iter().position(|m| m.key == *key && !m.replied);
                if let Some(index) = failed {
                    let made = self.creations.remove(index);
                    let reason =
                        if made.restart { GoneReason::Exited } else { GoneReason::CreationFailed };
                    self.end(&made.sink, reason);
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
            InputEvent::PageUnhandled { id } => self.page_answered(id.0, true),
            InputEvent::PageHandled { id } => self.page_answered(id.0, false),
        }
        self.drop_left();
        self.settle();
    }

    /// The page answered offered key `id`: the same page's older offers were
    /// handled; the key's action runs when the page left it unhandled.
    fn page_answered(&mut self, id: u64, unhandled: bool) {
        let Some(index) = self.offers.iter().position(|offer| offer.id == id) else { return };
        let answered = self.offers.remove(index);
        let mut kept = Vec::new();
        for offer in std::mem::take(&mut self.offers) {
            if offer.id < id && offer.page == answered.page {
                self.offer_ends.push((offer.id, OfferEnd::Handled));
            } else {
                kept.push(offer);
            }
        }
        self.offers = kept;
        if !unhandled {
            self.offer_ends.push((id, OfferEnd::Handled));
            return;
        }
        if let Some(key) = self.keys.iter_mut().find(|key| key.id == id) {
            key.state = State::Ended(Ending::Ran { action: answered.action, tab: answered.tab });
        }
    }

    fn close(&mut self, window: &str) {
        if !self.windows.iter().any(|(id, _)| id == window) {
            return;
        }
        if self.session.as_ref().is_some_and(|(_, w)| w == window) {
            self.end_session(SessionEnd::WindowClosed);
        }
        self.windows.retain(|(id, _)| id != window);
        self.return_to.remove(window);
        self.pressed.retain(|(pressed, _), _| pressed != window);
        for key in &mut self.keys {
            if let State::Waiting(sink) = &key.state
                && sink.window().is_some_and(|w| **w == *window)
            {
                key.state = State::Ended(Ending::Dropped(DropReason::WindowClosed));
            }
        }
        self.track_gone();
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
        let before = focus.state().derived.resolved.clone();
        let mut effects: Vec<FocusEffect> = Vec::new();
        focus.send(event, &mut effects);
        let after = focus.state().derived.resolved.clone();
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
            self.track_gone();
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

    /// Every tab sink some window shows: each tab's content and its
    /// developer tools.
    fn shown_sinks(&self) -> Vec<Sink> {
        let mut shown = Vec::new();
        for (_, focus) in &self.windows {
            for tab in focus.state().topology.panes.iter().flat_map(|pane| &pane.tabs) {
                shown.extend(tab_sink(tab));
                shown.push(Sink::DevTools(Arc::from(tab.id.as_str())));
            }
        }
        shown
    }

    /// An exited sink stays ended wherever its tab shows: only a creation
    /// makes it new. A closed (or failed) sink that a window shows again after
    /// none did is new; one that no window shows and no held key names is
    /// forgotten (also new).
    fn track_gone(&mut self) {
        self.forget_shown_creations();
        let shown = self.shown_sinks();
        let ended: Vec<Sink> = self.gone.keys().cloned().collect();
        for sink in ended {
            let shows = shown.contains(&sink);
            let held = self.pressed.values().any(|pressed| match pressed {
                Pressed::Sink(held, down) => *held == sink && !self.reached_nothing(*down),
                Pressed::Offered(held) => *held == sink,
                _ => false,
            });
            let Some((reason, left)) = self.gone.get_mut(&sink) else { continue };
            if *reason == GoneReason::Exited {
                continue;
            }
            let new = if shows {
                *left
            } else {
                *left = true;
                !held
            };
            if new {
                self.gone.remove(&sink);
                self.renew(&sink);
            }
        }
    }

    /// A done creation is forgotten once some window shows its tab.
    fn forget_shown_creations(&mut self) {
        let windows = &self.windows;
        self.creations.retain(|made| {
            !made.replied
                || !windows.iter().any(|(_, focus)| find_tab(focus.state(), &made.key).is_some())
        });
    }

    /// `sink` names a new sink: the presses held for the ended one reach nothing.
    fn renew(&mut self, sink: &Sink) {
        for pressed in self.pressed.values_mut() {
            let old = match pressed {
                Pressed::Sink(held, _) | Pressed::Offered(held) => held == sink,
                _ => false,
            };
            if old {
                *pressed = Pressed::Nothing;
            }
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
        self.gone.get(sink).map(|(reason, _)| *reason)
    }

    fn end(&mut self, sink: &Sink, reason: GoneReason) {
        self.ready.remove(sink);
        if matches!(sink, Sink::Terminal(_) | Sink::Content(_) | Sink::DevTools(_)) {
            self.creations.retain(|made| made.sink != *sink);
            let shown = self.shown_sinks().contains(sink);
            match self.gone.get_mut(sink) {
                // An exited sink whose tab then closes is gone for good.
                Some((had, left)) => {
                    if *had == GoneReason::Exited && reason != GoneReason::Exited {
                        *had = reason;
                        *left = !shown;
                    }
                }
                None => {
                    self.gone.insert(sink.clone(), (reason, !shown));
                }
            }
            // The page's offers can get no answer now.
            let mut kept = Vec::new();
            for offer in std::mem::take(&mut self.offers) {
                if offer.page == *sink {
                    self.offer_ends.push((offer.id, OfferEnd::PageGone));
                } else {
                    kept.push(offer);
                }
            }
            self.offers = kept;
        }
        for key in &mut self.keys {
            if key.state == State::Waiting(sink.clone()) {
                key.state = State::Ended(Ending::Dropped(DropReason::SinkGone(reason)));
            }
        }
    }

    /// Ends every waiting key or action that can go now, oldest first.
    fn settle(&mut self) {
        loop {
            let mut fronts: HashSet<Sink> = HashSet::new();
            let mut chosen: Option<usize> = None;
            for (index, key) in self.keys.iter().enumerate() {
                let State::Waiting(sink) = &key.state else { continue };
                // Only the first waiting entry of each sink may go.
                if !fronts.insert(sink.clone()) {
                    continue;
                }
                if self.via(sink, self.reaches.as_ref(), key.text).is_ok() {
                    chosen = Some(index);
                    break;
                }
            }
            let Some(index) = chosen else { return };
            let Some(sink) = self.keys[index].sink.clone() else { return };
            let ending = match self.keys[index].action.clone() {
                Some((action, tab)) => Ending::Ran { action, tab },
                None => {
                    let text = self.keys[index].text;
                    let Ok(via) = self.via(&sink, self.reaches.as_ref(), text) else { return };
                    self.deliveries.entry(sink.clone()).or_default().push(self.keys[index].id);
                    Ending::Delivered(sink, via)
                }
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

    /// The entries waiting for `sink`.
    fn waits(&self, sink: &Sink) -> usize {
        self.keys.iter().filter(|key| key.state == State::Waiting(sink.clone())).count()
    }

    fn record(&mut self, id: u64, sink: Option<Sink>, text: bool, state: State) {
        if let State::Ended(Ending::Delivered(to, _) | Ending::Offered(to)) = &state {
            self.deliveries.entry(to.clone()).or_default().push(id);
        }
        self.keys.push(Key { id, sink, text, action: None, state });
    }

    /// Key `down` was dropped: its press reached nothing.
    fn reached_nothing(&self, down: u64) -> bool {
        self.keys
            .iter()
            .any(|key| key.id == down && matches!(key.state, State::Ended(Ending::Dropped(_))))
    }

    fn key(&mut self, key: &KeyRecord) {
        let id = self.keys.last().map_or(1, |last| last.id + 1);
        let slot = (key.window.to_string(), key.code);
        let follows = State::Ended(Ending::Consumed(ConsumeReason::FollowsConsumedPress));
        match key.phase {
            KeyPhase::Up => match self.pressed.remove(&slot) {
                Some(Pressed::Sink(sink, down)) if !self.reached_nothing(down) => {
                    self.release(id, key, sink);
                }
                Some(Pressed::Offered(sink)) => self.release(id, key, sink),
                Some(Pressed::Sink(..) | Pressed::Consumed | Pressed::Nothing) => {
                    self.record(id, None, false, follows);
                }
                Some(Pressed::Platform) | None => {
                    self.record(id, None, false, State::Ended(Ending::Platform));
                }
            },
            KeyPhase::Repeat => match self.pressed.get(&slot).cloned() {
                Some(Pressed::Sink(sink, down)) if !self.reached_nothing(down) => {
                    self.to(id, key, sink);
                }
                Some(Pressed::Sink(..) | Pressed::Nothing) => self.record(id, None, false, follows),
                Some(Pressed::Platform) => {
                    self.record(id, None, false, State::Ended(Ending::Platform));
                }
                // The release of a key-down its page got first goes to that page.
                Some(Pressed::Offered(page)) => {
                    let pressed = match self.decide(id, key) {
                        offered @ Pressed::Offered(_) => offered,
                        _ => Pressed::Offered(page),
                    };
                    self.pressed.insert(slot, pressed);
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

    /// A running session's reading of a key of its window; none: the key is
    /// no session key.
    fn session_reading(kind: &SessionKind, key: &KeyRecord) -> Option<SessionKey> {
        let m = key.modifiers;
        match kind {
            SessionKind::Recorder => Some(SessionKey::Any),
            _ if key.code == 53 => Some(SessionKey::Escape),
            _ if m.command || m.control || m.option => None,
            _ if key.code == 51 => Some(SessionKey::Backspace),
            _ => key.letter.map(|letter| SessionKey::Letter { letter, shift: m.shift }),
        }
    }

    fn decide(&mut self, id: u64, key: &KeyRecord) -> Pressed {
        // A key of another window or panel ends the running session first.
        if self
            .session
            .as_ref()
            .is_some_and(|(_, w)| key.role != WindowRole::Main || **w != *key.window)
        {
            self.end_session(SessionEnd::OtherWindow);
        }
        // A blocking dialog over the key's target takes a key with no Command
        // or Control before a session (which keeps running) or a binding.
        let known = self.windows.iter().any(|(w, _)| **w == *key.window);
        if known
            && key.role == WindowRole::Main
            && !key.composing
            && !(key.modifiers.command || key.modifiers.control)
        {
            let aimed = self.aimed(&key.window);
            if let Some(dialog) = self.dialog_for(&key.window, aimed.sink.as_ref()) {
                return self.press(id, key, Sink::Dialog(dialog));
            }
        }
        if let Some((kind, window)) = self.session.clone() {
            if key.role != WindowRole::Main || *window != *key.window {
                self.end_session(SessionEnd::OtherWindow);
            } else {
                match Model::session_reading(&kind, key) {
                    Some(reading) => {
                        self.record(id, None, false, State::Ended(Ending::Session(reading)));
                        if reading == SessionKey::Escape {
                            self.end_session(SessionEnd::Escape);
                        }
                        return Pressed::Consumed;
                    }
                    None => self.end_session(SessionEnd::OtherKey),
                }
            }
        }
        if key.role != WindowRole::Main || !known {
            self.record(id, None, false, State::Ended(Ending::Platform));
            return Pressed::Platform;
        }
        if key.composing && !key.modifiers.command {
            return match key.reaches.clone() {
                Some(sink) => self.press(id, key, sink),
                None => {
                    self.record(id, None, false, State::Ended(Ending::Platform));
                    Pressed::Platform
                }
            };
        }
        let aimed = self.aimed(&key.window);
        let dialog = self.dialog_for(&key.window, aimed.sink.as_ref());
        if let Some(binding) = &key.binding
            && let Some(focus) = self.focus(&key.window)
        {
            let seen = aimed.seen;
            let mode = focus.derived.browser_focus_mode_active;
            // Copy mode is the focused terminal's, never a new terminal's.
            let copy_mode = key.terminal_copy_mode && !aimed.expected;
            let to_view =
                binding.ghostty && ((seen.terminal && !copy_mode) || binding.tier == Tier::Content);
            if !to_view && runs(&binding.action, binding.tier, seen, mode) {
                if dialog.is_none()
                    && let Some(page) = self.page_first(binding, key, focus, aimed.sink.as_ref())
                {
                    let waiting = self.offers.iter().filter(|offer| offer.page == page).count();
                    if waiting >= self.limit
                        && let Some(oldest) =
                            self.offers.iter().position(|offer| offer.page == page)
                    {
                        let dropped = self.offers.remove(oldest);
                        self.offer_ends.push((dropped.id, OfferEnd::Overflow));
                    }
                    let action = binding.action.clone();
                    let offer = Offered { id, page: page.clone(), action, tab: aimed.tab.clone() };
                    self.offers.push(offer);
                    self.record(id, None, false, State::Ended(Ending::Offered(page.clone())));
                    return Pressed::Offered(page);
                }
                // Under a dialog, an input action edits the dialog's input, with no tab.
                let (input, tab) = match dialog {
                    Some(dialog) => {
                        let tab = if binding.edits_input { None } else { aimed.tab };
                        (Some(Sink::Dialog(dialog)), tab)
                    }
                    None => (aimed.sink, aimed.tab),
                };
                self.ran(id, binding, input, tab, key);
                return Pressed::Consumed;
            }
        }
        if let Some(dialog) = dialog {
            return self.press(id, key, Sink::Dialog(dialog));
        }
        let m = key.modifiers;
        let bare_escape = key.code == 53 && !(m.command || m.control || m.option || m.shift);
        let in_field = matches!(
            aimed.sink,
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
            let returned = State::Ended(Ending::Consumed(ConsumeReason::ReturnedFocus));
            self.record(id, None, false, returned);
            return Pressed::Nothing;
        }
        match aimed.sink {
            Some(sink) => self.press(id, key, sink),
            None => {
                let none = State::Ended(Ending::Consumed(ConsumeReason::NoTarget));
                self.record(id, None, false, none);
                Pressed::Nothing
            }
        }
    }

    /// Key `id` runs `binding`: now, or, when the action edits `input`, in
    /// `input`'s lane while it cannot take input or has entries waiting; an
    /// input that ended drops it, like a key.
    fn ran(
        &mut self,
        id: u64,
        binding: &Binding,
        input: Option<Sink>,
        tab: Option<Arc<str>>,
        key: &KeyRecord,
    ) {
        let ran = State::Ended(Ending::Ran { action: binding.action.clone(), tab: tab.clone() });
        let Some(sink) = input.filter(|_| binding.edits_input) else {
            self.record(id, None, false, ran);
            return;
        };
        if let Some(reason) = self.gone_reason(&sink) {
            let dropped = State::Ended(Ending::Dropped(DropReason::SinkGone(reason)));
            self.record(id, None, false, dropped);
            return;
        }
        let waiting = self.waits(&sink);
        if waiting == 0 && self.via(&sink, key.reaches.as_ref(), false).is_ok() {
            self.record(id, None, false, ran);
            return;
        }
        let state = if waiting >= self.limit {
            State::Ended(Ending::Dropped(DropReason::LaneFull))
        } else {
            State::Waiting(sink.clone())
        };
        let action = Some((binding.action.clone(), tab));
        self.keys.push(Key { id, sink: Some(sink), text: false, action, state });
    }

    /// A press to `sink`: its repeats and release follow it, unless it was
    /// dropped.
    fn press(&mut self, id: u64, key: &KeyRecord, sink: Sink) -> Pressed {
        self.to(id, key, sink.clone());
        Pressed::Sink(sink, id)
    }

    fn to(&mut self, id: u64, key: &KeyRecord, sink: Sink) {
        let text = !(key.modifiers.command || key.modifiers.control);
        let waiting = self.waits(&sink);
        let state = if let Some(reason) = self.gone_reason(&sink) {
            State::Ended(Ending::Dropped(DropReason::SinkGone(reason)))
        } else if waiting >= self.limit {
            State::Ended(Ending::Dropped(DropReason::LaneFull))
        } else if waiting > 0 {
            State::Waiting(sink.clone())
        } else {
            match self.via(&sink, key.reaches.as_ref(), text) {
                Ok(via) => State::Ended(Ending::Delivered(sink.clone(), via)),
                Err(_) => State::Waiting(sink.clone()),
            }
        };
        self.record(id, Some(sink), text, state);
    }

    fn release(&mut self, id: u64, key: &KeyRecord, sink: Sink) {
        let waiting = self.waits(&sink);
        let state = if let Some(reason) = self.gone_reason(&sink) {
            State::Ended(Ending::Dropped(DropReason::SinkGone(reason)))
        } else if waiting >= self.limit {
            State::Ended(Ending::Dropped(DropReason::LaneFull))
        } else if waiting > 0 {
            State::Waiting(sink.clone())
        } else {
            match self.via(&sink, key.reaches.as_ref(), false) {
                Ok(via) => State::Ended(Ending::Delivered(sink.clone(), via)),
                Err(_) => State::Ended(Ending::Consumed(ConsumeReason::ReleaseNotTaken)),
            }
        };
        self.record(id, Some(sink), false, state);
    }

    /// Where a key typed now in `window` goes: an open overlay, else the
    /// target an expectation waits for on its tab (shown in some window, else
    /// its creation's; a chrome target only on a browser tab), else the
    /// focused target.
    fn aimed(&self, window: &str) -> Aimed {
        let nothing = Seen {
            terminal: false,
            text_input: false,
            dev_tools: false,
            browser: false,
            chrome_field: false,
        };
        let Some(focus) = self.focus(window) else {
            return Aimed { sink: None, tab: None, seen: nothing, expected: false };
        };
        let w: Arc<str> = Arc::from(window);
        let focused = seen_focused(&focus.derived.resolved);
        if let Some(top) = focus.overlays.last() {
            let sink = Some(Sink::Overlay { window: w, overlay: *top });
            return Aimed { sink, tab: None, seen: focused, expected: false };
        }
        if let Some(expectation) = &focus.expectation
            && expectation.generation == focus.generation
            && let Some((tab, sink, kind)) = self.expected_tab(focus, &expectation.key)
        {
            let browser = kind == Kind::Browser;
            let field = |which| Sink::Field { window: w.clone(), field: which };
            let sink = match (expectation.target, tab.as_ref()) {
                (Target::AddressBar {}, Some(t)) if browser => {
                    field(FieldKind::AddressBar { tab: t.clone() })
                }
                (Target::FindBar {}, Some(t)) if browser => {
                    field(FieldKind::FindBar { tab: t.clone() })
                }
                (Target::DevTools {}, Some(t)) if browser => Sink::DevTools(t.clone()),
                (Target::Sidebar { .. }, _) => field(FieldKind::Sidebar),
                (Target::SidebarField {}, _) => field(FieldKind::SidebarField),
                (Target::TextField {}, _) => field(FieldKind::TextField),
                _ => sink,
            };
            let seen = seen_expected(&sink, kind);
            return Aimed { sink: Some(sink), tab, seen, expected: true };
        }
        let field = |which| Some(Sink::Field { window: w.clone(), field: which });
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
        let tab = focus.derived.resolved.tab().map(tab);
        Aimed { sink, tab, seen: focused, expected: false }
    }

    /// The tab an expectation names: its id, content sink and kind, from a
    /// window that shows it (this one first), else from its creation.
    fn expected_tab(
        &self,
        focus: &FocusState,
        key: &ExpectationKey,
    ) -> Option<(Option<Arc<str>>, Sink, Kind)> {
        let others = self.windows.iter().map(|(_, f)| f.state());
        if let Some(shown) = std::iter::once(focus).chain(others).find_map(|f| find_tab(f, key)) {
            let sink = tab_sink(&shown)?;
            return Some((Some(Arc::from(shown.id.as_str())), sink, shown.kind));
        }
        let made = self.creations.iter().find(|made| made.key == *key)?;
        let tab = match (key, &made.sink) {
            (ExpectationKey::Tab { id }, _) => Some(Arc::from(id.as_str())),
            (
                ExpectationKey::Surface { .. },
                Sink::Content(t) | Sink::DevTools(t) | Sink::Terminal(TerminalKey::Tab(t)),
            ) => Some(t.clone()),
            (ExpectationKey::Surface { .. }, _) => None,
        };
        Some((tab, made.sink.clone(), made.kind))
    }

    /// The page a bound chord goes to first (the app's `offersToPage`): the
    /// page the key is aimed at, when it is the window's focused browser page,
    /// it reports the keys it leaves unhandled, its window has the keys and it
    /// takes them now.
    fn page_first(
        &self,
        binding: &Binding,
        key: &KeyRecord,
        focus: &FocusState,
        aimed: Option<&Sink>,
    ) -> Option<Sink> {
        let Resolved::BrowserPage { tab, .. } = &focus.derived.resolved else { return None };
        let page = Sink::Content(Arc::from(tab.as_str()));
        let action: &str = &binding.action;
        if aimed != Some(&page)
            || !key.page_reports_unhandled
            || focus.derived.browser_focus_mode_active
            || binding.ghostty
            || DEV_TOOLS.contains(&action)
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
        let reached = key.reaches.as_ref() == Some(&page);
        let takes = self.waits(&page) == 0
            && self.via(&page, key.reaches.as_ref(), false) == Ok(Via::Responder);
        (page_may_own && reached && takes).then_some(page)
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

/// What the binding rules see of the focused target.
fn seen_focused(resolved: &Resolved) -> Seen {
    let chrome_field = matches!(resolved, Resolved::AddressBar { .. } | Resolved::FindBar { .. });
    let dev_tools = matches!(resolved, Resolved::DevTools { .. });
    Seen {
        terminal: matches!(resolved, Resolved::Terminal { .. }),
        text_input: resolved.is_text_input(),
        dev_tools,
        browser: chrome_field || dev_tools || matches!(resolved, Resolved::BrowserPage { .. }),
        chrome_field,
    }
}

/// What the binding rules see of `sink`, expected on a tab of `kind`.
fn seen_expected(sink: &Sink, kind: Kind) -> Seen {
    let (chrome_field, text_field) = match sink {
        Sink::Field { field, .. } => match field {
            FieldKind::AddressBar { .. } | FieldKind::FindBar { .. } => (true, false),
            FieldKind::SidebarField | FieldKind::TextField => (false, true),
            FieldKind::Sidebar => (false, false),
        },
        _ => (false, false),
    };
    let dev_tools = matches!(sink, Sink::DevTools(_));
    Seen {
        terminal: matches!(sink, Sink::Terminal(_)),
        text_input: chrome_field || text_field,
        dev_tools,
        browser: chrome_field
            || dev_tools
            || (matches!(sink, Sink::Content(_)) && kind == Kind::Browser),
        chrome_field,
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
/// `KeyRouter.allows` states it, on what the rules see of the key's target.
fn runs(action: &str, tier: Tier, seen: Seen, mode: bool) -> bool {
    match tier {
        Tier::System if mode => KEPT.contains(&action),
        Tier::System => true,
        Tier::Navigation => !mode,
        Tier::Content if DEV_TOOLS.contains(&action) && seen.browser && !mode => true,
        Tier::Content if CHROME.contains(&action) && seen.chrome_field => true,
        Tier::Content => !mode && !seen.text_input && !seen.dev_tools,
    }
}
