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
    let mut chat = Chat {
        hyperlinks: super::hyperlink::enabled(),
        chief: session.chief.clone(),
        ..Chat::default()
    };
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
                    let refused = super::registry::agent_control_refusal("Ctrl+C", "stop");
                    let note = match chat.busy.then(|| refused.is_none().then(|| session.stop())) {
                        Some(None) => agent_note(refused.as_ref()),
                        None => m.stop_idle.to_owned(),
                        Some(Some(Ok(true))) => m.stop_sent.to_owned(),
                        Some(Some(Ok(false))) => m.stop_idle.to_owned(),
                        Some(Some(Err(error))) => super::control::refusal(&error),
                    };
                    lines.extend(chat.note(&note));
                }
                EditorAction::Submit(text) => {
                    if let Some(command) = text.trim().strip_prefix('/') {
                        match slash(command, &mut chat, &mut session) {
                            Slash::Quit => break,
                            Slash::Note(note) if note.is_empty() => {}
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

/// The chat note of an agent-caller refusal: its message.
fn agent_note(refusal: Option<&serde_json::Value>) -> String {
    refusal
        .and_then(|value| value.get("message"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// A `/command` typed in the chat.
pub(super) fn slash(command: &str, chat: &mut Chat, session: &mut Session) -> Slash {
    let m = messages();
    let name = command.split_whitespace().next().unwrap_or("");
    match name {
        "quit" | "exit" | "q" => Slash::Quit,
        "help" | "?" => {
            Slash::Note(format!("{}\n{}", m.help, super::script_text::text().chat_help))
        }
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
            if !changes.is_empty()
                && let Some(refusal) =
                    super::registry::agent_control_refusal(&format!("/{name}"), "engine")
            {
                return Slash::Note(agent_note(Some(&refusal)));
            }
            Slash::Note(match session.engine(&changes) {
                Ok(report) => super::control::engine_line(&report),
                Err(error) => super::control::refusal(&error),
            })
        }
        "chats" | "open" | "reply" | "react" | "unreact" | "thread" | "attach" | "edit"
        | "retract" | "new" => {
            let rest = command.get(name.len()..).unwrap_or_default().trim();
            Slash::Note(match home_command(name, rest, chat, session) {
                Ok(note) | Err(note) => note,
            })
        }
        _ => Slash::Note(m.unknown_command.replace("{command}", &format!("/{name}"))),
    }
}

/// The Home commands of the chat (plans/cmux-next/chief-tui.md): chats,
/// replies, reactions, threads, attachments, edits and new Chiefs. The
/// answer is a note line; a sent or changed message also shows when its
/// event comes back.
fn home_command(
    name: &str,
    rest: &str,
    chat: &mut Chat,
    session: &mut Session,
) -> Result<String, String> {
    use super::script::{MessageRef, parse_ref, reaction_kind};
    let t = super::script_text::text();
    let refused = |e: LinkError| e.to_string();
    let (first, tail) = rest.split_once(char::is_whitespace).unwrap_or((rest, ""));
    let tail = tail.trim();
    // `#SEQ` (or a message id) to the message's id, from the messages shown.
    let id_of =
        |chat: &Chat, session: &mut Session, word: &str| -> Result<(String, u64, u32), String> {
            let (reference, part) = parse_ref(word)?;
            let part = part.unwrap_or(0);
            match reference {
                MessageRef::Id(id) => {
                    let seq = chat.seqs.get(&id).copied().unwrap_or(0);
                    Ok((id, seq, part))
                }
                MessageRef::Seq(seq) => {
                    if let Some((id, _)) = chat.seqs.iter().find(|(_, s)| **s == seq) {
                        return Ok((id.clone(), seq, part));
                    }
                    let conversation = session.conversation.clone();
                    let page =
                        session.client.history(&conversation, seq + 1, 1).map_err(refused)?;
                    page.iter()
                        .find(|m| m.get("seq").and_then(serde_json::Value::as_u64) == Some(seq))
                        .and_then(|m| m.get("id").and_then(serde_json::Value::as_str))
                        .map(|id| (id.to_owned(), seq, part))
                        .ok_or_else(|| t.no_seq.replace("{seq}", &seq.to_string()))
                }
            }
        };
    let conversation = session.conversation.clone();
    match name {
        "chats" => {
            let rows =
                super::script::chat_rows(session, Some(&conversation)).map_err(|(_, e)| e)?;
            chat.listed = rows
                .iter()
                .filter_map(|r| r.get("id").and_then(serde_json::Value::as_str).map(str::to_owned))
                .collect();
            if rows.is_empty() {
                return Ok(t.no_chats.into());
            }
            let lines: Vec<String> = rows
                .iter()
                .enumerate()
                .map(|(i, row)| super::script::chat_row_text(i + 1, row))
                .collect();
            Ok(lines.join("\n"))
        }
        "open" => {
            let wanted = match rest.parse::<usize>() {
                Ok(n) if n >= 1 => {
                    chat.listed.get(n - 1).cloned().unwrap_or_else(|| rest.to_owned())
                }
                _ => rest.to_owned(),
            };
            let wanted = (!wanted.is_empty()).then_some(wanted);
            session.open_chat(wanted.as_deref(), 20).map_err(|(_, e)| e)?;
            // A new chat: what was shown belongs to the old one.
            let listed = std::mem::take(&mut chat.listed);
            *chat = Chat {
                width: chat.width,
                hyperlinks: chat.hyperlinks,
                show_thoughts: chat.show_thoughts,
                chief: session.chief.clone(),
                listed,
                ..Chat::default()
            };
            let title =
                session.summary.get("title").and_then(serde_json::Value::as_str).unwrap_or("");
            Ok(t.opened
                .replace("{title}", title)
                .replace("{id}", &session.conversation)
                .replace("{owner}", session.client.owner.name()))
        }
        "reply" => {
            let (id, _, part) = id_of(chat, session, first)?;
            if tail.is_empty() {
                return Err(t.needs_text.into());
            }
            let reply_to = serde_json::json!({"message_id": id, "part_index": part});
            let parts = vec![serde_json::json!({"type": "text", "text": tail})];
            session.send_parts(parts, Some(reply_to), None).map_err(refused)?;
            Ok(String::new())
        }
        "react" | "unreact" => {
            let (id, seq, part) = id_of(chat, session, first)?;
            let kind = reaction_kind(tail)?;
            let op_kind = if name == "react" { "reaction.add" } else { "reaction.remove" };
            let op = serde_json::json!({"kind": op_kind, "message_id": id, "part_index": part, "reaction": kind});
            session
                .client
                .op(&conversation, &super::link::new_message_id(), op)
                .map_err(refused)?;
            let template = if name == "react" { t.reacted } else { t.unreacted };
            Ok(template.replace("{reaction}", tail).replace("{seq}", &seq.to_string()))
        }
        "thread" => {
            let (id, seq, part) = id_of(chat, session, first)?;
            if !tail.is_empty() {
                // `/thread #SEQ TEXT`: a reply in that message's thread.
                let reply_to = serde_json::json!({"message_id": id, "part_index": part});
                let parts = vec![serde_json::json!({"type": "text", "text": tail})];
                // A message that is itself a thread reply keeps its own root (the
                // owner gives a reply to it that root when none is sent).
                match session.send_parts(parts.clone(), Some(reply_to.clone()), Some(&id)) {
                    Err(LinkError::Rejected { message, .. })
                        if message.contains("invalid_thread_root") =>
                    {
                        session.send_parts(parts, Some(reply_to), None).map_err(refused)?;
                    }
                    other => {
                        other.map_err(refused)?;
                    }
                }
                return Ok(String::new());
            }
            let thread = session.client.thread(&conversation, &id).map_err(refused)?;
            let replies = thread
                .get("replies")
                .and_then(serde_json::Value::as_array)
                .cloned()
                .unwrap_or_default();
            if replies.is_empty() {
                return Ok(t.thread_empty.replace("{seq}", &seq.to_string()));
            }
            let lines: Vec<String> = replies
                .iter()
                .map(|m| {
                    let who = super::render::author_name(m, &chat.participants);
                    let n = m.get("seq").and_then(serde_json::Value::as_u64).unwrap_or(0);
                    let text = super::render::message_text(m);
                    format!("#{n} {who}: {}", text.lines().next().unwrap_or(""))
                })
                .collect();
            Ok(lines.join("\n"))
        }
        "attach" => {
            if first.is_empty() {
                return Err(t.needs_text.into());
            }
            let path = std::path::PathBuf::from(first);
            let mut parts = vec![session.client.upload(&conversation, &path)?];
            if !tail.is_empty() {
                parts.push(serde_json::json!({"type": "text", "text": tail}));
            }
            session.send_parts(parts, None, None).map_err(refused)?;
            Ok(String::new())
        }
        "edit" | "retract" => {
            let (id, seq, _) = id_of(chat, session, first)?;
            let op = if name == "edit" {
                if tail.is_empty() {
                    return Err(t.needs_text.into());
                }
                serde_json::json!({"kind": "message.edit", "message_id": id,
                                   "parts": [{"type": "text", "text": tail}]})
            } else {
                serde_json::json!({"kind": "message.retract", "message_id": id})
            };
            session
                .client
                .op(&conversation, &super::link::new_message_id(), op)
                .map_err(refused)?;
            let template = if name == "edit" { t.edited } else { t.retracted };
            Ok(template.replace("{seq}", &seq.to_string()))
        }
        "new" => {
            if rest.is_empty() {
                return Err(t.needs_text.into());
            }
            let key = super::link::new_message_id();
            let created = session
                .client
                .link
                .call("chief.profile.create", serde_json::json!({"display_name": rest}), Some(&key))
                .map_err(refused)?;
            let record = created.get("value").cloned().unwrap_or_default();
            let id = record.get("id").and_then(serde_json::Value::as_str).unwrap_or("").to_owned();
            Ok(t.chief_no_chat.replace("{name}", rest).replace("{id}", &id))
        }
        _ => Err(String::new()),
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
        if *style == Style::Linked {
            // Wrapped to the width when the message came; its escapes take no columns.
            let _ = queue!(out, Print(text));
            return;
        }
        let text = clip(text, self.width.saturating_sub(1));
        let _ = match style {
            Style::Plain | Style::Linked => queue!(out, Print(text)),
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
pub(super) fn clip(text: &str, width: usize) -> String {
    let mut used = 0;
    text.chars()
        .take_while(|c| {
            used += c.width().unwrap_or(0);
            used <= width
        })
        .collect()
}
