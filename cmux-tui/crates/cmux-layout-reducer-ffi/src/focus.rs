//! The window focus machine's C ABI (`cmux_focus_*`): one handle per window
//! owns `cmux-focus-core`'s state. The app sends small typed events and a
//! topology only when it changed, and reads a typed reply the handle owns:
//! no JSON and no copy of the whole state per event, no output buffer per
//! call. JSON is only for the input journal (checkpoints, replay).
//!
//! Strings in a request are `CmuxFocusStr` ranges into the call's string
//! bytes; in a reply, ranges into the reply's `strings`. An absent string
//! has `offset == CMUX_FOCUS_NONE`. The enum values are the header's
//! `CMUX_FOCUS_*` constants.

use cmux_focus_core::event::{DragOutcome, FocusEffect, FocusEvent, Responder, Source};
use cmux_focus_core::reducer;
use cmux_focus_core::state::{
    CloseFocusPolicy, Context, ExpectationKey, FocusState, Overlay, Resolved, Target,
};
use cmux_focus_core::topology::{Column, Kind, Pane, Tab, Topology};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const NONE: u32 = u32::MAX;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxFocusStr {
    pub offset: u32,
    pub len: u32,
}

impl CmuxFocusStr {
    pub const ABSENT: CmuxFocusStr = CmuxFocusStr { offset: NONE, len: 0 };
}

#[repr(C)]
pub struct CmuxFocusEvent {
    pub kind: u8,
    pub source: u8,
    pub target: u8,
    pub target_keyboard: u8,
    pub value: u8,
    pub reserved: [u8; 3],
    pub list_count: u32,
    pub reserved2: u32,
    pub generation: u64,
    pub a: CmuxFocusStr,
    pub b: CmuxFocusStr,
    pub c: CmuxFocusStr,
    pub list: *const CmuxFocusStr,
}

#[repr(C)]
pub struct CmuxFocusTab {
    pub id: CmuxFocusStr,
    pub surface: CmuxFocusStr,
    pub kind: u32,
    pub reserved: u32,
}

#[repr(C)]
pub struct CmuxFocusPane {
    pub id: CmuxFocusStr,
    pub selected: CmuxFocusStr,
    pub tab_start: u32,
    pub tab_count: u32,
}

#[repr(C)]
pub struct CmuxFocusColumn {
    pub id: CmuxFocusStr,
    pub screen: u32,
    pub pane_start: u32,
    pub pane_count: u32,
    pub reserved: u32,
}

