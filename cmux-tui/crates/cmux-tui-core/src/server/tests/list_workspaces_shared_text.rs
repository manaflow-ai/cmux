//! Clients that read the tree at once share one build (`TreeReplyFlight`), but each of them wrote
//! that shared tree into its own reply: N clients made N serializations of the same tree, each
//! O(workspaces + terminals), one after another on N reader threads. At 800 workspaces and 10
//! clients this is most of a `list-workspaces` reply's time after the build.
//!
//! The readers of one build share one serialization of its tree. Each reply is still its own:
//! its own `id`, its own `lines_written_before_read`, and its own projection for the
//! capabilities its connection declared (`project_conversation_tabs`, `project_api_revision`).
//! The count is a count of serializations, so a loaded host does not change it.

use super::*;
use crate::state::conversation_tabs_store::{
    AGENT_SESSION_TABS_CAPABILITY, CLOSED_CONVERSATION_TABS_CAPABILITY,
    CONVERSATION_TABS_CAPABILITY, PAGE_TABS_CAPABILITY,
};
use std::sync::atomic::Ordering;
use std::sync::mpsc::sync_channel;
use std::time::Instant;

const READERS: usize = 8;

/// A local connection of the daemon.
struct Connection {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
}

impl Connection {
    /// A local (Unix socket) connection whose writer uses `render`, the daemon's render service,
    /// with `capabilities` declared when there are any.
    fn open(mux: &Arc<Mux>, render: &Arc<RenderService>, capabilities: &[&str]) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new_with_render_service(
            QueuedSink { outbound: outbound.clone(), control: None },
            render.clone(),
        );
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let connection = Self { client, writer, outbound };
        if !capabilities.is_empty() {
            let info = connection.ask(
                mux,
                json!({"id": "info", "cmd": "set-client-info", "name": "test",
                       "capabilities": capabilities}),
            );
            assert!(info.contains("\"ok\":true"), "{info}");
        }
        connection
    }

    /// The reply line to `request`, as the socket sends it.
    fn ask(&self, mux: &Arc<Mux>, request: Value) -> String {
        let request: Request = serde_json::from_value(request).unwrap();
        assert!(handle_request(mux, self.client, request, &self.writer));
        self.reply()
    }

    fn reply(&self) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(line) = self.outbound.try_pop() {
                return line;
            }
            assert!(Instant::now() < deadline, "no reply");
            std::thread::yield_now();
        }
    }
}

/// Six workspaces of two terminal tabs each.
fn session() -> Arc<Mux> {
    let mux = test_mux();
    for index in 0..6 {
        let surface = mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap();
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    }
    mux
}

fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::yield_now();
    }
}

#[test]
fn the_readers_of_one_build_share_one_serialization_of_its_tree() {
    let mux = session();
    let render = Arc::new(RenderService::new());
    let connections: Vec<Connection> =
        (0..READERS).map(|_| Connection::open(&mux, &render, &[])).collect();

    // A read holds a build open, so each reader that arrives now needs the build after it, and
    // they all share that one.
    let (started, running) = sync_channel(1);
    let (release, gate) = sync_channel::<()>(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.tree_reply_flight
                .read(move || {
                    started.send(()).unwrap();
                    gate.recv_timeout(Duration::from_secs(10)).unwrap();
                    Ok(Value::Null)
                })
                .unwrap()
        })
    };
    running.recv_timeout(Duration::from_secs(10)).unwrap();

    let before = render.control_serializations.load(Ordering::SeqCst);
    let readers = connections
        .into_iter()
        .enumerate()
        .map(|(index, connection)| {
            let mux = mux.clone();
            std::thread::spawn(move || {
                connection.ask(&mux, json!({"id": index, "cmd": "list-workspaces"}))
            })
        })
        .collect::<Vec<_>>();
    wait_until("every reader waits for the next build", || {
        mux.tree_reply_flight.waiting_readers() == READERS
    });
    release.send(()).unwrap();
    holder.join().unwrap();
    let replies = readers.into_iter().map(|reader| reader.join().unwrap()).collect::<Vec<_>>();
    let serializations = render.control_serializations.load(Ordering::SeqCst) - before;

    for (index, reply) in replies.iter().enumerate() {
        let reply: Value = serde_json::from_str(reply).unwrap();
        assert_eq!(reply["id"], json!(index), "each reply has its own id");
        assert_eq!(reply["data"]["workspaces"].as_array().map(Vec::len), Some(6), "{reply}");
        assert_eq!(reply["data"]["lines_written_before_read"], json!(0), "{reply}");
    }
    assert_eq!(
        serializations, 1,
        "{READERS} readers of one build made {serializations} serializations of its tree"
    );
    mux.shutdown();
}

