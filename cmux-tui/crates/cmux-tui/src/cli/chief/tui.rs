//! The chat on a terminal, inline: finished messages go into the terminal's
//! own scrollback, and a footer (live reply, status, input, hint) is drawn
//! again under them on every change. No alternate screen, so the chat stays
//! in the scrollback after the chat ends.

use std::io::{self, Write};

use crossterm::event::{DisableBracketedPaste, EnableBracketedPaste, Event};
use crossterm::style::{Attribute, Print, SetAttribute};
use crossterm::terminal::{self, Clear, ClearType};
use crossterm::{cursor, queue};
use unicode_width::UnicodeWidthChar;

use super::adapter::adapt;
use super::chat::{Chat, Line, Style};
use super::editor::{Editor, EditorAction};
use super::link::LinkError;
use super::messages::messages;
use super::{Input, Session};

pub(super) fn run(mut session: Session) -> i32 {
    let mut chat = Chat::default();
    let mut editor = Editor::default();
    let mut screen = match Screen::open() {
        Ok(screen) => screen,
        Err(error) => {
            eprintln!("cmux: {error}");
            return 3;
        }
    };
    chat.width = screen.width;
    let lines: Vec<Line> = Vec::new();
    let tx = session.tx.clone();
    let _ = std::thread::Builder::new().name("chief-keys".into()).spawn(move || {
        while let Ok(event) = crossterm::event::read() {
            if tx.send(Input::Term(event)).is_err() {
                return;
            }
        }
    });
    screen.paint(&lines, &chat, &editor);
    let mut code = 0;
    while let Ok(input) = session.rx.recv() {
        let mut lines: Vec<Line> = Vec::new();
        match input {
            Input::Closed(reason) if reason == "gap" && session.reopen(50).is_ok() => {
                // Typing and drafts are live only: forget what the gap hid.
                chat.busy = false;
                chat.drafts = super::adapter::Drafts::default();
            }
            Input::Closed(_) => {
                lines.extend(chat.note(messages().lost));
                screen.paint(&lines, &chat, &editor);
                code = 3;
                break;
            }
            Input::Daemon(line) => {
                if let Some(event) = adapt(&line, &session.conversation) {
                    // A snapshot after a gap may start past what was shown.
                    if let super::adapter::UiEvent::Snapshot { messages, .. } = &event
                        && let Some(first) = messages.first().and_then(|m| m["seq"].as_u64())
                        && chat.last_seq != 0
                        && first > chat.last_seq + 1
                    {
                        lines.extend(catch_up(&mut session, &mut chat, first));
                    }
                    let (done, gap) = chat.apply(&event);
                    lines.extend(done);
                    if let Some(seq) = gap {
                        lines.extend(catch_up(&mut session, &mut chat, seq));
                        if let super::adapter::UiEvent::Message(message) = &event {
                            lines.extend(chat.message(message));
                        }
                    }
                }
            }
            Input::Term(Event::Resize(width, _)) => {
                screen.width = width as usize;
                chat.width = width as usize;
            }
            Input::Term(Event::Paste(text)) => editor.insert(&text),
            Input::Term(Event::Key(key)) => match editor.key(key) {
                EditorAction::None => {}
                EditorAction::Quit => break,
                EditorAction::Interrupt => {
                    let m = messages();
                    let note = match chat.busy.then(|| session.stop()) {
                        None => m.stop_idle.to_owned(),
                        Some(Ok(true)) => m.stop_sent.to_owned(),
                        Some(Ok(false)) => m.stop_idle.to_owned(),
                        Some(Err(error)) => super::control::refusal(&error),
                    };
                    lines.extend(chat.note(&note));
                }
                EditorAction::Submit(text) => {
                    if let Some(command) = text.trim().strip_prefix('/') {
                        match slash(command, &mut chat, &mut session) {
                            Slash::Quit => break,
                            Slash::Note(note) => lines.extend(chat.note(&note)),
                        }
                    } else if let Err(error) = session.send(&text) {
                        let reason = match error {
                            LinkError::Transport(message) => message,
                            other => messages().rejected.replace("{reason}", &other.to_string()),
                        };
                        lines.extend(chat.note(&reason));
                    }
                }
            },
            Input::Term(_) => {}
        }
        screen.paint(&lines, &chat, &editor);
    }
    screen.close();
    code
}

/// Messages missed before `seq` (a rev gap), fetched and shown in order.
fn catch_up(session: &mut Session, chat: &mut Chat, seq: u64) -> Vec<Line> {
    match session.between(chat.last_seq, seq) {
        Ok(messages) => messages.iter().flat_map(|m| chat.message(m)).collect(),
        Err(error) => chat.note(&error.to_string()),
    }
}

