//! The SWITCH FRAMES beacon (cp/switch-frames-kit scripts/journeys/ext_switch.py `ansi`, `rows`), compiled:
//! every frame says, in colors a video judge reads, which pane it is and when it drew. Top-left, one block
//! = `cell_cols` columns x 1 row, truecolor background:
//!   row 0:  Y  ws[6 bits]  pane[4 bits]            parity  R
//!   row 1:  Y  clock gray-code bits 17..9          parity  R
//!   row 2:  Y  clock gray-code bits  8..0          parity  R
//! Y yellow, R red, bit 1 magenta, bit 0 cyan. The clock is CLOCK_UPTIME_RAW (the recorder's frames.json
//! clock; the SWITCH owner's request, STATUS 4794's neighbour item) in 2 ms units, 18 bits.

use std::fmt::Write as _;

pub const CLOCK_UNIT_MS: u64 = 2;
pub const CLOCK_BITS: u32 = 18;
pub const WS_BITS: u32 = 6;
pub const PANE_BITS: u32 = 4;

pub fn gray(n: u64) -> u64 {
    n ^ (n >> 1)
}

fn bits(value: u64, width: u32) -> Vec<u8> {
    (0..width)
        .map(|i| ((value >> (width - 1 - i)) & 1) as u8)
        .collect()
}

fn parity(values: &[u8]) -> u8 {
    values.iter().map(|&v| u32::from(v)).sum::<u32>() as u8 & 1
}

/// ext_switch.py `clock_units`, on the monotonic clock: (ns / 2 ms) mod 2^18.
pub fn clock_units(mono_ns: u64) -> u64 {
    (mono_ns / (CLOCK_UNIT_MS * 1_000_000)) % (1_u64 << CLOCK_BITS)
}

/// ext_switch.py `rows`: the data bits of the three rows (no markers, parity last).
pub fn rows(ws: u64, pane: u64, clock: u64) -> [Vec<u8>; 3] {
    let mut ids = bits(ws % (1 << WS_BITS), WS_BITS);
    ids.extend(bits(pane % (1 << PANE_BITS), PANE_BITS));
    let g = bits(gray(clock), CLOCK_BITS);
    let (hi, lo) = g.split_at(9);
    let mut hi = hi.to_vec();
    let mut lo = lo.to_vec();
    let p = parity(&ids);
    ids.push(p);
    let p = parity(&hi);
    hi.push(p);
    let p = parity(&lo);
    lo.push(p);
    [ids, hi, lo]
}

fn block(out: &mut String, rgb: (u8, u8, u8), cols: usize) {
    let _ = write!(
        out,
        "\x1b[48;2;{};{};{}m{}",
        rgb.0,
        rgb.1,
        rgb.2,
        " ".repeat(cols)
    );
}

const YELLOW: (u8, u8, u8) = (255, 255, 0);
const RED: (u8, u8, u8) = (255, 0, 0);
const ONE: (u8, u8, u8) = (255, 0, 255);
const ZERO: (u8, u8, u8) = (0, 255, 255);

/// ext_switch.py `ansi(ws, pane, clock, cell_cols, 1, 1)`.
pub fn ansi(ws: u64, pane: u64, clock: u64, cell_cols: usize) -> String {
    let mut out = String::with_capacity(1024);
    for (i, data) in rows(ws, pane, clock).iter().enumerate() {
        let _ = write!(out, "\x1b[{};1H", i + 1);
        block(&mut out, YELLOW, cell_cols);
        for &bit in data {
            block(&mut out, if bit == 1 { ONE } else { ZERO }, cell_cols);
        }
        block(&mut out, RED, cell_cols);
        out.push_str("\x1b[0m");
    }
    out
}

/// ext_switch.py `_fill`: a moving shade below the beacon (rows top..=height).
pub fn fill(frame: u64, width: usize, height: usize, top: usize) -> String {
    let mut out = String::new();
    for y in top..=height {
        let shade = (frame.wrapping_mul(3).wrapping_add(y as u64 * 7)) % 64 + 32;
        let _ = write!(
            out,
            "\x1b[{y};1H\x1b[48;2;{};{};{}m{}",
            shade,
            shade / 2,
            96 - shade / 2,
            " ".repeat(width)
        );
    }
    out.push_str("\x1b[0m");
    out
}

/// One beacon frame, as ext_switch.py `beacon_main` writes it.
pub fn frame(
    ws: u64,
    pane: u64,
    clock: u64,
    cell_cols: usize,
    label: &str,
    k: u64,
    clear: bool,
    fill_size: Option<(usize, usize)>,
) -> String {
    let mut out = String::from("\x1b[?2026h");
    if clear {
        out.push_str("\x1b[2J");
    }
    out.push_str(&ansi(ws, pane, clock, cell_cols));
    let _ = write!(out, "\x1b[5;1H\x1b[1m{label}\x1b[0m  frame {k:9}");
    if let Some((w, h)) = fill_size {
        out.push_str(&fill(k, w, h, 7));
    }
    out.push_str("\x1b[?2026l");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn rows_and_parity() {
        let r = rows(5, 3, 0b10_1010_1010_1010_1010);
        assert_eq!(r[0], vec![0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0]);
        assert_eq!(r[1].len(), 10);
        assert_eq!(r[2].len(), 10);
        for row in &r {
            assert_eq!(row.iter().map(|&b| u32::from(b)).sum::<u32>() % 2, 0);
        }
        assert_eq!(clock_units(4_000_000), 2);
    }
}
