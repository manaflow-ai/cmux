//! The vertical tab list's rows (`VerticalTabListLayout`): pinned tabs as a wrapping grid of
//! icon tiles, a separator, one row per tab with each group's tabs under a header of its color
//! (hidden while it is collapsed), then New Tab; and where a dragged tab lands. Content
//! coordinates: y grows down from the top of the list, before scrolling.

use serde::{Deserialize, Serialize};

/// Every size the vertical list uses (`VerticalTabListMetrics`; the corner radius draws only).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Metrics {
    pub row_height: f64,
    pub row_spacing: f64,
    /// Horizontal inset of the rows from the list's edges.
    pub padding: f64,
    /// Space above the first row and below the last.
    pub vertical_padding: f64,
    pub icon_size: f64,
    pub header_height: f64,
    pub icons_only_header_height: f64,
    pub separator_height: f64,
    pub group_indent: f64,
    pub group_line_width: f64,
    pub tile_size: f64,
    pub tile_spacing: f64,
}

impl Default for Metrics {
    fn default() -> Self {
        Self {
            row_height: 28.0,
            row_spacing: 1.0,
            padding: 6.0,
            vertical_padding: 6.0,
            icon_size: 16.0,
            header_height: 24.0,
            icons_only_header_height: 8.0,
            separator_height: 9.0,
            group_indent: 8.0,
            group_line_width: 2.0,
            tile_size: 32.0,
            tile_spacing: 4.0,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const ZERO: Rect = Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }

    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }

    /// Half-open, as `CGRect.contains`.
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.max_x() && y >= self.y && y < self.max_y()
    }
}

/// A tab as the list reads it (`TabItem`'s id, pinned flag and group).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tab {
    pub id: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub id: String,
    #[serde(default)]
    pub collapsed: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "camelCase")]
pub enum RowKind {
    Pinned(String),
    Tab(String),
    GroupHeader(String),
    Separator,
    NewTab,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    #[serde(flatten)]
    pub kind: RowKind,
    pub frame: Rect,
    /// The group a tab row belongs to, or a header's group.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// A tab's index in `tabs` (display order, pinned first).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
}

/// A group's line along its shown tabs, or its pane from header to last shown member.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GroupLine {
    pub group: String,
    pub frame: Rect,
}

/// Where a dragged tab would land: before `tabs[index]` (`tabs.len()`: at the end), inside
/// `group` or outside every group, and the insertion mark to draw.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DropSlot {
    pub index: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    pub indicator: Rect,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    pub rows: Vec<Row>,
    pub group_lines: Vec<GroupLine>,
    pub group_panes: Vec<GroupLine>,
    pub content_height: f64,
    pub pinned_columns: usize,
}

/// A pane or line being drawn: its group and top.
struct Start {
    group: String,
    y: f64,
}

/// The list's inputs, kept for lookups and drop slots.
pub struct List<'a> {
    pub tabs: &'a [Tab],
    pub groups: &'a [Group],
    pub icons_only: bool,
    pub width: f64,
    pub metrics: Metrics,
}

