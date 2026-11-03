//! The model-based fuzz (DESIGN.md section 4.9): seeded random sequences of
//! keys, clicks, creations, closes, page readiness, dispatch changes, overlays,
//! input sources and windows, run through the router and the reference model
//! together. After every event the router's effects must keep the ledger's
//! invariants, and every key's state and every sink's deliveries must equal
//! the model's. At the end every page becomes ready, the input source stops
//! composing and the windows close: no key may still wait.
//!
//! `CMUX_INPUT_FUZZ_CASES` (default 400) and `CMUX_INPUT_FUZZ_LEN` (160)
//! change the run; `CMUX_INPUT_FUZZ_SEED` replays one case. A failure prints
//! its seed and its shrunk event list. Each mutant (a router with one rule
//! broken, as a bug of the old key paths broke it) must be caught.

use super::model::{Ending, Model, State};
use cmux_focus_core::event::{FocusEvent, Source};
use cmux_focus_core::input::ledger::Ledger;
use cmux_focus_core::input::{
    Binding, DialogScope, FieldKind, GoneReason, InputEffect, InputEvent, InputId, InputRouter,
    KeyPhase, KeyRecord, Modifiers, SessionEnd, SessionKind, Sink, TerminalKey, Tier, WindowRole,
};
use cmux_focus_core::state::{ExpectationKey, Overlay, Target};
use cmux_focus_core::topology::{Kind, Pane, Tab, Topology};
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

pub(super) fn env(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// splitmix64: deterministic for a seed on every platform.
struct Rng(u64);

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next_u64() % n as u64) as usize }
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.next_u64() % 100 < percent
    }
}

// MARK: The world

struct WorldPane {
    id: String,
    tabs: Vec<Tab>,
    selected: usize,
}

struct WorldWindow {
    id: String,
    open: bool,
    workspace: String,
    panes: Vec<WorldPane>,
}

struct Creation {
    key: ExpectationKey,
    window: usize,
    tab: Tab,
    new_pane: bool,
}

/// What the generator believes the app shows, to make events that make sense.
struct World {
    rng: Rng,
    windows: Vec<WorldWindow>,
    counter: u32,
    creations: Vec<Creation>,
    pages: Vec<String>,
    pressed: Vec<KeyRecord>,
    reaches: Option<Sink>,
    queue: VecDeque<InputEvent>,
    /// Dialogs shown, by id.
    dialogs: Vec<u64>,
}

/// The letters of the key codes the fuzz types: a, b, c, d, e.
const LETTERS: [(u16, char); 5] = [(0, 'a'), (11, 'b'), (8, 'c'), (2, 'd'), (14, 'e')];

fn arc(text: &str) -> Arc<str> {
    Arc::from(text)
}

fn terminal_tab(id: &str, host: &str) -> Tab {
    Tab { id: id.into(), surface: None, kind: Kind::Terminal, terminal: Some(host.into()) }
}

fn page_tab(id: &str, kind: Kind) -> Tab {
    Tab { id: id.into(), surface: None, kind, terminal: None }
}

fn sink_of(tab: &Tab) -> Sink {
    match &tab.terminal {
        Some(host) if tab.kind == Kind::Terminal => Sink::Terminal(TerminalKey::Host(arc(host))),
        _ if tab.kind == Kind::Terminal => Sink::Terminal(TerminalKey::Tab(arc(&tab.id))),
        _ => Sink::Content(arc(&tab.id)),
    }
}

