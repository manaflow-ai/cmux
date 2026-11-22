#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

use axum::body::Body;
use axum::body::to_bytes;
use axum::http::Request as HttpRequest;
use cmux_remote_protocol::{RequestId, WorkspaceRequest};
use tempfile::tempdir;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tower::ServiceExt;

use super::*;

fn request(authorization: Option<&str>) -> HttpRequest<Body> {
    workspace_request(authorization, 1, WorkspaceRequest::Capabilities)
}

fn workspace_request(
    authorization: Option<&str>,
    request_id: u128,
    request: WorkspaceRequest,
) -> HttpRequest<Body> {
    let rpc = RpcRequest { id: RequestId::from_u128(request_id), timeout_ms: None, request };
    let mut builder = HttpRequest::builder()
        .method("POST")
        .uri("/v1/workspace-rpc")
        .header("content-type", "application/json");
    if let Some(authorization) = authorization {
        builder = builder.header(AUTHORIZATION, authorization);
    }
    builder.body(Body::from(serde_json::to_vec(&rpc).unwrap())).unwrap()
}

async fn decode_rpc_response(response: Response) -> RpcResponse {
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), MAX_HTTP_RPC_BODY_BYTES).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}

fn raw_capabilities_request(
    address: SocketAddr,
    token: &WorkspaceHttpBearerToken,
    request_id: u128,
) -> Vec<u8> {
    raw_capabilities_request_with_connection(address, token, request_id, "close")
}

fn raw_capabilities_request_with_connection(
    address: SocketAddr,
    token: &WorkspaceHttpBearerToken,
    request_id: u128,
    connection: &str,
) -> Vec<u8> {
    let rpc = RpcRequest {
        id: RequestId::from_u128(request_id),
        timeout_ms: None,
        request: WorkspaceRequest::Capabilities,
    };
    let body = serde_json::to_vec(&rpc).unwrap();
    let mut request = format!(
        "POST /v1/workspace-rpc HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: {connection}\r\n\r\n",
        token.0.as_str(),
        body.len()
    )
    .into_bytes();
    request.extend_from_slice(&body);
    request
}

async fn read_raw_http_response(connection: &mut TcpStream) -> Vec<u8> {
    let mut response = Vec::new();
    loop {
        let header_end = response.windows(4).position(|bytes| bytes == b"\r\n\r\n");
        if let Some(header_end) = header_end {
            let headers = std::str::from_utf8(&response[..header_end]).unwrap();
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .expect("raw HTTP response omitted Content-Length");
            if response.len() >= header_end + 4 + content_length {
                return response;
            }
        }
        let read = connection.read_buf(&mut response).await.unwrap();
        assert_ne!(read, 0, "HTTP connection closed before its response completed");
    }
}

#[tokio::test]
async fn workspace_http_authenticates_before_rpc_dispatch() {
    let token = WorkspaceHttpBearerToken::test_value();
    let authorization = format!("Bearer {}", token.0.as_str());
    let router = workspace_http_router(WorkspaceService::new(), token);

    let unauthorized = router.clone().oneshot(request(None)).await.unwrap();
    assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
    assert_eq!(unauthorized.headers().get(CONNECTION).unwrap(), "close");
    assert_eq!(
        router.clone().oneshot(request(Some("Bearer wrong"))).await.unwrap().status(),
        StatusCode::UNAUTHORIZED
    );
    let response = router.oneshot(request(Some(&authorization))).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), MAX_HTTP_RPC_BODY_BYTES).await.unwrap();
    let response: RpcResponse = serde_json::from_slice(&body).unwrap();
    assert!(response.result.is_ok());
}

#[tokio::test]
async fn workspace_http_refuses_browser_origins_even_with_the_token() {
    let token = WorkspaceHttpBearerToken::test_value();
    let authorization = format!("Bearer {}", token.0.as_str());
    let router = workspace_http_router(WorkspaceService::new(), token);
    for origin in ["https://evil.example", "null", "http://127.0.0.1:1"] {
        let mut request = request(Some(&authorization));
        request.headers_mut().insert(ORIGIN, HeaderValue::from_static(origin));
        let response = router.clone().oneshot(request).await.unwrap();
        assert_eq!(response.status(), StatusCode::FORBIDDEN, "{origin}");
        assert_eq!(response.headers().get(CONNECTION).unwrap(), "close");
    }
}

