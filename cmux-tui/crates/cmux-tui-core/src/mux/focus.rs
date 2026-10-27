//! Focus and navigation: directional pane neighbors, tab selection, and per-client and per-session focus memory.

use super::*;
use crate::panic_free::RecoverPoison;

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
        let Some((current_index, current)) =
            screen.layout_columns.iter().enumerate().find(|(_, column)| column.root.contains(pane))
        else {
            return layout_screen(&screen.root, column_area, Some(screen.active_pane));
        };
        let neighbor_index = match dir {
            Direction::Up | Direction::Down => None,
            Direction::Left => current_index.checked_sub(1),
            Direction::Right => current_index.checked_add(1),
        };
        let Some((neighbor_index, neighbor)) =
            neighbor_index.and_then(|index| Some((index, screen.layout_columns.get(index)?)))
        else {
            return layout_screen(&current.root, column_area, Some(screen.active_pane));
        };

        let (left, right) =
            if neighbor_index < current_index { (neighbor, current) } else { (current, neighbor) };
        let mut result = LayoutResult { virtual_width: 20_000, ..Default::default() };
        for (laid_out, x) in [(left, 0), (right, NAVIGATION_COLUMN_WIDTH)] {
            let mut column =
                layout_screen(&laid_out.root, Rect { x, ..column_area }, Some(screen.active_pane));
            result.panes.append(&mut column.panes);
            result.stacked_headers.extend(column.stacked_headers);
        }
        result
    }

    pub fn pane_neighbor(&self, pane: PaneId, dir: Direction) -> anyhow::Result<Option<PaneId>> {
        self.with_state(|state| {
            let Some(screen) = state
                .screen_of(pane)
                .and_then(|(wi, si)| state.workspaces.get(wi)?.screens.get(si))
            else {
                anyhow::bail!("unknown pane {pane}");
            };
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
    #[track_caller]
    pub fn select_tab_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: Option<PaneId>,
        index: Option<usize>,
        delta: Option<isize>,
    ) {
        let surface = {
            let state = self.state.lock().recover_poison();
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
            let Some(&surface) = pane.tabs.get(selected) else { return };
            surface
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
        let mut memory = self.client_focus_memory.lock().recover_poison();
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
            let memory = self.client_focus_memory.lock().recover_poison();
            memory.iter().find(|record| record.client_id == client_id).cloned()?
        };
        self.with_state(|state| state.panes.contains_key(&record.pane))
            .then_some((record.pane, record.tab))
    }

    /// Record the session's last reported focus from any client: the
    /// adoption default for a later attach without per-client memory.
    /// Never moves the live shared focus.
    pub fn record_session_focus(&self, pane: PaneId, tab: Option<usize>) {
        *self.last_reported_focus.lock().recover_poison() = Some((pane, tab));
    }

    /// The session's last reported focus, if its pane is still alive.
    pub fn session_focus(&self) -> Option<(PaneId, Option<usize>)> {
        let record = (*self.last_reported_focus.lock().recover_poison())?;
        self.with_state(|state| state.panes.contains_key(&record.0)).then_some(record)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selecting_the_active_tab_of_a_pane_with_a_stale_active_index_changes_nothing() {
        let mux = Mux::new_for_test("focus-stale-active-tab", SurfaceOptions::default());
        let first = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        mux.state.lock().unwrap().panes.get_mut(&pane).unwrap().active_tab = 5;

        mux.select_tab(Some(pane), None, None);

        assert_eq!(mux.with_state(|state| state.panes[&pane].active_tab), 5);
    }
}