impl World {
    fn new(seed: u64) -> World {
        let mut world = World {
            rng: Rng(seed),
            windows: Vec::new(),
            counter: 0,
            creations: Vec::new(),
            pages: Vec::new(),
            pressed: Vec::new(),
            reaches: None,
            queue: VecDeque::new(),
            dialogs: Vec::new(),
        };
        let w1 = vec![
            WorldPane { id: "p1".into(), tabs: vec![terminal_tab("t1", "T1")], selected: 0 },
            WorldPane { id: "p2".into(), tabs: vec![page_tab("b1", Kind::Browser)], selected: 0 },
        ];
        let w2 = vec![
            WorldPane { id: "q1".into(), tabs: vec![terminal_tab("t2", "T2")], selected: 0 },
            WorldPane {
                id: "q2".into(),
                tabs: vec![page_tab("c1", Kind::Conversation)],
                selected: 0,
            },
        ];
        world.windows.push(WorldWindow {
            id: "w1".into(),
            open: false,
            workspace: "ws1".into(),
            panes: w1,
        });
        world.windows.push(WorldWindow {
            id: "w2".into(),
            open: false,
            workspace: "ws2".into(),
            panes: w2,
        });
        world.pages = vec!["b1".into(), "c1".into()];
        for index in 0..2 {
            world.open(index);
        }
        if world.rng.chance(50) {
            world.queue.push_back(InputEvent::Ready { sink: Sink::Content(arc("b1")) });
        }
        world.queue.push_back(InputEvent::Ready { sink: Sink::Content(arc("c1")) });
        world.dispatch(Some(Sink::Terminal(TerminalKey::Host(arc("T1")))));
        world
    }

    fn fresh(&mut self, prefix: &str) -> String {
        self.counter = self.counter.wrapping_add(1);
        format!("{prefix}{}", self.counter)
    }

    fn open(&mut self, index: usize) {
        let Some(window) = self.windows.get_mut(index) else { return };
        window.open = true;
        let id = arc(&window.id);
        let first = window.panes.first().map(|pane| pane.id.clone());
        self.queue.push_back(InputEvent::WindowOpened { window: id.clone() });
        self.topology(index);
        if let Some(pane) = first {
            let event = FocusEvent::FocusPane { pane, workspace: None, source: Source::Keyboard };
            self.queue.push_back(InputEvent::Focus { window: id, event });
        }
    }

    fn topology(&mut self, index: usize) {
        let Some(window) = self.windows.get(index) else { return };
        let panes = window
            .panes
            .iter()
            .map(|pane| Pane {
                id: pane.id.clone(),
                tabs: pane.tabs.clone(),
                selected: pane.tabs.get(pane.selected).map(|tab| tab.id.clone()),
            })
            .collect();
        let topology = Topology::new(Some(window.workspace.clone()), panes, Vec::new());
        self.queue.push_back(InputEvent::Focus {
            window: arc(&window.id),
            event: FocusEvent::Topology { topology },
        });
    }

    fn dispatch(&mut self, reaches: Option<Sink>) {
        self.reaches.clone_from(&reaches);
        self.queue.push_back(InputEvent::Dispatch { reaches });
    }

    fn open_windows(&self) -> Vec<usize> {
        (0..self.windows.len()).filter(|i| self.windows.get(*i).is_some_and(|w| w.open)).collect()
    }

    /// An open window, the first one most of the time.
    fn some_window(&mut self) -> Option<usize> {
        let open = self.open_windows();
        if open.first() == Some(&0) && self.rng.chance(75) {
            return Some(0);
        }
        let pick = self.rng.below(open.len());
        open.get(pick).copied()
    }

    /// Every sink the app could name now, with a field or two.
    fn some_sink(&mut self) -> Option<Sink> {
        let mut sinks: Vec<Sink> = Vec::new();
        for window in &self.windows {
            for pane in &window.panes {
                for tab in &pane.tabs {
                    sinks.push(sink_of(tab));
                    if tab.kind == Kind::Browser {
                        sinks.push(Sink::Field {
                            window: arc(&window.id),
                            field: FieldKind::AddressBar { tab: arc(&tab.id) },
                        });
                    }
                }
            }
            sinks.push(Sink::Field { window: arc(&window.id), field: FieldKind::SidebarField });
            sinks.push(Sink::Field { window: arc(&window.id), field: FieldKind::Sidebar });
        }
        for creation in &self.creations {
            sinks.push(sink_of(&creation.tab));
        }
        let pick = self.rng.below(sinks.len());
        sinks.get(pick).cloned()
    }