#[repr(C)]
pub struct CmuxFocusTopology {
    pub workspace: CmuxFocusStr,
    pub panes: *const CmuxFocusPane,
    pub tabs: *const CmuxFocusTab,
    pub columns: *const CmuxFocusColumn,
    pub column_panes: *const CmuxFocusStr,
    pub pane_count: u32,
    pub tab_count: u32,
    pub column_count: u32,
    pub column_pane_count: u32,
    pub screen_count: u32,
    pub reserved: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxFocusResolved {
    pub kind: u8,
    pub overlay: u8,
    pub reserved: [u8; 6],
    pub pane: CmuxFocusStr,
    pub tab: CmuxFocusStr,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxFocusEffect {
    pub kind: u8,
    pub context: u8,
    pub active: u8,
    pub reserved: [u8; 5],
    pub pane: CmuxFocusStr,
    pub tab: CmuxFocusStr,
    pub resolved: CmuxFocusResolved,
}

#[repr(C)]
pub struct CmuxFocusReply {
    pub ok: u8,
    pub changed: u8,
    pub window_key: u8,
    pub app_active: u8,
    pub sidebar_hidden: u8,
    pub target: u8,
    pub target_keyboard: u8,
    pub context: u8,
    pub browser_focus_mode_active: u8,
    pub dragging: u8,
    pub has_expectation: u8,
    pub expectation_key: u8,
    pub expectation_target: u8,
    pub expectation_target_keyboard: u8,
    pub reserved: [u8; 2],
    pub generation: u64,
    pub expectation_generation: u64,
    pub pane: CmuxFocusStr,
    pub workspace: CmuxFocusStr,
    pub expectation_id: CmuxFocusStr,
    pub expectation_away_from: CmuxFocusStr,
    pub resolved: CmuxFocusResolved,
    pub underlying: CmuxFocusResolved,
    pub overlays: *const u8,
    pub effects: *const CmuxFocusEffect,
    pub strings: *const u8,
    pub overlay_count: u32,
    pub effect_count: u32,
    pub strings_len: u32,
    pub reserved2: u32,
}

#[repr(C)]
pub struct CmuxFocusStrings {
    pub items: *const CmuxFocusStr,
    pub bytes: *const u8,
    pub count: u32,
    pub bytes_len: u32,
}

/// What the reply describes, to tell whether a reduction changed it.
#[derive(Clone, PartialEq, Default)]
struct Summary {
    pane: Option<String>,
    workspace: Option<String>,
    target: Option<Target>,
    overlays: Vec<Overlay>,
    flags: [bool; 5],
    generation: u64,
    expectation: Option<(ExpectationKey, Target, Option<String>, u64)>,
    derived: Option<cmux_focus_core::state::Derived>,
}

impl Summary {
    fn of(state: &FocusState) -> Summary {
        Summary {
            pane: state.pane.clone(),
            workspace: state.topology.workspace.clone(),
            target: Some(state.target),
            overlays: state.overlays.clone(),
            flags: [
                state.window_key,
                state.app_active,
                state.sidebar_hidden,
                state.drag.is_some(),
                state.derived.browser_focus_mode_active,
            ],
            generation: state.generation,
            expectation: state
                .expectation
                .as_ref()
                .map(|e| (e.key.clone(), e.target, e.away_from.clone(), e.generation)),
            derived: Some(state.derived.clone()),
        }
    }
}

/// One window's focus machine and the reply it last wrote.
pub struct Focus {
    state: FocusState,
    effects: Vec<FocusEffect>,
    summary: Summary,
    strings: Vec<u8>,
    overlays: Vec<u8>,
    c_effects: Vec<CmuxFocusEffect>,
    reply: CmuxFocusReply,
    list: Vec<CmuxFocusStr>,
    list_bytes: Vec<u8>,
    list_reply: CmuxFocusStrings,
}

const fn empty_resolved() -> CmuxFocusResolved {
    CmuxFocusResolved {
        kind: 13,
        overlay: 0,
        reserved: [0; 6],
        pane: CmuxFocusStr::ABSENT,
        tab: CmuxFocusStr::ABSENT,
    }
}

impl Focus {
    pub fn new() -> Focus {
        let mut focus = Focus {
            state: FocusState::default(),
            effects: Vec::new(),
            summary: Summary::default(),
            strings: Vec::new(),
            overlays: Vec::new(),
            c_effects: Vec::new(),
            reply: CmuxFocusReply {
                ok: 0,
                changed: 0,
                window_key: 0,
                app_active: 0,
                sidebar_hidden: 0,
                target: 0,
                target_keyboard: 0,
                context: 0,
                browser_focus_mode_active: 0,
                dragging: 0,
                has_expectation: 0,
                expectation_key: 0,
                expectation_target: 0,
                expectation_target_keyboard: 0,
                reserved: [0; 2],
                generation: 0,
                expectation_generation: 0,
                pane: CmuxFocusStr::ABSENT,
                workspace: CmuxFocusStr::ABSENT,
                expectation_id: CmuxFocusStr::ABSENT,
                expectation_away_from: CmuxFocusStr::ABSENT,
                resolved: empty_resolved(),
                underlying: empty_resolved(),
                overlays: std::ptr::null(),
                effects: std::ptr::null(),
                strings: std::ptr::null(),
                overlay_count: 0,
                effect_count: 0,
                strings_len: 0,
                reserved2: 0,
            },
            list: Vec::new(),
            list_bytes: Vec::new(),
            list_reply: CmuxFocusStrings {
                items: std::ptr::null(),
                bytes: std::ptr::null(),
                count: 0,
                bytes_len: 0,
            },
        };
        focus.state.derive();
        focus.summary = Summary::of(&focus.state);
        focus.write_reply(true);
        focus
    }

    pub fn state(&self) -> &FocusState {
        &self.state
    }

    /// Reduces `event`; the reply says whether the focus changed.
    pub fn send(&mut self, event: &FocusEvent) -> &CmuxFocusReply {
        let ran = reducer::reduce(&mut self.state, event, &mut self.effects);
        self.finish(ran)
    }

    /// A topology report; an equal topology returns at once.
    pub fn set_topology(&mut self, topology: Topology) -> &CmuxFocusReply {
        let ran = reducer::set_topology(&mut self.state, topology, &mut self.effects);
        self.finish(ran)
    }

    pub fn set_close_focus(&mut self, policy: CloseFocusPolicy) {
        self.state.close_focus = policy;
    }

    /// Replaces the state with a journal checkpoint.
    pub fn import(&mut self, json: &[u8]) -> bool {
        match FocusState::import(json) {
            Ok(state) => {
                self.state = state;
                self.effects.clear();
                self.summary = Summary::of(&self.state);
                self.write_reply(true);
                true
            }
            Err(_) => false,
        }
    }

    /// The current reply (no event): after `import`, or on creation.
    pub fn current(&mut self) -> &CmuxFocusReply {
        self.effects.clear();
        self.summary = Summary::of(&self.state);
        self.write_reply(true);
        &self.reply
    }

    /// A reduction panicked part way: the state may have changed. Re-derive
    /// it (the fast paths read `derived`) and report it as it is now, with
    /// `ok` 0 and no effects.
    fn recover(&mut self) -> &CmuxFocusReply {
        self.state.derive();
        self.current();
        self.reply.ok = 0;
        &self.reply
    }

    pub fn fail(&mut self) -> &CmuxFocusReply {
        self.reply.ok = 0;
        self.reply.changed = 0;
        self.reply.effect_count = 0;
        &self.reply
    }

    fn finish(&mut self, ran: bool) -> &CmuxFocusReply {
        if !ran {
            // Nothing changed: the last reply's fields still hold.
            self.reply.ok = 1;
            self.reply.changed = 0;
            self.reply.effect_count = 0;
            return &self.reply;
        }
        let summary = Summary::of(&self.state);
        let changed = summary != self.summary;
        if changed || !self.effects.is_empty() {
            self.summary = summary;
            self.write_reply(changed);
        } else {
            self.reply.ok = 1;
            self.reply.changed = 0;
            self.reply.effect_count = 0;
        }
        &self.reply
    }

    fn write_reply(&mut self, changed: bool) {
        self.strings.clear();
        self.overlays.clear();
        self.c_effects.clear();
        let state = &self.state;
        let strings = &mut self.strings;
        let mut put = |text: Option<&str>| -> CmuxFocusStr {
            match text {
                None => CmuxFocusStr::ABSENT,
                Some(text) => {
                    let offset = strings.len() as u32;
                    strings.extend_from_slice(text.as_bytes());
                    CmuxFocusStr { offset, len: text.len() as u32 }
                }
            }
        };
        let pane = put(state.pane.as_deref());
        let workspace = put(state.topology.workspace.as_deref());
        let resolved = encode_resolved(&state.derived.resolved, &mut put);
        let underlying = encode_resolved(&state.derived.underlying, &mut put);
        let (expectation_id, expectation_away_from) = match &state.expectation {
            Some(e) => {
                let id = match &e.key {
                    ExpectationKey::Surface { id } | ExpectationKey::Tab { id } => id.as_str(),
                };
                (put(Some(id)), put(e.away_from.as_deref()))
            }
            None => (CmuxFocusStr::ABSENT, CmuxFocusStr::ABSENT),
        };
        for effect in &self.effects {
            let mut out = CmuxFocusEffect {
                kind: 0,
                context: 0,
                active: 0,
                reserved: [0; 5],
                pane: CmuxFocusStr::ABSENT,
                tab: CmuxFocusStr::ABSENT,
                resolved: empty_resolved(),
            };
            match effect {
                FocusEffect::Select { pane, tab } => {
                    out.pane = put(Some(pane));
                    out.tab = put(Some(tab));
                }
                FocusEffect::RevealPane { pane } => {
                    out.kind = 1;
                    out.pane = put(Some(pane));
                }
                FocusEffect::MoveResponder { resolved } => {
                    out.kind = 2;
                    out.resolved = encode_resolved(resolved, &mut put);
                }
                FocusEffect::PublishContext { context } => {
                    out.kind = 3;
                    out.context = context_bits(*context);
                }
                FocusEffect::BrowserFocusMode { tab, active } => {
                    out.kind = 4;
                    out.tab = put(Some(tab));
                    out.active = u8::from(*active);
                }
            }
            self.c_effects.push(out);
        }
        self.overlays.extend(state.overlays.iter().map(|o| overlay_code(*o)));
        let (target, target_keyboard) = target_code(state.target);
        let expectation = state.expectation.as_ref();
        let reply = &mut self.reply;
        reply.ok = 1;
        reply.changed = u8::from(changed);
        reply.window_key = u8::from(state.window_key);
        reply.app_active = u8::from(state.app_active);
        reply.sidebar_hidden = u8::from(state.sidebar_hidden);
        reply.target = target;
        reply.target_keyboard = target_keyboard;
        reply.context = context_bits(state.derived.context);
        reply.browser_focus_mode_active = u8::from(state.derived.browser_focus_mode_active);
        reply.dragging = u8::from(state.drag.is_some());
        reply.has_expectation = u8::from(expectation.is_some());
        reply.expectation_key =
            expectation.map_or(0, |e| u8::from(matches!(e.key, ExpectationKey::Tab { .. })));
        let (expectation_target, expectation_target_keyboard) =
            expectation.map_or((0, 0), |e| target_code(e.target));
        reply.expectation_target = expectation_target;
        reply.expectation_target_keyboard = expectation_target_keyboard;
        reply.expectation_generation = expectation.map_or(0, |e| e.generation);
        reply.generation = state.generation;
        reply.pane = pane;
        reply.workspace = workspace;
        reply.expectation_id = expectation_id;
        reply.expectation_away_from = expectation_away_from;
        reply.resolved = resolved;
        reply.underlying = underlying;
        reply.overlays = self.overlays.as_ptr();
        reply.overlay_count = self.overlays.len() as u32;
        reply.effects = self.c_effects.as_ptr();
        reply.effect_count = self.c_effects.len() as u32;
        reply.strings = self.strings.as_ptr();
        reply.strings_len = self.strings.len() as u32;
    }

    /// The focus history of `workspace` (none: the shown one), newest first.
    pub fn recent_panes(&mut self, workspace: Option<&str>) -> &CmuxFocusStrings {
        self.list.clear();
        self.list_bytes.clear();
        let state = &self.state;
        let recent = match workspace {
            Some(workspace) => state.history.get(workspace).map_or(&[][..], Vec::as_slice),
            None => state.recent_panes(),
        };
        for pane in recent {
            push(&mut self.list, &mut self.list_bytes, pane);
        }
        self.finish_list()
    }

    /// The last focused pane of each workspace: workspace, pane, workspace,
    /// pane, ... (a window record save; not per event).
    pub fn remembered(&mut self) -> &CmuxFocusStrings {
        self.list.clear();
        self.list_bytes.clear();
        for (workspace, pane) in &self.state.remembered {
            push(&mut self.list, &mut self.list_bytes, workspace);
            push(&mut self.list, &mut self.list_bytes, pane);
        }
        self.finish_list()
    }

    fn finish_list(&mut self) -> &CmuxFocusStrings {
        self.list_reply = CmuxFocusStrings {
            items: self.list.as_ptr(),
            bytes: self.list_bytes.as_ptr(),
            count: self.list.len() as u32,
            bytes_len: self.list_bytes.len() as u32,
        };
        &self.list_reply
    }
}

fn push(list: &mut Vec<CmuxFocusStr>, bytes: &mut Vec<u8>, text: &str) {
    let offset = bytes.len() as u32;
    bytes.extend_from_slice(text.as_bytes());
    list.push(CmuxFocusStr { offset, len: text.len() as u32 });
}

impl Default for Focus {
    fn default() -> Self {
        Focus::new()
    }
}

// MARK: Codes

fn context_bits(context: Context) -> u8 {
    u8::from(context.terminal) | (u8::from(context.browser) << 1) | (u8::from(context.agent) << 2)
}

fn overlay_code(overlay: Overlay) -> u8 {
    match overlay {
        Overlay::Palette => 0,
        Overlay::Sheet => 1,
        Overlay::Rename => 2,
        Overlay::GroupEditor => 3,
    }
}

fn overlay_of(code: u8) -> Option<Overlay> {
    Some(match code {
        0 => Overlay::Palette,
        1 => Overlay::Sheet,
        2 => Overlay::Rename,
        3 => Overlay::GroupEditor,
        _ => return None,
    })
}

fn target_code(target: Target) -> (u8, u8) {
    match target {
        Target::Content {} => (0, 0),
        Target::AddressBar {} => (1, 0),
        Target::FindBar {} => (2, 0),
        Target::DevTools {} => (3, 0),
        Target::Sidebar { keyboard } => (4, u8::from(keyboard)),
        Target::SidebarField {} => (5, 0),
        Target::TextField {} => (6, 0),
        Target::None {} => (7, 0),
    }
}

fn target_of(code: u8, keyboard: u8) -> Option<Target> {
    Some(match code {
        0 => Target::Content {},
        1 => Target::AddressBar {},
        2 => Target::FindBar {},
        3 => Target::DevTools {},
        4 => Target::Sidebar { keyboard: keyboard != 0 },
        5 => Target::SidebarField {},
        6 => Target::TextField {},
        7 => Target::None {},
        _ => return None,
    })
}

fn source_of(code: u8) -> Option<Source> {
    Some(match code {
        0 => Source::Mouse,
        1 => Source::Keyboard,
        2 => Source::Cli,
        3 => Source::Palette,
        4 => Source::Programmatic,
        _ => return None,
    })
}

fn kind_of(code: u32) -> Option<Kind> {
    Some(match code {
        0 => Kind::Terminal,
        1 => Kind::Browser,
        2 => Kind::Agent,
        3 => Kind::Page,
        4 => Kind::Conversation,
        5 => Kind::Other,
        _ => return None,
    })
}

fn encode_resolved(
    resolved: &Resolved,
    put: &mut impl FnMut(Option<&str>) -> CmuxFocusStr,
) -> CmuxFocusResolved {
    let mut out = empty_resolved();
    let (kind, pane, tab): (u8, Option<&str>, Option<&str>) = match resolved {
        Resolved::Terminal { pane, tab } => (0, Some(pane), Some(tab)),
        Resolved::BrowserPage { pane, tab } => (1, Some(pane), Some(tab)),
        Resolved::AddressBar { pane, tab } => (2, Some(pane), Some(tab)),
        Resolved::FindBar { pane, tab } => (3, Some(pane), Some(tab)),
        Resolved::DevTools { pane, tab } => (4, Some(pane), Some(tab)),
        Resolved::AgentPage { pane, tab } => (5, Some(pane), Some(tab)),
        Resolved::Page { pane, tab } => (6, Some(pane), Some(tab)),
        Resolved::Conversation { pane, tab } => (7, Some(pane), Some(tab)),
        Resolved::EmptyPane { pane } => (8, Some(pane), None),
        Resolved::Sidebar {} => (9, None, None),
        Resolved::SidebarField {} => (10, None, None),
        Resolved::TextField {} => (11, None, None),
        Resolved::Overlay { overlay } => {
            out.overlay = overlay_code(*overlay);
            (12, None, None)
        }
        Resolved::None {} => (13, None, None),
    };
    out.kind = kind;
    out.pane = put(pane);
    out.tab = put(tab);
    out
}

// MARK: Decoding

/// The request's string bytes.
struct Strings<'a>(&'a [u8]);

impl Strings<'_> {
    fn get(&self, range: CmuxFocusStr) -> Result<Option<String>, ()> {
        if range.offset == NONE {
            return Ok(None);
        }
        let start = range.offset as usize;
        let end = start.checked_add(range.len as usize).ok_or(())?;
        let bytes = self.0.get(start..end).ok_or(())?;
        std::str::from_utf8(bytes).map(|text| Some(text.to_owned())).map_err(|_| ())
    }

