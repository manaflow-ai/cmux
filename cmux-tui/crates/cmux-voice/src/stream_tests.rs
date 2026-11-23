use super::*;
use crate::endpoint::{Settings, resolve};
use crate::session::Shown;
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};

fn endpoint(engine: &str, url: &str) -> Endpoint {
    resolve(&Settings { engine: engine.into(), url: url.into(), model: String::new() })
        .endpoint
        .unwrap()
}

/// A stand-in realtime server: checks the upgrade, records every client message, and answers
/// each `input_audio_buffer.append` count and the commit with the scripted messages.
struct Fake {
    url: String,
    seen: Arc<Mutex<Vec<Value>>>,
    auth: Arc<Mutex<Option<String>>>,
    path: Arc<Mutex<String>>,
}

/// `script(n, message)`: what to answer after the client's `n`th message (0 = session.update).
async fn fake(script: fn(usize, &Value) -> Vec<Value>) -> Fake {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let auth = Arc::new(Mutex::new(None));
    let path = Arc::new(Mutex::new(String::new()));
    let (s, a, p) = (seen.clone(), auth.clone(), path.clone());
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let callback = |req: &Request, res: Response| {
            *a.lock().unwrap() =
                req.headers().get("authorization").map(|v| v.to_str().unwrap().to_owned());
            *p.lock().unwrap() = req.uri().to_string();
            Ok(res)
        };
        let mut ws = tokio_tungstenite::accept_hdr_async(stream, callback).await.unwrap();
        let mut n = 0;
        while let Some(Ok(message)) = ws.next().await {
            let Message::Text(text) = message else { continue };
            let value: Value = serde_json::from_str(&text).unwrap();
            s.lock().unwrap().push(value.clone());
            for answer in script(n, &value) {
                if ws.send(Message::Text(answer.to_string().into())).await.is_err() {
                    return;
                }
            }
            n += 1;
        }
    });
    Fake { url, seen, auth, path }
}

fn kind(v: &Value) -> &str {
    v["type"].as_str().unwrap_or_default()
}

/// Speaks two utterances while audio flows; the stop's commit names a third.
fn two_utterances(n: usize, message: &Value) -> Vec<Value> {
    match (n, kind(message)) {
        (1, "input_audio_buffer.append") => vec![
            json!({"type": "input_audio_buffer.committed", "item_id": "i1"}),
            json!({"type": "conversation.item.input_audio_transcription.delta", "item_id": "i1", "delta": "Hello"}),
            json!({"type": "conversation.item.input_audio_transcription.delta", "item_id": "i1", "delta": " world"}),
            json!({"type": "conversation.item.input_audio_transcription.completed", "item_id": "i1", "transcript": "Hello world."}),
        ],
        (2, "input_audio_buffer.append") => vec![
            json!({"type": "conversation.item.input_audio_transcription.delta", "item_id": "i2", "delta": "and more"}),
        ],
        (_, "input_audio_buffer.commit") => vec![
            json!({"type": "input_audio_buffer.committed", "item_id": "i2"}),
            json!({"type": "conversation.item.input_audio_transcription.completed", "item_id": "i2", "transcript": "And more."}),
        ],
        _ => vec![],
    }
}

async fn drain(mut rx: mpsc::Receiver<Shown>) -> Vec<Shown> {
    let mut all = Vec::new();
    while let Some(s) = rx.recv().await {
        all.push(s);
    }
    all
}

