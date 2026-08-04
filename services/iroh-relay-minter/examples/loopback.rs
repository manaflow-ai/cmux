use std::{convert::Infallible, env, sync::Arc, time::SystemTime};

use cmux_iroh_relay_minter::{MinterConfig, handle_request};
use hyper::{Request, body::Incoming, server::conn::http1, service::service_fn};
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let port = env::var("CMUX_IROH_MINT_DEV_PORT")
        .ok()
        .map(|value| value.parse::<u16>())
        .transpose()?
        .unwrap_or(9460);
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    let config = Arc::new(MinterConfig::from_env()?);
    eprintln!("Iroh relay minter listening on http://127.0.0.1:{port}");

    loop {
        let (stream, peer) = listener.accept().await?;
        if !peer.ip().is_loopback() {
            continue;
        }
        let config = Arc::clone(&config);
        tokio::spawn(async move {
            let service = service_fn(move |request: Request<Incoming>| {
                let config = Arc::clone(&config);
                async move {
                    Ok::<_, Infallible>(handle_request(request, &config, SystemTime::now()).await)
                }
            });
            let _ = http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await;
        });
    }
}