    fn required(&self, range: CmuxFocusStr) -> Result<String, ()> {
        self.get(range)?.ok_or(())
    }
}

/// `count` items at `ptr` (null only with a zero count).
///
/// # Safety
///
/// `ptr` points to `count` readable items, or `count` is 0.
unsafe fn items<'a, T>(ptr: *const T, count: u32) -> Result<&'a [T], ()> {
    if count == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(());
    }
    // SAFETY: guaranteed by the C caller.
    Ok(unsafe { std::slice::from_raw_parts(ptr, count as usize) })
}

/// # Safety
///
/// The event's `list` points to `list_count` items (or the count is 0).
unsafe fn decode_event(event: &CmuxFocusEvent, strings: &[u8]) -> Result<FocusEvent, ()> {
    let s = Strings(strings);
    let source = || source_of(event.source).ok_or(());
    let target = || target_of(event.target, event.target_keyboard).ok_or(());
    let list = || -> Result<Vec<String>, ()> {
        // SAFETY: the caller's contract.
        let ranges = unsafe { items(event.list, event.list_count) }?;
        ranges.iter().map(|r| s.required(*r)).collect()
    };
    Ok(match event.kind {
        0 => FocusEvent::FocusPane {
            pane: s.required(event.a)?,
            workspace: s.get(event.c)?,
            source: source()?,
        },
        1 => FocusEvent::SelectTab {
            pane: s.required(event.a)?,
            tab: s.required(event.b)?,
            workspace: s.get(event.c)?,
            source: source()?,
        },
        2 => FocusEvent::FocusTarget { target: target()?, source: source()? },
        3 => {
            let pane = || s.required(event.a);
            let responder = match event.value {
                0 => Responder::Content { pane: pane()? },
                1 => Responder::AddressBar { pane: pane()? },
                2 => Responder::FindBar { pane: pane()? },
                3 => Responder::DevTools { pane: pane()? },
                4 => Responder::Sidebar {},
                5 => Responder::SidebarField {},
                6 => Responder::TextField {},
                7 => Responder::WindowOrNone {},
                _ => return Err(()),
            };
            FocusEvent::Responder { responder, source: source()? }
        }
        4 => FocusEvent::WindowKey { key: event.value != 0 },
        5 => FocusEvent::AppActive { active: event.value != 0 },
        6 => FocusEvent::OverlayOpened { overlay: overlay_of(event.value).ok_or(())? },
        7 => FocusEvent::OverlayClosed { overlay: overlay_of(event.value).ok_or(())? },
        8 => FocusEvent::BeginIntent {},
        9 => {
            let id = s.required(event.a)?;
            let key = match event.value {
                0 => ExpectationKey::Surface { id },
                1 => ExpectationKey::Tab { id },
                _ => return Err(()),
            };
            FocusEvent::Expect {
                key,
                target: target()?,
                away_from: s.get(event.b)?,
                generation: event.generation,
            }
        }
        10 => FocusEvent::DragBegan { tabs: list()?, pane: s.required(event.a)? },
        11 => {
            let outcome = match event.value {
                0 => DragOutcome::Cancelled {},
                1 => DragOutcome::Dropped { tabs: list()?, away_from: s.get(event.b)? },
                2 => DragOutcome::MovedAway {},
                _ => return Err(()),
            };
            FocusEvent::DragEnded { outcome }
        }
        12 => FocusEvent::ContentPresented { pane: s.required(event.a)? },
        13 => FocusEvent::ToggleBrowserFocusMode { tab: s.get(event.a)? },
        14 => FocusEvent::SidebarVisibility { hidden: event.value != 0 },
        15 => {
            FocusEvent::RestoredPane { pane: s.required(event.a)?, workspace: s.required(event.c)? }
        }
        _ => return Err(()),
    })
}

