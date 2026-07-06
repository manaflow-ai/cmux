#[cfg(unix)]
use std::fs::OpenOptions;
#[cfg(unix)]
use std::io;
#[cfg(unix)]
use std::os::fd::{AsRawFd, RawFd};
#[cfg(unix)]
use std::time::{Duration, Instant};

use mux_core::DefaultColors;
#[cfg(any(unix, test))]
use mux_core::Rgb;

#[cfg(unix)]
const QUERY: &[u8] = b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\";
#[cfg(unix)]
const DEADLINE: Duration = Duration::from_millis(150);

#[cfg(unix)]
struct ProbeIo {
    read_fd: RawFd,
    write_fd: RawFd,
    _tty: Option<std::fs::File>,
}

#[cfg(unix)]
impl ProbeIo {
    fn open() -> Option<Self> {
        if is_tty(libc::STDIN_FILENO) {
            let write_fd =
                if is_tty(libc::STDOUT_FILENO) { libc::STDOUT_FILENO } else { libc::STDIN_FILENO };
            return Some(ProbeIo { read_fd: libc::STDIN_FILENO, write_fd, _tty: None });
        }

        if let Ok(tty) = OpenOptions::new().read(true).write(true).open("/dev/tty") {
            let fd = tty.as_raw_fd();
            return Some(ProbeIo { read_fd: fd, write_fd: fd, _tty: Some(tty) });
        }
        None
    }
}

#[cfg(unix)]
pub fn probe_default_colors() -> DefaultColors {
    let Some(io) = ProbeIo::open() else {
        return DefaultColors::default();
    };
    if write_all_fd(io.write_fd, QUERY).is_err() {
        return DefaultColors::default();
    }

    // The probe runs before the crossterm input reader starts. Any human
    // keystrokes during this short window may be consumed here; preserving
    // them would require feeding raw bytes back into crossterm's parser.
    parse_replies(&read_available_until(io.read_fd, DEADLINE))
}

#[cfg(not(unix))]
pub fn probe_default_colors() -> DefaultColors {
    DefaultColors::default()
}

#[cfg(unix)]
fn is_tty(fd: RawFd) -> bool {
    unsafe { libc::isatty(fd) == 1 }
}

#[cfg(unix)]
fn write_all_fd(fd: RawFd, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let written = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if written < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(err);
        }
        if written == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "short terminal probe write"));
        }
        bytes = &bytes[written as usize..];
    }
    Ok(())
}

#[cfg(unix)]
fn read_available_until(fd: RawFd, timeout: Duration) -> Vec<u8> {
    let deadline = Instant::now() + timeout;
    let mut out = Vec::with_capacity(128);
    loop {
        let now = Instant::now();
        if now >= deadline {
            break;
        }
        let remaining = deadline.saturating_duration_since(now);
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128) as i32;
        let mut poll_fd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if ready < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            break;
        }
        if ready == 0 {
            break;
        }
        let terminal_events = libc::POLLERR | libc::POLLHUP | libc::POLLNVAL;
        if poll_fd.revents & terminal_events != 0 {
            break;
        }
        if poll_fd.revents & libc::POLLIN == 0 {
            break;
        }

        let mut buf = [0u8; 512];
        let read = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if read < 0 {
            let err = io::Error::last_os_error();
            if matches!(err.raw_os_error(), Some(code) if code == libc::EINTR || code == libc::EAGAIN)
            {
                continue;
            }
            break;
        }
        if read == 0 {
            break;
        }
        out.extend_from_slice(&buf[..read as usize]);
        let colors = parse_replies(&out);
        if colors.fg.is_some() && colors.bg.is_some() {
            break;
        }
    }
    out
}

#[cfg(any(unix, test))]
fn parse_replies(bytes: &[u8]) -> DefaultColors {
    let mut colors = DefaultColors::default();
    let mut offset = 0;
    while let Some(relative_start) = find_subslice(&bytes[offset..], b"\x1b]") {
        let start = offset + relative_start + 2;
        let Some((end, next)) = find_terminator(bytes, start) else {
            break;
        };
        if let Some((target, color)) = parse_reply(&bytes[start..end]) {
            match target {
                10 => colors.fg = Some(color),
                11 => colors.bg = Some(color),
                _ => {}
            }
        }
        offset = next;
    }
    colors
}

#[cfg(any(unix, test))]
fn find_terminator(bytes: &[u8], start: usize) -> Option<(usize, usize)> {
    let mut i = start;
    while i < bytes.len() {
        match bytes[i] {
            b'\x07' => return Some((i, i + 1)),
            b'\x1b' if bytes.get(i + 1) == Some(&b'\\') => return Some((i, i + 2)),
            _ => i += 1,
        }
    }
    None
}

#[cfg(any(unix, test))]
fn parse_reply(reply: &[u8]) -> Option<(u8, Rgb)> {
    let (target, rest) = if let Some(rest) = reply.strip_prefix(b"10;rgb:") {
        (10, rest)
    } else if let Some(rest) = reply.strip_prefix(b"11;rgb:") {
        (11, rest)
    } else {
        return None;
    };

    let mut parts = rest.split(|b| *b == b'/');
    let r = parse_component(parts.next()?)?;
    let g = parse_component(parts.next()?)?;
    let b = parse_component(parts.next()?)?;
    parts.next().is_none().then_some((target, Rgb { r, g, b }))
}

#[cfg(any(unix, test))]
fn parse_component(bytes: &[u8]) -> Option<u8> {
    if !(2..=4).contains(&bytes.len()) {
        return None;
    }
    let mut value = 0u16;
    for b in bytes {
        value = (value << 4) | u16::from(hex_nibble(*b)?);
    }
    let shift = (bytes.len() - 2) * 4;
    Some((value >> shift) as u8)
}

#[cfg(any(unix, test))]
fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(any(unix, test))]
fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_bel_and_st_rgb_replies() {
        let colors =
            parse_replies(b"noise\x1b]10;rgb:eeee/dddd/cccc\x1b\\more\x1b]11;rgb:13/14/15\x07");
        assert_eq!(colors.fg, Some(Rgb { r: 0xee, g: 0xdd, b: 0xcc }));
        assert_eq!(colors.bg, Some(Rgb { r: 0x13, g: 0x14, b: 0x15 }));
    }

    #[test]
    fn ignores_malformed_replies() {
        let colors = parse_replies(b"\x1b]11;rgb:1/2/3\x07\x1b]10;rgb:zz/00/00\x1b\\");
        assert_eq!(colors, DefaultColors::default());
    }
}