pub(super) enum Slash {
    Quit,
    Note(String),
}

/// A `/command` typed in the chat.
pub(super) fn slash(command: &str, chat: &mut Chat, session: &mut Session) -> Slash {
    let m = messages();
    let name = command.split_whitespace().next().unwrap_or("");
    match name {
        "quit" | "exit" | "q" => Slash::Quit,
        "help" | "?" => Slash::Note(m.help.into()),
        "thoughts" => {
            chat.show_thoughts = !chat.show_thoughts;
            Slash::Note(if chat.show_thoughts { m.thoughts_on } else { m.thoughts_off }.into())
        }
        "model" | "effort" => {
            let changes: Vec<(String, String)> = command
                .split_whitespace()
                .nth(1)
                .map(|value| vec![(name.to_owned(), value.to_owned())])
                .unwrap_or_default();
            Slash::Note(match session.engine(&changes) {
                Ok(report) => super::control::engine_line(&report),
                Err(error) => super::control::refusal(&error),
            })
        }
        _ => Slash::Note(m.unknown_command.replace("{command}", &format!("/{name}"))),
    }
}

/// The terminal in raw mode with the footer drawn at the bottom.
struct Screen {
    width: usize,
    /// The cursor's row inside the drawn footer.
    cursor_row: usize,
    /// The terminal was given back.
    closed: bool,
}

impl Screen {
    fn open() -> io::Result<Self> {
        // A panic gives the terminal back before its message prints.
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            let _ = queue!(io::stdout(), DisableBracketedPaste);
            let _ = io::stdout().flush();
            let _ = terminal::disable_raw_mode();
            previous(info);
        }));
        terminal::enable_raw_mode()?;
        let mut out = io::stdout();
        queue!(out, EnableBracketedPaste)?;
        out.flush()?;
        let width = terminal::size().map(|(w, _)| w as usize).unwrap_or(80);
        Ok(Self { width, cursor_row: 0, closed: false })
    }

    /// Writes `done` into scrollback above the footer, then the footer.
    fn paint(&mut self, done: &[Line], chat: &Chat, editor: &Editor) {
        let height =
            terminal::size().map(|(_, h)| h as usize).unwrap_or(24).saturating_sub(1).max(4);
        let (footer, (row, column)) = chat.footer(editor, self.width, height);
        let mut out = io::stdout().lock();
        let _ = queue!(out, terminal::BeginSynchronizedUpdate, cursor::MoveToColumn(0));
        if self.cursor_row > 0 {
            let _ = queue!(out, cursor::MoveUp(self.cursor_row as u16));
        }
        let _ = queue!(out, Clear(ClearType::FromCursorDown));
        for line in done {
            self.line(&mut out, line);
            let _ = queue!(out, Print("\r\n"));
        }
        for (index, line) in footer.iter().enumerate() {
            self.line(&mut out, line);
            if index + 1 < footer.len() {
                let _ = queue!(out, Print("\r\n"));
            }
        }
        let below = footer.len().saturating_sub(1 + row);
        if below > 0 {
            let _ = queue!(out, cursor::MoveUp(below as u16));
        }
        let _ = queue!(out, cursor::MoveToColumn(column as u16), terminal::EndSynchronizedUpdate);
        let _ = out.flush();
        self.cursor_row = row;
    }

    fn line(&self, out: &mut impl Write, (style, text): &Line) {
        let text = clip(text, self.width.saturating_sub(1));
        let _ = match style {
            Style::Plain => queue!(out, Print(text)),
            Style::Header => queue!(
                out,
                SetAttribute(Attribute::Bold),
                Print(text),
                SetAttribute(Attribute::Reset)
            ),
            Style::Dim => queue!(
                out,
                SetAttribute(Attribute::Dim),
                Print(text),
                SetAttribute(Attribute::Reset)
            ),
        };
    }

    /// Erases the footer and gives the terminal back.
    fn close(&mut self) {
        if self.closed {
            return;
        }
        self.closed = true;
        let mut out = io::stdout();
        let _ = queue!(out, cursor::MoveToColumn(0));
        if self.cursor_row > 0 {
            let _ = queue!(out, cursor::MoveUp(self.cursor_row as u16));
        }
        let _ = queue!(out, Clear(ClearType::FromCursorDown), DisableBracketedPaste);
        let _ = out.flush();
        let _ = terminal::disable_raw_mode();
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        self.close();
    }
}

/// `text` cut to `width` display columns.
fn clip(text: &str, width: usize) -> String {
    let mut used = 0;
    text.chars()
        .take_while(|c| {
            used += c.width().unwrap_or(0);
            used <= width
        })
        .collect()
}
