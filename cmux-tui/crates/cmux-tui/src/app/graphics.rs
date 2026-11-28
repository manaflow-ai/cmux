//! Kitty graphics identity and routing: graphic identity and layout keys, the
//! route index, and the graphics scene cache keys.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use cmux_tui_core::{Rect, SurfaceId};

use crate::app::App;
use crate::ui::graphics::GraphicPlacement;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct GraphicIdentity {
    pub(super) session_generation: u64,
    pub(super) surface: SurfaceId,
    pub(super) rect: Rect,
    pub(super) seq: u64,
    pub(super) pointer_frame_seq: Option<u64>,
}

impl GraphicIdentity {
    pub(super) fn same_pointer_layout(self, other: Self) -> bool {
        self.session_generation == other.session_generation
            && self.surface == other.surface
            && self.rect == other.rect
    }

    fn layout_key(self) -> GraphicLayoutKey {
        GraphicLayoutKey {
            session_generation: self.session_generation,
            surface: self.surface,
            x: self.rect.x,
            y: self.rect.y,
            width: self.rect.width,
            height: self.rect.height,
        }
    }

    fn route_key(self) -> GraphicRouteKey {
        GraphicRouteKey { layout: self.layout_key(), pointer_frame_seq: self.pointer_frame_seq }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) struct GraphicLayoutKey {
    pub(super) session_generation: u64,
    pub(super) surface: SurfaceId,
    pub(super) x: u16,
    pub(super) y: u16,
    pub(super) width: u16,
    pub(super) height: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(super) struct GraphicRouteKey {
    pub(super) layout: GraphicLayoutKey,
    pub(super) pointer_frame_seq: Option<u64>,
}

pub(super) struct GraphicRouteIndex {
    pub(super) routes: HashMap<GraphicRouteKey, bool>,
    pub(super) routed_layouts: HashSet<GraphicLayoutKey>,
}

pub(super) const GRAPHICS_ROUTE_INDEX_FAST_PATH_LIMIT: usize = 8;

impl GraphicRouteIndex {
    pub(super) fn build(app: &App, graphics: &[GraphicIdentity]) -> Self {
        let mut routes = HashMap::with_capacity(graphics.len());
        let mut routed_layouts = HashSet::with_capacity(graphics.len());
        for &graphic in graphics {
            let route_key = graphic.route_key();
            let route_valid = graphic.pointer_frame_seq.is_some_and(|frame_seq| {
                app.session.surface(graphic.surface).is_some_and(|surface| {
                    surface.browser_pointer_frame_is_in_current_route(frame_seq)
                })
            });
            routes
                .entry(route_key)
                .and_modify(|existing| *existing |= route_valid)
                .or_insert(route_valid);
            if route_valid {
                routed_layouts.insert(route_key.layout);
            }
        }
        Self { routes, routed_layouts }
    }

    pub(super) fn has_match(&self, graphic: GraphicIdentity, other: &Self) -> bool {
        let route_key = graphic.route_key();
        if other.routes.contains_key(&route_key) {
            return true;
        }
        graphic.pointer_frame_seq.is_some()
            && self.routes.get(&route_key).copied().unwrap_or(false)
            && other.routed_layouts.contains(&route_key.layout)
    }
}

pub(super) fn bounding_rect(first: Rect, second: Rect) -> Rect {
    let left = first.x.min(second.x);
    let top = first.y.min(second.y);
    let right = first.x.saturating_add(first.width).max(second.x.saturating_add(second.width));
    let bottom = first.y.saturating_add(first.height).max(second.y.saturating_add(second.height));
    Rect { x: left, y: top, width: right.saturating_sub(left), height: bottom.saturating_sub(top) }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct KittySceneSnapshotKey {
    pub(super) identity: usize,
    pub(super) generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum GraphicsSceneSourceKey {
    Unavailable,
    Browser { frame: Option<(u64, u32, u32, Option<u64>)> },
    Pty { snapshot: Option<KittySceneSnapshotKey> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct GraphicsPaneSceneKey {
    pub(super) surface: SurfaceId,
    pub(super) content: Rect,
    pub(super) content_source_x: u16,
    pub(super) full_content_width: u16,
    pub(super) terminal_bounds: Option<Rect>,
    pub(super) source: GraphicsSceneSourceKey,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct GraphicsSceneContextKey {
    pub(super) session_generation: u64,
    pub(super) cell_pixels: (u16, u16),
    pub(super) occluders: Vec<Rect>,
}

pub(super) struct CachedGraphicsProjection {
    pub(super) key: GraphicsPaneSceneKey,
    pub(super) placements: Arc<[GraphicPlacement]>,
}

#[derive(Default)]
pub(super) struct GraphicsSceneCache {
    pub(super) context: Option<GraphicsSceneContextKey>,
    pub(super) projections: HashMap<SurfaceId, CachedGraphicsProjection>,
    #[cfg(test)]
    pub(super) rebuilds: usize,
    #[cfg(test)]
    pub(super) projection_rebuilds: HashMap<SurfaceId, usize>,
}

impl GraphicsSceneCache {
    pub(super) fn invalidate(&mut self) {
        self.context = None;
        self.projections.clear();
    }
}
