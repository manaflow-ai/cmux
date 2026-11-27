//! Kitty graphics on the App: tracking submissions, occlusion, the pane scene
//! key, emitting placements per frame, and committing or retrying graphics
//! processing results.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use cmux_tui_core::{Rect, SurfaceId, SurfaceKind};

use crate::app::graphics::{
    CachedGraphicsProjection, GraphicIdentity, GraphicsPaneSceneKey, GraphicsSceneContextKey,
    GraphicsSceneSourceKey, KittySceneSnapshotKey, bounding_rect,
};
use crate::app::layout::PaneArea;
use crate::app::pane_projection::browser_frame_source_crop;
use crate::app::pointer::PaneContentGeneration;
use crate::app::pointer::deferred::PointerRoutePhase;
use crate::app::{App, RenderAction, rects_intersect};
use crate::browser_input::{BrowserInputEvent, BrowserInputKind};
use crate::session::SurfaceHandle;
use crate::ui::graphics::{
    GraphicPlacement, GraphicSourceRect, kitty_graphic_image, kitty_graphic_placement,
};
use crate::ui::graphics_writer::{GraphicsCompletion, GraphicsProcessing, GraphicsWriter};

impl App {
    fn mark_graphics_clean(&self, dirty_surfaces: Option<&HashSet<SurfaceId>>) {
        let mut visited = HashSet::new();
        for area in &self.pane_areas {
            if dirty_surfaces.is_none_or(|dirty| dirty.contains(&area.surface))
                && visited.insert(area.surface)
                && let Some(surface) = self.session.surface(area.surface)
            {
                surface.take_dirty();
            }
        }
    }

    pub(super) fn track_graphics_submission(
        &mut self,
        submission: u64,
        snapshot: Vec<GraphicIdentity>,
    ) {
        let previous =
            self.pending_graphics_snapshot.as_deref().unwrap_or(&self.last_graphics_snapshot);
        if let Some(changed) = self.graphics_changed_rect_bound(previous, &snapshot) {
            self.pending_graphics_affected_rect = Some(
                self.pending_graphics_affected_rect
                    .map_or(changed, |affected| bounding_rect(affected, changed)),
            );
        }
        self.pending_graphics_submission = Some(submission);
        self.pending_graphics_snapshot = Some(snapshot);
    }

    fn graphic_occlusion_rects(&self) -> Vec<Rect> {
        let mut rects: Vec<Rect> = self
            .menu
            .as_ref()
            .map(|menu| menu.levels.iter().map(|level| level.rect).collect())
            .unwrap_or_default();
        rects.extend(self.prompt.as_ref().map(|prompt| prompt.rect));
        rects.extend(self.pairing_dialog.as_ref().map(|dialog| dialog.rect));
        rects.extend(self.shortcut_help.as_ref().map(|help| help.rect));
        rects.extend(crate::ui::toast_rect(self));
        rects
    }

    fn graphics_pane_scene_key(
        &self,
        area: PaneArea,
        surface: Option<&SurfaceHandle>,
    ) -> GraphicsPaneSceneKey {
        let (terminal_bounds, source) = match surface {
            None => (None, GraphicsSceneSourceKey::Unavailable),
            Some(surface) => match surface.kind() {
                SurfaceKind::Browser => (
                    None,
                    GraphicsSceneSourceKey::Browser { frame: surface.browser_frame_metadata() },
                ),
                SurfaceKind::Pty => {
                    let snapshot =
                        self.rendered_kitty_graphics.get(&area.surface).map(|snapshot| {
                            KittySceneSnapshotKey {
                                identity: Arc::as_ptr(snapshot) as usize,
                                generation: snapshot.generation,
                            }
                        });
                    (
                        self.rendered_terminal_bounds.get(&area.surface).copied(),
                        GraphicsSceneSourceKey::Pty { snapshot },
                    )
                }
            },
        };
        GraphicsPaneSceneKey {
            surface: area.surface,
            content: area.content,
            content_source_x: area.content_source_x(),
            full_content_width: area.content_size().0,
            terminal_bounds,
            source,
        }
    }

