//! Render broker — owns server-side libghostty-vt Terminals off the async
//! runtime so we can feed PTY bytes into them, maintain authoritative grid
//! state, and compose frames with cmx chrome (sidebar + status bar) for
//! Grid clients.
//!
//! libghostty-vt's objects are `!Send + !Sync` (deliberately) so all
//! Terminals live on a single dedicated std::thread. Communication is via
//! message passing — async callers enqueue requests via a `std::sync::mpsc`
//! sender and, for compose requests, await a `tokio::sync::oneshot` reply.

use std::cell::Cell as StdCell;
use std::collections::{BTreeMap, HashMap};
use std::rc::Rc;
use std::thread;
use std::time::Duration;

use cmux_cli_core::compositor::{
    self, Cell, Frame, RgbColor, StyleColor, TerminalGridDefaultColors, TerminalGridSnapshot,
};
use cmux_cli_core::layout::Rect;
use cmux_cli_core::probe;
use libghostty_vt::screen::Screen;
use libghostty_vt::style::RgbColor as GhosttyRgbColor;
use libghostty_vt::terminal::{
    ConformanceLevel, DeviceAttributeFeature, DeviceAttributes, DeviceType,
    PrimaryDeviceAttributes, SecondaryDeviceAttributes, SizeReportSize,
};
use libghostty_vt::{Terminal, TerminalOptions};
use tokio::sync::{mpsc, oneshot};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use crate::{PtyOp, TerminalResponse, TerminalResponseSource};

pub type TabId = u64;
const XTVERSION_RESPONSE: &str = concat!("cmx ", env!("CARGO_PKG_VERSION"));

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalProbeKind {
    DefaultForegroundColor,
    DefaultBackgroundColor,
}

#[derive(Debug, Clone, Copy)]
pub struct TerminalProbeColors {
    pub foreground: Option<GhosttyRgbColor>,
    pub background: Option<GhosttyRgbColor>,
}

impl TerminalProbeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::DefaultForegroundColor => "default_foreground_color",
            Self::DefaultBackgroundColor => "default_background_color",
        }
    }
}

/// Snapshot of the chrome the render thread should draw around the pane.
#[derive(Debug, Clone)]
pub struct ChromeSpec {
    pub sidebar: SidebarSpec,
    pub space_bar: TabBarSpec,
    pub status: StatusSpec,
    /// One entry per visible leaf pane. In the simple (unsplit) case
    /// this has a single entry whose tab_bar covers every tab in the
    /// workspace. When splits are active, each split leaf contributes
    /// its own entry with only its own tab in the tab_bar.
    pub panes: Vec<PaneChrome>,
}

#[derive(Debug, Clone)]
pub struct PaneChrome {
    /// Active tab rendered in this pane. Used by the render thread to
    /// clamp the pane border to the tab's canonical grid when another
    /// client has made the shared terminal smaller than this TUI pane.
    pub active_tab_id: TabId,
    /// Interior rect where terminal cells are pasted.
    pub terminal_rect: Rect,
    /// Tab bar painted inline along the top of this pane's border.
    pub tab_bar: TabBarSpec,
    /// Optional zellij-style border around this pane. `None` when the
    /// viewport is too small to spare rows/cols for it.
    pub border: Option<BorderSpec>,
}

#[derive(Debug, Clone)]
pub struct BorderSpec {
    /// Outer rectangle whose perimeter is drawn as a single-line
    /// box. Tab pills are painted inline along the top edge after
    /// the box characters are laid down.
    pub rect: Rect,
    /// Tab pills embedded in the top border (zellij-style). Kept
    /// separate from `tab_bar.tabs` so the border painter can reason
    /// about labels without worrying about the chrome-level hit-test
    /// that `tab_bar` drives.
    pub tabs: Vec<TabPill>,
    /// When true the border is drawn in an attention colour (the
    /// result of `cmx notify` or an inbound bell). Transient — the
    /// server's notify handler schedules a repaint after the flash
    /// window to clear it.
    pub flashing: bool,
    /// True for the panel that receives keyboard input. The compositor
    /// paints it with a bright ring so focus remains obvious in dense
    /// split layouts.
    pub focused: bool,
}

/// Tab strip painted at the top row of each pane. When splits land this
/// will render per-leaf-pane — today there's only one pane so it covers
/// the full pane width.
#[derive(Debug, Clone)]
pub struct TabBarSpec {
    pub rect: Rect,
    pub tabs: Vec<TabPill>,
    pub style: TabBarStyle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TabBarStyle {
    Pill,
    Text,
}

#[derive(Debug, Clone)]
pub struct SidebarSpec {
    pub width: u16,
    pub items: Vec<SidebarItem>,
    pub active: usize,
    pub focused: bool,
}

#[derive(Debug, Clone)]
pub struct SidebarItem {
    pub title: String,
    /// Pinned workspaces render with a leading `📌` so the user
    /// knows which ones survive `exit` / last-tab-close.
    pub pinned: bool,
    /// Optional user-set RGB tint for the workspace row. Painted
    /// as a small `●` dot after the pin marker so long titles stay
    /// readable on a narrow sidebar.
    pub color_rgb: Option<RgbColor>,
}

#[derive(Debug, Clone)]
pub struct StatusSpec {
    /// Left side: `[workspace]` label.
    pub text: String,
    /// Right side: zellij-style shortcut hints, e.g.
    /// `C-b c new · C-b n next · C-b d detach`.
    pub hints: String,
}

#[derive(Debug, Clone)]
pub struct TabPill {
    pub title: String,
    pub active: bool,
    /// Inactive tab whose PTY emitted output since the user last
    /// viewed it. Rendered with a leading `•` marker so the user sees
    /// which background tabs are noisy without switching to them.
    pub has_activity: bool,
    /// 0-based global tab index — used in the pill label so the
    /// printed number matches `cmx select-tab <N>` and the rest of
    /// the CLI. In split mode the leaf's single pill still carries
    /// its global index, so pane 1's pill prints `1:…` rather than
    /// `0:…` from local enumerate.
    pub index: usize,
}

/// A text-style (line-wrapping) selection: from `start` to `end`,
/// inclusive on both ends. Coordinates are in pane-local cells (row 0 =
/// first row of the pane).
#[derive(Debug, Clone, Copy)]
pub struct LineSelection {
    pub start_col: u16,
    pub start_row: u16,
    pub end_col: u16,
    pub end_row: u16,
}

/// A text-style selection in terminal scrollback coordinates. Row 0 is
/// the top of the terminal's scrollable area, not the current viewport.
#[derive(Debug, Clone, Copy)]
pub struct LogicalLineSelection {
    pub start_col: u16,
    pub start_row: u64,
    pub end_col: u16,
    pub end_row: u64,
}

pub(crate) struct RenderTabInit {
    pub id: TabId,
    pub cols: u16,
    pub rows: u16,
    /// Weak writer handle for libghostty-generated terminal responses
    /// (DSR, DA, size reports, etc.). Upgrading routes through the same
    /// per-tab writer path as user input without keeping that writer alive
    /// after the tab is removed.
    pub pty_response_tx: std::sync::Weak<mpsc::UnboundedSender<PtyOp>>,
    /// Channel the render thread publishes is_mouse_tracking() on,
    /// so handlers can decide whether to pass mouse events through
    /// to the PTY or consume them for selection.
    pub mouse_tracking_tx: tokio::sync::watch::Sender<bool>,
    /// Channel the render thread publishes the active screen buffer on.
    /// Selection belongs to cmx on the primary screen, while alternate-screen
    /// TUIs keep ownership when they request mouse tracking.
    pub alternate_screen_tx: tokio::sync::watch::Sender<bool>,
    /// Shared holder where the render thread pushes the tab's latest title
    /// whenever libghostty-vt reports it via an OSC 0/2 sequence.
    pub title: std::sync::Arc<arc_swap::ArcSwap<String>>,
    /// True after an explicit `cmx rename-tab`. When set, PTY OSC title
    /// updates must not clobber the user's chosen name.
    pub explicit_title: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

pub(crate) enum RenderMsg {
    AddTab(RenderTabInit),
    PtyBytes {
        id: TabId,
        data: Vec<u8>,
    },
    Resize {
        id: TabId,
        cols: u16,
        rows: u16,
    },
    RemoveTab {
        id: TabId,
    },
    Compose {
        /// One tab/rect per visible leaf pane. Rendered in order; the
        /// first entry is assumed to be the focused one for
        /// cursor-placement purposes.
        panes: Vec<(TabId, Rect)>,
        viewport: (u16, u16),
        chrome: ChromeSpec,
        /// Optional line-wrapping selection (text-style, not
        /// rectangular). Coordinates are in the FOCUSED pane's local
        /// cell space.
        selection: Option<LineSelection>,
        reply: oneshot::Sender<Vec<u8>>,
    },
    /// Extract the plain text of a line-wrapping selection from a tab's
    /// grid. Used by the highlight-to-copy path.
    ExtractText {
        id: TabId,
        selection: LineSelection,
        pane: Rect,
        reply: oneshot::Sender<String>,
    },
    /// Extract a selection whose rows are anchored in the full
    /// scrollback coordinate space. Used when a mouse selection crosses
    /// viewport scrolls before mouse-up.
    ExtractLogicalText {
        id: TabId,
        selection: LogicalLineSelection,
        pane: Rect,
        reply: oneshot::Sender<String>,
    },
    /// Return the natural word/chunk selection at a scrollback coordinate.
    WordSelection {
        id: TabId,
        col: u16,
        row: u64,
        reply: oneshot::Sender<Option<LogicalLineSelection>>,
    },
    /// Return the current viewport offset within the scrollable area.
    ViewportOffset {
        id: TabId,
        reply: oneshot::Sender<u64>,
    },
    /// Scroll the active tab's viewport by `delta` lines (negative = up,
    /// positive = down). Used by wheel events.
    Scroll {
        id: TabId,
        delta: isize,
    },
    /// Snapshot the active screen as resolved grid cells for native
    /// graphical clients.
    GridSnapshot {
        id: TabId,
        reply: oneshot::Sender<Option<compositor::TerminalGridSnapshot>>,
    },
    TerminalProbeResponse {
        id: TabId,
        kind: TerminalProbeKind,
        reply: std::sync::mpsc::Sender<Option<Vec<u8>>>,
    },
    SetTerminalProbeColors {
        colors: TerminalProbeColors,
    },
    SetDefaultColors {
        colors: Box<TerminalGridDefaultColors>,
    },
}

pub struct RenderBroker {
    tx: std::sync::mpsc::Sender<RenderMsg>,
}

impl RenderBroker {
    pub fn spawn() -> std::io::Result<Self> {
        let (tx, rx) = std::sync::mpsc::channel::<RenderMsg>();
        thread::Builder::new()
            .name("cmx-render".into())
            .spawn(move || Self::run(rx))?;
        Ok(Self { tx })
    }

