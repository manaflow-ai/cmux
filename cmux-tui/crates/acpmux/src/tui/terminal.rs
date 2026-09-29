//! One owner for terminal output. Hyperlinks participate in the cell diff;
//! they never repaint the transcript behind Ratatui's back. All escapes for
//! a frame, including the final cursor, are committed as one buffered update.

use std::{cell::RefCell, collections::BTreeMap, io::{self, Write}, rc::Rc};
use ratatui::{backend::{Backend, ClearType, CrosstermBackend, WindowSize}, buffer::{Buffer, Cell}, layout::{Position, Size}};
use unicode_width::UnicodeWidthStr;
use super::{App, links::LinkCell};

type Coord = (u16, u16); // row, column: terminal output order

#[derive(Default)]
pub(super) struct LinkState {
    current: BTreeMap<Coord, (String, Cell)>,
    forced: BTreeMap<Coord, Cell>,
}

impl LinkState {
    fn prepare(&mut self, links: &[LinkCell], buffer: &Buffer) {
        let mut next = BTreeMap::new();
        for link in links {
            let mut x = link.x;
            let end = x.saturating_add(link.text.width() as u16);
            while x < end {
                let Some(cell) = buffer.cell((x, link.y)) else { break; };
                next.insert((link.y, x), (link.href.clone(), cell.clone()));
                x = x.saturating_add(cell.symbol().width().max(1) as u16);
            }
        }
        self.forced.clear();
        // A URL can change without changing its visible label. Likewise an
        // overlay can remove a link while leaving identical text underneath.
        for (&coord, (href, cell)) in &next {
            if self.current.get(&coord).map(|(old, _)| old) != Some(href) {
                self.forced.insert(coord, cell.clone());
            }
        }
        for (&(y, x), (_, old)) in &self.current {
            if !next.contains_key(&(y, x))
                && let Some(cell) = buffer.cell((x, y)) {
                    // Changed cells already belong to Ratatui's diff. In
                    // particular, do not force a wide-glyph continuation.
                    if cell == old { self.forced.insert((y, x), cell.clone()); }
                }
        }
        self.current = next;
    }
}

#[derive(Clone, Default)]
struct FrameBytes(Rc<RefCell<Vec<u8>>>);

impl Write for FrameBytes {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.borrow_mut().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}

pub(super) struct AtomicBackend<W: Write> {
    out: W,
    encoded: CrosstermBackend<FrameBytes>,
    bytes: FrameBytes,
    links: Rc<RefCell<LinkState>>,
    cursor_visible: bool,
}

impl<W: Write> AtomicBackend<W> {
    fn new(out: W, links: Rc<RefCell<LinkState>>) -> Self {
        let bytes = FrameBytes::default();
        Self { out, encoded: CrosstermBackend::new(bytes.clone()), bytes, links, cursor_visible: false }
    }
}

impl<W: Write> Backend for AtomicBackend<W> {
    type Error = io::Error;

    fn draw<'a, I>(&mut self, content: I) -> io::Result<()> where I: Iterator<Item = (u16, u16, &'a Cell)> {
        let mut links = self.links.borrow_mut();
        let mut cells = std::mem::take(&mut links.forced);
        cells.extend(content.map(|(x, y, c)| ((y, x), c.clone())));
        let cells: Vec<_> = cells.into_iter().collect();
        let mut start = 0;
        while start < cells.len() {
            let href = links.current.get(&cells[start].0).map(|(h, _)| h.as_str());
            let mut end = start + 1;
            while end < cells.len() && links.current.get(&cells[end].0).map(|(h, _)| h.as_str()) == href { end += 1; }
            if let Some(href) = href {
                // Never let content terminate an OSC sequence.
                let safe: String = href.chars().filter(|c| !c.is_control()).collect();
                write!(self.encoded, "\x1b]8;;{safe}\x1b\\")?;
            }
            self.encoded.draw(cells[start..end].iter().map(|((y, x), c)| (*x, *y, c)))?;
            if href.is_some() { self.encoded.write_all(b"\x1b]8;;\x1b\\")?; }
            start = end;
        }
        Ok(())
    }

    fn hide_cursor(&mut self) -> io::Result<()> { self.cursor_visible = false; Ok(()) }
    fn show_cursor(&mut self) -> io::Result<()> { self.cursor_visible = true; Ok(()) }
    fn get_cursor_position(&mut self) -> io::Result<Position> { self.encoded.get_cursor_position() }
    fn set_cursor_position<P: Into<Position>>(&mut self, p: P) -> io::Result<()> { self.encoded.set_cursor_position(p) }
    fn clear(&mut self) -> io::Result<()> { self.encoded.clear() }
    fn clear_region(&mut self, c: ClearType) -> io::Result<()> { self.encoded.clear_region(c) }
    fn size(&self) -> io::Result<Size> { self.encoded.size() }
    fn window_size(&mut self) -> io::Result<WindowSize> { self.encoded.window_size() }
    fn flush(&mut self) -> io::Result<()> {
        let mut encoded = self.bytes.0.borrow_mut();
        let mut frame = Vec::with_capacity(encoded.len() + 40);
        // DEC synchronized output is ignored by older terminals; buffering
        // and hiding the cursor still prevent exposing intermediate positions.
        frame.extend_from_slice(b"\x1b[?2026h\x1b[?25l");
        frame.append(&mut encoded);
        if self.cursor_visible { frame.extend_from_slice(b"\x1b[?25h"); }
        frame.extend_from_slice(b"\x1b[?2026l");
        self.out.write_all(&frame)?;
        self.out.flush()
    }
}

