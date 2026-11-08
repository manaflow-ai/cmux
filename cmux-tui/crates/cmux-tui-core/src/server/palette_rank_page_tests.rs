//! `palette.rank` (`palette-rank-v1`) on the request path a page takes
//! (`handle_connection_message`: the origin gate, then the router). The
//! Channels page's WebSocket gets exactly the shared ranker's answer; a page
//! without it on its allow list is refused, and a request past the caps is
//! refused before any ranking. The caps hold any title the app allows, and a
//! catalog past one request's entry cap ranks in several requests whose merge
//! is the one request's answer.

use std::collections::BTreeMap;

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

    // The catalog allows null for every optional field: null is the default, never a refusal.
    let mut with_nulls = channels_request("rel");
    with_nulls["operation"] = Value::Null;
    with_nulls["frecency"] = Value::Null;
    let reply = rank(&mux, &page, &with_nulls);
    assert_eq!(reply["result"]["sections"], matched["result"]["sections"], "{reply}");
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

    let long_title = "a".repeat(1_025);
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

/// The longest titles and names the app allows: a conversation or thread title
/// of 200 characters (`cmux_conversation::MAX_TITLE_CHARS`), a channel's with
/// its `#`, and a participant name of 100 characters (`MAX_DISPLAY_NAME_CHARS`)
/// for each of a conversation's 64 participants, as its keywords.
#[test]
fn a_long_cjk_title_is_ranked_whole() {
    let mux = Mux::new_for_test("palette-rank-cjk", crate::SurfaceOptions::default());
    let page = page_websocket(&mux, "home-channels");
    // 198 characters, 578 UTF-8 bytes: "Release" is past byte 512.
    let title = format!("{} Release", "发".repeat(190));
    assert_eq!(title.chars().count(), 198);
    let names = (0..64).map(|index| format!("{index:02}{}", "名".repeat(98))).collect::<Vec<_>>();
    let entries = json!([
        {"title": "general", "sectionIndex": 0},
        {"title": title, "sectionIndex": 0},
        {"title": format!("#{}", "😀".repeat(200)), "sectionIndex": 0},
        {"title": "Team", "keywords": names, "sectionIndex": 0},
    ]);
    let found = |query: &str| {
        let reply = rank(&mux, &page, &json!({"entries": entries, "query": query}));
        assert_eq!(reply["ok"], true, "{query:?}: {reply}");
        reply["result"]["sections"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|section| section["rows"].as_array().unwrap().iter())
            .map(|row| row["index"].as_u64().unwrap())
            .collect::<Vec<_>>()
    };
    assert_eq!(found("Release"), vec![1]);
    assert_eq!(found("😀😀"), vec![2]);
    // The last participant's whole name.
    assert_eq!(found(&format!("63{}", "名".repeat(98))), vec![3]);
}

/// The page's batched rank (paletteRank.ts `rankPalette`): requests of at most
/// `batch` entries, each without the typo pass; when all of them together
/// matched fewer than three rows strictly (the ranker's typo-pass threshold),
/// again with it. Their rows merge by score, then catalog order, cut to the
/// row limit; the empty query's rows are every batch's in order.
fn rank_in_batches(mux: &Arc<Mux>, page: &Conn, fields: &Value, batch: usize) -> Value {
    let entries = fields["entries"].as_array().unwrap();
    let query = fields["query"].as_str().unwrap();
    let keeps_section_order = fields["keepsSectionOrder"] == true;
    let ask = |typo_pass: Option<bool>| {
        entries
            .chunks(batch)
            .enumerate()
            .map(|(at, chunk)| {
                let mut request = fields.clone();
                request["entries"] = json!(chunk);
                request["rowLimit"] = json!(400);
                request["highlightLimit"] = json!(60);
                if let Some(typo_pass) = typo_pass {
                    request["typoPass"] = json!(typo_pass);
                }
                let reply = rank(mux, page, &request);
                assert_eq!(reply["ok"], true, "{reply}");
                (at * batch, reply["result"].clone())
            })
            .collect::<Vec<_>>()
    };
    let rows_of = |replies: &[(usize, Value)]| {
        replies
            .iter()
            .flat_map(|(start, result)| {
                result["sections"].as_array().unwrap().iter().flat_map(move |section| {
                    section["rows"].as_array().unwrap().iter().map(move |row| {
                        let mut row = row.clone();
                        row["index"] = json!(row["index"].as_u64().unwrap() + *start as u64);
                        (section["sectionIndex"].as_i64().unwrap(), row)
                    })
                })
            })
            .collect::<Vec<_>>()
    };
    let grouped = |rows: Vec<(i64, Value)>, by_index: bool| {
        let mut order = Vec::<i64>::new();
        let mut by_section = BTreeMap::<i64, Vec<Value>>::new();
        for (section, row) in rows {
            if !by_section.contains_key(&section) {
                order.push(section);
            }
            by_section.entry(section).or_default().push(row);
        }
        if by_index {
            order.sort();
        }
        Value::Array(
            order
                .into_iter()
                .map(|section| json!({"sectionIndex": section, "rows": by_section[&section]}))
                .collect(),
        )
    };
    if query.trim().is_empty() {
        return grouped(rows_of(&ask(None)), true);
    }
    let mut replies = ask(Some(false));
    let strict =
        replies.iter().map(|(_, result)| result["strictMatches"].as_u64().unwrap()).sum::<u64>();
    if strict < 3 {
        replies = ask(Some(true));
    }
    let mut rows = rows_of(&replies);
    rows.sort_by(|(_, left), (_, right)| {
        right["score"]
            .as_i64()
            .cmp(&left["score"].as_i64())
            .then(left["index"].as_u64().cmp(&right["index"].as_u64()))
    });
    rows.truncate(400);
    for (rank, (_, row)) in rows.iter_mut().enumerate() {
        if rank >= 60 {
            row["highlights"] = json!([]);
        }
    }
    grouped(rows, keeps_section_order)
}