    fn reaches_for(&mut self, window: &str, model: &Model) -> Option<Sink> {
        match self.rng.below(100) {
            0..50 => model.aim(window),
            50..75 => self.reaches.clone(),
            75..85 => None,
            _ => self.some_sink(),
        }
    }

    fn key(
        &mut self,
        window: usize,
        model: &Model,
        code: u16,
        modifiers: Modifiers,
        binding: Option<Binding>,
    ) -> KeyRecord {
        let id = self.windows.get(window).map_or_else(|| arc("w1"), |w| arc(&w.id));
        let reaches = self.reaches_for(&id, model);
        let role = match self.rng.below(100) {
            0..4 => WindowRole::Overlay,
            4..8 => WindowRole::Other,
            _ => WindowRole::Main,
        };
        let letter = LETTERS.iter().find(|(c, _)| *c == code).map(|(_, l)| *l);
        let letter =
            letter.filter(|_| !(modifiers.command || modifiers.control || modifiers.option));
        KeyRecord {
            window: id,
            role,
            phase: KeyPhase::Down,
            code,
            modifiers,
            timestamp_ns: 0,
            composing: self.rng.chance(3),
            terminal_copy_mode: self.rng.chance(20),
            reaches,
            binding,
            letter,
            page_editing_chord: modifiers.command && self.rng.chance(40),
            field_uses_escape: code == 53 && self.rng.chance(30),
        }
    }

    fn press(&mut self, record: KeyRecord) {
        self.pressed.retain(|held| held.window != record.window || held.code != record.code);
        self.pressed.push(record.clone());
        self.queue.push_back(InputEvent::Key(record));
    }

    fn command(action: &str, tier: Tier, edits_input: bool) -> (Modifiers, Option<Binding>) {
        let binding = Binding { action: arc(action), tier, ghostty: false, edits_input };
        (Modifiers { command: true, ..Modifiers::default() }, Some(binding))
    }

    /// The focused pane of `window` in the model.
    fn focused_pane(&self, window: usize, model: &Model) -> Option<usize> {
        let id = &self.windows.get(window)?.id;
        let pane = model.focus(id)?.pane.clone()?;
        self.windows.get(window)?.panes.iter().position(|p| p.id == pane)
    }

    /// A creation the person asked for in `window`: its stand-in shows now or later.
    fn create(&mut self, window: usize, model: &Model, tab: Tab, new_pane: bool) {
        let Some(id) = self.windows.get(window).map(|w| arc(&w.id)) else { return };
        let key = ExpectationKey::Tab { id: tab.id.clone() };
        self.queue.push_back(InputEvent::Creation { key: key.clone(), sink: sink_of(&tab) });
        let generation = model.focus(&id).map_or(0, |f| f.generation).wrapping_add(1);
        self.queue
            .push_back(InputEvent::Focus { window: id.clone(), event: FocusEvent::BeginIntent {} });
        let expect = FocusEvent::Expect {
            key: key.clone(),
            target: Target::Content {},
            away_from: None,
            generation,
        };
        self.queue.push_back(InputEvent::Focus { window: id, event: expect });
        if tab.kind != Kind::Terminal {
            self.pages.push(tab.id.clone());
        }
        let creation = Creation { key, window, tab, new_pane };
        if self.rng.chance(60) {
            self.show(creation, model);
        } else {
            self.creations.push(creation);
        }
    }

    fn show(&mut self, creation: Creation, model: &Model) {
        let focused = self.focused_pane(creation.window, model);
        let fresh = self.fresh("x");
        let Some(window) = self.windows.get_mut(creation.window) else { return };
        if !window.open {
            return;
        }
        if creation.new_pane || window.panes.is_empty() {
            let at =
                focused.map_or(window.panes.len(), |i| i.saturating_add(1).min(window.panes.len()));
            window.panes.insert(at, WorldPane { id: fresh, tabs: vec![creation.tab], selected: 0 });
        } else {
            let index = focused.unwrap_or(0).min(window.panes.len().saturating_sub(1));
            if let Some(pane) = window.panes.get_mut(index) {
                pane.tabs.push(creation.tab);
                pane.selected = pane.tabs.len().saturating_sub(1);
            }
        }
        self.topology(creation.window);
    }

