//! Part of the TUI renderer; see `render/mod.rs`.
//!
//! The sidebar follows the Codex app's rail: a shaded column with "New
//! session" at the top, sessions grouped under their project (the session
//! directory's last segment, prefixed by the host for remote ones), one
//! line per session with a status mark at the right edge, and "Add host"
//! pinned to the bottom. No vertical rule: the shade is the edge.
//!
//! The grouped list is kept between frames ([`SidebarLayout`]) and built again only when the
//! sessions, drafts, host filter, opened projects or the selection's cut project change, so a
//! frame (a tick, a hover, a scroll) touches only the rows in view, at any number of sessions.

use super::super::session_route_id;
use super::super::sessions::Change;
use super::*;
use std::collections::{HashMap, HashSet};

/// A line of the list. Names index [`SidebarLayout::names`] and rows the app's rows (drafts,
/// then sessions), so the kept list holds no copy of a session.
#[derive(Clone, Copy)]
enum Entry {
    /// A project and, for one on this machine, the row whose directory its "+" opens.
    Header(u32, Option<u32>),
    Row(u32),
    Blank,
    /// "Show more (N)" under a group that is cut at its first rows.
    More(u32, u32),
}

/// Rows a project shows before "Show more", as in the Codex app.
const GROUP_ROWS: usize = 6;

/// A row filtered out, or hidden behind "Show more".
const NONE: u32 = u32::MAX;

struct Group {
    name: u32,
    /// Its rows are `members[start..start + len]`, newest first.
    start: u32,
    len: u32,
    cwd_row: Option<u32>,
}

/// What the groups were built from, past the sessions' version.
struct GroupInputs {
    drafts_shown: Vec<bool>,
    filter: Option<String>,
}

/// What the lines were built from, past the groups.
struct LineInputs {
    expanded: HashSet<String>,
    /// The group whose cut rows hold the selection, drawn open so the keys can reach it.
    forced: Option<u32>,
}

/// What grouping reads of a session, kept per session row so a change to one row reads that
/// row alone.
#[derive(Clone, Copy)]
struct RowKey {
    name: u32,
    /// Passes the host filter.
    shown: bool,
    /// On this machine with a directory: a project's "+" can open it.
    local_cwd: bool,
}

/// A row inserted or set since its key was read.
const STALE: RowKey = RowKey { name: NONE, shown: false, local_cwd: false };

/// The sidebar's grouped list, kept between frames.
#[derive(Default)]
pub(crate) struct SidebarLayout {
    group_inputs: Option<GroupInputs>,
    line_inputs: Option<LineInputs>,
    /// The sessions' version `keys` and the groups were brought up to.
    seen: u64,
    keys: Vec<RowKey>,
    /// Project names by session directory and peer, kept across builds: a session's project
    /// name is worked out once, not per build.
    names_by_cwd: HashMap<String, Vec<(Option<String>, u32)>>,
    names: Vec<String>,
    name_ids: HashMap<String, u32>,
    groups: Vec<Group>,
    members: Vec<u32>,
    /// Per row: (group, rank in it), `NONE` when filtered out.
    place: Vec<(u32, u32)>,
    entries: Vec<Entry>,
    /// Per row: its line in `entries`, `NONE` when not drawn.
    line_of_row: Vec<u32>,
    /// Session rows whose keys were read, for the tests: every row on a new list or filter,
    /// one on a one-row change, none on a frame with nothing changed.
    pub(crate) rows_read: usize,
}

impl SidebarLayout {
    fn intern(&mut self, name: String) -> u32 {
        if let Some(&id) = self.name_ids.get(&name) {
            return id;
        }
        let id = self.names.len() as u32;
        self.names.push(name.clone());
        self.name_ids.insert(name, id);
        id
    }

    /// A session's project name: its directory's label, prefixed by its peer.
    fn name_of(&mut self, s: &Value) -> u32 {
        let cwd = s.get("cwd").and_then(Value::as_str).unwrap_or("");
        let peer = s.get("peer").and_then(Value::as_str);
        if let Some(known) = self.names_by_cwd.get(cwd)
            && let Some((_, id)) = known.iter().find(|(p, _)| p.as_deref() == peer)
        {
            return *id;
        }
        let project = project_label(cwd);
        let id = self.intern(match peer {
            Some(p) => format!("{p} · {project}"),
            None => project,
        });
        self.names_by_cwd.entry(cwd.to_owned()).or_default().push((peer.map(str::to_owned), id));
        id
    }

