//! Pane-area projection: virtual and clipped pane rects, pane parts (tab bar,
//! header, content, scrollbar), the viewport pane-area projection, size
//! leases, and browser source crops.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::{BrowserFrame, PaneId, Rect, ScreenId, SurfaceId, SurfaceKind, VirtualRect};

use crate::app::layout::{PaneArea, PaneSizeLease, PaneViewportClip};
use crate::app::viewport::VIEWPORT_ANIMATION_SYNC_OPERATION_BUDGET;
#[cfg(test)]
use crate::app::viewport::record_pane_area_projection_work;
use crate::app::{pane_parts_for_rect, stacked_header_parts_for_rect};
use crate::config::ScrollbarPosition;
use crate::session::tree::{PaneView, ScreenView};

pub(super) fn clip_horizontal_rect(
    rect: VirtualRect,
    viewport_x: u64,
    viewport_width: u16,
    output_x: u16,
) -> Option<(Rect, u16)> {
    let left = rect.x.max(viewport_x);
    let right =
        rect.x.saturating_add(rect.width).min(viewport_x.saturating_add(u64::from(viewport_width)));
    if left >= right {
        return None;
    }
    let visible_width = u16::try_from(right - left).ok()?;
    let source_x = u16::try_from(left - rect.x).ok()?;
    Some((
        Rect {
            x: output_x.saturating_add(u16::try_from(left - viewport_x).ok()?),
            y: rect.y,
            width: visible_width,
            height: rect.height,
        },
        source_x,
    ))
}

pub(super) fn terminal_rect_from_virtual(rect: VirtualRect) -> Option<Rect> {
    Some(Rect {
        x: u16::try_from(rect.x).ok()?,
        y: rect.y,
        width: u16::try_from(rect.width).ok()?,
        height: rect.height,
    })
}

pub(super) fn virtualize_local_rect(parent_x: u64, rect: Rect) -> VirtualRect {
    VirtualRect {
        x: parent_x.saturating_add(u64::from(rect.x)),
        y: rect.y,
        width: u64::from(rect.width),
        height: rect.height,
    }
}

pub(super) type PaneParts<T> = (Option<T>, Option<T>, T, Option<T>);

pub(super) fn pane_parts_for_virtual_rect(
    rect: VirtualRect,
    scrollbar_position: ScrollbarPosition,
    pane_padding: u16,
    has_browser_omnibar: bool,
) -> Option<PaneParts<VirtualRect>> {
    let local =
        Rect { x: 0, y: rect.y, width: u16::try_from(rect.width).ok()?, height: rect.height };
    let (bar, omnibar, content, track) =
        pane_parts_for_rect(local, scrollbar_position, pane_padding, has_browser_omnibar);
    Some((
        bar.map(|part| virtualize_local_rect(rect.x, part)),
        omnibar.map(|part| virtualize_local_rect(rect.x, part)),
        virtualize_local_rect(rect.x, content),
        track.map(|part| virtualize_local_rect(rect.x, part)),
    ))
}

pub(super) fn stacked_header_parts_for_virtual_rect(
    rect: VirtualRect,
) -> Option<PaneParts<VirtualRect>> {
    let local =
        Rect { x: 0, y: rect.y, width: u16::try_from(rect.width).ok()?, height: rect.height };
    let (bar, omnibar, content, track) = stacked_header_parts_for_rect(local);
    Some((
        bar.map(|part| virtualize_local_rect(rect.x, part)),
        omnibar.map(|part| virtualize_local_rect(rect.x, part)),
        virtualize_local_rect(rect.x, content),
        track.map(|part| virtualize_local_rect(rect.x, part)),
    ))
}

pub(super) struct PaneAreaProjection<'a> {
    pub(super) screen: &'a ScreenView,
    pub(super) layout: &'a [(PaneId, VirtualRect)],
    pub(super) stacked_headers: &'a HashSet<PaneId>,
    pub(super) area: Rect,
    pub(super) scrollbar_position: ScrollbarPosition,
    pub(super) pane_padding: u16,
    pub(super) surface_only: Option<SurfaceId>,
    pub(super) viewport_offset: Option<u64>,
}

