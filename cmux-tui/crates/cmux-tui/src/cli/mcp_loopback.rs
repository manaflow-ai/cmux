//! The loopback sign-in for a catalog server whose vendor takes only loopback redirects (RFC 8252;
//! Vercel answers `invalid_redirect_uri` to any other). The platform registers cmux with the vendor
//! for `http://127.0.0.1:<port>/callback`; the vendor sends the browser there, and this listener
//! answers `302` to the platform's own `GET /v1/mcp-servers/oauth/callback` with the query
//! unchanged, in the same browser tab, so the platform's `302` back to `return_to` lands too
//! (cmux-platform `docs/mcp-servers.md`, "A loopback entry"). The code is useless without the PKCE
//! verifier and client the platform holds, so nothing here reads or keeps it.
//!
//! `cmux mcp-servers connect` and `reconnect` start it only when the platform answers
//! `mcp_servers.loopback_required`: a detached `cmux mcp-servers loopback-serve` child that binds
//! the one fixed port, says `ready`, and serves until 10 minutes after the newest sign-in started
//! (the platform's state lives 10 minutes), or a minute after a callback. A second Connect while
//! it runs reuses it (`/cmux-loopback/ping` extends it); one left by a build signed in to another
//! platform is told to stop first.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::time::{Duration, Instant};

/// The fixed port: the vendor's registration names it, so it never moves
/// (`CMUX_MCP_LOOPBACK_PORT` overrides it for a test).
pub(super) const DEFAULT_PORT: u16 = 47_215;
/// How long a listener waits for its sign-in: the platform's state expires after 10 minutes.
const SIGN_IN_FOR: Duration = Duration::from_secs(600);
/// How long it lingers after forwarding a callback (another tab's sign-in may follow).
const AFTER_CALLBACK: Duration = Duration::from_secs(60);
const BANNER: &str = "cmux-loopback";
/// The platform path a callback is forwarded to.
pub(super) const CALLBACK_PATH: &str = "/v1/mcp-servers/oauth/callback";

pub(super) fn port() -> u16 {
    std::env::var("CMUX_MCP_LOOPBACK_PORT")
        .ok()
        .and_then(|v| v.trim().parse::<u16>().ok())
        .filter(|p| *p >= 1024)
        .unwrap_or(DEFAULT_PORT)
}

/// The platform callback this listener forwards to: `<origin>/v1/mcp-servers/oauth/callback`, an
/// https origin (or http on loopback, a local platform), no query or fragment.
pub(super) fn valid_forward(url: &str) -> bool {
    let Some(origin) = url.strip_suffix(CALLBACK_PATH) else { return false };
    if url.len() > 300
        || url.contains(['?', '#', '@', '\\'])
        || url.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        return false;
    }
    let host = origin
        .strip_prefix("https://")
        .or_else(|| {
            origin.strip_prefix("http://").filter(|h| {
                let name = h.split(':').next().unwrap_or_default();
                name == "127.0.0.1" || name == "localhost"
            })
        })
        .unwrap_or_default();
    !host.is_empty() && !host.contains('/')
}

/// One request's line and Host header, the rest ignored. `None` for anything that is not a short GET.
pub(super) fn read_request(stream: &mut impl Read) -> Option<(String, Option<String>)> {
    let mut reader = BufReader::new(stream.take(8192));
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let mut parts = line.split_ascii_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?.to_owned();
    let mut host = None;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).ok()? == 0 || header.trim().is_empty() {
            break;
        }
        if let Some((name, value)) = header.split_once(':')
            && name.trim().eq_ignore_ascii_case("host")
        {
            host = Some(value.trim().to_owned());
        }
    }
    Some((target, host))
}

/// What the listener does with one request target.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Reply {
    /// `302` to the platform callback with this query, unchanged.
    Forward(String),
    /// The reuse probe: answers the banner and the forward URL, and extends the wait.
    Ping,
    /// A listener for another platform: stop now.
    Stop,
    NotFound,
}

pub(super) fn route(target: &str, host: Option<&str>, port: u16) -> Reply {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    match path {
        "/callback" if !query.is_empty() => Reply::Forward(query.to_owned()),
        // The probes come only from this machine's cmux, by its loopback address (no DNS rebinding).
        "/cmux-loopback/ping" | "/cmux-loopback/stop"
            if host == Some(format!("127.0.0.1:{port}").as_str()) =>
        {
            if path.ends_with("ping") {
                Reply::Ping
            } else {
                Reply::Stop
            }
        }
        _ => Reply::NotFound,
    }
}