    /// The next event, made against the model's state now.
    fn next(&mut self, model: &Model) -> InputEvent {
        while self.queue.is_empty() {
            self.act(model);
        }
        self.queue.pop_front().unwrap_or(InputEvent::InputSource { composes: false })
    }

    fn act(&mut self, model: &Model) {
        let Some(window) = self.some_window() else {
            if let Some(closed) =
                (0..self.windows.len()).find(|i| self.windows.get(*i).is_some_and(|w| !w.open))
            {
                self.open(closed);
            }
            return;
        };
        let roll = self.rng.below(100);
        match roll {
            0..30 => {
                let code = [0u16, 11, 8, 2, 14, 36, 51, 53][self.rng.below(8)];
                let modifiers = Modifiers { shift: self.rng.chance(10), ..Modifiers::default() };
                let record = self.key(window, model, code, modifiers, None);
                self.press(record);
            }
            30..40 => {
                if self.pressed.is_empty() {
                    return;
                }
                let index = self.rng.below(self.pressed.len());
                let held = self.pressed.remove(index);
                let reaches = self.reaches_for(&held.window, model);
                self.queue.push_back(InputEvent::Key(KeyRecord {
                    phase: KeyPhase::Up,
                    reaches,
                    ..held
                }));
            }
            40..44 => {
                let Some(held) = self.pressed.last().cloned() else { return };
                let reaches = self.reaches_for(&held.window, model);
                self.queue.push_back(InputEvent::Key(KeyRecord {
                    phase: KeyPhase::Repeat,
                    reaches,
                    ..held
                }));
            }
            44..47 => {
                let modifiers = Modifiers { control: true, ..Modifiers::default() };
                let record = self.key(window, model, 8, modifiers, None);
                self.press(record);
            }
            47..52 => {
                let (modifiers, binding) = World::command("newSplit", Tier::Navigation, false);
                let record = self.key(window, model, 2, modifiers, binding);
                self.press(record);
                let id = self.fresh("s");
                let host = self.fresh("T");
                self.create(window, model, terminal_tab(&id, &host), true);
            }
            52..55 => {
                let (modifiers, binding) =
                    World::command("newTerminalTab", Tier::Navigation, false);
                let record = self.key(window, model, 50, modifiers, binding);
                self.press(record);
                let id = self.fresh("s");
                let host = self.fresh("T");
                let new_pane = self.rng.chance(30);
                self.create(window, model, terminal_tab(&id, &host), new_pane);
            }
            55..58 => {
                let (modifiers, binding) = World::command("newTab", Tier::Navigation, false);
                let record = self.key(window, model, 17, modifiers, binding);
                self.press(record);
                let id = self.fresh("b");
                let new_pane = self.rng.chance(50);
                self.create(window, model, page_tab(&id, Kind::Browser), new_pane);
            }
            58..62 => self.close(window, model),
            62..68 => {
                if let Some(page) = self.pages.get(self.rng.below(self.pages.len())).cloned() {
                    self.queue.push_back(InputEvent::Ready { sink: Sink::Content(arc(&page)) });
                }
            }
            68..70 => {
                if let Some(page) = self.pages.get(self.rng.below(self.pages.len())).cloned() {
                    self.queue.push_back(InputEvent::Pending { sink: Sink::Content(arc(&page)) });
                }
            }
            70..76 => self.click(window),
            76..78 => {
                let (modifiers, binding) =
                    World::command("focusBrowserAddressBar", Tier::Navigation, false);
                let record = self.key(window, model, 37, modifiers, binding);
                self.press(record);
                let event = FocusEvent::FocusTarget {
                    target: Target::AddressBar {},
                    source: Source::Keyboard,
                };
                let id = arc(&self.windows.get(window).map_or("w1".into(), |w| w.id.clone()));
                self.queue.push_back(InputEvent::Focus { window: id, event });
            }
            78..82 => {
                if !self.creations.is_empty() {
                    let creation = self.creations.remove(self.rng.below(self.creations.len()));
                    self.show(creation, model);
                }
            }
            82..83 => {
                if !self.creations.is_empty() {
                    let creation = self.creations.remove(self.rng.below(self.creations.len()));
                    self.queue.push_back(InputEvent::CreationFailed { key: creation.key });
                }
            }
            83..87 => {
                let reaches = if self.rng.chance(50) {
                    let id = self.windows.get(window).map_or("w1".into(), |w| w.id.clone());
                    model.aim(&id)
                } else {
                    self.some_sink()
                };
                self.dispatch(reaches);
            }
            87..89 => {
                let id = arc(&self.windows.get(window).map_or("w1".into(), |w| w.id.clone()));
                let open = model.focus(&id).is_some_and(|f| !f.overlays.is_empty());
                let event = if open {
                    FocusEvent::OverlayClosed { overlay: Overlay::Palette }
                } else {
                    FocusEvent::OverlayOpened { overlay: Overlay::Palette }
                };
                self.queue.push_back(InputEvent::Focus { window: id, event });
            }
            89..91 => {
                let (modifiers, binding) = World::command("paste", Tier::Content, true);
                let record = self.key(window, model, 9, modifiers, binding);
                self.press(record);
            }
            91..92 => {
                let (action, tier, code) = match self.rng.below(3) {
                    0 => ("find", Tier::Navigation, 3),
                    1 => ("browserReload", Tier::Content, 15),
                    _ => ("toggleSidebar", Tier::Navigation, 11),
                };
                let (modifiers, binding) = World::command(action, tier, false);
                let record = self.key(window, model, code, modifiers, binding);
                self.press(record);
            }
            92..94 => {
                let binding = Binding {
                    action: arc("goToSplit"),
                    tier: Tier::Navigation,
                    ghostty: true,
                    edits_input: false,
                };
                let modifiers = Modifiers { command: true, control: true, ..Modifiers::default() };
                let record = self.key(window, model, 4, modifiers, Some(binding));
                self.press(record);
            }
            94..95 => {
                let composes = self.rng.chance(50);
                self.queue.push_back(InputEvent::InputSource { composes });
            }
            95 => self.s1b(window, model),
            96..97 => {
                let id = arc(&self.windows.get(window).map_or("w1".into(), |w| w.id.clone()));
                let target = if self.rng.chance(50) {
                    Target::SidebarField {}
                } else {
                    Target::TextField {}
                };
                self.queue.push_back(InputEvent::Focus {
                    window: id.clone(),
                    event: FocusEvent::FocusTarget { target, source: Source::Mouse },
                });
                if self.rng.chance(60) {
                    let field = if target == (Target::SidebarField {}) {
                        FieldKind::SidebarField
                    } else {
                        FieldKind::TextField
                    };
                    self.dispatch(Some(Sink::Field { window: id, field }));
                }
            }
            97..98 => self.s1b(window, model),
            98..99 => {
                if let Some(second) = self.windows.get(1).map(|w| w.open) {
                    if second {
                        if let Some(w) = self.windows.get_mut(1) {
                            w.open = false;
                        }
                        self.queue.push_back(InputEvent::WindowClosed { window: arc("w2") });
                    } else {
                        self.open(1);
                    }
                }
            }
            _ => self.swap_stand_in(window),
        }
    }

