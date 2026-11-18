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
    let sent = Mutex::new(0_u32);
    let answers = Mutex::new(answers.into_iter());
    let result = retry_connect(
        tries,
        Fake { copyable },
        |fake: &Fake| fake.copyable.then_some(Fake { copyable: fake.copyable }),
        |_fake: Fake| {
            let n = {
                let mut sent = sent.lock().unwrap();
                *sent += 1;
                *sent
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
    let sent = *sent.lock().unwrap();
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

/// A refused local port is a connect error to reqwest (what [`super::send`] retries on), and a
/// client with [`super::CONNECT_TIMEOUT`] builds.
#[tokio::test]
async fn reqwest_calls_a_refused_connect_a_connect_error() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let client =
        reqwest::Client::builder().connect_timeout(super::CONNECT_TIMEOUT).build().unwrap();
    let error = super::send(client.post(format!("http://127.0.0.1:{port}/v1/x")).body("{}"))
        .await
        .unwrap_err();
    assert!(error.is_connect(), "{error:?}");
}
