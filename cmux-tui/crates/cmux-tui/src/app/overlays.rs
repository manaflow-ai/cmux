//! Modal overlay state: prompts and their targets, the pairing and connection
//! dialogs, shortcut help, omnibar state and toasts.

use std::time::Instant;

use cmux_tui_core::{PairingChallenge, PaneId, Rect, ScreenId, SurfaceId, WorkspaceId};

use crate::app::action_available_in_mode;
use crate::config::{Action, Config};
use crate::machine::{MachineConnectRoute, MachineKey};
use crate::ui::input::TextInput;
use crate::ui::{viewport_drag_offset, viewport_jump_offset, viewport_thumb_geometry};

/// What a committed rename prompt applies to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptTarget {
    ClientMachine(MachineKey),
    ManagedMachine(MachineKey),
    ConfirmDeleteManagedMachine(MachineKey),
    ConfirmPurgeManagedMachine(MachineKey),
    Workspace(WorkspaceId),
    ManagedWorkspace(WorkspaceId),
    ConfirmPurgeManagedWorkspace(usize),
    Screen(ScreenId),
    Surface(SurfaceId),
    ConnectMachine(MachineConnectRoute),
    ProviderAction(usize),
    ConfirmProviderAction,
    ConfirmLayoutUndo { pane: PaneId, revision: u64 },
}

/// Centered rename dialog: a text input with OK/Cancel buttons. The
/// renderer writes the final geometry back so mouse hit-testing (buttons,
/// dismiss-outside) matches what is drawn.
pub struct Prompt {
    pub label: String,
    pub input: TextInput,
    pub target: PromptTarget,
    /// Dialog rect (set by the renderer each frame).
    pub rect: Rect,
    /// Input / button rects (set by the renderer each frame).
    pub input_rect: Rect,
    pub clear: Rect,
    pub ok: Rect,
    pub cancel: Rect,
}

pub struct PairingDialog {
    pub challenge: PairingChallenge,
    pub rect: Rect,
    pub approve: Rect,
    pub deny: Rect,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ConnectionDialogPhase {
    Editing,
    Connecting,
    Starting,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ConnectionTransaction {
    pub attempt: u64,
    pub target: String,
    pub route: MachineConnectRoute,
    pub phase: ConnectionDialogPhase,
}

impl PairingDialog {
    pub(super) fn new(challenge: PairingChallenge) -> Self {
        Self { challenge, rect: Rect::default(), approve: Rect::default(), deny: Rect::default() }
    }
}

#[derive(Debug, Default)]
pub struct ShortcutHelp {
    pub rows: Vec<(Action, String)>,
    pub rect: Rect,
    pub scroll_offset: usize,
    pub visible_rows: usize,
    pub close_button: Rect,
    pub scrollbar_track: Rect,
    pub scrollbar_thumb: Rect,
    pub(super) scrollbar_drag: Option<(u16, usize)>,
}

impl ShortcutHelp {
    pub(super) fn resolved_rows(config: &Config, surface_only: bool) -> Vec<(Action, String)> {
        let mut rows: Vec<(Action, String)> = config
            .keys
            .resolved_shortcuts()
            .into_iter()
            .filter(|(definition, _)| action_available_in_mode(definition.action, surface_only))
            .map(|(definition, shortcuts)| (definition.action, shortcuts.join(", ")))
            .collect();
        // The default provider-menu chord is contextual to the machine rail,
        // so it is not part of the generic resolved shortcut map.
        if !config.keys.provider_menu_overridden
            && action_available_in_mode(Action::ProviderMenu, surface_only)
        {
            rows.push((Action::ProviderMenu, "m".to_string()));
        }
        for index in 0..config.commands.len() {
            let Some(action) = Action::user_command(index) else { break };
            if !action_available_in_mode(action, surface_only) {
                continue;
            }
            let shortcuts = config.keys.shortcut_labels(action);
            if !shortcuts.is_empty() {
                rows.push((action, shortcuts.join(", ")));
            }
        }
        rows
    }

    pub(super) fn from_config(config: &Config, surface_only: bool) -> Self {
        Self { rows: Self::resolved_rows(config, surface_only), ..Self::default() }
    }

    pub(super) fn max_scroll(&self, total_rows: usize) -> usize {
        total_rows.saturating_sub(self.visible_rows)
    }

    pub(super) fn scroll_by(&mut self, delta: isize, total_rows: usize) {
        self.scroll_offset =
            self.scroll_offset.saturating_add_signed(delta).min(self.max_scroll(total_rows));
    }

    pub(crate) fn scrollbar_geometry(&self, total_rows: usize) -> (u16, u16) {
        viewport_thumb_geometry(
            total_rows,
            self.visible_rows,
            self.scroll_offset,
            self.scrollbar_track.height,
        )
    }

    pub(super) fn start_scrollbar_drag(&mut self, y: u16, total_rows: usize) {
        if self.scrollbar_track.height == 0 {
            return;
        }
        let relative = y
            .saturating_sub(self.scrollbar_track.y)
            .min(self.scrollbar_track.height.saturating_sub(1));
        let (thumb_y, thumb_height) = self.scrollbar_geometry(total_rows);
        if relative < thumb_y || relative >= thumb_y.saturating_add(thumb_height) {
            self.scroll_offset = viewport_jump_offset(
                total_rows,
                self.visible_rows,
                self.scrollbar_track.height,
                relative,
            );
        }
        self.scrollbar_drag = Some((y, self.scroll_offset));
    }

    pub(super) fn drag_scrollbar(&mut self, y: u16, total_rows: usize) {
        let Some((anchor_y, anchor_offset)) = self.scrollbar_drag else { return };
        self.scroll_offset = viewport_drag_offset(
            total_rows,
            self.visible_rows,
            self.scrollbar_track.height,
            anchor_offset,
            y as i128 - anchor_y as i128,
        );
    }

    pub(crate) fn scrollbar_dragging(&self) -> bool {
        self.scrollbar_drag.is_some()
    }
}

#[derive(Debug, Clone)]
pub struct OmnibarState {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub input: TextInput,
    pub select_all: bool,
}

pub struct Toast {
    pub text: String,
    pub(super) deadline: Instant,
}