    fn key_of(&mut self, app: &App, s: &Value) -> RowKey {
        self.rows_read += 1;
        let peer = s.get("peer");
        RowKey {
            name: self.name_of(s),
            shown: app.host_matches(peer.and_then(Value::as_str)),
            local_cwd: peer.is_none() && s.get("cwd").and_then(Value::as_str).is_some(),
        }
    }

    /// Brings `keys` up to the sessions: the logged changes since `seen` when there are any,
    /// else every row. Whether anything changed.
    fn update_keys(&mut self, app: &App, all: bool) -> bool {
        let sessions = &app.sessions;
        if !all && self.seen == sessions.version() {
            return false;
        }
        let followed = (!all).then(|| sessions.changes_since(self.seen)).flatten();
        match followed {
            Some(changes) => {
                for change in changes {
                    match change {
                        Change::Set(at) => self.keys[at] = STALE,
                        Change::Insert(at) => self.keys.insert(at, STALE),
                        Change::Remove(at) => {
                            self.keys.remove(at);
                        }
                    }
                }
                for at in 0..self.keys.len() {
                    if self.keys[at].name == NONE {
                        self.keys[at] = self.key_of(app, &sessions[at]);
                    }
                }
            }
            None => {
                self.keys.clear();
                for s in sessions.iter() {
                    let key = self.key_of(app, s);
                    self.keys.push(key);
                }
            }
        }
        self.seen = sessions.version();
        true
    }

    /// Brings the list up to date with `app`; the drawn order when the lines were built again.
    fn update(&mut self, app: &App) -> Option<Vec<usize>> {
        let inputs_current = self.group_inputs.as_ref().is_some_and(|k| {
            k.filter == app.host_filter
                && k.drafts_shown
                    .iter()
                    .copied()
                    .eq(app.drafts.iter().map(|d| app.host_matches(d.peer.as_deref())))
        });
        let keys_changed = self.update_keys(
            app,
            self.group_inputs.is_none() || {
                self.group_inputs.as_ref().is_some_and(|k| k.filter != app.host_filter)
            },
        );
        if !inputs_current || keys_changed {
            self.group_inputs = Some(GroupInputs {
                drafts_shown: app
                    .drafts
                    .iter()
                    .map(|d| app.host_matches(d.peer.as_deref()))
                    .collect(),
                filter: app.host_filter.clone(),
            });
            self.build_groups(app);
            self.line_inputs = None;
        }
        let forced = self
            .place
            .get(app.selected)
            .filter(|(g, rank)| *g != NONE && *rank as usize >= GROUP_ROWS)
            .map(|(g, _)| *g);
        let lines_current = self
            .line_inputs
            .as_ref()
            .is_some_and(|k| k.forced == forced && k.expanded == app.expanded_groups);
        if lines_current {
            return None;
        }
        self.line_inputs = Some(LineInputs { expanded: app.expanded_groups.clone(), forced });
        Some(self.build_lines(app, forced))
    }

    /// Groups the shown rows from their keys, with no session read: every session of a project
    /// under one name, groups in order of their most recent session (the list is already
    /// recency-sorted), drafts first.
    fn build_groups(&mut self, app: &App) {
        let ndrafts = app.drafts.len();
        let total = ndrafts + self.keys.len();
        let drafts = self.intern(String::new());
        self.groups.clear();
        self.place.clear();
        self.place.resize(total, (NONE, NONE));
        let mut group_of_name = vec![NONE; self.names.len()];
        for i in 0..total {
            let key = match i.checked_sub(ndrafts) {
                None => RowKey {
                    name: drafts,
                    shown: app.host_matches(app.drafts[i].peer.as_deref()),
                    local_cwd: false,
                },
                Some(at) => self.keys[at],
            };
            if !key.shown {
                continue;
            }
            let mut g = group_of_name[key.name as usize];
            if g == NONE {
                g = self.groups.len() as u32;
                group_of_name[key.name as usize] = g;
                self.groups.push(Group { name: key.name, start: 0, len: 0, cwd_row: None });
            }
            let group = &mut self.groups[g as usize];
            self.place[i] = (g, group.len);
            group.len += 1;
            if group.cwd_row.is_none() && key.local_cwd {
                group.cwd_row = Some(i as u32);
            }
        }
        let mut start = 0;
        for group in &mut self.groups {
            group.start = start;
            start += group.len;
        }
        self.members.clear();
        self.members.resize(start as usize, 0);
        for (i, &(g, rank)) in self.place.iter().enumerate() {
            if g != NONE {
                self.members[(self.groups[g as usize].start + rank) as usize] = i as u32;
            }
        }
    }