#[derive(Debug, Clone, Copy)]
pub(super) struct PaneAreaSource {
    layout_order: usize,
    pub(super) pane: PaneId,
    pub(super) surface: SurfaceId,
    full_rect: VirtualRect,
    full_bar: Option<VirtualRect>,
    full_omnibar: Option<VirtualRect>,
    full_content: VirtualRect,
    full_track: Option<VirtualRect>,
}

/// Cached immutable geometry for paint-only viewport animation frames.
///
/// `sync_layout` replaces this snapshot whenever authoritative tree, layout,
/// chrome, or terminal geometry changes. Animation frames only query it.
#[derive(Default)]
pub(super) struct ViewportPaneAreaProjection {
    pub(super) screen: Option<ScreenId>,
    pub(super) sources: Vec<PaneAreaSource>,
    pub(super) prefix_max_right: Vec<u64>,
}

pub(super) fn full_pane_parts_for_layout(
    pane: &PaneView,
    full_rect: VirtualRect,
    stacked_headers: &HashSet<PaneId>,
    scrollbar_position: ScrollbarPosition,
    pane_padding: u16,
    surface_only: Option<SurfaceId>,
) -> Option<(SurfaceId, PaneParts<VirtualRect>)> {
    let surface_id = pane.active_surface()?;
    let has_browser_omnibar =
        pane.tabs.get(pane.active_tab).is_some_and(|tab| tab.kind == SurfaceKind::Browser);
    let parts = if surface_only.is_some() {
        (None, None, full_rect, None)
    } else if stacked_headers.contains(&pane.id) {
        stacked_header_parts_for_virtual_rect(full_rect)?
    } else {
        pane_parts_for_virtual_rect(
            full_rect,
            scrollbar_position,
            pane_padding,
            has_browser_omnibar,
        )?
    };
    Some((surface_id, parts))
}

pub(super) fn pane_area_source(
    layout_order: usize,
    pane: &PaneView,
    full_rect: VirtualRect,
    stacked_headers: &HashSet<PaneId>,
    scrollbar_position: ScrollbarPosition,
    pane_padding: u16,
    surface_only: Option<SurfaceId>,
) -> Option<PaneAreaSource> {
    let (surface, (full_bar, full_omnibar, full_content, full_track)) = full_pane_parts_for_layout(
        pane,
        full_rect,
        stacked_headers,
        scrollbar_position,
        pane_padding,
        surface_only,
    )?;
    Some(PaneAreaSource {
        layout_order,
        pane: pane.id,
        surface,
        full_rect,
        full_bar,
        full_omnibar,
        full_content,
        full_track,
    })
}

impl ViewportPaneAreaProjection {
    pub(super) fn clear(&mut self) {
        self.screen = None;
        self.sources.clear();
        self.prefix_max_right.clear();
    }

    pub(super) fn is_for_screen(&self, screen: ScreenId) -> bool {
        self.screen == Some(screen)
    }

    pub(super) fn rebuild(&mut self, projection: PaneAreaProjection<'_>) {
        let PaneAreaProjection {
            screen,
            layout,
            stacked_headers,
            scrollbar_position,
            pane_padding,
            surface_only,
            ..
        } = projection;
        self.sources.clear();
        self.prefix_max_right.clear();
        self.screen = Some(screen.id);

        #[cfg(test)]
        record_pane_area_projection_work(screen.panes.len());
        let panes = screen.panes.iter().map(|pane| (pane.id, pane)).collect::<HashMap<_, _>>();
        self.sources.extend(layout.iter().enumerate().filter_map(
            |(layout_order, &(pane_id, full_rect))| {
                #[cfg(test)]
                record_pane_area_projection_work(1);
                if full_rect.width == 0 || full_rect.height == 0 {
                    return None;
                }
                pane_area_source(
                    layout_order,
                    panes.get(&pane_id).copied()?,
                    full_rect,
                    stacked_headers,
                    scrollbar_position,
                    pane_padding,
                    surface_only,
                )
            },
        ));
        self.sources.sort_unstable_by_key(|source| (source.full_rect.x, source.layout_order));

        let mut maximum_right = 0;
        self.prefix_max_right.reserve(self.sources.len());
        for source in &self.sources {
            maximum_right =
                maximum_right.max(source.full_rect.x.saturating_add(source.full_rect.width));
            self.prefix_max_right.push(maximum_right);
        }
    }