fn respond(stream: &mut TcpStream, status: &str, headers: &[(&str, &str)], body: &str) {
    let mut out = format!("HTTP/1.1 {status}\r\nConnection: close\r\nCache-Control: no-store\r\n");
    for (name, value) in headers {
        out.push_str(&format!("{name}: {value}\r\n"));
    }
    out.push_str(&format!("Content-Length: {}\r\n\r\n{body}", body.len()));
    let _ = stream.write_all(out.as_bytes());
    let _ = stream.flush();
}

/// `cmux mcp-servers loopback-serve --port P --forward URL`: bind, print `ready` (or `in-use`), serve.
pub(super) fn serve_main(words: &[String]) -> i32 {
    let mut port = None;
    let mut forward = None;
    let mut args = words.iter();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => {
                port = args.next().and_then(|v| v.parse::<u16>().ok()).filter(|p| *p >= 1024);
            }
            "--forward" => forward = args.next().filter(|v| valid_forward(v)).cloned(),
            _ => return 2,
        }
    }
    let (Some(port), Some(forward)) = (port, forward) else {
        eprintln!("cmux mcp-servers loopback-serve: --port PORT --forward PLATFORM_CALLBACK");
        return 2;
    };
    let listener = match TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, port))) {
        Ok(l) => l,
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            println!("in-use");
            return 1;
        }
        Err(_) => {
            println!("failed");
            return 1;
        }
    };
    println!("ready");
    let _ = std::io::stdout().flush();
    if listener.set_nonblocking(true).is_err() {
        return 1;
    }
    let mut deadline = Instant::now() + SIGN_IN_FOR;
    while Instant::now() < deadline {
        let mut stream = match listener.accept() {
            Ok((s, _)) => s,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100));
                continue;
            }
            Err(_) => continue,
        };
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let Some((target, host)) = read_request(&mut stream) else {
            respond(&mut stream, "400 Bad Request", &[], "");
            continue;
        };
        match route(&target, host.as_deref(), port) {
            Reply::Forward(query) => {
                let location = format!("{forward}?{query}");
                respond(
                    &mut stream,
                    "302 Found",
                    &[("Location", &location), ("Content-Type", "text/plain; charset=utf-8")],
                    "Finishing the sign-in in cmux…",
                );
                deadline = deadline.min(Instant::now() + AFTER_CALLBACK);
            }
            Reply::Ping => {
                respond(
                    &mut stream,
                    "200 OK",
                    &[("Content-Type", "text/plain")],
                    &format!("{BANNER} {forward}"),
                );
                deadline = Instant::now() + SIGN_IN_FOR;
            }
            Reply::Stop => {
                respond(&mut stream, "200 OK", &[], "");
                return 0;
            }
            Reply::NotFound => respond(&mut stream, "404 Not Found", &[], ""),
        }
    }
    0
}

/// Sends one probe to a listener on `port`; its body, or `None` when nothing (or not cmux) answers.
fn probe(port: u16, path: &str) -> Option<String> {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(500)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let request =
        format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).ok()?;
    let mut answer = String::new();
    let _ = stream.take(4096).read_to_string(&mut answer);
    let body = answer.split_once("\r\n\r\n")?.1;
    Some(body.to_owned())
}

/// Ensures a listener forwarding to `forward` holds `port`: reuses (and extends) one already there,
/// stops one for another platform, else starts a detached `loopback-serve`. `Err` says why not.
pub(super) fn ensure(port: u16, forward: &str) -> Result<(), String> {
    match probe(port, "/cmux-loopback/ping") {
        Some(body) if body == format!("{BANNER} {forward}") => return Ok(()),
        Some(body) if body.starts_with(BANNER) => {
            let _ = probe(port, "/cmux-loopback/stop");
            std::thread::sleep(Duration::from_millis(200));
        }
        _ => {}
    }
    let exe = std::env::current_exe()
        .map_err(|_| "could not find the cmux CLI to listen for the sign-in".to_owned())?;
    let mut command = cmux_process::Command::new(exe);
    command
        .args(["mcp-servers", "loopback-serve", "--port", &port.to_string(), "--forward", forward])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        // Its own process group: the app's Process ending the CLI never takes the listener with it.
        .process_group(0);
    let mut child =
        command.spawn().map_err(|_| "could not start the sign-in listener".to_owned())?;
    // It must wait for the browser after this CLI exits; it ends itself (SIGN_IN_FOR, AFTER_CALLBACK).
    child.detach(
        "the sign-in listener waits for the browser after the CLI exits, and times itself out",
    );
    let mut first = String::new();
    if let Some(out) = child.stdout.take() {
        let _ = BufReader::new(out).read_line(&mut first);
    }
    match first.trim() {
        "ready" => Ok(()),
        "in-use" => Err(format!(
            "port {port} on this Mac is taken by another program; quit it and Connect again"
        )),
        _ => Err("the sign-in listener did not start".into()),
    }
}

#[cfg(test)]
#[path = "mcp_loopback_tests.rs"]
mod tests;