    /// The lines: a header per project, its rows, "Show more" under a long one; the drawn order.
    fn build_lines(&mut self, app: &App, forced: Option<u32>) -> Vec<usize> {
        self.entries.clear();
        self.line_of_row.clear();
        self.line_of_row.resize(self.place.len(), NONE);
        let mut order = Vec::with_capacity(self.members.len());
        for (gi, group) in self.groups.iter().enumerate() {
            let name = &self.names[group.name as usize];
            if !name.is_empty() {
                if !self.entries.is_empty() {
                    self.entries.push(Entry::Blank);
                }
                self.entries.push(Entry::Header(group.name, group.cwd_row));
            }
            // A long group shows its first rows and a "Show more"; the group
            // holding the selection is always open so the keys can reach it.
            let open = name.is_empty()
                || app.expanded_groups.contains(name)
                || group.len as usize <= GROUP_ROWS + 1
                || forced == Some(gi as u32);
            let shown = if open { group.len } else { GROUP_ROWS as u32 };
            let start = group.start as usize;
            for &row in &self.members[start..start + shown as usize] {
                self.line_of_row[row as usize] = self.entries.len() as u32;
                self.entries.push(Entry::Row(row));
                order.push(row as usize);
            }
            if !open {
                self.entries.push(Entry::More(group.name, group.len - GROUP_ROWS as u32));
            }
        }
        order
    }
}