    /// A session, a dialog or a page's report (stage S1b's events).
    fn s1b(&mut self, window: usize, model: &Model) {
        let Some(id) = self.windows.get(window).map(|w| arc(&w.id)) else { return };
        match self.rng.below(9) {
            0 | 1 => {
                // Link hints on the focused page, or (when none) on a random page tab.
                let tab = match model.aim(&id) {
                    Some(Sink::Content(tab)) => tab,
                    _ => match self.pages.get(self.rng.below(self.pages.len())) {
                        Some(page) => arc(page),
                        None => return,
                    },
                };
                self.queue.push_back(InputEvent::SessionStarted {
                    kind: SessionKind::LinkHints { tab },
                    window: id,
                });
            }
            2 => {
                let kind = if self.rng.chance(50) {
                    SessionKind::WindowHints
                } else {
                    SessionKind::Recorder
                };
                self.queue.push_back(InputEvent::SessionStarted { kind, window: id });
            }
            3 => self.queue.push_back(InputEvent::SessionEnded),
            4 | 5 => {
                let dialog = u64::from(self.counter.wrapping_add(1000));
                self.counter = self.counter.wrapping_add(1);
                let scope = match model.focus(&id).and_then(|f| f.derived.resolved.tab().map(arc)) {
                    Some(tab) if self.rng.chance(60) => DialogScope::Tab { window: id, tab },
                    _ => DialogScope::Window(id),
                };
                self.dialogs.push(dialog);
                self.queue.push_back(InputEvent::DialogShown { id: dialog, scope });
            }
            6 => {
                if !self.dialogs.is_empty() {
                    let dialog = self.dialogs.remove(self.rng.below(self.dialogs.len()));
                    self.queue.push_back(InputEvent::DialogDismissed { id: dialog });
                }
            }
            _ => {
                // The page reports an offered key unhandled (sometimes one that is not offered).
                let offered = model.offered();
                let id = match offered.get(self.rng.below(offered.len().max(1))) {
                    Some(id) if self.rng.chance(85) => *id,
                    _ => self.rng.next_u64() % 64,
                };
                self.queue.push_back(InputEvent::PageUnhandled { id: InputId(id) });
            }
        }
    }

