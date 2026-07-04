use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::time::{Duration, Instant};

use mux_core::{Rect, SurfaceId};

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
    pub fn frame_bytes(&mut self, placements: &[GraphicPlacement]) -> Vec<u8> {
        let now_visible = placements.iter().map(|p| p.surface).collect::<HashSet<_>>();
        let mut out = Vec::new();

        for old in self.visible.difference(&now_visible) {
            out.extend(delete_image(*old));
            self.transmitted.remove(old);
        }

        for placement in placements {
            let already_sent =
                self.transmitted.get(&placement.surface).is_some_and(|seq| *seq == placement.seq);
            if !already_sent {
                out.extend(transmit_png(placement.surface, &placement.data_b64));
                self.transmitted.insert(placement.surface, placement.seq);
            }
            out.extend(place_image(placement.surface, placement.rect));
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
            format!("{ESC}_Ga=T,f=100,i={id},q=2,m={more};")
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
    let ok = find_bytes(&bytes, b"_Gi=31;OK");
    let da = find_da1(&bytes);
    match (ok, da) {
        (Some(ok), Some(da)) => ok < da,
        (Some(_), None) => true,
        _ => false,
    }
}

pub fn detect_cell_pixels(query_fallback: bool) -> (u16, u16) {
    if let Some(cell) = ioctl_cell_pixels() {
        return cell;
    }
    if query_fallback {
        if let Some(cell) = query_cell_pixels() {
            return cell;
        }
    }
    (8, 16)
}

fn ioctl_cell_pixels() -> Option<(u16, u16)> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0;
    if !ok || ws.ws_col == 0 || ws.ws_row == 0 || ws.ws_xpixel == 0 || ws.ws_ypixel == 0 {
        return None;
    }
    let w = (ws.ws_xpixel / ws.ws_col).max(1);
    let h = (ws.ws_ypixel / ws.ws_row).max(1);
    Some((w, h))
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
        if find_da1(&out).is_some() {
            break;
        }
    }
    out
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn find_da1(bytes: &[u8]) -> Option<usize> {
    bytes.iter().enumerate().find_map(|(idx, byte)| {
        if *byte == b'c' && bytes[..idx].iter().rev().take(16).any(|b| *b == b'[') {
            Some(idx)
        } else {
            None
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transmits_png_in_quiet_chunks() {
        let data = format!("{}{}", "a".repeat(4096), "b".repeat(4));
        let bytes = String::from_utf8(transmit_png(7, &data)).unwrap();
        assert_eq!(
            bytes,
            format!(
                "\x1b_Ga=T,f=100,i=8,q=2,m=1;{}\x1b\\\x1b_Gq=2,m=0;bbbb\x1b\\",
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
}
