//! `_acpmux/voice/state`, `_acpmux/voice/transcribe` and `_acpmux/voice/check` over the request
//! path, with a settings file (CMUX_NEXT_CONFIG_FILE) and a stand-in provider on 127.0.0.1: an
//! unknown engine reads as on-device, on-device and a custom engine without a URL are
//! `not_configured`, whisper.cpp and an OpenAI-style local server transcribe from base64,
//! paths never grant daemon file access, a provider that needs a key and has none is
//! `key_missing` without a connection, a recording over 24 MiB is `too_large` without a
//! connection, and only the unix socket may ask.
//! Its own test binary: it sets CMUX_NEXT_CONFIG_FILE, which every call reads.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts in this process.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::server::{Origin, serve_connection_with};
use base64::Engine;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;

const WAV: &[u8] = b"RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00";

/// The stand-in provider: a GET answers a page, a POST `{"text": " heard\n"}`.
struct Fake {
    url: String,
    connections: Arc<AtomicUsize>,
    requests: Arc<Mutex<Vec<String>>>,
}

async fn read_request(stream: &mut TcpStream) -> Vec<u8> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 65536];
    loop {
        let n = stream.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            return buf;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
            let length = head
                .lines()
                .find_map(|l| l.strip_prefix("content-length:"))
                .map_or(0, |v| v.trim().parse::<usize>().unwrap());
            if buf.len() >= end + 4 + length {
                return buf;
            }
        }
    }
}

async fn fake() -> Fake {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let connections = Arc::new(AtomicUsize::new(0));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let (c, r) = (connections.clone(), requests.clone());
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            c.fetch_add(1, Ordering::SeqCst);
            let r = r.clone();
            tokio::spawn(async move {
                let request =
                    String::from_utf8_lossy(&read_request(&mut stream).await).into_owned();
                let body = if request.starts_with("GET ") {
                    "<html></html>"
                } else {
                    r#"{"text":" heard\n"}"#
                };
                r.lock().unwrap().push(request);
                let answer = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(answer.as_bytes()).await.ok();
                stream.shutdown().await.ok();
            });
        }
    });
    Fake { url, connections, requests }
}

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

async fn call(hub: &Arc<Hub>, origin: Origin, m: &str, params: Value) -> Value {
    let (tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut rx) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    // Native requests use the 64 MiB inbound limit, not the daemon's 31 MiB reply limit.
    let request = json!({"jsonrpc": "2.0", "id": 1, "method": m, "params": params});
    tx.send(serde_json::to_string(&request).unwrap()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), rx.recv())
            .await
            .expect("an answer in time")
            .expect("the connection stays open");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

#[cfg(unix)]
async fn socket_call(socket: &Path, params: Value) -> Value {
    use tokio::io::{AsyncBufReadExt, BufReader};
    let request = json!({"jsonrpc": "2.0", "id": 1,
        "method": "_acpmux/voice/transcribe", "params": params});
    let mut line = serde_json::to_vec(&request).unwrap();
    line.push(b'\n');
    assert!(line.len() < acpmux::server::WS_MAX_MESSAGE_BYTES);
    tokio::time::timeout(Duration::from_secs(60), async {
        let mut socket = tokio::net::UnixStream::connect(socket).await.unwrap();
        socket.write_all(&line).await.unwrap();
        let mut lines = BufReader::new(socket).lines();
        while let Some(line) = lines.next_line().await.unwrap() {
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply.get("id") == Some(&json!(1)) {
                return reply;
            }
        }
        panic!("socket closed before reply")
    })
    .await
    .expect("the Unix socket answers in time")
}

fn set(path: &Path, settings: Value) {
    std::fs::write(path, serde_json::to_vec(&settings).unwrap()).unwrap();
}