#[tokio::test]
async fn words_stream_in_while_speaking_and_the_stop_brings_the_last() {
    let fake = fake(two_utterances).await;
    let ep = endpoint("openai", &fake.url);
    let (tx, rx) = mpsc::channel(8);
    let (shown_tx, shown_rx) = mpsc::channel(64);
    let run = tokio::spawn(run(
        ep,
        Some(" sk-test ".into()),
        Http::default(),
        Some("en-US".into()),
        rx,
        shown_tx,
    ));
    tx.send(Command::Audio(vec![0, 300, 600, 900])).await.unwrap();
    tx.send(Command::Audio(vec![1200, 1500])).await.unwrap();
    tx.send(Command::Stop).await.unwrap();
    let text = run.await.unwrap().unwrap();
    assert_eq!(text, "Hello world. And more.");
    assert_eq!(
        drain(shown_rx).await,
        vec![
            Shown::Partial("Hello".into()),
            Shown::Partial("Hello world".into()),
            Shown::Final("Hello world.".into()),
            Shown::Partial("and more".into()),
            Shown::Final("And more.".into()),
        ]
    );
    assert_eq!(fake.auth.lock().unwrap().as_deref(), Some("Bearer sk-test"));
    assert_eq!(fake.path.lock().unwrap().as_str(), "/v1/realtime?intent=transcription");
    let seen = fake.seen.lock().unwrap().clone();
    assert_eq!(seen[0], session_update("gpt-4o-mini-transcribe", Some("en")));
    assert_eq!(seen[0]["session"]["audio"]["input"]["transcription"]["language"], "en");
    assert_eq!(kind(&seen[1]), "input_audio_buffer.append");
    // Four 16 kHz samples are five at 24 kHz (three for every two after the first).
    let audio = base64::engine::general_purpose::STANDARD
        .decode(seen[1]["audio"].as_str().unwrap())
        .unwrap();
    assert_eq!(audio.len(), 5 * 2);
    assert_eq!(kind(seen.last().unwrap()), "input_audio_buffer.commit");
}

fn refuse_after_audio(n: usize, _: &Value) -> Vec<Value> {
    match n {
        1 => vec![
            json!({"type": "conversation.item.input_audio_transcription.delta", "item_id": "i1", "delta": "kept"}),
            json!({"type": "error", "error": {"type": "invalid_request_error", "code": "rate_limit_exceeded", "message": "slow down sk-test"}}),
        ],
        _ => vec![],
    }
}

#[tokio::test]
async fn a_provider_error_ends_the_session_and_keeps_the_words() {
    let fake = fake(refuse_after_audio).await;
    let (tx, rx) = mpsc::channel(8);
    let (shown_tx, shown_rx) = mpsc::channel(64);
    let run = tokio::spawn(run(
        endpoint("openai", &fake.url),
        Some("sk-test".into()),
        Http::default(),
        None,
        rx,
        shown_tx,
    ));
    tx.send(Command::Audio(vec![1; 8])).await.unwrap();
    let err = run.await.unwrap().unwrap_err();
    assert_eq!(err.code, ErrorCode::RateLimited);
    assert!(!err.detail.contains("sk-test"), "{}", err.detail);
    assert_eq!(
        drain(shown_rx).await,
        vec![Shown::Partial("kept".into()), Shown::Final("kept".into())]
    );
    drop(tx);
}

fn empty_commit(_: usize, message: &Value) -> Vec<Value> {
    if kind(message) == "input_audio_buffer.commit" {
        vec![
            json!({"type": "error", "error": {"type": "invalid_request_error", "code": "input_audio_buffer_commit_empty", "message": "buffer too small"}}),
        ]
    } else {
        vec![]
    }
}

#[tokio::test]
async fn a_stop_after_silence_ends_cleanly_with_no_text() {
    let fake = fake(empty_commit).await;
    let (tx, rx) = mpsc::channel(8);
    let (shown_tx, shown_rx) = mpsc::channel(64);
    let run = tokio::spawn(run(
        endpoint("openai", &fake.url),
        Some("k".into()),
        Http::default(),
        None,
        rx,
        shown_tx,
    ));
    tx.send(Command::Stop).await.unwrap();
    assert_eq!(run.await.unwrap().unwrap(), "");
    assert!(drain(shown_rx).await.is_empty());
}

