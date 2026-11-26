//! The plain HTTP answers of the web + WebSocket port: the dashboard page and refusals.

use super::*;

pub(super) async fn refuse_ws_transport(
    mut stream: tokio::net::TcpStream,
    status: u16,
    error: &str,
) {
    let reason = match status {
        503 => "Service Unavailable",
        _ => "Bad Request",
    };
    let body = format!("{{\"error\":\"{error}\"}}\n");
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// Check the `Host` and `Origin` values of a complete request head.
fn check_head(policy: &ListenerPolicy, head: &str) -> Result<(), Refusal> {
    let mut hosts = Vec::new();
    let mut origins = Vec::new();
    for line in head.split("\r\n").skip(1) {
        if line.is_empty() {
            break;
        }
        let Some((name, value)) = line.split_once(':') else { continue };
        let name = name.trim();
        if name.eq_ignore_ascii_case("host") {
            hosts.push(value.trim());
        } else if name.eq_ignore_ascii_case("origin") {
            origins.push(value.trim());
        }
    }
    policy.check(&hosts, &origins)
}

pub(super) async fn refuse_http(mut stream: tokio::net::TcpStream, refusal: Refusal) {
    let status = match refusal.status() {
        401 => "401 Unauthorized",
        _ => "403 Forbidden",
    };
    let body = refusal.reason();
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/plain\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

/// Minimal HTTP for the dashboard. The whole head passes the listener rule
/// first; then GET / serves the dashboard and /app/ the shipped NEXT pane. The page is
/// static and holds no secret: it reads the token from its URL fragment,
/// which never reaches a server, and its WebSocket presents it.
pub(super) async fn serve_http(
    mut stream: tokio::net::TcpStream,
    head: &str,
    policy: &ListenerPolicy,
    peer: std::net::SocketAddr,
) {
    if let Err(refusal) = check_head(policy, head) {
        tracing::warn!("web request from {peer} refused: {refusal}");
        refuse_http(stream, refusal).await;
        return;
    }
    let first = head.lines().next().unwrap_or("");
    let mut parts = first.split_whitespace();
    let method_ = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let path = target.split_once('?').map_or(target, |(path, _)| path);
    let (status, body, ctype) = if !method_.eq_ignore_ascii_case("get") {
        ("405 Method Not Allowed", b"method not allowed".to_vec(), "text/plain")
    } else if path == "/health" {
        ("200 OK", b"ok".to_vec(), "text/plain")
    } else if path == "/" || path == "/index.html" {
        ("200 OK", INDEX_HTML.inflate().into_bytes(), "text/html; charset=utf-8")
    } else if path.starts_with("/app/") {
        app_assets::serve(path).await
    } else {
        ("404 Not Found", b"not found".to_vec(), "text/plain")
    };
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\ncache-control: no-store\r\nreferrer-policy: no-referrer\r\nx-content-type-options: nosniff\r\nconnection: close\r\n\r\n",
        body.len()
    );
    if stream.write_all(response.as_bytes()).await.is_ok() {
        let _ = stream.write_all(&body).await;
    }
    let _ = stream.shutdown().await;
}
