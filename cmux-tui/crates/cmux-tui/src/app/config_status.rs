//! Config reload and status line upkeep: cell pixel refresh, config reload,
//! the status command worker and segment resolution, sidebar files sync, and
//! the window title.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crate::app::layout::{FocusTarget, RailKind};
use crate::app::overlays::ShortcutHelp;
use crate::app::status_segments::{
    ResolvedStatusSegments, StatusSegmentView, StatusSegmentWorker, StatusTemplateValues,
    StatusWorkerStop, cached_status_user, expand_status_tokens, run_status_segment_loop,
};
use crate::app::{App, publishes_global_cell_metrics};
use crate::config::{SidebarColumnKind, SidebarView};

impl App {
    pub(super) fn refresh_cell_pixels(&mut self) {
        let next = crate::ui::graphics::detect_cell_pixels(Some(self.cell_pixels));
        let changed = self.cell_pixels != next;
        if changed {
            if !self.prepare_pty_input_before_mutation() {
                return;
            }
            self.cell_pixels = next;
            self.browser_input.clear_resize_failures();
        }
        // Repeat unchanged measurements too. The mux publishes a new global
        // default only after every surface converges, so this reconciles a
        // transient failure or an acknowledgement that timed out after the
        // authoritative host committed.
        if publishes_global_cell_metrics(self.surface_only) {
            self.session.set_cell_pixel_size(next.0, next.1);
        }
    }

    pub(super) fn reload_config(&mut self) {
        #[cfg(test)]
        {
            self.config_reload_applications += 1;
        }
        let focused_projection_id = match self.focus {
            FocusTarget::ProjectionRail(index) => {
                self.config.sidebar.views.get(index).map(|view| view.id.clone())
            }
            _ => None,
        };
        let mut config = crate::config::load();
        config.apply_chrome_defaults(self.chrome);
        let shortcut_rows = self
            .shortcut_help
            .as_ref()
            .map(|_| ShortcutHelp::resolved_rows(&config, self.surface_only.is_some()));
        self.sidebar_plugin_error = None;
        self.sidebar_plugin_retry_after_ms = None;
        self.sidebar_plugin_retry_at = None;
        self.session.apply_config(config.clone());
        self.sidebar_view = config.sidebar.view;
        self.config = config;
        let valid_view_ids =
            self.config.sidebar.views.iter().map(|view| view.id.clone()).collect::<HashSet<_>>();
        self.projection_rails.retain(|id, _| valid_view_ids.contains(id));
        self.projection_sidebar_width_overrides.retain(|id, _| valid_view_ids.contains(id));
        if let Some(id) = focused_projection_id {
            if let Some((index, view)) =
                self.config.sidebar.views.iter().enumerate().find(|(_, view)| view.id == id)
            {
                let kind =
                    view.legacy_kind().map_or(RailKind::Projection(index), |kind| match kind {
                        SidebarColumnKind::Machines => RailKind::Machine,
                        SidebarColumnKind::Workspaces => RailKind::Workspace,
                        SidebarColumnKind::Tabs => RailKind::Tabs,
                    });
                self.focus_rail(kind);
            } else {
                self.focus = FocusTarget::Pane;
            }
        }
        if let (Some(help), Some(rows)) = (self.shortcut_help.as_mut(), shortcut_rows) {
            help.rows = rows;
            help.scroll_offset = help.scroll_offset.min(help.max_scroll(help.rows.len()));
        }
        self.sidebar_followed_surface = None;
        self.ensure_status_command_worker();
    }