    pub(super) fn emit_graphics(&mut self) -> anyhow::Result<()> {
        self.emit_graphics_with_scope(false)
    }

    pub(super) fn emit_dirty_graphics(&mut self) -> anyhow::Result<()> {
        self.emit_graphics_with_scope(true)
    }

    fn emit_graphics_with_scope(&mut self, dirty_only: bool) -> anyhow::Result<()> {
        if !self.graphics_supported {
            return Ok(());
        }
        let dirty_surfaces = std::mem::take(&mut self.graphics_dirty_surfaces);
        let occluders = self.graphic_occlusion_rects();
        let context_changed = self.graphics_scene_cache.context.as_ref().is_none_or(|cached| {
            cached.session_generation != self.session_generation
                || cached.cell_pixels != self.cell_pixels
                || cached.occluders.as_slice() != occluders.as_slice()
        });
        let full_scan = !dirty_only || context_changed;
        self.mark_graphics_clean((!full_scan).then_some(&dirty_surfaces));
        let mut updates = Vec::new();
        for index in 0..self.pane_areas.len() {
            let area = self.pane_areas[index];
            if !full_scan && !dirty_surfaces.contains(&area.surface) {
                continue;
            }
            let surface = self.session.surface(area.surface);
            let key = self.graphics_pane_scene_key(area, surface.as_ref());
            let unchanged = !context_changed
                && self
                    .graphics_scene_cache
                    .projections
                    .get(&area.surface)
                    .is_some_and(|cached| cached.key == key);
            if unchanged {
                continue;
            }
            let placements =
                Arc::from(self.graphic_placements_for_area(area, surface.as_ref(), &occluders));
            updates.push((area.surface, key, placements));
        }

        let visible = full_scan.then(|| {
            self.pane_areas.iter().map(|area| area.surface).collect::<HashSet<SurfaceId>>()
        });
        let removed = visible.as_ref().is_some_and(|visible| {
            self.graphics_scene_cache.projections.keys().any(|surface| !visible.contains(surface))
        });
        let projection_changed = !updates.is_empty();
        if context_changed {
            self.graphics_scene_cache.context = Some(GraphicsSceneContextKey {
                session_generation: self.session_generation,
                cell_pixels: self.cell_pixels,
                occluders,
            });
            self.graphics_scene_cache.projections.clear();
        }
        if let Some(visible) = &visible {
            self.graphics_scene_cache.projections.retain(|surface, _| visible.contains(surface));
        }
        for (surface, key, placements) in updates {
            self.graphics_scene_cache
                .projections
                .insert(surface, CachedGraphicsProjection { key, placements });
            #[cfg(test)]
            {
                *self.graphics_scene_cache.projection_rebuilds.entry(surface).or_default() += 1;
            }
        }
        let scene_changed = context_changed || removed || projection_changed;
        #[cfg(test)]
        if scene_changed {
            self.graphics_scene_cache.rebuilds += 1;
        }
        let scene = self
            .pane_areas
            .iter()
            .filter_map(|area| {
                self.graphics_scene_cache
                    .projections
                    .get(&area.surface)
                    .map(|cached| cached.placements.clone())
            })
            .collect::<Vec<_>>();
        let snapshot = scene
            .iter()
            .flat_map(|placements| placements.iter())
            .filter(|placement| placement.is_browser_frame())
            .map(|placement| self.graphic_identity(placement))
            .collect::<Vec<_>>();
        let submitted_snapshot =
            self.pending_graphics_snapshot.as_ref().unwrap_or(&self.last_graphics_snapshot);
        if !scene_changed && &snapshot == submitted_snapshot {
            if self.pointer_route_phase == PointerRoutePhase::GraphicsRenderPending {
                self.pointer_route_phase = if self.pending_graphics_submission.is_some() {
                    PointerRoutePhase::GraphicsProcessingPending
                } else {
                    PointerRoutePhase::Fresh
                };
            }
            return Ok(());
        }
        let Some(writer) = &self.graphics_writer else {
            return Ok(());
        };
        self.next_graphics_submission = self.next_graphics_submission.wrapping_add(1).max(1);
        let submission = self.next_graphics_submission;
        if writer.submit_scene(submission, self.session_generation, scene) {
            self.track_graphics_submission(submission, snapshot);
            self.pointer_route_phase = PointerRoutePhase::GraphicsProcessingPending;
        }
        Ok(())
    }

