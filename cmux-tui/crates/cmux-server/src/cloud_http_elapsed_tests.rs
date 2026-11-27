//! Actual socket cancellation with the poster retained after its request returns.
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::fd::AsRawFd;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_link::elapsed::Elapsed;
use serde_json::json;

use super::{JsonPoster, RequestDeadline};

#[test]
fn vm_receiver_client_http_elapsed_cancels_stalled_headers() {
    stalled(false);
}

#[test]
fn vm_receiver_client_http_elapsed_cancels_stalled_body() {
    stalled(true);
}

fn stalled(body_started: bool) {
    // Client setup is outside the request's budget. Rewinding the system
    // observation models three seconds already charged between policy stages;
    // the active-clock deadline remains four seconds away.
    let http = JsonPoster::allowing_http().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/private-original-policy", listener.local_addr().unwrap());
    let (seen, observed) = mpsc::channel();
    let (closed, closure) = mpsc::channel();
    let server = std::thread::spawn(move || {
        let mut poll = libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: poll names one live descriptor, and cannot wait indefinitely
        // if client setup fails before it sends a request.
        if unsafe { libc::poll(&mut poll, 1, 8000) } != 1 {
            return;
        }
        let (mut stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(6))).unwrap();
        let mut headers = Vec::new();
        let mut byte = [0; 1];
        while !headers.ends_with(b"\r\n\r\n") && headers.len() < 8192 {
            stream.read_exact(&mut byte).unwrap();
            headers.push(byte[0]);
        }
        assert!(
            String::from_utf8(headers)
                .unwrap()
                .to_ascii_lowercase()
                .contains("authorization: bearer private-test-bearer")
        );
        let mut request_body = [0; 2];
        stream.read_exact(&mut request_body).unwrap();
        assert_eq!(&request_body, b"{}");
        if body_started {
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{").unwrap();
        }
        seen.send(()).unwrap();
        let disconnected = match stream.read(&mut byte) {
            Ok(0) => true,
            Err(e) => matches!(
                e.kind(),
                std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
            ),
            _ => false,
        };
        let _ = closed.send(disconnected);
    });
    let request_url = url.clone();
    let (finished, result) = mpsc::channel();
    let (release, held) = mpsc::channel();
    let client = std::thread::spawn(move || {
        let elapsed = Elapsed::system().unwrap().rewind(Duration::from_secs(3)).unwrap();
        let deadline =
            RequestDeadline::with_elapsed(Instant::now(), elapsed, Duration::from_secs(4)).unwrap();
        let answer = http.request_with_deadline(
            &request_url,
            Some(&json!({})),
            Some("private-test-bearer"),
            &deadline,
        );
        let _ = finished.send(answer);
        let _ = held.recv_timeout(Duration::from_secs(10));
        drop(http);
    });
    let saw_request = observed.recv_timeout(Duration::from_secs(5)).is_ok();
    let answer = result.recv_timeout(Duration::from_secs(2));
    let disconnected_while_retained = closure.recv_timeout(Duration::from_secs(1)).unwrap_or(false);
    // Always release and join both owned threads before reporting a regression.
    let _ = release.send(());
    client.join().unwrap();
    server.join().unwrap();
    assert!(saw_request, "fixture never observed the original authenticated request");
    let error =
        answer.expect("elapsed authority did not cancel the outstanding HTTP request").unwrap_err();
    assert!(!error.contains(&url) && !error.contains("private-test-bearer"));
    assert!(disconnected_while_retained, "expired request retained its credential-bearing socket");
}
