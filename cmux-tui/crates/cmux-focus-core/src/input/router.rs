//! The router: every window's focus, the sinks' facts, the presses, and the
//! one decision per key, made in the key's own call (DESIGN.md section 4.4).
//! Lanes are in `lane`, sink lifetimes in `lifetime`, the binding rules in
//! `binding`; sessions, dialogs and page-first offers have their own modules.

use super::binding::{Class, allows, goes_to_view};
use super::dialog::DialogScope;
use super::key::{Binding, KeyPhase, KeyRecord, WindowRole};
use super::lane::{LaneEntry, LaneLimit};
use super::lifetime::{Creation, Gone};
use super::offer::Offer;
use super::session::{ESCAPE, Session, SessionEnd};
use super::sink::{FieldKind, Sink, TerminalKey};
use super::{
    ConsumeReason, DropReason, GoneReason, InputEffect, InputEvent, InputId, Via, WaitReason,
};
use crate::close_aim::Press as ClosePress;
use crate::event::{FocusEffect, FocusEvent, Source};
use crate::state::{CloseFocusPolicy, Expectation, ExpectationKey, FocusState, Resolved, Target};
use crate::topology::{Kind, Topology};
use crate::window::WindowFocus;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

/// A tab of a window's topology, as the router needs it.
pub(super) struct TabInfo {
    kind: Kind,
    terminal: Option<Arc<str>>,
}

pub(super) struct WindowInput {
    /// The window's focus, as the app's focus handle keeps it (the state, the
    /// address bar memory, the Close Tab aim).
    pub(super) window: WindowFocus,
    /// The tabs of the window's topology, by id (the first tab with an id).
    pub(super) tabs: HashMap<Arc<str>, TabInfo>,
    /// The tab showing each daemon surface (the first one, in layout order).
    surfaces: HashMap<Arc<str>, Arc<str>>,
    /// The pane whose content the keyboard left for a sidebar or text field
    /// by the person's own move: Escape there gives the keyboard back to it.
    return_to: Option<String>,
    /// The pane a focus event's user move leaves from its content, kept while
    /// the event reduces (a buffer reused for each event: no copy per event).
    left_pane: String,
}

impl WindowInput {
    fn new() -> WindowInput {
        WindowInput {
            window: WindowFocus::new(),
            tabs: HashMap::new(),
            surfaces: HashMap::new(),
            return_to: None,
            left_pane: String::new(),
        }
    }

    /// The window's focus state.
    pub(super) fn focus(&self) -> &FocusState {
        self.window.state()
    }

