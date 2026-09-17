use anyhow::{Context, Result};
use cmux_v3_control_server::{auth::Stack, router, store::Store, Service};
use cmux_v3_grants::GrantSigner;
use ed25519_dalek::SigningKey;
use sqlx::postgres::{PgConnectOptions, PgPoolOptions, PgSslMode};
use std::{sync::Arc, time::Duration};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
    let mut options: PgConnectOptions = std::env::var("DATABASE_URL")
        .context("DATABASE_URL required")?
        .parse()?;
    if !matches!(options.get_host(), "localhost" | "127.0.0.1" | "::1") {
        options = options.ssl_mode(PgSslMode::VerifyFull);
    }
    let db = PgPoolOptions::new()
        .max_connections(32)
        .acquire_timeout(Duration::from_secs(5))
        .connect_with(options)
        .await?;
    // Explicit operator step, never migrate from serving startup.
    if std::env::args().nth(1).as_deref() == Some("migrate") {
        sqlx::migrate!("./migrations").run(&db).await?;
        return Ok(());
    }
    let path = std::path::PathBuf::from(std::env::var("CMUX_V3_SIGNER_SEED_FILE")?);
    use std::os::unix::fs::PermissionsExt;
    let metadata = std::fs::symlink_metadata(&path)?;
    if !metadata.is_file() || metadata.len() != 32 || metadata.permissions().mode() & 0o077 != 0 {
        anyhow::bail!("signer seed must be a private regular 32-byte file");
    }
    let seed: [u8; 32] = std::fs::read(path)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid seed length"))?;
    let signer = Arc::new(GrantSigner::new(
        std::env::var("CMUX_V3_SIGNER_KEY_ID")?,
        &SigningKey::from_bytes(&seed),
    )?);
    let stack = Stack::new(
        std::env::var("STACK_API_BASE")
            .unwrap_or_else(|_| "https://api.stack-auth.com/".into())
            .parse()?,
        std::env::var("STACK_PROJECT_ID")?,
        std::env::var("STACK_PUBLISHABLE_CLIENT_KEY")?,
        std::env::var("STACK_SECRET_SERVER_KEY")?,
    )?;
    let audience = std::env::var("CMUX_V3_AUDIENCE")
        .context("CMUX_V3_AUDIENCE must identify the deployment")?;
    if audience.is_empty() {
        anyhow::bail!("empty deployment audience");
    }
    let store = Store(db);
    store.ready().await?;
    let service = Service {
        store,
        stack: Arc::new(stack),
        signer,
        audience,
    };
    let listener = tokio::net::TcpListener::bind(
        std::env::var("CMUX_V3_CONTROL_HTTP").unwrap_or_else(|_| "127.0.0.1:8081".into()),
    )
    .await?;
    tracing::info!(address=%listener.local_addr()?,"v3 control service listening");
    axum::serve(listener, router(service)).await?;
    Ok(())
}
