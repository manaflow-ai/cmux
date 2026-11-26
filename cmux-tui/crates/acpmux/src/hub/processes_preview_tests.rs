//! A background process's preview (`process_preview.rs`): the URL a dev server prints, kept
//! only once its port accepts a loopback connect, carried on the record while it runs.
use super::preview::{first_listening, previews_in};
use super::*;
use crate::config::{Config, StoreMode};
use std::net::TcpListener;
use std::path::Path;

fn urls(output: &str) -> Vec<String> {
    previews_in(output.as_bytes()).into_iter().map(|(_, preview)| preview.url).collect()
}

fn preview(url: &str, port: u16) -> ProcessPreview {
    ProcessPreview { url: url.to_owned(), port }
}

#[test]
fn a_preview_is_the_url_a_dev_server_prints() {
    let vite = "\n  \x1b[32m\x1b[1mVITE\x1b[22m v6.0.0\x1b[39m  \x1b[2mready in \x1b[0m\x1b[1m310\x1b[22m\x1b[2m\x1b[0m ms\n\n  \x1b[32m➜\x1b[39m  \x1b[1mLocal\x1b[22m:   \x1b[36mhttp://localhost:\x1b[1m5173\x1b[22m/\x1b[39m\n  \x1b[32m➜\x1b[39m  \x1b[1mNetwork\x1b[22m\x1b[2m: use \x1b[22m\x1b[1m--host\x1b[22m\x1b[2m to expose\x1b[22m\n";
    assert_eq!(urls(vite), ["http://localhost:5173/"], "through Vite's color codes");
    let next = "   ▲ Next.js 15.0.3\n   - Local:        http://localhost:3000\n   - Network:      http://192.168.1.20:3000\n\n ✓ Starting...\n ✓ Ready in 1186ms\n";
    assert_eq!(urls(next), ["http://localhost:3000/"], "the LAN address is not loopback");
    let rails = "=> Booting Puma\n=> Rails 8.0.0 application starting in development\nPuma starting in single mode...\n* Listening on http://127.0.0.1:3000\nUse Ctrl-C to stop\n";
    assert_eq!(urls(rails), ["http://127.0.0.1:3000/"]);
    let axum = "   Compiling app v0.1.0 (/src/app)\n    Finished `dev` profile [unoptimized + debuginfo] target(s) in 4.20s\n     Running `target/debug/app`\nlistening on 0.0.0.0:8080\n";
    assert_eq!(urls(axum), ["http://localhost:8080/"], "a wildcard host opens as localhost");
    let python = "Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n127.0.0.1 - - [08/Nov/2026 10:00:00] \"GET / HTTP/1.1\" 200 -\n";
    assert_eq!(urls(python), ["http://localhost:8000/"]);
    let puma = "* Listening on http://127.0.0.1:3000\n* Listening on http://[::1]:3000\n";
    assert_eq!(urls(puma), ["http://localhost:3000/"], "IPv6 loopback opens as localhost");
}

#[test]
fn an_api_path_previews_the_root() {
    let output = "API on http://localhost:4000/api/v1\nGraphQL at http://127.0.0.1:4001/graphql\n\
                  http://localhost:4002/v2/users\nhealth: http://[::]:4003/healthz\n\
                  media http://localhost:4004/videos\napp http://localhost:4005/app/?tab=1\n";
    assert_eq!(
        urls(output),
        [
            "http://localhost:4005/app/?tab=1",
            "http://localhost:4004/videos",
            "http://localhost:4003/",
            "http://localhost:4002/",
            "http://127.0.0.1:4001/",
            "http://localhost:4000/",
        ],
        "newest first; a page path is kept"
    );
}

#[tokio::test]
async fn a_preview_is_only_a_port_that_accepts() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let closed = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let output = format!("up http://localhost:{port}/\ndown http://127.0.0.1:{closed}/\n");
    let found = first_listening(previews_in(output.as_bytes())).await;
    assert_eq!(found, Some(preview(&format!("http://localhost:{port}/"), port)));
    drop(listener);
    assert_eq!(first_listening(previews_in(output.as_bytes())).await, None, "nothing listens");
}