pub(super) struct TerminalOutput {
    terminal: ratatui::Terminal<AtomicBackend<io::Stdout>>,
    links: Rc<RefCell<LinkState>>,
}

impl TerminalOutput {
    pub fn init() -> io::Result<Self> {
        // Install Ratatui's panic restoration and enter raw/alternate screen.
        let _ = ratatui::try_init()?;
        let links = Rc::new(RefCell::new(LinkState::default()));
        let terminal = ratatui::Terminal::new(AtomicBackend::new(io::stdout(), links.clone()))?;
        Ok(Self { terminal, links })
    }

    pub fn draw(&mut self, app: &mut App) -> io::Result<()> {
        let links = &self.links;
        self.terminal.draw(|f| {
            super::render::draw(f, app);
            links.borrow_mut().prepare(&app.link_cells, f.buffer_mut());
        })?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::{layout::Rect, style::{Color, Style}};

    #[derive(Default)]
    struct RecordingWriter { bytes: Vec<u8>, writes: usize, flushes: usize }
    impl Write for RecordingWriter {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            self.writes += 1;
            self.bytes.extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> io::Result<()> { self.flushes += 1; Ok(()) }
    }

    fn link(href: &str) -> LinkCell {
        LinkCell { x: 1, y: 1, text: "src/main.rs".into(), href: href.into() }
    }

    #[test]
    fn unchanged_links_emit_nothing_during_typing_and_cursor_is_last() {
        let links = Rc::new(RefCell::new(LinkState::default()));
        let mut backend = AtomicBackend::new(RecordingWriter::default(), links.clone());
        let empty = Buffer::empty(Rect::new(0, 0, 40, 5));
        let mut screen = empty.clone();
        screen.set_string(1, 1, "src/main.rs", Style::default());
        links.borrow_mut().prepare(&[link("file:///src/main.rs")], &screen);
        backend.draw(empty.diff(&screen).into_iter()).unwrap();
        backend.show_cursor().unwrap();
        backend.set_cursor_position((3, 4)).unwrap();
        assert!(backend.out.bytes.is_empty(), "no intermediate cursor/flush may reach stdout");
        Backend::flush(&mut backend).unwrap();
        let first = String::from_utf8(backend.out.bytes.clone()).unwrap();
        assert!(first.starts_with("\x1b[?2026h\x1b[?25l"));
        assert!(first.ends_with("\x1b[5;4H\x1b[?25h\x1b[?2026l"));
        assert_eq!(first.matches("src/main.rs").count(), 2, "one href and one text, no second paint");
        assert_eq!((backend.out.writes, backend.out.flushes), (1, 1));

        let previous = screen.clone();
        screen.set_string(3, 4, "x", Style::default());
        links.borrow_mut().prepare(&[link("file:///src/main.rs")], &screen);
        backend.out.bytes.clear();
        backend.draw(previous.diff(&screen).into_iter()).unwrap();
        backend.set_cursor_position((4, 4)).unwrap();
        Backend::flush(&mut backend).unwrap();
        let typed = String::from_utf8(backend.out.bytes.clone()).unwrap();
        assert!(!typed.contains("src/main.rs"));
        assert!(!typed.contains("\x1b]8;"));
        assert!(!typed.contains("\x1b[2;"), "cursor must never visit the unchanged transcript");
    }

    #[test]
    fn href_changes_and_removal_are_diffed_even_when_text_is_identical() {
        let links = Rc::new(RefCell::new(LinkState::default()));
        let mut backend = AtomicBackend::new(Vec::new(), links.clone());
        let mut screen = Buffer::empty(Rect::new(0, 0, 40, 5));
        screen.set_string(1, 1, "src/main.rs", Style::default().fg(Color::Red));
        for href in ["file:///one", "file:///two"] {
            links.borrow_mut().prepare(&[link(href)], &screen);
            backend.draw(std::iter::empty()).unwrap();
            Backend::flush(&mut backend).unwrap();
            let output = String::from_utf8(std::mem::take(&mut backend.out)).unwrap();
            assert!(output.contains(href));
            assert!(output.contains("src/main.rs"));
        }
        links.borrow_mut().prepare(&[], &screen);
        backend.draw(std::iter::empty()).unwrap();
        Backend::flush(&mut backend).unwrap();
        let output = String::from_utf8(backend.out).unwrap();
        assert!(output.contains("src/main.rs"));
        assert!(!output.contains("\x1b]8;"));
    }

    #[test]
    fn link_styles_come_from_final_cells_and_wide_continuations_are_not_repainted() {
        let links = Rc::new(RefCell::new(LinkState::default()));
        let mut screen = Buffer::empty(Rect::new(0, 0, 40, 5));
        screen.set_string(1, 1, "src/main.rs", Style::default());
        screen[(2, 1)].set_bg(Color::Blue);
        links.borrow_mut().prepare(&[link("file:///one")], &screen);
        assert_eq!(links.borrow().forced[&(1, 2)].bg, Color::Blue);
        let mut next = screen.clone();
        next.set_string(0, 1, "界", Style::default());
        links.borrow_mut().prepare(&[], &next);
        assert!(!links.borrow().forced.contains_key(&(1, 1)));
    }
}