pub(super) fn draw_sidebar(f: &mut ratatui::Frame, area: Rect, app: &mut App) {
    let c = app.chrome;
    let buf = f.buffer_mut();
    let ground = Style::default().bg(c.sidebar_bg);
    fill(buf, area, ground);
    let focused = app.focus == Focus::Sidebar;
    let content_w = area.width.saturating_sub(1) as usize;
    let hovered_row = |hover: Option<(u16, u16)>, y: u16| {
        hover
            .map(|(hx, hy)| hy == y && hx >= area.x && hx < area.x + area.width - 1)
            .unwrap_or(false)
    };
    let paint_row = |buf: &mut Buffer, y: u16, style: Style| {
        for x in area.x..area.x + area.width - 1 {
            if let Some(cell) = buf.cell_mut((x, y)) {
                cell.set_style(style);
            }
        }
    };
    // Top action.
    {
        let label = match app.host_filter.as_deref() {
            Some("local") => "New session on mac".to_owned(),
            Some(h) => format!("New session on {h}"),
            None => "New session".to_owned(),
        };
        let rect = Rect { x: area.x, y: area.y, width: area.width - 1, height: 1 };
        let hot = hovered_row(app.hover, rect.y) || (focused && app.selected == usize::MAX);
        let style = if hot {
            ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
        } else {
            ground.fg(c.status_fg)
        };
        if hot {
            paint_row(buf, rect.y, style);
        }
        buf.set_stringn(area.x + 1, area.y, "✎", 1, style.fg(c.muted_fg));
        buf.set_stringn(area.x + 3, area.y, &label, content_w.saturating_sub(3), style);
        app.buttons.push((rect, ButtonAction::NewDraft));
    }
    // Footer.
    let footer_h: u16 = if area.height > 6 { 2 } else { 0 };
    if footer_h > 0 {
        let y = area.y + area.height - 1;
        let rect = Rect { x: area.x, y, width: area.width - 1, height: 1 };
        let hot = hovered_row(app.hover, y);
        let style = if hot {
            ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
        } else {
            ground.fg(c.muted_fg)
        };
        if hot {
            paint_row(buf, y, style);
        }
        buf.set_stringn(area.x + 1, y, "+", 1, style);
        buf.set_stringn(area.x + 3, y, "Add host", content_w.saturating_sub(3), style);
        app.buttons.push((rect, ButtonAction::AddHost));
    }
    // Rows: drafts first, then sessions grouped by host and project.
    let mut layout = std::mem::take(&mut app.sidebar_layout);
    if let Some(order) = layout.update(app) {
        app.sidebar_order = order;
    }
    let entries = &layout.entries;
    let ndrafts = app.drafts.len();
    let selected = app.selected;
    let body_y = area.y + 2;
    let body_h = area.height.saturating_sub(2 + footer_h) as usize;
    let sel_pos = layout
        .line_of_row
        .get(selected)
        .filter(|line| **line != NONE)
        .map_or(0, |line| *line as usize);
    let offset = if body_h == 0 {
        0
    } else {
        sel_pos.saturating_sub(body_h.saturating_sub(1)).min(entries.len().saturating_sub(body_h))
    };
    app.sidebar_offset = offset;
    app.sidebar_rows.clear();
    let shown = &entries[offset.min(entries.len())..(offset + body_h).min(entries.len())];
    for (line, entry) in shown.iter().enumerate() {
        let y = body_y + line as u16;
        match *entry {
            Entry::Blank => {}
            Entry::More(group, hidden) => {
                let group = &layout.names[group as usize];
                let label = format!("Show more ({hidden})");
                let rect = Rect { x: area.x, y, width: area.width - 1, height: 1 };
                let hot = hovered_row(app.hover, y);
                let style = if hot {
                    ground.bg(c.sidebar_selected_bg).fg(c.status_fg)
                } else {
                    ground.fg(c.sidebar_dim_fg)
                };
                if hot {
                    paint_row(buf, y, style);
                }
                buf.set_stringn(area.x + 3, y, &label, content_w.saturating_sub(4), style);
                app.buttons.push((rect, ButtonAction::ShowGroup(group.to_owned())));
            }
            Entry::Header(name, cwd_row) => {
                let name = layout.names[name as usize].as_str();
                let cwd = cwd_row.and_then(|row| {
                    app.sessions[row as usize - ndrafts].get("cwd").and_then(Value::as_str)
                });
                buf.set_stringn(area.x + 1, y, "▢", 1, ground.fg(c.sidebar_dim_fg));
                let plus_w = if cwd.is_some() { 3 } else { 0 };
                let name_w = content_w.saturating_sub(4 + plus_w);
                buf.set_stringn(
                    area.x + 3,
                    y,
                    truncate(name, name_w),
                    name_w,
                    ground.fg(c.sidebar_dim_fg),
                );
                if let Some(path) = cwd {
                    let x = area.x + area.width.saturating_sub(4);
                    let hot =
                        app.hover.map(|(hx, hy)| hy == y && hx >= x && hx < x + 3).unwrap_or(false);
                    let style = if hot {
                        ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
                    } else {
                        ground.fg(c.sidebar_dim_fg)
                    };
                    buf.set_stringn(x, y, "+", 1, style);
                    app.buttons.push((
                        Rect { x, y, width: 3, height: 1 },
                        ButtonAction::NewProject(path.to_owned()),
                    ));
                }
            }
            Entry::Row(idx) => {
                let idx = idx as usize;
                let is_sel = idx == selected;
                let is_draft = idx < ndrafts;
                let (name_owned, status, pending, dot) = match idx.checked_sub(ndrafts) {
                    None => {
                        let preview = app.drafts[idx].text.text();
                        let title = if preview.trim().is_empty() {
                            "Draft".to_owned()
                        } else {
                            preview.lines().next().unwrap_or("").to_owned()
                        };
                        (title, "", false, 0)
                    }
                    Some(at) => {
                        let s = &app.sessions[at];
                        let t = session_title(s);
                        let name = match s.get("peer").and_then(Value::as_str) {
                            Some(p) => {
                                t.strip_prefix(&format!("{p}/")).map(str::to_owned).unwrap_or(t)
                            }
                            None => t,
                        };
                        let sid = session_route_id(s).unwrap_or_default();
                        (
                            name,
                            s.get("status").and_then(Value::as_str).unwrap_or(""),
                            s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0,
                            app.attention.get(&sid).copied().unwrap_or(0),
                        )
                    }
                };
                let name = name_owned.as_str();
                let hot = hovered_row(app.hover, y);
                let row_style = if is_sel {
                    ground.bg(c.sidebar_selected_bg).fg(c.sidebar_selected_fg)
                } else if hot {
                    ground.bg(c.sidebar_selected_bg).fg(c.status_fg)
                } else if status == "closed" {
                    ground.fg(c.sidebar_dim_fg)
                } else {
                    ground.fg(c.status_fg)
                };
                if is_sel || hot {
                    paint_row(buf, y, row_style);
                }
                // Mark at the right edge: a question for a pending permission,
                // a dot for work that ended unseen, a spinner glyph while running.
                let (mark, mark_style): (&str, Style) = if is_draft {
                    ("", row_style)
                } else if pending {
                    ("?", row_style.fg(c.attention_fg).add_modifier(Modifier::BOLD))
                } else if status == "running" {
                    ("●", row_style.fg(c.warn_fg))
                } else if status == "waiting" {
                    ("?", row_style.fg(c.attention_fg))
                } else if matches!(status, "disconnected" | "unreachable") {
                    ("!", row_style.fg(c.error_fg))
                } else if dot > 0 && !is_sel {
                    (
                        "•",
                        row_style.fg(match dot {
                            3 => c.error_fg,
                            2 => c.attention_fg,
                            _ => c.ok_fg,
                        }),
                    )
                } else {
                    ("", row_style)
                };
                let indent: u16 = if is_draft { 1 } else { 3 };
                let name_w =
                    content_w.saturating_sub(indent as usize + if mark.is_empty() { 1 } else { 3 });
                let shown = if is_draft { format!("✎ {name}") } else { name.to_owned() };
                buf.set_stringn(
                    area.x + indent,
                    y,
                    truncate(&shown, name_w),
                    name_w,
                    if is_sel { row_style.add_modifier(Modifier::BOLD) } else { row_style },
                );
                if !mark.is_empty() {
                    buf.set_stringn(area.x + area.width - 3, y, mark, 1, mark_style);
                }
                app.sidebar_rows
                    .push((Rect { x: area.x, y, width: area.width - 1, height: 1 }, idx));
            }
        }
    }
    if layout.groups.is_empty() && body_h > 1 {
        let what = match app.host_filter.as_deref() {
            Some("local") => "No sessions on this Mac".to_owned(),
            Some(h) => format!("No sessions on {h}"),
            None => "No sessions yet".to_owned(),
        };
        buf.set_stringn(area.x + 1, body_y, &what, content_w, ground.fg(c.sidebar_dim_fg));
        buf.set_stringn(
            area.x + 1,
            body_y + 1,
            "Ctrl-t starts one",
            content_w,
            ground.fg(c.sidebar_dim_fg),
        );
    }
    // Scrollbar at the inner edge when the list overflows.
    if entries.len() > body_h && body_h > 0 {
        let track = Rect { x: area.x + area.width - 2, y: body_y, width: 1, height: body_h as u16 };
        let thumb = crate::tui::scroll::thumb_geometry(entries.len(), body_h, offset, track.height);
        draw_thumb(
            buf,
            track,
            thumb,
            c.scrollbar_thumb_fg,
            c.scrollbar_thumb_active_fg,
            crate::tui::scroll::ThumbState::Idle,
        );
    }
    // The resize handle column stays the sidebar shade; a hover or drag
    // shows a thin mark so the affordance is discoverable.
    let rule_x = area.x + area.width - 1;
    let rule_hot =
        app.sidebar_drag.is_some() || app.hover.map(|(hx, _)| hx == rule_x).unwrap_or(false);
    if rule_hot {
        for y in area.y..area.y + area.height {
            if let Some(cell) = buf.cell_mut((rule_x, y)) {
                cell.set_symbol("▏").set_style(ground.fg(c.border_active_fg));
            }
        }
    }
    app.sidebar_layout = layout;
}

#[cfg(all(test, unix))]
#[path = "sidebar_tests.rs"]
mod tests;
