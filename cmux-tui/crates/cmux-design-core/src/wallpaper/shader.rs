//! The built-in shader wallpapers (Swift `BackdropShader`) and the shader view's clock (Swift
//! `BackdropShaderView.advance`, `framesPerSecond`, `ring`): Float math, as the view keeps it.

use serde::{Deserialize, Serialize};

/// The shaders in the picker's order, with the clock time each starts at.
pub const SHADERS: [(&str, f32); 12] = [
    ("currents", 42.0),
    ("ripples", 17.0),
    ("aurora", 63.0),
    ("field", 9.0),
    ("aero", 63.0),
    ("sakura", 31.0),
    ("sumi", 24.0),
    ("koi", 12.0),
    ("snowfall", 40.0),
    ("lanterns", 55.0),
    ("rain", 20.0),
    ("matrix", 21.0),
];

/// A shader picture id's prefix.
pub const ID_PREFIX: &str = "shader:";
/// The shaders' picker collection.
pub const COLLECTION: &str = "shaders";
/// `BackdropShaderSource.version`: posters of an older source are not reused.
pub const SOURCE_VERSION: u32 = 2;

/// One shader's names.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shader {
    pub raw: String,
    pub id: String,
    pub fragment_name: String,
    pub start_time: f32,
}

fn shader(raw: &str, start_time: f32) -> Shader {
    Shader {
        raw: raw.to_string(),
        id: format!("{ID_PREFIX}{raw}"),
        fragment_name: format!("wp_{raw}"),
        start_time,
    }
}

/// Every shader, in order.
pub fn all() -> Vec<Shader> {
    SHADERS.iter().map(|&(raw, start)| shader(raw, start)).collect()
}

/// The shader a raw name names.
pub fn named(raw: &str) -> Option<Shader> {
    SHADERS.iter().find(|s| s.0 == raw).map(|&(raw, start)| shader(raw, start))
}

/// The shader a picture id (`shader:NAME`) names.
pub fn from_id(id: &str) -> Option<Shader> {
    named(id.strip_prefix(ID_PREFIX)?)
}

/// A poster's file name: `NAME-dark|light-vVERSION.png`.
pub fn poster_name(raw: &str, dark: bool) -> String {
    format!("{raw}-{}-v{SOURCE_VERSION}.png", if dark { "dark" } else { "light" })
}

/// The shader and appearance of a poster's file name (in the poster folder); nil for another.
pub fn poster(file_name: &str) -> Option<(Shader, bool)> {
    let stem = match file_name.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem,
        _ => file_name,
    };
    let parts: Vec<&str> = stem.split('-').filter(|p| !p.is_empty()).collect();
    if parts.len() != 3 {
        return None;
    }
    Some((named(parts[0])?, parts[1] == "dark"))
}

/// The most frames a second.
pub const MAXIMUM_FPS: f64 = 60.0;
/// The frames a second while nothing answers the pointer.
pub const CALM_FPS: f64 = 30.0;
/// The most frames a second while the Mac is warm.
pub const WARM_FPS: f64 = 30.0;
/// Energy under which the pointer no longer moves anything visibly.
pub const CALM_ENERGY: f32 = 0.01;
/// Seconds a click's ring lives.
pub const RING_SECONDS: f32 = 5.0;
/// Seconds the clock takes to ease up to speed after a resume.
pub const RESUME_RAMP_SECONDS: f64 = 2.5;

/// The shader view's clock and pointer state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clock {
    #[serde(default)]
    pub time: f32,
    /// The real pointer in drawable pixels.
    #[serde(default)]
    pub pointer: [f32; 2],
    /// The shown pointer, easing toward the real one.
    #[serde(default)]
    pub mouse: [f32; 2],
    #[serde(default)]
    pub energy: f32,
    /// Each ring: x, y, start time, live (1) or not (0).
    #[serde(default)]
    pub rings: [[f32; 4]; 4],
    #[serde(default)]
    pub next_ring: usize,
    /// The last real pointer in view points.
    #[serde(default)]
    pub last_pointer: Option<[f64; 2]>,
    /// Seconds since the motion resumed; none for long ago.
    #[serde(default)]
    pub since_resumed: Option<f64>,
}

