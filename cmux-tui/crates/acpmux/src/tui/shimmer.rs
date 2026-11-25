//! Codex-style shimmer for "working" text: a soft band of light sweeps
//! across the characters, timed from process start so every row moves in
//! step. True-color terminals get a blended grey ramp; others get a
//! three-step DIM / normal / BOLD band.

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::Span;
use std::sync::OnceLock;
use std::time::Instant;

static START: OnceLock<Instant> = OnceLock::new();

fn true_color() -> bool {
    static TC: OnceLock<bool> = OnceLock::new();
    *TC.get_or_init(|| {
        let ct = std::env::var("COLORTERM").unwrap_or_default().to_ascii_lowercase();
        ct.contains("truecolor") || ct.contains("24bit")
    })
}

fn blend(a: (u8, u8, u8), b: (u8, u8, u8), t: f32) -> (u8, u8, u8) {
    let f = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round().clamp(0.0, 255.0) as u8;
    (f(a.0, b.0), f(a.1, b.1), f(a.2, b.2))
}

/// One span per character. `base` is the resting grey and `bright` the
/// band's peak, both as RGB; the sweep takes two seconds.
pub fn spans(text: &str, base: (u8, u8, u8), bright: (u8, u8, u8)) -> Vec<Span<'static>> {
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() {
        return Vec::new();
    }
    let padding = 10usize;
    let period = chars.len() + padding * 2;
    let sweep_seconds = 2.0f32;
    let elapsed = START.get_or_init(Instant::now).elapsed().as_secs_f32();
    let pos = ((elapsed % sweep_seconds) / sweep_seconds * period as f32) as isize;
    let half = 5.0f32;
    let tc = true_color();
    chars
        .iter()
        .enumerate()
        .map(|(i, ch)| {
            let dist = ((i + padding) as isize - pos).abs() as f32;
            let t = if dist <= half {
                0.5 * (1.0 + (std::f32::consts::PI * dist / half).cos())
            } else {
                0.0
            };
            let style = if tc {
                let (r, g, b) = blend(base, bright, (t * 0.9).clamp(0.0, 1.0));
                Style::default().fg(Color::Rgb(r, g, b)).add_modifier(Modifier::BOLD)
            } else if t < 0.2 {
                Style::default().add_modifier(Modifier::DIM)
            } else if t < 0.6 {
                Style::default()
            } else {
                Style::default().add_modifier(Modifier::BOLD)
            };
            Span::styled(ch.to_string(), style)
        })
        .collect()
}
