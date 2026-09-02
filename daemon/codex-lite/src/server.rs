use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::Context;
use anyhow::Result;
use axum::Json;
use axum::Router;
use axum::extract::Path;
use axum::extract::State;
use axum::response::IntoResponse;
use axum::response::Sse;
use axum::response::sse::Event;
use axum::routing::get;
use axum::routing::post;
use futures_util::StreamExt;
use serde::Serialize;
use serde_json::json;
use tokio::sync::mpsc;
use tokio_stream::wrappers::UnboundedReceiverStream;
use uuid::Uuid;

use crate::agent::AgentEvent;
use crate::agent::AgentRuntime;
use crate::agent::CreateSessionRequest;
use crate::agent::TurnRequest;

#[derive(Debug, Serialize)]
struct Health {
    ok: bool,
    service: &'static str,
}

#[derive(Debug, Serialize)]
struct ErrorBody {
    error: String,
}

pub async fn serve(listen: SocketAddr, runtime: Arc<AgentRuntime>) -> Result<()> {
    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/v1/sessions", get(list_sessions).post(create_session))
        .route("/v1/sessions/{session_id}/handoff", get(read_handoff))
        .route(
            "/v1/sessions/{session_id}/open-trajectory",
            post(open_trajectory),
        )
        .route("/v1/sessions/{session_id}/open-handoff", post(open_handoff))
        .route("/v1/sessions/{session_id}/turns", post(run_turn))
        .route("/v1/sessions/{session_id}/turns/stream", post(stream_turn))
        .with_state(runtime);

    let listener = tokio::net::TcpListener::bind(listen)
        .await
        .with_context(|| format!("binding {listen}"))?;
    tracing::info!("cmux-codex-lite listening on http://{listen}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn healthz() -> Json<Health> {
    Json(Health {
        ok: true,
        service: "cmux-codex-lite",
    })
}

async fn create_session(
    State(runtime): State<Arc<AgentRuntime>>,
    Json(request): Json<CreateSessionRequest>,
) -> impl IntoResponse {
    match runtime.create_session(request).await {
        Ok(response) => Json(response).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: err.to_string(),
            }),
        )
            .into_response(),
    }
}

async fn list_sessions(State(runtime): State<Arc<AgentRuntime>>) -> impl IntoResponse {
    match runtime.list_sessions().await {
        Ok(response) => Json(response).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: err.to_string(),
            }),
        )
            .into_response(),
    }
}

async fn read_handoff(
    State(runtime): State<Arc<AgentRuntime>>,
    Path(session_id): Path<Uuid>,
) -> impl IntoResponse {
    match runtime.read_handoff(session_id).await {
        Ok(response) => Json(response).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: err.to_string(),
            }),
        )
            .into_response(),
    }
}

async fn open_trajectory(
    State(runtime): State<Arc<AgentRuntime>>,
    Path(session_id): Path<Uuid>,
) -> impl IntoResponse {
    match runtime.open_trajectory(session_id).await {
        Ok(response) => Json(response).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: err.to_string(),
            }),
        )
            .into_response(),
    }
}

async fn open_handoff(
    State(runtime): State<Arc<AgentRuntime>>,
    Path(session_id): Path<Uuid>,
) -> impl IntoResponse {
    match runtime.open_handoff(session_id).await {
        Ok(response) => Json(response).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: err.to_string(),
            }),
        )
            .into_response(),
    }
}

async fn run_turn(
    State(runtime): State<Arc<AgentRuntime>>,
    Path(session_id): Path<Uuid>,
    Json(request): Json<TurnRequest>,
) -> impl IntoResponse {
    match runtime.run_turn(session_id, request, |_event| {}).await {
        Ok(response) => Json(response).into_response(),
        Err(err) => (
            axum::http::StatusCode::BAD_REQUEST,
            Json(ErrorBody {
                error: err.to_string(),
            }),
        )
            .into_response(),
    }
}

async fn stream_turn(
    State(runtime): State<Arc<AgentRuntime>>,
    Path(session_id): Path<Uuid>,
    Json(request): Json<TurnRequest>,
) -> Sse<impl futures_util::Stream<Item = Result<Event, Infallible>>> {
    let (tx, rx) = mpsc::unbounded_channel::<AgentEvent>();
    tokio::spawn(async move {
        let tx_for_events = tx.clone();
        let result = runtime
            .run_turn(session_id, request, move |event| {
                let _ = tx_for_events.send(event);
            })
            .await;
        if let Err(err) = result {
            let _ = tx.send(AgentEvent::Error {
                message: err.to_string(),
            });
        }
    });

    let stream = UnboundedReceiverStream::new(rx).map(|event| {
        let data = serde_json::to_string(&event).unwrap_or_else(|err| {
            json!({
                "type": "error",
                "message": format!("failed to serialize event: {err}")
            })
            .to_string()
        });
        Ok(Event::default().event(event_name(&event)).data(data))
    });
    Sse::new(stream)
}

fn event_name(event: &AgentEvent) -> &'static str {
    match event {
        AgentEvent::UserInput { .. } => "user_input",
        AgentEvent::TurnStarted { .. } => "turn_started",
        AgentEvent::Upstream { .. } => "upstream",
        AgentEvent::ToolStarted { .. } => "tool_started",
        AgentEvent::ToolCompleted { .. } => "tool_completed",
        AgentEvent::TurnCompleted { .. } => "turn_completed",
        AgentEvent::Error { .. } => "error",
    }
}
