use crate::adapters::{adapter_by_id, adapters};
use crate::state::{adapter_counts, group_sessions_by_status, HomeState, Session};
use crossterm::event::{self, Event, KeyCode, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph, Wrap};
use ratatui::{Frame, Terminal};
use std::io;
use std::time::Duration;

pub fn run(state: HomeState) -> io::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;
    let result = run_loop(&mut terminal, TuiApp::new(state));

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    result
}

struct TuiApp {
    state: HomeState,
    selected: usize,
}

impl TuiApp {
    fn new(state: HomeState) -> Self {
        Self { state, selected: 0 }
    }

    fn selected_session(&self) -> Option<Session> {
        self.state.sorted_sessions().into_iter().nth(self.selected)
    }

    fn session_count(&self) -> usize {
        self.state.sessions.len()
    }

    fn select_next(&mut self) {
        if self.session_count() == 0 {
            self.selected = 0;
        } else {
            self.selected = (self.selected + 1).min(self.session_count() - 1);
        }
    }

    fn select_previous(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }
}

fn run_loop(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    mut app: TuiApp,
) -> io::Result<()> {
    loop {
        terminal.draw(|frame| draw(frame, &app))?;

        if event::poll(Duration::from_millis(250))? {
            match event::read()? {
                Event::Key(key)
                    if key.modifiers.contains(KeyModifiers::CONTROL)
                        && key.code == KeyCode::Char('c') =>
                {
                    return Ok(());
                }
                Event::Key(key) => match key.code {
                    KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                    KeyCode::Down | KeyCode::Char('j') => app.select_next(),
                    KeyCode::Up | KeyCode::Char('k') => app.select_previous(),
                    _ => {}
                },
                _ => {}
            }
        }
    }
}

fn draw(frame: &mut Frame<'_>, app: &TuiApp) {
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(3),
            Constraint::Min(8),
            Constraint::Length(3),
        ])
        .split(frame.area());

    draw_header(frame, app, outer[0]);
    draw_adapter_counts(frame, app, outer[1]);

    let body = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(58), Constraint::Percentage(42)])
        .split(outer[2]);

    draw_sessions(frame, app, body[0]);
    draw_details(frame, app, body[1]);
    draw_task_prompt(frame, app, outer[3]);
}

fn draw_header(frame: &mut Frame<'_>, app: &TuiApp, area: Rect) {
    let subtitle = format!(
        "{} sessions, {} adapters, read-only prototype",
        app.state.sessions.len(),
        adapters().len()
    );
    let header = Paragraph::new(vec![
        Line::from(vec![
            Span::styled(
                "cmux home",
                Style::default()
                    .fg(Color::Cyan)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::raw("  "),
            Span::styled(subtitle, Style::default().fg(Color::Gray)),
        ]),
        Line::from("q quits, up/down changes preview"),
    ])
    .block(Block::default().borders(Borders::BOTTOM));

    frame.render_widget(header, area);
}

fn draw_adapter_counts(frame: &mut Frame<'_>, app: &TuiApp, area: Rect) {
    let counts = adapter_counts(&app.state)
        .into_iter()
        .map(|(id, count)| {
            let display = adapter_by_id(id)
                .map(|adapter| adapter.display_name)
                .unwrap_or(id);
            Span::styled(
                format!("{display}: {count}  "),
                Style::default().fg(Color::LightGreen),
            )
        })
        .collect::<Vec<_>>();

    frame.render_widget(Paragraph::new(Line::from(counts)), area);
}

fn draw_sessions(frame: &mut Frame<'_>, app: &TuiApp, area: Rect) {
    let mut items = Vec::new();
    let mut session_index = 0usize;

    for group in group_sessions_by_status(&app.state) {
        items.push(ListItem::new(Line::from(vec![Span::styled(
            format!("{} ({})", group.status.label(), group.sessions.len()),
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        )])));

        for session in group.sessions {
            let adapter_name = adapter_by_id(session.adapter)
                .map(|adapter| adapter.display_name)
                .unwrap_or(session.adapter);
            let marker = if session_index == app.selected {
                ">"
            } else {
                " "
            };
            let branch = session
                .branch
                .as_deref()
                .map(|branch| format!(" #{branch}"))
                .unwrap_or_default();
            let style = if session_index == app.selected {
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Cyan)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            items.push(ListItem::new(Line::from(vec![
                Span::styled(format!("{marker} "), style),
                Span::styled(format!("{adapter_name} "), style),
                Span::styled(session.title, style),
                Span::styled(branch, style.fg(Color::Gray)),
            ])));
            session_index += 1;
        }
    }

    if items.is_empty() {
        items.push(ListItem::new("No sessions found."));
    }

    let list = List::new(items).block(Block::default().title("Sessions").borders(Borders::ALL));
    frame.render_widget(list, area);
}

fn draw_details(frame: &mut Frame<'_>, app: &TuiApp, area: Rect) {
    let lines = match app.selected_session() {
        Some(session) => {
            let adapter = adapter_by_id(session.adapter);
            let resume = adapter
                .map(|adapter| adapter.resume_command(&session))
                .unwrap_or_else(|| session.resume_session_id().to_string());
            let gaps = adapter
                .map(|adapter| adapter.feature_gaps.join("\n- "))
                .unwrap_or_else(|| "unknown adapter".to_string());

            vec![
                Line::styled(session.title, Style::default().add_modifier(Modifier::BOLD)),
                Line::from(format!(
                    "adapter: {}",
                    adapter
                        .map(|adapter| adapter.display_name)
                        .unwrap_or(session.adapter)
                )),
                Line::from(format!("status: {}", session.status.label())),
                Line::from(format!("cwd: {}", session.cwd.as_deref().unwrap_or("-"))),
                Line::from(format!(
                    "branch: {}",
                    session.branch.as_deref().unwrap_or("-")
                )),
                Line::from(format!(
                    "updated: {}",
                    session.updated_at.as_deref().unwrap_or("-")
                )),
                Line::from(""),
                Line::styled("preview", Style::default().fg(Color::Yellow)),
                Line::from(session.preview.unwrap_or_else(|| "-".to_string())),
                Line::from(""),
                Line::styled("resume", Style::default().fg(Color::Yellow)),
                Line::from(resume),
                Line::from(""),
                Line::styled("known gaps", Style::default().fg(Color::Yellow)),
                Line::from(format!("- {gaps}")),
                Line::from(""),
                Line::styled("details", Style::default().fg(Color::Yellow)),
                Line::from(session.details.unwrap_or_else(|| "-".to_string())),
            ]
        }
        None => vec![Line::from("Select a session to preview details.")],
    };

    let details = Paragraph::new(lines)
        .wrap(Wrap { trim: false })
        .block(Block::default().title("Preview").borders(Borders::ALL));
    frame.render_widget(details, area);
}

fn draw_task_prompt(frame: &mut Frame<'_>, app: &TuiApp, area: Rect) {
    let prompt = Paragraph::new(Line::from(vec![
        Span::styled("Task > ", Style::default().fg(Color::Cyan)),
        Span::raw(&app.state.task_prompt),
    ]))
    .block(Block::default().borders(Borders::TOP));

    frame.render_widget(prompt, area);
}