    fn click(&mut self, window: usize) {
        let Some(w) = self.windows.get(window) else { return };
        if w.panes.is_empty() {
            return;
        }
        let index = self.rng.below(w.panes.len());
        let Some(pane) = w.panes.get(index) else { return };
        let id = arc(&w.id);
        let event =
            FocusEvent::FocusPane { pane: pane.id.clone(), workspace: None, source: Source::Mouse };
        let shown = pane.tabs.get(pane.selected).map(sink_of);
        self.queue.push_back(InputEvent::Focus { window: id, event });
        if self.rng.chance(70) {
            self.dispatch(shown);
        }
    }

    /// Cmd-W: the focused tab leaves the strip in the key's turn; its sink ends
    /// before or after.
    fn close(&mut self, window: usize, model: &Model) {
        let (modifiers, binding) = World::command("closeTab", Tier::System, false);
        let record = self.key(window, model, 13, modifiers, binding);
        self.press(record);
        let Some(pane) = self.focused_pane(window, model) else { return };
        let Some(w) = self.windows.get_mut(window) else { return };
        let Some(p) = w.panes.get_mut(pane) else { return };
        if p.tabs.is_empty() {
            return;
        }
        let closed = p.tabs.remove(p.selected.min(p.tabs.len().saturating_sub(1)));
        p.selected = p.selected.min(p.tabs.len().saturating_sub(1));
        if p.tabs.is_empty() {
            w.panes.remove(pane);
        }
        let gone = InputEvent::Gone { sink: sink_of(&closed), reason: GoneReason::Closed };
        if self.rng.chance(30) {
            self.queue.push_back(gone);
            self.topology(window);
        } else {
            self.topology(window);
            self.queue.push_back(gone);
        }
    }