impl List<'_> {
    fn row_width(&self) -> f64 {
        (self.width - 2.0 * self.metrics.padding).max(0.0)
    }

    fn group(&self, id: Option<&str>) -> Option<&Group> {
        let id = id?;
        self.groups.iter().find(|group| group.id == id)
    }

    /// Every row, line and pane, `tabs` in `TabStripModel.orderedTabs` order.
    pub fn layout(&self, shows_new_tab: bool) -> Layout {
        let m = self.metrics;
        let mut out = Layout {
            rows: Vec::new(),
            group_lines: Vec::new(),
            group_panes: Vec::new(),
            content_height: 0.0,
            pinned_columns: 1,
        };
        let has_more = shows_new_tab || self.tabs.iter().any(|tab| !tab.pinned);
        let mut y = self.place_pinned(&mut out, m.vertical_padding, has_more);
        y = self.place_unpinned(&mut out, y);
        if shows_new_tab {
            out.rows.push(Row {
                kind: RowKind::NewTab,
                frame: Rect::new(m.padding, y, self.row_width(), m.row_height),
                group: None,
                index: None,
            });
            y += m.row_height + m.row_spacing;
        }
        let placed_any = out.rows.iter().any(|row| !matches!(row.kind, RowKind::Pinned(_)));
        out.content_height = if placed_any { y - m.row_spacing } else { y } + m.vertical_padding;
        out
    }

    fn place_pinned(&self, out: &mut Layout, top: f64, has_more: bool) -> f64 {
        let pinned: Vec<usize> =
            (0..self.tabs.len()).filter(|&index| self.tabs[index].pinned).collect();
        if pinned.is_empty() {
            return top;
        }
        let m = self.metrics;
        let columns = if self.icons_only {
            1
        } else {
            // `Int(_)` truncates toward zero.
            (((self.row_width() + m.tile_spacing) / (m.tile_size + m.tile_spacing))
                .trunc()
                .max(1.0)) as usize
        };
        out.pinned_columns = columns;
        for (n, &index) in pinned.iter().enumerate() {
            let (column, line) = (n % columns, n / columns);
            let x = if self.icons_only {
                ((self.width - m.tile_size) / 2.0).round()
            } else {
                m.padding + column as f64 * (m.tile_size + m.tile_spacing)
            };
            let frame = Rect::new(
                x,
                top + line as f64 * (m.tile_size + m.tile_spacing),
                m.tile_size,
                m.tile_size,
            );
            out.rows.push(Row {
                kind: RowKind::Pinned(self.tabs[index].id.clone()),
                frame,
                group: None,
                index: Some(index),
            });
        }
        let lines = pinned.len().div_ceil(columns);
        let mut y = top + lines as f64 * m.tile_size + (lines as f64 - 1.0) * m.tile_spacing;
        if !has_more {
            return y;
        }
        out.rows.push(Row {
            kind: RowKind::Separator,
            frame: Rect::new(m.padding, y, self.row_width(), m.separator_height),
            group: None,
            index: None,
        });
        y += m.separator_height;
        y
    }

    fn place_unpinned(&self, out: &mut Layout, top: f64) -> f64 {
        let m = self.metrics;
        let row_width = self.row_width();
        let mut y = top;
        let mut current: Option<String> = None;
        let mut line_start: Option<Start> = None;
        let mut pane_start: Option<Start> = None;
        let mut last_bottom = y;
        let end_line =
            |out: &mut Layout, line: &mut Option<Start>, pane: &mut Option<Start>, bottom: f64| {
                if let Some(start) = pane.take() {
                    out.group_panes.push(GroupLine {
                        group: start.group,
                        frame: Rect::new(m.padding, start.y, row_width, bottom - start.y),
                    });
                }
                if let Some(start) = line.take()
                    && bottom > start.y
                {
                    let x = if self.icons_only {
                        1.0
                    } else {
                        m.padding + (m.group_indent - m.group_line_width) / 2.0
                    };
                    out.group_lines.push(GroupLine {
                        group: start.group,
                        frame: Rect::new(x, start.y, m.group_line_width, bottom - start.y),
                    });
                }
            };
        for (index, tab) in self.tabs.iter().enumerate() {
            if tab.pinned {
                continue;
            }
            let owner = self.group(tab.group.as_deref());
            if owner.map(|group| &group.id) != current.as_ref() {
                end_line(out, &mut line_start, &mut pane_start, last_bottom);
                current = owner.map(|group| group.id.clone());
                if let Some(owner) = owner {
                    let height =
                        if self.icons_only { m.icons_only_header_height } else { m.header_height };
                    out.rows.push(Row {
                        kind: RowKind::GroupHeader(owner.id.clone()),
                        frame: Rect::new(m.padding, y, row_width, height),
                        group: Some(owner.id.clone()),
                        index: None,
                    });
                    pane_start = Some(Start { group: owner.id.clone(), y });
                    last_bottom = y + height;
                    y += height + m.row_spacing;
                    if !owner.collapsed {
                        line_start = Some(Start { group: owner.id.clone(), y });
                    }
                }
            }
            if owner.is_some_and(|group| group.collapsed) {
                continue;
            }
            let indent = if owner.is_some() && !self.icons_only { m.group_indent } else { 0.0 };
            let frame =
                Rect::new(m.padding + indent, y, (row_width - indent).max(0.0), m.row_height);
            out.rows.push(Row {
                kind: RowKind::Tab(tab.id.clone()),
                frame,
                group: owner.map(|group| group.id.clone()),
                index: Some(index),
            });
            last_bottom = frame.max_y();
            y += m.row_height + m.row_spacing;
        }
        end_line(out, &mut line_start, &mut pane_start, last_bottom);
        y
    }

    /// The row under the point: a tile that holds it, or a row whose band holds its y.
    pub fn row_at<'r>(&self, layout: &'r Layout, x: f64, y: f64) -> Option<&'r Row> {
        layout.rows.iter().find(|row| match row.kind {
            RowKind::Pinned(_) => row.frame.contains(x, y),
            RowKind::Separator => false,
            _ => y >= row.frame.y && y < row.frame.max_y() && x >= 0.0 && x < self.width,
        })
    }

    pub fn frame_of(&self, layout: &Layout, id: &str) -> Option<Rect> {
        layout
            .rows
            .iter()
            .find(|row| matches!(&row.kind, RowKind::Tab(tab) | RowKind::Pinned(tab) if tab == id))
            .map(|row| row.frame)
    }

    /// Where a tab lands for the pointer at the point: a pinned tab among the pinned tiles, any
    /// other among the unpinned rows. Over a group's tab or the lower half of its open header the
    /// slot is in that group; between a group's last tab and the next row it is in the group while
    /// the pointer is over that last tab, outside it below.
    pub fn slot_at(&self, layout: &Layout, x: f64, y: f64, dragging_pinned: bool) -> DropSlot {
        if dragging_pinned { self.pinned_slot(layout, x, y) } else { self.unpinned_slot(layout, y) }
    }

    fn pinned_slot(&self, layout: &Layout, x: f64, y: f64) -> DropSlot {
        let tiles: Vec<&Row> =
            layout.rows.iter().filter(|row| matches!(row.kind, RowKind::Pinned(_))).collect();
        let mark = 2.0;
        let spacing = self.metrics.tile_spacing;
        let vertical = layout.pinned_columns > 1;
        for tile in &tiles {
            let f = tile.frame;
            let before =
                y < f.y || (y <= f.max_y() && if vertical { x < f.mid_x() } else { y < f.mid_y() });
            let Some(index) = tile.index.filter(|_| before) else { continue };
            let indicator = if vertical {
                Rect::new(f.x - (spacing + mark) / 2.0, f.y, mark, f.height)
            } else {
                Rect::new(f.x, f.y - (spacing + mark) / 2.0, f.width, mark)
            };
            return DropSlot { index, group: None, indicator };
        }
        let count = self.tabs.iter().filter(|tab| tab.pinned).count();
        let Some(f) = tiles.last().map(|tile| tile.frame) else {
            return DropSlot { index: 0, group: None, indicator: Rect::ZERO };
        };
        let indicator = if vertical {
            Rect::new(f.max_x() + (spacing - mark) / 2.0, f.y, mark, f.height)
        } else {
            Rect::new(f.x, f.max_y() + (spacing - mark) / 2.0, f.width, mark)
        };
        DropSlot { index: count, group: None, indicator }
    }

    fn unpinned_slot(&self, layout: &Layout, y: f64) -> DropSlot {
        let m = self.metrics;
        let candidates: Vec<&Row> = layout
            .rows
            .iter()
            .filter(|row| matches!(row.kind, RowKind::Tab(_) | RowKind::GroupHeader(_)))
            .collect();
        let gap = m.row_spacing;
        let above = |f: Rect| Rect::new(f.x, f.y - (gap + 2.0) / 2.0, f.width, 2.0);
        let below = |f: Rect| Rect::new(f.x, f.max_y() + (gap - 2.0) / 2.0, f.width, 2.0);
        for (position, row) in candidates.iter().enumerate() {
            let f = row.frame;
            match &row.kind {
                RowKind::GroupHeader(id) => {
                    let Some(first) = self
                        .tabs
                        .iter()
                        .position(|tab| tab.group.as_ref() == Some(id) && !tab.pinned)
                    else {
                        continue;
                    };
                    if y < f.mid_y() {
                        return DropSlot { index: first, group: None, indicator: above(f) };
                    }
                    let open = self.group(Some(id)).is_some_and(|group| !group.collapsed);
                    if open && y < f.max_y() + gap {
                        let mark = below(f);
                        let indicator = Rect::new(
                            mark.x + m.group_indent,
                            mark.y,
                            (mark.width - m.group_indent).max(0.0),
                            mark.height,
                        );
                        return DropSlot { index: first, group: Some(id.clone()), indicator };
                    }
                }
                RowKind::Tab(_) => {
                    let Some(index) = row.index else { continue };
                    if y < f.mid_y() {
                        return DropSlot { index, group: row.group.clone(), indicator: above(f) };
                    }
                    // The last shown tab of a group: the pointer still over it drops at the end.
                    if let Some(group) = &row.group
                        && y <= f.max_y() + gap / 2.0
                    {
                        let next = candidates.get(position + 1);
                        let ends = next.is_none_or(|next| {
                            next.group.as_ref() != Some(group)
                                || matches!(next.kind, RowKind::GroupHeader(_))
                        });
                        if ends {
                            return DropSlot {
                                index: index + 1,
                                group: Some(group.clone()),
                                indicator: below(f),
                            };
                        }
                    }
                }
                _ => {}
            }
        }
        // Past every row: the end, outside every group.
        let pinned_count = self.tabs.iter().filter(|tab| tab.pinned).count();
        let indicator = candidates.last().map_or(
            Rect::new(m.padding, m.vertical_padding, self.row_width(), 2.0),
            |row| {
                Rect::new(m.padding, row.frame.max_y() + (gap - 2.0) / 2.0, self.row_width(), 2.0)
            },
        );
        DropSlot { index: self.tabs.len().max(pinned_count), group: None, indicator }
    }
}