#[tokio::test]
async fn dropped_http_page_keeps_its_parent_cursor_retryable() {
    let directory = tempdir().unwrap();
    for name in ["a.txt", "b.txt", "c.txt"] {
        tokio::fs::write(directory.path().join(name), name).await.unwrap();
    }
    let workspace = WorkspaceService::new();
    let opened = workspace
        .handle_request(WorkspaceRequest::OpenWorkspace {
            root: directory.path().to_string_lossy().into_owned(),
        })
        .await
        .unwrap();
    let WorkspaceResponse::Workspace { id, .. } = opened else { panic!() };
    let token = WorkspaceHttpBearerToken::test_value();
    let authorization = format!("Bearer {}", token.0.as_str());
    let router = workspace_http_router(workspace, token);

    let first = decode_rpc_response(
        router
            .clone()
            .oneshot(workspace_request(
                Some(&authorization),
                1,
                WorkspaceRequest::ListDirectory {
                    workspace: id.clone(),
                    path: String::new(),
                    include_hidden: false,
                    limit: 1,
                    cursor: None,
                },
            ))
            .await
            .unwrap(),
    )
    .await;
    let WorkspaceResponse::Directory { next_cursor: Some(parent), .. } = first.result.unwrap()
    else {
        panic!()
    };

    let dropped = router
        .clone()
        .oneshot(workspace_request(
            Some(&authorization),
            2,
            WorkspaceRequest::ListDirectory {
                workspace: id.clone(),
                path: String::new(),
                include_hidden: false,
                limit: 1,
                cursor: Some(parent.clone()),
            },
        ))
        .await
        .unwrap();
    drop(dropped);

    let mut retries = Vec::new();
    for request_id in [3, 4] {
        let response = decode_rpc_response(
            router
                .clone()
                .oneshot(workspace_request(
                    Some(&authorization),
                    request_id,
                    WorkspaceRequest::ListDirectory {
                        workspace: id.clone(),
                        path: String::new(),
                        include_hidden: false,
                        limit: 1,
                        cursor: Some(parent.clone()),
                    },
                ))
                .await
                .unwrap(),
        )
        .await;
        let WorkspaceResponse::Directory { entries, next_cursor: Some(successor), .. } =
            response.result.unwrap()
        else {
            panic!()
        };
        retries.push((entries, successor));
    }
    assert_eq!(retries[0].0, retries[1].0);
    assert_eq!(retries[0].0[0].name, "b.txt");
    assert_eq!(retries[0].1, retries[1].1);
}

#[tokio::test]
async fn authenticated_rest_action_applies_native_codex_patch() {
    let directory = tempdir().unwrap();
    let workspace = WorkspaceService::new();
    let opened = workspace
        .handle_request(WorkspaceRequest::OpenWorkspace {
            root: directory.path().to_str().unwrap().to_owned(),
        })
        .await
        .unwrap();
    let WorkspaceResponse::Workspace { id, .. } = opened else { panic!() };
    let token = WorkspaceHttpBearerToken::test_value();
    let authorization = format!("Bearer {}", token.0.as_str());
    let router = workspace_http_router(workspace, token);
    let patch = "*** Begin Patch\n*** Add File: created.txt\n+created\n*** End Patch\n";
    let request = HttpRequest::builder()
        .method("POST")
        .uri(format!("/v1/workspaces/{}/apply-patch", id.0))
        .header(AUTHORIZATION, authorization)
        .header("content-type", "text/plain")
        .body(Body::from(patch))
        .unwrap();

    let response = router.oneshot(request).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), MAX_HTTP_RPC_BODY_BYTES).await.unwrap();
    let response: WorkspaceHttpResponse = serde_json::from_slice(&body).unwrap();
    assert!(response.result.is_ok());
    assert_eq!(tokio::fs::read(directory.path().join("created.txt")).await.unwrap(), b"created\n");
}

#[test]
fn workspace_http_token_file_is_owner_only_and_stable() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("workspace-http.token");
    let first = load_or_create_workspace_http_token(&path).unwrap();
    let second = load_or_create_workspace_http_token(&path).unwrap();
    assert!(bool::from(first.0.as_bytes().ct_eq(second.0.as_bytes())));
    #[cfg(unix)]
    assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
}