    /// The daemon's tab replaces a stand-in tab (same terminal, new id).
    fn swap_stand_in(&mut self, window: usize) {
        let fresh = self.fresh("d");
        let Some(w) = self.windows.get_mut(window) else { return };
        let mut swapped = false;
        for pane in &mut w.panes {
            if let Some(tab) = pane.tabs.iter_mut().find(|t| t.id.starts_with('s')) {
                tab.id = fresh;
                swapped = true;
                break;
            }
        }
        if swapped {
            self.topology(window);
        }
    }

    /// The end of a run: every page ready, no input method, every window
    /// closed. Nothing may wait after it.
    fn finale(&self, router_waiting: &[Sink]) -> Vec<InputEvent> {
        let mut events =
            vec![InputEvent::InputSource { composes: false }, InputEvent::SessionEnded];
        for dialog in &self.dialogs {
            events.push(InputEvent::DialogDismissed { id: *dialog });
        }
        for page in &self.pages {
            events.push(InputEvent::Ready { sink: Sink::Content(arc(page)) });
        }
        for sink in router_waiting {
            if sink.needs_ready() {
                events.push(InputEvent::Ready { sink: sink.clone() });
            }
        }
        for window in &self.windows {
            events.push(InputEvent::WindowClosed { window: arc(&window.id) });
        }
        events
    }
}

// MARK: Running a case

/// A router under test: the real one or a mutant.
pub(super) trait Under {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect>;
    fn waiting(&self) -> Vec<Sink>;
}

struct Real(InputRouter);

impl Under for Real {
    fn handle(&mut self, event: &InputEvent) -> Vec<InputEffect> {
        self.0.handle(event).to_vec()
    }

    fn waiting(&self) -> Vec<Sink> {
        self.0.waiting().map(|(sink, _)| sink.clone()).collect()
    }
}

/// What the router's effects say about every key, and its session ends.
#[derive(Default)]
struct Tracker {
    states: HashMap<u64, State>,
    deliveries: HashMap<Sink, Vec<u64>>,
    session_ends: Vec<(SessionKind, SessionEnd)>,
}

impl Tracker {
    fn note(&mut self, effect: &InputEffect) {
        let (id, state) = match effect {
            InputEffect::Deliver { id, sink, via } => {
                self.deliveries.entry(sink.clone()).or_default().push(id.0);
                (id, State::Ended(Ending::Delivered(sink.clone(), *via)))
            }
            InputEffect::Offer { id, sink, .. } => {
                self.deliveries.entry(sink.clone()).or_default().push(id.0);
                (id, State::Ended(Ending::Offered(sink.clone())))
            }
            InputEffect::Run { id, .. } => (id, State::Ended(Ending::Ran)),
            InputEffect::Queued { id, sink, .. } => (id, State::Waiting(sink.clone())),
            InputEffect::Consumed { id, reason } => (id, State::Ended(Ending::Consumed(*reason))),
            InputEffect::Dropped { id, reason } => (id, State::Ended(Ending::Dropped(*reason))),
            InputEffect::Platform { id } => (id, State::Ended(Ending::Platform)),
            InputEffect::SessionKey { id, key } => (id, State::Ended(Ending::Session(*key))),
            InputEffect::SessionEnded { kind, reason } => {
                self.session_ends.push((kind.clone(), *reason));
                return;
            }
            InputEffect::Focus { .. } => return,
        };
        self.states.insert(id.0, state);
    }
}

#[derive(Debug)]
pub(super) struct Failure {
    step: usize,
    why: String,
}

