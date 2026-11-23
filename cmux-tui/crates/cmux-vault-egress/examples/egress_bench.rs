//! The proxy alone, as the daemon runs it (multi-thread runtime, OS roots,
//! DNS), for a throughput harness: `egress_bench [HOST...]` prints its port
//! and writes its CA to `$EGRESS_BENCH_CA` (default `egress-bench-ca.pem`).
//! Each HOST is intercepted (a secret allows it); every other host is a blind
//! tunnel. Point `HTTPS_PROXY=http://127.0.0.1:PORT` at it and fetch
//! (`curl --cacert CA` for an intercepted host).

use std::sync::Arc;

use cmux_vault_egress::{Authority, Config, HostPattern, Policy, Resolver, Secret};

#[tokio::main]
async fn main() -> std::io::Result<()> {
    let hosts: Vec<HostPattern> =
        std::env::args().skip(1).map(|h| HostPattern::parse(&h).expect("a host pattern")).collect();
    let secrets = if hosts.is_empty() {
        Vec::new()
    } else {
        vec![Secret::new("BENCH_TOKEN", "bench-value".to_owned().into(), hosts)]
    };
    let policy = Arc::new(Policy::new(secrets));
    let authority = Arc::new(Authority::generate().map_err(std::io::Error::other)?);
    let ca = std::env::var("EGRESS_BENCH_CA").unwrap_or_else(|_| "egress-bench-ca.pem".to_owned());
    std::fs::write(&ca, authority.pem())?;
    let config = Arc::new(Config {
        policy: Arc::new(move || policy.clone()),
        authority,
        upstream_tls: cmux_vault_egress::upstream_tls_from_os()?,
        resolver: Resolver::Dns,
    });
    let listener = cmux_vault_egress::bind().await?;
    println!("{}", listener.local_addr()?.port());
    cmux_vault_egress::serve(listener, config).await
}