/// # Safety
///
/// Every pointer of `topology` points to its count of readable items (or the
/// count is 0).
unsafe fn decode_topology(topology: &CmuxFocusTopology, strings: &[u8]) -> Result<Topology, ()> {
    let s = Strings(strings);
    // SAFETY: the caller's contract.
    let (panes, tabs, columns, column_panes) = unsafe {
        (
            items(topology.panes, topology.pane_count)?,
            items(topology.tabs, topology.tab_count)?,
            items(topology.columns, topology.column_count)?,
            items(topology.column_panes, topology.column_pane_count)?,
        )
    };
    let mut out_panes = Vec::with_capacity(panes.len());
    for pane in panes {
        let start = pane.tab_start as usize;
        let end = start.checked_add(pane.tab_count as usize).ok_or(())?;
        let pane_tabs = tabs.get(start..end).ok_or(())?;
        let mut out_tabs = Vec::with_capacity(pane_tabs.len());
        for tab in pane_tabs {
            out_tabs.push(Tab {
                id: s.required(tab.id)?,
                surface: s.get(tab.surface)?,
                kind: kind_of(tab.kind).ok_or(())?,
            });
        }
        out_panes.push(Pane {
            id: s.required(pane.id)?,
            tabs: out_tabs,
            selected: s.get(pane.selected)?,
        });
    }
    // A screen holds at least one column, but an empty screen is allowed:
    // bound the count so a bad one cannot make a huge allocation.
    if topology.screen_count > topology.column_count.saturating_add(64) {
        return Err(());
    }
    let mut screens: Vec<Vec<Column>> = (0..topology.screen_count).map(|_| Vec::new()).collect();
    for column in columns {
        let start = column.pane_start as usize;
        let end = start.checked_add(column.pane_count as usize).ok_or(())?;
        let ids = column_panes.get(start..end).ok_or(())?;
        let panes = ids.iter().map(|r| s.required(*r)).collect::<Result<Vec<_>, _>>()?;
        screens
            .get_mut(column.screen as usize)
            .ok_or(())?
            .push(Column { id: s.required(column.id)?, panes });
    }
    Ok(Topology::new(s.get(topology.workspace)?, out_panes, screens))
}

