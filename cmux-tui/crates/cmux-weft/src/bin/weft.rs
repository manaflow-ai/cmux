//! `weft`: the device client and admin CLI.
//!
//! ```text
//! weft up --state FILE [--coord URL --tailnet T --authkey K --name N]
//!         [--echo PORT] [--serve PORT=HOST:PORT]... [--forward LOCAL=[ADDR]:PORT]...
//!         [--bench [ADDR]:PORT [--count N] [--size BYTES] [--wait SECONDS] [--once]]
//! weft status --state FILE
//! weft rotate --state FILE
//! weft keygen-authority
//! weft admin --coord URL create-tailnet NAME [--require-approval]
//! weft admin --coord URL set-policy NAME FILE [--if-version V]
//! weft admin --coord URL get-policy NAME
//! weft admin --coord URL mint NAME [--tags tag:a,tag:b] [--user U] [--reusable] [--preapproved] [--ttl SECONDS]
//! weft admin --coord URL nodes|audit NAME
//! weft admin --coord URL approve|revoke NAME NODE
//! ```
//! The admin token comes from `WEFT_ADMIN_TOKEN`, never from the command line.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, bail};
use cmux_weft::admin::{AdminClient, MintAuthKey};
use cmux_weft::client::{JoinOptions, Service, WeftNode};
use cmux_weft::keys::SigningKey;

struct Args {
    positional: Vec<String>,
    options: Vec<(String, Option<String>)>,
}

const FLAGS: &[&str] = &["--require-approval", "--reusable", "--preapproved", "--once"];

impl Args {
    fn parse(raw: impl Iterator<Item = String>) -> Self {
        let mut positional = Vec::new();
        let mut options = Vec::new();
        let mut raw = raw.peekable();
        while let Some(item) = raw.next() {
            if item.starts_with("--") {
                if FLAGS.contains(&item.as_str()) {
                    options.push((item, None));
                } else {
                    options.push((item, raw.next()));
                }
            } else {
                positional.push(item);
            }
        }
        Self { positional, options }
    }

    fn one(&self, name: &str) -> Option<String> {
        self.options.iter().rev().find(|(key, _)| key == name).and_then(|(_, value)| value.clone())
    }

    fn all(&self, name: &str) -> Vec<String> {
        self.options
            .iter()
            .filter(|(key, _)| key == name)
            .filter_map(|(_, value)| value.clone())
            .collect()
    }

    fn flag(&self, name: &str) -> bool {
        self.options.iter().any(|(key, _)| key == name)
    }

    fn need(&self, name: &str) -> anyhow::Result<String> {
        self.one(name).with_context(|| format!("{name} is required"))
    }

    fn arg(&self, index: usize, what: &str) -> anyhow::Result<String> {
        self.positional.get(index).cloned().with_context(|| format!("missing {what}"))
    }
}

fn percentile(sorted: &[Duration], fraction: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let index = ((sorted.len() as f64 - 1.0) * fraction).round() as usize;
    sorted[index.min(sorted.len() - 1)].as_secs_f64() * 1000.0
}

async fn up(args: &Args) -> anyhow::Result<()> {
    let state = PathBuf::from(args.need("--state")?);
    let options = match args.one("--authkey") {
        Some(auth_key) => Some(JoinOptions {
            coord: args.need("--coord")?,
            tailnet: args.need("--tailnet")?,
            auth_key,
            name: args.one("--name").unwrap_or_else(hostname),
        }),
        None => None,
    };
    let node = WeftNode::join(&state, options).await?;
    eprintln!(
        "weft: node {} {} in {} ({:?}), home relay {}",
        node.node_id(),
        node.address(),
        node.tailnet(),
        node.state(),
        node.home_relay().unwrap_or_else(|| "none".into())
    );
    if let Some(port) = args.one("--echo") {
        node.serve(port.parse().context("--echo PORT")?, Service::Echo).await?;
    }
    for spec in args.all("--serve") {
        let (port, target) = spec.split_once('=').context("--serve PORT=HOST:PORT")?;
        node.serve(port.parse()?, Service::Forward(target.parse()?)).await?;
    }
    for spec in args.all("--forward") {
        let (local, remote) = spec.split_once('=').context("--forward LOCAL=[ADDR]:PORT")?;
        let bound = node.forward_local(local.parse()?, remote.parse()?).await?;
        eprintln!("weft: forwarding {bound} -> {remote}");
    }
    if let Some(target) = args.one("--bench") {
        let target: SocketAddr = target.parse().context("--bench [ADDR]:PORT")?;
        let count: usize = args.one("--count").map_or(Ok(200), |count| count.parse())?;
        let size: usize = args.one("--size").map_or(Ok(64), |size| size.parse())?;
        let wait: u64 = args.one("--wait").map_or(Ok(60), |wait| wait.parse())?;
        let first = node.wait_reachable(target, Duration::from_secs(wait)).await?;
        let (connect, mut rounds) = node.bench(target, count, size).await?;
        rounds.sort();
        let report = serde_json::json!({
            "node": node.node_id(),
            "target": target.to_string(),
            "home_relay": node.home_relay(),
            "first_reachable_ms": first.as_secs_f64() * 1000.0,
            "connect_ms": connect.as_secs_f64() * 1000.0,
            "count": rounds.len(),
            "size": size,
            "min_ms": percentile(&rounds, 0.0),
            "p50_ms": percentile(&rounds, 0.5),
            "p90_ms": percentile(&rounds, 0.9),
            "p99_ms": percentile(&rounds, 0.99),
            "max_ms": percentile(&rounds, 1.0),
        });
        println!("{report}");
        if args.flag("--once") {
            node.shutdown().await;
            return Ok(());
        }
    }
    tokio::signal::ctrl_c().await?;
    node.shutdown().await;
    Ok(())
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "device".into())
}

