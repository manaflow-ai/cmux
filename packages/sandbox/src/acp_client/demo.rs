use anyhow::Result;
use crossterm::{
    event::{Event, EventStream, KeyCode, KeyModifiers, MouseEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use futures::StreamExt;
use ratatui::{backend::CrosstermBackend, Terminal};
use tokio::sync::mpsc;

use crate::acp_client::demo_content::{DEMO_CODE_EXAMPLES, DEMO_MARKDOWN_CONTENT};
use crate::acp_client::markdown::normalize_code_fences;
use crate::acp_client::state::{App, ChatEntry, ConnectionState};
use crate::acp_client::ui::ui;

pub async fn run_demo_tui() -> Result<()> {
    let mut stdout = std::io::stdout();
    execute!(
        stdout,
        EnterAlternateScreen,
        crossterm::event::EnableMouseCapture,
        crossterm::event::EnableBracketedPaste
    )?;
    enable_raw_mode()?;

    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let res = run_demo_loop(&mut terminal).await;

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        crossterm::event::DisableMouseCapture,
        LeaveAlternateScreen,
        crossterm::event::DisableBracketedPaste
    )?;
    terminal.show_cursor()?;

    res
}

async fn run_demo_loop<B: ratatui::backend::Backend>(terminal: &mut Terminal<B>) -> Result<()> {
    let (tx, _rx) = mpsc::unbounded_channel();
    let mut app = App::new(
        crate::acp_client::provider::AcpProvider::default(),
        tx,
        String::new(),
        String::new(),
    );
    app.connection_state = ConnectionState::Connected;
    app.history = create_demo_chat_entries();

    let mut reader = EventStream::new();

    loop {
        terminal.draw(|f| ui(f, &mut app))?;

        if let Some(Ok(event)) = reader.next().await {
            let mut scroll_delta: i32 = 0;

            if let Some(exit) = process_demo_event(&mut app, event, &mut scroll_delta) {
                if exit {
                    return Ok(());
                }
            }

            while let Ok(Some(Ok(event))) =
                tokio::time::timeout(std::time::Duration::from_millis(5), reader.next()).await
            {
                if let Some(exit) = process_demo_event(&mut app, event, &mut scroll_delta) {
                    if exit {
                        return Ok(());
                    }
                }
            }

            if scroll_delta > 0 {
                app.scroll_up(scroll_delta as u16);
            } else if scroll_delta < 0 {
                app.scroll_down((-scroll_delta) as u16);
            }
        }
    }
}

fn process_demo_event(app: &mut App, event: Event, scroll_delta: &mut i32) -> Option<bool> {
    match event {
        Event::Key(key) => {
            if key.modifiers.contains(KeyModifiers::CONTROL) {
                match key.code {
                    KeyCode::Char('q') | KeyCode::Char('c') | KeyCode::Char('d') => {
                        return Some(true);
                    }
                    _ => {}
                }
            } else {
                match key.code {
                    KeyCode::PageUp => app.scroll_up(10),
                    KeyCode::PageDown => app.scroll_down(10),
                    KeyCode::Home => app.scroll_to_top(),
                    KeyCode::End => app.scroll_to_bottom(),
                    KeyCode::Char('q') => return Some(true),
                    _ => {}
                }
            }
            Some(false)
        }
        Event::Mouse(mouse_event) => {
            match mouse_event.kind {
                MouseEventKind::ScrollUp => *scroll_delta += 1,
                MouseEventKind::ScrollDown => *scroll_delta -= 1,
                _ => {}
            }
            None
        }
        _ => Some(false),
    }
}

fn create_demo_chat_entries() -> Vec<ChatEntry> {
    vec![
        ChatEntry::Message {
            role: "User".to_string(),
            text: "Can you help me build a web server with authentication?".to_string(),
            normalized_markdown: None,
        },
        ChatEntry::Message {
            role: "Agent".to_string(),
            text: DEMO_MARKDOWN_CONTENT.to_string(),
            normalized_markdown: Some(normalize_code_fences(DEMO_MARKDOWN_CONTENT)),
        },
        ChatEntry::Message {
            role: "Thought".to_string(),
            text: "Let me analyze the requirements...\n\nI should:\n1. Check existing code structure\n2. Plan the authentication flow\n3. Implement secure password hashing".to_string(),
            normalized_markdown: Some("Let me analyze the requirements...\n\nI should:\n1. Check existing code structure\n2. Plan the authentication flow\n3. Implement secure password hashing".to_string()),
        },
        ChatEntry::Plan(agent_client_protocol::Plan {
            entries: vec![
                agent_client_protocol::PlanEntry {
                    content: "Research authentication patterns".to_string(),
                    priority: agent_client_protocol::PlanEntryPriority::High,
                    status: agent_client_protocol::PlanEntryStatus::Completed,
                    meta: None,
                },
                agent_client_protocol::PlanEntry {
                    content: "Implement JWT token generation".to_string(),
                    priority: agent_client_protocol::PlanEntryPriority::High,
                    status: agent_client_protocol::PlanEntryStatus::Completed,
                    meta: None,
                },
                agent_client_protocol::PlanEntry {
                    content: "Add password hashing with bcrypt".to_string(),
                    priority: agent_client_protocol::PlanEntryPriority::Medium,
                    status: agent_client_protocol::PlanEntryStatus::InProgress,
                    meta: None,
                },
                agent_client_protocol::PlanEntry {
                    content: "Create login/logout endpoints".to_string(),
                    priority: agent_client_protocol::PlanEntryPriority::Medium,
                    status: agent_client_protocol::PlanEntryStatus::Pending,
                    meta: None,
                },
                agent_client_protocol::PlanEntry {
                    content: "Write integration tests".to_string(),
                    priority: agent_client_protocol::PlanEntryPriority::Low,
                    status: agent_client_protocol::PlanEntryStatus::Pending,
                    meta: None,
                },
            ],
            meta: None,
        }),
        ChatEntry::ToolCall {
            id: "tool-1".to_string(),
            title: "Read src/auth/mod.rs".to_string(),
            kind: agent_client_protocol::ToolKind::Read,
            status: agent_client_protocol::ToolCallStatus::Completed,
        },
        ChatEntry::ToolCall {
            id: "tool-2".to_string(),
            title: "Edit src/auth/jwt.rs - add token validation".to_string(),
            kind: agent_client_protocol::ToolKind::Edit,
            status: agent_client_protocol::ToolCallStatus::InProgress,
        },
        ChatEntry::ToolCall {
            id: "tool-3".to_string(),
            title: "Delete src/auth/deprecated.rs".to_string(),
            kind: agent_client_protocol::ToolKind::Delete,
            status: agent_client_protocol::ToolCallStatus::Completed,
        },
        ChatEntry::ToolCall {
            id: "tool-4".to_string(),
            title: "Move src/utils/hash.rs → src/auth/hash.rs".to_string(),
            kind: agent_client_protocol::ToolKind::Move,
            status: agent_client_protocol::ToolCallStatus::Completed,
        },
        ChatEntry::ToolCall {
            id: "tool-5".to_string(),
            title: "Search for \"password\" in src/".to_string(),
            kind: agent_client_protocol::ToolKind::Search,
            status: agent_client_protocol::ToolCallStatus::Completed,
        },
        ChatEntry::ToolCall {
            id: "tool-6".to_string(),
            title: "Execute: cargo test auth::tests".to_string(),
            kind: agent_client_protocol::ToolKind::Execute,
            status: agent_client_protocol::ToolCallStatus::Failed,
        },
        ChatEntry::ToolCall {
            id: "tool-7".to_string(),
            title: "Analyzing authentication flow".to_string(),
            kind: agent_client_protocol::ToolKind::Think,
            status: agent_client_protocol::ToolCallStatus::Completed,
        },
        ChatEntry::ToolCall {
            id: "tool-8".to_string(),
            title: "Fetch https://docs.rs/jsonwebtoken".to_string(),
            kind: agent_client_protocol::ToolKind::Fetch,
            status: agent_client_protocol::ToolCallStatus::Pending,
        },
        ChatEntry::ToolCall {
            id: "tool-9".to_string(),
            title: "Switch to code-review mode".to_string(),
            kind: agent_client_protocol::ToolKind::SwitchMode,
            status: agent_client_protocol::ToolCallStatus::Completed,
        },
        ChatEntry::ToolCall {
            id: "tool-10".to_string(),
            title: "Custom: generate-schema".to_string(),
            kind: agent_client_protocol::ToolKind::Other,
            status: agent_client_protocol::ToolCallStatus::InProgress,
        },
        ChatEntry::Message {
            role: "User".to_string(),
            text: "Great progress! Can you also add rate limiting?".to_string(),
            normalized_markdown: None,
        },
        ChatEntry::Message {
            role: "Agent".to_string(),
            text: DEMO_CODE_EXAMPLES.to_string(),
            normalized_markdown: Some(normalize_code_fences(DEMO_CODE_EXAMPLES)),
        },
    ]
}
