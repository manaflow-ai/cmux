//! `dwell`: a moving wallpaper's slow tour between salient regions.
//!
//! [`tour`] orders the regions (heaviest first, then always the nearest
//! region not yet seen, so the camera never zig-zags across the picture) and
//! returns one [`Signal::Salient`] event per stop, `dwell_us` apart. Pushed
//! into a [`Camera`](crate::Camera) built with [`Config::wallpaper`], the
//! crop pans between the stops with the camera's bounded speed and
//! acceleration and its dead zone: a stop whose framing is already inside
//! the dead zone does not move the camera at all, so it never jitters.

// Pure and panic-free on any input.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented
    )
)]

use crate::fit::Salient;
use crate::{Config, Event, Signal};

impl Config {
    /// A slow camera for a moving wallpaper or idle screen of `aspect`: the
    /// crop is a little smaller than the largest (zoom 1.2) so it has room
    /// to travel, moves at most 3% of its width a second, and takes about two
    /// seconds to reach that speed.
    pub fn wallpaper(aspect: f64) -> Self {
        Self {
            aspect,
            zoom: 1.2,
            dead_zone: 0.5,
            max_speed: 0.03,
            max_accel: 0.015,
            ..Self::default()
        }
    }
}

/// `stops` events from `start_us`, one every `dwell_us`, each framing one
/// region of the tour (cycling when there are fewer regions than stops).
/// Regions that are not finite or have no positive weight are skipped; no
/// usable region gives no events.
pub fn tour(regions: &[Salient], start_us: u64, dwell_us: u64, stops: usize) -> Vec<Event> {
    let order = order(regions);
    if order.is_empty() {
        return Vec::new();
    }
    (0..stops)
        .filter_map(|k| {
            let r = order.get(k % order.len())?;
            let t_us = start_us.saturating_add(dwell_us.saturating_mul(k as u64));
            Some(Event {
                t_us,
                signal: Signal::Salient { x: r.x, y: r.y, w: r.w, h: r.h, weight: 1.0 },
            })
        })
        .collect()
}

/// Heaviest first, then nearest-unvisited by centre. Deterministic: ties
/// keep input order.
fn order(regions: &[Salient]) -> Vec<Salient> {
    let mut left: Vec<Salient> = regions
        .iter()
        .copied()
        .filter(|r| {
            [r.x, r.y, r.w, r.h, r.weight].iter().all(|v| v.is_finite())
                && r.weight > 0.0
                && r.w >= 0.0
                && r.h >= 0.0
        })
        .collect();
    let mut out = Vec::with_capacity(left.len());
    let first = left
        .iter()
        .enumerate()
        .fold(None::<(usize, f64)>, |best, (i, r)| match best {
            Some((_, w)) if w >= r.weight => best,
            _ => Some((i, r.weight)),
        })
        .map(|(i, _)| i);
    let Some(first) = first else { return out };
    let mut at = left.remove(first);
    out.push(at);
    while !left.is_empty() {
        let (ax, ay) = at.center();
        let next = left
            .iter()
            .enumerate()
            .fold(None::<(usize, f64)>, |best, (i, r)| {
                let (rx, ry) = r.center();
                let d = (rx - ax).hypot(ry - ay);
                match best {
                    Some((_, bd)) if bd <= d => best,
                    _ => Some((i, d)),
                }
            })
            .map(|(i, _)| i);
        let Some(next) = next else { break };
        at = left.remove(next);
        out.push(at);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heaviest_first_then_nearest() {
        let regions = [
            Salient::new(0.0, 0.0, 10.0, 10.0, 0.2),
            Salient::new(1000.0, 0.0, 10.0, 10.0, 0.5),
            Salient::new(900.0, 0.0, 10.0, 10.0, 0.1),
        ];
        let events = tour(&regions, 100, 1000, 4);
        let xs: Vec<f64> = events
            .iter()
            .map(|e| match e.signal {
                Signal::Salient { x, .. } => x,
                _ => f64::NAN,
            })
            .collect();
        assert_eq!(xs, vec![1000.0, 900.0, 0.0, 1000.0]);
        let ts: Vec<u64> = events.iter().map(|e| e.t_us).collect();
        assert_eq!(ts, vec![100, 1100, 2100, 3100]);
    }

    #[test]
    fn bad_regions_give_nothing() {
        let bad = [
            Salient::new(f64::NAN, 0.0, 1.0, 1.0, 1.0),
            Salient::new(0.0, 0.0, 1.0, 1.0, 0.0),
            Salient::new(0.0, 0.0, -1.0, 1.0, 1.0),
        ];
        assert!(tour(&bad, 0, 1, 5).is_empty());
        assert!(tour(&[], 0, 1, 5).is_empty());
        assert_eq!(tour(&[Salient::new(0.0, 0.0, 1.0, 1.0, 1.0)], u64::MAX, u64::MAX, 3).len(), 3);
    }
}
