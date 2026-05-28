#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

use std::collections::BTreeMap;

use comeup_protocol::{
    Delta, Focus, Pane, PaneId, Seq, Space, SpaceId, Terminal, TerminalId, Viewport,
    VisibleTerminal, Workspace, WorkspaceId,
};

#[derive(Debug, Clone)]
pub struct Model {
    seq: Seq,
    next_workspace_id: WorkspaceId,
    next_space_id: SpaceId,
    next_pane_id: PaneId,
    next_terminal_id: TerminalId,
    workspaces: BTreeMap<WorkspaceId, Workspace>,
    spaces: BTreeMap<SpaceId, Space>,
    panes: BTreeMap<PaneId, Pane>,
    terminals: BTreeMap<TerminalId, Terminal>,
    focus: Focus,
}

impl Model {
    #[must_use]
    pub fn new(initial_size: Viewport) -> Self {
        let workspace_id = 1;
        let space_id = 1;
        let pane_id = 1;
        let terminal_id = 1;
        let initial_size = initial_size.clamp_min();

        let workspace = Workspace {
            id: workspace_id,
            title: "Workspace 1".to_string(),
            active_space_id: space_id,
        };
        let space = Space {
            id: space_id,
            workspace_id,
            title: "Space 1".to_string(),
            root_pane_id: pane_id,
        };
        let pane = Pane {
            id: pane_id,
            space_id,
            active_terminal_id: terminal_id,
            terminal_ids: vec![terminal_id],
        };
        let terminal = Terminal {
            id: terminal_id,
            pane_id,
            title: "Terminal 1".to_string(),
            size: initial_size,
        };

        Self {
            seq: 0,
            next_workspace_id: 2,
            next_space_id: 2,
            next_pane_id: 2,
            next_terminal_id: 2,
            workspaces: [(workspace_id, workspace)].into(),
            spaces: [(space_id, space)].into(),
            panes: [(pane_id, pane)].into(),
            terminals: [(terminal_id, terminal)].into(),
            focus: Focus {
                workspace_id,
                space_id,
                pane_id,
                terminal_id,
            },
        }
    }

    #[must_use]
    pub fn snapshot(&self) -> comeup_protocol::Snapshot {
        comeup_protocol::Snapshot {
            seq: self.seq,
            workspaces: self.workspaces.values().cloned().collect(),
            spaces: self.spaces.values().cloned().collect(),
            panes: self.panes.values().cloned().collect(),
            terminals: self.terminals.values().cloned().collect(),
            focus: self.focus,
        }
    }

    #[must_use]
    pub fn focus(&self) -> Focus {
        self.focus
    }

    #[must_use]
    pub fn seq(&self) -> Seq {
        self.seq
    }

    #[must_use]
    pub fn terminal_size(&self, terminal_id: TerminalId) -> Option<Viewport> {
        self.terminals
            .get(&terminal_id)
            .map(|terminal| terminal.size)
    }

    pub fn create_workspace(&mut self, title: impl Into<String>) -> Vec<Delta> {
        let workspace_id = self.take_workspace_id();
        let space_id = self.take_space_id();
        let pane_id = self.take_pane_id();
        let terminal_id = self.take_terminal_id();
        let title = title.into();
        let terminal_size = self
            .terminals
            .get(&self.focus.terminal_id)
            .map_or(Viewport { cols: 80, rows: 24 }, |terminal| terminal.size);

        let workspace = Workspace {
            id: workspace_id,
            title: title.clone(),
            active_space_id: space_id,
        };
        let space = Space {
            id: space_id,
            workspace_id,
            title: "Space 1".to_string(),
            root_pane_id: pane_id,
        };
        let pane = Pane {
            id: pane_id,
            space_id,
            active_terminal_id: terminal_id,
            terminal_ids: vec![terminal_id],
        };
        let terminal = Terminal {
            id: terminal_id,
            pane_id,
            title: format!("{title} terminal"),
            size: terminal_size,
        };
        let focus = Focus {
            workspace_id,
            space_id,
            pane_id,
            terminal_id,
        };

        self.workspaces.insert(workspace_id, workspace.clone());
        self.spaces.insert(space_id, space.clone());
        self.panes.insert(pane_id, pane.clone());
        self.terminals.insert(terminal_id, terminal.clone());
        self.focus = focus;

        vec![
            self.delta_workspace(workspace),
            self.delta_space(space),
            self.delta_pane(pane),
            self.delta_terminal(terminal),
            self.delta_focus(focus),
        ]
    }