async fn admin(args: &Args) -> anyhow::Result<()> {
    let token = std::env::var("WEFT_ADMIN_TOKEN").context("WEFT_ADMIN_TOKEN")?;
    let client = AdminClient::new(&args.need("--coord")?, &token);
    let command = args.arg(1, "admin command")?;
    let tailnet = args.arg(2, "tailnet")?;
    let print = |value: serde_json::Value| {
        println!("{}", serde_json::to_string_pretty(&value).unwrap_or_default());
    };
    match command.as_str() {
        "create-tailnet" => {
            client.create_tailnet(&tailnet, args.flag("--require-approval")).await?;
        }
        "set-policy" => {
            let text = std::fs::read_to_string(args.arg(3, "policy file")?)?;
            let if_version = args.one("--if-version").map(|version| version.parse()).transpose()?;
            let version = client.set_policy(&tailnet, &text, if_version).await?;
            print(serde_json::json!({"version": version}));
        }
        "get-policy" => print(serde_json::to_value(client.get_policy(&tailnet).await?)?),
        "mint" => {
            let tags = args
                .one("--tags")
                .map(|tags| tags.split(',').map(str::to_owned).collect())
                .unwrap_or_default();
            let key = client
                .mint_auth_key(
                    &tailnet,
                    &MintAuthKey {
                        tags,
                        user: args.one("--user"),
                        reusable: args.flag("--reusable"),
                        preapproved: args.flag("--preapproved"),
                        ttl_seconds: args.one("--ttl").map_or(Ok(3600), |ttl| ttl.parse())?,
                    },
                )
                .await?;
            println!("{key}");
        }
        "nodes" => print(serde_json::to_value(client.nodes(&tailnet).await?)?),
        "audit" => print(serde_json::to_value(client.audit(&tailnet).await?)?),
        "approve" => client.approve_node(&tailnet, &args.arg(3, "node id")?).await?,
        "revoke" => client.revoke_node(&tailnet, &args.arg(3, "node id")?).await?,
        other => bail!("unknown admin command {other}"),
    }
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse(std::env::args().skip(1));
    match args.positional.first().map(String::as_str) {
        Some("up") => up(&args).await,
        Some("status") => {
            let node = WeftNode::join(&PathBuf::from(args.need("--state")?), None).await?;
            println!("{}", serde_json::to_string_pretty(&node.netmap())?);
            node.shutdown().await;
            Ok(())
        }
        Some("rotate") => {
            let node = WeftNode::join(&PathBuf::from(args.need("--state")?), None).await?;
            node.rotate().await?;
            println!("{}", cmux_weft::b64::encode_key(&node.node_key()));
            node.shutdown().await;
            Ok(())
        }
        Some("keygen-authority") => {
            let key = SigningKey::generate();
            println!("WEFT_TICKET_SEED={}", cmux_weft::b64::encode_key(key.seed()));
            println!("WEFT_TICKET_PUBKEY={}", cmux_weft::b64::encode_key(&key.public()));
            Ok(())
        }
        Some("admin") => admin(&args).await,
        _ => bail!("usage: weft up|status|rotate|keygen-authority|admin (see the crate docs)"),
    }
}
