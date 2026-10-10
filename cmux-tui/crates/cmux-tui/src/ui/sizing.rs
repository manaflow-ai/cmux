//! Shared terminal sizing as this frontend shows it
//! (docs/shared-terminal-sizing.md): the pane border label, which carries the
//! same text as the Mac chip, and the names used in the size menu.

use cmux_tui_core::sizing_policy::{
    TerminalDeviceKind, TerminalSizingParticipant, TerminalSizingReason, TerminalSizingState,
};

use crate::localization::MenuMessages;
use crate::session::SurfaceSizeState;

/// The pane border label, ` 118×38 · Lawrence's Mac ` (plus `· 12 cols
/// hidden` when this client shows fewer columns than the grid). `None` when
/// nobody else is attached and this client shows exactly the grid, which is
/// when the Mac and iPhone hide their sizing chrome too.
pub(crate) fn border_label(size: &SurfaceSizeState, strings: &MenuMessages) -> Option<String> {
    let state = &size.state;
    let self_id = size.self_participant.as_deref();
    let own_viewport =
        self_id.and_then(|id| state.participant(id)).and_then(|row| row.participant.viewport);
    let someone_else =
        state.participants.iter().any(|row| Some(row.participant.id.as_str()) != self_id);
    let shows_grid = own_viewport.is_none_or(|viewport| viewport == state.size());
    if !someone_else && shows_grid {
        return None;
    }
    let mut label = format!(" {}×{} · {}", state.cols, state.rows, owner_label(size, strings));
    let hidden = own_viewport.map_or(0, |viewport| state.cols.saturating_sub(viewport.cols));
    if hidden > 0 {
        label.push_str(" · ");
        label.push_str(&hidden_columns(hidden, strings));
    }
    label.push(' ');
    Some(label)
}

/// Who or what sets the grid: an owner name, or the policy when several
/// participants (or none) set it.
pub(crate) fn owner_label(size: &SurfaceSizeState, strings: &MenuMessages) -> String {
    let state = &size.state;
    if let [owner] = state.owners.as_slice()
        && let Some(row) = state.participant(owner)
    {
        return owner_name(&row.participant, size.self_participant.as_deref(), strings);
    }
    match state.reason {
        TerminalSizingReason::Fixed => strings.size_owner_fixed,
        TerminalSizingReason::Held => strings.size_owner_held,
        TerminalSizingReason::Smallest => strings.size_owner_fits_everyone,
        TerminalSizingReason::Largest => strings.size_owner_largest,
        TerminalSizingReason::Latest
        | TerminalSizingReason::Priority
        | TerminalSizingReason::PriorityFallback => strings.size_owner_shared,
    }
    .to_string()
}

/// A short owner name: `this client`, `Lawrence's Mac`, or the device alone.
pub(crate) fn owner_name(
    participant: &TerminalSizingParticipant,
    self_id: Option<&str>,
    strings: &MenuMessages,
) -> String {
    if Some(participant.id.as_str()) == self_id {
        return strings.this_client.to_string();
    }
    let first_name = trimmed(participant.display_name.as_deref())
        .and_then(|name| name.split(|c: char| c.is_whitespace() || c == '@').next())
        .filter(|name| !name.is_empty());
    match first_name {
        Some(name) => strings
            .size_possessive_device
            .replace("{name}", name)
            .replace("{device}", device_kind_label(participant.device_kind, strings)),
        None => device_label(participant, strings),
    }
}

/// A participant row: `Maya · Mac Studio`, or the device alone.
pub(crate) fn participant_label(
    participant: &TerminalSizingParticipant,
    strings: &MenuMessages,
) -> String {
    let device = device_label(participant, strings);
    match trimmed(participant.display_name.as_deref()) {
        Some(person) if person != device => format!("{person} · {device}"),
        _ => device,
    }
}

fn device_label(participant: &TerminalSizingParticipant, strings: &MenuMessages) -> String {
    trimmed(participant.device_name.as_deref())
        .map(str::to_string)
        .unwrap_or_else(|| device_kind_label(participant.device_kind, strings).to_string())
}

fn device_kind_label(kind: TerminalDeviceKind, strings: &MenuMessages) -> &'static str {
    match kind {
        TerminalDeviceKind::Mac => strings.device_mac,
        TerminalDeviceKind::Iphone => strings.device_iphone,
        TerminalDeviceKind::Ipad => strings.device_ipad,
        TerminalDeviceKind::Tui => strings.device_tui,
        TerminalDeviceKind::Browser => strings.device_browser,
        TerminalDeviceKind::Linux => strings.device_linux,
        TerminalDeviceKind::Windows => strings.device_windows,
        TerminalDeviceKind::Unknown => strings.device_unknown,
    }
}

fn hidden_columns(count: u16, strings: &MenuMessages) -> String {
    if count == 1 {
        strings.size_one_col_hidden.to_string()
    } else {
        strings.size_cols_hidden.replace("{count}", &count.to_string())
    }
}

fn trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

/// Priority keys with this client first, then everyone else in state order,
/// for choosing Priority from the menu.
pub(crate) fn priority_with_self_first(
    state: &TerminalSizingState,
    self_id: Option<&str>,
) -> Vec<String> {
    let mut keys = Vec::new();
    let self_row = self_id.and_then(|id| state.participant(id));
    for row in self_row.into_iter().chain(state.participants.iter()) {
        if !keys.contains(&row.priority_key) {
            keys.push(row.priority_key.clone());
        }
    }
    keys
}
