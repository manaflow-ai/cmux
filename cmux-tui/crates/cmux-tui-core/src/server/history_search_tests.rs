//! Wire tests for `history-search` (`history-search-v1`) and its worker.

use std::path::PathBuf;
use std::sync::atomic::AtomicU32;
use std::time::Duration;

use cmux_history::{HistoryError, SearchDoc, SearchFeed, SearchKind};

use super::super::*;
use super::HISTORY_SEARCH_CAPABILITY;
use crate::history_search::{HistorySearch, SearchPace};

const T0: i64 = 1_800_000_000_000;

/// A fresh directory under the system temp dir, removed on drop.
struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-history-search-{label}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        Self(path)
    }

    fn index(&self) -> PathBuf {
        self.0.join("search.sqlite")
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// One chat session's messages, each `delay` slow to read.
struct Chat {
    session: &'static str,
    messages: Vec<&'static str>,
    delay: Duration,
}

impl SearchFeed for Chat {
    fn sources(&self) -> Result<Vec<String>, HistoryError> {
        Ok(vec![format!("acpmux:{}", self.session)])
    }

    fn read(
        &self,
        _source: &str,
        after: Option<i64>,
        max: usize,
    ) -> Result<(Vec<SearchDoc>, i64), HistoryError> {
        std::thread::sleep(self.delay);
        let start = after.unwrap_or(0);
        let end = (start + max as i64).min(self.messages.len() as i64);
        let docs = (start..end)
            .map(|turn| SearchDoc {
                key: format!("chat:{}:{turn}", self.session),
                source: format!("acpmux:{}", self.session),
                kind: SearchKind::Chat,
                target: self.session.to_owned(),
                position: Some(turn),
                title: "Flaky test".to_owned(),
                text: self.messages[turn as usize].to_owned(),
                at_ms: T0 + turn,
            })
            .collect();
        Ok((docs, end))
    }
}

fn chat(messages: Vec<&'static str>) -> Box<Chat> {
    Box::new(Chat { session: "s1", messages, delay: Duration::ZERO })
}

fn fast() -> SearchPace {
    SearchPace { budget: 64, pause: Duration::from_millis(1), idle: Duration::from_millis(10) }
}

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn local_mux() -> (Arc<Mux>, u64) {
    let mux = Mux::new_for_test("history-search", crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client)
}

fn run(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer())
}

/// Searches until the worker has indexed a hit, for at most five seconds.
fn search_until_found(mux: &Arc<Mux>, client: u64, request: Value) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let result = run(mux, client, request.clone()).unwrap();
        if !result["hits"].as_array().unwrap().is_empty() || Instant::now() > deadline {
            return result;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn keys(result: &Value) -> Vec<&str> {
    result["hits"].as_array().unwrap().iter().map(|hit| hit["key"].as_str().unwrap()).collect()
}

#[test]
fn a_message_is_found_and_names_its_turn() {
    let dir = TempDir::new("found");
    let (mux, client) = local_mux();
    let feed = chat(vec!["Why is CI red?", "🔥 The flaky middle-click test", "Fixed it"]);
    let service = HistorySearch::start(&dir.index(), vec![feed], fast()).unwrap();
    assert!(mux.install_history_search(service));

    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == HISTORY_SEARCH_CAPABILITY));

    let result =
        search_until_found(&mux, client, json!({"cmd":"history-search","query":"middle-click"}));
    let hits = result["hits"].as_array().unwrap();
    assert_eq!(hits.len(), 1, "{result}");
    let hit = &hits[0];
    assert_eq!(hit["key"], "chat:s1:1");
    assert_eq!(hit["kind"], "chat");
    assert_eq!(hit["target"], "s1");
    assert_eq!(hit["position"], 1);
    assert_eq!(hit["title"], "Flaky test");
    assert_eq!(hit["at_ms"], T0 + 1);
    // UTF-16 offsets: the emoji before the match is two code units.
    let snippet: Vec<u16> = hit["snippet"].as_str().unwrap().encode_utf16().collect();
    let range = &hit["highlights"][0];
    let (start, end) =
        (range["start"].as_u64().unwrap() as usize, range["end"].as_u64().unwrap() as usize);
    assert_eq!(String::from_utf16(&snippet[start..end]).unwrap(), "middle-click");
    assert!(result["took_us"].is_u64());
}

