//! Wire tests for the bookmark tree of each browser profile in the home
//! session (`bookmarks-v1`, plans/cmux-next/bookmarks.md sections 1 and 2.1).

use super::super::*;

const FOLDER: &str = "bm_00000000000000000000000000000001";
const PAGE: &str = "bm_00000000000000000000000000000002";

/// Decode the request line as the server does (the envelope's `id` is the
/// request id, so a bookmark is named by `bookmark`) and run it.
fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let mut request = request;
    request["id"] = json!(7);
    let request: Request = serde_json::from_str(&request.to_string())?;
    handle_command(mux, mux.local_test_client(0), request.cmd, &writer)
}

fn bookmarks_mux() -> Arc<Mux> {
    Mux::new_for_test("bookmarks", crate::SurfaceOptions::default())
}

fn listed(mux: &Arc<Mux>, profile: &str) -> Value {
    run(mux, json!({"cmd":"list-bookmarks","browser_profile_id":profile})).unwrap()
}

fn ids(listing: &Value) -> Vec<String> {
    listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| node["id"].as_str().unwrap().to_string())
        .collect()
}

fn create(mux: &Arc<Mux>, request: Value) -> Value {
    let mut request = request;
    request["cmd"] = json!("create-bookmark");
    run(mux, request).unwrap()
}

/// The machine-readable `error_code` the response envelope carries.
fn error_code(result: anyhow::Result<Value>) -> String {
    let error = result.expect_err("the command must fail");
    response_error_code(&error).unwrap_or_else(|| format!("no code: {error}"))
}

fn bookmark_events(events: &crate::event_bus::MuxEventReceiver) -> Vec<Value> {
    events
        .try_iter()
        .map(|event| subscribed_event_json(&event))
        .filter(|event| event["event"] == "bookmarks-changed")
        .collect()
}

