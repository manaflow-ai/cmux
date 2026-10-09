//! The open context menu: level stack, selection, search, scrolling and
//! pointer hit testing, plus the pane menu group layout.

use std::sync::Arc;

use cmux_tui_core::{PaneId, Rect};
use crossterm::event::KeyEvent;
use unicode_width::UnicodeWidthStr;

use crate::app::menu::{MenuItem, MenuLevel, MenuScrollbarDrag, MenuSearch};
use crate::app::{MenuAction, MenuActionResource};
use crate::ui::input::{InputEvent, TextInput};
use crate::ui::{viewport_drag_offset, viewport_jump_offset, viewport_thumb_geometry};

/// Right-click context menu overlay. The rect includes the border chrome;
/// action rows get a one-cell padding column on each side inside that border,
/// groups are divided by separator rows, and the hover/selection highlight
/// spans the content row including padding, leaving room for an overflow thumb.
pub struct ContextMenu {
    pub levels: Vec<MenuLevel>,
    pub(crate) search: Option<MenuSearch>,
    pub(in crate::app) right_press: (u16, u16),
    pub(in crate::app) right_drag_moved: bool,
    pub(in crate::app) scrollbar_drag: Option<MenuScrollbarDrag>,
    pub(in crate::app) captured_resources: Vec<(MenuAction, Option<MenuActionResource>)>,
}

impl ContextMenu {
    /// Horizontal padding between the menu edge and the item labels.
    pub const PAD: u16 = 1;

    #[cfg(test)]
    pub(in crate::app) fn at(x: u16, y: u16, groups: Vec<Vec<MenuAction>>) -> Self {
        Self::with_groups(
            x,
            y,
            groups
                .into_iter()
                .map(|group| group.into_iter().map(MenuItem::Action).collect())
                .collect(),
        )
    }

    pub(in crate::app) fn with_groups(x: u16, y: u16, groups: Vec<Vec<MenuItem>>) -> Self {
        let mut items = Vec::new();
        for group in groups.into_iter().filter(|group| !group.is_empty()) {
            if !items.is_empty() {
                items.push(MenuItem::Separator);
            }
            items.extend(group);
        }
        ContextMenu {
            levels: vec![MenuLevel::new(x.saturating_sub(1), y.saturating_sub(1), items)],
            search: None,
            right_press: (x, y),
            right_drag_moved: false,
            scrollbar_drag: None,
            captured_resources: Vec::new(),
        }
    }

    pub(in crate::app) fn searchable(
        x: u16,
        y: u16,
        label: impl Into<String>,
        placeholder: impl Into<String>,
        items: Vec<MenuItem>,
        fallback: Vec<MenuItem>,
    ) -> Self {
        let label = label.into();
        let placeholder = placeholder.into();
        let search_items: Arc<[MenuItem]> = items.into();
        let lowered_labels = search_items
            .iter()
            .map(|item| item.label().unwrap_or_default().to_lowercase())
            .collect::<Arc<[String]>>();
        let fallback: Arc<[MenuItem]> = fallback.into();
        let mut visible = fallback.to_vec();
        if !visible.is_empty() && !search_items.is_empty() {
            visible.push(MenuItem::Separator);
        }
        visible.extend(search_items.iter().cloned());
        let mut level = MenuLevel::new(x.saturating_sub(1), y.saturating_sub(1), visible);
        let search_width = label.width() + placeholder.width() + 9;
        level.rect.width = level.rect.width.max(search_width.min(u16::MAX as usize) as u16);
        ContextMenu {
            levels: vec![level],
            search: Some(MenuSearch {
                label,
                placeholder,
                input: TextInput::new(String::new()),
                items: search_items,
                lowered_labels,
                fallback,
            }),
            right_press: (x, y),
            right_drag_moved: false,
            scrollbar_drag: None,
            captured_resources: Vec::new(),
        }
    }

    fn refresh_search(&mut self) {
        let Some(search) = self.search.as_ref() else { return };
        let query = search.input.as_str().trim().to_lowercase();
        let terms = query.split_whitespace().collect::<Vec<_>>();
        let matches = search
            .items
            .iter()
            .zip(search.lowered_labels.iter())
            .filter(|(_, label)| terms.is_empty() || terms.iter().all(|term| label.contains(term)))
            .map(|(item, _)| item.clone())
            .collect::<Vec<_>>();
        let mut visible = search.fallback.to_vec();
        if !matches.is_empty() && !search.fallback.is_empty() {
            visible.push(MenuItem::Separator);
        }
        let first_match = (!terms.is_empty() && !matches.is_empty()).then_some(visible.len());
        visible.extend(matches);
        self.levels.truncate(1);
        self.scrollbar_drag = None;
        if let Some(level) = self.levels.first_mut() {
            level.replace_items(visible);
            if let Some(first_match) = first_match {
                level.selected = first_match;
                level.ensure_selection_visible();
            }
        }
    }