    fn run(rx: std::sync::mpsc::Receiver<RenderMsg>) {
        let mut terminals: HashMap<TabId, Box<Terminal<'static, 'static>>> = HashMap::new();
        let mut terminal_sizes: HashMap<TabId, Rc<StdCell<(u16, u16)>>> = HashMap::new();
        let mut mouse_watchers: HashMap<TabId, tokio::sync::watch::Sender<bool>> = HashMap::new();
        let mut alternate_screen_watchers: HashMap<TabId, tokio::sync::watch::Sender<bool>> =
            HashMap::new();
        let mut titles: HashMap<TabId, std::sync::Arc<arc_swap::ArcSwap<String>>> = HashMap::new();
        let mut explicit_titles: HashMap<TabId, std::sync::Arc<std::sync::atomic::AtomicBool>> =
            HashMap::new();
        let mut terminal_probe_colors: Option<TerminalProbeColors> = None;
        let mut terminal_default_colors = TerminalGridDefaultColors::default();
        let mut vt_write_seq: u64 = 0;
        let mut compose_seq: u64 = 0;
        while let Ok(msg) = rx.recv() {
            match msg {
                RenderMsg::AddTab(RenderTabInit {
                    id,
                    cols,
                    rows,
                    pty_response_tx,
                    mouse_tracking_tx,
                    alternate_screen_tx,
                    title,
                    explicit_title,
                }) => {
                    let cols = cols.max(1);
                    let rows = rows.max(1);
                    if let Ok(t) = Terminal::new(TerminalOptions {
                        cols,
                        rows,
                        max_scrollback: 1_000_000,
                    }) {
                        let mut t = Box::new(t);
                        apply_terminal_default_colors(t.as_mut(), terminal_default_colors, id);
                        let size = Rc::new(StdCell::new((cols, rows)));
                        if let Err(error) =
                            install_terminal_effects(&mut t, id, pty_response_tx, Rc::clone(&size))
                        {
                            probe::log_event(
                                "render",
                                "terminal_effects_failed",
                                &[("tab_id", id.to_string()), ("error", error.to_string())],
                            );
                        }
                        terminals.insert(id, t);
                        terminal_sizes.insert(id, size);
                        probe::log_event(
                            "render",
                            "add_tab",
                            &[
                                ("tab_id", id.to_string()),
                                ("cols", cols.to_string()),
                                ("rows", rows.to_string()),
                            ],
                        );
                    }
                    mouse_watchers.insert(id, mouse_tracking_tx);
                    alternate_screen_watchers.insert(id, alternate_screen_tx);
                    titles.insert(id, title);
                    explicit_titles.insert(id, explicit_title);
                }
                RenderMsg::PtyBytes { id, data } => {
                    vt_write_seq = vt_write_seq.saturating_add(1);
                    if probe::verbose_enabled()
                        || (probe::color_enabled() && probe::has_terminal_color_sequences(&data))
                        || probe::contains_alt_screen(&data)
                        || vt_write_seq <= 12
                    {
                        probe::log_event(
                            "render",
                            "vt_write",
                            &[
                                ("tab_id", id.to_string()),
                                ("seq", vt_write_seq.to_string()),
                                ("summary", probe::terminal_bytes_summary(&data)),
                            ],
                        );
                    }
                    if let Some(t) = terminals.get_mut(&id) {
                        t.vt_write(&data);
                        if let Some(tx) = mouse_watchers.get(&id)
                            && let Ok(tracking) = t.is_mouse_tracking()
                        {
                            let _ = tx.send(tracking);
                        }
                        if let Some(tx) = alternate_screen_watchers.get(&id)
                            && let Ok(screen) = t.active_screen()
                        {
                            let _ = tx.send(screen == Screen::Alternate);
                        }
                        // Push the latest OSC 0/2 title (if any)
                        // into the Tab's shared title slot so
                        // `cmx list-tabs` + the tab bar both pick
                        // up the program's self-reported name
                        // (vim's filename, btop, shell's PS1 hook,
                        // etc.) until the user chooses an explicit
                        // name with `cmx rename-tab`.
                        if let Some(holder) = titles.get(&id)
                            && !explicit_titles.get(&id).is_some_and(|locked| {
                                locked.load(std::sync::atomic::Ordering::Relaxed)
                            })
                            && let Ok(new_title) = t.title()
                            && !new_title.is_empty()
                        {
                            let current = holder.load();
                            if current.as_str() != new_title {
                                holder.store(std::sync::Arc::new(new_title.to_string()));
                            }
                        }
                    }
                }
                RenderMsg::Resize { id, cols, rows } => {
                    probe::log_event(
                        "render",
                        "resize",
                        &[
                            ("tab_id", id.to_string()),
                            ("cols", cols.to_string()),
                            ("rows", rows.to_string()),
                        ],
                    );
                    if let Some(t) = terminals.get_mut(&id) {
                        let cols = cols.max(1);
                        let rows = rows.max(1);
                        if let Some(size) = terminal_sizes.get(&id) {
                            size.set((cols, rows));
                        }
                        let _ = t.resize(cols, rows, 0, 0);
                    }
                }
                RenderMsg::RemoveTab { id } => {
                    probe::log_event("render", "remove_tab", &[("tab_id", id.to_string())]);
                    terminals.remove(&id);
                    terminal_sizes.remove(&id);
                    mouse_watchers.remove(&id);
                    alternate_screen_watchers.remove(&id);
                    titles.remove(&id);
                    explicit_titles.remove(&id);
                }
                RenderMsg::ExtractText {
                    id,
                    selection,
                    pane,
                    reply,
                } => {
                    let text = terminals
                        .get(&id)
                        .map(|t| extract_line_selection(t, selection, pane))
                        .unwrap_or_default();
                    let _ = reply.send(text);
                }
                RenderMsg::ExtractLogicalText {
                    id,
                    selection,
                    pane,
                    reply,
                } => {
                    let text = terminals
                        .get_mut(&id)
                        .map(|t| extract_logical_line_selection(t, selection, pane))
                        .unwrap_or_default();
                    let _ = reply.send(text);
                }
                RenderMsg::WordSelection {
                    id,
                    col,
                    row,
                    reply,
                } => {
                    let range = terminals
                        .get_mut(&id)
                        .and_then(|t| word_selection_at(t, col, row));
                    let _ = reply.send(range);
                }
                RenderMsg::ViewportOffset { id, reply } => {
                    let offset = terminals
                        .get(&id)
                        .and_then(|t| t.scrollbar().ok())
                        .map(|scrollbar| scrollbar.offset)
                        .unwrap_or(0);
                    let _ = reply.send(offset);
                }
                RenderMsg::Scroll { id, delta } => {
                    if let Some(t) = terminals.get_mut(&id) {
                        use libghostty_vt::terminal::ScrollViewport;
                        t.scroll_viewport(ScrollViewport::Delta(delta));
                    }
                }
                RenderMsg::GridSnapshot { id, reply } => {
                    let snapshot = terminals
                        .get(&id)
                        .and_then(|terminal| compositor::terminal_grid_snapshot(terminal).ok());
                    if let Some(snapshot) = &snapshot
                        && (probe::color_enabled() || probe::verbose_enabled())
                    {
                        let sample = if probe::color_enabled() {
                            terminal_grid_color_sample(snapshot)
                        } else {
                            String::new()
                        };
                        probe::log_event(
                            "render",
                            "grid_snapshot",
                            &[
                                ("tab_id", id.to_string()),
                                ("cols", snapshot.cols.to_string()),
                                ("rows", snapshot.rows.to_string()),
                                ("cells", snapshot.cells.len().to_string()),
                                ("sample", sample),
                            ],
                        );
                    }
                    let _ = reply.send(snapshot);
                }
                RenderMsg::TerminalProbeResponse { id, kind, reply } => {
                    let bytes = terminals
                        .contains_key(&id)
                        .then(|| terminal_probe_response(kind, terminal_probe_colors))
                        .flatten();
                    let _ = reply.send(bytes);
                }
                RenderMsg::SetTerminalProbeColors { colors } => {
                    terminal_probe_colors = Some(colors);
                }
                RenderMsg::SetDefaultColors { colors } => {
                    terminal_default_colors = *colors;
                    for (id, terminal) in &mut terminals {
                        apply_terminal_default_colors(
                            terminal.as_mut(),
                            terminal_default_colors,
                            *id,
                        );
                    }
                    if probe::color_enabled() {
                        probe::log_event(
                            "render",
                            "terminal_default_colors_set",
                            &[(
                                "summary",
                                terminal_default_color_summary(terminal_default_colors),
                            )],
                        );
                    }
                }
                RenderMsg::Compose {
                    panes,
                    viewport,
                    chrome,
                    selection,
                    reply,
                } => {
                    compose_seq = compose_seq.saturating_add(1);
                    let mut frame = Frame::new(viewport.0, viewport.1);
                    paint_sidebar(&mut frame, &chrome.sidebar);
                    paint_tab_bar(&mut frame, &chrome.space_bar);
                    // Each leaf pane paints its border BEFORE its tab
                    // bar, so the tab pills overlay the `─` chars
                    // along the top edge without the background fill
                    // clobbering the corners.
                    for pc in &chrome.panes {
                        if let Some(border) = pc.border.as_ref() {
                            let effective_border = effective_pane_border(
                                border,
                                pc.terminal_rect,
                                terminal_sizes.get(&pc.active_tab_id).map(|size| size.get()),
                            );
                            paint_pane_border(&mut frame, &effective_border);
                            let effective_tab_bar =
                                tab_bar_for_border(&pc.tab_bar, effective_border.rect);
                            paint_tab_bar(&mut frame, &effective_tab_bar);
                        } else {
                            paint_tab_bar(&mut frame, &pc.tab_bar);
                        }
                    }
                    paint_status(&mut frame, &chrome.status);
                    // Paste each pane's terminal content.
                    let mut cursor_tail: Option<Vec<u8>> = None;
                    for (i, (pane_id, pane_rect)) in panes.iter().enumerate() {
                        let Some(terminal) = terminals.get(pane_id) else {
                            continue;
                        };
                        if let Err(error) = compositor::paste_pane(&mut frame, *pane_rect, terminal)
                        {
                            tracing::warn!(%error, pane_id, "could not paste pane into composed frame");
                        }
                        if probe::color_enabled() && (compose_seq <= 80 || i == 0) {
                            probe::log_event(
                                "render",
                                "compose_pane_colors",
                                &[
                                    ("compose_seq", compose_seq.to_string()),
                                    ("tab_id", pane_id.to_string()),
                                    (
                                        "rect",
                                        format!(
                                            "{}x{}@{},{}",
                                            pane_rect.cols,
                                            pane_rect.rows,
                                            pane_rect.col,
                                            pane_rect.row
                                        ),
                                    ),
                                    ("summary", frame_color_summary(&frame, Some(*pane_rect))),
                                ],
                            );
                        }
                        // Selection is clipped to the focused (first)
                        // pane in the list. Other panes stay untouched
                        // so dragging a selection in one pane doesn't
                        // smear into siblings.
                        if i == 0
                            && let Some(sel) = selection
                        {
                            overlay_line_selection(&mut frame, sel, *pane_rect);
                        }
                        // Cursor placement: only the focused pane (the
                        // first one) shows its tab's cursor. Other
                        // panes stay cursor-hidden so the host
                        // terminal only blinks in one place.
                        if i == 0 {
                            let visible = terminal.is_cursor_visible().unwrap_or(true);
                            if visible {
                                let cx = terminal.cursor_x().unwrap_or(0);
                                let cy = terminal.cursor_y().unwrap_or(0);
                                let max_col = frame.cols.saturating_sub(1) as u32;
                                let max_row = frame.rows.saturating_sub(1) as u32;
                                let abs_col =
                                    (pane_rect.col as u32 + cx as u32).min(max_col) as u16;
                                let abs_row =
                                    (pane_rect.row as u32 + cy as u32).min(max_row) as u16;
                                let mut tail = Vec::new();
                                tail.extend_from_slice(b"\x1b[?25h");
                                tail.extend_from_slice(
                                    format!("\x1b[{};{}H", abs_row + 1, abs_col + 1).as_bytes(),
                                );
                                cursor_tail = Some(tail);
                            } else {
                                cursor_tail = Some(b"\x1b[?25l".to_vec());
                            }
                        }
                    }
                    let mut ansi = Vec::new();
                    ansi.extend_from_slice(&compositor::emit_ansi(&frame));
                    ansi.extend_from_slice(cursor_tail.as_deref().unwrap_or(b"\x1b[?25h"));
                    if probe::color_enabled()
                        && (compose_seq <= 120
                            || probe::has_terminal_color_sequences(&ansi)
                            || probe::contains_alt_screen(&ansi))
                    {
                        probe::log_event(
                            "render",
                            "compose_output",
                            &[
                                ("compose_seq", compose_seq.to_string()),
                                ("viewport", format!("{}x{}", viewport.0, viewport.1)),
                                ("frame_colors", frame_color_summary(&frame, None)),
                                ("bytes", probe::terminal_bytes_summary(&ansi)),
                            ],
                        );
                    }
                    let _ = reply.send(ansi);
                }
            }
        }
    }

