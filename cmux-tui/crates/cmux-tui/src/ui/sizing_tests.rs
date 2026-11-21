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
    let phone = participant("c2/mobile:p", Some("Maya"), TerminalDeviceKind::Iphone, None, 50, 30);
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
