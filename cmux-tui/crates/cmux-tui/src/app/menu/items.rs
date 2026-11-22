//! Per-surface menu items: terminal size modes, size participants and the
//! attached-clients submenu.

use cmux_tui_core::SurfaceId;
use cmux_tui_core::sizing_policy::TerminalSizingMode;

use crate::app::MenuAction;
use crate::app::menu::MenuItem;
use crate::localization;
use crate::session::{ClientInfo, SurfaceSizeState};

/// A coalescing key for one participant id (FNV-1a).
pub(in crate::app) fn participant_key(participant: &str) -> u64 {
    participant.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// The mode names of the size menu, in menu order (Fit everyone first, the default).
pub(in crate::app) const SIZE_MENU_MODES: [TerminalSizingMode; 5] = [
    TerminalSizingMode::Smallest,
    TerminalSizingMode::Latest,
    TerminalSizingMode::Largest,
    TerminalSizingMode::Priority,
    TerminalSizingMode::Fixed,
];

pub(in crate::app) fn size_mode_label(mode: TerminalSizingMode) -> &'static str {
    let menu = &localization::catalog().menu;
    match mode {
        TerminalSizingMode::Smallest => menu.size_mode_fit_everyone,
        TerminalSizingMode::Latest => menu.size_mode_follow_latest,
        TerminalSizingMode::Largest => menu.size_mode_largest,
        TerminalSizingMode::Priority => menu.size_mode_priority,
        TerminalSizingMode::Fixed => menu.size_mode_fixed,
    }
}

/// The shared-sizing menu for a terminal (the Mac size panel's controls):
/// the five modes with the current one checked, then one submenu per
/// participant with Counts toward size and Disconnect.
pub(in crate::app) fn size_menu_item(size: &SurfaceSizeState, surface: SurfaceId) -> MenuItem {
    let menu = &localization::catalog().menu;
    let state = &size.state;
    let self_id = size.self_participant.as_deref();
    let check = |on: bool| if on { "✓ " } else { "  " };
    let mut items = SIZE_MENU_MODES
        .into_iter()
        .map(|mode| MenuItem::LabeledAction {
            label: format!("{}{}", check(state.policy.mode == mode), size_mode_label(mode)),
            action: MenuAction::SetSizeMode { surface, mode },
        })
        .collect::<Vec<_>>();
    items.push(MenuItem::Separator);
    for (index, row) in state.participants.iter().enumerate() {
        let participant = &row.participant;
        let is_self = Some(participant.id.as_str()) == self_id;
        let mut label = if is_self {
            menu.this_client.to_string()
        } else {
            crate::ui::sizing::participant_label(participant, menu)
        };
        if let Some(viewport) = participant.viewport {
            label.push_str(&format!(" · {}×{}", viewport.cols, viewport.rows));
        }
        if state.owners.contains(&participant.id) {
            label.push_str(&format!(" · {}", menu.size_sets_size));
        } else if !row.counts {
            label.push_str(&format!(" · {}", menu.size_not_counted));
        }
        let generation = state.generation;
        items.push(MenuItem::Submenu {
            label,
            items: vec![
                MenuItem::LabeledAction {
                    label: format!("{}{}", check(row.counts), menu.size_counts),
                    action: MenuAction::SetSizeCounts {
                        surface,
                        generation,
                        participant: index,
                        counts: !row.counts,
                    },
                },
                MenuItem::Separator,
                MenuItem::Action(MenuAction::DisconnectSizeParticipant {
                    surface,
                    generation,
                    participant: index,
                }),
            ],
        });
    }
    MenuItem::Submenu { label: menu.terminal_size.to_string(), items }
}

/// The size menu when the host publishes shared sizing, else the legacy
/// per-client menu for hosts without `shared-sizing-v1`.
pub(in crate::app) fn terminal_size_menu_item(
    size: Option<&SurfaceSizeState>,
    clients: &[ClientInfo],
    surface: SurfaceId,
) -> Option<MenuItem> {
    match size {
        Some(size) => Some(size_menu_item(size, surface)),
        None => client_menu_item(clients, surface),
    }
}

pub(in crate::app) fn client_menu_item(
    clients: &[ClientInfo],
    surface: SurfaceId,
) -> Option<MenuItem> {
    if clients.is_empty() {
        return None;
    }
    let mut items = Vec::new();
    if let Some(current) = clients.iter().find(|client| {
        client.is_self
            && client
                .sizes
                .iter()
                .any(|size| size.surface == surface && size.cols.is_some() && size.rows.is_some())
    }) {
        items.push(MenuItem::Action(MenuAction::UseClientSize { surface, client: current.client }));
    }
    items.extend([
        MenuItem::Action(MenuAction::RestoreAllClientSizing(surface)),
        MenuItem::Separator,
    ]);
    for client in clients {
        let size_info = client.sizes.iter().find(|size| size.surface == surface);
        let reported_size = size_info.and_then(|size| size.cols.zip(size.rows));
        let size_participating = size_info.is_none_or(|size| size.size_participating);
        let identity = client.kind.as_deref().or(client.name.as_deref()).unwrap_or("client");
        let size = reported_size
            .map(|(cols, rows)| format!("{cols}×{rows}"))
            .unwrap_or_else(|| localization::catalog().menu.no_grid.to_string());
        let self_label = if client.is_self {
            format!(" · {}", localization::catalog().menu.this_client)
        } else {
            String::new()
        };
        let sizing_label = if size_participating {
            String::new()
        } else {
            format!(" · {}", localization::catalog().menu.excluded)
        };
        let label = format!("#{} {identity} · {size}{self_label}{sizing_label}", client.client);
        let mut actions = Vec::new();
        if reported_size.is_some() {
            actions.extend([
                MenuItem::Action(MenuAction::UseClientSize { surface, client: client.client }),
                MenuItem::Action(MenuAction::SetClientSizing {
                    surface,
                    client: client.client,
                    enabled: !size_participating,
                }),
            ]);
        }
        if client.client != 0 {
            if !actions.is_empty() {
                actions.push(MenuItem::Separator);
            }
            actions.push(MenuItem::Action(MenuAction::DisconnectClient(client.client)));
        }
        items.push(MenuItem::Submenu { label, items: actions });
    }
    Some(MenuItem::Submenu {
        label: format!("{} ({})", localization::catalog().menu.connected_clients, clients.len()),
        items,
    })
}
