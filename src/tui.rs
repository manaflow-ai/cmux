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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LoginChoice {
    Browser,
    Code,
    Cancel,
}

#[derive(Clone, Debug)]
pub struct RemoveChoice {
    pub id: String,
    pub label: String,
    pub provider: String,
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

pub fn choose_login_action() -> Result<LoginChoice, Error> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Ok(LoginChoice::Browser);
    }
    crossterm::terminal::enable_raw_mode()?;
    let backend = CrosstermBackend::new(io::stdout());
    let options = ratatui::TerminalOptions {
        viewport: ratatui::Viewport::Inline(11),
    };
    let mut terminal = Terminal::with_options(backend, options)?;
    let result = choose_login(&mut terminal);
    let restore = crossterm::terminal::disable_raw_mode();
    terminal.show_cursor()?;
    println!();
    restore?;
    result
}

pub fn choose_remove_account(accounts: &[RemoveChoice]) -> Result<Option<RemoveChoice>, Error> {
    if accounts.is_empty() {
        return Ok(None);
    }
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(Error::Usage(
            "`cr remove` needs an interactive terminal; pass an account ID or exact label".into(),
        ));
    }
    crossterm::terminal::enable_raw_mode()?;
    let backend = CrosstermBackend::new(io::stdout());
    let height = (accounts.len() as u16 + 6).min(20);
    let options = ratatui::TerminalOptions {
        viewport: ratatui::Viewport::Inline(height),
    };
    let mut terminal = Terminal::with_options(backend, options)?;
    let result = choose_remove(&mut terminal, accounts);
    let restore = crossterm::terminal::disable_raw_mode();
    terminal.show_cursor()?;
    println!();
    restore?;
    result
}

pub fn confirm_remove(label: &str) -> Result<bool, Error> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(Error::Usage(
            "refusing non-interactive removal; run this command in a terminal".into(),
        ));
    }
    print!("Remove {label}? [y/N] ");
    use std::io::Write;
    io::stdout().flush()?;
    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    Ok(matches!(
        answer.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn choose_remove(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    accounts: &[RemoveChoice],
) -> Result<Option<RemoveChoice>, Error> {
    let mut state = ListState::default().with_selected(Some(0));
    loop {
        terminal.draw(|frame| draw_remove(frame, &mut state, accounts))?;
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        let selected = state.selected().unwrap_or(0);
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                state.select(Some(selected.checked_sub(1).unwrap_or(accounts.len() - 1)));
            }
            KeyCode::Down | KeyCode::Char('j') => {
                state.select(Some((selected + 1) % accounts.len()));
            }
            KeyCode::Enter => return Ok(Some(accounts[selected].clone())),
            KeyCode::Esc | KeyCode::Char('q') => return Ok(None),
            _ => {}
        }
    }
}

fn choose_login(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
) -> Result<LoginChoice, Error> {
    let choices = [LoginChoice::Browser, LoginChoice::Code, LoginChoice::Cancel];
    let mut state = ListState::default().with_selected(Some(0));
    loop {
        terminal.draw(|frame| draw_login(frame, &mut state))?;
        let Event::Key(key) = event::read()? else {
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        let selected = state.selected().unwrap_or(0);
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                state.select(Some(selected.checked_sub(1).unwrap_or(choices.len() - 1)));
            }
            KeyCode::Down | KeyCode::Char('j') => {
                state.select(Some((selected + 1) % choices.len()));
            }
            KeyCode::Enter => return Ok(choices[selected]),
            KeyCode::Esc | KeyCode::Char('q') => return Ok(LoginChoice::Cancel),
            _ => {}
        }
    }
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
                "Credentials are encrypted in your coderouter workspace.",
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

fn draw_login(frame: &mut ratatui::Frame<'_>, state: &mut ListState) {
    let [header, choices, footer] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Length(6),
        Constraint::Length(2),
    ])
    .areas(frame.area());
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(Span::styled(
                "Sign in to coderouter",
                Style::default().add_modifier(Modifier::BOLD),
            )),
            Line::from(Span::styled(
                "Choose the flow that works on this machine.",
                Style::default().fg(Color::DarkGray),
            )),
        ]),
        header,
    );
    let rows = [
        ("Open browser", "Authorize this terminal in your browser."),
        (
            "Enter a code",
            "Paste a one-time coderouter sign-in code or magic link.",
        ),
        ("Cancel", "Stay signed out."),
    ]
    .into_iter()
    .map(|(title, detail)| {
        ListItem::new(vec![
            Line::from(title),
            Line::from(Span::styled(
                format!("  {detail}"),
                Style::default().fg(Color::DarkGray),
            )),
        ])
    });
    frame.render_stateful_widget(
        List::new(rows).highlight_symbol("› ").highlight_style(
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

fn draw_remove(frame: &mut ratatui::Frame<'_>, state: &mut ListState, accounts: &[RemoveChoice]) {
    let [header, choices, footer] = Layout::vertical([
        Constraint::Length(2),
        Constraint::Min(1),
        Constraint::Length(2),
    ])
    .areas(frame.area());
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            "Remove a subscription",
            Style::default().add_modifier(Modifier::BOLD),
        ))),
        header,
    );
    frame.render_stateful_widget(
        List::new(
            accounts
                .iter()
                .map(|account| ListItem::new(format!("{}  {}", account.label, account.provider))),
        )
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
        assert!(screen.contains("encrypted"));
    }

    #[test]
    fn login_screen_offers_browser_and_code_flows() {
        let backend = TestBackend::new(80, 10);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut state = ListState::default().with_selected(Some(0));
        terminal
            .draw(|frame| draw_login(frame, &mut state))
            .unwrap();
        let screen = terminal.backend().to_string();
        assert!(screen.contains("Open browser"));
        assert!(screen.contains("Enter a code"));
    }

    #[test]
    fn remove_screen_lists_only_supplied_accounts() {
        let backend = TestBackend::new(80, 10);
        let mut terminal = Terminal::new(backend).unwrap();
        let mut state = ListState::default().with_selected(Some(0));
        let accounts = vec![RemoveChoice {
            id: "account-1".into(),
            label: "person@example.com".into(),
            provider: "codex".into(),
        }];
        terminal
            .draw(|frame| draw_remove(frame, &mut state, &accounts))
            .unwrap();
        let screen = terminal.backend().to_string();
        assert!(screen.contains("Remove a subscription"));
        assert!(screen.contains("person@example.com"));
    }
}