    pub(crate) fn add_tab(&self, init: RenderTabInit) {
        let _ = self.tx.send(RenderMsg::AddTab(init));
    }

    pub fn pty_bytes(&self, id: TabId, data: Vec<u8>) {
        let _ = self.tx.send(RenderMsg::PtyBytes { id, data });
    }

    pub fn resize(&self, id: TabId, cols: u16, rows: u16) {
        let _ = self.tx.send(RenderMsg::Resize { id, cols, rows });
    }

    pub fn remove_tab(&self, id: TabId) {
        let _ = self.tx.send(RenderMsg::RemoveTab { id });
    }

    pub async fn compose(
        &self,
        panes: Vec<(TabId, Rect)>,
        viewport: (u16, u16),
        chrome: ChromeSpec,
        selection: Option<LineSelection>,
    ) -> Vec<u8> {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .tx
            .send(RenderMsg::Compose {
                panes,
                viewport,
                chrome,
                selection,
                reply: reply_tx,
            })
            .is_err()
        {
            return Vec::new();
        }
        reply_rx.await.unwrap_or_default()
    }

    pub async fn extract_text(&self, id: TabId, selection: LineSelection, pane: Rect) -> String {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .tx
            .send(RenderMsg::ExtractText {
                id,
                selection,
                pane,
                reply: reply_tx,
            })
            .is_err()
        {
            return String::new();
        }
        reply_rx.await.unwrap_or_default()
    }

    pub async fn extract_logical_text(
        &self,
        id: TabId,
        selection: LogicalLineSelection,
        pane: Rect,
    ) -> String {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .tx
            .send(RenderMsg::ExtractLogicalText {
                id,
                selection,
                pane,
                reply: reply_tx,
            })
            .is_err()
        {
            return String::new();
        }
        reply_rx.await.unwrap_or_default()
    }

    pub async fn word_selection(
        &self,
        id: TabId,
        col: u16,
        row: u64,
    ) -> Option<LogicalLineSelection> {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .tx
            .send(RenderMsg::WordSelection {
                id,
                col,
                row,
                reply: reply_tx,
            })
            .is_err()
        {
            return None;
        }
        reply_rx.await.unwrap_or(None)
    }

    pub async fn viewport_offset(&self, id: TabId) -> u64 {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .tx
            .send(RenderMsg::ViewportOffset {
                id,
                reply: reply_tx,
            })
            .is_err()
        {
            return 0;
        }
        reply_rx.await.unwrap_or_default()
    }

    pub fn scroll(&self, id: TabId, delta: isize) {
        let _ = self.tx.send(RenderMsg::Scroll { id, delta });
    }

    pub async fn grid_snapshot(&self, id: TabId) -> Option<compositor::TerminalGridSnapshot> {
        let (reply_tx, reply_rx) = oneshot::channel();
        if self
            .tx
            .send(RenderMsg::GridSnapshot {
                id,
                reply: reply_tx,
            })
            .is_err()
        {
            return None;
        }
        reply_rx.await.unwrap_or_default()
    }

