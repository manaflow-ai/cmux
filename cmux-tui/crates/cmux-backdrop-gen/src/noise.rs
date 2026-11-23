//! Seeded randomness: a SplitMix64 stream for placing things, and hashed value noise for fields.
//! Integer hashing only, so a seed draws the same picture on every machine.

/// A SplitMix64 stream: small, fast and fully determined by its seed.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed ^ 0x5DEE_CE66_D1CE_4E5B)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in 0..1.
    pub fn unit(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }

    /// Uniform in lo..hi.
    pub fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.unit()
    }

    /// A phase, 0..2π.
    pub fn angle(&mut self) -> f32 {
        self.range(0.0, std::f32::consts::TAU)
    }

    /// One of `items`, or None when it is empty.
    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        let index = (self.unit() * items.len() as f32) as usize;
        items.get(index.min(items.len().saturating_sub(1)))
    }
}

/// A hash of a lattice point to 0..1.
pub fn hash2(x: i32, y: i32, seed: u64) -> f32 {
    let mut h = (x as u32 as u64).wrapping_mul(0x9E37_79B1)
        ^ (y as u32 as u64).wrapping_mul(0x85EB_CA77).rotate_left(17)
        ^ seed.wrapping_mul(0xC2B2_AE3D_27D4_EB4F);
    h ^= h >> 33;
    h = h.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
    h ^= h >> 33;
    h = h.wrapping_mul(0xC4CE_B9FE_1A85_EC53);
    h ^= h >> 33;
    (h >> 40) as f32 / (1u64 << 24) as f32
}

/// Smooth value noise in 0..1.
pub fn value(x: f32, y: f32, seed: u64) -> f32 {
    let (fx, fy) = (x.floor(), y.floor());
    let (ix, iy) = (fx as i32, fy as i32);
    let (tx, ty) = (x - fx, y - fy);
    let (ux, uy) = (
        tx * tx * tx * (tx * (tx * 6.0 - 15.0) + 10.0),
        ty * ty * ty * (ty * (ty * 6.0 - 15.0) + 10.0),
    );
    let a = hash2(ix, iy, seed);
    let b = hash2(ix.wrapping_add(1), iy, seed);
    let c = hash2(ix, iy.wrapping_add(1), seed);
    let d = hash2(ix.wrapping_add(1), iy.wrapping_add(1), seed);
    let top = a + (b - a) * ux;
    let bottom = c + (d - c) * ux;
    top + (bottom - top) * uy
}

/// Fractal value noise in 0..1: `octaves` layers, each twice the frequency and half the weight.
pub fn fbm(x: f32, y: f32, seed: u64, octaves: u32) -> f32 {
    let (mut sum, mut weight, mut total) = (0.0, 0.5, 0.0);
    let (mut px, mut py) = (x, y);
    for octave in 0..octaves {
        sum +=
            weight * value(px, py, seed.wrapping_add(u64::from(octave).wrapping_mul(0x632B_E59B)));
        total += weight;
        // A rotation between octaves hides the lattice's grid.
        let (rx, ry) = (1.6 * px - 1.2 * py, 1.2 * px + 1.6 * py);
        px = rx + 3.1;
        py = ry - 1.7;
        weight *= 0.5;
    }
    if total > 0.0 { sum / total } else { 0.0 }
}