// MARK: C ABI

/// # Safety
///
/// `ptr` points to `len` readable bytes, or `len` is 0.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// A new focus machine (one per window). Free it with `cmux_focus_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_focus_new() -> *mut Focus {
    Box::into_raw(Box::new(Focus::new()))
}

/// # Safety
///
/// `focus` is null or a live handle from `cmux_focus_new`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_free(focus: *mut Focus) {
    if !focus.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(focus) });
    }
}

/// Reduces one event. The reply stays valid until the next `cmux_focus_*`
/// call on the same handle. Null for a null handle or event.
///
/// # Safety
///
/// `focus` is a live handle used by one thread, `event` is readable, its
/// `list` points to `list_count` items, and `strings` points to
/// `strings_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_send(
    focus: *mut Focus,
    event: *const CmuxFocusEvent,
    strings: *const u8,
    strings_len: usize,
) -> *const CmuxFocusReply {
    if focus.is_null() || event.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle, used by one thread; a readable event.
    let (focus, event) = unsafe { (&mut *focus, &*event) };
    // SAFETY: this function's contract gives `strings_len` readable bytes at `strings`, which is
    // what `bytes` requires (it refuses a null pointer itself); the slice is used only during this
    // call.
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else { return focus.fail() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        let event = unsafe { decode_event(event, strings) }?;
        focus.send(&event);
        Ok::<(), ()>(())
    }));
    match result {
        Ok(Ok(())) => &focus.reply,
        Ok(Err(())) => focus.fail(),
        Err(_) => focus.recover(),
    }
}

