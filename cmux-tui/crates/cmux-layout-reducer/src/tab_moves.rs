//! The tab moves the ops share: take a tab out of a pane (removing an
//! emptied pane, column and screen), place it, and move it between panes.

use crate::{LayoutEvent, LayoutState, PaneId, Reject, TabId};

impl LayoutState {
    /// Remove `tab` from `pane`, removing the pane (and an emptied column
    /// and screen) when it was the pane's last tab. Callers checked that
    /// `pane` exists; a missing one rejects the op (`apply` works on a copy).
    pub(crate) fn take_tab(
        &mut self,
        tab: TabId,
        pane: PaneId,
        events: &mut Vec<LayoutEvent>,
    ) -> Result<(), Reject> {
        let tabs = self.panes.get_mut(&pane).ok_or(Reject::UnknownPane(pane))?;
        tabs.retain(|candidate| *candidate != tab);
        if tabs.is_empty() {
            self.remove_pane(pane, events);
        }
        Ok(())
    }

    pub(crate) fn remove_pane(&mut self, pane: PaneId, events: &mut Vec<LayoutEvent>) {
        self.panes.remove(&pane);
        events.push(LayoutEvent::PaneRemoved { pane });
        let Some(slot) = self.slot(pane) else { return };
        let workspace = &mut self.workspaces[slot.workspace];
        let screen = &mut workspace.screens[slot.screen];
        let column = &mut screen.columns[slot.column];
        column.note_removed(slot.pane, events);
        column.panes.remove(slot.pane);
        if column.panes.is_empty() {
            let column = screen.columns.remove(slot.column);
            if screen.columns_active {
                events.push(LayoutEvent::ColumnRemoved { column: column.id });
            }
        }
        if screen.columns.is_empty() {
            let screen = workspace.screens.remove(slot.screen);
            events.push(LayoutEvent::ScreenRemoved { screen: screen.id });
        }
    }

    /// Put `tab` at insertion `index` of `pane`.
    pub(crate) fn place_tab(
        &mut self,
        tab: TabId,
        pane: PaneId,
        index: usize,
    ) -> Result<usize, Reject> {
        let tabs = self.panes.get_mut(&pane).ok_or(Reject::UnknownPane(pane))?;
        let index = index.min(tabs.len());
        tabs.insert(index, tab);
        Ok(index)
    }

    /// The `MoveTab` step, shared by the ops that end in an existing pane.
    pub(crate) fn move_tab(
        &mut self,
        tab: TabId,
        source: PaneId,
        target: PaneId,
        index: usize,
        events: &mut Vec<LayoutEvent>,
    ) -> Result<(), Reject> {
        if source == target {
            let tabs = self.panes.get_mut(&source).ok_or(Reject::UnknownPane(source))?;
            let old = tabs
                .iter()
                .position(|candidate| *candidate == tab)
                .ok_or(Reject::UnknownTab(tab))?;
            let new = if index > old { index - 1 } else { index }.min(tabs.len() - 1);
            if new != old {
                let moved = tabs.remove(old);
                tabs.insert(new, moved);
                events.push(LayoutEvent::TabMoved { tab, from: source, to: target, index: new });
            }
            return Ok(());
        }
        self.take_tab(tab, source, events)?;
        let index = self.place_tab(tab, target, index)?;
        events.push(LayoutEvent::TabMoved { tab, from: source, to: target, index });
        Ok(())
    }
}
