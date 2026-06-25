use std::collections::VecDeque;
use std::io::Write;
use std::path::PathBuf;
use std::time::Duration;
use std::time::Instant;

use anyhow::Context;
use anyhow::Result;
use anyhow::anyhow;
use bytes::Bytes;
use crossterm::cursor;
use crossterm::event;
use crossterm::event::Event;
use crossterm::event::KeyCode;
use crossterm::event::KeyModifiers;
use crossterm::execute;
use crossterm::queue;
use crossterm::terminal;
use http::Method;
use http_body_util::BodyExt;
use http_body_util::Full;
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
use serde_json::Value;
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::agent::CreateSessionRequest;
use crate::agent::CreateSessionResponse;
use crate::agent::TurnRequest;
use crate::storage::HandoffResponse;
use crate::storage::SessionFileResponse;
use crate::storage::SessionMeta;

type HttpClient = Client<HttpConnector, Full<Bytes>>;

#[derive(Debug, Clone)]
pub struct TuiConfig {
    pub server: String,
    pub cwd: Option<PathBuf>,
}

struct TuiGuard;

impl TuiGuard {
    fn enter() -> Result<Self> {
        terminal::enable_raw_mode()?;
        execute!(
            std::io::stdout(),
            terminal::EnterAlternateScreen,
            cursor::Hide
        )?;
        Ok(Self)
    }
}

impl Drop for TuiGuard {
    fn drop(&mut self) {
        let _ = execute!(
            std::io::stdout(),
            cursor::Show,
            terminal::LeaveAlternateScreen
        );
        let _ = terminal::disable_raw_mode();
    }
}

#[derive(Debug)]
struct TuiState {
    server: String,
    cwd: Option<PathBuf>,
    sessions: Vec<SessionMeta>,
    selected: usize,
    input: String,
    handoff: String,
    status: String,
    log: VecDeque<String>,
    last_refresh: Instant,
}

#[derive(Debug)]
enum TuiMsg {
    Log(String),
    Refresh,
}

pub async fn run(config: TuiConfig) -> Result<()> {
    let _guard = TuiGuard::enter()?;
    let client = Client::builder(TokioExecutor::new()).build(HttpConnector::new());
    let mut state = TuiState {
        server: config.server.trim_end_matches('/').to_string(),
        cwd: config.cwd,
        sessions: Vec::new(),
        selected: 0,
        input: String::new(),
        handoff: String::new(),
        status: "ready".to_string(),
        log: VecDeque::new(),
        last_refresh: Instant::now() - Duration::from_secs(10),
    };
    let (tx, mut rx) = mpsc::unbounded_channel::<TuiMsg>();
    refresh(&client, &mut state).await?;

    loop {
        draw(&state)?;

        while let Ok(message) = rx.try_recv() {
            match message {
                TuiMsg::Log(line) => push_log(&mut state, line),
                TuiMsg::Refresh => {
                    refresh(&client, &mut state).await?;
                }
            }
        }

        if state.last_refresh.elapsed() >= Duration::from_secs(2) {
            refresh(&client, &mut state).await?;
        }

        if !event::poll(Duration::from_millis(100))? {
            continue;
        }
        let Event::Key(key) = event::read()? else {
            continue;
        };
        match (key.code, key.modifiers) {
            (KeyCode::Char('c'), KeyModifiers::CONTROL) => break,
            (KeyCode::Char('q'), _) if state.input.is_empty() => break,
            (KeyCode::Esc, _) => state.input.clear(),
            (KeyCode::Up, _) => {
                state.selected = state.selected.saturating_sub(1);
                refresh_handoff(&client, &mut state).await?;
            }
            (KeyCode::Down, _) => {
                if state.selected + 1 < state.sessions.len() {
                    state.selected += 1;
                }
                refresh_handoff(&client, &mut state).await?;
            }
            (KeyCode::Tab, _) => {
                if !state.sessions.is_empty() {
                    state.selected = (state.selected + 1) % state.sessions.len();
                    refresh_handoff(&client, &mut state).await?;
                }
            }
            (KeyCode::Char('r'), KeyModifiers::CONTROL) => {
                refresh(&client, &mut state).await?;
            }
            (KeyCode::Char('o'), KeyModifiers::CONTROL) => {
                open_session_file(&client, &mut state, "open-trajectory").await?;
            }
            (KeyCode::Char('h'), KeyModifiers::CONTROL) => {
                open_session_file(&client, &mut state, "open-handoff").await?;
            }
            (KeyCode::Enter, _) => {
                let input = state.input.trim().to_string();
                if input.is_empty() {
                    continue;
                }
                state.input.clear();
                state.status = "starting task".to_string();
                let client = client.clone();
                let server = state.server.clone();
                let cwd = state.cwd.clone();
                let tx = tx.clone();
                tokio::spawn(async move {
                    if let Err(err) = start_task(client, server, cwd, input, tx.clone()).await {
                        let _ = tx.send(TuiMsg::Log(format!("error: {err}")));
                    }
                    let _ = tx.send(TuiMsg::Refresh);
                });
            }
            (KeyCode::Backspace, _) => {
                state.input.pop();
            }
            (KeyCode::Char(ch), _) => {
                if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT {
                    state.input.push(ch);
                }
            }
            _ => {}
        }
    }
    Ok(())
}

