//! `palette.rank` (`palette-rank-v1`) on the request path a page takes
//! (`handle_connection_message`: the origin gate, then the router). The
//! Channels page's WebSocket gets exactly the shared ranker's answer; a page
//! without it on its allow list is refused, and a request past the caps is
//! refused before any ranking.

use serde_json::{Value, json};

use crate::server::origin_gate::set_scoped_page;
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn page_websocket(mux: &Arc<Mux>, page: &str) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::WebSocket, writer.clone());
    set_scoped_page(mux, client, page.to_owned());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

fn rank(mux: &Arc<Mux>, conn: &Conn, fields: &Value) -> Value {
    let mut params = json!({"machine": "current", "session": "current"});
    for (key, value) in fields.as_object().unwrap() {
        params[key] = value.clone();
    }
    let request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": "palette.rank", "params": params,
    });
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    serde_json::from_str(&conn.outbound.try_pop().expect("a synchronous reply")).unwrap()
}

/// The Channels palette's request: conversations, threads and actions as
/// sections 0, 1 and 2, kept in section order.
fn channels_request(query: &str) -> Value {
    json!({
        "entries": [
            {"title": "general", "sectionIndex": 0, "isVisibleWhenQueryEmpty": true},
            {"title": "Release train", "keywords": ["ship"], "sectionIndex": 0,
             "isVisibleWhenQueryEmpty": true},
            {"title": "Fix the release notes", "sectionIndex": 1, "isVisibleWhenQueryEmpty": true},
            {"title": "New channel", "keywords": ["create", "room"], "sectionIndex": 2,
             "isVisibleWhenQueryEmpty": true},
            {"title": "Resolve thread", "sectionIndex": 2, "isVisibleWhenQueryEmpty": true},
        ],
        "query": query,
        "keepsSectionOrder": true,
    })
}

#[test]
fn the_channels_page_gets_the_shared_rankers_sections() {
    let mux = Mux::new_for_test("palette-rank-page", crate::SurfaceOptions::default());
    let page = page_websocket(&mux, "home-channels");
    for query in ["", "rel", "nc", "ship", "zzz"] {
        let fields = channels_request(query);
        let reply = rank(&mux, &page, &fields);
        assert_eq!(reply["ok"], true, "{query:?}: {reply}");
        let request: cmux_palette_ranker::RankRequest =
            serde_json::from_value(fields.clone()).unwrap();
        let expected = serde_json::to_value(cmux_palette_ranker::rank_request(&request)).unwrap();
        assert_eq!(reply["result"]["sections"], expected, "{query:?}");
    }
    // A query that matches ranks something, so the comparison above is not
    // only of empty answers.
    let matched = rank(&mux, &page, &channels_request("rel"));
    let rows = matched["result"]["sections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|section| section["rows"].as_array().unwrap().len())
        .sum::<usize>();
    assert!(rows >= 2, "{matched}");
}

#[test]
fn a_page_without_it_on_its_allow_list_is_refused() {
    let mux = Mux::new_for_test("palette-rank-other-page", crate::SurfaceOptions::default());
    let page = page_websocket(&mux, "history");
    let reply = rank(&mux, &page, &channels_request("rel"));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
}

#[test]
fn a_request_past_the_caps_is_refused() {
    let mux = Mux::new_for_test("palette-rank-caps", crate::SurfaceOptions::default());
    let page = page_websocket(&mux, "home-channels");
    let too_many_entries = vec![json!({"title": "a"}); 5_001];
    let reply = rank(&mux, &page, &json!({"entries": too_many_entries, "query": "a"}));
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");

    let long_title = "a".repeat(513);
    let reply = rank(&mux, &page, &json!({"entries": [{"title": long_title}], "query": "a"}));
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");

    let history = (0..=crate::resource_router::palette_rank::MAX_HISTORY_ENTRIES)
        .map(|index| (format!("k{index}"), json!({"score": 1.0, "lastUsed": 0.0})))
        .collect::<serde_json::Map<_, _>>();
    let reply = rank(
        &mux,
        &page,
        &json!({"entries": [{"title": "a"}], "query": "a", "frecency": {"entries": history}}),
    );
    assert_eq!(reply["error"]["code"], "validation.invalid", "{reply}");
    assert_eq!(reply["error"]["details"]["field"], "frecency.entries", "{reply}");
}
