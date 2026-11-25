//! A linear-light RGB canvas and the colour math every layer shares.

/// A colour in linear light, each channel 0...1 (a glow may go past 1 until the final encode).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rgb {
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

impl Rgb {
    pub const WHITE: Rgb = Rgb { r: 1.0, g: 1.0, b: 1.0 };

    pub const fn new(r: f32, g: f32, b: f32) -> Self {
        Rgb { r, g, b }
    }

    /// An sRGB `0xRRGGBB` colour, converted to linear light.
    pub fn hex(rgb: u32) -> Self {
        let channel = |shift: u32| srgb_to_linear(((rgb >> shift) & 0xFF) as f32 / 255.0);
        Rgb::new(channel(16), channel(8), channel(0))
    }

    pub fn mix(self, other: Rgb, t: f32) -> Rgb {
        Rgb::new(lerp(self.r, other.r, t), lerp(self.g, other.g, t), lerp(self.b, other.b, t))
    }

    pub fn scale(self, k: f32) -> Rgb {
        Rgb::new(self.r * k, self.g * k, self.b * k)
    }

    pub fn plus(self, other: Rgb) -> Rgb {
        Rgb::new(self.r + other.r, self.g + other.g, self.b + other.b)
    }

    pub fn times(self, other: Rgb) -> Rgb {
        Rgb::new(self.r * other.r, self.g * other.g, self.b * other.b)
    }

    /// Screen blend of `light` at strength `t`: brightens without ever passing white.
    pub fn screen(self, light: Rgb, t: f32) -> Rgb {
        let s = |a: f32, b: f32| 1.0 - (1.0 - a.min(1.0)) * (1.0 - (b * t).min(1.0));
        Rgb::new(s(self.r, light.r), s(self.g, light.g), s(self.b, light.b))
    }

    pub fn luminance(self) -> f32 {
        0.2126 * self.r + 0.7152 * self.g + 0.0722 * self.b
    }
}

pub fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

pub fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

pub fn srgb_to_linear(c: f32) -> f32 {
    if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
}

pub fn linear_to_srgb(c: f32) -> f32 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.003_130_8 { c * 12.92 } else { 1.055 * c.powf(1.0 / 2.4) - 0.055 }
}

/// A gradient through `stops` (position 0...1, colour), positions ascending.
pub fn gradient(stops: &[(f32, Rgb)], t: f32) -> Rgb {
    let mut previous: Option<(f32, Rgb)> = None;
    for &(at, color) in stops {
        if t <= at {
            return match previous {
                Some((from, before)) if at > from => {
                    before.mix(color, smoothstep(0.0, 1.0, (t - from) / (at - from)))
                }
                _ => color,
            };
        }
        previous = Some((at, color));
    }
    previous.map_or(Rgb::default(), |(_, color)| color)
}

/// The picture being built: `width` × `height` linear-light pixels, rows top to bottom.
#[derive(Clone, Debug, PartialEq)]
pub struct Canvas {
    pub width: usize,
    pub height: usize,
    pixels: Vec<Rgb>,
}

impl Canvas {
    /// A black canvas; a zero side is taken as one pixel.
    pub fn new(width: usize, height: usize) -> Self {
        let (width, height) = (width.max(1), height.max(1));
        Canvas { width, height, pixels: vec![Rgb::default(); width.saturating_mul(height)] }
    }

    /// The short side in pixels: the unit every layer measures in, so a picture keeps its
    /// composition at any size.
    pub fn unit(&self) -> f32 {
        self.width.min(self.height) as f32
    }

    /// The pixel at (x, y), clamped to the edges.
    pub fn at(&self, x: usize, y: usize) -> Rgb {
        let x = x.min(self.width.saturating_sub(1));
        let y = y.min(self.height.saturating_sub(1));
        self.pixels.get(y.saturating_mul(self.width).saturating_add(x)).copied().unwrap_or_default()
    }

    /// Bilinear sample at pixel coordinates (centres at +0.5), clamped to the edges.
    pub fn sample(&self, x: f32, y: f32) -> Rgb {
        let fx = (x - 0.5).clamp(0.0, (self.width - 1) as f32);
        let fy = (y - 0.5).clamp(0.0, (self.height - 1) as f32);
        let (x0, y0) = (fx.floor() as usize, fy.floor() as usize);
        let (tx, ty) = (fx - fx.floor(), fy - fy.floor());
        let top = self.at(x0, y0).mix(self.at(x0.saturating_add(1), y0), tx);
        let bottom = self
            .at(x0, y0.saturating_add(1))
            .mix(self.at(x0.saturating_add(1), y0.saturating_add(1)), tx);
        top.mix(bottom, ty)
    }

    /// Repaints every pixel: `f(x, y, current)` with x, y at the pixel's centre.
    pub fn shade(&mut self, f: impl Fn(f32, f32, Rgb) -> Rgb) {
        let (width, height) = (self.width, self.height);
        self.shade_rect(0, 0, width, height, f);
    }

    /// Repaints the pixels in columns `x0..x1`, rows `y0..y1` (clamped to the canvas).
    pub fn shade_rect(
        &mut self,
        x0: usize,
        y0: usize,
        x1: usize,
        y1: usize,
        f: impl Fn(f32, f32, Rgb) -> Rgb,
    ) {
        let (x1, y1) = (x1.min(self.width), y1.min(self.height));
        if x0 >= x1 || y0 >= y1 {
            return;
        }
        for (dy, row) in self.pixels.chunks_exact_mut(self.width).skip(y0).take(y1 - y0).enumerate()
        {
            let y = (y0 + dy) as f32 + 0.5;
            if let Some(span) = row.get_mut(x0..x1) {
                for (dx, pixel) in span.iter_mut().enumerate() {
                    *pixel = f((x0 + dx) as f32 + 0.5, y, *pixel);
                }
            }
        }
    }

    /// The pixels as 8-bit sRGB, rows top to bottom, with a seeded half-step dither so the
    /// long soft gradients never band.
    pub fn to_srgb8(&self, seed: u64) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.pixels.len().saturating_mul(3));
        for (y, row) in self.pixels.chunks_exact(self.width).enumerate() {
            for (x, pixel) in row.iter().enumerate() {
                let n = crate::noise::hash2(x as i32, y as i32, seed);
                for (i, c) in [pixel.r, pixel.g, pixel.b].into_iter().enumerate() {
                    let dither =
                        crate::noise::hash2(x as i32 ^ (i as i32 * 7919), y as i32, seed ^ 0x9E37)
                            + n
                            - 1.0;
                    out.push(
                        (linear_to_srgb(c) * 255.0 + 0.5 + dither * 0.5).clamp(0.0, 255.0) as u8
                    );
                }
            }
        }
        out
    }
}