fn code(reply: &Value) -> &str {
    reply["result"]["error"]["code"].as_str().unwrap_or_else(|| panic!("no error code: {reply}"))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn voice_methods_follow_the_settings() {
    let scratch = daemon_env::Scratch::new("acpmux-voice-rpc");
    let dir: PathBuf = std::fs::canonicalize(scratch.path()).unwrap();
    let settings = dir.join("cmux-next.json");
    set(&settings, json!({}));
    // SAFETY: the only test in this binary, set before any call reads it.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    let hub = hub();
    let local = Origin::Local;
    let wav = dir.join("recording.wav");
    std::fs::write(&wav, WAV).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD.encode(WAV);

    // Defaults: on-device, nothing sent.
    let r = call(&hub, local, "_acpmux/voice/state", json!({})).await;
    let s = &r["result"];
    assert_eq!(s["engine"], "onDevice", "{r}");
    assert_eq!(s["wire"], "builtin");
    assert_eq!(s["keyService"], "cmux-voice-key");
    assert_eq!(s["keyAccount"], Value::Null);
    assert_eq!(s["hasKey"], false);
    assert_eq!(s["error"], Value::Null);
    assert_eq!(s["providers"].as_array().map(Vec::len), Some(6));
    assert_eq!(s["providers"][1]["defaultUrl"], "https://api.openai.com/v1");
    let r = call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64})).await;
    assert_eq!(code(&r), "not_configured");
    let r = call(&hub, local, "_acpmux/voice/check", json!({})).await;
    assert_eq!(r["result"]["ok"], false, "{r}");
    assert_eq!(r["result"]["error"]["code"], "not_configured");

    // An unknown engine reads as on-device.
    set(&settings, json!({"agentPane": {"dictationEngine": "parakeet-9000"}}));
    let r = call(&hub, local, "_acpmux/voice/state", json!({})).await;
    assert_eq!(r["result"]["engine"], "onDevice", "{r}");

    // Custom without a URL: not configured.
    set(&settings, json!({"agentPane": {"dictationEngine": "custom"}}));
    let r = call(&hub, local, "_acpmux/voice/state", json!({})).await;
    assert_eq!(r["result"]["error"]["code"], "not_configured", "{r}");
    let r = call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64})).await;
    assert_eq!(code(&r), "not_configured");

    // whisper.cpp on this machine: no key, POST /inference.
    let server = fake().await;
    set(
        &settings,
        json!({"agentPane": {"dictationEngine": "whisperCpp", "dictationEngineURL": server.url}}),
    );
    let r = call(&hub, local, "_acpmux/voice/state", json!({})).await;
    assert_eq!(r["result"]["url"], server.url.as_str(), "{r}");
    assert_eq!(r["result"]["keyAccount"], Value::Null);
    let r = call(&hub, local, "_acpmux/voice/check", json!({})).await;
    assert_eq!(r["result"], json!({"ok": true}));
    let r = call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64})).await;
    assert_eq!(r["result"], json!({"text": "heard"}));
    let r =
        call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64, "language": "fr-CA"}))
            .await;
    assert_eq!(r["result"], json!({"text": "heard"}));
    {
        let seen = server.requests.lock().unwrap();
        assert!(seen[0].starts_with("GET / "), "{}", seen[0]);
        assert!(seen[1].starts_with("POST /inference "), "{}", seen[1]);
        assert!(seen[2].contains("name=\"language\"\r\n\r\nfr\r\n"), "{}", seen[2]);
        assert!(seen.iter().all(|r| !r.to_ascii_lowercase().contains("authorization:")));
    }

    // A full 24 MiB recording survives the actual Unix request framing, even though
    // its base64 is larger than the daemon's outbound reply limit. One more byte is refused.
    #[cfg(unix)]
    {
        let socket_dir = tempfile::tempdir().unwrap();
        let socket = socket_dir.path().join("voice.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let serving = tokio::spawn(acpmux::server::serve_unix(hub.clone(), listener));
        let mut bytes = vec![0u8; cmux_voice::MAX_AUDIO_BYTES as usize];
        bytes[..WAV.len()].copy_from_slice(WAV);
        let audio = base64::engine::general_purpose::STANDARD.encode(&bytes);
        let r = socket_call(&socket, json!({"audio": audio})).await;
        assert_eq!(r["result"], json!({"text": "heard"}), "{r}");
        assert!(server.requests.lock().unwrap().last().unwrap().len() > bytes.len());
        let before = server.connections.load(Ordering::SeqCst);
        bytes.push(0);
        let audio = base64::engine::general_purpose::STANDARD.encode(&bytes);
        let r = socket_call(&socket, json!({"audio": audio})).await;
        assert_eq!(code(&r), "too_large");
        assert_eq!(server.connections.load(Ordering::SeqCst), before);
        serving.abort();
    }

    // No path value, even a real regular file or a path alongside valid bytes, may cause
    // daemon-side file I/O or a provider connection. The client must supply the bytes itself.
    let before = server.connections.load(Ordering::SeqCst);
    let bad = [
        json!({}),
        json!({"path": wav}),
        json!({"path": "recording.wav"}),
        json!({"path": dir}),
        json!({"path": wav, "audio": b64}),
        json!({"path": null, "audio": b64}),
        json!({"path": 1, "audio": b64}),
        json!({"audio": "%%%"}),
    ];
    #[cfg(unix)]
    {
        let link = dir.join("recording-link.wav");
        std::os::unix::fs::symlink(&wav, &link).unwrap();
        let r = call(&hub, local, "_acpmux/voice/transcribe", json!({"path": link})).await;
        assert_eq!(r["error"]["code"], -32602, "{r}");
    }
    for params in bad {
        let r = call(&hub, local, "_acpmux/voice/transcribe", params.clone()).await;
        assert_eq!(r["error"]["code"], -32602, "{params}: {r}");
    }
    assert_eq!(server.connections.load(Ordering::SeqCst), before);

    // An OpenAI-style server on this machine: a key account, no key saved, none sent.
    set(
        &settings,
        json!({"agentPane.dictationEngine": "localServer", "agentPane.dictationEngineURL": format!("{}/v1", server.url),
               "agentPane.dictationEngineModel": "parakeet-tdt"}),
    );
    let r = call(&hub, local, "_acpmux/voice/state", json!({})).await;
    let port = server.url.rsplit(':').next().unwrap();
    assert_eq!(r["result"]["keyAccount"], format!("localServer@http://127.0.0.1:{port}"), "{r}");
    assert_eq!(r["result"]["model"], "parakeet-tdt");
    assert_eq!(r["result"]["hasKey"], false);
    let captured_settings = r["result"]["settings"].clone();
    let r =
        call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64, "language": "en-US"}))
            .await;
    assert_eq!(r["result"], json!({"text": "heard"}), "{r}");
    {
        let seen = server.requests.lock().unwrap();
        let last = seen.last().unwrap();
        assert!(last.starts_with("POST /v1/audio/transcriptions "), "{last}");
        assert!(last.contains("name=\"model\"\r\n\r\nparakeet-tdt\r\n"), "{last}");
        assert!(!last.to_ascii_lowercase().contains("authorization:"), "{last}");
    }

    // A live voice session retains its provider when Settings changes. A new session uses
    // the new settings, and malformed snapshots never silently fall back to on-device.
    set(&settings, json!({}));
    let r = call(
        &hub,
        local,
        "_acpmux/voice/transcribe",
        json!({"audio": b64, "settings": captured_settings}),
    )
    .await;
    assert_eq!(r["result"], json!({"text": "heard"}), "{r}");
    let r = call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64})).await;
    assert_eq!(code(&r), "not_configured");
    let r = call(
        &hub,
        local,
        "_acpmux/voice/transcribe",
        json!({"audio": b64, "settings": {"engine": "localServer"}}),
    )
    .await;
    assert_eq!(r["error"]["code"], -32602);

    // A provider that needs a key, with none saved: key_missing, and no connection.
    let before = server.connections.load(Ordering::SeqCst);
    set(
        &settings,
        json!({"agentPane": {"dictationEngine": "openai", "dictationEngineURL": format!("{}/v1", server.url)}}),
    );
    let r = call(&hub, local, "_acpmux/voice/transcribe", json!({"audio": b64})).await;
    assert_eq!(code(&r), "key_missing");
    let r = call(&hub, local, "_acpmux/voice/check", json!({})).await;
    assert_eq!(r["result"]["error"]["code"], "key_missing", "{r}");
    assert_eq!(server.connections.load(Ordering::SeqCst), before);

    // A forbidden endpoint: bad_endpoint.
    set(
        &settings,
        json!({"agentPane": {"dictationEngine": "groq", "dictationEngineURL": "http://example.com/v1"}}),
    );
    let r = call(&hub, local, "_acpmux/voice/state", json!({})).await;
    assert_eq!(r["result"]["error"]["code"], "bad_endpoint", "{r}");
    let r = call(&hub, local, "_acpmux/voice/check", json!({})).await;
    assert_eq!(r["result"]["error"]["code"], "bad_endpoint", "{r}");

    // Only the unix socket.
    for origin in [Origin::LocalApp, Origin::Web] {
        for method in ["_acpmux/voice/state", "_acpmux/voice/relay", "_acpmux/voice/transcribe"] {
            let r = call(&hub, origin, method, json!({"settings": captured_settings})).await;
            assert!(r.get("error").is_some(), "{origin:?}: {r}");
        }
    }
}