    pub(super) fn project_into(
        &self,
        pane_areas: &mut Vec<PaneArea>,
        area: Rect,
        viewport_offset: u64,
    ) {
        pane_areas.clear();
        let viewport_x = u64::from(area.x).saturating_add(viewport_offset);
        let viewport_right = viewport_x.saturating_add(u64::from(area.width));
        let start = self.prefix_max_right.partition_point(|right| *right <= viewport_x);
        let end = self.sources.partition_point(|source| source.full_rect.x < viewport_right);
        if start >= end {
            return;
        }
        for &source in &self.sources[start..end] {
            #[cfg(test)]
            record_pane_area_projection_work(1);
            if let Some(projected) = project_pane_area(source, area, Some(viewport_offset)) {
                pane_areas.push(projected);
            }
        }
    }
}

pub(super) fn swept_viewport_size_leases(
    projection: PaneAreaProjection<'_>,
    target_offset: u64,
) -> Option<Vec<PaneSizeLease>> {
    let PaneAreaProjection {
        screen,
        layout,
        stacked_headers,
        area,
        scrollbar_position,
        pane_padding,
        surface_only,
        viewport_offset,
    } = projection;
    let current_offset = viewport_offset.unwrap_or(0);
    let swept_left = u64::from(area.x).saturating_add(current_offset.min(target_offset));
    let swept_right = u64::from(area.x)
        .saturating_add(current_offset.max(target_offset))
        .saturating_add(u64::from(area.width));
    let panes = screen.panes.iter().map(|pane| (pane.id, pane)).collect::<HashMap<_, _>>();
    let mut operation_cost = 0usize;
    let mut leases = Vec::new();
    for &(pane_id, full_rect) in layout {
        let Some(pane) = panes.get(&pane_id).copied() else { continue };
        let Some((surface, (_, _, content, _))) = full_pane_parts_for_layout(
            pane,
            full_rect,
            stacked_headers,
            scrollbar_position,
            pane_padding,
            surface_only,
        ) else {
            continue;
        };
        let content_right = content.x.saturating_add(content.width);
        if content.height == 0
            || content.width == 0
            || content.x >= swept_right
            || content_right <= swept_left
        {
            continue;
        }
        // One possible attach per tab and one resize for the active surface.
        operation_cost = operation_cost.saturating_add(pane.tabs.len().saturating_add(1));
        if operation_cost > VIEWPORT_ANIMATION_SYNC_OPERATION_BUDGET {
            return None;
        }
        leases.push(PaneSizeLease {
            pane: pane_id,
            surface,
            content_size: (u16::try_from(content.width).unwrap_or(u16::MAX), content.height),
        });
    }
    Some(leases)
}

pub(super) fn visible_pane_size_leases(pane_areas: &[PaneArea]) -> Vec<PaneSizeLease> {
    pane_areas
        .iter()
        .filter(|area| area.content.width > 0 && area.content.height > 0)
        .map(|area| PaneSizeLease {
            pane: area.pane,
            surface: area.surface,
            content_size: area.content_size(),
        })
        .collect()
}

