use anyhow::Result;
use tracing_subscriber::EnvFilter;

const HELP: &str = "cnx-hostd: serve this Mac to cnx-ios phones.

Configuration is read from the environment; see cnx-ios/rust/README.md.
Required: CNX_BASE_URL, CNX_TEAM_ID, and CNX_REFRESH_TOKEN(_FILE) or
CNX_ACCESS_TOKEN(_FILE).

  --print-device-id   print this Mac's device id and exit";

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_env("CNX_LOG").unwrap_or_else(|_| EnvFilter::new("info")))
        .init();
    match std::env::args().nth(1).as_deref() {
        Some("--help" | "-h") => {
            println!("{HELP}");
            return Ok(());
        }
        Some("--print-device-id") => {
            let id = match std::env::var("CNX_DEVICE_ID") {
                Ok(id) if !id.trim().is_empty() => id,
                _ => cnx_hostd::config::persistent_device_id(&cnx_hostd::config::default_state_dir())?,
            };
            println!("{id}");
            return Ok(());
        }
        Some(other) => anyhow::bail!("unknown argument {other}\n\n{HELP}"),
        None => {}
    }
    let config = cnx_hostd::config::HostConfig::from_env()?;
    tracing::info!(device_id = config.device_id, team = config.team_id, "starting");
    cnx_hostd::host::run(config).await
}