    pub(super) fn graphic_identity(&self, placement: &GraphicPlacement) -> GraphicIdentity {
        GraphicIdentity {
            session_generation: placement.key.image.namespace,
            surface: placement.key.image.surface,
            rect: placement.rect,
            seq: placement.image.generation,
            pointer_frame_seq: placement.pointer_frame_seq,
        }
    }

    pub(super) fn graphic_placements_for_area(
        &self,
        area: PaneArea,
        surface: Option<&SurfaceHandle>,
        occluders: &[Rect],
    ) -> Vec<GraphicPlacement> {
        let mut placements = Vec::new();
        let Some(surface) = surface else { return placements };
        if area.content.width == 0 || area.content.height == 0 {
            return placements;
        }
        match surface.kind() {
            SurfaceKind::Browser => {
                if Self::graphic_occluded(area.content, occluders) {
                    return placements;
                }
                let Some(update) = surface.browser_frame_update() else { return placements };
                let frame = Arc::new(update.frame);
                let source = area.viewport.and_then(|clip| {
                    browser_frame_source_crop(
                        &frame,
                        clip.content_source_x,
                        area.content.width,
                        clip.full_content_width,
                    )
                    .map(|(x, width)| GraphicSourceRect {
                        x,
                        y: 0,
                        width,
                        height: frame.image_height,
                    })
                });
                placements.push(GraphicPlacement::browser_frame(
                    self.session_generation,
                    area.surface,
                    area.content,
                    frame,
                    update.pointer_frame_seq,
                    source,
                ));
            }
            SurfaceKind::Pty => {
                let Some(snapshot) = self.rendered_kitty_graphics.get(&area.surface) else {
                    return placements;
                };
                let pane = self
                    .rendered_terminal_bounds
                    .get(&area.surface)
                    .copied()
                    .unwrap_or(area.content);
                let images = snapshot
                    .images
                    .iter()
                    .map(|image| {
                        (
                            image.id,
                            kitty_graphic_image(self.session_generation, area.surface, image),
                        )
                    })
                    .collect::<HashMap<_, _>>();
                placements.extend(snapshot.placements.iter().filter_map(|placement| {
                    let image = images.get(&placement.image_id)?.clone();
                    let placement = kitty_graphic_placement(
                        pane,
                        area.content_source_x(),
                        self.cell_pixels,
                        image,
                        placement,
                    )?;
                    (!Self::graphic_occluded(placement.rect, occluders)).then_some(placement)
                }));
            }
        }
        placements
    }

    fn graphic_occluded(rect: Rect, occluders: &[Rect]) -> bool {
        occluders.iter().any(|occluder| rects_intersect(rect, *occluder))
    }

    pub(super) fn apply_graphics_completion(&mut self) -> RenderAction {
        let Some(completion) =
            self.graphics_writer.as_ref().and_then(GraphicsWriter::take_completion)
        else {
            return RenderAction::None;
        };
        match completion {
            GraphicsCompletion::Processed(processing) => {
                self.commit_graphics_processing(processing);
                RenderAction::None
            }
            GraphicsCompletion::TimedOut { id, session_generation } => {
                self.retry_graphics_after_timeout(id, session_generation)
            }
            GraphicsCompletion::Failed => self.disable_graphics_after_failure(),
        }
    }

