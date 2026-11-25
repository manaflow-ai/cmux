//! The stable node as a process, for the live proof on a throwaway tailnet
//! (`testing/stable-node-e2e.sh`). Three roles in one binary:
//!
//! `stable_node front --state DIR [--hostname cmux] [--control-url URL] [--authkey-file F]
//!      [--ctl 127.0.0.1:9900] --route PORT=WORKSPACE ... --place WORKSPACE=HOST:PORT ...`
//!   Starts the stable tsnet node (never ephemeral, identity in DIR), prints its identity as one
//!   JSON line, serves each route's tailnet port through the front, and takes
//!   [`PlacementMessage`] JSON lines on the control address (local only), printing each one it
//!   applies with a timestamp.
//! `stable_node echo NAME ADDR`   a backend that answers every chunk with `NAME:<chunk>`.
//! `stable_node ctl ADDR JSON`    send one control line and print the answer.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_tailnet_front::tsnet::{StableNode, StableNodeConfig};
use cmux_tailnet_front::{
    Backend, Front, Placement, PlacementMessage, PlacementTable, Route, TcpDialer,
};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn emit(value: serde_json::Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn fail(message: &str) -> ! {
    eprintln!("stable_node: {message}");
    std::process::exit(2)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .unwrap_or_else(|e| fail(&e.to_string()));
    match args.first().map(String::as_str) {
        Some("front") => runtime.block_on(front(&args[1..])),
        Some("echo") if args.len() == 3 => runtime.block_on(echo(&args[1], &args[2])),
        Some("ctl") if args.len() == 3 => runtime.block_on(ctl(&args[1], &args[2])),
        _ => fail("usage: stable_node front|echo NAME ADDR|ctl ADDR JSON"),
    }
}

async fn echo(name: &str, addr: &str) {
    let listener = TcpListener::bind(addr).await.unwrap_or_else(|e| fail(&e.to_string()));
    emit(serde_json::json!({"event": "echo", "name": name, "addr": addr}));
    let connections = cmux_scope::Scope::new("stable-node-echo");
    loop {
        let Ok((mut stream, _)) = listener.accept().await else { continue };
        let name = name.to_owned();
        connections.spawn_until_cancelled("echo.connection", async move {
            let mut buf = [0u8; 4096];
            loop {
                let n = match stream.read(&mut buf).await {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                let mut reply = format!("{name}:").into_bytes();
                reply.extend_from_slice(&buf[..n]);
                if stream.write_all(&reply).await.is_err() {
                    return;
                }
            }
        });
    }
}

async fn ctl(addr: &str, line: &str) {
    let mut stream = TcpStream::connect(addr).await.unwrap_or_else(|e| fail(&e.to_string()));
    let _ = stream.write_all(format!("{line}\n").as_bytes()).await;
    let mut reply = String::new();
    let _ = BufReader::new(stream).read_line(&mut reply).await;
    print!("{reply}");
}

async fn front(args: &[String]) {
    let mut state = None;
    let mut hostname = cmux_tailnet_front::tsnet::DEFAULT_HOSTNAME.to_owned();
    let mut control_url = None;
    let mut auth_key = None;
    let mut ctl_addr = "127.0.0.1:9900".to_owned();
    let mut routes: BTreeMap<u16, String> = BTreeMap::new();
    let mut places: Vec<(String, String)> = Vec::new();
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let value = it.next().unwrap_or_else(|| fail(&format!("{flag} needs a value")));
        match flag.as_str() {
            "--state" => state = Some(PathBuf::from(value)),
            "--hostname" => hostname = value.clone(),
            "--control-url" => control_url = Some(value.clone()),
            "--authkey-file" => {
                auth_key = Some(
                    std::fs::read_to_string(value)
                        .unwrap_or_else(|e| fail(&format!("authkey: {e}")))
                        .trim()
                        .to_owned(),
                );
            }
            "--ctl" => ctl_addr = value.clone(),
            "--route" => {
                let (port, ws) = value.split_once('=').unwrap_or_else(|| fail("--route PORT=WS"));
                routes.insert(port.parse().unwrap_or_else(|_| fail("bad port")), ws.to_owned());
            }
            "--place" => {
                let (ws, addr) = value.split_once('=').unwrap_or_else(|| fail("--place WS=ADDR"));
                places.push((ws.to_owned(), addr.to_owned()));
            }
            other => fail(&format!("unknown flag {other}")),
        }
    }
    let state = state.unwrap_or_else(|| fail("--state DIR"));
    let config = StableNodeConfig { state_dir: state, hostname, auth_key, control_url };
    let started = now();
    let node = tokio::task::spawn_blocking(move || {
        StableNode::start_blocking(&config, Duration::from_secs(90))
    })
    .await
    .unwrap_or_else(|e| fail(&e.to_string()))
    .unwrap_or_else(|e| fail(&e.to_string()));
    let identity = node.identity().unwrap_or_else(|e| fail(&e.to_string()));
    emit(serde_json::json!({
        "event": "identity",
        "hostname": identity.hostname,
        "dns_name": identity.dns_name,
        "ips": identity.ips,
        "start_s": now() - started,
    }));

    let table = Arc::new(PlacementTable::new());
    for (ws, addr) in places {
        table.set(&ws, Placement { ssh: Some(Backend::new(addr)), previews: BTreeMap::new() });
    }
    let front = Front::new(Arc::clone(&table), TcpDialer);
    for (port, ws) in &routes {
        let listener = node.listen(*port).await.unwrap_or_else(|e| fail(&e.to_string()));
        front.spawn_serve(listener, Route::Ssh { workspace: ws.clone() });
    }
    emit(serde_json::json!({"event": "serving", "ports": routes.keys().collect::<Vec<_>>()}));

    let control = TcpListener::bind(&ctl_addr).await.unwrap_or_else(|e| fail(&e.to_string()));
    loop {
        let Ok((stream, _)) = control.accept().await else { continue };
        let mut lines = BufReader::new(stream);
        let mut line = String::new();
        if lines.read_line(&mut line).await.is_err() {
            continue;
        }
        let reply = match serde_json::from_str::<PlacementMessage>(&line) {
            Ok(message) => {
                let applied = table.apply(&message);
                let at = now();
                emit(serde_json::json!({
                    "event": "applied",
                    "t": at,
                    "workspace": message.workspace(),
                    "result": format!("{applied:?}"),
                }));
                serde_json::json!({"ok": true, "t": at, "result": format!("{applied:?}")})
            }
            Err(e) => serde_json::json!({"ok": false, "error": e.to_string()}),
        };
        let mut stream = lines.into_inner();
        let _ = stream.write_all(format!("{reply}\n").as_bytes()).await;
    }
}