    /// Rebuilds the tab index from the focus topology.
    fn reindex(&mut self) {
        self.tabs.clear();
        self.surfaces.clear();
        for pane in &self.window.state().topology.panes {
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

    /// The tab expectation key `key` names.
    fn tab_of(&self, key: &ExpectationKey) -> Option<(&Arc<str>, &TabInfo)> {
        match key {
            ExpectationKey::Tab { id } => self.tabs.get_key_value(id.as_str()),
            ExpectationKey::Surface { id } => self.tab_of_surface(id),
        }
    }

    /// The window's topology shows the tab `key` names.
    pub(super) fn shows(&self, key: &ExpectationKey) -> bool {
        self.tab_of(key).is_some()
    }
}

/// The content sink of a tab: its terminal, or its content.
pub(super) fn content_sink(tab: &Arc<str>, info: &TabInfo) -> Option<Sink> {
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

/// A focus reduction of a window: an event, or a topology report its caller
/// gives up (the app's focus handle: no copy of it).
enum FocusInput<'a> {
    Event(&'a FocusEvent),
    Topology(Topology),
}

/// Where a press went, so its repeats and release follow it.
#[derive(Clone)]
pub(super) enum Press {
    /// It went to `sink` (taken, or waiting in its lane); `down` is the
    /// key-down's id.
    Sink { sink: Sink, down: InputId },
    /// AppKit's own dispatch took it.
    Platform,
    /// It ran its binding, or a key session took it: a repeat is decided
    /// again.
    Consumed,
    /// It reached nothing (no target, dropped, or its sink ended and its id
    /// names a new sink): its repeats and release reach nothing either.
    Nothing,
    /// It went to a page first (an offer): its release follows it there, and
    /// a repeat is decided again.
    Offered(Sink),
}

/// The sink a key typed now is aimed at, the tab it is for, and the target
/// the binding rules read (none: the window's focused target, and the focus
/// is not on its way to another one).
pub(super) struct Aim {
    pub(super) sink: Option<Sink>,
    tab: Option<Arc<str>>,
    class: Option<Class>,
}

/// What the platform reported about the sinks.
#[derive(Default)]
pub(super) struct Facts {
    /// What AppKit's dispatch of a key typed now reaches.
    pub(super) reaches: Option<Sink>,
    /// Sinks that need readiness and reported it.
    pub(super) ready: HashSet<Sink>,
    /// Tab sinks that ended, until they are new or forgotten.
    pub(super) gone: HashMap<Sink, Gone>,
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
    pub(super) windows: HashMap<Arc<str>, WindowInput>,
    /// Creations by the key their focus expectation waits for, until their
    /// reply.
    pub(super) creations: HashMap<ExpectationKey, Creation>,
    pub(super) facts: Facts,
    pub(super) lanes: HashMap<Sink, VecDeque<LaneEntry>>,
    pub(super) presses: HashMap<(Arc<str>, u16), Press>,
    pub(super) lane_limit: LaneLimit,
    /// The key session that runs (at most one, I5).
    pub(super) session: Option<Session>,
    /// The blocking dialogs, oldest first.
    pub(super) dialogs: Vec<(u64, DialogScope)>,
    /// Keys offered to their page first, oldest first.
    pub(super) offers: VecDeque<Offer>,
    next_id: u64,
    effects: Vec<InputEffect>,
    focus_effects: Vec<FocusEffect>,
}

impl InputRouter {
    /// A router with no window yet; a lane holds at most `lane_limit` entries.
    pub fn new(lane_limit: LaneLimit) -> InputRouter {
        InputRouter {
            windows: HashMap::new(),
            creations: HashMap::new(),
            facts: Facts::default(),
            lanes: HashMap::new(),
            presses: HashMap::new(),
            lane_limit,
            session: None,
            dialogs: Vec::new(),
            offers: VecDeque::new(),
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

    /// A focus event of `window` from the app's focus handle: as
    /// `handle(&InputEvent::Focus { .. })`, without a copy of the event.
    pub fn send_focus(&mut self, window: &str, event: &FocusEvent) -> &[InputEffect] {
        self.focus_input(window, FocusInput::Event(event))
    }

    /// A topology report of `window` from the app's focus handle: as a
    /// `FocusEvent::Topology`, without a copy of the topology. An equal
    /// topology changes nothing (the reducer does not run).
    pub fn set_focus_topology(&mut self, window: &str, topology: Topology) -> &[InputEffect] {
        self.focus_input(window, FocusInput::Topology(topology))
    }

    fn focus_input(&mut self, window: &str, input: FocusInput) -> &[InputEffect] {
        self.effects.clear();
        if let Some(id) = self.windows.get_key_value(window).map(|(id, _)| id.clone()) {
            self.focus_event(&id, input);
            self.drop_left_lanes();
            self.drain();
        }
        &self.effects
    }

    /// The effects of the last call, as it returned them.
    pub fn effects(&self) -> &[InputEffect] {
        &self.effects
    }

    /// `window`'s focus; none for a window that is not open.
    pub fn focus(&self, window: &str) -> Option<&FocusState> {
        self.windows.get(window).map(WindowInput::focus)
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

    // MARK: The app's focus handle (stage S2)
    //
    // The operations of the app's per-window focus handle that are not focus
    // events: they touch neither the topology nor the focus target, so the
    // router's tab index stays as it is. A journal import replaces both, so it
    // reindexes the window.

    /// The focused pane of `window` moved from `from`; the move's serial for
    /// [`InputRouter::frame_presented`] (0 for a window that is not open).
    pub fn pane_moved(&mut self, window: &str, from: Option<&str>) -> u64 {
        self.windows.get_mut(window).map_or(0, |input| input.window.pane_moved(from))
    }

    /// The frame that shows `window`'s move `serial` was presented at `time`.
    pub fn frame_presented(&mut self, window: &str, serial: u64, time: f64) {
        if let Some(input) = self.windows.get_mut(window) {
            input.window.frame_presented(serial, time);
        }
    }

    /// `press` closed the last tab of `pane` in `window`.
    pub fn pane_emptied(&mut self, window: &str, pane: &str, press: ClosePress) {
        if let Some(input) = self.windows.get_mut(window) {
            input.window.pane_emptied(pane, press);
        }
    }

    /// Whether `press` in `window` is aimed at a pane a close emptied.
    pub fn aims_at_emptied_pane(&mut self, window: &str, press: ClosePress) -> bool {
        self.windows.get_mut(window).is_some_and(|input| input.window.aims_at_emptied_pane(press))
    }

    /// `layout.closeFocus` for `window`.
    pub fn set_close_focus(&mut self, window: &str, policy: CloseFocusPolicy) {
        if let Some(input) = self.windows.get_mut(window) {
            input.window.set_close_focus(policy);
        }
    }

    /// Replaces `window`'s focus with a journal checkpoint
    /// (`FocusState::import`) and reindexes its tabs. False when the window is
    /// not open or the JSON does not decode (the focus is kept).
    pub fn import_focus(&mut self, window: &str, json: &[u8]) -> bool {
        let Some(input) = self.windows.get_mut(window) else { return false };
        if !input.window.import(json) {
            return false;
        }
        input.reindex();
        self.track_gone();
        true
    }

    /// Re-derives `window`'s focus after a reduction that panicked part way.
    pub fn rederive_focus(&mut self, window: &str) {
        if let Some(input) = self.windows.get_mut(window) {
            input.window.rederive();
            input.reindex();
        }
    }

    // MARK: Events

    fn apply(&mut self, event: &InputEvent) {
        match event {
            InputEvent::Key(_) => {}
            InputEvent::Focus { window, event } => {
                self.focus_event(window, FocusInput::Event(event));
            }
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
            InputEvent::Creation { key, sink, kind } => self.creation(key, sink, *kind),
            InputEvent::Created { key } => self.creation_done(key),
            InputEvent::CreationFailed { key } => self.creation_failed(key),
            InputEvent::InputSource { composes } => self.facts.composes = *composes,
            InputEvent::SessionStarted { kind, window } => self.start_session(kind, window),
            InputEvent::SessionEnded => self.end_session(SessionEnd::Finished),
            InputEvent::DialogShown { id, scope } => {
                if !self.dialogs.iter().any(|(shown, _)| shown == id) {
                    self.dialogs.push((*id, scope.clone()));
                }
            }
            InputEvent::DialogDismissed { id } => {
                self.dialogs.retain(|(shown, _)| shown != id);
                let reason = DropReason::SinkGone(GoneReason::Closed);
                self.drop_lanes(vec![Sink::Dialog(*id)], reason);
            }
            InputEvent::PageUnhandled { id } => self.page_answered(*id, true),
            InputEvent::PageHandled { id } => self.page_answered(*id, false),
        }
    }

    fn focus_event(&mut self, window: &Arc<str>, focus: FocusInput) {
        let Some(input) = self.windows.get_mut(window) else { return };
        let event = match &focus {
            FocusInput::Event(event) => Some(*event),
            FocusInput::Topology(_) => None,
        };
        // The pane a user move leaves from its content (a buffer, not a copy
        // of the state, per event).
        input.left_pane.clear();
        let left = match (event.is_some_and(is_user_move), &input.window.state().derived.resolved) {
            (true, before) if is_content(before) => {
                before.pane().map(|pane| input.left_pane.push_str(pane)).is_some()
            }
            _ => false,
        };
        // The app's focus handle's reduction: a topology takes the fast path,
        // and the address bar memory notes every reduction.
        let (reduction, topology) = match focus {
            FocusInput::Event(event) => (
                input.window.send(event, &mut self.focus_effects),
                matches!(event, FocusEvent::Topology { .. }),
            ),
            FocusInput::Topology(topology) => {
                (input.window.set_topology(topology, &mut self.focus_effects), true)
            }
        };
        for effect in self.focus_effects.drain(..) {
            self.effects.push(InputEffect::Focus { window: window.clone(), effect });
        }
        self.effects.push(InputEffect::FocusReduced { window: window.clone(), reduction });
        if !is_return_field(&input.focus().derived.resolved) {
            input.return_to = None;
        } else if left {
            input.return_to = Some(input.left_pane.clone());
        }
        // Every topology report judges the sinks that ended (`track_gone`); an equal one did not run the
        // reducer, so the tabs it shows, and their index, are the same.
        if topology {
            if reduction.ran {
                input.reindex();
            }
            self.track_gone();
        }
        self.session_after_focus(window, event);
    }

    fn close_window(&mut self, window: &Arc<str>) {
        if self.windows.remove(window).is_none() {
            return;
        }
        if self.session.as_ref().is_some_and(|session| session.window == *window) {
            self.end_session(SessionEnd::WindowClosed);
        }
        self.presses.retain(|(pressed, _), _| pressed != window);
        let closed: Vec<Sink> =
            self.lanes.keys().filter(|sink| sink.window() == Some(window)).cloned().collect();
        self.drop_lanes(closed, DropReason::WindowClosed);
        self.track_gone();
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
        let follows = ConsumeReason::FollowsConsumedPress;
        match key.phase {
            KeyPhase::Up => match self.presses.remove(&slot) {
                Some(Press::Sink { sink, .. } | Press::Offered(sink)) => {
                    self.release_to(id, key, sink);
                }
                Some(Press::Consumed | Press::Nothing) => {
                    self.push(InputEffect::Consumed { id, reason: follows });
                }
                Some(Press::Platform) | None => self.push(InputEffect::Platform { id }),
            },
            KeyPhase::Repeat => match self.presses.get(&slot).cloned() {
                Some(Press::Sink { sink, .. }) => {
                    self.route_to(id, key, sink);
                }
                Some(Press::Platform) => self.push(InputEffect::Platform { id }),
                Some(Press::Nothing) => self.push(InputEffect::Consumed { id, reason: follows }),
                // A repeat of a press its page got first is decided again; its
                // release still goes to that page, which got the key-down.
                Some(Press::Offered(page)) => {
                    let press = match self.decide(id, key) {
                        offered @ Press::Offered(_) => offered,
                        _ => Press::Offered(page),
                    };
                    self.presses.insert(slot, press);
                }
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
        self.end_session_of_other_window(key);
        // A blocking dialog over the key's target takes a key with no Command
        // or Control before any session or binding (the session keeps running).
        if let Some(dialog) = self.dialog_first(key) {
            return self.press_to(id, key, Sink::Dialog(dialog));
        }
        if self.session_takes(id, key) {
            return Press::Consumed;
        }
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
                Some(sink) => self.press_to(id, key, sink),
                None => {
                    self.push(InputEffect::Platform { id });
                    Press::Platform
                }
            };
        }
        let aim = self.aim_in(window_id, window);
        // Only a Command or Control chord gets here with a dialog that blocks its
        // target (dialog_first took every other key): it runs its binding
        // (Cmd-W closes the tab and its dialog), else it is the dialog's.
        let dialog = self.dialog_for(window_id, aim.sink.as_ref());
        if let Some(binding) = &key.binding {
            let focus = window.focus();
            // The rules read the key's own target: the tab the focus is on its
            // way to, else the focused target. Copy mode is the focused
            // terminal's, never a new one's.
            let (class, copy_mode) = match aim.class {
                Some(class) => (class, false),
                None => (Class::of(&focus.derived.resolved), key.terminal_copy_mode),
            };
            let focus_mode = focus.derived.browser_focus_mode_active;
            if !goes_to_view(binding, class, copy_mode) && allows(binding, class, focus_mode) {
                if dialog.is_none()
                    && let Some(page) = self.offer_target(binding, key, focus, aim.sink.as_ref())
                {
                    self.offer(id, binding, page.clone(), aim.tab);
                    return Press::Offered(page);
                }
                // Under a dialog, an action that edits an input edits the
                // dialog's (and names no tab).
                let (input, tab) = match dialog {
                    Some(dialog) => {
                        let tab = if binding.edits_input { None } else { aim.tab };
                        (Some(Sink::Dialog(dialog)), tab)
                    }
                    None => (aim.sink, aim.tab),
                };
                self.run(id, binding, input, tab, key.reaches.as_ref());
                return Press::Consumed;
            }
        }
        if let Some(dialog) = dialog {
            return self.press_to(id, key, Sink::Dialog(dialog));
        }
        if let Some(pane) = self.returns_focus(window_id, key, aim.sink.as_ref()) {
            let window = window_id.clone();
            let event = FocusEvent::FocusPane { pane, workspace: None, source: Source::Keyboard };
            self.focus_event(&window, FocusInput::Event(&event));
            // The field's waiting keys can no longer reach it.
            self.drop_left_lanes();
            self.push(InputEffect::Consumed { id, reason: ConsumeReason::ReturnedFocus });
            return Press::Nothing;
        }
        match aim.sink {
            Some(sink) => self.press_to(id, key, sink),
            None => {
                self.push(InputEffect::Consumed { id, reason: ConsumeReason::NoTarget });
                Press::Nothing
            }
        }
    }

    /// Runs `binding` for key `id` now. An action that edits the input
    /// `input` waits in its lane instead when `input` cannot take input now or
    /// keys typed before it wait there (a Paste before a page's first paint,
    /// a Paste behind typing), and keeps its place there; for an input that
    /// ended it is dropped with the input's reason, like a key.
    fn run(
        &mut self,
        id: InputId,
        binding: &Binding,
        input: Option<Sink>,
        tab: Option<Arc<str>>,
        reaches: Option<&Sink>,
    ) {
        let action = binding.action.clone();
        if binding.edits_input
            && let Some(sink) = input
        {
            if let Some(reason) = self.ended(&sink) {
                self.push(InputEffect::Dropped { id, reason: DropReason::SinkGone(reason) });
                return;
            }
            let wait = if self.lanes.get(&sink).is_some_and(|lane| !lane.is_empty()) {
                Some(WaitReason::BehindQueued)
            } else {
                self.deliverable(&sink, reaches, false).err()
            };
            if let Some(reason) = wait {
                self.enqueue(sink, LaneEntry::Run { id, action, tab }, reason);
                return;
            }
        }
        self.push(InputEffect::Run { id, action, tab });
    }

    /// A press goes to `sink`; its repeats and release follow it, unless it
    /// was dropped.
    fn press_to(&mut self, id: InputId, key: &KeyRecord, sink: Sink) -> Press {
        if self.route_to(id, key, sink.clone()) {
            Press::Sink { sink, down: id }
        } else {
            Press::Nothing
        }
    }

    /// Key `id` (a press or a repeat) goes to `sink`, or waits in its lane.
    /// False: it was dropped.
    fn route_to(&mut self, id: InputId, key: &KeyRecord, sink: Sink) -> bool {
        if let Some(reason) = self.ended(&sink) {
            self.push(InputEffect::Dropped { id, reason: DropReason::SinkGone(reason) });
            return false;
        }
        let text = key.is_text();
        if self.lanes.get(&sink).is_some_and(|lane| !lane.is_empty()) {
            return self.enqueue(sink, LaneEntry::Key { id, text }, WaitReason::BehindQueued);
        }
        match self.deliverable(&sink, key.reaches.as_ref(), text) {
            Ok(via) => {
                self.push(InputEffect::Deliver { id, sink, via });
                true
            }
            Err(reason) => self.enqueue(sink, LaneEntry::Key { id, text }, reason),
        }
    }

    /// The release `id` of a press that went to `sink`: after its press when
    /// that still waits, else to the sink when it can take it now; a sink
    /// that cannot take it now needs no release.
    fn release_to(&mut self, id: InputId, key: &KeyRecord, sink: Sink) {
        if let Some(reason) = self.ended(&sink) {
            self.push(InputEffect::Dropped { id, reason: DropReason::SinkGone(reason) });
            return;
        }
        if self.lanes.get(&sink).is_some_and(|lane| !lane.is_empty()) {
            self.enqueue(sink, LaneEntry::Key { id, text: false }, WaitReason::BehindQueued);
            return;
        }
        match self.deliverable(&sink, key.reaches.as_ref(), false) {
            Ok(via) => self.push(InputEffect::Deliver { id, sink, via }),
            Err(_) => {
                self.push(InputEffect::Consumed { id, reason: ConsumeReason::ReleaseNotTaken });
            }
        }
    }

    /// How a key reaches `sink` now, or why it waits: a dialog blocks it, or
    /// the sink's facts say ([`Facts::deliverable`]).
    pub(super) fn deliverable(
        &self,
        sink: &Sink,
        reaches: Option<&Sink>,
        text: bool,
    ) -> Result<Via, WaitReason> {
        if self.is_blocked(sink) {
            return Err(WaitReason::Blocked);
        }
        self.facts.deliverable(sink, reaches, text)
    }

    /// The pane Escape gives the keyboard back to: a bare Escape aimed at a
    /// sidebar or text field the person moved into from that pane's content,
    /// when the field does not use Escape itself.
    fn returns_focus(
        &self,
        window: &Arc<str>,
        key: &KeyRecord,
        sink: Option<&Sink>,
    ) -> Option<String> {
        let m = key.modifiers;
        if key.code != ESCAPE
            || m.command
            || m.control
            || m.option
            || m.shift
            || key.field_uses_escape
        {
            return None;
        }
        let Some(Sink::Field { field: FieldKind::SidebarField | FieldKind::TextField, .. }) = sink
        else {
            return None;
        };
        let input = self.windows.get(window)?;
        let pane = input.return_to.as_ref()?;
        input.focus().topology.contains_pane(pane).then(|| pane.clone())
    }

    pub(super) fn push(&mut self, effect: InputEffect) {
        self.effects.push(effect);
    }

    // MARK: Aim

    /// The sink a key typed now in `window` is aimed at: an open overlay, else
    /// the tab the focus is on its way to (a creation's, a drop's), else the
    /// focused target.
    pub(super) fn aim_in(&self, window_id: &Arc<str>, window: &WindowInput) -> Aim {
        let focus = window.focus();
        if let Some(top) = focus.overlays.last() {
            return Aim {
                sink: Some(Sink::Overlay { window: window_id.clone(), overlay: *top }),
                tab: None,
                class: None,
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

    /// The target an expectation waits for, on the tab it names: in any
    /// window's topology (a tab moving between windows), else its creation's.
    /// A chrome target only on a browser tab, as the focus reducer keeps it.
    fn expected(&self, window_id: &Arc<str>, expectation: &Expectation) -> Option<Aim> {
        let shown = self
            .windows
            .get(window_id)
            .into_iter()
            .chain(self.windows.values())
            .find_map(|window| window.tab_of(&expectation.key));
        let (tab, content, kind) = match shown {
            Some((tab, info)) => (Some(tab.clone()), content_sink(tab, info)?, info.kind),
            None => {
                let creation = self.creations.get(&expectation.key)?;
                (creation.tab.clone(), creation.sink.clone(), creation.kind)
            }
        };
        let field = |which| Sink::Field { window: window_id.clone(), field: which };
        let chrome = kind == Kind::Browser;
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
        let class = Class::expected(&sink, kind);
        Some(Aim { sink: Some(sink), tab, class: Some(class) })
    }

    fn resolved_aim(&self, window_id: &Arc<str>, window: &WindowInput, resolved: &Resolved) -> Aim {
        let tab = resolved.tab().map(|tab| match window.tabs.get_key_value(tab) {
            Some((shared, _)) => shared.clone(),
            None => Arc::<str>::from(tab),
        });
        let field = |which| Some(Sink::Field { window: window_id.clone(), field: which });
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
        Aim { sink, tab, class: None }
    }
}

/// A sidebar field or another text field of the window: Escape there may give
/// the keyboard back to the content it came from.
fn is_return_field(resolved: &Resolved) -> bool {
    matches!(resolved, Resolved::SidebarField {} | Resolved::TextField {})
}

/// A tab's content has the keyboard.
fn is_content(resolved: &Resolved) -> bool {
    matches!(
        resolved,
        Resolved::Terminal { .. }
            | Resolved::BrowserPage { .. }
            | Resolved::AgentPage { .. }
            | Resolved::Page { .. }
            | Resolved::Conversation { .. }
    )
}

/// The person moved the focus (a click, a key, the palette), not the app.
pub(super) fn is_user_move(event: &FocusEvent) -> bool {
    match event {
        FocusEvent::FocusPane { source, .. }
        | FocusEvent::SelectTab { source, .. }
        | FocusEvent::FocusTarget { source, .. }
        | FocusEvent::Responder { source, .. } => source.is_user_intent(),
        _ => false,
    }
}
