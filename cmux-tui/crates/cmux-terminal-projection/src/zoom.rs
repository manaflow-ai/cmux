//! The scaled projection of a full-screen app: the host's exact grid on the
//! phone, zoomed and panned locally, never resized (docs/design
//! ios-terminal-projection.md, option C).
//!
//! The phone draws the host's grid at the reader's font size (scale 1,
//! "readable") and scales it. Pinching snaps to two stops: **fit width** (the
//! whole width of the grid on the page, as small as that takes) and
//! **readable**. A double tap goes from one to the other, about the tapped
//! point. Past readable a pinch goes up to [`MAX_SCALE`]; below fit width it
//! stops at fit width. The pan is in page points and keeps the grid on the
//! page. Pure geometry: the phone applies it as a transform, so a zoom or a
//! pan is one frame and sends nothing to the host.

/// The largest zoom past readable.
pub const MAX_SCALE: f64 = 2.0;

/// A pinch that ends this close to a stop (as a fraction of the stop) lands on it.
pub const SNAP: f64 = 0.15;

/// The grid and the page, in points at scale 1.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ZoomGeometry {
    pub grid_width: f64,
    pub grid_height: f64,
    pub page_width: f64,
    pub page_height: f64,
}

/// A zoom and a pan: the grid's top-left is at `(-pan_x, -pan_y)` on the page,
/// drawn at `scale`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ZoomState {
    pub scale: f64,
    pub pan_x: f64,
    pub pan_y: f64,
}

/// The two stops.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ZoomStop {
    FitWidth,
    Readable,
    /// Between or past the stops.
    Free,
}

impl ZoomGeometry {
    /// The scale that shows the grid's whole width (at most readable: a grid
    /// narrower than the page is never blown up).
    pub fn fit_width_scale(&self) -> f64 {
        if self.grid_width <= 0.0 || self.page_width <= 0.0 {
            return 1.0;
        }
        (self.page_width / self.grid_width).min(1.0)
    }

    pub fn clamp_scale(&self, scale: f64) -> f64 {
        let low = self.fit_width_scale();
        if scale.is_finite() { scale.clamp(low, MAX_SCALE.max(low)) } else { low }
    }

    /// Where a pinch that ended at `scale` settles.
    pub fn snap(&self, scale: f64) -> f64 {
        let scale = self.clamp_scale(scale);
        let fit = self.fit_width_scale();
        if (scale - fit).abs() <= fit * SNAP {
            fit
        } else if (scale - 1.0).abs() <= SNAP {
            1.0
        } else {
            scale
        }
    }

    pub fn stop(&self, scale: f64) -> ZoomStop {
        let fit = self.fit_width_scale();
        if (scale - fit).abs() < 1e-6 {
            ZoomStop::FitWidth
        } else if (scale - 1.0).abs() < 1e-6 {
            ZoomStop::Readable
        } else {
            ZoomStop::Free
        }
    }

    /// The pan kept inside the grid: no gap at the right or bottom while the
    /// scaled grid is larger than the page; pinned to the top-left where it
    /// is smaller (the rows below are letterboxed).
    pub fn clamp(&self, state: ZoomState) -> ZoomState {
        let scale = self.clamp_scale(state.scale);
        let max_x = (self.grid_width * scale - self.page_width).max(0.0);
        let max_y = (self.grid_height * scale - self.page_height).max(0.0);
        let clamp = |v: f64, max: f64| if v.is_finite() { v.clamp(0.0, max) } else { 0.0 };
        ZoomState { scale, pan_x: clamp(state.pan_x, max_x), pan_y: clamp(state.pan_y, max_y) }
    }

    /// `state` zoomed to `scale` keeping the grid point under `focus` (page
    /// points) under it.
    pub fn zoom_about(
        &self,
        state: ZoomState,
        scale: f64,
        focus_x: f64,
        focus_y: f64,
    ) -> ZoomState {
        let from = if state.scale > 0.0 { state.scale } else { 1.0 };
        let to = self.clamp_scale(scale);
        let grid_x = (state.pan_x + focus_x) / from;
        let grid_y = (state.pan_y + focus_y) / from;
        self.clamp(ZoomState {
            scale: to,
            pan_x: grid_x * to - focus_x,
            pan_y: grid_y * to - focus_y,
        })
    }

    /// A double tap at `focus`: readable from fit width (or from anything
    /// below readable), fit width from readable or above.
    pub fn toggle(&self, state: ZoomState, focus_x: f64, focus_y: f64) -> ZoomState {
        let fit = self.fit_width_scale();
        let target = if state.scale < 1.0 - 1e-6 { 1.0 } else { fit };
        self.zoom_about(state, target, focus_x, focus_y)
    }

    /// The pan that shows grid point `(x, y)` (scale-1 points) with `margin`
    /// page points around it, moving as little as it can (typing follows the
    /// cursor).
    pub fn reveal(
        &self,
        state: ZoomState,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        margin: f64,
    ) -> ZoomState {
        let s = state.scale;
        let (left, top, right, bottom) = (x * s, y * s, (x + width) * s, (y + height) * s);
        let mut next = state;
        if left - margin < next.pan_x {
            next.pan_x = left - margin;
        } else if right + margin > next.pan_x + self.page_width {
            next.pan_x = right + margin - self.page_width;
        }
        if top < next.pan_y {
            next.pan_y = top;
        } else if bottom > next.pan_y + self.page_height {
            next.pan_y = bottom - self.page_height;
        }
        self.clamp(next)
    }

    /// The opening zoom for a grid: fit width.
    pub fn initial(&self) -> ZoomState {
        self.clamp(ZoomState { scale: self.fit_width_scale(), pan_x: 0.0, pan_y: 0.0 })
    }
}

#[cfg(test)]
#[path = "zoom_tests.rs"]
mod tests;