    pub fn resize_terminal(&mut self, terminal_id: TerminalId, size: Viewport) -> Option<Delta> {
        let terminal = {
            let terminal = self.terminals.get_mut(&terminal_id)?;
            terminal.size = size.clamp_min();
            terminal.clone()
        };
        Some(self.delta_terminal(terminal))
    }

    fn take_workspace_id(&mut self) -> WorkspaceId {
        let id = self.next_workspace_id;
        self.next_workspace_id = self.next_workspace_id.saturating_add(1);
        id
    }

    fn take_space_id(&mut self) -> SpaceId {
        let id = self.next_space_id;
        self.next_space_id = self.next_space_id.saturating_add(1);
        id
    }

    fn take_pane_id(&mut self) -> PaneId {
        let id = self.next_pane_id;
        self.next_pane_id = self.next_pane_id.saturating_add(1);
        id
    }

    fn take_terminal_id(&mut self) -> TerminalId {
        let id = self.next_terminal_id;
        self.next_terminal_id = self.next_terminal_id.saturating_add(1);
        id
    }

    fn next_seq(&mut self) -> Seq {
        self.seq = self.seq.saturating_add(1);
        self.seq
    }

    fn delta_workspace(&mut self, workspace: Workspace) -> Delta {
        Delta::WorkspaceUpsert {
            seq: self.next_seq(),
            workspace,
        }
    }

    fn delta_space(&mut self, space: Space) -> Delta {
        Delta::SpaceUpsert {
            seq: self.next_seq(),
            space,
        }
    }

    fn delta_pane(&mut self, pane: Pane) -> Delta {
        Delta::PaneUpsert {
            seq: self.next_seq(),
            pane,
        }
    }

    fn delta_terminal(&mut self, terminal: Terminal) -> Delta {
        Delta::TerminalUpsert {
            seq: self.next_seq(),
            terminal,
        }
    }

    fn delta_focus(&mut self, focus: Focus) -> Delta {
        Delta::FocusChanged {
            seq: self.next_seq(),
            focus,
        }
    }
}

#[must_use]
pub fn effective_terminal_size(
    terminal_id: TerminalId,
    visible: &[VisibleTerminal],
    fallback: Viewport,
) -> Viewport {
    let mut size: Option<Viewport> = None;
    for terminal in visible {
        if terminal.terminal_id != terminal_id || !terminal.visible {
            continue;
        }
        let viewport = Viewport {
            cols: terminal.cols,
            rows: terminal.rows,
        }
        .clamp_min();
        size = Some(match size {
            Some(current) => Viewport {
                cols: current.cols.min(viewport.cols),
                rows: current.rows.min(viewport.rows),
            },
            None => viewport,
        });
    }
    size.unwrap_or(fallback).clamp_min()
}

#[cfg(test)]
mod tests {
    use super::*;
    use comeup_protocol::ClientId;

    #[test]
    fn create_workspace_emits_ordered_deltas_and_focuses_terminal() {
        let mut model = Model::new(Viewport { cols: 80, rows: 24 });
        let deltas = model.create_workspace("Build");

        assert_eq!(deltas.len(), 5);
        assert_eq!(
            deltas.iter().map(Delta::seq).collect::<Vec<_>>(),
            vec![1, 2, 3, 4, 5]
        );
        assert_eq!(model.snapshot().workspaces.len(), 2);
        assert_eq!(model.focus().workspace_id, 2);
        assert_eq!(model.focus().terminal_id, 2);
    }

    #[test]
    fn effective_terminal_size_uses_smallest_visible_client() {
        let visible = vec![
            visible(1, 9, 160, 48, true),
            visible(2, 9, 120, 60, true),
            visible(3, 9, 100, 30, false),
            visible(4, 10, 20, 10, true),
        ];

        assert_eq!(
            effective_terminal_size(9, &visible, Viewport { cols: 80, rows: 24 }),
            Viewport {
                cols: 120,
                rows: 48
            }
        );
    }

    #[test]
    fn effective_terminal_size_keeps_fallback_when_terminal_is_hidden() {
        let visible = vec![visible(1, 9, 120, 40, false)];

        assert_eq!(
            effective_terminal_size(9, &visible, Viewport { cols: 80, rows: 24 }),
            Viewport { cols: 80, rows: 24 }
        );
    }

    fn visible(
        client_id: ClientId,
        terminal_id: TerminalId,
        cols: u16,
        rows: u16,
        visible: bool,
    ) -> VisibleTerminal {
        VisibleTerminal {
            client_id,
            terminal_id,
            cols,
            rows,
            visible,
        }
    }
}
