use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::time::Duration;
#[cfg(unix)]
use std::time::Instant;

use cmux_tui_core::{Rect, SurfaceId};

const ESC: &str = "\x1b";
const CHUNK: usize = 4096;
const PLACEMENT_ID: u32 = 1;

#[derive(Debug, Clone)]
pub struct GraphicPlacement {
    pub surface: SurfaceId,
    pub rect: Rect,
    pub seq: u64,
    pub data_b64: String,
}

#[derive(Default)]
pub struct GraphicsState {
    transmitted: HashMap<SurfaceId, u64>,
    visible: HashSet<SurfaceId>,
}

impl GraphicsState {
    pub fn frame_batches(&mut self, placements: &[GraphicPlacement]) -> Vec<Vec<u8>> {
        let visible_placements = placements
            .iter()
            .filter(|placement| placement.rect.width > 0 && placement.rect.height > 0)
            .collect::<Vec<_>>();
        let now_visible = visible_placements.iter().map(|p| p.surface).collect::<HashSet<_>>();
        let mut out = Vec::new();

        for old in self.visible.difference(&now_visible) {
            out.push(delete_image(*old));
            self.transmitted.remove(old);
        }

        for placement in visible_placements {
            let mut batch = Vec::new();
            let already_sent =
                self.transmitted.get(&placement.surface).is_some_and(|seq| *seq == placement.seq);
            if !already_sent {
                batch.extend(transmit_png(placement.surface, &placement.data_b64));
                self.transmitted.insert(placement.surface, placement.seq);
            }
            batch.extend(place_image(placement.surface, placement.rect));
            if !batch.is_empty() {
                out.push(batch);
            }
        }

        self.visible = now_visible;
        out
    }
}

pub fn image_id(surface: SurfaceId) -> u32 {
    ((surface % 2_000_000_000) + 1) as u32
}

pub fn transmit_png(surface: SurfaceId, data_b64: &str) -> Vec<u8> {
    let id = image_id(surface);
    let mut out = Vec::new();
    let chunks = data_b64.as_bytes().chunks(CHUNK).collect::<Vec<&[u8]>>();
    for (idx, chunk) in chunks.iter().enumerate() {
        let more = usize::from(idx + 1 < chunks.len());
        let header = if idx == 0 {
            format!("{ESC}_Ga=t,f=100,i={id},q=2,m={more};")
        } else {
            format!("{ESC}_Gq=2,m={more};")
        };
        out.extend_from_slice(header.as_bytes());
        out.extend_from_slice(chunk);
        out.extend_from_slice(format!("{ESC}\\").as_bytes());
    }
    out
}

pub fn place_image(surface: SurfaceId, rect: Rect) -> Vec<u8> {
    let id = image_id(surface);
    format!(
        "{ESC}7{ESC}[{};{}H{ESC}_Ga=p,i={id},p={PLACEMENT_ID},c={},r={},q=2;{ESC}\\{ESC}8",
        rect.y + 1,
        rect.x + 1,
        rect.width.max(1),
        rect.height.max(1)
    )
    .into_bytes()
}

pub fn delete_image(surface: SurfaceId) -> Vec<u8> {
    let id = image_id(surface);
    format!("{ESC}_Ga=d,d=i,i={id},q=2;{ESC}\\").into_bytes()
}

pub fn probe_kitty_graphics() -> bool {
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c");
    let _ = stdout.flush();
    let bytes = read_stdin_for(Duration::from_millis(180));
    kitty_probe_succeeded(&bytes)
}

const FALLBACK_CELL_PIXELS: (u16, u16) = (8, 16);

/// Resolve host cell metrics without treating an absent resize-time ioctl
/// value as a new measurement. Some outer terminals zero `ws_xpixel` and
/// `ws_ypixel` after `TIOCSWINSZ`; in that case the last real measurement is
/// more accurate than the synthetic startup fallback.
pub fn detect_cell_pixels(known: Option<(u16, u16)>, query_fallback: bool) -> (u16, u16) {
    let detected = ioctl_cell_pixels().or_else(|| query_fallback.then(query_cell_pixels).flatten());
    resolve_cell_pixels(known, detected)
}

fn resolve_cell_pixels(known: Option<(u16, u16)>, detected: Option<(u16, u16)>) -> (u16, u16) {
    detected.or(known).unwrap_or(FALLBACK_CELL_PIXELS)
}

fn cell_pixels_from_terminal_size(
    cols: u16,
    rows: u16,
    width_px: u16,
    height_px: u16,
) -> Option<(u16, u16)> {
    if cols == 0 || rows == 0 || width_px == 0 || height_px == 0 {
        return None;
    }
    Some(((width_px / cols).max(1), (height_px / rows).max(1)))
}

#[cfg(unix)]
fn ioctl_cell_pixels() -> Option<(u16, u16)> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0;
    ok.then(|| cell_pixels_from_terminal_size(ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel))
        .flatten()
}

#[cfg(not(unix))]
fn ioctl_cell_pixels() -> Option<(u16, u16)> {
    None
}