/// A Channels catalog past one request's 5,000 entries: conversations first,
/// then threads and actions. "Relaese checklist" is one edit from "release",
/// so a batch that alone found fewer than three strict matches for it would
/// run the typo pass that the whole catalog does not.
fn big_channels_catalog(query: &str) -> Value {
    let mut entries = (0..5_200)
        .map(|index| {
            let title = if index % 1_000 == 7 {
                format!("Release train {index}")
            } else {
                format!("Conversation {index}")
            };
            json!({"title": title, "keywords": [format!("person {}", index % 97)],
                   "sectionIndex": 0, "isVisibleWhenQueryEmpty": true})
        })
        .collect::<Vec<_>>();
    entries.extend([
        json!({"title": "Relaese checklist", "sectionIndex": 1, "isVisibleWhenQueryEmpty": true}),
        json!({"title": "Fix the release notes", "sectionIndex": 1, "isVisibleWhenQueryEmpty": true}),
        json!({"title": "New message", "keywords": ["create", "room"], "sectionIndex": 2,
               "isVisibleWhenQueryEmpty": true}),
        json!({"title": "Resolve thread", "sectionIndex": 2, "isVisibleWhenQueryEmpty": true}),
    ]);
    json!({"entries": entries, "query": query, "keepsSectionOrder": true})
}

#[test]
fn a_catalog_past_the_entry_cap_ranks_in_batches_as_one_request() {
    let mux = Mux::new_for_test("palette-rank-batches", crate::SurfaceOptions::default());
    let page = page_websocket(&mux, "home-channels");
    for query in ["", "release", "relese", "New message", "nm", "conversation 51", "conv", "zzz"] {
        let fields = big_channels_catalog(query);
        let request: cmux_palette_ranker::RankRequest =
            serde_json::from_value(fields.clone()).unwrap();
        let expected = serde_json::to_value(cmux_palette_ranker::rank_request(&request)).unwrap();
        for batch in [5_000, 2_000] {
            assert_eq!(
                rank_in_batches(&mux, &page, &fields, batch),
                expected,
                "{query:?} by {batch}"
            );
        }
    }
    // The action past the cap is found, and only "release"'s strict matches rank: the second
    // batch alone (one strict match) would have added the typo row.
    let index_of = |title: &str| {
        big_channels_catalog("")["entries"]
            .as_array()
            .unwrap()
            .iter()
            .position(|entry| entry["title"] == title)
            .unwrap() as u64
    };
    let indexes = |sections: &Value| {
        sections
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|section| section["rows"].as_array().unwrap().iter())
            .map(|row| row["index"].as_u64().unwrap())
            .collect::<Vec<_>>()
    };
    let found = rank_in_batches(&mux, &page, &big_channels_catalog("New message"), 5_000);
    assert_eq!(indexes(&found).first(), Some(&index_of("New message")), "{found}");
    let release = indexes(&rank_in_batches(&mux, &page, &big_channels_catalog("release"), 5_000));
    assert!(release.contains(&index_of("Fix the release notes")), "{release:?}");
    assert!(!release.contains(&index_of("Relaese checklist")), "{release:?}");
    let mut tail = big_channels_catalog("release");
    let tail_entries = tail["entries"].as_array().unwrap()[5_000..].to_vec();
    tail["entries"] = json!(tail_entries);
    let alone = rank(&mux, &page, &tail);
    assert!(
        indexes(&alone["result"]["sections"]).contains(&(index_of("Relaese checklist") - 5_000)),
        "{alone}"
    );
}
