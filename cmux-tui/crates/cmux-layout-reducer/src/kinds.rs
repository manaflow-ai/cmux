//! An op in two steps: [`check_kind`] meets every rejection an op can meet
//! before it changes anything, reading the state only; [`apply_checked`]
//! makes the change with what the check resolved.
//!
//! [`apply_mut`](crate::apply_mut) runs the check before it captures the
//! op's region, so a rejected op (most ops a caller can send against a
//! given layout) costs its lookups, not a capture and a restore.

use crate::{
    COLUMN_WIDTH_PERMILLE, Column, ColumnId, Edge, LayoutEvent, LayoutOpKind, LayoutState, NewTab,
    PaneId, Reject, ScreenId, Slot, TabId, Workspace, WorkspaceId, rows, single_pane_screen,
};

/// What [`check_kind`] resolved for an op it accepts.
pub(crate) enum Checked<'a> {
    /// A move into the workspace the tab is in: no change.
    Nothing,
    MoveTab {
        tab: TabId,
        source: PaneId,
        target: PaneId,
        index: usize,
    },
    Split {
        tab: TabId,
        source: PaneId,
        slot: Slot,
        edge: Edge,
        new_pane: PaneId,
        respawn: Option<&'a NewTab>,
    },
    Column {
        tab: TabId,
        source: PaneId,
        slot: Slot,
        position: usize,
        new_pane: PaneId,
        new_column: ColumnId,
        base_column: ColumnId,
    },
    NewWorkspace {
        tab: TabId,
        source: PaneId,
        index: Option<usize>,
        new_workspace: WorkspaceId,
        new_screen: ScreenId,
        new_pane: PaneId,
    },
    IntoPane {
        tab: TabId,
        source: PaneId,
        destination: PaneId,
    },
    IntoEmptyWorkspace {
        tab: TabId,
        source: PaneId,
        workspace: WorkspaceId,
        new_screen: ScreenId,
        new_pane: PaneId,
    },
    /// The row ops check and change in [`rows::apply`].
    Rows(&'a LayoutOpKind),
    Close {
        tab: TabId,
        pane: PaneId,
    },
    RuntimeExited {
        runtime: u64,
    },
}