    /// Stop any running status command worker and start a new one when the
    /// visible status bar has command segments. Called at startup and after
    /// every config reload.
    pub(super) fn ensure_status_command_worker(&mut self) {
        if let Some(stop) = self.status_command_worker_stop.take() {
            stop.raise();
        }
        // Stopped workers observe the flag at every capture poll tick, so
        // they exit within milliseconds. Keep their handles and enforce a
        // hard bound anyway, so even a reload storm cannot stack live
        // worker generations; a join past the bound is bounded by that same
        // poll tick.
        const MAX_RETIRING_STATUS_WORKERS: usize = 32;
        self.retiring_status_workers.append(&mut self.status_command_workers);
        self.retiring_status_workers.retain(|handle| !handle.is_finished());
        while self.retiring_status_workers.len() > MAX_RETIRING_STATUS_WORKERS {
            let handle = self.retiring_status_workers.remove(0);
            let _ = handle.join();
        }
        // A fresh map per generation: a stopped worker mid-command can only
        // write into its own orphaned map, never under an index that now
        // belongs to a different segment.
        self.status_command_outputs = Arc::new(Mutex::new(HashMap::new()));
        self.status_outputs_generation = Arc::new(AtomicU64::new(1));
        self.status_poke_pending = Arc::new(AtomicBool::new(false));
        self.status_segments_cache = None;
        if !self.config.status_bar.visible || self.is_surface_only() {
            return;
        }
        let commands = self.config.status_bar.command_segments();
        if commands.is_empty() {
            return;
        }
        let stop = Arc::new(StatusWorkerStop::new());
        for (index, argv, interval) in commands {
            let outputs = self.status_command_outputs.clone();
            let generation = self.status_outputs_generation.clone();
            let poke = self.status_poke_pending.clone();
            let events = self.app_events.clone();
            let worker_stop = stop.clone();
            match std::thread::Builder::new().name(format!("status-segment-{index}")).spawn(
                move || {
                    run_status_segment_loop(StatusSegmentWorker {
                        index,
                        argv,
                        interval,
                        outputs,
                        generation,
                        poke,
                        events,
                        stop: worker_stop,
                    });
                },
            ) {
                Ok(handle) => self.status_command_workers.push(handle),
                Err(error) => {
                    crate::client_log::stderr_log!(
                        "status-segment",
                        "{BIN}: could not start a status segment worker: {error}"
                    );
                }
            }
        }
        self.status_command_worker_stop = Some(stop);
    }

    /// Resolve the configured status segments to displayable text: literal
    /// segments expand `{variable}`s, command segments read the worker's
    /// latest output. The resolved result is cached against a fingerprint
    /// of every expansion input, so an ordinary draw reuses the previous
    /// strings instead of re-expanding templates.
    pub(crate) fn resolved_status_segments(&mut self) -> Arc<ResolvedStatusSegments> {
        static EMPTY: std::sync::OnceLock<Arc<ResolvedStatusSegments>> = std::sync::OnceLock::new();
        if self.config.status_bar.left.is_empty() && self.config.status_bar.right.is_empty() {
            return EMPTY.get_or_init(|| Arc::new((Vec::new(), Vec::new()))).clone();
        }
        let fingerprint = self.status_segments_fingerprint();
        if self.status_segments_cache.as_ref().map(|(cached, _)| *cached) != Some(fingerprint) {
            let resolved = Arc::new(self.resolve_status_segments_now());
            self.status_segments_cache = Some((fingerprint, resolved));
        }
        self.status_segments_cache
            .as_ref()
            .map(|(_, resolved)| Arc::clone(resolved))
            .unwrap_or_else(|| EMPTY.get_or_init(|| Arc::new((Vec::new(), Vec::new()))).clone())
    }

    /// Allocation-free hash of every input `resolve_status_segments_now`
    /// reads: command outputs (via the workers' change counter) plus the
    /// interpolated session, workspace, screen, and title values. The
    /// frequently-changing tab title participates only when a configured
    /// template actually uses `{title}`, so ordinary title churn does not
    /// rebuild fixed segments.
    fn status_segments_fingerprint(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        self.status_outputs_generation.load(Ordering::Acquire).hash(&mut hasher);
        self.session_label.hash(&mut hasher);
        if let Some(workspace) = self.tree.active_workspace() {
            workspace.name.hash(&mut hasher);
            workspace.screens.len().hash(&mut hasher);
            workspace.active_screen.hash(&mut hasher);
            if let Some(screen) = workspace.screens.get(workspace.active_screen) {
                screen.name.hash(&mut hasher);
            }
        }
        if self.status_templates_use("{title}")
            && let Some(tab) = self
                .tree
                .active_screen()
                .and_then(|screen| screen.pane(screen.active_pane))
                .and_then(|pane| pane.tabs.get(pane.active_tab))
        {
            tab.name.hash(&mut hasher);
            tab.title.hash(&mut hasher);
        }
        hasher.finish()
    }

