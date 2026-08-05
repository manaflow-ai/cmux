use std::io::{self, IsTerminal};

use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use ratatui::{
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
};

use crate::cli::Error;
use crate::oauth::Provider;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AddChoice {
    Provider(Provider),
    Cancel,
}

const ITEMS: &[(AddChoice, &str, &str)] = &[
    (
        AddChoice::Provider(Provider::Codex),
        "Codex / ChatGPT Plus or Pro",
        "Authorize directly with OpenAI using OAuth and PKCE.",
    ),
    (
        AddChoice::Provider(Provider::OpenCodeGo),
        "OpenCode Go",
        "Connect your OpenCode Console subscription using device authorization.",
    ),
    (AddChoice::Cancel, "Cancel", "Make no changes."),
];

pub fn choose_add_action() -> Result<AddChoice, Error> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(Error::Usage(
            "`cr add` needs an interactive terminal; use `cr add codex` or `cr add opencode`"
                .into(),
        ));
    }
    crossterm::terminal::enable_raw_mode()?;
    let backend = CrosstermBackend::new(io::stdout());
    let options = ratatui::TerminalOptions {
        viewport: ratatui::Viewport::Inline(12),
    };
    let mut terminal = Terminal::with_options(backend, options)?;
    let result = choose(&mut terminal);
    let restore = crossterm::terminal::disable_raw_mode();
    terminal.show_cursor()?;
    println!();
    restore?;
    result
}

fn choose(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>) -> Result<AddChoice, Error> {
    let mut state = ListState::default().with_selected(Some(0));
    loop {
        terminal.draw(|frame| draw_add(frame, &mut state))?;
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        let selected = state.selected().unwrap_or(0);
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                state.select(Some(selected.checked_sub(1).unwrap_or(ITEMS.len() - 1)));
            }
            KeyCode::Down | KeyCode::Char('j') => {
                state.select(Some((selected + 1) % ITEMS.len()));
            }
            KeyCode::Char('1') => return Ok(ITEMS[0].0),
            KeyCode::Char('2') => return Ok(ITEMS[1].0),
            KeyCode::Enter => return Ok(ITEMS[selected].0),
            KeyCode::Esc | KeyCode::Char('q') => return Ok(AddChoice::Cancel),
            _ => {}
        }
    }
}

fn draw_add(frame: &mut ratatui::Frame<'_>, state: &mut ListState) {
    let [header, choices, footer] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Length(7),
        Constraint::Length(2),
    ])
    .areas(frame.area());
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                "Add a subscription",
                Style::default().add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(
                "Credentials go directly to your team’s Stack vault.",
                Style::default().fg(Color::DarkGray),
            )),
        ]),
        header,
    );
    let rows = ITEMS.iter().map(|(_, title, detail)| {
        ListItem::new(vec![
            Line::from(*title),
            Line::from(Span::styled(
                format!("  {detail}"),
                Style::default().fg(Color::DarkGray),
            )),
        ])
    });
    frame.render_stateful_widget(
        List::new(rows)
            .block(Block::default().borders(Borders::NONE))
            .highlight_symbol("› ")
            .highlight_style(
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
        choices,
        state,
    );
    frame.render_widget(
        Paragraph::new(Span::styled(
            "↑/↓ move  enter select  esc cancel",
            Style::default().fg(Color::DarkGray),
        )),
        footer,
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    #[test]
    fn add_screen_names_only_supported_subscriptions() {
        let backend = TestBackend::new(80, 12);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut state = ListState::default().with_selected(Some(0));
        terminal.draw(|frame| draw_add(frame, &mut state)).unwrap();
        let screen = terminal.backend().to_string();
        assert!(screen.contains("Codex / ChatGPT Plus or Pro"));
        assert!(screen.contains("OpenCode Go"));
        assert!(!screen.contains("Claude"));
        assert!(screen.contains("Stack vault"));
    }
}
