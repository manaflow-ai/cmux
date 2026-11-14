//! Timestamp encodings of browser databases (`BrowserTime.swift`), each to seconds since
//! 2001-01-01 UTC: what Foundation's `Date` holds and `JSONEncoder` writes by default. Each
//! conversion does the Swift arithmetic in the Swift order, so the app's `Date` is the same bits.

/// Seconds between 1601-01-01 (Windows FILETIME epoch, Chromium) and 1970-01-01.
const CHROMIUM_EPOCH_OFFSET: f64 = 11_644_473_600.0;
/// Seconds between 1970-01-01 and 2001-01-01 (`Date.timeIntervalBetween1970AndReferenceDate`).
pub const UNIX_TO_REFERENCE: f64 = 978_307_200.0;

#[allow(clippy::cast_precision_loss, reason = "Swift's Double(Int64) rounds the same way")]
fn seconds(microseconds: i64) -> f64 {
    microseconds as f64 / 1_000_000.0
}

/// `Date(timeIntervalSince1970:)`.
pub fn from_unix(seconds: f64) -> f64 {
    seconds - UNIX_TO_REFERENCE
}

/// Chromium: microseconds since 1601-01-01 UTC. Zero or less means unknown.
pub fn chromium(microseconds: i64) -> Option<f64> {
    (microseconds > 0).then(|| from_unix(seconds(microseconds) - CHROMIUM_EPOCH_OFFSET))
}

/// Firefox: microseconds since 1970-01-01 UTC. Zero or less means unknown.
pub fn mozilla(microseconds: i64) -> Option<f64> {
    (microseconds > 0).then(|| from_unix(seconds(microseconds)))
}

/// Safari: seconds since 2001-01-01 UTC (Core Foundation absolute time). Zero or less (and NaN)
/// means unknown.
pub fn cocoa(seconds: f64) -> Option<f64> {
    (seconds > 0.0).then_some(seconds)
}
