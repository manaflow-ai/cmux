//! `server-stats` section `commands`: the requests the daemon handled, by command name and by
//! client kind. The lines go through the connection's own frame path, as a socket's lines do.

use serde_json::{Value, json};

use super::super::*;

/// One connection of a test: its lines go through `handle_connection_frame`.
struct Connection {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn connect(mux: &Arc<Mux>) -> Connection {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Connection { client, writer, outbound, scheduler }
}

impl Connection {
    /// Sends one line and does not wait for its reply.
    fn post(&self, mux: &Arc<Mux>, line: &Value) {
        let line = line.to_string();
        handle_connection_frame(
            mux,
            self.client,
            ClientTransport::Unix,
            &line,
            &self.writer,
            &self.scheduler,
        );
    }

    /// Sends one line and returns the text of the reply that has its `id`. A queued command
    /// answers from the connection's dispatch thread, so the reply can come a moment later.
    fn request_text(&self, mux: &Arc<Mux>, line: &Value) -> String {
        self.post(mux, line);
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            while let Some(text) = self.outbound.try_pop() {
                let reply: Value = serde_json::from_str(&text).unwrap();
                if reply.get("id") == line.get("id") {
                    return text;
                }
            }
            assert!(Instant::now() < deadline, "no reply to {line}");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    fn request(&self, mux: &Arc<Mux>, line: &Value) -> Value {
        serde_json::from_str(&self.request_text(mux, line)).unwrap()
    }

    /// Drops the replies that nobody reads, so the connection's queue stays small.
    fn drain(&self) {
        while self.outbound.try_pop().is_some() {}
    }
}

fn ping(id: u64) -> Value {
    json!({"id": id, "cmd": "ping"})
}

fn resource_ping(id: &str, params: Value) -> Value {
    json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": id,
        "operation": "session.ping",
        "params": params,
    })
}

fn current() -> Value {
    json!({"machine": "current", "session": "current"})
}

/// The `commands` section, read on `connection`.
fn commands(mux: &Arc<Mux>, connection: &Connection) -> Value {
    let reply = connection.request(
        mux,
        &json!({"id": "read-commands", "cmd": "server-stats", "include": ["commands"]}),
    );
    let section = reply["data"]["commands"].clone();
    assert!(section.is_object(), "server-stats has no commands section: {reply}");
    section
}

/// The row of `name` and `kind`, if the section has one.
fn row<'a>(section: &'a Value, name: &str, kind: &str) -> Option<&'a Value> {
    section["rows"]
        .as_array()
        .expect("rows")
        .iter()
        .find(|row| row["name"] == name && row["kind"] == kind)
}

fn count(section: &Value, name: &str, kind: &str) -> u64 {
    row(section, name, kind).and_then(|row| row["count"].as_u64()).unwrap_or(0)
}

#[test]
fn server_stats_commands_counts_requests_by_command_name_and_client_kind() {
    let mux = Mux::new_for_test("server-stats-commands", crate::SurfaceOptions::default());
    let app = connect(&mux);
    let unnamed = connect(&mux);

    let declared = app.request(
        &mux,
        &json!({"id": "declare", "cmd": "set-client-info", "name": "cmux", "kind": "frontend"}),
    );
    assert_eq!(declared["ok"], true, "{declared}");
    for id in 0..5 {
        app.request(&mux, &ping(id));
    }
    for id in 0..3 {
        app.request(&mux, &json!({"id": id, "cmd": "identify"}));
    }
    for id in 0..2 {
        unnamed.request(&mux, &ping(id));
    }
    for id in 0..4 {
        unnamed.post(&mux, &resource_ping(&format!("resource-{id}"), current()));
    }
    unnamed.drain();
    // A queued command is counted when its handler returns, a moment after its reply: the next
    // answer of the same connection's queue comes after that.
    let synced = app.request(&mux, &json!({"id": "sync", "cmd": "server-stats"}));
    assert!(synced["data"].is_object(), "{synced}");

    let plain = unnamed.request(&mux, &json!({"id": "plain", "cmd": "server-stats"}));
    assert!(plain["data"].is_object(), "{plain}");
    assert!(plain["data"].get("commands").is_none(), "only when asked: {plain}");

    let section = commands(&mux, &unnamed);
    for (name, kind, expected) in [
        ("ping", "app", 5),
        ("identify", "app", 3),
        ("set-client-info", "app", 1),
        ("ping", "unknown", 2),
        ("session.ping", "unknown", 4),
        ("server-stats", "unknown", 1),
    ] {
        let row = row(&section, name, kind)
            .unwrap_or_else(|| panic!("no row for {name} from {kind}: {section}"));
        assert_eq!(row["count"], expected, "{name} from {kind}: {section}");
        let total = row["total_ns"].as_u64().unwrap_or(0);
        let slowest = row["max_ns"].as_u64().unwrap_or(0);
        assert!(total > 0, "{name} from {kind} took time: {row}");
        assert!(slowest > 0 && slowest <= total, "{name} from {kind}: {row}");
        let histogram = row["hist"].as_array().expect("hist");
        assert_eq!(histogram.len(), 16, "{row}");
        assert_eq!(histogram.iter().filter_map(Value::as_u64).sum::<u64>(), expected, "{row}");
    }
    assert_eq!(count(&section, "ping", "terminal"), 0, "{section}");

    // 0.25 ms to 4.096 s in powers of 2: a p50 and a p95 come from two reads.
    let bounds = section["hist_bounds_ns"].as_array().expect("bounds");
    let bounds: Vec<u64> = bounds.iter().filter_map(Value::as_u64).collect();
    assert_eq!(bounds.len(), 15, "{section}");
    assert_eq!(bounds.first(), Some(&250_000), "{section}");
    assert_eq!(bounds.last(), Some(&4_096_000_000), "{section}");
    assert!(bounds.windows(2).all(|pair| pair[1] == pair[0] * 2), "{section}");

    let connections = section["connections"].as_array().expect("connections");
    let accepted = |kind: &str| {
        connections
            .iter()
            .find(|entry| entry["kind"] == kind)
            .and_then(|entry| entry["accepted"].as_u64())
            .unwrap_or(0)
    };
    assert_eq!(accepted("app"), 1, "{section}");
    assert_eq!(accepted("unknown"), 1, "{section}");
}

