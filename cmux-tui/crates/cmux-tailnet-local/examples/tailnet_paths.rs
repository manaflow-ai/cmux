//! Reads the system tailscaled once and prints how many peers are on each
//! path kind, the source and the time taken. Names nothing (no host names
//! or addresses), so the output is safe to paste.
//!
//! `cargo run -p cmux-tailnet-local --example tailnet_paths`

use std::collections::BTreeMap;
use std::time::Instant;

use cmux_tailnet_local::{Limits, fetch_view_with};

fn main() {
    let limits = Limits::default();
    let start = Instant::now();
    let first = fetch_view_with(&limits, None);
    let cold = start.elapsed();
    let (view, target) = match first {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };
    let start = Instant::now();
    let warm = fetch_view_with(&limits, Some(&view)).map(|_| ());
    let warm_t = start.elapsed();
    let mut kinds: BTreeMap<&str, usize> = BTreeMap::new();
    for p in &view.peers {
        *kinds.entry(p.path.kind()).or_default() += 1;
    }
    println!("source: {:?} ({:?})", view.source, target.map(|t| t.source()));
    println!(
        "backend: {} control: {}",
        view.backend_state,
        match &view.control {
            cmux_tailnet_local::ControlKind::TailscaleSaas => "tailscale",
            cmux_tailnet_local::ControlKind::SelfHosted { .. } => "self-hosted",
            cmux_tailnet_local::ControlKind::Unknown => "unknown",
        }
    );
    println!("profile readable: {}", view.profile.is_some());
    println!("peers: {} {kinds:?}", view.peers.len());
    println!("exit node in use: {}", view.exit_node.is_some());
    println!(
        "subnet routers: {} shared-in: {}",
        view.peers.iter().filter(|p| p.is_subnet_router()).count(),
        view.peers.iter().filter(|p| p.sharee_node).count()
    );
    println!(
        "cold read (status+prefs+profile): {cold:?}; steady read (status only): {warm_t:?} {warm:?}"
    );
}