async fn refresh(client: &HttpClient, state: &mut TuiState) -> Result<()> {
    let sessions = get_json::<Vec<SessionMeta>>(client, &state.server, "/v1/sessions")
        .await
        .context("listing sessions")?;
    let selected_id = state
        .sessions
        .get(state.selected)
        .map(|session| session.session_id);
    state.sessions = sessions;
    state.selected = selected_id
        .and_then(|id| {
            state
                .sessions
                .iter()
                .position(|session| session.session_id == id)
        })
        .unwrap_or(0);
    refresh_handoff(client, state).await?;
    state.last_refresh = Instant::now();
    Ok(())
}

async fn refresh_handoff(client: &HttpClient, state: &mut TuiState) -> Result<()> {
    let Some(session) = state.sessions.get(state.selected) else {
        state.handoff.clear();
        return Ok(());
    };
    let response = get_json::<HandoffResponse>(
        client,
        &state.server,
        &format!("/v1/sessions/{}/handoff", session.session_id),
    )
    .await
    .context("reading handoff")?;
    state.handoff = response.handoff;
    Ok(())
}

async fn start_task(
    client: HttpClient,
    server: String,
    cwd: Option<PathBuf>,
    input: String,
    tx: mpsc::UnboundedSender<TuiMsg>,
) -> Result<()> {
    let session = post_json::<CreateSessionRequest, CreateSessionResponse>(
        &client,
        &server,
        "/v1/sessions",
        &CreateSessionRequest {
            cwd,
            env: Default::default(),
        },
    )
    .await
    .context("creating session")?;
    let _ = tx.send(TuiMsg::Log(format!(
        "started {}: {}",
        short_id(session.session_id),
        input
    )));
    stream_turn(&client, &server, session.session_id, input, tx).await
}

async fn stream_turn(
    client: &HttpClient,
    server: &str,
    session_id: Uuid,
    input: String,
    tx: mpsc::UnboundedSender<TuiMsg>,
) -> Result<()> {
    let request = build_request(
        Method::POST,
        server,
        &format!("/v1/sessions/{session_id}/turns/stream"),
        Some(serde_json::to_vec(&TurnRequest {
            input,
            model: None,
            instructions: None,
            reasoning_effort: None,
            max_steps: None,
        })?),
    )?;
    let response = client.request(request).await.context("starting turn")?;
    if !response.status().is_success() {
        return Err(anyhow!("turn stream failed with {}", response.status()));
    }

    let mut body = response.into_body();
    let mut buffer = String::new();
    while let Some(frame) = body.frame().await {
        let frame = frame?;
        let Some(chunk) = frame.data_ref() else {
            continue;
        };
        buffer.push_str(&String::from_utf8_lossy(chunk));
        while let Some(index) = buffer.find("\n\n") {
            let frame = buffer[..index].to_string();
            buffer.drain(..index + 2);
            if let Some(data) = sse_data(&frame)
                && let Some(line) = summarize_event(&data)
            {
                let _ = tx.send(TuiMsg::Log(line));
            }
        }
    }
    let _ = tx.send(TuiMsg::Log(format!("finished {}", short_id(session_id))));
    Ok(())
}

