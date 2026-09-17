mod agent;
mod openai_ws;
mod output_store;
mod server;
mod storage;
mod tools;
mod tui;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use anyhow::Result;
use clap::Parser;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "cmux-codex-lite")]
#[command(about = "A lightweight Rust coding-agent app server for OpenAI Responses WebSocket mode")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, clap::Subcommand)]
enum Command {
    Serve(ServeArgs),
    Tui(TuiArgs),
}

#[derive(Debug, Parser, Clone)]
struct ServeArgs {
    #[arg(long, default_value = "127.0.0.1:17680")]
    listen: SocketAddr,

    #[arg(long, default_value = ".codex-lite")]
    state_dir: PathBuf,

    #[arg(long, default_value = "gpt-5.3-codex")]
    model: String,

    #[arg(long, default_value = "https://api.openai.com/v1")]
    base_url: String,

    #[arg(long, env = "OPENAI_API_KEY")]
    api_key: String,

    #[arg(long, env = "OPENAI_ORGANIZATION")]
    organization: Option<String>,

    #[arg(long, env = "OPENAI_PROJECT")]
    project: Option<String>,

    #[arg(long, default_value_t = 1_048_576)]
    inline_output_bytes: usize,

    #[arg(long, default_value_t = 300_000)]
    stream_idle_timeout_ms: u64,

    #[arg(long, default_value = "responses_websockets=2026-02-06")]
    openai_beta: String,
}

#[derive(Debug, Parser, Clone)]
struct TuiArgs {
    #[arg(long, default_value = "http://127.0.0.1:17680")]
    server: String,

    #[arg(long)]
    cwd: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    match cli.command {
        Command::Serve(args) => serve(args).await,
        Command::Tui(args) => {
            tui::run(tui::TuiConfig {
                server: args.server,
                cwd: args.cwd,
            })
            .await
        }
    }
}

async fn serve(args: ServeArgs) -> Result<()> {
    let output_store = output_store::OutputStore::new(
        args.state_dir.join("outputs"),
        output_store::OutputLimits {
            inline_bytes: args.inline_output_bytes,
            preview_bytes: 16 * 1024,
        },
    )
    .await?;

    let openai = openai_ws::ResponsesWsClient::new(openai_ws::ResponsesWsConfig {
        base_url: args.base_url,
        api_key: args.api_key,
        organization: args.organization,
        project: args.project,
        openai_beta: Some(args.openai_beta),
        idle_timeout: Duration::from_millis(args.stream_idle_timeout_ms),
    })?;

    let session_store = storage::SessionStore::new(args.state_dir.join("sessions")).await?;

    let runtime = Arc::new(
        agent::AgentRuntime::new(args.model, output_store, session_store, Arc::new(openai)).await?,
    );

    server::serve(args.listen, runtime)
        .await
        .context("serving app server")
}