    pub fn terminal_probe_response(&self, id: TabId, kind: TerminalProbeKind) -> Option<Vec<u8>> {
        let (reply_tx, reply_rx) = std::sync::mpsc::channel();
        if self
            .tx
            .send(RenderMsg::TerminalProbeResponse {
                id,
                kind,
                reply: reply_tx,
            })
            .is_err()
        {
            return None;
        }
        reply_rx
            .recv_timeout(Duration::from_millis(250))
            .ok()
            .flatten()
    }

    pub fn set_terminal_probe_colors(&self, colors: TerminalProbeColors) {
        let _ = self.tx.send(RenderMsg::SetTerminalProbeColors { colors });
    }

    pub fn set_default_colors(&self, colors: TerminalGridDefaultColors) {
        let _ = self.tx.send(RenderMsg::SetDefaultColors {
            colors: Box::new(colors),
        });
    }
}

fn apply_terminal_default_colors(
    terminal: &mut Terminal<'static, 'static>,
    colors: TerminalGridDefaultColors,
    tab_id: TabId,
) {
    if let Err(error) = terminal.set_default_fg_color(colors.foreground) {
        log_terminal_default_color_error(tab_id, "foreground", error);
    }
    if let Err(error) = terminal.set_default_bg_color(colors.background) {
        log_terminal_default_color_error(tab_id, "background", error);
    }
    if let Err(error) = terminal.set_default_color_palette(colors.palette) {
        log_terminal_default_color_error(tab_id, "palette", error);
    }
    if probe::color_enabled() {
        probe::log_event(
            "render",
            "terminal_default_colors_applied",
            &[
                ("tab_id", tab_id.to_string()),
                ("summary", terminal_default_color_summary(colors)),
            ],
        );
    }
}

fn log_terminal_default_color_error(
    tab_id: TabId,
    field: &'static str,
    error: libghostty_vt::error::Error,
) {
    probe::log_event(
        "render",
        "terminal_default_color_failed",
        &[
            ("tab_id", tab_id.to_string()),
            ("field", field.to_string()),
            ("error", error.to_string()),
        ],
    );
}

fn terminal_default_color_summary(colors: TerminalGridDefaultColors) -> String {
    let palette = colors
        .palette
        .map(|palette| {
            [
                0usize, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 81, 118, 135, 166,
            ]
            .into_iter()
            .map(|index| format!("{index}={}", rgb_label(palette[index])))
            .collect::<Vec<_>>()
            .join(",")
        })
        .unwrap_or_else(|| "-".to_string());
    format!(
        "fg={} bg={} palette={}",
        colors
            .foreground
            .map(rgb_label)
            .unwrap_or_else(|| "-".to_string()),
        colors
            .background
            .map(rgb_label)
            .unwrap_or_else(|| "-".to_string()),
        palette,
    )
}

fn terminal_grid_color_sample(snapshot: &TerminalGridSnapshot) -> String {
    let mut samples = Vec::new();
    for (index, cell) in snapshot.cells.iter().enumerate() {
        if samples.len() >= 80 {
            break;
        }
        if cell.text.trim().is_empty() {
            continue;
        }
        let row = index / usize::from(snapshot.cols);
        let col = index % usize::from(snapshot.cols);
        samples.push(format!(
            "{row}:{col}:{} fg={} bg={} flags={}{}{}{}{}{}",
            probe::preview_bytes(cell.text.as_bytes(), 12),
            rgb_label(cell.fg),
            rgb_label(cell.bg),
            if cell.bold { "b" } else { "-" },
            if cell.italic { "i" } else { "-" },
            if cell.underline { "u" } else { "-" },
            if cell.faint { "f" } else { "-" },
            if cell.blink { "k" } else { "-" },
            if cell.strikethrough { "s" } else { "-" },
        ));
    }
    samples.join(";")
}

fn rgb_label(color: RgbColor) -> String {
    format!("#{:02X}{:02X}{:02X}", color.r, color.g, color.b)
}

fn install_terminal_effects(
    terminal: &mut Terminal<'static, 'static>,
    tab_id: TabId,
    pty_response_tx: std::sync::Weak<mpsc::UnboundedSender<PtyOp>>,
    size: Rc<StdCell<(u16, u16)>>,
) -> libghostty_vt::error::Result<()> {
    terminal
        .on_pty_write(move |_terminal, data| {
            let bytes = data.to_vec();
            if probe::enabled() {
                probe::log_event(
                    "render",
                    "terminal_effect_response",
                    &[
                        ("tab_id", tab_id.to_string()),
                        ("bytes", bytes.len().to_string()),
                        ("preview", probe::preview_bytes(&bytes, 80)),
                    ],
                );
            }
            if let Some(pty_response_tx) = pty_response_tx.upgrade() {
                let _ = pty_response_tx.send(PtyOp::TerminalResponse(TerminalResponse {
                    kind: TerminalResponseSource::Libghostty,
                    bytes,
                }));
            }
        })?
        .on_size(move |_terminal| {
            let (columns, rows) = size.get();
            Some(SizeReportSize {
                rows,
                columns,
                cell_width: 0,
                cell_height: 0,
            })
        })?
        .on_device_attributes(|_terminal| Some(cmx_device_attributes()))?
        .on_xtversion(|_terminal| Some(XTVERSION_RESPONSE))?
        .on_color_scheme(|_terminal| None)?;
    Ok(())
}

fn cmx_device_attributes() -> DeviceAttributes {
    DeviceAttributes {
        primary: PrimaryDeviceAttributes::new(
            ConformanceLevel::VT220,
            [
                DeviceAttributeFeature::COLUMNS_132,
                DeviceAttributeFeature::SELECTIVE_ERASE,
                DeviceAttributeFeature::ANSI_COLOR,
            ],
        ),
        secondary: SecondaryDeviceAttributes {
            device_type: DeviceType::VT220,
            firmware_version: 1,
            rom_cartridge: 0,
        },
        tertiary: Default::default(),
    }
}

fn terminal_probe_response(
    kind: TerminalProbeKind,
    client_colors: Option<TerminalProbeColors>,
) -> Option<Vec<u8>> {
    let colors = client_colors?;
    match kind {
        TerminalProbeKind::DefaultForegroundColor => {
            colors.foreground.map(|color| osc_color_response(10, color))
        }
        TerminalProbeKind::DefaultBackgroundColor => {
            colors.background.map(|color| osc_color_response(11, color))
        }
    }
}

fn osc_color_response(slot: u8, color: GhosttyRgbColor) -> Vec<u8> {
    let r = u16::from(color.r) * 257;
    let g = u16::from(color.g) * 257;
    let b = u16::from(color.b) * 257;
    format!("\x1b]{slot};rgb:{r:04x}/{g:04x}/{b:04x}\x1b\\").into_bytes()
}

// ------------------------------ chrome paint -----------------------------

const SIDEBAR_BG: RgbColor = RgbColor {
    r: 24,
    g: 26,
    b: 30,
};
const SIDEBAR_FG: RgbColor = RgbColor {
    r: 210,
    g: 210,
    b: 215,
};
const SIDEBAR_FG_DIM: RgbColor = RgbColor {
    r: 130,
    g: 130,
    b: 140,
};
const ACCENT: RgbColor = RgbColor {
    r: 100,
    g: 160,
    b: 255,
};
const STATUS_BG: RgbColor = RgbColor {
    r: 40,
    g: 44,
    b: 50,
};
const STATUS_FG: RgbColor = RgbColor {
    r: 220,
    g: 220,
    b: 220,
};

fn paint_sidebar(frame: &mut Frame, spec: &SidebarSpec) {
    let width = spec.width.min(frame.cols);
    if width == 0 {
        return;
    }
    // Background fill across the full height (minus status row).
    frame.fill_rect(
        Rect {
            col: 0,
            row: 0,
            cols: width,
            rows: frame.rows.saturating_sub(1),
        },
        Some(SIDEBAR_BG),
    );

    // Header.
    let header_bg = if spec.focused {
        TAB_PILL_ACTIVE_BG
    } else {
        SIDEBAR_BG
    };
    let header_fg = if spec.focused {
        TAB_PILL_ACTIVE_FG
    } else {
        ACCENT
    };
    frame.paint_text(
        0,
        0,
        &pad_left(" cmux ", width as usize),
        Some(header_fg),
        Some(header_bg),
    );

    // Items.
    for (i, item) in spec.items.iter().enumerate() {
        let row = 2u16.saturating_add(i as u16);
        if row >= frame.rows.saturating_sub(1) {
            break;
        }
        let active_marker = if i == spec.active { "▶" } else { " " };
        let pin_marker = if item.pinned { "*" } else { " " };
        let fg = if i == spec.active {
            SIDEBAR_FG
        } else {
            SIDEBAR_FG_DIM
        };
        // Layout: "<active><pin><colordot><title>". The colored
        // dot is painted separately so it uses the user's RGB
        // instead of the row's foreground color.
        let (dot_glyph, dot_col) = if item.color_rgb.is_some() {
            ("● ", Some(2u16))
        } else {
            ("", None)
        };
        let prefix = format!("{active_marker}{pin_marker}{dot_glyph}");
        let line = format!("{prefix}{}", item.title);
        frame.paint_text(
            row,
            0,
            &pad_left(&line, width as usize),
            Some(fg),
            Some(SIDEBAR_BG),
        );
        // Overlay the dot in the user's color so it stands out
        // regardless of the dim/bright row styling above.
        if let (Some(rgb), Some(col)) = (item.color_rgb, dot_col) {
            frame.paint_text(row, col, "●", Some(rgb), Some(SIDEBAR_BG));
        }
    }
}

const TAB_PILL_BG: RgbColor = RgbColor {
    r: 44,
    g: 48,
    b: 54,
};
const TAB_PILL_FG: RgbColor = RgbColor {
    r: 170,
    g: 170,
    b: 180,
};
const TAB_PILL_ACTIVE_BG: RgbColor = RgbColor {
    r: 70,
    g: 115,
    b: 180,
};
const TAB_PILL_ACTIVE_FG: RgbColor = RgbColor {
    r: 240,
    g: 240,
    b: 245,
};

const TAB_PILL_ACTIVITY_FG: RgbColor = RgbColor {
    r: 255,
    g: 180,
    b: 90,
};
const PANE_BORDER_FG: RgbColor = RgbColor {
    r: 90,
    g: 100,
    b: 120,
};
/// Attention colour used when `BorderSpec.flashing` is set — the
/// result of `cmx notify`, a PTY bell, or any other ask-the-user
/// event. Bright yellow stands out against both light and dark
/// host-terminal themes.
const PANE_BORDER_FLASH_FG: RgbColor = RgbColor {
    r: 255,
    g: 200,
    b: 70,
};
const PANE_BORDER_FOCUS_FG: RgbColor = RgbColor {
    r: 120,
    g: 210,
    b: 255,
};

/// Paint a single-line rounded-corner box around `border.rect`.
/// This is the zellij-style frame that visually encloses a pane. The
/// tab bar is painted separately ON TOP of the top edge, so the
/// border just lays down box-drawing glyphs around the perimeter and
/// leaves the pane interior alone. When `border.flashing` is true the
/// whole perimeter is drawn in the attention colour.
fn paint_pane_border(frame: &mut Frame, border: &BorderSpec) {
    let rect = border.rect;
    if rect.rows < 2 || rect.cols < 2 {
        return;
    }
    let top_row = rect.row;
    let bottom_row = rect.row + rect.rows - 1;
    let left_col = rect.col;
    let right_col = rect.col + rect.cols - 1;
    let fg = if border.flashing {
        PANE_BORDER_FLASH_FG
    } else if border.focused {
        PANE_BORDER_FOCUS_FG
    } else {
        PANE_BORDER_FG
    };
    let bold = border.focused && !border.flashing;

    // Corners.
    paint_border_glyph(frame, top_row, left_col, "╭", fg, bold);
    paint_border_glyph(frame, top_row, right_col, "╮", fg, bold);
    paint_border_glyph(frame, bottom_row, left_col, "╰", fg, bold);
    paint_border_glyph(frame, bottom_row, right_col, "╯", fg, bold);

    // Top + bottom horizontal runs.
    for c in (left_col + 1)..right_col {
        paint_border_glyph(frame, top_row, c, "─", fg, bold);
        paint_border_glyph(frame, bottom_row, c, "─", fg, bold);
    }

    // Left + right vertical runs.
    for r in (top_row + 1)..bottom_row {
        paint_border_glyph(frame, r, left_col, "│", fg, bold);
        paint_border_glyph(frame, r, right_col, "│", fg, bold);
    }
}

fn effective_pane_border(
    border: &BorderSpec,
    _terminal_rect: Rect,
    _terminal_size: Option<(u16, u16)>,
) -> BorderSpec {
    // The canonical terminal grid can be smaller than this client's pane when
    // another visible client is smaller. The chrome still belongs to the
    // current client viewport, so keep the pane border at the client rect.
    border.clone()
}

fn tab_bar_for_border(tab_bar: &TabBarSpec, border_rect: Rect) -> TabBarSpec {
    if border_rect.cols < 2 || border_rect.rows == 0 {
        return tab_bar.clone();
    }
    let mut effective = tab_bar.clone();
    effective.rect = Rect {
        col: border_rect.col.saturating_add(1),
        row: border_rect.row,
        cols: border_rect.cols.saturating_sub(2),
        rows: tab_bar.rect.rows.min(border_rect.rows),
    };
    effective
}

fn paint_border_glyph(
    frame: &mut Frame,
    row: u16,
    col: u16,
    glyph: &str,
    fg: RgbColor,
    bold: bool,
) {
    frame.put(
        row,
        col,
        Cell {
            grapheme: glyph.to_string(),
            fg: StyleColor::Rgb(fg),
            bold,
            ..Cell::default()
        },
    );
}

fn paint_tab_bar(frame: &mut Frame, spec: &TabBarSpec) {
    if spec.rect.rows == 0 || spec.rect.cols == 0 {
        return;
    }
    // Don't fill the full rect — when a pane border is drawn, the
    // top-edge `─` characters sit underneath this strip and should
    // remain visible between / after the pills so the frame looks
    // closed. Pills paint over them where needed.

    let row = spec.rect.row;
    let mut cursor = spec.rect.col;
    let max_col = spec.rect.col + spec.rect.cols;
    if spec.tabs.is_empty() {
        return;
    }
    let active = spec.tabs.iter().position(|pill| pill.active).unwrap_or(0);
    let (start, end, left_hidden, right_hidden) =
        visible_pill_range(&spec.tabs, active, spec.rect.cols);
    if left_hidden && cursor < max_col {
        frame.paint_text(row, cursor, "… ", Some(TAB_PILL_FG), None);
        cursor = cursor.saturating_add(2).min(max_col);
    }
    for pill in spec.tabs.iter().take(end).skip(start) {
        // Inactive tabs with new PTY output since the last view get a
        // leading `•`. Active tabs never show it (the flag is masked
        // in `tab_list`). Number is 0-based to match `cmx select-tab`
        // and every other CLI that indexes tabs.
        let marker = if !pill.active && pill.has_activity {
            "•"
        } else {
            " "
        };
        let label = format!("{marker} {}:{} ", pill.index, pill.title);
        let len = UnicodeWidthStr::width(label.as_str())
            .try_into()
            .unwrap_or(u16::MAX);
        if cursor >= max_col {
            break;
        }
        let visible_len = len.min(max_col.saturating_sub(cursor));
        let text = truncate_to_display_width(&label, visible_len as usize);
        let (fg, bg) = match spec.style {
            TabBarStyle::Pill => {
                if pill.active {
                    (TAB_PILL_ACTIVE_FG, Some(TAB_PILL_ACTIVE_BG))
                } else {
                    (TAB_PILL_FG, Some(TAB_PILL_BG))
                }
            }
            TabBarStyle::Text => {
                if pill.active {
                    (TAB_PILL_ACTIVE_FG, None)
                } else {
                    (TAB_PILL_FG, None)
                }
            }
        };
        frame.paint_text(row, cursor, &text, Some(fg), bg);
        // If there's an activity marker and the pill is inactive,
        // repaint just that single cell in the accent colour so the
        // dot pops against the muted pill background.
        if !pill.active && pill.has_activity && visible_len > 0 {
            frame.paint_text(row, cursor, marker, Some(TAB_PILL_ACTIVITY_FG), bg);
        }
        cursor = cursor.saturating_add(visible_len);
    }
    if right_hidden && cursor < max_col {
        frame.paint_text(row, cursor, " …", Some(TAB_PILL_FG), None);
    }
}

fn pill_width(pill: &TabPill) -> usize {
    UnicodeWidthStr::width(format!("  {}:{} ", pill.index, pill.title).as_str())
}

fn truncate_to_display_width(text: &str, max_width: usize) -> String {
    let mut out = String::new();
    let mut width = 0usize;
    for grapheme in text.graphemes(true) {
        let next_width = UnicodeWidthStr::width(grapheme);
        if width.saturating_add(next_width) > max_width {
            break;
        }
        out.push_str(grapheme);
        width = width.saturating_add(next_width);
    }
    out
}

fn display_width(text: &str) -> usize {
    text.graphemes(true).map(UnicodeWidthStr::width).sum()
}

fn visible_pill_range(
    pills: &[TabPill],
    active: usize,
    max_cols: u16,
) -> (usize, usize, bool, bool) {
    if pills.is_empty() {
        return (0, 0, false, false);
    }
    let count = pills.len();
    let active = active.min(count - 1);
    let widths: Vec<usize> = pills.iter().map(pill_width).collect();
    let total: usize = widths.iter().sum();
    let max_cols = usize::from(max_cols);
    if total <= max_cols {
        return (0, count, false, false);
    }
    let mut best = (active, active + 1);
    let mut best_visible = 1usize;
    for start in 0..=active {
        for end in (active + 1)..=count {
            let left_hidden = start > 0;
            let right_hidden = end < count;
            let marker_width =
                (if left_hidden { 2 } else { 0 }) + (if right_hidden { 2 } else { 0 });
            let width = widths[start..end].iter().sum::<usize>() + marker_width;
            let visible = end - start;
            if width <= max_cols && visible > best_visible {
                best = (start, end);
                best_visible = visible;
            }
        }
    }
    (best.0, best.1, best.0 > 0, best.1 < count)
}

fn paint_status(frame: &mut Frame, spec: &StatusSpec) {
    if frame.rows == 0 {
        return;
    }
    let row = frame.rows - 1;
    frame.fill_rect(
        Rect {
            col: 0,
            row,
            cols: frame.cols,
            rows: 1,
        },
        Some(STATUS_BG),
    );

    frame.paint_text(row, 0, &spec.text, Some(STATUS_FG), Some(STATUS_BG));
    let cursor = display_width(&spec.text).min(frame.cols as usize);

    let cols = frame.cols as usize;
    let hint_budget = cols.saturating_sub(cursor).saturating_sub(1);
    if hint_budget == 0 || spec.hints.is_empty() {
        return;
    }
    let hints = truncate_to_display_width(&spec.hints, hint_budget);
    let hint_width = display_width(&hints);
    let start_col = cols.saturating_sub(hint_width);
    if start_col > cursor {
        frame.paint_text(
            row,
            start_col.min(u16::MAX as usize) as u16,
            &hints,
            Some(STATUS_FG),
            Some(STATUS_BG),
        );
    }
}

fn pad_left(text: &str, width: usize) -> String {
    let mut out = truncate_to_display_width(text, width);
    let mut count = display_width(&out);
    while count < width {
        out.push(' ');
        count += 1;
    }
    out
}

/// Force the emitted ANSI to reference a helper we never otherwise call —
/// this silences dead-code warnings in pass-through profiles where Compose
/// is never issued.
#[doc(hidden)]
pub fn _touch_cells(_: Cell) {}

/// Selection background (bright blue) and foreground (near-white). We use
/// explicit RGB rather than inverting the cell's existing fg/bg because
/// most shell cells are default fg + default bg, and swapping two "None"
/// colors produces no visible change.
/// Toned-down selection highlight — not fluorescent blue. Close to the
/// muted "selection" bg most native terminals use.
const SELECTION_BG: RgbColor = RgbColor {
    r: 55,
    g: 70,
    b: 95,
};
const SELECTION_FG: RgbColor = RgbColor {
    r: 220,
    g: 225,
    b: 230,
};

/// Paint a line-wrapping text selection over the pane. `sel` is in
/// pane-local coordinates and this translates it to absolute frame
/// coordinates.
fn overlay_line_selection(frame: &mut Frame, sel: LineSelection, pane: Rect) {
    let (sc, sr, ec, er) = normalised(sel);
    let pane_max_row = pane.rows.saturating_sub(1);
    let pane_max_col = pane.cols.saturating_sub(1);
    let sr = sr.min(pane_max_row);
    let er = er.min(pane_max_row);
    let sc = sc.min(pane_max_col);
    let ec = ec.min(pane_max_col);

    for r in sr..=er {
        let (left, right) = if r == sr && r == er {
            (sc, ec)
        } else if r == sr {
            (sc, pane_max_col)
        } else if r == er {
            (0, ec)
        } else {
            (0, pane_max_col)
        };
        let abs_row = pane.row + r;
        for c in left..=right {
            let abs_col = pane.col + c;
            if abs_row >= frame.rows || abs_col >= frame.cols {
                continue;
            }
            let cell = &mut frame.cells[abs_row as usize][abs_col as usize];
            cell.fg = StyleColor::Rgb(SELECTION_FG);
            cell.bg = StyleColor::Rgb(SELECTION_BG);
        }
    }
}

fn normalised(sel: LineSelection) -> (u16, u16, u16, u16) {
    if (sel.start_row, sel.start_col) <= (sel.end_row, sel.end_col) {
        (sel.start_col, sel.start_row, sel.end_col, sel.end_row)
    } else {
        (sel.end_col, sel.end_row, sel.start_col, sel.start_row)
    }
}

fn normalised_logical(sel: LogicalLineSelection) -> (u16, u64, u16, u64) {
    if (sel.start_row, sel.start_col) <= (sel.end_row, sel.end_col) {
        (sel.start_col, sel.start_row, sel.end_col, sel.end_row)
    } else {
        (sel.end_col, sel.end_row, sel.start_col, sel.start_row)
    }
}

/// Read the plain-text contents of a line-wrapping selection from a
/// libghostty-vt Terminal. `sel` is in pane-local coordinates; `pane` is
/// the pane rect (unused here except for bounds — the Terminal's grid
/// is sized to the pane).
fn extract_line_selection(terminal: &Terminal<'_, '_>, sel: LineSelection, _pane: Rect) -> String {
    let (sc, sr, ec, er) = normalised(sel);
    let rect = Rect {
        col: 0,
        row: sr,
        cols: u16::MAX,
        rows: er.saturating_sub(sr).saturating_add(1),
    };
    let rows = extract_cell_rows_between(terminal, rect);
    if rows.is_empty() {
        return String::new();
    }

    // Shape the output: first row from sc, middle rows full, last row up
    // to ec (inclusive).
    let mut out = String::new();
    for (i, row) in rows.iter().enumerate() {
        let row_str: String = if rows.len() == 1 {
            row_text_between_cells(row, sc as usize, Some(ec as usize))
        } else if i == 0 {
            row_text_between_cells(row, sc as usize, None)
        } else if i + 1 == rows.len() {
            row_text_between_cells(row, 0, Some(ec as usize))
        } else {
            row.iter().filter_map(|cell| cell.as_deref()).collect()
        };
        if i > 0 {
            out.push('\n');
        }
        out.push_str(row_str.trim_end());
    }
    out
}

fn row_text_between_cells(row: &[Option<String>], start: usize, end: Option<usize>) -> String {
    let inclusive_end = end.unwrap_or_else(|| row.len().saturating_sub(1));
    row.iter()
        .enumerate()
        .filter_map(|(index, cell)| {
            (index >= start && index <= inclusive_end)
                .then_some(cell.as_ref())
                .flatten()
        })
        .map(String::as_str)
        .collect()
}

fn scroll_to_viewport_offset(terminal: &mut Terminal<'_, '_>, target_offset: u64) -> u64 {
    use libghostty_vt::terminal::ScrollViewport;

    let current = terminal
        .scrollbar()
        .map(|scrollbar| scrollbar.offset)
        .unwrap_or(0);
    let delta = target_offset as i128 - current as i128;
    if delta != 0 {
        let delta = delta.clamp(isize::MIN as i128, isize::MAX as i128) as isize;
        terminal.scroll_viewport(ScrollViewport::Delta(delta));
    }
    terminal
        .scrollbar()
        .map(|scrollbar| scrollbar.offset)
        .unwrap_or(current)
}

/// Read a selection anchored in scrollback coordinates. The render API
/// exposes fast viewport iteration, so for long selections we page the
/// viewport through the needed rows, extract each visible chunk, then put
/// the viewport back exactly where the user left it.
fn extract_logical_line_selection(
    terminal: &mut Terminal<'_, '_>,
    sel: LogicalLineSelection,
    pane: Rect,
) -> String {
    let (sc, sr, ec, er) = normalised_logical(sel);
    let Ok(original_scrollbar) = terminal.scrollbar() else {
        return String::new();
    };
    if original_scrollbar.total == 0 || pane.rows == 0 {
        return String::new();
    }

    let max_row = original_scrollbar.total.saturating_sub(1);
    let start_row = sr.min(max_row);
    let end_row = er.min(max_row);
    if start_row > end_row {
        return String::new();
    }

    let original_offset = original_scrollbar.offset;
    let mut out = String::new();
    let mut row = start_row;

    while row <= end_row {
        scroll_to_viewport_offset(terminal, row);
        let Ok(scrollbar) = terminal.scrollbar() else {
            break;
        };
        let visible_start = scrollbar.offset;
        let visible_len = scrollbar.len.max(1);
        let visible_end = visible_start
            .saturating_add(visible_len)
            .saturating_sub(1)
            .min(max_row);

        if row < visible_start {
            row = visible_start;
        }
        if row > visible_end {
            break;
        }

        let chunk_end = end_row.min(visible_end);
        let start_view_row = (row - visible_start).min(u16::MAX as u64) as u16;
        let end_view_row = (chunk_end - visible_start).min(u16::MAX as u64) as u16;
        let view_sel = LineSelection {
            start_col: if row == start_row { sc } else { 0 },
            start_row: start_view_row,
            end_col: if chunk_end == end_row {
                ec
            } else {
                pane.cols.saturating_sub(1)
            },
            end_row: end_view_row,
        };
        let chunk = extract_line_selection(terminal, view_sel, pane);
        if row != start_row {
            out.push('\n');
        }
        out.push_str(&chunk);

        if chunk_end == u64::MAX {
            break;
        }
        row = chunk_end.saturating_add(1);
    }

    scroll_to_viewport_offset(terminal, original_offset);
    out
}

fn word_selection_at(
    terminal: &mut Terminal<'_, '_>,
    col: u16,
    row: u64,
) -> Option<LogicalLineSelection> {
    let original_scrollbar = terminal.scrollbar().ok()?;
    if original_scrollbar.total == 0 {
        return None;
    }

    let max_row = original_scrollbar.total.saturating_sub(1);
    let target_row = row.min(max_row);
    let original_offset = original_scrollbar.offset;
    let visible_offset = scroll_to_viewport_offset(terminal, target_row);
    let visible_row = target_row.checked_sub(visible_offset)?;
    if visible_row > u16::MAX as u64 {
        scroll_to_viewport_offset(terminal, original_offset);
        return None;
    }

    let rows = extract_cell_rows_between(
        terminal,
        Rect {
            col: 0,
            row: visible_row as u16,
            cols: u16::MAX,
            rows: 1,
        },
    );
    scroll_to_viewport_offset(terminal, original_offset);

    let row = rows.first()?;
    word_range_in_cells(row, col as usize).map(|(start, end)| LogicalLineSelection {
        start_col: start.min(u16::MAX as usize) as u16,
        start_row: target_row,
        end_col: end.min(u16::MAX as usize) as u16,
        end_row: target_row,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WordSelectionClass {
    Word,
    Punctuation,
}

fn word_range_in_cells(row: &[Option<String>], col: usize) -> Option<(usize, usize)> {
    if col >= row.len() {
        return None;
    }
    let class = word_selection_class_at_cell(row, col)?;

    let mut start = col;
    while start > 0 && word_selection_class_at_cell(row, start - 1) == Some(class) {
        start -= 1;
    }

    let mut end = col;
    while end + 1 < row.len() && word_selection_class_at_cell(row, end + 1) == Some(class) {
        end += 1;
    }

    Some((start, end))
}

fn word_selection_class_at_cell(
    row: &[Option<String>],
    index: usize,
) -> Option<WordSelectionClass> {
    match row.get(index)? {
        Some(cell) => cell.chars().next().and_then(word_selection_class),
        None if index > 0 => word_selection_class_at_cell(row, index - 1),
        None => None,
    }
}

fn word_selection_class(ch: char) -> Option<WordSelectionClass> {
    if ch.is_whitespace() {
        return None;
    }
    if is_word_selection_char(ch) {
        Some(WordSelectionClass::Word)
    } else {
        Some(WordSelectionClass::Punctuation)
    }
}

fn is_word_selection_char(ch: char) -> bool {
    ch.is_alphanumeric()
        || matches!(
            ch,
            '_' | '-' | '.' | '/' | ':' | '@' | '~' | '%' | '+' | '?' | '&' | '=' | '#' | '$' | '!'
        )
}

fn extract_cell_rows_between(terminal: &Terminal<'_, '_>, rect: Rect) -> Vec<Vec<Option<String>>> {
    use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
    use libghostty_vt::screen::CellWide;
    let Ok(mut rs) = RenderState::new() else {
        return Vec::new();
    };
    let Ok(snapshot) = rs.update(terminal) else {
        return Vec::new();
    };
    let Ok(mut row_it) = RowIterator::new() else {
        return Vec::new();
    };
    let Ok(mut row_iter) = row_it.update(&snapshot) else {
        return Vec::new();
    };

    let mut lines: Vec<Vec<Option<String>>> = Vec::new();
    let mut row_idx: u16 = 0;
    let top = rect.row;
    let bot = rect.row.saturating_add(rect.rows);
    while row_iter.next().is_some() {
        if row_idx >= bot {
            break;
        }
        if row_idx >= top {
            let Ok(mut cell_it) = CellIterator::new() else {
                break;
            };
            let Ok(mut cell_iter) = cell_it.update(&row_iter) else {
                break;
            };
            let mut line = Vec::new();
            while cell_iter.next().is_some() {
                let wide = cell_iter
                    .raw_cell()
                    .and_then(|cell| cell.wide())
                    .unwrap_or(CellWide::Narrow);
                if matches!(wide, CellWide::SpacerTail) {
                    line.push(None);
                    continue;
                }
                if let Ok(graphemes) = cell_iter.graphemes() {
                    if graphemes.is_empty() {
                        line.push(Some(" ".to_string()));
                    } else {
                        let mut cell = String::new();
                        for ch in graphemes {
                            if ch != '\0' {
                                cell.push(ch);
                            }
                        }
                        if cell.is_empty() {
                            line.push(Some(" ".to_string()));
                        } else {
                            line.push(Some(cell));
                        }
                    }
                }
            }
            lines.push(line);
        }
        row_idx += 1;
    }
    lines
}

fn frame_color_summary(frame: &Frame, rect: Option<Rect>) -> String {
    let row_start = rect.map_or(0, |r| r.row.min(frame.rows)) as usize;
    let row_end =
        rect.map_or(frame.rows, |r| r.row.saturating_add(r.rows).min(frame.rows)) as usize;
    let col_start = rect.map_or(0, |r| r.col.min(frame.cols)) as usize;
    let col_end =
        rect.map_or(frame.cols, |r| r.col.saturating_add(r.cols).min(frame.cols)) as usize;

    let mut fg_none = 0usize;
    let mut fg_palette = 0usize;
    let mut fg_rgb = 0usize;
    let mut bg_none = 0usize;
    let mut bg_palette = 0usize;
    let mut bg_rgb = 0usize;
    let mut fg_palette_indices = BTreeMap::<u8, usize>::new();
    let mut bg_palette_indices = BTreeMap::<u8, usize>::new();
    let mut samples = Vec::new();

    for row in row_start..row_end {
        let Some(cells) = frame.cells.get(row) else {
            continue;
        };
        for col in col_start..col_end {
            let Some(cell) = cells.get(col) else {
                continue;
            };
            match cell.fg {
                StyleColor::None => fg_none += 1,
                StyleColor::Palette(p) => {
                    fg_palette += 1;
                    *fg_palette_indices.entry(p.0).or_default() += 1;
                }
                StyleColor::Rgb(_) => fg_rgb += 1,
            }
            match cell.bg {
                StyleColor::None => bg_none += 1,
                StyleColor::Palette(p) => {
                    bg_palette += 1;
                    *bg_palette_indices.entry(p.0).or_default() += 1;
                }
                StyleColor::Rgb(_) => bg_rgb += 1,
            }
            if samples.len() < 16
                && (!matches!(cell.fg, StyleColor::None)
                    || !matches!(cell.bg, StyleColor::None)
                    || cell.bold
                    || cell.italic
                    || cell.underline)
            {
                let text = if cell.grapheme.is_empty() {
                    " ".to_string()
                } else {
                    cell.grapheme.clone()
                };
                samples.push(format!(
                    "{}:{}:{} fg={} bg={} flags={}{}{}{}{}",
                    row,
                    col,
                    probe::preview_bytes(text.as_bytes(), 12),
                    style_color_label(cell.fg),
                    style_color_label(cell.bg),
                    if cell.bold { "b" } else { "-" },
                    if cell.italic { "i" } else { "-" },
                    if cell.underline { "u" } else { "-" },
                    if cell.reverse { "r" } else { "-" },
                    if cell.blink { "k" } else { "-" },
                ));
            }
        }
    }

    format!(
        "fg none/palette/rgb={fg_none}/{fg_palette}/{fg_rgb} fg_palette_indices={} bg none/palette/rgb={bg_none}/{bg_palette}/{bg_rgb} bg_palette_indices={} samples=[{}]",
        palette_index_counts(&fg_palette_indices),
        palette_index_counts(&bg_palette_indices),
        samples.join(" | ")
    )
}

fn palette_index_counts(counts: &BTreeMap<u8, usize>) -> String {
    if counts.is_empty() {
        return "-".into();
    }
    counts
        .iter()
        .map(|(index, count)| format!("{index}:{count}"))
        .collect::<Vec<_>>()
        .join(",")
}

fn style_color_label(color: StyleColor) -> String {
    match color {
        StyleColor::None => "none".into(),
        StyleColor::Palette(p) => format!("pal{}", p.0),
        StyleColor::Rgb(c) => format!("rgb({},{},{})", c.r, c.g, c.b),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn focused_pane_border_is_bright_and_bold() {
        let mut frame = Frame::new(8, 4);
        let border = BorderSpec {
            rect: Rect {
                col: 0,
                row: 0,
                cols: 8,
                rows: 4,
            },
            tabs: Vec::new(),
            flashing: false,
            focused: true,
        };

        paint_pane_border(&mut frame, &border);

        let corner = &frame.cells[0][0];
        assert_eq!(corner.grapheme, "╭");
        assert_eq!(corner.fg, StyleColor::Rgb(PANE_BORDER_FOCUS_FG));
        assert!(corner.bold);
    }

    #[test]
    fn flashing_pane_border_takes_precedence_over_focus_ring() {
        let mut frame = Frame::new(8, 4);
        let border = BorderSpec {
            rect: Rect {
                col: 0,
                row: 0,
                cols: 8,
                rows: 4,
            },
            tabs: Vec::new(),
            flashing: true,
            focused: true,
        };

        paint_pane_border(&mut frame, &border);

        let corner = &frame.cells[0][0];
        assert_eq!(corner.fg, StyleColor::Rgb(PANE_BORDER_FLASH_FG));
        assert!(!corner.bold);
    }

    #[test]
    fn pane_border_keeps_client_viewport_when_canonical_terminal_is_smaller() {
        let border = Rect {
            col: 16,
            row: 1,
            cols: 84,
            rows: 26,
        };
        let terminal = Rect {
            col: 17,
            row: 2,
            cols: 82,
            rows: 24,
        };

        assert_eq!(
            effective_pane_border(
                &BorderSpec {
                    rect: border,
                    tabs: Vec::new(),
                    flashing: false,
                    focused: true,
                },
                terminal,
                Some((30, 24)),
            )
            .rect,
            border
        );
    }

    #[test]
    fn sidebar_color_dot_does_not_overwrite_pin_marker() {
        let mut frame = Frame::new(16, 6);
        let dot = RgbColor { r: 255, g: 0, b: 0 };
        paint_sidebar(
            &mut frame,
            &SidebarSpec {
                width: 16,
                items: vec![SidebarItem {
                    title: "main".into(),
                    pinned: true,
                    color_rgb: Some(dot),
                }],
                active: 0,
                focused: false,
            },
        );

        assert_eq!(frame.cells[2][0].grapheme, "▶");
        assert_eq!(frame.cells[2][1].grapheme, "*");
        assert_eq!(frame.cells[2][2].grapheme, "●");
        assert_eq!(frame.cells[2][2].fg, StyleColor::Rgb(dot));
    }

    #[test]
    fn pad_left_uses_display_width() {
        let padded = pad_left("表", 3);

        assert_eq!(display_width(&padded), 3);
        assert_eq!(padded, "表 ");
    }

    #[test]
    fn word_range_in_cells_treats_wide_tail_as_same_word() {
        let row = vec![
            Some(" ".to_string()),
            Some("界".to_string()),
            None,
            Some(" ".to_string()),
        ];

        assert_eq!(word_range_in_cells(&row, 1), Some((1, 2)));
        assert_eq!(word_range_in_cells(&row, 2), Some((1, 2)));
    }

    #[test]
    fn terminal_default_colors_are_applied_to_libghostty_terminal_state() {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 4,
            rows: 1,
            max_scrollback: 1000,
        })
        .unwrap();
        let mut palette = terminal.default_color_palette().unwrap();
        palette[5] = RgbColor {
            r: 174,
            g: 129,
            b: 255,
        };

        let default_colors = TerminalGridDefaultColors {
            palette: Some(palette),
            ..TerminalGridDefaultColors::default()
        };
        apply_terminal_default_colors(&mut terminal, default_colors, 1);
        terminal.vt_write(b"\x1b[35mm");

        let snapshot = compositor::terminal_grid_snapshot(&terminal).unwrap();

        assert_eq!(snapshot.cells[0].text, "m");
        assert_eq!(
            snapshot.cells[0].fg,
            RgbColor {
                r: 174,
                g: 129,
                b: 255,
            }
        );
    }

    #[test]
    fn terminal_default_colors_resolve_prompt_palette_grid_snapshot() {
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 64,
            rows: 1,
            max_scrollback: 1000,
        })
        .unwrap();
        let default_colors = TerminalGridDefaultColors {
            foreground: Some(RgbColor {
                r: 253,
                g: 255,
                b: 241,
            }),
            background: Some(RgbColor {
                r: 39,
                g: 40,
                b: 34,
            }),
            palette: Some(terminal.default_color_palette().unwrap()),
        };
        apply_terminal_default_colors(&mut terminal, default_colors, 1);

        terminal.vt_write(
            b"\x1b[38;5;135mlawrence\x1b[00m in \x1b[38;5;118m~/fun/cmux-cli\x1b[00m on \x1b[38;5;81mmain\x1b[00m\x1b[38;5;166m \xce\xbb\x1b[00m ",
        );

        let snapshot = compositor::terminal_grid_snapshot(&terminal).unwrap();

        assert_eq!(
            snapshot.cells[0].fg,
            RgbColor {
                r: 175,
                g: 95,
                b: 255,
            }
        );
        assert_eq!(
            snapshot.cells[12].fg,
            RgbColor {
                r: 135,
                g: 255,
                b: 0,
            }
        );
        assert_eq!(
            snapshot.cells[30].fg,
            RgbColor {
                r: 95,
                g: 215,
                b: 255,
            }
        );
        assert_eq!(
            snapshot.cells[35].fg,
            RgbColor {
                r: 215,
                g: 95,
                b: 0,
            }
        );
    }

    #[test]
    fn libghostty_effects_emit_cursor_position_response() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let tx = std::sync::Arc::new(tx);
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 1000,
        })
        .unwrap();
        install_terminal_effects(
            &mut terminal,
            7,
            std::sync::Arc::downgrade(&tx),
            Rc::new(StdCell::new((80, 24))),
        )
        .unwrap();

