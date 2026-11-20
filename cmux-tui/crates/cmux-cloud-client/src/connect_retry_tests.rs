//! The connect-phase retry with an injected send: which try connects, and which error is a
//! connect failure. No network.

use std::sync::Mutex;

use super::retry_connect;

/// A request: its try number once sent, and whether it can be copied.
#[derive(Debug)]
struct Fake {
    copyable: bool,
}

#[derive(Debug, PartialEq, Eq)]
enum Error {
    /// It never connected: nothing of the request was written.
    Connect(u32),
    /// It connected and then failed (a timeout waiting for the answer, a reset).
    AfterConnect(u32),
}

/// What each try answers, in order; a try past the list connects.
async fn run(
    copyable: bool,
    tries: u32,
    answers: Vec<Result<&'static str, Error>>,
) -> (Result<&'static str, Error>, u32) {
    let (result, lasts) = run_marked(copyable, tries, answers).await;
    (result, lasts.len() as u32)
}

/// [`run`], answering for each try sent whether it was sent as the last (the patient connect).
async fn run_marked(
    copyable: bool,
    tries: u32,
    answers: Vec<Result<&'static str, Error>>,
) -> (Result<&'static str, Error>, Vec<bool>) {
    let sent = Mutex::new(Vec::new());
    let answers = Mutex::new(answers.into_iter());
    let result = retry_connect(
        tries,
        Fake { copyable },
        |fake: &Fake| fake.copyable.then_some(Fake { copyable: fake.copyable }),
        |_fake: Fake, last: bool| {
            let n = {
                let mut sent = sent.lock().unwrap();
                sent.push(last);
                sent.len() as u32
            };
            let answer = answers.lock().unwrap().next().unwrap_or(Ok("answered"));
            let answer = answer.map_err(|error| match error {
                Error::Connect(_) => Error::Connect(n),
                Error::AfterConnect(_) => Error::AfterConnect(n),
            });
            async move { answer }
        },
        |error: &Error| matches!(error, Error::Connect(_)),
    )
    .await;
    let sent = sent.lock().unwrap().clone();
    (result, sent)
}

#[tokio::test]
async fn a_request_that_connects_is_sent_once() {
    assert_eq!(run(true, 3, vec![Ok("first")]).await, (Ok("first"), 1));
}

#[tokio::test]
async fn a_connect_failure_is_sent_again_on_a_new_try() {
    let (result, sent) = run(true, 3, vec![Err(Error::Connect(0)), Ok("second")]).await;
    assert_eq!(result, Ok("second"));
    assert_eq!(sent, 2);
}

#[tokio::test]
async fn connect_failures_stop_at_the_try_limit_with_the_last_one() {
    let answers =
        vec![Err(Error::Connect(0)), Err(Error::Connect(0)), Err(Error::Connect(0)), Ok("never")];
    assert_eq!(run(true, 3, answers).await, (Err(Error::Connect(3)), 3));
}

#[tokio::test]
async fn a_failure_after_the_connect_is_never_sent_again() {
    // The request may have reached the server: a mutation without a key must not run twice.
    let answers = vec![Err(Error::AfterConnect(0)), Ok("never")];
    assert_eq!(run(true, 3, answers).await, (Err(Error::AfterConnect(1)), 1));
}

#[tokio::test]
async fn a_request_that_cannot_be_copied_is_sent_once() {
    let answers = vec![Err(Error::Connect(0)), Ok("never")];
    assert_eq!(run(false, 3, answers).await, (Err(Error::Connect(1)), 1));
}

#[tokio::test]
async fn zero_tries_still_sends_once() {
    let answers = vec![Err(Error::Connect(0)), Ok("never")];
    assert_eq!(run(true, 0, answers).await, (Err(Error::Connect(1)), 1));
}

/// Only the last try connects patiently: the early ones keep the short connect timeout, and the
/// last, after every short one failed to connect, waits as long as the request's own timeout.
#[tokio::test]
async fn only_the_last_try_is_sent_as_the_patient_one() {
    let answers = vec![Err(Error::Connect(0)), Err(Error::Connect(0)), Ok("slow")];
    assert_eq!(run_marked(true, 3, answers).await, (Ok("slow"), vec![false, false, true]));
    assert_eq!(run_marked(true, 3, vec![Ok("first")]).await, (Ok("first"), vec![false]));
}

/// A request sent once (its body cannot be copied, or one try only) is that last try.
#[tokio::test]
async fn a_request_sent_once_is_sent_as_the_patient_one() {
    assert_eq!(run_marked(false, 3, vec![Ok("once")]).await, (Ok("once"), vec![true]));
    assert_eq!(run_marked(true, 1, vec![Ok("once")]).await, (Ok("once"), vec![true]));
}

/// A refused local port is a connect error to reqwest (what [`super::send`] retries on), and a
/// client with [`super::CONNECT_TIMEOUT`] builds.
#[tokio::test]
async fn reqwest_calls_a_refused_connect_a_connect_error() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let clients = super::Clients::build(reqwest::Client::builder).unwrap();
    let request = clients.fast.post(format!("http://127.0.0.1:{port}/v1/x")).body("{}");
    let error = super::send(&clients, request).await.unwrap_err();
    assert!(error.is_connect(), "{error:?}");
}

/// The patient last try sends the request as it was built, its own timeout included: a local
/// server that answers at once answers it through either client.
#[tokio::test]
async fn the_patient_try_sends_the_built_request() {
    use std::io::{Read as _, Write as _};
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut seen = Vec::new();
        let mut buf = [0_u8; 1024];
        while !seen.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = stream.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            seen.extend_from_slice(&buf[..n]);
        }
        stream.write_all(b"HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n").unwrap();
        String::from_utf8_lossy(&seen).into_owned()
    });
    let clients = super::Clients::build(reqwest::Client::builder).unwrap();
    // A stream body cannot be copied: its one try is the last, through the patient client.
    let empty = futures::stream::empty::<Result<Vec<u8>, std::io::Error>>();
    let body = reqwest::Body::wrap_stream(empty);
    let request = clients
        .fast
        .get(format!("http://127.0.0.1:{port}/v1/x"))
        .header("x-probe", "1")
        .timeout(std::time::Duration::from_secs(5))
        .body(body);
    let response = super::send(&clients, request).await.unwrap();
    assert_eq!(response.status().as_u16(), 204);
    let seen = server.join().unwrap();
    assert!(seen.contains("x-probe: 1"), "{seen}");
}
