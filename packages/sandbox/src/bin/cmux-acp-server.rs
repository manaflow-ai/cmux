//! cmux-acp-server binary entry point.
//!
//! Standalone ACP server for iOS app integration. Handles WebSocket connections
//! from iOS clients and manages conversations with coding CLIs.

use std::net::SocketAddr;
use std::path::PathBuf;

use axum::routing::{any, get};
use axum::Router;
use clap::Parser;
use tracing::{info, Level};
use tracing_subscriber::EnvFilter;
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

use cmux_sandbox::acp_server::{acp_websocket_handler, AcpServerState, ApiKeys};

/// ACP Server for iOS app integration.
#[derive(Parser, Debug)]
#[command(name = "cmux-acp-server")]
#[command(about = "ACP server for cmux iOS app")]
struct Args {
    /// Port to listen on
    #[arg(short, long, env = "ACP_PORT", default_value = "39384")]
    port: u16,

    /// Convex deployment URL
    #[arg(long, env = "CONVEX_URL")]
    convex_url: String,

    /// JWT secret for conversation token verification
    #[arg(long, env = "CMUX_CONVERSATION_JWT_SECRET")]
    jwt_secret: String,

    /// Convex admin key for API authentication
    #[arg(long, env = "CONVEX_ADMIN_KEY")]
    convex_admin_key: String,

    /// Default working directory for spawned CLIs
    #[arg(long, env = "ACP_WORKING_DIR", default_value = "/workspace")]
    working_dir: PathBuf,

    /// Anthropic API key for Claude Code
    #[arg(long, env = "ANTHROPIC_API_KEY")]
    anthropic_api_key: Option<String>,

    /// OpenAI API key for Codex
    #[arg(long, env = "OPENAI_API_KEY")]
    openai_api_key: Option<String>,

    /// Google API key for Gemini CLI
    #[arg(long, env = "GOOGLE_API_KEY")]
    google_api_key: Option<String>,

    /// Enable verbose logging
    #[arg(short, long)]
    verbose: bool,
}

/// Health check endpoint response.
#[derive(serde::Serialize, utoipa::ToSchema)]
struct HealthResponse {
    status: &'static str,
    version: &'static str,
}

/// Health check handler.
#[utoipa::path(
    get,
    path = "/health",
    responses(
        (status = 200, description = "Server is healthy", body = HealthResponse)
    ),
    tag = "health"
)]
async fn health() -> axum::Json<HealthResponse> {
    axum::Json(HealthResponse {
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

/// OpenAPI documentation for the ACP server.
#[derive(OpenApi)]
#[openapi(
    info(
        title = "cmux ACP Server",
        description = "ACP (Agent Client Protocol) server for iOS app integration. \
            Provides WebSocket endpoints for communicating with coding agents (Claude Code, Codex, etc.).",
        version = "0.1.0"
    ),
    paths(health),
    components(schemas(HealthResponse)),
    tags(
        (name = "health", description = "Health check endpoints"),
        (name = "acp", description = "WebSocket endpoints for ACP protocol")
    )
)]
struct ApiDoc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Initialize logging
    let filter = if args.verbose {
        EnvFilter::default().add_directive(Level::DEBUG.into())
    } else {
        EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| EnvFilter::default().add_directive(Level::INFO.into()))
    };

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .init();

    info!(
        port = args.port,
        working_dir = %args.working_dir.display(),
        "Starting cmux-acp-server"
    );

    // Create API keys from args
    let api_keys = ApiKeys {
        anthropic_api_key: args.anthropic_api_key.clone(),
        openai_api_key: args.openai_api_key.clone(),
        google_api_key: args.google_api_key.clone(),
    };

    // Create ACP server state
    let state = AcpServerState::new(
        args.convex_url.clone(),
        args.jwt_secret.clone(),
        args.convex_admin_key.clone(),
        args.working_dir.clone(),
    )
    .with_api_keys(api_keys);

    // Build router
    let app = Router::new()
        .route("/health", get(health))
        .route("/healthz", get(health))
        .route("/api/acp", any(acp_websocket_handler))
        .route(
            "/api/conversations/{conversation_id}/ws",
            any(acp_websocket_handler),
        )
        .merge(SwaggerUi::new("/docs").url("/api-docs/openapi.json", ApiDoc::openapi()))
        .with_state(state);

    // Bind and serve
    let addr = SocketAddr::from(([0, 0, 0, 0], args.port));
    info!("Listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}
