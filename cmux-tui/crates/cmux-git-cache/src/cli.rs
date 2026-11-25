//! `cmux host git-cache serve|credential` (and the tests' entry).
//!
//! `serve [--listen ADDR] [--upstream URL] [--edge URL] [--tenant T] [--cache DIR] [--peer URL]...
//!        [--include PATH --helper CMD] [--stats PATH]`: listens, then writes the include (when given) and
//! removes it on SIGTERM or SIGINT.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use crate::gitconfig;
use crate::server::{Config, State, app};

pub const USAGE: &str = "usage: cmux host git-cache serve [--listen ADDR] [--upstream URL] [--edge URL] [--tenant T] [--cache DIR] [--peer URL]... [--include PATH --helper CMD] [--stats PATH] | credential get|store|erase";

pub struct Serve {
    pub cfg: Config,
    pub include: Option<PathBuf>,
    pub helper: Option<String>,
}

pub fn parse_serve(args: &[String]) -> Result<Serve, String> {
    let mut cfg = Config::new(PathBuf::from("/var/cache/cmux/git-cache"));
    let (mut include, mut helper) = (None, None);
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--listen" => {
                cfg.listen =
                    value()?.parse::<SocketAddr>().map_err(|e| format!("--listen: {e}"))?;
            }
            "--upstream" => cfg.upstream = value()?,
            "--edge" => cfg.edge = Some(value()?),
            "--tenant" => cfg.tenant = value()?,
            "--cache" => cfg.cache_root = PathBuf::from(value()?),
            "--peer" => cfg.peers.push(value()?),
            "--auth-ttl-seconds" => {
                cfg.auth_ttl = Duration::from_secs(
                    value()?.parse().map_err(|e| format!("--auth-ttl-seconds: {e}"))?,
                );
            }
            "--include" => include = Some(PathBuf::from(value()?)),
            "--stats" => cfg.stats_file = Some(PathBuf::from(value()?)),
            "--helper" => helper = Some(value()?),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    if include.is_some() && helper.is_none() {
        return Err("--include needs --helper".to_owned());
    }
    if cfg.stats_file.is_none() {
        cfg.stats_file = include.as_ref().and_then(|p| p.parent()).map(|d| d.join("stats.json"));
    }
    Ok(Serve { cfg, include, helper })
}

pub async fn serve(opts: Serve) -> Result<(), String> {
    let state = State::new(opts.cfg.clone())?;
    let listener = tokio::net::TcpListener::bind(opts.cfg.listen)
        .await
        .map_err(|e| format!("bind {}: {e}", opts.cfg.listen))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    if let (Some(path), Some(helper)) = (&opts.include, &opts.helper) {
        gitconfig::write_include(path, &gitconfig::include_text(port, helper))
            .map_err(|e| format!("write {}: {e}", path.display()))?;
    }
    eprintln!(
        "git-cache: listening on 127.0.0.1:{port} upstream={} tenant={} peers={}",
        opts.cfg.upstream,
        opts.cfg.tenant,
        opts.cfg.peers.len()
    );
    let shutdown = async {
        let mut term =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = async { match term.as_mut() { Some(t) => { t.recv().await; } None => std::future::pending().await } } => {}
        }
    };
    let result = axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown)
        .await
        .map_err(|e| e.to_string());
    if let Some(path) = &opts.include {
        gitconfig::remove_include(path);
    }
    result
}

/// Entry for `cmux host git-cache <args>`.
pub fn run(args: &[String]) -> u8 {
    match args.split_first() {
        Some((verb, rest)) if verb == "serve" => {
            let opts = match parse_serve(rest) {
                Ok(opts) => opts,
                Err(e) => {
                    eprintln!("cmux host git-cache: {e}\n{USAGE}");
                    return 2;
                }
            };
            let include = opts.include.clone();
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(e) => {
                    eprintln!("cmux host git-cache: runtime: {e}");
                    return 1;
                }
            };
            match runtime.block_on(serve(opts)) {
                Ok(()) => 0,
                Err(e) => {
                    if let Some(path) = &include {
                        gitconfig::remove_include(path);
                    }
                    eprintln!("cmux host git-cache: {e}");
                    1
                }
            }
        }
        Some((verb, rest)) if verb == "credential" => {
            crate::credential::run(rest.first().map_or("", String::as_str))
        }
        _ => {
            eprintln!("{USAGE}");
            2
        }
    }
}