    fn reset_unconfirmed_graphics(&mut self) {
        self.pending_graphics_submission = None;
        self.pending_graphics_snapshot = None;
        self.pending_graphics_affected_rect = None;
        self.last_graphics_snapshot.clear();
        self.graphics_scene_cache.invalidate();
        self.rendered_pane_content_generations
            .retain(|_, generation| !matches!(generation, PaneContentGeneration::Browser(_)));
        self.commit_rendered_pane_content_generations();
        self.pointer_route_phase = PointerRoutePhase::DrawPending;
    }

    pub(super) fn retry_graphics_after_timeout(
        &mut self,
        id: u64,
        session_generation: u64,
    ) -> RenderAction {
        if self.pending_graphics_submission != Some(id)
            || self.session_generation != session_generation
        {
            return RenderAction::None;
        }
        self.reset_unconfirmed_graphics();
        RenderAction::Draw
    }

    pub(super) fn disable_graphics_after_failure(&mut self) -> RenderAction {
        self.reset_unconfirmed_graphics();
        self.graphics_supported = false;
        if let Some(mut writer) = self.graphics_writer.take() {
            writer.shutdown(Duration::from_millis(200));
        }
        RenderAction::Draw
    }

    pub(super) fn commit_graphics_processing(&mut self, processing: GraphicsProcessing) {
        let settles_latest = self.pending_graphics_submission == Some(processing.id);
        let belongs_to_current_session = processing.session_generation == self.session_generation;
        let current_browser_authorities = belongs_to_current_session.then(|| {
            processing
                .graphics
                .iter()
                .filter(|graphic| {
                    self.session
                        .surface(graphic.surface)
                        .is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
                })
                .filter_map(|graphic| {
                    graphic.pointer_frame_seq.map(|authority| (graphic.surface, authority))
                })
                .collect::<Vec<_>>()
        });
        self.last_graphics_snapshot = processing
            .graphics
            .iter()
            .map(|graphic| GraphicIdentity {
                session_generation: processing.session_generation,
                surface: graphic.surface,
                rect: graphic.rect,
                seq: graphic.seq,
                pointer_frame_seq: graphic.pointer_frame_seq,
            })
            .collect();
        if settles_latest {
            self.pending_graphics_submission = None;
            self.pending_graphics_snapshot = None;
            self.pending_graphics_affected_rect = None;
        } else if let Some(pending) = self.pending_graphics_snapshot.as_deref() {
            self.pending_graphics_affected_rect =
                self.graphics_changed_rect_bound(&self.last_graphics_snapshot, pending);
        }
        if let Some(current_browser_authorities) = current_browser_authorities {
            self.rendered_pane_content_generations
                .retain(|_, generation| !matches!(generation, PaneContentGeneration::Browser(_)));
            for (surface, generation) in current_browser_authorities {
                if let Some(handle) = self.session.surface(surface)
                    && handle.browser_acknowledge_pointer_frame(generation)
                {
                    let _ = self.browser_input.enqueue(BrowserInputEvent {
                        surface_id: surface,
                        surface: handle,
                        kind: BrowserInputKind::Presented { frame_seq: generation },
                    });
                }
                self.rendered_pane_content_generations
                    .insert(surface, PaneContentGeneration::Browser(generation));
            }
            self.commit_rendered_pane_content_generations();
        }
        if settles_latest
            && self.pointer_route_phase == PointerRoutePhase::GraphicsProcessingPending
        {
            self.pointer_route_phase = PointerRoutePhase::Fresh;
        }
    }

    fn commit_rendered_pane_content_generations(&mut self) {
        if *self.rendered_pointer_frame.pane_content_generations
            != self.rendered_pane_content_generations
        {
            self.rendered_pointer_frame.pane_content_generations =
                Arc::new(self.rendered_pane_content_generations.clone());
        }
    }

    #[cfg(test)]
    pub(super) fn browser_graphic_occluded(&self, rect: Rect) -> bool {
        Self::graphic_occluded(rect, &self.graphic_occlusion_rects())
    }
}
