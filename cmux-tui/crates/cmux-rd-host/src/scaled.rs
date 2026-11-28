//! The bench viewer's half of cap `video.scaled` (the resolution ladder, design D5): the host
//! may encode a picture smaller than the stream, and a viewer shows it scaled up to the
//! stream's size. The bench reads the marker, the quality region and the snapshot in stream
//! pixels, from the picture scaled up the way a viewer shows it (bilinear), so a run with the
//! ladder measures what a person sees, not the smaller picture.

/// Maps stream pixels onto one decoded picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scale {
    picture: (usize, usize),
    stream: (usize, usize),
}

impl Scale {
    /// A picture of `picture` pixels shown at `stream` pixels.
    pub fn new(picture: (usize, usize), stream: (usize, usize)) -> Self {
        Self { picture, stream }
    }

    /// The picture is the full stream: read it directly.
    pub fn is_identity(&self) -> bool {
        self.picture == self.stream
    }

    /// The picture coordinate under the centre of stream pixel `i` along one axis.
    fn source(i: usize, picture: usize, stream: usize) -> f64 {
        let at = (i as f64 + 0.5) * picture as f64 / stream.max(1) as f64 - 0.5;
        at.clamp(0.0, picture.saturating_sub(1) as f64)
    }

    /// The value at stream pixel (`x`, `y`) of a plane of `channels` interleaved bytes per
    /// pixel, `stride` bytes per row; `None` outside the plane.
    fn at(
        &self,
        plane: &[u8],
        stride: usize,
        channels: usize,
        x: usize,
        y: usize,
        c: usize,
    ) -> Option<u8> {
        let (sx, sy) = (
            Self::source(x, self.picture.0, self.stream.0),
            Self::source(y, self.picture.1, self.stream.1),
        );
        let (x0, y0) = (sx.floor() as usize, sy.floor() as usize);
        let (x1, y1) = (
            (x0 + 1).min(self.picture.0.saturating_sub(1)),
            (y0 + 1).min(self.picture.1.saturating_sub(1)),
        );
        let (fx, fy) = (sx - x0 as f64, sy - y0 as f64);
        let get = |px: usize, py: usize| -> Option<f64> {
            plane.get(py * stride + px * channels + c).map(|&v| f64::from(v))
        };
        let top = get(x0, y0)? * (1.0 - fx) + get(x1, y0)? * fx;
        let bottom = get(x0, y1)? * (1.0 - fx) + get(x1, y1)? * fx;
        Some((top * (1.0 - fy) + bottom * fy).round() as u8)
    }

    /// One luma sample at stream pixel (`x`, `y`).
    pub fn luma(&self, plane: &[u8], stride: usize, x: usize, y: usize) -> Option<u8> {
        self.at(plane, stride, 1, x, y, 0)
    }

    /// The luma of the stream rectangle (`x`, `y`, `width`, `height`), row by row.
    pub fn luma_rect(
        &self,
        plane: &[u8],
        stride: usize,
        (x, y, width, height): (usize, usize, usize, usize),
    ) -> Option<Vec<u8>> {
        if x + width > self.stream.0 || y + height > self.stream.1 {
            return None;
        }
        (y..y + height)
            .flat_map(|row| (x..x + width).map(move |col| (col, row)))
            .map(|(col, row)| self.luma(plane, stride, col, row))
            .collect()
    }

    /// A packed RGB picture scaled up to the stream: (width, height, pixels).
    pub fn rgb(&self, rgb: &[u8]) -> (usize, usize, Vec<u8>) {
        let (w, h) = self.stream;
        let stride = self.picture.0 * 3;
        let mut out = Vec::with_capacity(w * h * 3);
        for y in 0..h {
            for x in 0..w {
                for c in 0..3 {
                    out.push(self.at(rgb, stride, 3, x, y, c).unwrap_or(0));
                }
            }
        }
        (w, h, out)
    }
}

#[cfg(test)]
#[path = "scaled_tests.rs"]
mod tests;