/// Every rejection `kind` meets on `state` before it changes anything, in
/// the order [`apply_checked`] used to meet them, so the reject is the same.
pub(crate) fn check_kind<'a>(
    state: &LayoutState,
    kind: &'a LayoutOpKind,
) -> Result<Checked<'a>, Reject> {
    let source_of = |tab: TabId| state.pane_of(tab).ok_or(Reject::UnknownTab(tab));
    // `source` came from `pane_of`, which finds it in `state.panes`.
    let only_tab = |source: PaneId| state.panes.get(&source).is_some_and(|tabs| tabs.len() == 1);
    Ok(match kind {
        LayoutOpKind::MoveTab { tab, pane, index } => {
            let source = source_of(*tab)?;
            state.require_pane(*pane)?;
            Checked::MoveTab { tab: *tab, source, target: *pane, index: *index }
        }
        LayoutOpKind::MoveTabToSplit { tab, pane, edge, new_pane, respawn } => {
            let source = source_of(*tab)?;
            let slot = state.require_pane(*pane)?;
            let only = source == *pane && only_tab(source);
            match respawn {
                None if only => return Err(Reject::OnlyTabSplitOutOfOwnPane),
                None => state.ensure_fresh(&[*new_pane])?,
                Some(_) if !only => return Err(Reject::RespawnNotNeeded),
                Some(respawn) => state.ensure_fresh(&[*new_pane, respawn.tab])?,
            }
            Checked::Split {
                tab: *tab,
                source,
                slot,
                edge: *edge,
                new_pane: *new_pane,
                respawn: respawn.as_ref(),
            }
        }
        LayoutOpKind::MoveTabToColumn {
            tab,
            anchor,
            after_column,
            width_permille,
            new_pane,
            new_column,
            base_column,
        } => {
            if !COLUMN_WIDTH_PERMILLE.contains(width_permille) {
                return Err(Reject::InvalidWidth(*width_permille));
            }
            let source = source_of(*tab)?;
            let slot = state.require_pane(*anchor)?;
            if source == *anchor && only_tab(source) {
                return Err(Reject::OnlyTabSplitOutOfOwnPane);
            }
            let screen = state
                .workspaces
                .get(slot.workspace)
                .and_then(|workspace| workspace.screens.get(slot.screen))
                .ok_or(Reject::UnknownPane(*anchor))?;
            let position = match after_column {
                Some(column) if screen.columns_active => {
                    screen
                        .columns
                        .iter()
                        .position(|candidate| candidate.id == *column)
                        .ok_or(Reject::UnknownColumn(*column))?
                        + 1
                }
                Some(column) => return Err(Reject::UnknownColumn(*column)),
                None => screen.columns.len(),
            };
            if screen.columns_active {
                state.ensure_fresh(&[*new_pane, *new_column])?;
            } else {
                state.ensure_fresh(&[*new_pane, *new_column, *base_column])?;
            }
            Checked::Column {
                tab: *tab,
                source,
                slot,
                position,
                new_pane: *new_pane,
                new_column: *new_column,
                base_column: *base_column,
            }
        }
        LayoutOpKind::MoveTabToNewWorkspace { tab, index, new_workspace, new_screen, new_pane } => {
            let source = source_of(*tab)?;
            state.ensure_fresh(&[*new_workspace, *new_screen, *new_pane])?;
            Checked::NewWorkspace {
                tab: *tab,
                source,
                index: *index,
                new_workspace: *new_workspace,
                new_screen: *new_screen,
                new_pane: *new_pane,
            }
        }
        LayoutOpKind::MoveTabToWorkspace { tab, workspace, pane, new_screen, new_pane } => {
            let source = source_of(*tab)?;
            let target = state
                .workspaces
                .iter()
                .position(|candidate| candidate.id == *workspace)
                .ok_or(Reject::UnknownWorkspace(*workspace))?;
            if state.slot(source).map(|slot| slot.workspace) == Some(target) {
                return Ok(Checked::Nothing);
            }
            let has_screens =
                state.workspaces.get(target).is_some_and(|target| !target.screens.is_empty());
            if has_screens {
                let destination = pane
                    .filter(|pane| {
                        state.panes.contains_key(pane)
                            && state.slot(*pane).is_some_and(|slot| slot.workspace == target)
                    })
                    .ok_or(Reject::PaneNotInWorkspace { pane: *pane, workspace: *workspace })?;
                Checked::IntoPane { tab: *tab, source, destination }
            } else {
                state.ensure_fresh(&[*new_screen, *new_pane])?;
                Checked::IntoEmptyWorkspace {
                    tab: *tab,
                    source,
                    workspace: *workspace,
                    new_screen: *new_screen,
                    new_pane: *new_pane,
                }
            }
        }
        LayoutOpKind::InsertRow { .. }
        | LayoutOpKind::MoveTabToRow { .. }
        | LayoutOpKind::SetRowHeights { .. }
        | LayoutOpKind::FlattenRows { .. } => Checked::Rows(kind),
        LayoutOpKind::CloseTab { tab } => Checked::Close { tab: *tab, pane: source_of(*tab)? },
        LayoutOpKind::RuntimeExited { runtime } => Checked::RuntimeExited { runtime: *runtime },
    })
}

