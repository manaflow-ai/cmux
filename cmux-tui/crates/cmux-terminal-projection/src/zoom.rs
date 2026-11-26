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
mod tests {
    use super::*;

    /// A 120x40 Mac pane at 12 pt (7.2 x 15.6 pt cells) on a 378 x 600 pt page.
    fn mac() -> ZoomGeometry {
        ZoomGeometry {
            grid_width: 120.0 * 7.2,
            grid_height: 40.0 * 15.6,
            page_width: 378.0,
            page_height: 600.0,
        }
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    #[test]
    fn fit_width_shows_the_whole_width_and_never_enlarges_a_narrow_grid() {
        let g = mac();
        assert!(close(g.fit_width_scale(), 378.0 / 864.0));
        let fitted = g.initial();
        assert!(close(fitted.scale * g.grid_width, g.page_width));
        assert_eq!((fitted.pan_x, fitted.pan_y), (0.0, 0.0));
        let narrow = ZoomGeometry { grid_width: 40.0 * 7.2, ..g };
        assert!(close(narrow.fit_width_scale(), 1.0));
        assert_eq!(narrow.stop(narrow.initial().scale), ZoomStop::FitWidth);
    }

    #[test]
    fn a_pinch_snaps_to_the_stops_and_stays_in_bounds() {
        let g = mac();
        let fit = g.fit_width_scale();
        assert!(close(g.snap(fit * 1.1), fit));
        assert!(close(g.snap(0.9), 1.0));
        assert!(close(g.snap(1.12), 1.0));
        assert!(close(g.snap(0.7), 0.7), "between the stops it stays");
        assert!(close(g.snap(0.01), fit), "never smaller than fit width");
        assert!(close(g.snap(9.0), MAX_SCALE));
        assert!(close(g.snap(f64::NAN), fit));
    }

    #[test]
    fn a_double_tap_toggles_about_the_tapped_point() {
        let g = mac();
        let fitted = g.initial();
        // Tap column 60, row 1 at fit width (row 1 so the vertical pan is inside the 24 pt the
        // readable grid overhangs the page).
        let s = fitted.scale;
        let (fx, fy) = (60.0 * 7.2 * s, 1.0 * 15.6 * s);
        let readable = g.toggle(fitted, fx, fy);
        assert!(close(readable.scale, 1.0));
        // The tapped cell is still under the finger.
        assert!(close(readable.pan_x + fx, 60.0 * 7.2));
        assert!(close(readable.pan_y + fy, 1.0 * 15.6));
        let back = g.toggle(readable, fx, fy);
        assert!(close(back.scale, g.fit_width_scale()));
        assert_eq!(
            (back.pan_x, back.pan_y),
            (0.0, 0.0),
            "fit width shows the whole grid from the top"
        );
        // Zoomed past readable: a double tap goes to fit width.
        let past = g.zoom_about(readable, 1.8, 10.0, 10.0);
        assert!(close(g.toggle(past, 0.0, 0.0).scale, g.fit_width_scale()));
    }

    #[test]
    fn the_pan_keeps_the_grid_on_the_page() {
        let g = mac();
        let wild = g.clamp(ZoomState { scale: 1.0, pan_x: 5000.0, pan_y: -40.0 });
        assert!(close(wild.pan_x, 864.0 - 378.0));
        assert!(close(wild.pan_y, 0.0));
        let low = g.clamp(ZoomState { scale: 1.0, pan_x: 10.0, pan_y: 9999.0 });
        assert!(close(low.pan_y, 624.0 - 600.0));
        // Smaller than the page vertically: pinned to the top.
        let small = g.clamp(ZoomState { scale: g.fit_width_scale(), pan_x: 30.0, pan_y: 30.0 });
        assert_eq!((small.pan_x, small.pan_y), (0.0, 0.0));
        let nan = g.clamp(ZoomState { scale: 1.0, pan_x: f64::NAN, pan_y: f64::INFINITY });
        assert_eq!((nan.pan_x, nan.pan_y), (0.0, 0.0));
    }

    #[test]
    fn typing_reveals_the_cursor_moving_as_little_as_it_can() {
        let g = mac();
        let start = ZoomState { scale: 1.0, pan_x: 0.0, pan_y: 0.0 };
        // Cursor at column 100: pans right just enough, with a margin.
        let next = g.reveal(start, 100.0 * 7.2, 0.0, 7.2, 15.6, 28.8);
        assert!(close(next.pan_x, 101.0 * 7.2 + 28.8 - 378.0));
        // Already visible: no move.
        assert_eq!(g.reveal(next, 90.0 * 7.2, 0.0, 7.2, 15.6, 28.8), next);
        // Row 39 below the page: pans down to it.
        let low = g.reveal(start, 0.0, 39.0 * 15.6, 7.2, 15.6, 0.0);
        assert!(close(low.pan_y, 624.0 - 600.0));
    }
}
