//! Fling: velocity decays exponentially (the platform-like curve), so the offset at t is closed form and a frame
//! never integrates: o(t) = o0 + v0 * tau * (1 - e^(-t / tau)).

/// The decay constant, seconds (AppKit's momentum is close to this).
pub const TAU: f64 = 0.325;
/// Below this speed (points/s) a fling ends.
pub const STOP_SPEED: f64 = 5.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fling {
    pub start: f64,
    pub origin: f64,
    pub velocity: f64,
}

impl Fling {
    /// The offset at `now` and whether the fling is still moving.
    pub fn at(&self, now: f64) -> (f64, bool) {
        let t = (now - self.start).max(0.0);
        let decay = (-t / TAU).exp();
        let offset = self.origin + self.velocity * TAU * (1.0 - decay);
        (offset, (self.velocity * decay).abs() >= STOP_SPEED)
    }
}
