//! The focus handle's reply buffers: the typed `CmuxFocusReply` a call returns, and the string lists the app reads
//! after one. One per window, kept beside the window's focus: by the window handle (`cmux_focus_*`) and by the
//! input handle for each of its windows (`cmux_input_focus_*`), so both answer with the same bytes.

use super::codec::{context_bits, encode_resolved, overlay_code, target_code};
use super::{CmuxFocusEffect, CmuxFocusReply, CmuxFocusResolved, CmuxFocusStr, CmuxFocusStrings};
use cmux_focus_core::event::FocusEffect;
use cmux_focus_core::state::{ExpectationKey, FocusState, Overlay, Target};

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

pub(crate) const fn empty_resolved() -> CmuxFocusResolved {
    CmuxFocusResolved {
        kind: 13,
        overlay: 0,
        reserved: [0; 6],
        pane: CmuxFocusStr::ABSENT,
        tab: CmuxFocusStr::ABSENT,
    }
}

/// One window's reply and string-list buffers. The reply's pointers point into these buffers, so a reply stays valid
/// until the next call that writes this window's reply.
pub struct FocusReply {
    summary: Summary,
    strings: Vec<u8>,
    overlays: Vec<u8>,
    c_effects: Vec<CmuxFocusEffect>,
    reply: CmuxFocusReply,
    list: Vec<CmuxFocusStr>,
    list_bytes: Vec<u8>,
    list_reply: CmuxFocusStrings,
}

impl FocusReply {
    /// The reply for a new window in `state` (`changed` 1, no effects).
    pub(crate) fn new(state: &FocusState) -> FocusReply {
        let mut out = FocusReply {
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
                omnibar_return: 0,
                returns_to_omnibar: 0,
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
                typing_tab: CmuxFocusStr::ABSENT,
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
        out.reset(state);
        out
    }

    /// The reply the last call wrote.
    pub(crate) fn reply(&self) -> &CmuxFocusReply {
        &self.reply
    }

    /// The address bar memory's two asks of the last reduction.
    pub(crate) fn set_omnibar(&mut self, omnibar_return: bool, returns_to_omnibar: bool) {
        self.reply.omnibar_return = u8::from(omnibar_return);
        self.reply.returns_to_omnibar = u8::from(returns_to_omnibar);
    }

    /// The state in full (after a creation or a journal import): `changed` 1, no effects. The address bar
    /// memory's asks keep their last values.
    pub(crate) fn reset(&mut self, state: &FocusState) {
        self.summary = Summary::of(state);
        self.write(true, state, std::iter::empty());
    }

    /// The current state as a reply (`changed` 1, no effects, no address bar asks).
    pub(crate) fn current(&mut self, state: &FocusState) -> &CmuxFocusReply {
        self.reset(state);
        self.set_omnibar(false, false);
        &self.reply
    }

    /// A request that did not decode, or a handle that could not answer: `ok` 0, nothing changed.
    pub(crate) fn fail(&mut self) -> &CmuxFocusReply {
        self.reply.ok = 0;
        self.reply.omnibar_return = 0;
        self.reply.returns_to_omnibar = 0;
        self.reply.changed = 0;
        self.reply.effect_count = 0;
        &self.reply
    }

    /// A reduction panicked part way: report the (re-derived) state as it is now, with `ok` 0 and no effects.
    pub(crate) fn recovered(&mut self, state: &FocusState) -> &CmuxFocusReply {
        self.current(state);
        self.reply.ok = 0;
        &self.reply
    }

    /// The reply after a reduction of `state` that produced `effects`, in order (`ran`: the reducer ran at all). The
    /// input handle passes its window's effects straight from the router's (no copy).
    pub(crate) fn finish<'e, E>(
        &mut self,
        ran: bool,
        state: &FocusState,
        effects: E,
    ) -> &CmuxFocusReply
    where
        E: IntoIterator<Item = &'e FocusEffect>,
        E::IntoIter: Clone,
    {
        if !ran {
            // Nothing changed: the last reply's fields still hold.
            self.reply.ok = 1;
            self.reply.changed = 0;
            self.reply.effect_count = 0;
            return &self.reply;
        }
        let effects = effects.into_iter();
        let summary = Summary::of(state);
        let changed = summary != self.summary;
        if changed || effects.clone().next().is_some() {
            self.summary = summary;
            self.write(changed, state, effects);
        } else {
            self.reply.ok = 1;
            self.reply.changed = 0;
            self.reply.effect_count = 0;
        }
        &self.reply
    }

    fn write<'e>(
        &mut self,
        changed: bool,
        state: &FocusState,
        effects: impl Iterator<Item = &'e FocusEffect>,
    ) {
        self.strings.clear();
        self.overlays.clear();
        self.c_effects.clear();
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
        let typing_tab = put(state.typing_tab());
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
        for effect in effects {
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
        reply.typing_tab = typing_tab;
    }

    /// The focus history of `workspace` (none: the shown one), newest first.
    pub(crate) fn recent_panes(
        &mut self,
        state: &FocusState,
        workspace: Option<&str>,
    ) -> &CmuxFocusStrings {
        self.list.clear();
        self.list_bytes.clear();
        let recent = match workspace {
            Some(workspace) => state.history.get(workspace).map_or(&[][..], Vec::as_slice),
            None => state.recent_panes(),
        };
        for pane in recent {
            push(&mut self.list, &mut self.list_bytes, pane);
        }
        self.finish_list()
    }

    /// The last focused pane of each workspace: workspace, pane, workspace, pane, ... (a window record save; not
    /// per event).
    pub(crate) fn remembered(&mut self, state: &FocusState) -> &CmuxFocusStrings {
        self.list.clear();
        self.list_bytes.clear();
        for (workspace, pane) in &state.remembered {
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