/// Reports the shown workspace's topology. A topology equal to the current
/// one changes nothing (reply `changed` 0, no effects).
///
/// # Safety
///
/// As `cmux_focus_send`; every array of `topology` holds its count of items.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_set_topology(
    focus: *mut Focus,
    topology: *const CmuxFocusTopology,
    strings: *const u8,
    strings_len: usize,
) -> *const CmuxFocusReply {
    if focus.is_null() || topology.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle, used by one thread; a readable topology.
    let (focus, topology) = unsafe { (&mut *focus, &*topology) };
    // SAFETY: this function's contract gives `strings_len` readable bytes at `strings`, which is
    // what `bytes` requires (it refuses a null pointer itself); the slice is used only during this
    // call.
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else { return focus.fail() };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        let topology = unsafe { decode_topology(topology, strings) }?;
        focus.set_topology(topology);
        Ok::<(), ()>(())
    }));
    match result {
        Ok(Ok(())) => &focus.reply,
        Ok(Err(())) => focus.fail(),
        Err(_) => focus.recover(),
    }
}

/// The current state as a reply (`changed` 1, no effects).
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_current(focus: *mut Focus) -> *const CmuxFocusReply {
    if focus.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.current()
}

/// `layout.closeFocus`: 0 previous neighbor, 1 most recent.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_set_close_focus(focus: *mut Focus, policy: u8) {
    if focus.is_null() {
        return;
    }
    let policy =
        if policy == 1 { CloseFocusPolicy::MostRecent } else { CloseFocusPolicy::PreviousNeighbor };
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.set_close_focus(policy);
}

