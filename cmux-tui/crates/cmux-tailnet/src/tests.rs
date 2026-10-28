use std::io::{Read, Write};
use std::net::TcpListener;

fn local_api(reply: &'static str) -> (crate::localapi::LocalApi, std::thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let worker = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        socket.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
        let mut bytes = Vec::new();
        let mut byte = [0];
        while !bytes.ends_with(b"\r\n\r\n") {
            socket.read_exact(&mut byte).unwrap();
            bytes.push(byte[0]);
        }
        socket.write_all(reply.as_bytes()).unwrap();
        String::from_utf8(bytes).unwrap()
    });
    (crate::localapi::LocalApi::new(&address.to_string(), "private-password").unwrap(), worker)
}

#[test]
fn logout_is_authenticated_and_signin_uses_the_correct_action() {
    for (action, path) in [(false, "/localapi/v0/logout"), (true, "/localapi/v0/login-interactive")]
    {
        let (api, worker) = local_api("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
        if action {
            api.login_interactive().unwrap();
        } else {
            api.logout().unwrap();
        }
        let request = worker.join().unwrap();
        assert!(request.starts_with(&format!("POST {path} HTTP/1.1")));
        assert!(request.to_ascii_lowercase().contains("authorization: basic "));
        assert!(request.to_ascii_lowercase().contains("sec-tailscale: localapi"));
    }
}

#[test]
fn local_api_refuses_redirects_without_exposing_error_bodies() {
    let (api, worker) = local_api(
        "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:1/secret\r\nContent-Length: 12\r\nConnection: close\r\n\r\nsecret-token",
    );
    let error = api.logout().unwrap_err().to_string();
    worker.join().unwrap();
    assert!(error.contains("307"));
    assert!(!error.contains("secret-token"));
    assert!(!error.contains("private-password"));
}

#[test]
fn certificate_is_requested_as_an_in_memory_pair() {
    let (api, worker) =
        local_api("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\npem-pair");
    assert_eq!(api.certificate_pair("example.test.ts.net").unwrap(), b"pem-pair");
    assert!(
        worker
            .join()
            .unwrap()
            .starts_with("GET /localapi/v0/cert/example.test.ts.net?type=pair HTTP/1.1")
    );
}

#[test]
fn local_api_can_drop_on_a_tokio_worker() {
    let api = crate::localapi::LocalApi::new("127.0.0.1:1", "private-password").unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async move {
        drop(api);
        tokio::task::yield_now().await;
    });
}
