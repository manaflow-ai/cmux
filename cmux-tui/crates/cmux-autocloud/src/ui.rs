//! Drawing: the full-screen view (header with readiness, the chat, the prompt) and the plain
//! line printer for a pipe or a link too poor for a full screen.

use std::io::Write;

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Gauge, Paragraph};

use crate::App;
use crate::link::Spec;
use crate::readiness::Phase;
use crate::transcript::{Item, Transcript};

const SPIN: [&str; 4] = ["◐", "◓", "◑", "◒"];

fn spin(ticks: u64) -> &'static str {
    let i = usize::try_from(ticks % 4).unwrap_or_default();
    SPIN.get(i).copied().unwrap_or("◐")
}

/// The flags that reach this chat's machine again, for the "continue" hint.
pub fn link_flags(spec: &Spec) -> String {
    match spec {
        Spec::Local => String::new(),
        Spec::Ssh(h) => format!(" --host {h}"),
        Spec::Machine(m) => format!(" --machine {m}"),
        Spec::Via(c) => format!(" --via '{c}'"),
    }
}

pub fn draw(f: &mut Frame, app: &App) {
    let ready = app.readiness.percent() >= 100;
    let header_h = if ready { 1 } else { 2 };
    let [header, body, input] =
        Layout::vertical([Constraint::Length(header_h), Constraint::Min(1), Constraint::Length(3)])
            .areas(f.area());

    // Header: where, what state, how ready.
    let link_state = if app.live() {
        Span::styled("● live", Style::new().fg(Color::Green))
    } else if app.link_note.is_empty() {
        Span::styled(
            format!("{} {}", spin(app.ticks), app.readiness.label()),
            Style::new().fg(Color::Yellow),
        )
    } else {
        Span::styled(format!("○ {}", app.link_note), Style::new().fg(Color::Red))
    };
    let agent = match app.transcript.status.as_str() {
        "running" => {
            Span::styled(format!(" {} working", spin(app.ticks)), Style::new().fg(Color::Cyan))
        }
        "" => Span::raw(""),
        s => Span::styled(format!(" {s}"), Style::new().dim()),
    };
    let session = app.session.as_deref().map(short).unwrap_or("new chat");
    let mut spans = vec![
        Span::styled(" cmux autocloud ", Style::new().bold().reversed()),
        Span::raw(format!(" {} · {} · ", app.spec.describe(), session)),
        Span::raw(if app.sides.is_empty() {
            String::new()
        } else {
            format!("{} chats · ", app.sides.len().saturating_add(1))
        }),
        link_state,
        agent,
    ];
    if app.reconnects > 0 {
        spans.push(Span::styled(format!("  ↻{}", app.reconnects), Style::new().dim()));
    }
    if ready {
        spans.push(Span::styled("  ready 100", Style::new().fg(Color::Green).dim()));
    }
    let [top, bar] =
        Layout::vertical([Constraint::Length(1), Constraint::Length(header_h.saturating_sub(1))])
            .areas(header);
    f.render_widget(Paragraph::new(Line::from(spans)), top);
    if !ready {
        let pct = app.readiness.percent();
        let gauge = Gauge::default()
            .gauge_style(Style::new().fg(Color::Cyan).bg(Color::DarkGray))
            .percent(u16::from(pct))
            .label(format!("readiness {pct} · {}", app.readiness.label()));
        f.render_widget(gauge, bar);
    }

    // The chats: one fills the body; several share it in columns (RFD 0139 "several chats in one
    // view"), the focused one framed in color and taking the prompt.
    if app.sides.is_empty() {
        draw_chat(f, body, &app.transcript, app.scroll, app.live());
    } else {
        let all = app.sides.len().saturating_add(1);
        let first = window_start(all, app.focus, MAX_COLUMNS);
        let shown = all.min(MAX_COLUMNS);
        let columns = Layout::horizontal(vec![Constraint::Fill(1); shown]).split(body);
        for (col, area) in columns.iter().enumerate() {
            let at = first.saturating_add(col);
            let (transcript, title) = match at.checked_sub(1) {
                None => (&app.transcript, app.session.as_deref().map(short).unwrap_or("new chat")),
                Some(i) => match app.sides.get(i) {
                    Some(side) => (&side.transcript, short(&side.session)),
                    None => continue,
                },
            };
            let focused = at == app.focus;
            let style = if focused { Style::new().fg(Color::Cyan) } else { Style::new().dim() };
            let status = match transcript.status.as_str() {
                "running" => format!(" {} working", spin(app.ticks)),
                _ => String::new(),
            };
            let block = Block::default()
                .borders(Borders::ALL)
                .title(format!(" {} {title}{status} ", at.saturating_add(1)))
                .border_style(style);
            let inner = block.inner(*area);
            f.render_widget(block, *area);
            let scroll = if focused { app.scroll } else { 0 };
            draw_chat(f, inner, transcript, scroll, app.live());
        }
    }

    // The prompt. Typing works while the link is down: it goes out on reconnect.
    let title = if !app.live() {
        " message (sends when the link is back) ".to_owned()
    } else if app.sides.is_empty() {
        " message · Enter send · Ctrl-N another chat · PgUp/PgDn scroll · Ctrl-C quit ".to_owned()
    } else {
        format!(
            " message to chat {} · Tab next chat · Ctrl-N another · Ctrl-W close · Ctrl-C quit ",
            app.focus.saturating_add(1)
        )
    };
    let prompt = Paragraph::new(format!("{}▏", app.input)).block(
        Block::default().borders(Borders::ALL).title(title).border_style(Style::new().dim()),
    );
    f.render_widget(prompt, input);
}

