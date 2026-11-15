//! `desktop-lease serve | mcp | journey | call`: see `lib.rs`.

use anyhow::{Context, Result, bail};
use desktop_lease::at;
use desktop_lease::{linux::LinuxXvfb, pool, server};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

const USAGE: &str = "usage:
  desktop-lease serve [--socket P] [--warm N] [--budget-mb MB] [--suspend-after-ms MS] [--state DIR]
  desktop-lease mcp [--socket P]                    the stdio MCP server a session gets
  desktop-lease journey --script F --out DIR [--socket P]
  desktop-lease call [--socket P] JSON              one raw pool request";

fn main() -> Result<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        bail!("{USAGE}");
    }
    let cmd = args.remove(0);
    let mut flag = |name: &str| -> Option<String> {
        let i = args.iter().position(|a| a == name)?;
        let v = args.get(i + 1).cloned();
        args.drain(i..(i + 2).min(args.len()));
        v
    };
    let socket = flag("--socket").map(PathBuf::from).unwrap_or_else(server::default_socket);
    let num = |v: Option<String>, d: u64| -> Result<u64> {
        v.map_or(Ok(d), |v| v.parse().with_context(|| format!("not a number: {v}")))
    };
    match cmd.as_str() {
        "serve" => {
            let warm = num(flag("--warm"), 2)? as usize;
            let budget_mb = num(flag("--budget-mb"), 4096)?;
            let suspend_after = Duration::from_millis(num(flag("--suspend-after-ms"), 0)?);
            let state = flag("--state").map(PathBuf::from).unwrap_or_else(|| {
                std::env::temp_dir().join(format!("desktop-lease-{}", std::process::id()))
            });
            let backend = Arc::new(LinuxXvfb::new(state));
            let pool =
                pool::Pool::new(vec![backend], pool::Config { warm, budget_mb, suspend_after });
            pool.refill_in_background();
            server::serve(pool, &socket)
        }
        "mcp" => desktop_lease::mcp::run(&socket),
        "journey" => {
            let script = flag("--script").map(PathBuf::from).context("--script F")?;
            let out = flag("--out").map(PathBuf::from).context("--out DIR")?;
            let r = desktop_lease::journey::run(&script, &out, &socket)?;
            let d = at(&r, "/desktop_lease");
            println!(
                "{} of {} steps passed; {}",
                at(d, "/steps_passed"),
                at(d, "/steps").as_array().map_or(0, Vec::len),
                out.join("summary.md").display()
            );
            if at(&r, "/cells/0/outcome") != "pass" {
                bail!("the journey has reds: {}", out.join("results.json").display());
            }
            Ok(())
        }
        "call" => {
            let req: serde_json::Value = serde_json::from_str(args.first().context("JSON")?)?;
            let v = server::Client::connect(&socket)?.call(&req)?;
            println!("{v}");
            Ok(())
        }
        _ => bail!("{USAGE}"),
    }
}
