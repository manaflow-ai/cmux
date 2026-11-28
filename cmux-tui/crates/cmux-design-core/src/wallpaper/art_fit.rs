//! How the desktop's own picture fits a screen (Swift `BackdropArtFit`), read from the desktop
//! store's `imageScaling` and `allowClipping` options.

use super::placement::{Rect, Size};
use serde::{Deserialize, Serialize};

/// The desktop picture's scaling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ArtFit {
    #[default]
    Fill,
    Fit,
    Stretch,
    Center,
}

impl ArtFit {
    /// The store's options: 1 stretch, 2 center, 0 fit, 3 fill (fit when clipping is off).
    pub fn from_options(image_scaling: Option<i64>, allow_clipping: Option<bool>) -> Self {
        match image_scaling {
            Some(1) => Self::Stretch,
            Some(2) => Self::Center,
            Some(0) => Self::Fit,
            Some(3) if allow_clipping == Some(false) => Self::Fit,
            _ => Self::Fill,
        }
    }

    /// Whether the fill color shows around the picture.
    pub fn shows_fill(self) -> bool {
        matches!(self, Self::Fit | Self::Center)
    }

    /// Where the picture is drawn in `bounds`, centered; nil without area. A centered picture is
    /// drawn at `points_per_pixel` (1 when not positive and finite).
    pub fn rect(self, image: Size, bounds: Rect, points_per_pixel: f64) -> Option<Rect> {
        if !(image.width > 0.0 && image.height > 0.0 && bounds.width > 0.0 && bounds.height > 0.0) {
            return None;
        }
        let (width, height) = match self {
            Self::Stretch => return Some(bounds),
            Self::Fill | Self::Fit => {
                let sx = bounds.width / image.width;
                let sy = bounds.height / image.height;
                let scale = if self == Self::Fill { sx.max(sy) } else { sx.min(sy) };
                (image.width * scale, image.height * scale)
            }
            Self::Center => {
                let scale = if points_per_pixel > 0.0 && points_per_pixel.is_finite() {
                    points_per_pixel
                } else {
                    1.0
                };
                (image.width * scale, image.height * scale)
            }
        };
        Some(Rect {
            x: bounds.mid_x() - width / 2.0,
            y: bounds.mid_y() - height / 2.0,
            width,
            height,
        })
    }
}
