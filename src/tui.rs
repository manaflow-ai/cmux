use std::io::{self, IsTerminal};

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui::{
    DefaultTerminal, Terminal,
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
            "`coderouter add` needs an interactive terminal; use `coderouter add codex` or `coderouter add opencode`"
                .into(),
        ));
    }
    with_terminal(choose)
}

pub fn choose_login_action() -> Result<LoginChoice, Error> {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Ok(LoginChoice::Browser);
    }
    with_terminal(choose_login)
}

pub fn choose_remove_account(accounts: &[RemoveChoice]) -> Result<Option<RemoveChoice>, Error> {
    if accounts.is_empty() {
        return Ok(None);
    }
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return Err(Error::Usage(
            "`coderouter remove` needs an interactive terminal; pass an account ID or exact label"
                .into(),
        ));
    }
    with_terminal(|terminal| choose_remove(terminal, accounts))
}

/// Run one interactive menu with Ratatui's standard full-screen lifecycle.
///
/// These menus are complete terminal applications, not output embedded in a
/// normal log stream. The old inline viewport left raw mode and cursor state
/// under manual control, which could leave `cr login` with a stale screen or a
/// broken prompt after the menu returned. Ratatui's full-screen setup gives us
/// a clean buffer and a reliable restore path.
fn with_terminal<T>(
    app: impl FnOnce(&mut DefaultTerminal) -> Result<T, Error>,
) -> Result<T, Error> {
    let mut terminal = ratatui::try_init().map_err(Error::Io)?;
    let result = app(&mut terminal);

    // Always restore the cursor and leave the alternate screen, even when the
    // menu returns an application error. Preserve the original menu error over
    // a cleanup error because it is more useful to the caller.
    let cursor_result = terminal.show_cursor();
    let restore_result = ratatui::try_restore();
    match result {
        Err(error) => Err(error),
        Ok(value) => {
            cursor_result.map_err(Error::Io)?;
            restore_result.map_err(Error::Io)?;
            Ok(value)
        }
    }
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
    terminal: &mut DefaultTerminal,
    accounts: &[RemoveChoice],
) -> Result<Option<RemoveChoice>, Error> {
    let mut state = ListState::default().with_selected(Some(0));
    loop {
        terminal.draw(|frame| draw_remove(frame, &mut state, accounts))?;
        let event = event::read()?;
        let Event::Key(key) = event else {
            if matches!(event, Event::Resize(_, _)) {
                terminal.autoresize()?;
            }
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        if is_cancel_key(key) {
            return Ok(None);
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
            _ => {}
        }
    }
}

fn choose_login(terminal: &mut DefaultTerminal) -> Result<LoginChoice, Error> {
    let choices = [LoginChoice::Browser, LoginChoice::Code, LoginChoice::Cancel];
    let mut state = ListState::default().with_selected(Some(0));
    loop {
        terminal.draw(|frame| draw_login(frame, &mut state))?;
        let event = event::read()?;
        let Event::Key(key) = event else {
            if matches!(event, Event::Resize(_, _)) {
                terminal.autoresize()?;
            }
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        if is_cancel_key(key) {
            return Ok(LoginChoice::Cancel);
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
            _ => {}
        }
    }
}

fn choose(terminal: &mut DefaultTerminal) -> Result<AddChoice, Error> {
    let mut state = ListState::default().with_selected(Some(0));
    loop {
        terminal.draw(|frame| draw_add(frame, &mut state))?;
        let event = event::read()?;
        let Event::Key(key) = event else {
            if matches!(event, Event::Resize(_, _)) {
                terminal.autoresize()?;
            }
            continue;
        };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        if is_cancel_key(key) {
            return Ok(AddChoice::Cancel);
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
            _ => {}
        }
    }
}

fn is_cancel_key(key: KeyEvent) -> bool {
    matches!(key.code, KeyCode::Esc | KeyCode::Char('q'))
        || (key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL))
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
            "↑/↓ move  enter select  esc/ctrl-c cancel",
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
            "↑/↓ move  enter select  esc/ctrl-c cancel",
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
            "↑/↓ move  enter select  esc/ctrl-c cancel",
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
        assert!(screen.contains("ctrl-c cancel"));
    }

    #[test]
    fn ctrl_c_is_a_cancel_key() {
        assert!(is_cancel_key(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::CONTROL,
        )));
        assert!(!is_cancel_key(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::NONE,
        )));
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