    /// Whether any configured literal status segment contains `token`.
    fn status_templates_use(&self, token: &str) -> bool {
        self.config.status_bar.left.iter().chain(self.config.status_bar.right.iter()).any(
            |segment| match &segment.content {
                crate::config::StatusSegmentContent::Text(template) => template.contains(token),
                crate::config::StatusSegmentContent::Command { .. } => false,
            },
        )
    }

    fn resolve_status_segments_now(&self) -> ResolvedStatusSegments {
        let outputs = self.status_command_outputs.lock().unwrap();
        let mut index = 0usize;
        let mut resolve = |segments: &[crate::config::StatusSegment]| {
            segments
                .iter()
                .map(|segment| {
                    let text = match &segment.content {
                        crate::config::StatusSegmentContent::Text(template) => {
                            self.expand_status_template(template)
                        }
                        crate::config::StatusSegmentContent::Command { .. } => {
                            outputs.get(&index).cloned().unwrap_or_default()
                        }
                    };
                    index += 1;
                    StatusSegmentView { text, fg: segment.fg, bg: segment.bg }
                })
                .collect::<Vec<_>>()
        };
        let left = resolve(&self.config.status_bar.left);
        let right = resolve(&self.config.status_bar.right);
        (left, right)
    }

    /// `{session}`, `{workspace}`, `{screen}`, `{screens}`, `{title}`, and
    /// `{user}`. Unknown braces stay literal.
    fn expand_status_template(&self, template: &str) -> String {
        if !template.contains('{') {
            return template.to_string();
        }
        let workspace = self.tree.active_workspace();
        let workspace_name = workspace.map(|ws| ws.name.clone()).unwrap_or_default();
        let screens = workspace.map(|ws| ws.screens.len()).unwrap_or(0).to_string();
        let screen_name = workspace
            .and_then(|ws| {
                ws.screens.get(ws.active_screen).map(|screen| screen.display_name(ws.active_screen))
            })
            .unwrap_or_default();
        let title = self
            .tree
            .active_screen()
            .and_then(|screen| screen.pane(screen.active_pane))
            .and_then(|pane| pane.tabs.get(pane.active_tab))
            .map(|tab| tab.name.clone().unwrap_or_else(|| tab.title.clone()))
            .unwrap_or_default();
        expand_status_tokens(
            template,
            &StatusTemplateValues {
                session: &self.session_label,
                workspace: &workspace_name,
                screen: &screen_name,
                screens: &screens,
                title: &title,
                user: cached_status_user(),
            },
        )
    }

    pub(super) fn focused_surface_cwd(&self) -> Option<PathBuf> {
        let surface = self.tree.active_surface()?;
        self.session.surface_cwd(surface).map(PathBuf::from)
    }

    pub(super) fn sync_sidebar_files_to_focus(&mut self, force: bool) -> bool {
        if self.config.sidebar.plugin.is_some()
            || self.sidebar_view != SidebarView::Files
            || self.sidebar_files.is_pinned()
        {
            return false;
        }
        let focused = self.tree.active_surface();
        if !force && focused == self.sidebar_followed_surface {
            return false;
        }
        self.sidebar_followed_surface = focused;
        let Some(cwd) = self.focused_surface_cwd() else { return false };
        self.sidebar_files.follow_focused_cwd(&cwd)
    }

    pub(super) fn tick_sidebar_files(&mut self) -> bool {
        if self.config.sidebar.plugin.is_some()
            || self.sidebar_view != SidebarView::Files
            || !self.sidebar_visible
        {
            return false;
        }
        // The cwd follow can be a synchronous socket round-trip for remote
        // sessions; the event loop ticks up to ~33x/sec, so gate it behind the
        // same 2s refresh cadence as the directory reload.
        let now = Instant::now();
        let mut changed = false;
        if self.sidebar_files.refresh_due(now)
            && !self.sidebar_files.is_pinned()
            && let Some(cwd) = self.focused_surface_cwd()
        {
            changed |= self.sidebar_files.follow_focused_cwd(&cwd);
        }
        changed | self.sidebar_files.tick(now)
    }

    pub(super) fn write_window_title(&self, title: &str) -> anyhow::Result<()> {
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock();
        lock.recover_stream_locked()?;
        self.ensure_graphics_writer_healthy()?;
        let mut stdout = std::io::stdout();
        stdout.write_all(&cmux_tui_core::server::window_title_osc(title))?;
        stdout.flush()?;
        Ok(())
    }
}
