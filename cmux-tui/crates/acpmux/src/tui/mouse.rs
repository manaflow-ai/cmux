//! Part of the TUI `App`; see `tui/mod.rs`.

use super::*;

pub enum PermChoice {
    Index(usize),
    Allow,
    Deny,
}

/// Something a clickable dialog element does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ButtonAction {
    NewDraft,
    /// Title-row chips.
    DraftConfig,
    DraftHarness,
    DraftModel,
    DraftEffort,
    DraftPolicy,
    DraftDirectory,
    /// Start a draft in a project shown in the sidebar.
    NewProject(String),
    PickModel,
    PickMode,
    PickPolicy,
    PickThinking,
    EditDirectory,
    BrowseDirectory(String),
    /// Filter the sidebar to one host; None = all.
    HostFilter(Option<String>),
    AddHost,
    /// Copy the status-bar message (cmux's `[Copy message]`).
    CopyStatus,
    Help,
    Web,
    CloseOverlay,
    ConfirmYes,
    ConfirmNo,
    CreateFromForm,
    PermissionOption(usize),
    PermissionAllow,
    PermissionDeny,
    /// The composer's send glyph.
    Send,
    /// "Show more" under a sidebar group.
    ShowGroup(String),
}

impl App {
    pub(super) fn on_button(&mut self, action: &ButtonAction) {
        match action {
            ButtonAction::NewDraft => self.open_draft(),
            ButtonAction::DraftConfig => self.open_draft_config_picker(),
            ButtonAction::DraftHarness => self.open_draft_harness_picker(),
            ButtonAction::DraftModel => self.open_draft_model_picker(),
            ButtonAction::DraftEffort => self.open_thinking_picker(),
            ButtonAction::DraftPolicy => self.open_policy_picker(),
            ButtonAction::DraftDirectory => self.open_directory_dialog(),
            ButtonAction::NewProject(cwd) => self.open_draft_in_directory(cwd.clone()),
            ButtonAction::Send => self.run_action(super::actions::Action::Send, &[]),
            ButtonAction::ShowGroup(g) => {
                if !self.expanded_groups.remove(g) {
                    self.expanded_groups.insert(g.clone());
                }
            }
            ButtonAction::PickModel => self.open_model_picker(),
            ButtonAction::PickMode => self.open_mode_picker(),
            ButtonAction::PickPolicy => self.open_policy_picker(),
            ButtonAction::PickThinking => self.open_thinking_picker(),
            ButtonAction::EditDirectory => self.open_directory_dialog(),
            ButtonAction::BrowseDirectory(path) => self.open_directory_dialog_at(path.clone()),
            ButtonAction::HostFilter(h) => {
                // Clicking the active chip again clears the filter.
                let next = if self.host_filter == *h { None } else { h.clone() };
                self.set_host_filter(next);
            }
            ButtonAction::AddHost => self.overlay = Overlay::AddHost { text: Editor::default() },
            ButtonAction::Help => self.run_action(Action::Help, &[]),
            ButtonAction::Web => self.run_action(Action::Web, &[]),
            ButtonAction::CopyStatus => {
                let text = self.status.trim_start_matches("error: ").to_owned();
                self.copy_to_clipboard(&text);
            }
            ButtonAction::CloseOverlay => {
                let was_agent = matches!(&self.overlay, Overlay::Picker(p) if matches!(p.on_pick, PickTarget::Agent));
                self.overlay = Overlay::None;
                if was_agent
                    && let Some(form) = self.parked_form.take() {
                        self.overlay = form;
                    }
            }
            ButtonAction::ConfirmYes => self.on_key(KeyEvent::new(KeyCode::Char('y'), KeyModifiers::NONE)),
            ButtonAction::ConfirmNo => self.on_key(KeyEvent::new(KeyCode::Char('n'), KeyModifiers::NONE)),
            ButtonAction::CreateFromForm => self.on_key(KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE)),
            ButtonAction::PermissionOption(i) => self.answer_permission(PermChoice::Index(*i)),
            ButtonAction::PermissionAllow => self.answer_permission(PermChoice::Allow),
            ButtonAction::PermissionDeny => self.answer_permission(PermChoice::Deny),
        }
    }
}