#[tokio::test]
async fn cancel_ends_at_once_and_sends_no_commit() {
    let fake = fake(|_, _| vec![]).await;
    let (tx, rx) = mpsc::channel(8);
    let (shown_tx, _shown_rx) = mpsc::channel(64);
    let run = tokio::spawn(run(
        endpoint("openai", &fake.url),
        Some("k".into()),
        Http::default(),
        None,
        rx,
        shown_tx,
    ));
    tx.send(Command::Audio(vec![1, 2])).await.unwrap();
    tx.send(Command::Cancel).await.unwrap();
    assert_eq!(run.await.unwrap().unwrap(), "");
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(fake.seen.lock().unwrap().iter().all(|m| kind(m) != "input_audio_buffer.commit"));
}

#[tokio::test]
async fn a_refused_upgrade_is_the_providers_status() {
    let served = crate::test_server::serve(vec![crate::test_server::answer(
        401,
        r#"{"error":{"message":"bad key"}}"#,
    )])
    .await;
    let (_tx, rx) = mpsc::channel(8);
    let (shown_tx, _rx) = mpsc::channel(8);
    let err = run(
        endpoint("openai", &format!("{}/v1", served.url)),
        Some("k".into()),
        Http::default(),
        None,
        rx,
        shown_tx,
    )
    .await
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::KeyInvalid);
}

#[tokio::test]
async fn nothing_listening_is_offline() {
    let url = crate::test_server::closed_url().await;
    let (_tx, rx) = mpsc::channel(8);
    let (shown_tx, _rx) = mpsc::channel(8);
    let err = run(
        endpoint("openai", &format!("{url}/v1")),
        Some("k".into()),
        Http::default(),
        None,
        rx,
        shown_tx,
    )
    .await
    .unwrap_err();
    assert_eq!(err.code, ErrorCode::Offline);
}

#[test]
fn only_a_streaming_provider_has_a_stream_url() {
    assert_eq!(
        stream_url(&endpoint("openai", "")).as_deref(),
        Some("wss://api.openai.com/v1/realtime?intent=transcription")
    );
    assert_eq!(stream_url(&endpoint("groq", "")), None);
    assert_eq!(stream_url(&endpoint("whisperCpp", "")), None);
}

#[test]
fn upsampling_is_three_for_two_and_continuous_across_calls() {
    let mut one = Upsampler::default();
    let mut whole = Vec::new();
    one.push(&[0, 300, 600, 900, 1200, 1500], &mut whole);
    let mut split = Upsampler::default();
    let mut parts = Vec::new();
    split.push(&[0, 300, 600], &mut parts);
    split.push(&[900], &mut parts);
    split.push(&[1200, 1500], &mut parts);
    assert_eq!(whole, parts);
    assert_eq!(whole, vec![0, 200, 400, 600, 800, 1000, 1200, 1400]);
    let mut edge = Upsampler::default();
    let mut out = Vec::new();
    edge.push(&[i16::MIN, i16::MAX], &mut out);
    assert_eq!(out.len(), 2);
}

#[test]
fn provider_messages_map_to_events() {
    let e = |v: Value| provider_event(&v, None);
    assert_eq!(e(json!({"type": "session.updated"})), None);
    assert_eq!(
        e(json!({"type": "conversation.item.input_audio_transcription.failed", "item_id": "x"})),
        Some(Event::ItemFailed { item: "x".into() })
    );
    let failed = |v: Value| match provider_event(&v, None) {
        Some(Event::Failed(err)) => err.code,
        other => panic!("{other:?}"),
    };
    assert_eq!(
        failed(json!({"type": "error", "error": {"code": "invalid_api_key"}})),
        ErrorCode::KeyInvalid
    );
    assert_eq!(
        failed(
            json!({"type": "error", "error": {"type": "invalid_request_error", "code": "unknown_model"}})
        ),
        ErrorCode::Rejected
    );
    assert_eq!(
        failed(json!({"type": "error", "error": {"type": "server_error"}})),
        ErrorCode::ProviderError
    );
}