    pub(in crate::app) fn insert_search_text(&mut self, text: &str) -> bool {
        let changed = self.search.as_mut().is_some_and(|search| search.input.insert_str(text));
        if changed {
            self.refresh_search();
        }
        changed
    }

    pub(in crate::app) fn handle_search_key(&mut self, key: &KeyEvent) -> bool {
        let Some(search) = self.search.as_mut() else { return false };
        let changed = search.input.handle_key(key) == InputEvent::Changed;
        if changed {
            self.refresh_search();
        }
        true
    }

    pub(in crate::app) fn actions(&self) -> Vec<MenuAction> {
        fn collect(items: &[MenuItem], actions: &mut Vec<MenuAction>) {
            for item in items {
                if let Some(action) = item.action() {
                    actions.push(action);
                } else if let Some(items) = item.submenu() {
                    collect(items, actions);
                }
            }
        }

        let mut actions = Vec::new();
        if let Some(search) = self.search.as_ref() {
            collect(&search.items, &mut actions);
            collect(&search.fallback, &mut actions);
        } else if let Some(level) = self.levels.first() {
            collect(&level.all_items, &mut actions);
        }
        actions
    }

    pub(in crate::app) fn captured_resource(
        &self,
        action: MenuAction,
    ) -> Option<Option<MenuActionResource>> {
        self.captured_resources
            .iter()
            .find_map(|(candidate, resource)| (*candidate == action).then(|| resource.clone()))
    }

    /// The item row at a screen cell. Border cells are dead chrome and
    /// never activate an item.
    #[cfg(test)]
    pub fn item_at(&self, x: u16, y: u16) -> Option<usize> {
        self.hit_at(x, y).filter(|(depth, _)| *depth == 0).map(|(_, item)| item)
    }

    pub fn hit_at(&self, x: u16, y: u16) -> Option<(usize, usize)> {
        let (depth, level) =
            self.levels.iter().enumerate().rev().find(|(_, level)| level.rect.contains(x, y))?;
        if level.scrollbar_track().is_some_and(|track| track.contains(x, y)) {
            return None;
        }
        let rect = level.rect;
        let right = rect.x + rect.width.saturating_sub(1);
        let bottom = rect.y + rect.height.saturating_sub(1);
        if x == rect.x || y == rect.y || x == right || y == bottom {
            return None;
        }
        let row = level.scroll_offset + (y - rect.y - 1) as usize;
        level.items.get(row).filter(|item| item.selectable()).map(|_| (depth, row))
    }

    pub fn contains(&self, x: u16, y: u16) -> bool {
        self.levels.iter().any(|level| level.rect.contains(x, y))
    }

    pub(in crate::app) fn scrollbar_at(&self, x: u16, y: u16) -> Option<(usize, Rect)> {
        self.levels.iter().enumerate().rev().find_map(|(depth, level)| {
            level.scrollbar_track().filter(|track| track.contains(x, y)).map(|track| (depth, track))
        })
    }

    pub(in crate::app) fn scroll_at(&mut self, x: u16, y: u16, down: bool) -> bool {
        let Some(depth) = self
            .levels
            .iter()
            .enumerate()
            .rev()
            .find(|(_, level)| level.rect.contains(x, y))
            .map(|(depth, _)| depth)
        else {
            return false;
        };
        self.levels.truncate(depth + 1);
        self.scrollbar_drag = None;
        self.levels[depth].scroll_rows(if down { 3 } else { -3 })
    }