async fn open_session_file(client: &HttpClient, state: &mut TuiState, action: &str) -> Result<()> {
    let Some(session) = state.sessions.get(state.selected) else {
        state.status = "no selected task".to_string();
        return Ok(());
    };
    let response = post_empty::<SessionFileResponse>(
        client,
        &state.server,
        &format!("/v1/sessions/{}/{}", session.session_id, action),
    )
    .await
    .with_context(|| format!("calling {action}"))?;
    state.status = format!("opened {}", response.path.display());
    Ok(())
}

async fn get_json<T>(client: &HttpClient, server: &str, path: &str) -> Result<T>
where
    T: serde::de::DeserializeOwned,
{
    request_json(client, Method::GET, server, path, None).await
}

async fn post_json<B, T>(client: &HttpClient, server: &str, path: &str, body: &B) -> Result<T>
where
    B: serde::Serialize + ?Sized,
    T: serde::de::DeserializeOwned,
{
    request_json(
        client,
        Method::POST,
        server,
        path,
        Some(serde_json::to_vec(body)?),
    )
    .await
}

async fn post_empty<T>(client: &HttpClient, server: &str, path: &str) -> Result<T>
where
    T: serde::de::DeserializeOwned,
{
    request_json(client, Method::POST, server, path, None).await
}

async fn request_json<T>(
    client: &HttpClient,
    method: Method,
    server: &str,
    path: &str,
    body: Option<Vec<u8>>,
) -> Result<T>
where
    T: serde::de::DeserializeOwned,
{
    let response = client
        .request(build_request(method, server, path, body)?)
        .await?;
    let status = response.status();
    let bytes = response.into_body().collect().await?.to_bytes();
    if !status.is_success() {
        return Err(anyhow!(
            "request failed with {status}: {}",
            String::from_utf8_lossy(&bytes)
        ));
    }
    Ok(serde_json::from_slice(&bytes)?)
}

fn build_request(
    method: Method,
    server: &str,
    path: &str,
    body: Option<Vec<u8>>,
) -> Result<Request<Full<Bytes>>> {
    let body = body.unwrap_or_default();
    let uri = format!("{}{}", server.trim_end_matches('/'), path);
    Request::builder()
        .method(method)
        .uri(uri)
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body)))
        .context("building HTTP request")
}