pub(super) fn project_pane_area(
    source: PaneAreaSource,
    area: Rect,
    viewport_offset: Option<u64>,
) -> Option<PaneArea> {
    let PaneAreaSource {
        pane,
        surface,
        full_rect,
        full_bar,
        full_omnibar,
        full_content,
        full_track,
        ..
    } = source;
    let viewport_x = viewport_offset.map(|offset| u64::from(area.x).saturating_add(offset));
    let (rect, rect_source_x, bar, omnibar, omnibar_source_x, content, content_source_x, track) =
        if let Some(viewport_x) = viewport_x {
            let (rect, rect_source_x) =
                clip_horizontal_rect(full_rect, viewport_x, area.width, area.x)?;
            let bar = full_bar.and_then(|rect| {
                clip_horizontal_rect(rect, viewport_x, area.width, area.x).map(|(rect, _)| rect)
            });
            let (omnibar, omnibar_source_x) = full_omnibar
                .and_then(|rect| clip_horizontal_rect(rect, viewport_x, area.width, area.x))
                .map_or((None, 0), |(rect, source_x)| (Some(rect), source_x));
            let (content, content_source_x) =
                clip_horizontal_rect(full_content, viewport_x, area.width, area.x).unwrap_or((
                    Rect { x: rect.x, y: full_content.y, width: 0, height: full_content.height },
                    0,
                ));
            let track = full_track.and_then(|rect| {
                clip_horizontal_rect(rect, viewport_x, area.width, area.x).map(|(rect, _)| rect)
            });
            (rect, rect_source_x, bar, omnibar, omnibar_source_x, content, content_source_x, track)
        } else {
            let rect = terminal_rect_from_virtual(full_rect)?;
            let bar = full_bar.and_then(terminal_rect_from_virtual);
            let omnibar = full_omnibar.and_then(terminal_rect_from_virtual);
            let content = terminal_rect_from_virtual(full_content)?;
            let track = full_track.and_then(terminal_rect_from_virtual);
            (rect, 0, bar, omnibar, 0, content, 0, track)
        };
    let pane_viewport = viewport_x
        .is_some()
        .then_some(PaneViewportClip {
            rect_source_x,
            full_rect_width: u16::try_from(full_rect.width).unwrap_or(u16::MAX),
            omnibar_source_x,
            full_omnibar_width: full_omnibar
                .and_then(|rect| u16::try_from(rect.width).ok())
                .unwrap_or(0),
            content_source_x,
            full_content_width: u16::try_from(full_content.width).unwrap_or(u16::MAX),
        })
        .filter(|clip| clip.rect_source_x > 0 || rect.width < clip.full_rect_width);
    Some(PaneArea { pane, surface, rect, bar, omnibar, content, track, viewport: pane_viewport })
}

pub(super) fn rebuild_pane_areas(
    pane_areas: &mut Vec<PaneArea>,
    projection: PaneAreaProjection<'_>,
) {
    let PaneAreaProjection {
        screen,
        layout,
        stacked_headers,
        area,
        scrollbar_position,
        pane_padding,
        surface_only,
        viewport_offset,
    } = projection;
    pane_areas.clear();
    #[cfg(test)]
    record_pane_area_projection_work(screen.panes.len());
    let panes = screen.panes.iter().map(|pane| (pane.id, pane)).collect::<HashMap<_, _>>();
    for (layout_order, &(pane_id, full_rect)) in layout.iter().enumerate() {
        #[cfg(test)]
        record_pane_area_projection_work(1);
        let Some(pane) = panes.get(&pane_id).copied() else { continue };
        let Some(source) = pane_area_source(
            layout_order,
            pane,
            full_rect,
            stacked_headers,
            scrollbar_position,
            pane_padding,
            surface_only,
        ) else {
            continue;
        };
        if let Some(projected) = project_pane_area(source, area, viewport_offset) {
            pane_areas.push(projected);
        }
    }
}

pub(super) fn browser_source_crop(
    frame_width: u32,
    source_column: u16,
    visible_columns: u16,
    full_columns: u16,
) -> Option<(u32, u32)> {
    if frame_width == 0 || visible_columns == 0 || full_columns == 0 {
        return None;
    }
    let frame_width = u64::from(frame_width);
    let full_columns = u64::from(full_columns);
    let source_column = u64::from(source_column).min(full_columns);
    let end_column = source_column.saturating_add(u64::from(visible_columns)).min(full_columns);
    if source_column >= end_column {
        return None;
    }
    let source_x = source_column.saturating_mul(frame_width) / full_columns;
    let source_end = end_column.saturating_mul(frame_width).div_ceil(full_columns).min(frame_width);
    let source_x = source_x.min(frame_width.saturating_sub(1));
    Some((source_x as u32, source_end.saturating_sub(source_x).max(1) as u32))
}

pub(super) fn browser_frame_source_crop(
    frame: &BrowserFrame,
    source_column: u16,
    visible_columns: u16,
    full_columns: u16,
) -> Option<(u32, u32)> {
    browser_source_crop(frame.image_width, source_column, visible_columns, full_columns)
}