/// 1 when `event` moves focus or selection on purpose (`FocusEvent::changes_view`),
/// 0 when not or when it does not decode.
///
/// # Safety
///
/// As `cmux_focus_send` for `event` and `strings`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_changes_view(
    event: *const CmuxFocusEvent,
    strings: *const u8,
    strings_len: usize,
) -> u8 {
    if event.is_null() {
        return 0;
    }
    // SAFETY: this function's contract gives `strings_len` readable bytes at `strings`, which is
    // what `bytes` requires (it refuses a null pointer itself); the slice is used only during this
    // call.
    let Some(strings) = (unsafe { bytes(strings, strings_len) }) else { return 0 };
    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller's contract.
        unsafe { decode_event(&*event, strings) }.map_or(0, |e| u8::from(e.changes_view()))
    }))
    .unwrap_or(0)
}

/// The focus history of `workspace` (`has_workspace` 0: the shown one),
/// newest first. Valid until the next `cmux_focus_*` call on the handle.
///
/// # Safety
///
/// `focus` is a live handle used by one thread; `workspace` points to
/// `workspace_len` readable bytes (or the length is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_recent_panes(
    focus: *mut Focus,
    workspace: *const u8,
    workspace_len: usize,
    has_workspace: u8,
) -> *const CmuxFocusStrings {
    if focus.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    let workspace = if has_workspace == 0 {
        None
    } else {
        // SAFETY: this function's contract gives `workspace_len` readable bytes at `workspace` when
        // `has_workspace` is set, which is what `bytes` requires; the text is copied before return.
        match unsafe { bytes(workspace, workspace_len) }.map(std::str::from_utf8) {
            Some(Ok(text)) => Some(text.to_owned()),
            _ => return std::ptr::null(),
        }
    };
    focus.recent_panes(workspace.as_deref())
}

