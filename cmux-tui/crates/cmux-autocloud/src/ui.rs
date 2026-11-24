//! Drawing: the full-screen view (header with readiness, the chat, the prompt) and the plain
//! line printer for a pipe or a link too poor for a full screen.

use std::io::Write;

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Gauge, Paragraph};

use crate::App;
use crate::link::Spec;
use crate::readiness::Phase;
use crate::transcript::Item;

const SPIN: [&str; 4] = ["◐", "◓", "◑", "◒"];

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
            format!("{} {}", SPIN[(app.ticks % 4) as usize], app.readiness.label()),
            Style::new().fg(Color::Yellow),
        )
    } else {
        Span::styled(format!("○ {}", app.link_note), Style::new().fg(Color::Red))
    };
    let agent = match app.transcript.status.as_str() {
        "running" => Span::styled(
            format!(" {} working", SPIN[(app.ticks % 4) as usize]),
            Style::new().fg(Color::Cyan),
        ),
        "" => Span::raw(""),
        s => Span::styled(format!(" {s}"), Style::new().dim()),
    };
    let session = app.session.as_deref().map(short).unwrap_or("new chat");
    let mut spans = vec![
        Span::styled(" cmux autocloud ", Style::new().bold().reversed()),
        Span::raw(format!(" {} · {} · ", app.spec.describe(), session)),
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
        Layout::vertical([Constraint::Length(1), Constraint::Length(header_h - 1)]).areas(header);
    f.render_widget(Paragraph::new(Line::from(spans)), top);
    if !ready {
        let pct = app.readiness.percent();
        let gauge = Gauge::default()
            .gauge_style(Style::new().fg(Color::Cyan).bg(Color::DarkGray))
            .percent(u16::from(pct))
            .label(format!("readiness {pct} · {}", app.readiness.label()));
        f.render_widget(gauge, bar);
    }

    // The chat, wrapped by hand so the bottom stays in view.
    let width = body.width.max(10) as usize;
    let mut lines: Vec<Line> = Vec::new();
    for item in &app.transcript.items {
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
    if app.transcript.items.is_empty() && app.live() {
        lines.push(Line::styled("  Say something to the agent below.", Style::new().dim()));
    }
    let height = body.height as usize;
    let end = lines.len().saturating_sub(app.scroll as usize);
    let start = end.saturating_sub(height);
    f.render_widget(Paragraph::new(lines[start..end].to_vec()), body);

    // The prompt. Typing works while the link is down: it goes out on reconnect.
    let title = if app.live() {
        " message · Enter send · PgUp/PgDn scroll · Ctrl-C quit "
    } else {
        " message (sends when the link is back) "
    };
    let prompt = Paragraph::new(format!("{}▏", app.input)).block(
        Block::default().borders(Borders::ALL).title(title).border_style(Style::new().dim()),
    );
    f.render_widget(prompt, input);
}

fn short(id: &str) -> &str {
    &id[..id.len().min(8)]
}

/// Splits on newlines, then cuts each line at `width` chars (at a space when there is one).
fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    for raw in text.trim_end().split('\n') {
        let chars: Vec<char> = raw.chars().collect();
        if chars.is_empty() {
            out.push(String::new());
            continue;
        }
        let mut i = 0;
        while i < chars.len() {
            let mut end = (i + width).min(chars.len());
            // Cut at the last space in the window, unless the window already ends on one.
            if end < chars.len()
                && chars[end] != ' '
                && let Some(sp) = chars[i..end].iter().rposition(|c| *c == ' ')
                && sp > 0
            {
                end = i + sp + 1;
            }
            out.push(chars[i..end].iter().collect::<String>().trim_end().to_owned());
            i = end;
            while i < chars.len() && chars[i] == ' ' {
                i += 1;
            }
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
            self.items += 1;
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
        while self.items < items.len() {
            let i = self.items;
            let last = i + 1 == items.len();
            let (head, text) = match &items[i] {
                Item::User(t) => ("> ", t.as_str()),
                Item::Assistant(t) => ("", t.as_str()),
                Item::Thought(_) => {
                    self.items += 1;
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
            if last && matches!(items[i], Item::Assistant(_)) {
                self.tail = text.len();
                break;
            }
            let _ = writeln!(out);
            self.items += 1;
            self.tail = 0;
        }
        let _ = out.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::wrap;

    #[test]
    fn wraps_at_spaces_and_keeps_blank_lines() {
        assert_eq!(wrap("hello there world", 11), vec!["hello there", "world"]);
        assert_eq!(wrap("a\n\nb", 5), vec!["a", "", "b"]);
        assert_eq!(wrap("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
    }
}
