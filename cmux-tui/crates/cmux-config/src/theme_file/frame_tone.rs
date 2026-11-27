//! The two-tone frame's share: how much of the theme's ink the chrome around
//! the content card (the sidebar, the titlebar and the tab row under
//! `appearance.titleAreaTone` Subtle Tone) mixes into the content's surface.
//! Leo, 2026-11-23: "proper contrast that is only as contrasty as necessary and
//! probably not much more to not fuck up themes and bgs".
//!
//! The design system's ink ladder (hq `docs/design/design-system-decisions.md`,
//! Fills) counts every tone as the share of ink in the result: frame 4, hover
//! 8, selected 12. A fixed share is not one step on every theme: 4% black on
//! white moves OKLCH lightness by 0.03, 4% white on a near-black ground by
//! about 0.04, and a mid-gray theme less than either. So the frame takes the
//! least share, from the frame rung up to the selected rung, that moves the
//! surface's OKLCH lightness by [`STEP`] (what the frame rung gives on white):
//! one perceived step on every theme, light or dark, and never more.
//!
//! The wash is ink over the surface (sRGB alpha compositing, what Core
//! Animation draws), so the same share holds as a plain wash over a
//! translucent window or a background picture: the theme's background is the
//! base it is solved on. The Swift mirror (`FrameTone`, CmuxNextDesign) is
//! checked against [`fixture`], written at test time, never into git.

use cmux_theme_tokens::{Rgb, oklch};
use serde_json::{Value, json};

/// The ink ladder's frame rung: the least share.
pub const FRAME_RUNG: f64 = 0.04;
/// The ink ladder's selected rung: the most share, past which the frame would
/// read as a selected row.
pub const SELECTED_RUNG: f64 = 0.12;
/// The OKLCH lightness step the frame must make from the surface: the frame
/// rung's step on white (4% black, `#F5F5F5`).
pub const STEP: f64 = 0.03;
/// Bisection rounds: the share to within 1e-6.
const ROUNDS: u32 = 24;

/// `ink` at `share` over `base`, opaque.
pub fn washed(base: Rgb, ink: Rgb, share: f64) -> Rgb {
    base.with_alpha(1.0).mixed(ink.with_alpha(1.0), share)
}

fn step(base: Rgb, ink: Rgb, share: f64) -> f64 {
    (oklch(washed(base, ink, share)).l - oklch(base.with_alpha(1.0)).l).abs()
}

/// The frame's share of `ink` over `base`: the least share in
/// [`FRAME_RUNG`]..=[`SELECTED_RUNG`] whose wash moves OKLCH lightness by
/// [`STEP`]; [`SELECTED_RUNG`] when even that does not (an ink close to its
/// ground).
pub fn share(base: Rgb, ink: Rgb) -> f64 {
    if step(base, ink, FRAME_RUNG) >= STEP {
        return FRAME_RUNG;
    }
    if step(base, ink, SELECTED_RUNG) <= STEP {
        return SELECTED_RUNG;
    }
    let (mut low, mut high) = (FRAME_RUNG, SELECTED_RUNG);
    for _ in 0..ROUNDS {
        let mid = (low + high) / 2.0;
        if step(base, ink, mid) >= STEP {
            high = mid;
        } else {
            low = mid;
        }
    }
    high
}

/// The share a state's rung (hover 8, pressed 12) adds over a ground that
/// already holds `under` of the ink, so the result holds `rung` of it:
/// `(rung − under) / (1 − under)`, 0 when the ground already holds as much.
pub fn wash_over(rung: f64, under: f64) -> f64 {
    if rung <= under || under >= 1.0 { 0.0 } else { (rung - under) / (1.0 - under) }
}

/// Grounds and inks [`fixture`] solves: the two-tone samples (dark and light,
/// neutral and hued) plus a mid-gray ground, where the frame rung is too
/// faint and the share grows.
pub const FIXTURE_THEMES: [(&str, u32, u32); 10] = [
    ("ghostty-dark", 0x282C34, 0xFFFFFF),
    ("tokyo-night", 0x1A1B26, 0xC0CAF5),
    ("black-neutral", 0x000000, 0xEEEEEE),
    ("rose-pine", 0x191724, 0xE0DEF4),
    ("solarized-light", 0xFDF6E3, 0x586E75),
    ("github-light", 0xFFFFFF, 0x1F2328),
    ("paper-neutral", 0xF5F5F5, 0x222222),
    ("catppuccin-latte", 0xEFF1F5, 0x4C4F69),
    ("mid-gray", 0x6E6E6E, 0xF0F0F0),
    ("low-contrast", 0x3A3A3A, 0x707070),
];

/// Every share [`share`] gives [`FIXTURE_THEMES`], as JSON, for the Swift
/// mirror's test (`FrameToneTests`).
pub fn fixture() -> Value {
    let cases: Vec<Value> = FIXTURE_THEMES
        .iter()
        .map(|&(name, base, ink)| {
            let (base, ink) = (Rgb::hex(base), Rgb::hex(ink));
            let s = share(base, ink);
            json!({
                "theme": name,
                "base": format!("#{:06X}", base.to_hex()),
                "ink": format!("#{:06X}", ink.to_hex()),
                "share": s,
                "frame": format!("#{:06X}", washed(base, ink, s).to_hex()),
            })
        })
        .collect();
    json!({
        "$comment": "cmux-config theme_file::frame_tone::fixture, written for FrameToneTests at test time and never committed.",
        "frameRung": FRAME_RUNG,
        "selectedRung": SELECTED_RUNG,
        "step": STEP,
        "cases": cases,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn white_takes_the_frame_rung() {
        assert_eq!(share(Rgb::hex(0xFFFFFF), Rgb::hex(0x000000)), FRAME_RUNG);
    }

    #[test]
    fn every_share_is_one_step_and_no_more() {
        for &(name, base, ink) in &FIXTURE_THEMES {
            let (base, ink) = (Rgb::hex(base), Rgb::hex(ink));
            let s = share(base, ink);
            assert!((FRAME_RUNG..=SELECTED_RUNG).contains(&s), "{name}: {s}");
            let made = step(base, ink, s);
            if s > FRAME_RUNG && s < SELECTED_RUNG {
                assert!((made - STEP).abs() < 1e-4, "{name}: step {made}");
            } else if s == FRAME_RUNG {
                assert!(made >= STEP, "{name}: step {made}");
            }
        }
    }

    #[test]
    fn a_mid_gray_ground_takes_more_than_the_rung() {
        let s = share(Rgb::hex(0x6E6E6E), Rgb::hex(0xF0F0F0));
        assert!(s > FRAME_RUNG && s < SELECTED_RUNG, "{s}");
    }

    #[test]
    fn a_state_washes_to_its_rung_over_the_frame() {
        let under = 0.05;
        let w = wash_over(0.08, under);
        assert!((1.0 - (1.0 - under) * (1.0 - w) - 0.08).abs() < 1e-12);
        assert_eq!(wash_over(0.04, under), 0.0);
    }

    /// Writes the fixture `FrameToneTests` reads to `CMUX_FRAME_TONE_FIXTURE`;
    /// without it, only checks the fixture serializes.
    #[test]
    fn writes_the_swift_fixture() {
        let fresh = format!("{}\n", serde_json::to_string_pretty(&fixture()).unwrap());
        if let Some(path) = std::env::var_os("CMUX_FRAME_TONE_FIXTURE") {
            std::fs::write(&path, &fresh).unwrap();
        }
        assert!(fresh.contains("\"cases\""));
    }
}
