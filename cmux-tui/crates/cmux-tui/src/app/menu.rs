//! Context menu model: menu items, menu levels with search and scrollbar state. The `ContextMenu`
//! navigation state and the per-surface menu items live in the child modules.

use std::sync::Arc;

use cmux_tui_core::Rect;
use unicode_width::UnicodeWidthStr;

use crate::app::MenuAction;
use crate::app::menu::context_menu::ContextMenu;
use crate::ui::input::TextInput;
use crate::ui::viewport_thumb_geometry;

pub(super) mod context_menu;
pub(super) mod items;

/// One row in a context menu. Separators divide related action groups and
/// are skipped by keyboard and mouse selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuItem {
    Action(MenuAction),
    ActionWithShortcut { action: MenuAction, shortcut: String },
    LabeledAction { label: String, action: MenuAction },
    Submenu { label: String, items: Vec<MenuItem> },
    Separator,
}

impl MenuItem {
    pub fn action(&self) -> Option<MenuAction> {
        match self {
            MenuItem::Action(action)
            | MenuItem::ActionWithShortcut { action, .. }
            | MenuItem::LabeledAction { action, .. } => Some(*action),
            MenuItem::Submenu { .. } | MenuItem::Separator => None,
        }
    }

    pub fn label(&self) -> Option<&str> {
        match self {
            MenuItem::Action(action) | MenuItem::ActionWithShortcut { action, .. } => {
                Some(action.label())
            }
            MenuItem::LabeledAction { label, .. } => Some(label),
            MenuItem::Submenu { label, .. } => Some(label),
            MenuItem::Separator => None,
        }
    }

    pub fn shortcut(&self) -> Option<&str> {
        match self {
            MenuItem::ActionWithShortcut { shortcut, .. } => Some(shortcut),
            _ => None,
        }
    }

    pub(super) fn selectable(&self) -> bool {
        !matches!(self, MenuItem::Separator)
    }

    pub(super) fn submenu(&self) -> Option<&[MenuItem]> {
        match self {
            MenuItem::Submenu { items, .. } => Some(items),
            _ => None,
        }
    }
}

pub(super) fn menu_scrollbar_track(rect: Rect, total_rows: usize) -> Option<Rect> {
    let visible_rows = usize::from(rect.height.saturating_sub(2));
    (rect.width >= 3 && visible_rows > 0 && total_rows > visible_rows).then_some(Rect {
        x: rect.x + rect.width - 2,
        y: rect.y + 1,
        width: 1,
        height: visible_rows as u16,
    })
}

pub struct MenuLevel {
    pub items: Arc<[MenuItem]>,
    pub(super) all_items: Arc<[MenuItem]>,
    pub selected: usize,
    pub selection_active: bool,
    pub scroll_offset: usize,
    pub(super) visible_rows: usize,
    pub(super) fitted_rows: Option<usize>,
    pub rect: Rect,
}

impl MenuLevel {
    pub(super) fn new(x: u16, y: u16, items: Vec<MenuItem>) -> Self {
        let content_w = items
            .iter()
            .filter_map(|item| {
                let label = item.label()?;
                let suffix = item
                    .shortcut()
                    .map(|shortcut| shortcut.width() + 2)
                    .unwrap_or(if matches!(item, MenuItem::Submenu { .. }) { 2 } else { 0 });
                Some(label.width() + suffix)
            })
            .max()
            .unwrap_or(0) as u16;
        let width = content_w + 2 + ContextMenu::PAD * 2 + 2;
        let height = items.len() as u16 + 2;
        let selected = items.iter().position(MenuItem::selectable).unwrap_or(0);
        let visible_rows = items.len();
        let items: Arc<[MenuItem]> = items.into();
        Self {
            all_items: items.clone(),
            items,
            selected,
            selection_active: true,
            scroll_offset: 0,
            visible_rows,
            fitted_rows: None,
            rect: Rect { x, y, width, height },
        }
    }

