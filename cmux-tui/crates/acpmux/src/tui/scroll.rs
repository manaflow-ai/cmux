//! Scroll containers and the shared scrollbar, ported from cmux-tui so the
//! two feel identical: invisible track, `▕` thumb that becomes `▐` while
//! hovered or dragged, track click jumps, thumb drag anchors, and follow
//! mode that sticks to the bottom only when you are already there.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Color, Style};

/// Thumb position and length (in track cells) for a row-based viewport.
pub fn thumb_geometry(
    total_rows: usize,
    visible_rows: usize,
    offset: usize,
    track_height: u16,
) -> (u16, u16) {
    if track_height == 0 || total_rows <= visible_rows {
        return (0, 0);
    }
    let numerator = visible_rows.max(1) as u128 * track_height as u128;
    let thumb_height = numerator.div_ceil(total_rows as u128).clamp(1, track_height as u128) as u16;
    let max_scroll = total_rows.saturating_sub(visible_rows);
    let travel = track_height.saturating_sub(thumb_height);
    let thumb_y = if max_scroll == 0 {
        0
    } else {
        let numerator = offset.min(max_scroll) as u128 * travel as u128;
        ((numerator + max_scroll as u128 / 2) / max_scroll as u128) as u16
    };
    (thumb_y, thumb_height)
}

/// Viewport offset produced by clicking a scrollbar track.
pub fn jump_offset(
    total_rows: usize,
    visible_rows: usize,
    track_height: u16,
    relative_y: u16,
) -> usize {
    if track_height == 0 {
        return 0;
    }
    let (_, thumb_height) = thumb_geometry(total_rows, visible_rows, 0, track_height);
    let travel = track_height.saturating_sub(thumb_height);
    if travel == 0 {
        return 0;
    }
    let relative_y = relative_y.min(track_height - 1);
    let centered = relative_y.saturating_sub(thumb_height / 2).min(travel);
    let max_scroll = total_rows.saturating_sub(visible_rows);
    (centered as u128 * max_scroll as u128 + travel as u128 / 2).div_euclid(travel as u128) as usize
}

/// Viewport offset produced by moving an anchored scrollbar thumb.
pub fn drag_offset(
    total_rows: usize,
    visible_rows: usize,
    track_height: u16,
    anchor_offset: usize,
    delta_y: i128,
) -> usize {
    let (_, thumb_height) = thumb_geometry(total_rows, visible_rows, anchor_offset, track_height);
    let travel = track_height.saturating_sub(thumb_height).max(1) as i128;
    let max_scroll = total_rows.saturating_sub(visible_rows) as i128;
    let delta = delta_y * max_scroll / travel;
    (anchor_offset as i128 + delta).clamp(0, max_scroll) as usize
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThumbState {
    Idle,
    Highlighted,
    Expanded,
}

/// Draw the thumb into `track` (a one-column rect). Nothing is drawn when
/// every row fits.
pub fn draw_thumb(
    buf: &mut Buffer,
    track: Rect,
    thumb: (u16, u16),
    idle: Color,
    active: Color,
    state: ThumbState,
) {
    let (thumb_y, thumb_height) = thumb;
    if track.height == 0 || thumb_height == 0 {
        return;
    }
    let glyph = if state == ThumbState::Expanded { "▐" } else { "▕" };
    let color = if state == ThumbState::Idle { idle } else { active };
    for row in thumb_y..thumb_y.saturating_add(thumb_height).min(track.height) {
        if let Some(cell) = buf.cell_mut((track.x, track.y + row)) {
            cell.set_symbol(glyph).set_style(Style::default().fg(color));
        }
    }
}

/// A vertical viewport over `total` rows. `offset` is the first visible row.
/// `follow` keeps the viewport pinned to the bottom as rows are added, and
/// turns off the moment the user scrolls up.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Viewport {
    pub offset: usize,
    pub visible: usize,
    pub total: usize,
    pub follow: bool,
    pub track: Rect,
    /// (mouse y at press, offset at press) while the thumb is dragged.
    pub drag: Option<(u16, usize)>,
    pub hover: bool,
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            offset: 0,
            visible: 0,
            total: 0,
            follow: true,
            track: Rect::default(),
            drag: None,
            hover: false,
        }
    }
}

impl Viewport {
    pub fn max_offset(&self) -> usize {
        self.total.saturating_sub(self.visible)
    }

    /// Call once per frame with the current geometry. Applies follow mode and
    /// clamps a stale offset.
    pub fn layout(&mut self, total: usize, visible: usize, track: Rect) {
        self.total = total;
        self.visible = visible;
        self.track = track;
        if self.follow {
            self.offset = self.max_offset();
        } else {
            self.offset = self.offset.min(self.max_offset());
            if self.offset == self.max_offset() {
                self.follow = true;
            }
        }
    }

