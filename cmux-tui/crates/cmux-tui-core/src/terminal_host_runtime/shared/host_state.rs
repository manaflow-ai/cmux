//! Host-side state of the terminal-host runtime that does not touch the OS
//! (cx-ko2e table A). For now: PTY geometry and the kitty-graphics ceiling
//! check; `HostShared` follows once its OS fields sit behind seams.

use cmux_pty::PtySize;

use super::super::*;

pub(crate) fn pty_size(cols: u16, rows: u16, cell_pixels: (u16, u16)) -> anyhow::Result<PtySize> {
    let pixel_width = cols.checked_mul(cell_pixels.0).ok_or_else(|| {
        anyhow::anyhow!(
            "terminal pixel width exceeds {}: {cols} columns at {} pixels per cell",
            u16::MAX,
            cell_pixels.0
        )
    })?;
    let pixel_height = rows.checked_mul(cell_pixels.1).ok_or_else(|| {
        anyhow::anyhow!(
            "terminal pixel height exceeds {}: {rows} rows at {} pixels per cell",
            u16::MAX,
            cell_pixels.1
        )
    })?;
    Ok(PtySize { rows, cols, pixel_width, pixel_height })
}

pub(crate) fn kitty_graphics_limits_within(
    candidate: KittyGraphicsLimits,
    ceiling: KittyGraphicsLimits,
) -> bool {
    candidate.image_bytes <= ceiling.image_bytes
        && candidate.inflight_bytes <= ceiling.inflight_bytes
        && candidate.images <= ceiling.images
        && candidate.placements <= ceiling.placements
}