/// The change of an op [`check_kind`] accepted on this same `state`. A
/// later step can still reject (the row ops check as they go); the caller
/// then puts the state back.
pub(crate) fn apply_checked(
    state: &mut LayoutState,
    checked: Checked<'_>,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    match checked {
        Checked::Nothing => {}
        Checked::MoveTab { tab, source, target, index } => {
            state.move_tab(tab, source, target, index, events)?;
        }
        Checked::Split { tab, source, slot, edge, new_pane, respawn } => {
            if let Some(respawn) = respawn {
                // The fresh tab first: the pane keeps a tab throughout.
                state.tabs.insert(respawn.tab, respawn.content.clone());
                state.panes.get_mut(&source).ok_or(Reject::UnknownPane(source))?.push(respawn.tab);
                events.push(LayoutEvent::TabCreated { tab: respawn.tab, pane: source });
            }
            let screen = state.screen_mut(slot);
            let at = if edge.before() { slot.pane } else { slot.pane + 1 };
            let column = screen.columns.get_mut(slot.column).ok_or(Reject::UnknownPane(source))?;
            column.note_inserted(slot.pane);
            column.panes.insert(at, new_pane);
            let screen_id = screen.id;
            state.insert_pane(new_pane);
            events.push(LayoutEvent::PaneCreated { pane: new_pane, screen: screen_id });
            state.move_tab(tab, source, new_pane, 0, events)?;
        }
        Checked::Column { tab, source, slot, position, new_pane, new_column, base_column } => {
            let screen = state.screen_mut(slot);
            if !screen.columns_active {
                screen.columns_active = true;
                if let Some(first) = screen.columns.first_mut() {
                    first.id = base_column;
                }
                events.push(LayoutEvent::ColumnCreated { column: base_column, screen: screen.id });
            }
            screen.columns.insert(position, Column::single(new_column, vec![new_pane]));
            let screen_id = screen.id;
            state.insert_pane(new_pane);
            events.push(LayoutEvent::ColumnCreated { column: new_column, screen: screen_id });
            events.push(LayoutEvent::PaneCreated { pane: new_pane, screen: screen_id });
            state.move_tab(tab, source, new_pane, 0, events)?;
        }
        Checked::NewWorkspace { tab, source, index, new_workspace, new_screen, new_pane } => {
            state.take_tab(tab, source, events)?;
            let position = index.unwrap_or(state.workspaces.len()).min(state.workspaces.len());
            state.workspaces.insert(
                position,
                Workspace {
                    id: new_workspace,
                    screens: vec![single_pane_screen(new_screen, new_pane)],
                },
            );
            state.panes.insert(new_pane, vec![tab]);
            events
                .push(LayoutEvent::WorkspaceCreated { workspace: new_workspace, index: position });
            events
                .push(LayoutEvent::ScreenCreated { screen: new_screen, workspace: new_workspace });
            events.push(LayoutEvent::PaneCreated { pane: new_pane, screen: new_screen });
            events.push(LayoutEvent::TabMoved { tab, from: source, to: new_pane, index: 0 });
        }
        Checked::IntoPane { tab, source, destination } => {
            let end = state.panes.get(&destination).map_or(0, Vec::len);
            state.move_tab(tab, source, destination, end, events)?;
        }
        Checked::IntoEmptyWorkspace { tab, source, workspace, new_screen, new_pane } => {
            state.take_tab(tab, source, events)?;
            let target = state
                .workspaces
                .iter_mut()
                .find(|candidate| candidate.id == workspace)
                .ok_or(Reject::UnknownWorkspace(workspace))?;
            target.screens.push(single_pane_screen(new_screen, new_pane));
            state.panes.insert(new_pane, vec![tab]);
            events.push(LayoutEvent::ScreenCreated { screen: new_screen, workspace });
            events.push(LayoutEvent::PaneCreated { pane: new_pane, screen: new_screen });
            events.push(LayoutEvent::TabMoved { tab, from: source, to: new_pane, index: 0 });
        }
        Checked::Rows(kind) => rows::apply(state, kind, events)?,
        Checked::Close { tab, pane } => {
            state.tabs.remove(&tab);
            events.push(LayoutEvent::TabClosed { tab, pane });
            state.take_tab(tab, pane, events)?;
        }
        Checked::RuntimeExited { runtime } => {
            // A runtime with no tab (a detached terminal) is not an error:
            // the store never rejects a host's lifecycle fact.
            for (tab, content) in &mut state.tabs {
                if content.runtime == runtime && !content.dead {
                    content.dead = true;
                    events.push(LayoutEvent::TabDied { tab: *tab });
                }
            }
        }
    }
    Ok(())
}