#[test]
fn server_stats_commands_puts_unknown_command_words_in_other() {
    let mux = Mux::new_for_test("server-stats-commands-cap", crate::SurfaceOptions::default());
    let connection = connect(&mux);
    connection.request(&mux, &ping(1));
    let before = commands(&mux, &connection);
    let names_before = before["names"].as_u64().expect("names");

    for number in 0..3000 {
        connection.post(&mux, &json!({"id": number, "cmd": format!("no-such-command-{number}")}));
        connection.drain();
    }

    let after = commands(&mux, &connection);
    assert_eq!(after["names"].as_u64(), Some(names_before), "no name was added: {after}");
    assert!(after["names"].as_u64() <= after["name_limit"].as_u64(), "{after}");
    assert!(
        count(&after, "other", "unknown") >= count(&before, "other", "unknown") + 3000,
        "the unknown words count in other: {after}"
    );
    let rows = after["rows"].as_array().expect("rows");
    assert!(rows.len() <= 8, "ping, server-stats and other only: {after}");
    assert!(
        rows.iter().all(|row| !row["name"].as_str().unwrap_or("").starts_with("no-such")),
        "{after}"
    );
}

#[test]
fn server_stats_commands_reports_no_argument_text() {
    let mux = Mux::new_for_test("server-stats-commands-private", crate::SurfaceOptions::default());
    let connection = connect(&mux);

    // A label and a kind that the daemon does not know, an unknown section name, a parameter,
    // an unknown command word, an id: none of them is a command name.
    connection.request(
        &mux,
        &json!({
            "id": "declare",
            "cmd": "set-client-info",
            "name": "SECRET-NAME-sk-live-0001",
            "kind": "SECRET-KIND-0002",
        }),
    );
    connection.request(
        &mux,
        &json!({"id": "sections", "cmd": "server-stats", "include": ["SECRET-SECTION-0003"]}),
    );
    connection.post(
        &mux,
        &resource_ping(
            "SECRET-ID-0004",
            json!({"machine": "current", "session": "current", "note": "/Users/SECRET-PATH-0005"}),
        ),
    );
    connection.post(&mux, &json!({"id": 6, "cmd": "SECRET-COMMAND-0006", "text": "SECRET-0007"}));
    connection.post(&mux, &json!({"id": 8, "cmd": "ping", "SECRET-KEY-0008": "SECRET-0009"}));
    connection.drain();

    let text = connection.request_text(
        &mux,
        &json!({"id": "read-commands", "cmd": "server-stats", "include": ["commands"]}),
    );
    let reply: Value = serde_json::from_str(&text).unwrap();
    let section = &reply["data"]["commands"];
    assert!(section.is_object(), "server-stats has no commands section: {reply}");
    // The requests are counted, under the daemon's own words.
    assert_eq!(count(section, "set-client-info", "other"), 1, "{section}");
    assert_eq!(count(section, "session.ping", "other"), 1, "{section}");
    assert!(count(section, "other", "other") >= 1, "{section}");
    assert!(!text.contains("SECRET"), "argument text in the reply: {text}");
    assert!(!section.to_string().contains("/Users/"), "a path in the section: {section}");
}

/// The cost of the counter on one request: 1 000 000 `ping` requests with it and without it, in
/// the same binary, in turns. Not a CI test: run it by name with `--release` and
/// `--ignored --nocapture`.
#[test]
#[ignore = "a measurement; run it by name"]
fn bench_command_stats_cost_per_request() {
    const REQUESTS: u32 = 1_000_000;
    const ROUNDS: usize = 5;
    let mux = Mux::new_for_test("server-stats-commands-bench", crate::SurfaceOptions::default());
    let connection = connect(&mux);
    // The first request of a name is the one that makes its row.
    connection.request(&mux, &ping(0));
    let commands_stats = mux.connection_stats().commands();
    let run = |counted: bool| {
        let started = Instant::now();
        for _ in 0..REQUESTS {
            let request = Request { id: None, cmd: Command::Ping, remote_line: None };
            if counted {
                // What a line pays: the line's own count and the command's.
                let line = commands_stats.start_line(&connection.writer.kind);
                handle_request(&mux, connection.client, request, &connection.writer);
                drop(line);
            } else {
                let writer = &connection.writer;
                super::handle_request_uncounted(&mux, connection.client, request, writer, None);
            }
            connection.drain();
        }
        started.elapsed().as_nanos() / u128::from(REQUESTS)
    };
    let (mut with, mut without) = (Vec::new(), Vec::new());
    for _ in 0..ROUNDS {
        without.push(run(false));
        with.push(run(true));
    }
    with.sort_unstable();
    without.sort_unstable();
    let (with, without) = (with[ROUNDS / 2], without[ROUNDS / 2]);
    eprintln!(
        "COMMAND-STATS-BENCH requests={REQUESTS} rounds={ROUNDS} ping_with_ns={with} \
         ping_without_ns={without} added_ns={}",
        i128::try_from(with).unwrap_or(0) - i128::try_from(without).unwrap_or(0)
    );
    assert_eq!(
        count(&commands(&mux, &connection), "ping", "unknown"),
        u64::from(REQUESTS) * ROUNDS as u64 + 1
    );
}