fn running(id: &str, preview: Option<ProcessPreview>) -> Process {
    let mut process: Process = serde_json::from_value(json!({
        "id": id, "sessionId": "chat", "toolCallId": id, "taskId": id,
        "harness": "claude", "command": "npm run dev", "cwd": "/tmp",
        "startedAt": 100, "state": "running", "origin": "background",
    }))
    .unwrap();
    process.preview = preview;
    process
}

#[test]
fn a_preview_round_trips_and_none_is_omitted() {
    let with = running("chat/a", Some(preview("http://localhost:5173/", 5173)));
    let value = serde_json::to_value(&with).unwrap();
    assert_eq!(value["preview"], json!({"url": "http://localhost:5173/", "port": 5173}));
    let back: Process = serde_json::from_value(value).unwrap();
    assert_eq!(back.preview, with.preview);
    let without = serde_json::to_value(running("chat/b", None)).unwrap();
    assert!(without.get("preview").is_none(), "no preview, no key: {without}");
}

#[test]
fn a_preview_lasts_while_the_process_runs() {
    let found = preview("http://localhost:3000/", 3000);
    let mut table = ProcessTable::default();
    table.upsert(running("chat/a", Some(found.clone())));
    table.upsert(running("chat/a", None));
    assert_eq!(table.processes[0].preview, Some(found.clone()), "a record naming none keeps it");
    let mut ended = running("chat/a", Some(found.clone()));
    ended.state = ProcessState::Exited;
    table.upsert(ended);
    assert_eq!(table.processes[0].preview, None, "an ended server has none");

    table.upsert(running("chat/b", Some(found)));
    let lost = table.lose_running(200, HARNESS_EXIT, true);
    assert!(lost[0].preview.is_none() && table.processes[1].preview.is_none());
}

/// A hub with one chat on the fake agent.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// The preview `hub` lists for the chat's first process, waiting up to 5 s (the first check is
/// 0.5 s in).
async fn listed_preview(hub: &Hub, session: &Session) -> Value {
    let mut listed = Value::Null;
    for _ in 0..50 {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        listed = hub.list_processes(Some(session))["processes"][0]["preview"].clone();
        if !listed.is_null() {
            break;
        }
    }
    listed
}

/// After a restart the daemon adopts the running host and reads its processes again: a running
/// server with no preview yet gets a watch then, not only on its next shell update.
#[tokio::test]
async fn an_adopted_hosts_running_server_is_watched_again() {
    let (hub, session) = chat().await;
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let name = format!("acpmux-preview-adopt-{}.output", std::process::id());
    let file = std::env::temp_dir().join(name);
    std::fs::write(&file, format!("listening on http://127.0.0.1:{port}\n")).unwrap();
    let shell = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": "running", "command": "./serve"}}});
    let rec = hub.append(&session, "in", "background_task_update", shell);
    // Logged with its output file, but no watch ran (the daemon that saw it is gone).
    hub.note_process(&session, &rec, file.to_str());
    assert!(session.processes.lock().unwrap().watching.is_empty());

    hub.recover_processes(&session);
    assert_eq!(
        listed_preview(&hub, &session).await,
        json!({"url": format!("http://127.0.0.1:{port}/"), "port": port})
    );
    drop(listener);
    let _ = std::fs::remove_file(&file);
    hub.shutdown_all().await;
}

/// End to end: a running shell whose output file names a listening server gets a logged
/// `process_update` with its preview, which a read of the log finds again.
#[tokio::test]
async fn a_running_dev_server_gets_its_preview() {
    let (hub, session) = chat().await;

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let file = std::env::temp_dir().join(format!("acpmux-preview-{}.output", std::process::id()));
    std::fs::write(&file, format!("> dev\n\n  ➜  Local:   http://localhost:{port}/\n")).unwrap();
    let shell = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": "running", "command": "npm run dev"}}});
    let rec = hub.append(&session, "in", "background_task_update", shell);
    hub.note_process(&session, &rec, file.to_str());
    hub.watch_previews(&session);
    hub.watch_previews(&session);
    assert_eq!(session.processes.lock().unwrap().watching.len(), 1, "one watch a process");

    let want = json!({"url": format!("http://localhost:{port}/"), "port": port});
    assert_eq!(listed_preview(&hub, &session).await, want);
    let logged = hub.read_processes(&session);
    assert_eq!(serde_json::to_value(&logged.processes[0]).unwrap()["preview"], want);
    drop(listener);
    let _ = std::fs::remove_file(&file);
    hub.shutdown_all().await;
}
