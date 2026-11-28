//! The frame record: display intervals while flinging, the scene's own build time per frame, and late textures.
//! Samples are capped so a scene left open for hours stays bounded.

/// At most this many samples of each kind are kept (the oldest half is dropped when full).
pub const MAX_SAMPLES: usize = 1 << 16;
/// An interval over this (1.5 refresh periods at 120 Hz) is a missed frame.
pub const MISSED_MS: f64 = 8.333_333 * 1.5;

#[derive(Clone, Debug, Default)]
pub struct Record {
    pub frames: u64,
    pub late_texture_frames: u64,
    pub late_textures: u64,
    pub intervals_missed: u64,
    intervals_ms: Vec<f64>,
    build_us: Vec<f64>,
    last_flinging_now: Option<f64>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Summary {
    pub p50: f64,
    pub p95: f64,
    pub max: f64,
}

fn push_capped(v: &mut Vec<f64>, x: f64) {
    if v.len() >= MAX_SAMPLES {
        v.drain(..MAX_SAMPLES / 2);
    }
    v.push(x);
}

/// Nearest-rank percentiles of the samples (all zero when empty).
pub fn summarize(samples: &[f64]) -> Summary {
    if samples.is_empty() {
        return Summary::default();
    }
    let mut s = samples.to_vec();
    s.sort_by(f64::total_cmp);
    let rank = |p: f64| s[(((p * s.len() as f64).ceil() as usize).max(1) - 1).min(s.len() - 1)];
    Summary { p50: rank(0.50), p95: rank(0.95), max: s[s.len() - 1] }
}

impl Record {
    /// One frame at `now` (seconds): `flinging` when the frame moved under a fling, `late` rich rows on screen
    /// without a texture, `build_us` the scene's own time.
    pub fn frame(&mut self, now: f64, flinging: bool, late: u32, build_us: f64) {
        self.frames += 1;
        if late > 0 {
            self.late_texture_frames += 1;
            self.late_textures += u64::from(late);
        }
        push_capped(&mut self.build_us, build_us);
        if flinging {
            if let Some(prev) = self.last_flinging_now {
                let ms = (now - prev) * 1000.0;
                if ms > 0.0 {
                    if ms > MISSED_MS {
                        self.intervals_missed += 1;
                    }
                    push_capped(&mut self.intervals_ms, ms);
                }
            }
            self.last_flinging_now = Some(now);
        } else {
            self.last_flinging_now = None;
        }
    }

    pub fn intervals(&self) -> Summary {
        summarize(&self.intervals_ms)
    }

    pub fn build(&self) -> Summary {
        summarize(&self.build_us)
    }
}