    pub fn fit_to_rows(&mut self, max_rows: usize) {
        if self.fitted_rows == Some(max_rows) {
            return;
        }
        let selected_item = self.items.get(self.selected).cloned();
        let selectable_count = self.all_items.iter().filter(|item| item.selectable()).count();
        let mut separator_budget = max_rows.saturating_sub(selectable_count);
        self.items = if max_rows >= self.all_items.len() {
            self.all_items.clone()
        } else {
            self.all_items
                .iter()
                .filter(|item| match item {
                    MenuItem::Separator if separator_budget > 0 => {
                        separator_budget -= 1;
                        true
                    }
                    MenuItem::Separator => false,
                    _ => true,
                })
                .cloned()
                .collect::<Vec<_>>()
                .into()
        };
        self.selected = selected_item
            .and_then(|selected| self.items.iter().position(|item| *item == selected))
            .or_else(|| self.items.iter().position(MenuItem::selectable))
            .unwrap_or(0);
        self.visible_rows = self.items.len().min(max_rows);
        self.fitted_rows = Some(max_rows);
        self.ensure_selection_visible();
        self.rect.height = self.visible_rows as u16 + 2;
    }

    pub(super) fn ensure_selection_visible(&mut self) {
        if !self.selection_active || self.visible_rows == 0 || self.items.is_empty() {
            self.scroll_offset = 0;
            return;
        }
        if self.selected < self.scroll_offset {
            self.scroll_offset = self.selected;
        } else if self.selected >= self.scroll_offset + self.visible_rows {
            self.scroll_offset = self.selected + 1 - self.visible_rows;
        }
        self.scroll_offset =
            self.scroll_offset.min(self.items.len().saturating_sub(self.visible_rows));
    }

    pub(super) fn set_scroll_offset(&mut self, offset: usize) -> bool {
        let offset = offset.min(self.items.len().saturating_sub(self.visible_rows));
        if self.scroll_offset == offset {
            return false;
        }
        self.scroll_offset = offset;
        let end = offset.saturating_add(self.visible_rows).min(self.items.len());
        if (self.selected < offset || self.selected >= end)
            && let Some(relative) = self.items[offset..end].iter().position(MenuItem::selectable)
        {
            self.selected = offset + relative;
        }
        true
    }

    pub(super) fn scroll_rows(&mut self, delta: isize) -> bool {
        self.set_scroll_offset(self.scroll_offset.saturating_add_signed(delta))
    }

    pub(crate) fn scrollbar_track(&self) -> Option<Rect> {
        menu_scrollbar_track(self.rect, self.items.len())
    }

    pub(crate) fn scrollbar(&self) -> Option<(Rect, (u16, u16))> {
        let track = self.scrollbar_track()?;
        let thumb = viewport_thumb_geometry(
            self.items.len(),
            self.visible_rows,
            self.scroll_offset,
            track.height,
        );
        Some((track, thumb))
    }

    pub(super) fn replace_items(&mut self, items: Vec<MenuItem>) {
        let items: Arc<[MenuItem]> = items.into();
        self.all_items = items.clone();
        self.items = items;
        self.selected = self.items.iter().position(MenuItem::selectable).unwrap_or(0);
        self.selection_active = true;
        self.scroll_offset = 0;
        self.visible_rows = self.items.len();
        self.fitted_rows = None;
        self.rect.height = self.items.len() as u16 + 2;
    }
}

pub(crate) struct MenuSearch {
    pub label: String,
    pub placeholder: String,
    pub input: TextInput,
    pub(super) items: Arc<[MenuItem]>,
    pub(super) lowered_labels: Arc<[String]>,
    pub(super) fallback: Arc<[MenuItem]>,
}

#[derive(Clone, Copy)]
pub(super) struct MenuScrollbarDrag {
    pub(super) depth: usize,
    pub(super) anchor_y: u16,
    pub(super) anchor_offset: usize,
}