        terminal.vt_write(b"\x1b[10;20H\x1b[6n");

        let PtyOp::TerminalResponse(response) = rx.try_recv().unwrap() else {
            panic!("unexpected PTY op");
        };
        assert_eq!(response.kind, TerminalResponseSource::Libghostty);
        assert_eq!(response.bytes, b"\x1b[10;20R");
    }

    #[test]
    fn libghostty_effects_emit_cursor_position_after_keyboard_protocol_query() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let tx = std::sync::Arc::new(tx);
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 1000,
        })
        .unwrap();
        install_terminal_effects(
            &mut terminal,
            7,
            std::sync::Arc::downgrade(&tx),
            Rc::new(StdCell::new((80, 24))),
        )
        .unwrap();

        terminal.vt_write(b"\x1b[>7u\x1b[?1004h\x1b[6n");

        let PtyOp::TerminalResponse(response) = rx.try_recv().unwrap() else {
            panic!("unexpected PTY op");
        };
        assert_eq!(response.kind, TerminalResponseSource::Libghostty);
        assert_eq!(response.bytes, b"\x1b[1;1R");
    }

    #[test]
    fn libghostty_effects_survive_terminal_storage_move() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let tx = std::sync::Arc::new(tx);
        let mut terminal = Box::new(
            Terminal::new(TerminalOptions {
                cols: 80,
                rows: 24,
                max_scrollback: 1000,
            })
            .unwrap(),
        );
        install_terminal_effects(
            &mut terminal,
            7,
            std::sync::Arc::downgrade(&tx),
            Rc::new(StdCell::new((80, 24))),
        )
        .unwrap();

        let mut terminals = HashMap::new();
        terminals.insert(7, terminal);
        terminals.get_mut(&7).unwrap().vt_write(b"\x1b[6n");

        let PtyOp::TerminalResponse(response) = rx.try_recv().unwrap() else {
            panic!("unexpected PTY op");
        };
        assert_eq!(response.kind, TerminalResponseSource::Libghostty);
        assert_eq!(response.bytes, b"\x1b[1;1R");
    }

    #[test]
    fn libghostty_effects_do_not_emit_osc_color_query_response() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let tx = std::sync::Arc::new(tx);
        let mut terminal = Terminal::new(TerminalOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 1000,
        })
        .unwrap();
        install_terminal_effects(
            &mut terminal,
            7,
            std::sync::Arc::downgrade(&tx),
            Rc::new(StdCell::new((80, 24))),
        )
        .unwrap();

        terminal.vt_write(b"\x1b]10;?\x1b\\");

        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn osc_color_response_formats_supplied_rgb_without_fixed_defaults() {
        let bytes = osc_color_response(
            10,
            GhosttyRgbColor {
                r: 1,
                g: 128,
                b: 255,
            },
        );

        assert_eq!(bytes, b"\x1b]10;rgb:0101/8080/ffff\x1b\\");
    }

    #[test]
    fn terminal_probe_response_requires_reported_client_colors() {
        assert_eq!(
            terminal_probe_response(TerminalProbeKind::DefaultForegroundColor, None),
            None
        );
        assert_eq!(
            terminal_probe_response(
                TerminalProbeKind::DefaultBackgroundColor,
                Some(TerminalProbeColors {
                    foreground: Some(GhosttyRgbColor { r: 1, g: 2, b: 3 }),
                    background: None,
                }),
            ),
            None
        );
    }

    #[test]
    fn terminal_probe_response_uses_reported_client_colors() {
        assert_eq!(
            terminal_probe_response(
                TerminalProbeKind::DefaultBackgroundColor,
                Some(TerminalProbeColors {
                    foreground: None,
                    background: Some(GhosttyRgbColor {
                        r: 30,
                        g: 31,
                        b: 32,
                    }),
                }),
            ),
            Some(b"\x1b]11;rgb:1e1e/1f1f/2020\x1b\\".to_vec())
        );
    }
}
