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

#[cfg(test)]
mod tests {
    use cmux_tui_core::sizing_policy::{
        TerminalGridSize, TerminalSizingEngine, TerminalSizingMode, TerminalSizingPolicy,
    };

    use super::*;
    use crate::localization;

    fn participant(
        id: &str,
        name: Option<&str>,
        kind: TerminalDeviceKind,
        device: Option<&str>,
        cols: u16,
        rows: u16,
    ) -> TerminalSizingParticipant {
        TerminalSizingParticipant {
            id: id.into(),
            user_id: name.map(|name| format!("u_{name}")),
            display_name: name.map(str::to_string),
            device_kind: kind,
            device_name: device.map(str::to_string),
            viewport: Some(TerminalGridSize::new(cols, rows)),
            ..TerminalSizingParticipant::default()
        }
    }

    fn state(mode: TerminalSizingMode, rows: &[TerminalSizingParticipant]) -> TerminalSizingState {
        let mut engine = TerminalSizingEngine::new(
            TerminalGridSize::new(80, 24),
            TerminalSizingPolicy::new(mode, Vec::new(), None),
        );
        for row in rows {
            engine.attach(row.clone());
        }
        engine.state().clone()
    }

    fn strings() -> &'static MenuMessages {
        &localization::catalog_for_locale("en").menu
    }

    #[test]
    fn alone_at_the_grid_size_shows_no_label() {
        let me = participant("c1", None, TerminalDeviceKind::Tui, Some("devbox"), 120, 40);
        let size = SurfaceSizeState {
            state: state(TerminalSizingMode::Smallest, &[me]),
            self_participant: Some("c1".into()),
        };
        assert_eq!(border_label(&size, strings()), None);
    }

    #[test]
    fn a_larger_owner_names_its_device_and_the_hidden_columns() {
        let mac = participant(
            "c2",
            Some("Lawrence Chen"),
            TerminalDeviceKind::Mac,
            Some("Mac Studio"),
            118,
            38,
        );
        let me = participant("c1", None, TerminalDeviceKind::Tui, Some("devbox"), 100, 40);
        let size = SurfaceSizeState {
            state: state(TerminalSizingMode::Latest, &[me, mac]),
            self_participant: Some("c1".into()),
        };
        assert_eq!(size.state.size(), TerminalGridSize::new(118, 38));
        assert_eq!(
            border_label(&size, strings()).as_deref(),
            Some(" 118×38 · Lawrence's Mac · 18 cols hidden ")
        );
    }

    #[test]
    fn fit_everyone_with_two_setters_names_the_policy() {
        let mac = participant("c2", Some("Maya"), TerminalDeviceKind::Mac, None, 118, 30);
        let me = participant("c1", None, TerminalDeviceKind::Tui, None, 100, 40);
        let size = SurfaceSizeState {
            state: state(TerminalSizingMode::Smallest, &[me, mac]),
            self_participant: Some("c1".into()),
        };
        assert_eq!(border_label(&size, strings()).as_deref(), Some(" 100×30 · Fits everyone "));
    }

    #[test]
    fn this_client_as_sole_owner_is_named_as_such() {
        let phone =
            participant("c2/mobile:p", Some("Maya"), TerminalDeviceKind::Iphone, None, 50, 30);
        let me = participant("c1", None, TerminalDeviceKind::Tui, None, 40, 20);
        let size = SurfaceSizeState {
            state: state(TerminalSizingMode::Smallest, &[me, phone]),
            self_participant: Some("c1".into()),
        };
        assert_eq!(border_label(&size, strings()).as_deref(), Some(" 40×20 · this client "));
    }

    #[test]
    fn one_hidden_column_is_singular() {
        let mac = participant("c2", Some("Maya"), TerminalDeviceKind::Mac, None, 81, 24);
        let me = participant("c1", None, TerminalDeviceKind::Tui, None, 80, 24);
        let size = SurfaceSizeState {
            state: state(TerminalSizingMode::Latest, &[me, mac]),
            self_participant: Some("c1".into()),
        };
        assert_eq!(
            border_label(&size, strings()).as_deref(),
            Some(" 81×24 · Maya's Mac · 1 col hidden ")
        );
    }

    #[test]
    fn priority_puts_this_client_first_without_duplicates() {
        let mac = participant("c2", Some("Maya"), TerminalDeviceKind::Mac, None, 81, 24);
        let me = participant("c1", Some("Maya"), TerminalDeviceKind::Tui, None, 80, 24);
        let state = state(TerminalSizingMode::Latest, &[mac, me]);
        assert_eq!(priority_with_self_first(&state, Some("c1")), ["u_Maya/tui", "u_Maya/mac"]);
    }

    #[test]
    fn linux_and_windows_devices_have_their_own_labels() {
        let strings = strings();
        assert_eq!(device_kind_label(TerminalDeviceKind::Linux, strings), "Linux");
        assert_eq!(device_kind_label(TerminalDeviceKind::Windows, strings), "Windows");
        assert_eq!(device_kind_label(TerminalDeviceKind::parse("quantum"), strings), "Device");
    }
}