    pub(in crate::app) fn start_scrollbar_drag(&mut self, x: u16, y: u16) -> bool {
        let Some((depth, track)) = self.scrollbar_at(x, y) else {
            return false;
        };
        self.levels.truncate(depth + 1);
        let level = &mut self.levels[depth];
        let relative = y.saturating_sub(track.y).min(track.height.saturating_sub(1));
        let (thumb_y, thumb_height) = viewport_thumb_geometry(
            level.items.len(),
            level.visible_rows,
            level.scroll_offset,
            track.height,
        );
        if relative < thumb_y || relative >= thumb_y.saturating_add(thumb_height) {
            let offset =
                viewport_jump_offset(level.items.len(), level.visible_rows, track.height, relative);
            level.set_scroll_offset(offset);
        }
        self.scrollbar_drag =
            Some(MenuScrollbarDrag { depth, anchor_y: y, anchor_offset: level.scroll_offset });
        true
    }

    pub(in crate::app) fn drag_scrollbar(&mut self, y: u16) -> bool {
        let Some(drag) = self.scrollbar_drag else {
            return false;
        };
        let Some(level) = self.levels.get_mut(drag.depth) else {
            self.scrollbar_drag = None;
            return false;
        };
        let Some(track) = level.scrollbar_track() else {
            self.scrollbar_drag = None;
            return false;
        };
        let offset = viewport_drag_offset(
            level.items.len(),
            level.visible_rows,
            track.height,
            drag.anchor_offset,
            y as i128 - drag.anchor_y as i128,
        );
        level.set_scroll_offset(offset)
    }

    pub(in crate::app) fn finish_scrollbar_drag(&mut self) -> bool {
        self.scrollbar_drag.take().is_some()
    }

    pub(crate) fn scrollbar_dragging(&self, depth: usize) -> bool {
        self.scrollbar_drag.is_some_and(|drag| drag.depth == depth)
    }

    pub(in crate::app) fn selected_action(&self) -> Option<MenuAction> {
        let level = self.levels.last()?;
        if !level.selection_active {
            return None;
        }
        level.items.get(level.selected).and_then(MenuItem::action)
    }

    pub(in crate::app) fn targets_provider_state(&self) -> bool {
        fn item_targets_provider(item: &MenuItem) -> bool {
            match item {
                MenuItem::Action(
                    MenuAction::SelectProviderScope(_)
                    | MenuAction::InvokeProviderAction(_)
                    | MenuAction::RenameManagedMachine(_)
                    | MenuAction::DeleteManagedMachine(_)
                    | MenuAction::RestoreManagedMachine(_)
                    | MenuAction::PurgeManagedMachine(_)
                    | MenuAction::RenameManagedWorkspace(_)
                    | MenuAction::DeleteManagedWorkspace(_)
                    | MenuAction::RestoreManagedWorkspace(_)
                    | MenuAction::PurgeManagedWorkspace(_),
                )
                | MenuItem::LabeledAction {
                    action:
                        MenuAction::SelectProviderScope(_)
                        | MenuAction::InvokeProviderAction(_)
                        | MenuAction::RenameManagedMachine(_)
                        | MenuAction::DeleteManagedMachine(_)
                        | MenuAction::RestoreManagedMachine(_)
                        | MenuAction::PurgeManagedMachine(_)
                        | MenuAction::RenameManagedWorkspace(_)
                        | MenuAction::DeleteManagedWorkspace(_)
                        | MenuAction::RestoreManagedWorkspace(_)
                        | MenuAction::PurgeManagedWorkspace(_),
                    ..
                } => true,
                MenuItem::Submenu { items, .. } => items.iter().any(item_targets_provider),
                MenuItem::Action(_)
                | MenuItem::ActionWithShortcut { .. }
                | MenuItem::LabeledAction { .. }
                | MenuItem::Separator => false,
            }
        }

        if let Some(search) = self.search.as_ref() {
            search.items.iter().chain(search.fallback.iter()).any(item_targets_provider)
        } else {
            self.levels.iter().any(|level| level.all_items.iter().any(item_targets_provider))
        }
    }

    pub(in crate::app) fn action_at(&self, depth: usize, item: usize) -> Option<MenuAction> {
        self.levels.get(depth)?.items.get(item).and_then(MenuItem::action)
    }

    pub(in crate::app) fn open_selected_submenu(&mut self) -> bool {
        let depth = self.levels.len().saturating_sub(1);
        let Some(parent) = self.levels.get(depth) else {
            return false;
        };
        let Some(items) = parent.items.get(parent.selected).and_then(MenuItem::submenu) else {
            return false;
        };
        let x = parent.rect.x.saturating_add(parent.rect.width.saturating_sub(1));
        let y = parent
            .rect
            .y
            .saturating_add(1)
            .saturating_add(parent.selected.saturating_sub(parent.scroll_offset) as u16);
        self.levels.push(MenuLevel::new(x, y, items.to_vec()));
        true
    }