#[test]
fn workspace_http_token_reader_bounds_growth_after_metadata_check() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("workspace-http.token");
    fs::write(&path, b"x").unwrap();
    #[cfg(unix)]
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();

    let mut file = OpenOptions::new().read(true).open(&path).unwrap();
    let metadata = file.metadata().unwrap();
    validate_workspace_http_token_metadata(&metadata).unwrap();
    OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(&vec![b'x'; MAX_HTTP_TOKEN_FILE_BYTES as usize])
        .unwrap();

    let error = read_workspace_http_token_contents(&mut file).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    assert_eq!(error.to_string(), "HTTP token file is too large");
}

#[tokio::test]
async fn workspace_http_refuses_plaintext_non_loopback_bind() {
    let directory = tempdir().unwrap();
    let error = serve_workspace_http(
        WorkspaceService::new(),
        "0.0.0.0:0".parse().unwrap(),
        directory.path().join("token"),
    )
    .await
    .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
}

#[tokio::test]
async fn partial_headers_expire_and_raw_connection_admission_is_bounded() {
    let directory = tempdir().unwrap();
    let limits = WorkspaceHttpAdmissionLimits {
        maximum_connections: 1,
        header_timeout: Duration::from_millis(300),
        request_body_timeout: Duration::from_millis(300),
        graceful_shutdown_timeout: Duration::from_millis(300),
        maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
    };
    let server = serve_workspace_http_with_limits(
        WorkspaceService::new(),
        "127.0.0.1:0".parse().unwrap(),
        directory.path().join("token"),
        limits,
    )
    .await
    .unwrap();
    let address = server.local_addr();

    let mut slow_connections = Vec::new();
    for _ in 0..limits.maximum_connections {
        let mut connection = TcpStream::connect(address).await.unwrap();
        connection.write_all(b"POST /v1/workspace-rpc HTTP/1.1\r\nHost:").await.unwrap();
        slow_connections.push(connection);
    }
    tokio::time::sleep(Duration::from_millis(20)).await;

    let token = read_workspace_http_token(server.token_file()).unwrap();
    let request = raw_capabilities_request(address, &token, 2);
    let mut queued = TcpStream::connect(address).await.unwrap();
    queued.write_all(&request).await.unwrap();

    let mut first_byte = [0_u8; 1];
    assert!(
        tokio::time::timeout(Duration::from_millis(50), queued.read(&mut first_byte),)
            .await
            .is_err(),
        "a request bypassed raw connection admission"
    );

    let slow_result =
        tokio::time::timeout(Duration::from_secs(2), slow_connections[0].read(&mut first_byte))
            .await
            .expect("partial HTTP headers did not expire");
    assert!(matches!(slow_result, Ok(0) | Err(_)), "partial HTTP connection remained open");

    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), queued.read_to_end(&mut response))
        .await
        .expect("queued request was not admitted after the header deadline")
        .unwrap();
    assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn oversized_headers_close_and_release_raw_connection_admission() {
    let directory = tempdir().unwrap();
    let limits = WorkspaceHttpAdmissionLimits {
        maximum_connections: 1,
        header_timeout: Duration::from_secs(2),
        request_body_timeout: Duration::from_secs(2),
        graceful_shutdown_timeout: Duration::from_secs(2),
        maximum_header_bytes: 8 * 1024,
    };
    let server = serve_workspace_http_with_limits(
        WorkspaceService::new(),
        "127.0.0.1:0".parse().unwrap(),
        directory.path().join("token"),
        limits,
    )
    .await
    .unwrap();
    let address = server.local_addr();

    let mut oversized = TcpStream::connect(address).await.unwrap();
    let mut oversized_header = b"POST /v1/workspace-rpc HTTP/1.1\r\nX-Fill: ".to_vec();
    oversized_header.extend(std::iter::repeat_n(b'a', limits.maximum_header_bytes));
    oversized.write_all(&oversized_header).await.unwrap();

    let token = read_workspace_http_token(server.token_file()).unwrap();
    let request = raw_capabilities_request(address, &token, 3);
    let mut queued = TcpStream::connect(address).await.unwrap();
    queued.write_all(&request).await.unwrap();

    let mut rejected = Vec::new();
    let rejected =
        tokio::time::timeout(Duration::from_secs(1), oversized.read_to_end(&mut rejected))
            .await
            .expect("oversized HTTP headers did not close");
    if let Err(error) = rejected {
        assert!(
            matches!(
                error.kind(),
                io::ErrorKind::ConnectionAborted
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::BrokenPipe
            ),
            "unexpected oversized-header close error: {error}"
        );
    }

    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), queued.read_to_end(&mut response))
        .await
        .expect("oversized headers did not release raw connection admission")
        .unwrap();
    assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn partial_second_keep_alive_header_expires_and_releases_admission() {
    let directory = tempdir().unwrap();
    let limits = WorkspaceHttpAdmissionLimits {
        maximum_connections: 1,
        header_timeout: Duration::from_millis(200),
        request_body_timeout: Duration::from_millis(200),
        graceful_shutdown_timeout: Duration::from_millis(200),
        maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
    };
    let server = serve_workspace_http_with_limits(
        WorkspaceService::new(),
        "127.0.0.1:0".parse().unwrap(),
        directory.path().join("token"),
        limits,
    )
    .await
    .unwrap();
    let address = server.local_addr();
    let token = read_workspace_http_token(server.token_file()).unwrap();
    let mut keep_alive = TcpStream::connect(address).await.unwrap();
    keep_alive
        .write_all(&raw_capabilities_request_with_connection(address, &token, 4, "keep-alive"))
        .await
        .unwrap();
    let response = read_raw_http_response(&mut keep_alive).await;
    assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));

    keep_alive.write_all(b"POST /v1/workspace-rpc HTTP/1.1\r\nHost:").await.unwrap();
    let mut first_byte = [0_u8; 1];
    let expired = tokio::time::timeout(Duration::from_secs(2), keep_alive.read(&mut first_byte))
        .await
        .expect("the second keep-alive header had no deadline");
    assert!(matches!(expired, Ok(0) | Err(_)), "partial second header remained open");

    let mut replacement = TcpStream::connect(address).await.unwrap();
    replacement.write_all(&raw_capabilities_request(address, &token, 5)).await.unwrap();
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), replacement.read_to_end(&mut response))
        .await
        .expect("expired keep-alive connection retained its admission permit")
        .unwrap();
    assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn stalled_declared_request_body_expires_and_releases_admission() {
    let directory = tempdir().unwrap();
    let limits = WorkspaceHttpAdmissionLimits {
        maximum_connections: 1,
        header_timeout: Duration::from_millis(200),
        request_body_timeout: Duration::from_millis(200),
        graceful_shutdown_timeout: Duration::from_millis(200),
        maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
    };
    let server = serve_workspace_http_with_limits(
        WorkspaceService::new(),
        "127.0.0.1:0".parse().unwrap(),
        directory.path().join("token"),
        limits,
    )
    .await
    .unwrap();
    let address = server.local_addr();
    let token = read_workspace_http_token(server.token_file()).unwrap();
    let mut stalled = TcpStream::connect(address).await.unwrap();
    stalled
        .write_all(
            format!(
                "POST /v1/workspace-rpc HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{{",
                token.0.as_str()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), stalled.read_to_end(&mut response))
        .await
        .expect("declared request body had no idle deadline")
        .unwrap();

    let mut replacement = TcpStream::connect(address).await.unwrap();
    replacement.write_all(&raw_capabilities_request(address, &token, 6)).await.unwrap();
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(2), replacement.read_to_end(&mut response))
        .await
        .expect("stalled body retained its admission permit")
        .unwrap();
    assert!(String::from_utf8(response).unwrap().starts_with("HTTP/1.1 200 OK"));
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn workspace_http_shutdown_is_bounded_with_a_stalled_request() {
    let directory = tempdir().unwrap();
    let limits = WorkspaceHttpAdmissionLimits {
        maximum_connections: 1,
        header_timeout: Duration::from_millis(100),
        request_body_timeout: Duration::from_secs(60),
        graceful_shutdown_timeout: Duration::from_millis(100),
        maximum_header_bytes: MAX_HTTP_HEADER_BYTES,
    };
    let server = serve_workspace_http_with_limits(
        WorkspaceService::new(),
        "127.0.0.1:0".parse().unwrap(),
        directory.path().join("token"),
        limits,
    )
    .await
    .unwrap();
    let address = server.local_addr();
    let token = read_workspace_http_token(server.token_file()).unwrap();
    let mut stalled = TcpStream::connect(address).await.unwrap();
    stalled
        .write_all(
            format!(
                "POST /v1/workspace-rpc HTTP/1.1\r\nHost: {address}\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{{",
                token.0.as_str()
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(20)).await;

    tokio::time::timeout(Duration::from_secs(1), server.shutdown())
        .await
        .expect("workspace HTTP graceful shutdown was unbounded")
        .unwrap();
}
