mod auth;
mod capture;
mod client;
mod ghostty;
mod metadata;
mod pane;
mod proxy;
mod rpc;
mod server;
mod session;
mod tmux;

use std::env;
use std::io::{self, Write};
use std::path::Path;
use std::process;

use client::UnixRpcClient;
use server::Daemon;

fn main() {
    process::exit(run(env::args().collect()));
}

fn run(args: Vec<String>) -> i32 {
    let argv0 = args
        .first()
        .and_then(|value| Path::new(value).file_name())
        .and_then(|value| value.to_str())
        .unwrap_or("cmuxd-remote");

    if argv0 == "amux" {
        return run_amux_cli(&args[1..]);
    }
    if argv0 == "tmux" {
        return run_tmux_cli(&args[1..]);
    }
    if argv0 == "cmux" {
        return run_cli_relay(&args[1..]);
    }

    if args.len() <= 1 {
        usage(&mut io::stderr());
        return 2;
    }

    match args[1].as_str() {
        "version" => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            0
        }
        "serve" => run_serve(&args[2..]),
        "session" => run_session_cli(&args[2..]),
        "amux" => run_amux_cli(&args[2..]),
        "tmux" => run_tmux_cli(&args[2..]),
        "cli" => run_cli_relay(&args[2..]),
        "list" | "ls" | "attach" | "status" | "history" | "kill" | "new" => {
            run_session_cli(&args[1..])
        }
        _ => {
            usage(&mut io::stderr());
            2
        }
    }
}

fn run_serve(args: &[String]) -> i32 {
    let daemon = Daemon::new(env!("CARGO_PKG_VERSION"));
    if args == ["--stdio"] {
        match daemon.serve_stdio(io::stdin().lock(), io::stdout().lock()) {
            Ok(()) => 0,
            Err(err) => {
                eprintln!("serve failed: {err}");
                1
            }
        }
    } else if !args.is_empty() && args[0] == "--unix" {
        match daemon.serve_unix(parse_unix_args(&args[1..])) {
            Ok(()) => 0,
            Err(err) => {
                eprintln!("serve failed: {err}");
                1
            }
        }
    } else if !args.is_empty() && args[0] == "--tls" {
        match daemon.serve_tls(parse_tls_args(&args[1..])) {
            Ok(()) => 0,
            Err(err) => {
                eprintln!("serve failed: {err}");
                1
            }
        }
    } else {
        eprintln!("serve requires exactly one of --stdio, --unix, or --tls");
        2
    }
}

fn parse_unix_args(args: &[String]) -> server::UnixServeConfig {
    let mut cfg = server::UnixServeConfig::default();
    let mut idx = 0;
    while idx < args.len() {
        if idx + 1 >= args.len() {
            break;
        }
        match args[idx].as_str() {
            "--socket" => cfg.socket_path = args[idx + 1].clone(),
            "--ws-port" => cfg.ws_port = args[idx + 1].parse().ok(),
            "--ws-secret" => cfg.ws_secret = Some(args[idx + 1].clone()),
            _ => {}
        }
        idx += 2;
    }
    cfg
}

fn parse_tls_args(args: &[String]) -> server::TlsServeConfig {
    let mut cfg = server::TlsServeConfig::default();
    let mut idx = 0;
    while idx < args.len() {
        if idx + 1 >= args.len() {
            break;
        }
        match args[idx].as_str() {
            "--listen" => cfg.listen_addr = args[idx + 1].clone(),
            "--server-id" => cfg.server_id = args[idx + 1].clone(),
            "--ticket-secret" => cfg.ticket_secret = args[idx + 1].clone(),
            "--cert-file" => cfg.cert_file = args[idx + 1].clone(),
            "--key-file" => cfg.key_file = args[idx + 1].clone(),
            _ => {}
        }
        idx += 2;
    }
    cfg
}

fn run_session_cli(args: &[String]) -> i32 {
    match client::run_session_cli(args) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("{err}");
            1
        }
    }
}