/// The last focused pane of each workspace, as workspace, pane pairs.
/// Valid until the next `cmux_focus_*` call on the handle.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_remembered(focus: *mut Focus) -> *const CmuxFocusStrings {
    if focus.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle used by one thread.
    unsafe { &mut *focus }.remembered()
}

/// The whole state as JSON (journal checkpoints, `debug.focus`). Free it
/// with `cmux_focus_string_free`. Not for the per-event path.
///
/// # Safety
///
/// `focus` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_export_json(focus: *mut Focus) -> *mut c_char {
    if focus.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: a live handle used by one thread.
    let text = unsafe { &*focus }.state().export().to_string();
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Replaces the state with an exported one (journal replay). 0 when it
/// decoded, -2 when not (the state is kept).
///
/// # Safety
///
/// `focus` is a live handle used by one thread; `json` points to `json_len`
/// readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_import_json(
    focus: *mut Focus,
    json: *const u8,
    json_len: usize,
) -> i32 {
    if focus.is_null() {
        return crate::ERR_NULL;
    }
    // SAFETY: this function's contract gives `json_len` readable bytes at `json`, which is what
    // `bytes` requires (it refuses a null pointer itself); the slice is used only during this call.
    let Some(json) = (unsafe { bytes(json, json_len) }) else { return crate::ERR_NULL };
    // SAFETY: a live handle used by one thread.
    let focus = unsafe { &mut *focus };
    match catch_unwind(AssertUnwindSafe(|| focus.import(json))) {
        Ok(true) => crate::OK,
        _ => crate::ERR_INVALID,
    }
}

/// Frees a string from `cmux_focus_export_json`.
///
/// # Safety
///
/// `text` is null or a string from `cmux_focus_export_json`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_focus_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the pointer came from CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}