    pub fn scroll_by(&mut self, delta: isize) {
        let next = self.offset.saturating_add_signed(delta).min(self.max_offset());
        self.offset = next;
        self.follow = next >= self.max_offset();
    }

    pub fn page_up(&mut self) {
        self.scroll_by(-(self.visible.max(1) as isize));
    }
    pub fn page_down(&mut self) {
        self.scroll_by(self.visible.max(1) as isize);
    }
    pub fn to_top(&mut self) {
        self.offset = 0;
        self.follow = self.max_offset() == 0;
    }
    pub fn to_bottom(&mut self) {
        self.offset = self.max_offset();
        self.follow = true;
    }

    /// Rows hidden below the viewport, for the "↓ N new" chip.
    pub fn rows_below(&self) -> usize {
        self.max_offset().saturating_sub(self.offset)
    }

    pub fn has_scrollbar(&self) -> bool {
        self.track.height > 0 && self.total > self.visible
    }

    pub fn thumb(&self) -> (u16, u16) {
        thumb_geometry(self.total, self.visible, self.offset, self.track.height)
    }

    pub fn thumb_rect(&self) -> Rect {
        let (y, h) = self.thumb();
        Rect { x: self.track.x, y: self.track.y + y, width: 1, height: h }
    }

    pub fn track_contains(&self, x: u16, y: u16) -> bool {
        self.has_scrollbar()
            && x == self.track.x
            && y >= self.track.y
            && y < self.track.y + self.track.height
    }

    /// Mouse press on the track column. Track click jumps, thumb click anchors.
    pub fn press(&mut self, y: u16) {
        if !self.has_scrollbar() {
            return;
        }
        let relative = y.saturating_sub(self.track.y).min(self.track.height.saturating_sub(1));
        let (thumb_y, thumb_h) = self.thumb();
        if relative < thumb_y || relative >= thumb_y.saturating_add(thumb_h) {
            self.offset = jump_offset(self.total, self.visible, self.track.height, relative);
        }
        self.follow = self.offset >= self.max_offset();
        self.drag = Some((y, self.offset));
    }

    pub fn drag_to(&mut self, y: u16) {
        let Some((anchor_y, anchor_offset)) = self.drag else { return };
        self.offset = drag_offset(
            self.total,
            self.visible,
            self.track.height,
            anchor_offset,
            y as i128 - anchor_y as i128,
        );
        self.follow = self.offset >= self.max_offset();
    }

    pub fn release(&mut self) {
        self.drag = None;
    }

    pub fn thumb_state(&self) -> ThumbState {
        if self.drag.is_some() {
            ThumbState::Expanded
        } else if self.hover {
            ThumbState::Highlighted
        } else {
            ThumbState::Idle
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumb_is_absent_when_every_row_is_visible() {
        assert_eq!(thumb_geometry(8, 8, 0, 6), (0, 0));
        assert_eq!(thumb_geometry(0, 8, 0, 6), (0, 0));
        assert_eq!(thumb_geometry(8, 8, 0, 0), (0, 0));
    }

    #[test]
    fn track_click_and_drag_cover_the_scroll_range() {
        assert_eq!(jump_offset(30, 6, 6, 0), 0);
        assert_eq!(jump_offset(30, 6, 6, 5), 24);
        assert_eq!(drag_offset(30, 6, 6, 0, 5), 24);
        assert_eq!(drag_offset(30, 6, 6, 24, -5), 0);
    }

    #[test]
    fn follow_sticks_to_bottom_until_scrolled_up() {
        let mut v = Viewport::default();
        v.layout(100, 10, Rect::new(0, 0, 1, 10));
        assert_eq!(v.offset, 90);
        v.layout(120, 10, Rect::new(0, 0, 1, 10));
        assert_eq!(v.offset, 110, "new rows keep the viewport at the bottom");
        v.scroll_by(-3);
        assert!(!v.follow);
        v.layout(140, 10, Rect::new(0, 0, 1, 10));
        assert_eq!(v.offset, 107, "scrolled up: new rows do not move the viewport");
        assert_eq!(v.rows_below(), 23);
        v.to_bottom();
        assert!(v.follow);
        assert_eq!(v.offset, 130);
    }

    #[test]
    fn thumb_press_outside_thumb_jumps_and_anchors() {
        let mut v = Viewport::default();
        v.layout(30, 6, Rect::new(5, 2, 1, 6));
        v.to_top();
        v.press(2 + 5);
        assert_eq!(v.offset, 24);
        assert!(v.drag.is_some());
        v.drag_to(2);
        assert_eq!(v.offset, 0);
        v.release();
        assert!(v.drag.is_none());
    }
}