/// Runs `events` through `under` and the model; the first difference or
/// broken invariant.
pub(super) fn check(events: &[InputEvent], under: &mut dyn Under) -> Result<(), Failure> {
    let mut model = Model::new();
    let mut ledger = Ledger::new();
    let mut tracker = Tracker::default();
    for (step, event) in events.iter().enumerate() {
        let effects = under.handle(event);
        ledger.call(event, &effects);
        for effect in &effects {
            tracker.note(effect);
        }
        model.step(event);
        if let Some(violation) = ledger.violations().first() {
            return Err(Failure { step, why: format!("invariant: {violation:?}") });
        }
        let expected = model.states();
        if tracker.states != expected {
            let mut ids: Vec<u64> = expected.keys().chain(tracker.states.keys()).copied().collect();
            ids.sort_unstable();
            ids.dedup();
            let id = ids.into_iter().find(|id| tracker.states.get(id) != expected.get(id));
            let detail = id.map(|id| {
                format!(
                    "key {id}: router {:?}, model {:?}",
                    tracker.states.get(&id),
                    expected.get(&id)
                )
            });
            return Err(Failure {
                step,
                why: format!("state differs: {}", detail.unwrap_or_default()),
            });
        }
        if tracker.session_ends != model.session_ends {
            return Err(Failure {
                step,
                why: format!(
                    "session ends differ: router {:?}, model {:?}",
                    tracker.session_ends, model.session_ends
                ),
            });
        }
        if tracker.deliveries != model.deliveries {
            return Err(Failure {
                step,
                why: format!(
                    "deliveries differ: router {:?}, model {:?}",
                    tracker.deliveries, model.deliveries
                ),
            });
        }
    }
    let waiting = ledger.waiting();
    if !waiting.is_empty() {
        return Err(Failure {
            step: events.len(),
            why: format!("keys still wait at the end: {waiting:?}"),
        });
    }
    Ok(())
}

/// The events of case `seed`, made against a model run alongside, with the
/// finale.
pub(super) fn generate(
    seed: u64,
    len: usize,
    make: &dyn Fn() -> Box<dyn Under>,
) -> Vec<InputEvent> {
    let mut world = World::new(seed);
    let mut model = Model::new();
    let mut under = make();
    let mut events = Vec::with_capacity(len);
    for _ in 0..len {
        let event = world.next(&model);
        under.handle(&event);
        model.step(&event);
        events.push(event);
    }
    let finale = world.finale(&under.waiting());
    events.extend(finale);
    events
}

/// The smallest sub-list of `events` that still fails (delta debugging).
fn shrink(mut events: Vec<InputEvent>, make: &dyn Fn() -> Box<dyn Under>) -> Vec<InputEvent> {
    let mut chunk = events.len() / 2;
    while chunk > 0 {
        let mut start = 0;
        while start < events.len() {
            let end = (start + chunk).min(events.len());
            let candidate: Vec<InputEvent> =
                events[..start].iter().chain(&events[end..]).cloned().collect();
            if check(&candidate, &mut *make()).is_err() {
                events = candidate;
            } else {
                start = end;
            }
        }
        chunk /= 2;
    }
    events
}

/// Runs `cases` seeded cases from `first`; the first failure, shrunk.
fn fuzz(first: u64, cases: u64, len: usize, make: &dyn Fn() -> Box<dyn Under>) -> Option<String> {
    for seed in first..first.saturating_add(cases) {
        let events = generate(seed, len, make);
        if let Err(failure) = check(&events, &mut *make()) {
            let shrunk = shrink(events, make);
            let again = check(&shrunk, &mut *make()).err();
            return Some(format!(
                "seed {seed} failed at step {}: {}\nshrunk ({} events, {again:?}):\n{shrunk:#?}",
                failure.step,
                failure.why,
                shrunk.len(),
            ));
        }
    }
    None
}

/// Makes a fresh router under test.
pub(super) type Make = fn() -> Box<dyn Under>;

pub(super) fn real() -> Box<dyn Under> {
    Box::new(Real(InputRouter::new()))
}

#[test]
fn the_router_matches_the_reference_model() {
    let len = env("CMUX_INPUT_FUZZ_LEN", 160) as usize;
    let (first, cases) =
        match std::env::var("CMUX_INPUT_FUZZ_SEED").ok().and_then(|v| v.parse().ok()) {
            Some(seed) => (seed, 1),
            None => (1, env("CMUX_INPUT_FUZZ_CASES", 400)),
        };
    if let Some(report) = fuzz(first, cases, len, &real) {
        panic!("{report}");
    }
}
