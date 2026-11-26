use std::io::{self, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::Rect;
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use super::host_frame_writer;

/// Counts the writes that reach the host terminal: each is a write
/// syscall on its PTY, and over SSH a read and a packet of its own.
#[derive(Clone, Default)]
struct HostTerminal {
    writes: Arc<AtomicUsize>,
    bytes: Arc<AtomicUsize>,
}

impl Write for HostTerminal {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.writes.fetch_add(1, Ordering::Relaxed);
        self.bytes.fetch_add(buf.len(), Ordering::Relaxed);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A full screen of styled text, as a scroll or a burst of output
/// repaints it: every cell changes from the frame before, in several
/// colors.
fn full_screen(frame: usize, area: Rect) -> Paragraph<'static> {
    let colors = [Color::Red, Color::Green, Color::Yellow, Color::Blue];
    let width = usize::from(area.width);
    let chunk = width / 8;
    let lines: Vec<Line> = (0..usize::from(area.height))
        .map(|row| {
            let spans: Vec<Span> = (0..8)
                .map(|part| {
                    let text: String = (0..chunk)
                        .map(|col| {
                            let letter = (frame + row + part * chunk + col) % 26;
                            char::from(b'a' + letter as u8)
                        })
                        .collect();
                    Span::styled(text, Style::default().fg(colors[(part + row + frame) % 4]))
                })
                .collect();
            Line::from(spans)
        })
        .collect();
    Paragraph::new(lines)
}

/// A frame reaches the host terminal in one write: written in pieces it
/// costs a syscall and, over SSH, a packet per piece, and the host can
/// show a frame half drawn.
#[test]
fn a_full_screen_frame_is_one_write() {
    let host = HostTerminal::default();
    let backend = CrosstermBackend::new(host_frame_writer(host.clone()));
    let mut terminal = Terminal::with_options(
        backend,
        ratatui::TerminalOptions { viewport: ratatui::Viewport::Fixed(Rect::new(0, 0, 160, 48)) },
    )
    .unwrap();
    for frame in 1..=3usize {
        let before = host.writes.load(Ordering::Relaxed);
        let bytes_before = host.bytes.load(Ordering::Relaxed);
        terminal.draw(|f| f.render_widget(full_screen(frame, f.area()), f.area())).unwrap();
        let writes = host.writes.load(Ordering::Relaxed) - before;
        let bytes = host.bytes.load(Ordering::Relaxed) - bytes_before;
        assert!(bytes > 8 * 1024, "frame {frame} wrote only {bytes} bytes");
        assert_eq!(writes, 1, "frame {frame}: {bytes} bytes in {writes} writes");
    }
}