/// What one display frame sees.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub elapsed: f64,
    /// The real pointer in view points, if the view has a window.
    #[serde(default)]
    pub pointer: Option<[f64; 2]>,
    /// Drawable pixels per point on each axis.
    #[serde(default = "unit_scale")]
    pub scale: [f64; 2],
    /// The drawable's size in pixels.
    #[serde(default)]
    pub pixel_size: [f64; 2],
}

fn unit_scale() -> [f64; 2] {
    [1.0, 1.0]
}

impl Clock {
    /// `resumePace(over:)`: the clock's mean speed over the next `elapsed` seconds of a resume.
    fn resume_pace(&mut self, elapsed: f64) -> f64 {
        let Some(since) = self.since_resumed.filter(|s| *s < RESUME_RAMP_SECONDS) else {
            return 1.0;
        };
        let pace = |t: f64| {
            let x = (t / RESUME_RAMP_SECONDS).clamp(0.0, 1.0);
            x * x * (3.0 - 2.0 * x)
        };
        let start = pace(since);
        let since = since + elapsed;
        self.since_resumed = Some(since);
        (start + pace(since)) / 2.0
    }

    /// The motion starts again: the clock eases up from still.
    pub fn resumed(&mut self) {
        self.since_resumed = Some(0.0);
    }

    /// `advance(by:)`: steps the clock, eases the shown pointer, lets the energy decay.
    pub fn advance(&mut self, step: &Step) {
        let elapsed = step.elapsed;
        self.time += (elapsed * self.resume_pace(elapsed)) as f32;
        let Some(pointer) = step.pointer else { return };
        let pixels = |p: [f64; 2]| [(p[0] * step.scale[0]) as f32, (p[1] * step.scale[1]) as f32];
        let target = pixels(pointer);
        let previous = self.last_pointer.map_or(target, pixels);
        self.last_pointer = Some(pointer);
        self.pointer = target;
        if self.mouse == [0.0, 0.0] {
            self.mouse = target;
        }
        let ease = (1.0 - (-elapsed * 9.0).exp()) as f32;
        self.mouse[0] += (target[0] - self.mouse[0]) * ease;
        self.mouse[1] += (target[1] - self.mouse[1]) * ease;
        let (dx, dy) = (target[0] - previous[0], target[1] - previous[1]);
        let speed = if elapsed > 0.0 { (dx * dx + dy * dy).sqrt() / elapsed as f32 } else { 0.0 };
        let short = step.pixel_size[0].min(step.pixel_size[1]).max(1.0) as f32;
        self.energy = (self.energy * ((-elapsed * 2.0).exp() as f32)
            + speed / short * elapsed as f32 * 3.0)
            .min(1.0);
    }

    /// Whether the pointer or a click moves the picture now (`scale` turns the last pointer into
    /// pixels).
    pub fn lively(&self, scale: [f64; 2]) -> bool {
        if self.energy > CALM_ENERGY {
            return true;
        }
        if let Some(p) = self.last_pointer {
            let gap = [
                (p[0] * scale[0]) as f32 - self.mouse[0],
                (p[1] * scale[1]) as f32 - self.mouse[1],
            ];
            if gap[0] * gap[0] + gap[1] * gap[1] > 0.25 {
                return true;
            }
        }
        self.rings.iter().any(|r| r[3] > 0.5 && self.time - r[2] < RING_SECONDS)
    }

    /// The rate frames are drawn at now, never above `ceiling`.
    pub fn frames_per_second(&self, scale: [f64; 2], ceiling: f64) -> f64 {
        ceiling.min(if self.lively(scale) { MAXIMUM_FPS } else { CALM_FPS })
    }

    /// Sends a ring out from `point` (view points) at the current time.
    pub fn ring(&mut self, point: [f64; 2], scale: [f64; 2]) {
        let ring = [(point[0] * scale[0]) as f32, (point[1] * scale[1]) as f32, self.time, 1.0];
        self.rings[self.next_ring & 3] = ring;
        self.next_ring = (self.next_ring + 1) & 3;
        self.energy = (self.energy + 0.3).min(1.0);
    }
}

/// The frame-rate ceiling for the Mac's heat: warm (thermal state fair) halves it.
pub fn ceiling(warm: bool) -> f64 {
    if warm { WARM_FPS } else { MAXIMUM_FPS }
}

/// Whether a frame is due `since_drawn` seconds after the last at `fps`.
pub fn frame_due(since_drawn: f64, fps: f64) -> bool {
    since_drawn >= 1.0 / fps - 0.002
}
