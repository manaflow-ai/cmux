use super::*;
use crate::endpoint::{Settings, resolve};
use crate::test_server::{answer, closed_url, hang, serve};

const WAV: &[u8] = b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00";

fn endpoint(engine: &str, url: &str, model: &str) -> Endpoint {
    resolve(&Settings { engine: engine.into(), url: url.into(), model: model.into() })
        .endpoint
        .unwrap()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn header<'a>(request: &'a str, name: &str) -> Option<&'a str> {
    let head = request.split("\r\n\r\n").next()?;
    head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case(name).then(|| v.trim())
    })
}

#[tokio::test]
async fn openai_wire_posts_multipart_with_the_key_and_reads_text() {
    let served = serve(vec![answer(200, r#"{"text": "  hello there \n"}"#)]).await;
    let ep = endpoint("custom", &format!("{}/v1/", served.url), "whisper-1");
    let provider = provider_for(ep, Some(" sk-test-key ".into()), Http::default()).unwrap();
    assert_eq!(provider.capabilities(), &[Capability::DictationBatch]);
    let got =
        provider.transcribe(BatchRequest { audio: WAV, language: Some("en-US") }).await.unwrap();
    assert_eq!(got.text, "hello there");
    let requests = served.requests.await.unwrap();
    let raw = &requests[0];
    let request = text(raw);
    assert!(request.starts_with("POST /v1/audio/transcriptions HTTP/1.1\r\n"), "{request}");
    assert_eq!(header(&request, "authorization"), Some("Bearer sk-test-key"));
    let content_type = header(&request, "content-type").unwrap();
    let boundary = content_type.strip_prefix("multipart/form-data; boundary=").unwrap();
    let body_at = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
    let want = multipart::body(
        boundary,
        &[
            Part::file("file", "recording.wav", "audio/wav", WAV),
            Part::text("model", "whisper-1"),
            Part::text("response_format", "json"),
            Part::text("language", "en"),
        ],
    );
    assert_eq!(&raw[body_at..], &want[..]);
}

#[tokio::test]
async fn openai_wire_omits_an_empty_model_and_sends_no_key_without_one() {
    let served = serve(vec![answer(200, r#"{"text":"ok"}"#)]).await;
    let ep = endpoint("localServer", &format!("{}/v1", served.url), "");
    let provider = provider_for(ep, None, Http::default()).unwrap();
    let got = provider.transcribe(BatchRequest { audio: WAV, language: None }).await.unwrap();
    assert_eq!(got.text, "ok");
    let request = text(&served.requests.await.unwrap()[0]);
    assert_eq!(header(&request, "authorization"), None);
    assert!(!request.contains("name=\"model\""), "{request}");
    assert!(!request.contains("name=\"language\""), "{request}");
    assert!(request.contains("name=\"response_format\"\r\n\r\njson\r\n"), "{request}");
}

#[tokio::test]
async fn whisper_cpp_wire_posts_to_inference_without_a_key_or_model() {
    let served = serve(vec![answer(200, r#"{"text":" from whisper\n"}"#)]).await;
    let ep = endpoint("whisperCpp", &served.url, "large");
    // whisper.cpp takes no key: one handed over is never sent.
    let provider = provider_for(ep, Some("sk-unused".into()), Http::default()).unwrap();
    let got = provider.transcribe(BatchRequest { audio: WAV, language: Some("de") }).await.unwrap();
    assert_eq!(got.text, "from whisper");
    let request = text(&served.requests.await.unwrap()[0]);
    assert!(request.starts_with("POST /inference HTTP/1.1\r\n"), "{request}");
    assert_eq!(header(&request, "authorization"), None);
    assert!(!request.contains("name=\"model\""), "{request}");
    assert!(
        request.contains("filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n"),
        "{request}"
    );
    assert!(request.contains("name=\"language\"\r\n\r\nde\r\n"), "{request}");
}

#[tokio::test]
async fn each_status_maps_to_its_code() {
    let cases: &[(u16, &str, ErrorCode)] = &[
        (401, r#"{"error":{"message":"Incorrect API key"}}"#, ErrorCode::KeyInvalid),
        (403, "{}", ErrorCode::KeyInvalid),
        (404, "not found", ErrorCode::BadEndpoint),
        (405, "", ErrorCode::BadEndpoint),
        (302, "", ErrorCode::BadEndpoint),
        (408, "", ErrorCode::Timeout),
        (413, "", ErrorCode::TooLarge),
        (429, r#"{"error":{"message":"slow down"}}"#, ErrorCode::RateLimited),
        (400, r#"{"error":{"message":"model x does not exist"}}"#, ErrorCode::Rejected),
        (422, r#"{"detail":[{"msg":"field required"}]}"#, ErrorCode::Rejected),
        (418, "", ErrorCode::Rejected),
        (500, "boom", ErrorCode::ProviderError),
        (503, "", ErrorCode::ProviderError),
        (200, "<html>not json</html>", ErrorCode::BadResponse),
        (200, r#"{"words":[]}"#, ErrorCode::BadResponse),
    ];
    let served = serve(cases.iter().map(|(s, b, _)| answer(*s, b)).collect()).await;
    let ep = endpoint("localServer", &format!("{}/v1", served.url), "");
    let provider = provider_for(ep, None, Http::default()).unwrap();
    for (status, _, code) in cases {
        let e = provider.transcribe(BatchRequest { audio: WAV, language: None }).await.unwrap_err();
        assert_eq!(e.code, *code, "{status}: {e}");
    }
    served.requests.await.unwrap();
    // The provider's message rides in the detail.
    assert_eq!(
        status_error(400, br#"{"error":{"message":"model x does not exist"}}"#, None).detail,
        "400: model x does not exist"
    );
    assert_eq!(
        status_error(422, br#"{"detail":[{"msg":"field required"}]}"#, None).detail,
        "422: field required"
    );
    assert_eq!(status_error(500, b"", None).detail, "500");
}

#[tokio::test]
async fn the_key_is_scrubbed_from_the_detail() {
    let key = "not-a-real-key";
    let body =
        format!(r#"{{"error":{{"message":"Incorrect API key provided: {key}. Bearer {key}"}}}}"#);
    let served = serve(vec![answer(401, &body)]).await;
    let ep = endpoint("custom", &format!("{}/v1", served.url), "");
    let provider = provider_for(ep, Some(key.into()), Http::default()).unwrap();
    let e = provider.transcribe(BatchRequest { audio: WAV, language: None }).await.unwrap_err();
    assert_eq!(e.code, ErrorCode::KeyInvalid);
    assert!(!e.detail.contains(key), "{}", e.detail);
    assert!(e.detail.contains("[key]"), "{}", e.detail);
    assert!(e.detail.chars().count() <= crate::error::MAX_DETAIL_CHARS);
    served.requests.await.unwrap();
}

#[tokio::test]
async fn offline_and_timeout() {
    let ep = endpoint("localServer", &format!("{}/v1", closed_url().await), "");
    let provider = provider_for(ep, None, Http::default()).unwrap();
    let e = provider.transcribe(BatchRequest { audio: WAV, language: None }).await.unwrap_err();
    assert_eq!(e.code, ErrorCode::Offline, "{e}");

    let (url, _task) = hang().await;
    let ep = endpoint("whisperCpp", &url, "");
    let quick =
        Http { connect_timeout: Duration::from_secs(2), total_timeout: Duration::from_millis(300) };
    let provider = provider_for(ep, None, quick).unwrap();
    let e = provider.check().await.unwrap_err();
    assert_eq!(e.code, ErrorCode::Timeout, "{e}");
}

#[tokio::test]
async fn check_gets_models_or_the_base() {
    let served = serve(vec![answer(200, r#"{"data":[]}"#), answer(401, "{}")]).await;
    let ep = endpoint("custom", &format!("{}/v1", served.url), "");
    let provider = provider_for(ep, Some("k1".into()), Http::default()).unwrap();
    provider.check().await.unwrap();
    assert_eq!(provider.check().await.unwrap_err().code, ErrorCode::KeyInvalid);
    let requests = served.requests.await.unwrap();
    let first = text(&requests[0]);
    assert!(first.starts_with("GET /v1/models HTTP/1.1\r\n"), "{first}");
    assert_eq!(header(&first, "authorization"), Some("Bearer k1"));

    let served = serve(vec![answer(200, "<html></html>")]).await;
    let provider =
        provider_for(endpoint("whisperCpp", &served.url, ""), None, Http::default()).unwrap();
    provider.check().await.unwrap();
    let first = text(&served.requests.await.unwrap()[0]);
    assert!(first.starts_with("GET / HTTP/1.1\r\n"), "{first}");
}

#[test]
fn a_required_key_must_exist() {
    let ep = endpoint("openai", "http://127.0.0.1:9/v1", "");
    assert_eq!(
        provider_for(ep.clone(), None, Http::default()).err().unwrap().code,
        ErrorCode::KeyMissing
    );
    assert_eq!(
        provider_for(ep, Some("  ".into()), Http::default()).err().unwrap().code,
        ErrorCode::KeyMissing
    );
}

#[test]
fn language_is_the_primary_subtag() {
    assert_eq!(primary_language("en-US").as_deref(), Some("en"));
    assert_eq!(primary_language("PT_br").as_deref(), Some("pt"));
    assert_eq!(primary_language("yue-Hant-HK").as_deref(), Some("yue"));
    assert_eq!(primary_language(""), None);
    assert_eq!(primary_language("e"), None);
    assert_eq!(primary_language("12-US"), None);
}