#[test]
fn bookmarks_round_trip_over_the_wire() {
    let mux = bookmarks_mux();
    let events = mux.subscribe();
    let folder = create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","kind":"folder","title":"Work",
               "bookmark":FOLDER,"created_ms":1000}),
    );
    assert_eq!(folder["changed"], true);
    assert_eq!(
        folder["bookmark"],
        json!({"id":FOLDER,"browser_profile_id":"default","parent":"bar","kind":"folder",
               "index":0,"title":"Work","created_ms":1000})
    );
    let revision = listed(&mux, "default")["bookmarks_revision"].as_u64().unwrap();
    assert_eq!(revision, 1);
    assert_eq!(
        bookmark_events(&events),
        vec![json!({"event":"bookmarks-changed","browser_profile_id":"default",
                    "bookmarks_revision":1})]
    );
    // A retry with the same id returns the stored node and changes nothing.
    let retried = create(
        &mux,
        json!({"browser_profile_id":"default","parent":"other","kind":"folder","title":"Other",
               "bookmark":FOLDER}),
    );
    assert_eq!(retried["changed"], false);
    assert_eq!(retried["bookmark"]["title"], "Work");
    assert_eq!(listed(&mux, "default")["bookmarks_revision"], 1);
    assert!(bookmark_events(&events).is_empty());

    let page = create(
        &mux,
        json!({"browser_profile_id":"default","parent":FOLDER,"kind":"url","title":"Docs",
               "url":"https://example.com/docs","favicon_key":"https://example.com","bookmark":PAGE}),
    );
    assert_eq!(page["bookmark"]["parent"], FOLDER);
    assert_eq!(page["bookmark"]["index"], 0);
    assert!(page["bookmark"]["created_ms"].as_u64().unwrap() > 1000);
    // An absent index appends; an index inserts and shifts the siblings.
    let last = create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","kind":"url","title":"",
               "url":"https://last.example"}),
    );
    let last_id = last["bookmark"]["id"].as_str().unwrap().to_string();
    assert!(last_id.starts_with("bm_") && last_id.len() == 35);
    assert_eq!(last_id, last_id.to_lowercase());
    assert_eq!(last["bookmark"]["index"], 1);
    let first = create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","index":0,"kind":"url",
               "title":"First","url":"about:blank"}),
    );
    let first_id = first["bookmark"]["id"].as_str().unwrap().to_string();
    // A move's index is the final position, in the same parent too.
    let reordered =
        run(&mux, json!({"cmd":"move-bookmark","bookmark":first_id,"parent":"bar","index":1}))
            .unwrap();
    assert_eq!(reordered["changed"], true);
    assert_eq!(reordered["bookmark"]["index"], 1);
    assert_eq!(
        ids(&listed(&mux, "default")),
        vec![FOLDER.to_string(), PAGE.to_string(), first_id.clone(), last_id.clone()]
    );
    run(&mux, json!({"cmd":"move-bookmark","bookmark":first_id,"parent":"bar","index":0})).unwrap();
    let listing = listed(&mux, "default");
    // Depth-first: each folder is followed by its subtree.
    assert_eq!(
        ids(&listing),
        vec![first_id.clone(), FOLDER.to_string(), PAGE.to_string(), last_id.clone()]
    );
    let indexes = listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["index"].clone())
        .collect::<Vec<_>>();
    assert_eq!(indexes, vec![json!(0), json!(1), json!(0), json!(2)]);

    // Absent keeps, null clears.
    let updated = run(
        &mux,
        json!({"cmd":"update-bookmark","bookmark":PAGE,"title":"Docs 2","last_used_ms":5000}),
    )
    .unwrap();
    assert_eq!(updated["changed"], true);
    assert_eq!(updated["bookmark"]["title"], "Docs 2");
    assert_eq!(updated["bookmark"]["url"], "https://example.com/docs");
    assert_eq!(updated["bookmark"]["favicon_key"], "https://example.com");
    assert_eq!(updated["bookmark"]["last_used_ms"], 5000);
    let cleared = run(
        &mux,
        json!({"cmd":"update-bookmark","bookmark":PAGE,"favicon_key":null,"last_used_ms":null,
               "url":"https://example.com/new"}),
    )
    .unwrap();
    assert!(cleared["bookmark"].get("favicon_key").is_none());
    assert!(cleared["bookmark"].get("last_used_ms").is_none());
    assert_eq!(cleared["bookmark"]["url"], "https://example.com/new");
    let unchanged =
        run(&mux, json!({"cmd":"update-bookmark","bookmark":PAGE,"title":"Docs 2"})).unwrap();
    assert_eq!(unchanged["changed"], false);

    // Move into another parent, then reorder with a clamped index.
    let moved =
        run(&mux, json!({"cmd":"move-bookmark","bookmark":last_id,"parent":FOLDER,"index":0}))
            .unwrap();
    assert_eq!(moved["changed"], true);
    assert_eq!(moved["bookmark"]["parent"], FOLDER);
    assert_eq!(moved["bookmark"]["index"], 0);
    let clamped =
        run(&mux, json!({"cmd":"move-bookmark","bookmark":last_id,"parent":FOLDER,"index":99}))
            .unwrap();
    assert_eq!(clamped["bookmark"]["index"], 1);
    assert_eq!(
        ids(&listed(&mux, "default")),
        vec![first_id.clone(), FOLDER.to_string(), PAGE.to_string(), last_id.clone()]
    );
    let same =
        run(&mux, json!({"cmd":"move-bookmark","bookmark":last_id,"parent":FOLDER,"index":2}))
            .unwrap();
    assert_eq!(same["changed"], false);
    // A folder cannot move into itself or a descendant.
    let inner = create(
        &mux,
        json!({"browser_profile_id":"default","parent":FOLDER,"kind":"folder","title":"Inner"}),
    );
    let inner_id = inner["bookmark"]["id"].as_str().unwrap().to_string();
    for parent in [FOLDER, inner_id.as_str()] {
        assert_eq!(
            error_code(run(
                &mux,
                json!({"cmd":"move-bookmark","bookmark":FOLDER,"parent":parent,"index":0})
            )),
            "invalid_params"
        );
    }

    // Deleting a folder deletes its subtree and closes the gap.
    let revision_before = listed(&mux, "default")["bookmarks_revision"].as_u64().unwrap();
    let deleted = run(&mux, json!({"cmd":"delete-bookmark","bookmark":FOLDER})).unwrap();
    let mut deleted_ids = deleted["deleted"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| id.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    deleted_ids.sort();
    let mut expected = vec![FOLDER.to_string(), PAGE.to_string(), last_id, inner_id];
    expected.sort();
    assert_eq!(deleted_ids, expected);
    let listing = listed(&mux, "default");
    assert_eq!(ids(&listing), vec![first_id]);
    assert_eq!(listing["bookmarks"][0]["index"], 0);
    assert_eq!(listing["bookmarks_revision"].as_u64().unwrap(), revision_before + 1);
    assert_eq!(
        error_code(run(&mux, json!({"cmd":"delete-bookmark","bookmark":FOLDER}))),
        "not_found"
    );
}