fn query_cell_pixels() -> Option<(u16, u16)> {
    let (cols, rows) = crossterm::terminal::size().ok()?;
    if cols == 0 || rows == 0 {
        return None;
    }
    let mut stdout = std::io::stdout();
    let _ = write!(stdout, "\x1b[14t");
    let _ = stdout.flush();
    let bytes = read_stdin_for(Duration::from_millis(120));
    let response = String::from_utf8_lossy(&bytes);
    let start = response.find("\x1b[4;")?;
    let tail = &response[start + 4..];
    let end = tail.find('t')?;
    let mut parts = tail[..end].split(';');
    let height = parts.next()?.parse::<u32>().ok()?;
    let width = parts.next()?.parse::<u32>().ok()?;
    Some((((width / cols as u32).max(1)) as u16, ((height / rows as u32).max(1)) as u16))
}

#[cfg(unix)]
fn read_stdin_for(timeout: Duration) -> Vec<u8> {
    let start = Instant::now();
    let mut out = Vec::new();
    while start.elapsed() < timeout {
        let remaining = timeout.saturating_sub(start.elapsed());
        let poll_ms = remaining.min(Duration::from_millis(20)).as_millis() as i32;
        let mut fd = libc::pollfd { fd: libc::STDIN_FILENO, events: libc::POLLIN, revents: 0 };
        let ready = unsafe { libc::poll(&mut fd, 1, poll_ms) };
        if ready <= 0 {
            continue;
        }
        let mut buf = [0u8; 1024];
        let n = unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 {
            break;
        }
        out.extend_from_slice(&buf[..n as usize]);
        // DA1 is emitted as an inexpensive progress marker, but it is not a
        // completion fence: terminals can produce the Kitty APC reply on a
        // different render/output lane. Drain the entire bounded probe window
        // so that a valid reply arriving after DA1 cannot leak into crossterm
        // input (or the shell that resumes after cmux exits).
    }
    out
}

// Raw non-blocking stdin reads need poll(2); without them the graphics
// probes can't collect replies, so report "no response" and let callers
// fall back (no kitty graphics, default cell size).
#[cfg(not(unix))]
fn read_stdin_for(_timeout: Duration) -> Vec<u8> {
    Vec::new()
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn kitty_probe_succeeded(bytes: &[u8]) -> bool {
    find_bytes(bytes, b"_Gi=31;OK").is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_pixel_resize_preserves_known_cell_metrics() {
        let detected = cell_pixels_from_terminal_size(120, 40, 0, 0);
        assert_eq!(detected, None);
        assert_eq!(resolve_cell_pixels(Some((11, 23)), detected), (11, 23));
    }

    #[test]
    fn missing_initial_metrics_use_synthetic_fallback() {
        assert_eq!(resolve_cell_pixels(None, None), FALLBACK_CELL_PIXELS);
    }

    #[test]
    fn newly_detected_metrics_replace_known_metrics() {
        assert_eq!(resolve_cell_pixels(Some((8, 16)), Some((11, 23))), (11, 23));
    }

    #[test]
    fn kitty_probe_accepts_ok_before_da1() {
        assert!(kitty_probe_succeeded(b"\x1b_Gi=31;OK\x1b\\\x1b[?62;c"));
    }

    #[test]
    fn kitty_probe_accepts_async_ok_after_da1() {
        assert!(kitty_probe_succeeded(b"\x1b[?62;c\x1b_Gi=31;OK\x1b\\"));
    }

    #[test]
    fn kitty_probe_rejects_da1_or_error_without_ok() {
        assert!(!kitty_probe_succeeded(b"\x1b[?62;c"));
        assert!(!kitty_probe_succeeded(b"\x1b_Gi=31;EINVAL\x1b\\"));
    }

    #[test]
    fn transmits_png_in_quiet_chunks() {
        let data = format!("{}{}", "a".repeat(4096), "b".repeat(4));
        let bytes = String::from_utf8(transmit_png(7, &data)).unwrap();
        assert_eq!(
            bytes,
            format!(
                "\x1b_Ga=t,f=100,i=8,q=2,m=1;{}\x1b\\\x1b_Gq=2,m=0;bbbb\x1b\\",
                "a".repeat(4096)
            )
        );
    }

    #[test]
    fn places_at_cursor_rect_with_save_restore() {
        let bytes =
            String::from_utf8(place_image(2, Rect { x: 4, y: 6, width: 80, height: 24 })).unwrap();
        assert_eq!(bytes, "\x1b7\x1b[7;5H\x1b_Ga=p,i=3,p=1,c=80,r=24,q=2;\x1b\\\x1b8");
    }

    #[test]
    fn deletes_by_image_id_quietly() {
        let bytes = String::from_utf8(delete_image(41)).unwrap();
        assert_eq!(bytes, "\x1b_Ga=d,d=i,i=42,q=2;\x1b\\");
    }

    #[test]
    fn zero_sized_placement_hides_a_previously_visible_image() {
        let visible = GraphicPlacement {
            surface: 7,
            rect: Rect { x: 4, y: 6, width: 80, height: 24 },
            seq: 1,
            data_b64: "frame".to_string(),
        };
        let collapsed =
            GraphicPlacement { rect: Rect { height: 0, ..visible.rect }, ..visible.clone() };
        let mut state = GraphicsState::default();

        assert!(!state.frame_batches(&[visible]).is_empty());
        assert_eq!(state.frame_batches(&[collapsed]), vec![delete_image(7)]);
    }
}