fn draw(state: &TuiState) -> Result<()> {
    let mut stdout = std::io::stdout();
    let (cols, rows) = terminal::size()?;
    queue!(
        stdout,
        cursor::MoveTo(0, 0),
        terminal::Clear(terminal::ClearType::All)
    )?;
    let width = cols as usize;
    let mut row = 0_u16;

    write_line(
        &mut stdout,
        row,
        width,
        "cmux-codex-lite  ctrl-c/q quit  enter new task  tab/up/down select  ctrl-o trajectory  ctrl-h handoff",
    )?;
    row += 1;
    write_line(
        &mut stdout,
        row,
        width,
        &format!("status: {}", state.status),
    )?;
    row += 1;

    let task_rows = state
        .sessions
        .len()
        .min((rows as usize).saturating_sub(8) / 3 + 3);
    write_line(
        &mut stdout,
        row,
        width,
        &format!("Tasks ({})", state.sessions.len()),
    )?;
    row += 1;
    for (idx, session) in state.sessions.iter().take(task_rows).enumerate() {
        let marker = if idx == state.selected { ">" } else { " " };
        let tool = session
            .current_tool
            .as_ref()
            .map(|tool| format!(" tool={tool}"))
            .unwrap_or_default();
        let preview = session.last_handoff_preview.as_deref().unwrap_or("");
        write_line(
            &mut stdout,
            row,
            width,
            &format!(
                "{marker} {} {:?} {}{}  {}",
                short_id(session.session_id),
                session.status,
                session.cwd.display(),
                tool,
                preview
            ),
        )?;
        row += 1;
    }
    if state.sessions.len() > task_rows {
        write_line(
            &mut stdout,
            row,
            width,
            &format!("  ... {} more", state.sessions.len() - task_rows),
        )?;
        row += 1;
    }

    row += 1;
    write_line(&mut stdout, row, width, "Last handoff")?;
    row += 1;
    let handoff_rows = ((rows.saturating_sub(row + 5)) / 2).max(3);
    for line in state.handoff.lines().take(handoff_rows as usize) {
        write_line(&mut stdout, row, width, line)?;
        row += 1;
    }

    row += 1;
    write_line(&mut stdout, row, width, "Recent events")?;
    row += 1;
    let log_rows = rows.saturating_sub(row + 2) as usize;
    for line in state
        .log
        .iter()
        .rev()
        .take(log_rows)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
    {
        write_line(&mut stdout, row, width, line)?;
        row += 1;
    }

    let prompt = format!("task> {}", state.input);
    write_line(&mut stdout, rows.saturating_sub(1), width, &prompt)?;
    stdout.flush()?;
    Ok(())
}

fn write_line(stdout: &mut std::io::Stdout, row: u16, width: usize, line: &str) -> Result<()> {
    queue!(stdout, cursor::MoveTo(0, row))?;
    write!(stdout, "{}", clip(line, width))?;
    Ok(())
}

fn push_log(state: &mut TuiState, line: String) {
    state.log.push_back(line);
    while state.log.len() > 200 {
        state.log.pop_front();
    }
}

fn sse_data(frame: &str) -> Option<String> {
    let mut data = String::new();
    for line in frame.lines() {
        if let Some(value) = line.strip_prefix("data:") {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push_str(value.trim_start());
        }
    }
    (!data.is_empty()).then_some(data)
}

fn summarize_event(data: &str) -> Option<String> {
    let value: Value = serde_json::from_str(data).ok()?;
    match value.get("type").and_then(Value::as_str)? {
        "user_input" => Some(format!(
            "user: {}",
            clip(value.get("input")?.as_str()?, 120)
        )),
        "upstream" => {
            let event = value.get("event")?;
            match event.get("type").and_then(Value::as_str)? {
                "assistant_delta" => event
                    .get("delta")
                    .and_then(Value::as_str)
                    .filter(|delta| !delta.trim().is_empty())
                    .map(|delta| format!("assistant: {}", clip(delta, 120))),
                "completed" => Some("response completed".to_string()),
                "upstream_frame" => None,
                other => Some(format!("upstream: {other}")),
            }
        }
        "tool_started" => Some(format!(
            "tool: {}",
            value
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
        )),
        "tool_completed" => Some(format!(
            "tool done: {}",
            value
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
        )),
        "turn_completed" => Some("turn completed".to_string()),
        "error" => Some(format!(
            "error: {}",
            value
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
        )),
        _ => None,
    }
}

fn short_id(id: Uuid) -> String {
    id.to_string().chars().take(8).collect()
}

fn clip(text: &str, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let mut out = String::new();
    for ch in text.chars() {
        if out.chars().count() + 1 >= width {
            out.push_str("...");
            return out;
        }
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_sse_data() {
        assert_eq!(
            sse_data("event: log\ndata: {\"type\":\"turn_completed\"}\n\n").unwrap(),
            "{\"type\":\"turn_completed\"}"
        );
    }

    #[test]
    fn summarizes_tool_started() {
        assert_eq!(
            summarize_event(r#"{"type":"tool_started","name":"exec","call_id":"1"}"#).unwrap(),
            "tool: exec"
        );
    }
}