    pub(in crate::app) fn close_submenu(&mut self) -> bool {
        if self.levels.len() > 1 {
            self.levels.pop();
            if self.scrollbar_drag.is_some_and(|drag| drag.depth >= self.levels.len()) {
                self.scrollbar_drag = None;
            }
            true
        } else {
            false
        }
    }

    pub(in crate::app) fn select_at(&mut self, depth: usize, item: usize) -> bool {
        let had_deeper_level = self.levels.len() != depth + 1;
        let Some(level) = self.levels.get_mut(depth) else { return false };
        if !level.items.get(item).is_some_and(MenuItem::selectable) {
            return false;
        }
        let changed = !level.selection_active || level.selected != item || had_deeper_level;
        level.selected = item;
        level.selection_active = true;
        level.ensure_selection_visible();
        self.levels.truncate(depth + 1);
        self.open_selected_submenu();
        changed || self.levels.len() > depth + 1
    }

    /// Keep every action row visible when separators are the only reason the
    /// menu exceeds the available height. Full grouping returns after a resize.
    #[cfg(test)]
    pub fn fit_to_rows(&mut self, max_rows: usize) {
        if let Some(level) = self.levels.first_mut() {
            level.fit_to_rows(max_rows);
        }
    }

    pub(in crate::app) fn select_previous(&mut self) {
        let Some(level) = self.levels.last_mut() else { return };
        if !level.selection_active {
            if let Some(index) = level.items.iter().rposition(MenuItem::selectable) {
                level.selected = index;
                level.selection_active = true;
                level.ensure_selection_visible();
            }
            return;
        }
        if let Some(index) = level
            .items
            .get(..level.selected)
            .and_then(|items| items.iter().rposition(MenuItem::selectable))
        {
            level.selected = index;
            level.ensure_selection_visible();
            let depth = self.levels.len();
            self.levels.truncate(depth);
        }
    }

    pub(in crate::app) fn select_next(&mut self) {
        let Some(level) = self.levels.last_mut() else { return };
        if !level.selection_active {
            if let Some(index) = level.items.iter().position(MenuItem::selectable) {
                level.selected = index;
                level.selection_active = true;
                level.ensure_selection_visible();
            }
            return;
        }
        let start = level.selected.saturating_add(1);
        if let Some(offset) =
            level.items.get(start..).and_then(|items| items.iter().position(MenuItem::selectable))
        {
            level.selected += offset + 1;
            level.ensure_selection_visible();
        }
    }

    pub(in crate::app) fn select_first(&mut self) {
        let Some(level) = self.levels.last_mut() else { return };
        if let Some(index) = level.items.iter().position(MenuItem::selectable) {
            level.selected = index;
            level.selection_active = true;
            level.ensure_selection_visible();
        }
    }

    pub(in crate::app) fn select_last(&mut self) {
        let Some(level) = self.levels.last_mut() else { return };
        if let Some(index) = level.items.iter().rposition(MenuItem::selectable) {
            level.selected = index;
            level.selection_active = true;
            level.ensure_selection_visible();
        }
    }
}

pub(in crate::app) fn pane_context_menu_groups(
    pane: PaneId,
    is_browser: bool,
    external_browser: bool,
) -> Vec<Vec<MenuAction>> {
    let mut browser_actions = Vec::new();
    if is_browser {
        browser_actions.extend([
            MenuAction::BrowserBack(pane),
            MenuAction::BrowserForward(pane),
            MenuAction::BrowserReload(pane),
            MenuAction::BrowserEditUrl(pane),
            MenuAction::BrowserCopyUrl(pane),
        ]);
        if external_browser {
            browser_actions.push(MenuAction::BrowserActivate(pane));
        }
    }
    vec![
        vec![MenuAction::RenameTab(pane), MenuAction::CloseTab(pane)],
        vec![
            MenuAction::NewPaneSmart(pane),
            MenuAction::NewTab(pane),
            MenuAction::NewBrowserTab(pane),
        ],
        browser_actions,
        vec![
            MenuAction::SplitRight(pane),
            MenuAction::SplitDown(pane),
            MenuAction::ClosePane(pane),
        ],
        vec![MenuAction::CopyTabId(pane), MenuAction::CopyPaneId(pane)],
    ]
}
