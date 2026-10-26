//! The client's copy of the remote screen, RGBA, row-major.

use crate::error::{Result, VncError};

/// Largest framebuffer side this client accepts (a hostile size would
/// otherwise allocate without bound).
pub const MAX_SIDE: u16 = 16384;

/// A rectangle in framebuffer pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

impl Rect {
    pub fn new(x: u16, y: u16, width: u16, height: u16) -> Self {
        Self { x, y, width, height }
    }

    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }

    /// The smallest rectangle that holds both.
    pub fn union(&self, other: &Rect) -> Rect {
        if self.is_empty() {
            return *other;
        }
        if other.is_empty() {
            return *self;
        }
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = (u32::from(self.x) + u32::from(self.width))
            .max(u32::from(other.x) + u32::from(other.width));
        let y1 = (u32::from(self.y) + u32::from(self.height))
            .max(u32::from(other.y) + u32::from(other.height));
        Rect::new(x0, y0, (x1 - u32::from(x0)) as u16, (y1 - u32::from(y0)) as u16)
    }
}

/// RGBA pixels of the remote screen.
#[derive(Debug, Clone)]
pub struct Framebuffer {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
}

impl Framebuffer {
    pub fn new(width: u16, height: u16) -> Result<Self> {
        check_size(width, height)?;
        Ok(Self { width, height, pixels: black(usize::from(width) * usize::from(height)) })
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    /// RGBA bytes, `width * height * 4`.
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    /// Resizes to a new size, black (servers repaint after a resize).
    pub fn resize(&mut self, width: u16, height: u16) -> Result<()> {
        check_size(width, height)?;
        self.width = width;
        self.height = height;
        self.pixels = black(usize::from(width) * usize::from(height));
        Ok(())
    }

    /// Fails unless `rect` lies inside the framebuffer.
    pub fn check(&self, rect: &Rect) -> Result<()> {
        let fits = u32::from(rect.x) + u32::from(rect.width) <= u32::from(self.width)
            && u32::from(rect.y) + u32::from(rect.height) <= u32::from(self.height);
        if fits {
            Ok(())
        } else {
            Err(VncError::protocol(format!(
                "rectangle {rect:?} outside the {}x{} framebuffer",
                self.width, self.height
            )))
        }
    }

    fn offset(&self, x: u16, y: u16) -> usize {
        (usize::from(y) * usize::from(self.width) + usize::from(x)) * 4
    }

    /// Fills `rect` (already checked) with one color.
    pub fn fill(&mut self, rect: &Rect, rgba: [u8; 4]) {
        for row in 0..rect.height {
            let start = self.offset(rect.x, rect.y + row);
            let end = start + usize::from(rect.width) * 4;
            for pixel in self.pixels[start..end].chunks_exact_mut(4) {
                pixel.copy_from_slice(&rgba);
            }
        }
    }

    /// Writes RGBA rows (`rect.width * 4` bytes each) into `rect` (already checked).
    pub fn put(&mut self, rect: &Rect, rgba: &[u8]) {
        let stride = usize::from(rect.width) * 4;
        for (row, line) in rgba.chunks_exact(stride).take(usize::from(rect.height)).enumerate() {
            let start = self.offset(rect.x, rect.y + row as u16);
            self.pixels[start..start + stride].copy_from_slice(line);
        }
    }

    /// Copies the `rect`-sized area at (`src_x`, `src_y`) to `rect`; both
    /// already checked. Overlap is handled (scrolling moves overlap).
    pub fn copy(&mut self, src_x: u16, src_y: u16, rect: &Rect) {
        let stride = usize::from(rect.width) * 4;
        let mut area = Vec::with_capacity(stride * usize::from(rect.height));
        for row in 0..rect.height {
            let start = self.offset(src_x, src_y + row);
            area.extend_from_slice(&self.pixels[start..start + stride]);
        }
        self.put(rect, &area);
    }
}

fn check_size(width: u16, height: u16) -> Result<()> {
    if width > MAX_SIDE || height > MAX_SIDE {
        return Err(VncError::protocol(format!("framebuffer of {width}x{height}")));
    }
    Ok(())
}

fn black(pixels: usize) -> Vec<u8> {
    let mut buf = vec![0; pixels * 4];
    for pixel in buf.chunks_exact_mut(4) {
        pixel[3] = 255;
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlapping_copy_scrolls_up() {
        let mut fb = Framebuffer::new(1, 3).unwrap();
        fb.fill(&Rect::new(0, 0, 1, 1), [1, 0, 0, 255]);
        fb.fill(&Rect::new(0, 1, 1, 1), [2, 0, 0, 255]);
        fb.fill(&Rect::new(0, 2, 1, 1), [3, 0, 0, 255]);
        fb.copy(0, 1, &Rect::new(0, 0, 1, 2));
        assert_eq!(fb.pixels()[0], 2);
        assert_eq!(fb.pixels()[4], 3);
        assert_eq!(fb.pixels()[8], 3);
    }

    #[test]
    fn rectangles_outside_are_refused() {
        let fb = Framebuffer::new(10, 10).unwrap();
        assert!(fb.check(&Rect::new(5, 5, 5, 5)).is_ok());
        assert!(fb.check(&Rect::new(5, 5, 6, 5)).is_err());
        assert!(fb.check(&Rect::new(u16::MAX, 0, 2, 1)).is_err());
        assert!(Framebuffer::new(MAX_SIDE + 1, 1).is_err());
    }

    #[test]
    fn union_covers_both() {
        let a = Rect::new(0, 0, 2, 2);
        let b = Rect::new(5, 6, 1, 1);
        assert_eq!(a.union(&b), Rect::new(0, 0, 6, 7));
        assert_eq!(Rect::default().union(&b), b);
    }
}