/// The most chats drawn side by side; past it the view follows the focus.
const MAX_COLUMNS: usize = 4;

/// The first chat drawn when `all` chats share `columns` columns and `focus` must be in view.
pub fn window_start(all: usize, focus: usize, columns: usize) -> usize {
    let columns = columns.max(1);
    if all <= columns {
        return 0;
    }
    focus.saturating_add(1).saturating_sub(columns).min(all.saturating_sub(columns))
}

/// One chat's transcript, wrapped by hand so the bottom stays in view.
fn draw_chat(f: &mut Frame, body: Rect, transcript: &Transcript, scroll: u16, live: bool) {
    let width = body.width.max(10) as usize;
    let mut lines: Vec<Line> = Vec::new();
    for item in &transcript.items {
        let (prefix, style, text) = match item {
            Item::User(t) => {
                ("› ", Style::new().fg(Color::Magenta).add_modifier(Modifier::BOLD), t.clone())
            }
            Item::Assistant(t) => ("  ", Style::new(), t.clone()),
            Item::Thought(t) => ("  ", Style::new().dim().italic(), t.clone()),
            Item::Tool { title, status, .. } => {
                let mark = match status.as_str() {
                    "completed" => "✓",
                    "failed" => "✗",
                    _ => "…",
                };
                ("  ", Style::new().fg(Color::Blue), format!("{mark} {title}"))
            }
            Item::Note(t) => ("  ", Style::new().fg(Color::Yellow), t.clone()),
        };
        for (i, row) in wrap(&text, width.saturating_sub(2)).into_iter().enumerate() {
            let lead = if i == 0 { prefix } else { "  " };
            lines.push(Line::from(vec![Span::styled(lead, style), Span::styled(row, style)]));
        }
        lines.push(Line::raw(""));
    }
    if transcript.items.is_empty() && live {
        lines.push(Line::styled("  Say something to the agent below.", Style::new().dim()));
    }
    let height = body.height as usize;
    let end = lines.len().saturating_sub(scroll as usize);
    let start = end.saturating_sub(height);
    f.render_widget(
        Paragraph::new(lines.get(start..end).map(<[_]>::to_vec).unwrap_or_default()),
        body,
    );
}

fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

/// Splits on newlines, then cuts each line at `width` chars (at a space when there is one).
fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    for raw in text.trim_end().split('\n') {
        if raw.is_empty() {
            out.push(String::new());
            continue;
        }
        let mut rest: Vec<char> = raw.chars().collect();
        while !rest.is_empty() {
            let mut end = width.min(rest.len());
            // Cut at the last space in the window, unless the window already ends on one.
            if let (Some(next), Some(window)) = (rest.get(end), rest.get(..end))
                && *next != ' '
                && let Some(sp) = window.iter().rposition(|c| *c == ' ')
                && sp > 0
            {
                end = sp.saturating_add(1);
            }
            let tail = rest.split_off(end);
            out.push(rest.iter().collect::<String>().trim_end().to_owned());
            rest = tail.into_iter().skip_while(|c| *c == ' ').collect();
        }
    }
    out
}

/// Plain mode: prints what is new since the last flush, streaming the agent's text as it grows.
#[derive(Default)]
pub struct Printer {
    items: usize,
    /// Bytes of the last item's text already printed (it may still grow).
    tail: usize,
    phase_shown: Option<Phase>,
    reconnects: u64,
}

impl Printer {
    /// Ends the open line, if any, before the process prints anything else.
    pub fn finish(&mut self) {
        if self.tail > 0 {
            println!();
            self.tail = 0;
            self.items = self.items.saturating_add(1);
        }
    }

    pub fn flush(&mut self, app: &App) {
        let mut out = std::io::stdout().lock();
        if self.phase_shown != Some(app.readiness.phase) && app.live() {
            let _ = writeln!(
                out,
                "[{} · readiness {} · {}]",
                app.spec.describe(),
                app.readiness.percent(),
                app.readiness.label()
            );
            self.phase_shown = Some(app.readiness.phase);
        }
        if app.reconnects != self.reconnects {
            let _ = writeln!(out, "\n[link back after {} drop(s)]", app.reconnects);
            self.reconnects = app.reconnects;
        }
        let items = &app.transcript.items;
        while let Some(item) = items.get(self.items) {
            let last = self.items.saturating_add(1) == items.len();
            let (head, text) = match item {
                Item::User(t) => ("> ", t.as_str()),
                Item::Assistant(t) => ("", t.as_str()),
                Item::Thought(_) => {
                    self.items = self.items.saturating_add(1);
                    continue;
                }
                Item::Tool { title, .. } => ("  · ", title.as_str()),
                Item::Note(t) => ("  ! ", t.as_str()),
            };
            if self.tail == 0 {
                let _ = write!(out, "{head}");
            }
            let _ = write!(out, "{}", text.get(self.tail..).unwrap_or(""));
            // The agent's text may still grow; hold the item open until something follows it.
            if last && matches!(item, Item::Assistant(_)) {
                self.tail = text.len();
                break;
            }
            let _ = writeln!(out);
            self.items = self.items.saturating_add(1);
            self.tail = 0;
        }
        let _ = out.flush();
    }
}

#[cfg(test)]
#[path = "ui_tests.rs"]
mod tests;