/// Readers of one build that read the tab kinds in two ways: each gets the bytes that the command
/// path writes for its connection, and the build is written one time for each of the two ways.
#[test]
fn the_readers_of_one_build_share_one_text_for_each_tab_projection() {
    let mux = tricky_session();
    let render = Arc::new(RenderService::new());
    let all = [
        CONVERSATION_TABS_CAPABILITY,
        AGENT_SESSION_TABS_CAPABILITY,
        PAGE_TABS_CAPABILITY,
        CLOSED_CONVERSATION_TABS_CAPABILITY,
    ];
    let declared: [&[&str]; 4] = [&[], &all, &[], &all];
    let connections: Vec<Connection> =
        declared.iter().map(|capabilities| Connection::open(&mux, &render, capabilities)).collect();

    let (started, running) = sync_channel(1);
    let (release, gate) = sync_channel::<()>(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            mux.tree_reply_flight
                .read(move || {
                    started.send(()).unwrap();
                    gate.recv_timeout(Duration::from_secs(10)).unwrap();
                    Ok(Value::Null)
                })
                .unwrap()
        })
    };
    running.recv_timeout(Duration::from_secs(10)).unwrap();

    let before = render.control_serializations.load(Ordering::SeqCst);
    let readers = connections
        .into_iter()
        .enumerate()
        .map(|(index, connection)| {
            let mux = mux.clone();
            std::thread::spawn(move || {
                connection.ask(&mux, json!({"id": index, "cmd": "list-workspaces"}))
            })
        })
        .collect::<Vec<_>>();
    wait_until("every reader waits for the next build", || {
        mux.tree_reply_flight.waiting_readers() == declared.len()
    });
    release.send(()).unwrap();
    holder.join().unwrap();
    let replies = readers.into_iter().map(|reader| reader.join().unwrap()).collect::<Vec<_>>();
    let serializations = render.control_serializations.load(Ordering::SeqCst) - before;
    assert_eq!(
        serializations, 2,
        "4 readers of one build with 2 tab projections made {serializations} texts of its tree"
    );

    for (index, (reply, capabilities)) in replies.iter().zip(declared).enumerate() {
        // A connection with the same history, so the same lines written before its read.
        let reference = Connection::open(&mux, &render, capabilities);
        let expected = value_path_reply(&mux, &reference, Some(json!(index)));
        assert_eq!(reply, &expected, "capabilities {capabilities:?}");
        assert_eq!(
            reply.contains("\"kind\":\"conversation\""),
            !capabilities.is_empty(),
            "capabilities {capabilities:?}"
        );
    }
    mux.shutdown();
}

/// The reply the command path makes of `list-workspaces`: the tree value in a `Response`,
/// serialized by the connection's writer.
fn value_path_reply(mux: &Arc<Mux>, connection: &Connection, id: Option<Value>) -> String {
    let lines_written = connection.writer.lines_written();
    let data =
        cmd_workspaces::list_workspaces(mux, connection.client, lines_written, None, None).unwrap();
    let response = Response {
        id,
        ok: true,
        data: Some(data),
        error: None,
        error_code: None,
        error_delivery: None,
    };
    assert!(responses::send_response_with_details(&connection.writer, response, None, None, None));
    connection.reply()
}

/// A session whose names hold the keys and kinds a reply rewrites or adds, with a conversation
/// tab that the projection rewrites for a connection that did not declare the capabilities.
fn tricky_session() -> Arc<Mux> {
    let mux = session();
    for name in [
        "lines_written_before_read",
        "\"lines_written_before_read\":1,\"conversation\"",
        "conversation \u{1F600} \\ \u{7}",
    ] {
        mux.new_workspace(Some(name.to_string()), Some((80, 24))).unwrap();
    }
    let terminal = mux.new_workspace(Some("agents".into()), Some((80, 24))).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let request = json!({"cmd": "new-conversation-tab", "pane": pane,
                         "agent_session": {"host": "install:mac-test"}});
    let command: Command = serde_json::from_value(request).unwrap();
    handle_command(
        &mux,
        mux.local_test_client(0),
        command,
        &MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        }),
    )
    .unwrap();
    mux
}

#[test]
fn each_connection_gets_the_bytes_of_the_value_path() {
    let mux = tricky_session();
    let render = Arc::new(RenderService::new());
    let all = [
        CONVERSATION_TABS_CAPABILITY,
        AGENT_SESSION_TABS_CAPABILITY,
        PAGE_TABS_CAPABILITY,
        CLOSED_CONVERSATION_TABS_CAPABILITY,
    ];
    let declared: [&[&str]; 4] = [&all, &[], &all[..3], &all[..1]];
    let ids =
        [None, Some(json!(7)), Some(json!("list \"1\" \u{e9}")), Some(json!({"k": [1, null]}))];
    let mut rewritten = 0;
    for capabilities in declared {
        // Two connections with the same history, so the same lines written before each read: one
        // asks through the socket path, the other gets the command path's reply.
        let asked = Connection::open(&mux, &render, capabilities);
        let reference = Connection::open(&mux, &render, capabilities);
        for id in &ids {
            let mut request = json!({"cmd": "list-workspaces"});
            if let Some(id) = id {
                request["id"] = id.clone();
            }
            let sent = asked.ask(&mux, request);
            let expected = value_path_reply(&mux, &reference, id.clone());
            assert_eq!(sent, expected, "capabilities {capabilities:?}, id {id:?}");
            rewritten += usize::from(!sent.contains("\"kind\":\"conversation\""));
        }
        let lines =
            serde_json::from_str::<Value>(&asked.ask(&mux, json!({"cmd": "list-workspaces"})))
                .unwrap()["data"]["lines_written_before_read"]
                .clone();
        let before = ids.len() + usize::from(!capabilities.is_empty());
        assert_eq!(lines, json!(before), "the reply names the lines written before its read");
    }
    assert!(rewritten > 0, "a connection without the capabilities gets a rewritten tree");
    mux.shutdown();
}
