//! The focus handle's codes and request decoding: the `CMUX_FOCUS_*` values of the C ABI, and the typed event and
//! topology of a request turned into `cmux-focus-core` values. Shared by the window handle (`cmux_focus_*`) and the
//! input handle (`cmux_input_focus_*`).

use super::reply::empty_resolved;
use super::{CmuxFocusEvent, CmuxFocusResolved, CmuxFocusStr, CmuxFocusTopology, NONE};
use cmux_focus_core::event::{DragOutcome, FocusEvent, Responder, Source};
use cmux_focus_core::state::{Context, ExpectationKey, Overlay, Resolved, Target};
use cmux_focus_core::topology::{Column, Kind, Pane, Tab, Topology};

// MARK: Codes

pub(super) fn context_bits(context: Context) -> u8 {
    u8::from(context.terminal) | (u8::from(context.browser) << 1) | (u8::from(context.agent) << 2)
}

pub(super) fn overlay_code(overlay: Overlay) -> u8 {
    match overlay {
        Overlay::Palette => 0,
        Overlay::Sheet => 1,
        Overlay::Rename => 2,
        Overlay::GroupEditor => 3,
    }
}

pub(super) fn overlay_of(code: u8) -> Option<Overlay> {
    Some(match code {
        0 => Overlay::Palette,
        1 => Overlay::Sheet,
        2 => Overlay::Rename,
        3 => Overlay::GroupEditor,
        _ => return None,
    })
}

pub(super) fn target_code(target: Target) -> (u8, u8) {
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

pub(super) fn target_of(code: u8, keyboard: u8) -> Option<Target> {
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

pub(super) fn source_of(code: u8) -> Option<Source> {
    Some(match code {
        0 => Source::Mouse,
        1 => Source::Keyboard,
        2 => Source::Cli,
        3 => Source::Palette,
        4 => Source::Programmatic,
        _ => return None,
    })
}

pub(super) fn kind_of(code: u32) -> Option<Kind> {
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

pub(super) fn encode_resolved(
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
pub(super) struct Strings<'a>(&'a [u8]);

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
pub(super) unsafe fn items<'a, T>(ptr: *const T, count: u32) -> Result<&'a [T], ()> {
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
pub(crate) unsafe fn decode_event(
    event: &CmuxFocusEvent,
    strings: &[u8],
) -> Result<FocusEvent, ()> {
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
pub(crate) unsafe fn decode_topology(
    topology: &CmuxFocusTopology,
    strings: &[u8],
) -> Result<Topology, ()> {
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
                // The C topology carries no terminal id yet (R-INPUT stage S3 adds it).
                terminal: None,
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