fn run_amux_cli(args: &[String]) -> i32 {
    match client::run_amux_cli(args) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("{err}");
            1
        }
    }
}

fn run_tmux_cli(args: &[String]) -> i32 {
    match client::run_tmux_cli(args) {
        Ok(code) => code,
        Err(err) => {
            eprintln!("{err}");
            1
        }
    }
}

fn run_cli_relay(args: &[String]) -> i32 {
    let filtered = strip_socket_flag(args);
    if filtered.is_empty()
        || matches!(
            filtered.first().map(String::as_str),
            Some("--help") | Some("-h") | Some("help")
        )
    {
        cli_usage(&mut io::stdout());
        return 0;
    }

    let socket = match find_socket_flag(args)
        .or_else(|| env::var("CMUX_SOCKET_PATH").ok())
        .or_else(read_socket_addr_file)
    {
        Some(value) if !value.trim().is_empty() => value,
        _ => {
            eprintln!(
                "cmux: CMUX_SOCKET_PATH not set, ~/.cmux/socket_addr missing, and --socket not provided"
            );
            return 1;
        }
    };
    if filtered.first().map(String::as_str) == Some("rpc") {
        if filtered.len() < 2 {
            eprintln!("cmux: rpc requires a method");
            return 2;
        }
        let params = if filtered.len() > 2 {
            match serde_json::from_str::<serde_json::Value>(&filtered[2]) {
                Ok(value) => value,
                Err(err) => {
                    eprintln!("cmux: invalid JSON params: {err}");
                    return 2;
                }
            }
        } else {
            serde_json::json!({})
        };
        match UnixRpcClient::connect(&socket)
            .and_then(|mut client| client.call_value(filtered[1].clone(), params))
        {
            Ok(value) => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&value).unwrap_or_else(|_| "{}".to_string())
                );
                0
            }
            Err(err) => {
                eprintln!("cmux: {err}");
                1
            }
        }
    } else {
        eprintln!("cmux: Rust relay rewrite is not implemented for this command yet");
        2
    }
}

fn find_socket_flag(args: &[String]) -> Option<String> {
    let mut idx = 0;
    while idx < args.len() {
        if args[idx] == "--socket" && idx + 1 < args.len() {
            return Some(args[idx + 1].clone());
        }
        idx += 1;
    }
    None
}

fn strip_socket_flag(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut idx = 0;
    while idx < args.len() {
        if args[idx] == "--socket" && idx + 1 < args.len() {
            idx += 2;
            continue;
        }
        out.push(args[idx].clone());
        idx += 1;
    }
    out
}

fn read_socket_addr_file() -> Option<String> {
    let home = env::var("HOME").ok()?;
    let path = Path::new(&home).join(".cmux").join("socket_addr");
    let value = std::fs::read_to_string(path).ok()?;
    let trimmed = value.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn usage(stderr: &mut dyn Write) {
    let _ = writeln!(stderr, "Usage:");
    let _ = writeln!(stderr, "  cmuxd-remote version");
    let _ = writeln!(stderr, "  cmuxd-remote serve --stdio");
    let _ = writeln!(
        stderr,
        "  cmuxd-remote serve --unix --socket <path> [--ws-port <port> --ws-secret <secret>]"
    );
    let _ = writeln!(
        stderr,
        "  cmuxd-remote serve --tls --listen <addr> --server-id <id> --ticket-secret <secret> --cert-file <path> --key-file <path>"
    );
    let _ = writeln!(stderr, "  cmuxd-remote session <command> [args...]");
    let _ = writeln!(stderr, "  cmuxd-remote amux <command> [args...]");
    let _ = writeln!(stderr, "  cmuxd-remote tmux <command> [args...]");
    let _ = writeln!(stderr, "  cmuxd-remote cli rpc <method> [json-params]");
}

fn cli_usage(output: &mut dyn Write) {
    let _ = writeln!(
        output,
        "Usage: cmux [--socket <path>] [--json] <command> [args...]"
    );
}
