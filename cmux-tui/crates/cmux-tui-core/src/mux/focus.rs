//! Focus and navigation: directional pane neighbors, tab selection, and per-client and per-session focus memory.

use super::*;

impl Mux {
    pub(super) fn pane_navigation_layout(
        screen: &Screen,
        pane: PaneId,
        dir: Direction,
    ) -> LayoutResult {
        const NAVIGATION_COLUMN_WIDTH: u16 = 10_000;
        let column_area = Rect { x: 0, y: 0, width: NAVIGATION_COLUMN_WIDTH, height: 10_000 };
        if !screen.layout_columns_active() {
            return layout_screen(&screen.root, column_area, Some(screen.active_pane));
        }
        let Some(current_index) =
            screen.layout_columns.iter().position(|column| column.root.contains(pane))
        else {
            return layout_screen(&screen.root, column_area, Some(screen.active_pane));
        };
        let neighbor_index = match dir {
            Direction::Up | Direction::Down => None,
            Direction::Left => current_index.checked_sub(1),
            Direction::Right => {
                current_index.checked_add(1).filter(|index| *index < screen.layout_columns.len())
            }
        };
        let Some(neighbor_index) = neighbor_index else {
            return layout_screen(
                &screen.layout_columns[current_index].root,
                column_area,
                Some(screen.active_pane),
            );
        };

        let (left_index, right_index) = if neighbor_index < current_index {
            (neighbor_index, current_index)
        } else {
            (current_index, neighbor_index)
        };
        let mut result = LayoutResult { virtual_width: 20_000, ..Default::default() };
        for (index, x) in [(left_index, 0), (right_index, NAVIGATION_COLUMN_WIDTH)] {
            let mut column = layout_screen(
                &screen.layout_columns[index].root,
                Rect { x, ..column_area },
                Some(screen.active_pane),
            );
            result.panes.append(&mut column.panes);
            result.stacked_headers.extend(column.stacked_headers);
        }
        result
    }

    pub fn pane_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout = Self::pane_navigation_layout(screen, pane, dir);
            Ok(layout.neighbor(pane, dx, dy))
        })
    }

    #[cfg(test)]
    pub(super) fn pane_focus_neighbor(
        &self,
        pane: PaneId,
        dir: Direction,
    ) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some((wi, si)) = state.screen_of(pane) else {
                anyhow::bail!("unknown pane {pane}");
            };
            let screen = &state.workspaces[wi].screens[si];
            let (dx, dy) = dir.delta();
            let layout = Self::pane_navigation_layout(screen, pane, dir);
            Ok(layout.neighbor_by_recency(pane, dx, dy, |candidate| {
                state.panes.get(&candidate).map(|pane| pane.focused_at).unwrap_or_default()
            }))
        })
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let surface = {
            let state = self.state.lock().unwrap();
            let Some(target) = pane.or_else(|| state.active_pane()) else { return };
            let Some(pane) = state.panes.get(&target) else { return };
            let len = pane.tabs.len();
            if len == 0 {
                return;
            }
            let selected = if let Some(index) = index.filter(|index| *index < len) {
                index
            } else if let Some(delta) = delta {
                ((pane.active_tab as isize + delta).rem_euclid(len as isize)) as usize
            } else {
                pane.active_tab
            };
            pane.tabs[selected]
        };
        let Some(selectors) = self.ordinary_tab_selectors(surface) else { return };
        if self.commit_ordinary_tab_selection(actor, selectors).is_err() {
            return;
        }
        self.emit(MuxEvent::TreeChanged);
    }

    /// Remember one client's reported focus for its own later reconnection.
    /// Most-recent-first eviction keeps the memory bounded.
    pub fn remember_client_focus(&self, client_id: String, pane: PaneId, tab: Option<usize>) {
        let mut memory = self.client_focus_memory.lock().unwrap();
        memory.retain(|record| record.client_id != client_id);
        memory.push(ClientFocusRecord { client_id, pane, tab });
        if memory.len() > CLIENT_FOCUS_MEMORY_LIMIT {
            let excess = memory.len() - CLIENT_FOCUS_MEMORY_LIMIT;
            memory.drain(..excess);
        }
    }

    /// The remembered focus for one client, if its pane is still alive.
    pub fn client_focus(&self, client_id: &str) -> Option<(PaneId, Option<usize>)> {
        let record = {
            let memory = self.client_focus_memory.lock().unwrap();
            memory.iter().find(|record| record.client_id == client_id).cloned()?
        };
        self.with_state(|state| state.panes.contains_key(&record.pane))
            .then_some((record.pane, record.tab))
    }

    /// Record the session's last reported focus from any client: the
    /// adoption default for a later attach without per-client memory.
    /// Never moves the live shared focus.
    pub fn record_session_focus(&self, pane: PaneId, tab: Option<usize>) {
        *self.last_reported_focus.lock().unwrap() = Some((pane, tab));
    }

    /// The session's last reported focus, if its pane is still alive.
    pub fn session_focus(&self) -> Option<(PaneId, Option<usize>)> {
        let record = (*self.last_reported_focus.lock().unwrap())?;
        self.with_state(|state| state.panes.contains_key(&record.0)).then_some(record)
    }
}
