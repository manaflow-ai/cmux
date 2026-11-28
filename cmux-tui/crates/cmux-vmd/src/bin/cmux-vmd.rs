//! `cmux-vmd`: the host daemon. Run as root (KVM, netns, nftables).
//!
//! ```text
//! cmux-vmd --listen 127.0.0.1:7070 --token-file /etc/cmux-vmd/token \
//!          [--root /var/lib/cmux-vmd] [--firecracker /usr/local/bin/firecracker] \
//!          [--image default] [--vcpus 2] [--mem-mib 1024] [--dns 1.1.1.1] [--warm-slots 8] [--max-mem-mib N] [--no-ipv6]
//! ```

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use cmux_vmd::host::{Config, Host};

#[tokio::main]
async fn main() -> Result<()> {
    let mut cfg = Config::default();
    let mut listen = "127.0.0.1:7070".to_owned();
    let mut token_file: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        if flag == "--no-ipv6" {
            cfg.ipv6 = false;
            continue;
        }
        if flag == "-h" || flag == "--help" {
            println!(
                "usage: cmux-vmd --listen ADDR --token-file PATH [--root DIR] [--firecracker PATH] [--image NAME] [--vcpus N] [--mem-mib N] [--dns IP] [--warm-slots N] [--max-mem-mib N] [--no-ipv6]"
            );
            return Ok(());
        }
        let value = args.next().with_context(|| format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--listen" => listen = value,
            "--token-file" => token_file = Some(value.into()),
            "--root" => cfg.root = value.into(),
            "--firecracker" => cfg.firecracker = value.into(),
            "--image" => cfg.default_image = value,
            "--vcpus" => cfg.default_vcpus = value.parse()?,
            "--mem-mib" => cfg.default_mem_mib = value.parse()?,
            "--warm-slots" => cfg.warm_slots = value.parse()?,
            "--max-mem-mib" => cfg.max_mem_mib = value.parse()?,
            "--dns" => cfg.dns = value.parse::<std::net::IpAddr>()?.to_string(),
            other => bail!("unknown flag {other}"),
        }
    }
    let token_file = token_file.context("--token-file is required")?;
    let token = std::fs::read_to_string(&token_file)
        .with_context(|| format!("read {}", token_file.display()))?
        .trim()
        .to_owned();
    if token.len() < 16 {
        bail!("the token in {} is shorter than 16 characters", token_file.display());
    }
    let host = Host::open(cfg).await?;
    let listener =
        tokio::net::TcpListener::bind(&listen).await.with_context(|| format!("bind {listen}"))?;
    eprintln!("cmux-vmd: listening on {listen}, {} machines reattached", host.list().len());
    let own = cmux_vmd::ownhost::OwnHost::open(std::sync::Arc::clone(&host)).await?;
    axum::serve(listener, cmux_vmd::server::router(host, own, token)).await?;
    Ok(())
}