impl App {
    pub(super) fn with_viewport(&mut self, f: impl FnOnce(&mut Viewport)) {
        self.transcript_anchor = None;
        if !matches!(self.overlay, Overlay::None) {
            f(&mut self.dialog.viewport);
            return;
        }
        if let Some(id) = self.selected_id() {
            f(self.viewport.entry(id).or_default());
        }
    }

    pub fn selected_supports_steer(&self) -> bool {
        self.selected_session()
            .and_then(|s| s.get("agentInfo"))
            .map(|_| true)
            .unwrap_or(false)
            && self
                .selected_id()
                .and_then(|id| self.details.get(&id))
                .and_then(|d| d.pointer("/agentCapabilities/_meta/steering/supported").and_then(Value::as_bool))
                .unwrap_or(false)
    }

    pub(super) fn show_toast(&mut self, text: impl Into<String>) {
        self.toast = Some((text.into(), Instant::now()));
    }

    pub(super) fn copy_to_clipboard(&mut self, text: &str) {
        use base64::Engine;
        use std::io::Write;
        if text.is_empty() {
            return;
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(text.as_bytes());
        let mut out = std::io::stdout();
        let _ = write!(out, "\x1b]52;c;{encoded}\x07");
        let _ = out.flush();
        self.show_toast("Copied");
    }

    pub(super) fn set_pointer(&mut self, pointer: bool) {
        if self.pointer_shape == pointer {
            return;
        }
        use std::io::Write;
        let mut out = std::io::stdout();
        let _ = write!(out, "\x1b]22;{}\x07", if pointer { "pointer" } else { "default" });
        let _ = out.flush();
        self.pointer_shape = pointer;
    }

    /// Transcript row index and column under a screen position.
    /// Forgiving cell lookup: any point in the transcript
    /// pane snaps to the nearest row and column, so a press on the gutter,
    /// past the end of a line, or below the last line still starts a
    /// selection there.
    /// The rows' rect: the conversation column, one cell in from its left
    /// edge and clear of the header row and the scrollbar.
    pub(super) fn transcript_inner(&self) -> Rect {
        let col = self.areas.column;
        Rect { x: col.x + 1, y: col.y + 1, width: col.width.saturating_sub(3), height: col.height.saturating_sub(1) }
    }
    pub(super) fn transcript_cell_lenient(&self, x: u16, y: u16) -> Option<(usize, usize)> {
        let a = self.areas.transcript;
        if a.width < 4 || a.height < 2 || x < a.x || x >= a.x + a.width || y < a.y || y >= a.y + a.height {
            return None;
        }
        if self.rows_cache.is_empty() {
            return None;
        }
        let (rect, row) = self.transcript_hitboxes.iter().find(|(rect, _)| x >= rect.x && x < rect.x + rect.width && y == rect.y).copied()?;
        let col = ((x - rect.x) as usize).min(self.rows_cache[row].chars().count());
        Some((row, col))
    }

    pub(super) fn on_mouse(&mut self, m: MouseEvent) {
        let (x, y) = (m.column, m.row);
        self.hover = Some((x, y));
        let hit = |r: Rect| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
        let mut over = self.sidebar_rows.iter().any(|(r, _)| hit(*r)) || self.buttons.iter().any(|(r, _)| hit(*r)) || self.perm_rows.iter().any(|(r, _)| hit(*r)) || self.transcript_hitboxes.iter().any(|(r, _)| hit(*r)) || hit(self.areas.sidebar_rule);
        // Hover moves the picker cursor, except while the scrollbar is dragged.
        let dragging = self.dialog.viewport.drag.is_some() || self.sidebar_drag.is_some();
        if let (Overlay::Picker(p), false) = (&mut self.overlay, dragging)
            && let Some((_, vi)) = p.row_rects.iter().find(|(r, _)| hit(*r)).cloned()
                && p.visible.get(vi).map(|&ri| !p.rows[ri].header).unwrap_or(false) {
                    p.cursor = vi;
                    over = true;
                }
        self.set_pointer(over);
        match m.kind {
            MouseEventKind::ScrollDown => self.wheel(x, y, WHEEL_ROWS),
            MouseEventKind::ScrollUp => self.wheel(x, y, -WHEEL_ROWS),
            MouseEventKind::Down(MouseButton::Left) => self.press(x, y, m.modifiers),
            MouseEventKind::Drag(MouseButton::Left) if matches!(self.overlay, Overlay::Menu(_)) => {}
            MouseEventKind::Drag(MouseButton::Left) => self.drag(x, y),
            MouseEventKind::Up(MouseButton::Left) if matches!(self.overlay, Overlay::Menu(_)) => self.menu_release(x, y),
            MouseEventKind::Up(MouseButton::Left) => self.release(),
            MouseEventKind::Down(MouseButton::Right) => {
                if let Overlay::Menu(_) = self.overlay {
                    self.overlay = Overlay::None;
                }
                if matches!(self.overlay, Overlay::None) {
                    self.context_menu(x, y);
                    // Held down: the drag highlights, the release picks.
                    self.menu_pressed = matches!(self.overlay, Overlay::Menu(_));
                }
            }
            // The hover set above moves the highlight while a button is held.
            MouseEventKind::Drag(MouseButton::Right) => {}
            MouseEventKind::Up(MouseButton::Right) => self.menu_release(x, y),
            _ => {}
        }
    }

    /// A button came up with the menu open: run the item under the pointer
    /// when a press armed the menu; over no item, the menu stays for a click.
    pub(super) fn menu_release(&mut self, x: u16, y: u16) {
        if !self.menu_pressed {
            return;
        }
        self.menu_pressed = false;
        if let Overlay::Menu(m) = &self.overlay
            && let Some(i) = m.item_at(x, y) {
                let a = m.items[i].action.clone();
                self.overlay = Overlay::None;
                self.run_menu_action(a);
            }
    }

    pub(super) fn wheel(&mut self, x: u16, y: u16, delta: isize) {
        if !matches!(self.overlay, Overlay::None) {
            self.dialog.wheel(delta);
            return;
        }
        let a = self.areas.sidebar;
        if x >= a.x && x < a.x + a.width && y >= a.y && y < a.y + a.height {
            // Wheel over the sidebar moves the selection like a list.
            self.select_step(if delta > 0 { 1 } else { -1 });
            return;
        }
        self.with_viewport(|v| v.scroll_by(delta));
    }

    pub(super) fn press(&mut self, x: u16, y: u16, mods: KeyModifiers) {
        let hit = |r: Rect| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height;
        self.transcript_anchor = None;
        // Dialog buttons drawn last frame.
        if let Some((_, action)) = self.buttons.iter().find(|(r, _)| hit(*r)).cloned() {
            self.on_button(&action);
            return;
        }
        // Context menu: a press on a row arms it (the release runs it),
        // a press anywhere else closes the menu.
        if let Overlay::Menu(m) = &self.overlay {
            if m.item_at(x, y).is_some() {
                self.menu_pressed = true;
            } else {
                self.overlay = Overlay::None;
                self.menu_pressed = false;
            }
            return;
        }
        // Any open dialog: scrollbar first, then rows, then click-outside closes.
        if !matches!(self.overlay, Overlay::None) {
            if self.dialog.press(x, y) {
                return;
            }
            if let Overlay::Picker(p) = &mut self.overlay
                && let Some((_, vi)) = p.row_rects.iter().find(|(r, _)| hit(*r)).cloned() {
                    if let Some(&ri) = p.visible.get(vi)
                        && !p.rows[ri].header {
                            p.cursor = vi;
                            let row = p.rows[ri].clone();
                            let target = p.on_pick.clone();
                            let is_agent = matches!(target, PickTarget::Agent);
                            self.overlay = Overlay::None;
                            self.apply_pick(target, row.value, row.group);
                            if is_agent
                                && let Some(form) = self.parked_form.take() {
                                    self.overlay = form;
                                }
                        }
                    return;
                }
            if !hit(self.dialog_rect) {
                let is_agent = matches!(&self.overlay, Overlay::Picker(p) if matches!(p.on_pick, PickTarget::Agent));
                self.overlay = Overlay::None;
                if is_agent
                    && let Some(form) = self.parked_form.take() {
                        self.overlay = form;
                    }
            }
            return;
        }
        // Sidebar rule: start a resize drag.
        if hit(self.areas.sidebar_rule) {
            self.sidebar_drag = Some((x, self.areas.sidebar.width));
            return;
        }
        // Permission popup rows: click an option.
        if let Some((_, action)) = self.perm_rows.iter().find(|(r, _)| hit(*r)).cloned() {
            self.on_button(&action);
            return;
        }
        // Sidebar row click selects.
        if let Some((_, idx)) = self.sidebar_rows.iter().find(|(r, _)| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height).cloned() {
            self.select(idx);
            self.focus = Focus::Input;
            return;
        }
        // Scrollbar track.
        if let Some(id) = self.selected_id()
            && let Some(vp) = self.viewport.get_mut(&id)
                && vp.track_contains(x, y) {
                    vp.press(y);
                    return;
                }
        // Composer click focuses input.
        let comp = self.areas.composer;
        if x >= comp.x && x < comp.x + comp.width && y >= comp.y && y < comp.y + comp.height {
            self.focus = Focus::Input;
            if y > comp.y && y < comp.y + comp.height - 2 {
                let width = comp.width.saturating_sub(render::COMPOSER_INDENT + 1) as usize;
                let row = self.editor().scroll + (y - comp.y - 1) as usize;
                self.editor_mut().click(width, row, x.saturating_sub(comp.x + render::COMPOSER_INDENT) as usize);
                let cur = self.editor().cursor();
                self.composer_sel = Some((cur, cur));
            }
            return;
        }
        // Ctrl-click or Alt-click opens the link under the pointer (Cmd-click
        // is handled by the terminal through OSC 8 and never reaches us).
        if mods.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
            && let Some((row, col)) = self.transcript_cell_lenient(x, y) {
                let text = self.rows_cache.get(row).cloned().unwrap_or_default();
                if let Some(link) = crate::tui::links::find(&text).into_iter().find(|l| col >= l.start && col < l.end) {
                    let cwd = self.selected_session().and_then(|s| s.get("cwd").and_then(Value::as_str)).unwrap_or("").to_owned();
                    self.status = crate::tui::links::open(&link.target, &cwd);
                    self.selection = None;
                    return;
                }
            }
        // Transcript: a click on a collapsible header opens or closes it.
        if let Some((row, _)) = self.transcript_cell_lenient(x, y)
            && let (Some(&(_, Some(t))), Some(id)) = (self.row_meta.get(row), self.selected_id()) {
                let a = self.areas.transcript;
                let exact_row = y > a.y && (self.viewport.get(&id).map(|v| v.offset).unwrap_or(0) + (y - a.y - 1) as usize) == row;
                if exact_row {
                    let screen_row = y.saturating_sub(self.transcript_inner().y) as usize;
                    self.transcript_anchor = Some((id.clone(), row, screen_row));
                    self.toggle(t);
                    if let Some(vp) = self.viewport.get_mut(&id) { vp.follow = false; }
                    self.selection = None;
                    return;
                }
            }
        // Transcript: start a selection, with double and triple click. Any
        // point in the pane counts, not only a cell with text under it.
        let Some((row, col)) = self.transcript_cell_lenient(x, y) else {
            self.selection = None;
            return;
        };
        let Some(id) = self.selected_id() else { return };
        let now = Instant::now();
        let count = match self.last_click {
            Some((t, lx, ly, n)) if now.duration_since(t).as_millis() <= MULTI_CLICK_MS && lx.abs_diff(x) <= 1 && ly == y => (n % 3) + 1,
            _ => 1,
        };
        self.last_click = Some((now, x, y, count));
        let _ = mods;
        let line = self.rows_cache.get(row).cloned().unwrap_or_default();
        self.selection = Some(match count {
            2 => {
                let (s, e) = word_bounds(&line, col);
                Selection { session: id, anchor: (row, s), head: (row, e), mode: SelectMode::Word }
            }
            3 => Selection { session: id, anchor: (row, 0), head: (row, line.chars().count()), mode: SelectMode::Line },
            _ => Selection { session: id, anchor: (row, col), head: (row, col), mode: SelectMode::Cell },
        });
    }

    pub(super) fn drag(&mut self, x: u16, y: u16) {
        if !matches!(self.overlay, Overlay::None) {
            self.dialog.drag_to(y);
            return;
        }
        if let Some((x0, w0)) = self.sidebar_drag {
            let total = self.areas.sidebar.width + self.areas.transcript.width;
            let want = (w0 as i32 + x as i32 - x0 as i32).max(16) as u16;
            self.sidebar_width = Some(want.min(total.saturating_sub(render::MIN_MAIN_WIDTH)));
            return;
        }
        if let Some(id) = self.selected_id()
            && let Some(vp) = self.viewport.get_mut(&id)
                && vp.drag.is_some() {
                    vp.drag_to(y);
                    return;
                }
        // Composer selection follows the pointer.
        if let Some((anchor, _)) = self.composer_sel {
            let comp = self.areas.composer;
            let width = comp.width.saturating_sub(render::COMPOSER_INDENT + 1) as usize;
            let yy = y.clamp(comp.y + 1, (comp.y + comp.height).saturating_sub(3));
            let row = self.editor().scroll + (yy - comp.y - 1) as usize;
            self.editor_mut().click(width, row, x.saturating_sub(comp.x + render::COMPOSER_INDENT) as usize);
            let head = self.editor().cursor();
            self.composer_sel = Some((anchor, head));
            return;
        }
        if self.selection.is_none() {
            return;
        }
        // Dragging past the edges auto-scrolls and extends; the tick keeps
        // scrolling while the pointer stays outside.
        let a = self.areas.transcript;
        let inner_top = a.y + 1;
        let inner_bottom = a.y + a.height;
        self.drag_autoscroll = if y < inner_top {
            Some(-1)
        } else if y >= inner_bottom {
            Some(1)
        } else {
            None
        };
        if let Some(d) = self.drag_autoscroll {
            self.with_viewport(|v| v.scroll_by(d));
        }
        let yy = y.clamp(inner_top, inner_bottom.saturating_sub(1));
        let Some((row, col)) = self.transcript_cell_lenient(x.max(a.x), yy) else { return };
        let line = self.rows_cache.get(row).cloned().unwrap_or_default();
        let Some(sel) = self.selection.as_mut() else { return };
        match sel.mode {
            SelectMode::Cell => sel.head = (row, col),
            SelectMode::Word => {
                let (s, e) = word_bounds(&line, col);
                sel.head = if (row, col) >= sel.anchor { (row, e) } else { (row, s) };
            }
            SelectMode::Line => {
                sel.head = if row >= sel.anchor.0 { (row, line.chars().count()) } else { (row, 0) };
            }
        }
    }

    /// Called every tick: keeps scrolling while a selection drag sits past
    /// the transcript's top or bottom edge, extending the selection.
    pub(super) fn autoscroll_step(&mut self) {
        let Some(d) = self.drag_autoscroll else { return };
        if self.selection.is_none() {
            self.drag_autoscroll = None;
            return;
        }
        self.with_viewport(|v| v.scroll_by(d * 2));
        let a = self.areas.transcript;
        let y = if d < 0 { a.y + 1 } else { a.y + a.height - 1 };
        let Some((row, col)) = self.transcript_cell_lenient(a.x + 1, y) else { return };
        let line = self.rows_cache.get(row).cloned().unwrap_or_default();
        if let Some(sel) = self.selection.as_mut() {
            sel.head = match sel.mode {
                SelectMode::Cell => (row, if d < 0 { 0 } else { line.chars().count() }),
                SelectMode::Word | SelectMode::Line => (row, if d < 0 { 0 } else { line.chars().count() }),
            };
        }
        let _ = col;
    }

    pub(super) fn release(&mut self) {
        self.drag_autoscroll = None;
        if let Some((a, b)) = self.composer_sel.take() {
            let (a, b) = (a.min(b), a.max(b));
            if a < b {
                let text: String = self.editor().text().chars().skip(a).take(b - a).collect();
                self.copy_to_clipboard(&text);
            }
            return;
        }
        if !matches!(self.overlay, Overlay::None) {
            self.dialog.release();
            return;
        }
        if self.sidebar_drag.take().is_some() {
            return;
        }
        if let Some(id) = self.selected_id()
            && let Some(vp) = self.viewport.get_mut(&id)
                && vp.drag.is_some() {
                    vp.release();
                    return;
                }
        let Some(sel) = self.selection.clone() else { return };
        if sel.anchor == sel.head {
            self.selection = None;
            return;
        }
        let text = sel.text(&self.rows_cache);
        self.copy_to_clipboard(&text);
    }
}