#[test]
fn kinds_and_limit_narrow_the_hits() {
    let dir = TempDir::new("narrow");
    let (mux, client) = local_mux();
    let feed = chat(vec!["deploy one", "deploy two", "deploy three"]);
    mux.install_history_search(HistorySearch::start(&dir.index(), vec![feed], fast()).unwrap());

    search_until_found(&mux, client, json!({"cmd":"history-search","query":"deploy three"}));
    let limited =
        run(&mux, client, json!({"cmd":"history-search","query":"deploy","limit":2})).unwrap();
    assert_eq!(keys(&limited), ["chat:s1:2", "chat:s1:1"]);
    let commands = run(
        &mux,
        client,
        json!({"cmd":"history-search","query":"deploy","kinds":["command","workspace"]}),
    )
    .unwrap();
    assert!(commands["hits"].as_array().unwrap().is_empty());
}

#[test]
fn bad_requests_are_refused() {
    let dir = TempDir::new("bad");
    let (mux, client) = local_mux();
    mux.install_history_search(HistorySearch::start(&dir.index(), vec![], fast()).unwrap());
    for request in [
        json!({"cmd":"history-search","query":"   "}),
        json!({"cmd":"history-search","query":"a\u{7}b"}),
        json!({"cmd":"history-search","query":"x".repeat(201)}),
        json!({"cmd":"history-search","query":"ok","limit":0}),
        json!({"cmd":"history-search","query":"ok","limit":101}),
        json!({"cmd":"history-search","query":"ok","kinds":["email"]}),
    ] {
        let Err(error) = run(&mux, client, request.clone()) else {
            panic!("{request} was accepted");
        };
        assert!(error.to_string().starts_with("bad request"), "{request}: {error}");
    }
}

#[test]
fn only_trusted_local_connections_search() {
    let dir = TempDir::new("remote");
    let (mux, _) = local_mux();
    mux.install_history_search(HistorySearch::start(&dir.index(), vec![], fast()).unwrap());
    let web = mux.control_clients.register(ClientTransport::WebSocket, writer());
    let error = run(&mux, web, json!({"cmd":"history-search","query":"secret"})).unwrap_err();
    assert_eq!(error.to_string(), "history search requires a trusted local connection");
}

#[test]
fn without_an_index_search_is_unavailable_and_unadvertised() {
    let (mux, client) = local_mux();
    let error = run(&mux, client, json!({"cmd":"history-search","query":"deploy"})).unwrap_err();
    assert_eq!(error.to_string(), "history search is unavailable");
    let identity = run(&mux, client, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(!capabilities.iter().any(|value| value == HISTORY_SEARCH_CAPABILITY));
}

#[test]
fn indexing_never_holds_up_start_queries_or_shutdown() {
    let dir = TempDir::new("slow");
    // Every read of the backlog takes a second.
    let slow = Box::new(Chat { session: "s1", messages: vec!["slow"; 8], delay: SLOW_READ });
    let started = Instant::now();
    let service = HistorySearch::start(&dir.index(), vec![slow], fast()).unwrap();
    assert!(started.elapsed() < QUICK, "start waited for indexing: {:?}", started.elapsed());

    std::thread::sleep(Duration::from_millis(50));
    let queried = Instant::now();
    service.search("slow", &[], 20).unwrap();
    assert!(queried.elapsed() < QUICK, "a query waited for indexing: {:?}", queried.elapsed());

    // Shutdown waits at most for the read in flight, never the backlog.
    let stopped = Instant::now();
    drop(service);
    assert!(stopped.elapsed() < SLOW_READ + QUICK, "shutdown took {:?}", stopped.elapsed());
}

#[test]
fn an_idle_worker_stops_at_once() {
    let dir = TempDir::new("idle");
    let pace = SearchPace { idle: Duration::from_secs(60), ..fast() };
    let service = HistorySearch::start(&dir.index(), vec![chat(vec!["done"])], pace).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    let stopped = Instant::now();
    drop(service);
    assert!(stopped.elapsed() < QUICK, "an idle worker took {:?} to stop", stopped.elapsed());
}

const SLOW_READ: Duration = Duration::from_secs(1);
const QUICK: Duration = Duration::from_millis(250);
