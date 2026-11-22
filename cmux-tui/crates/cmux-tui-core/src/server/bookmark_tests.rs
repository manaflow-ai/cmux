//! Wire tests for the bookmark tree of each browser profile in the home
//! session (`bookmarks-v1`, plans/cmux-next/bookmarks.md sections 1 and 2.1).

use super::super::*;

const WORK: &str = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";
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
fn bookmarks_capability_is_advertised_and_a_profile_starts_empty() {
    let mux = bookmarks_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|value| value == "bookmarks-v1")
    );
    let listing = listed(&mux, "default");
    assert_eq!(listing["bookmarks_revision"], 0);
    assert_eq!(listing["bookmarks"], json!([]));
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

#[test]
fn bookmark_commands_refuse_bad_input() {
    let mux = bookmarks_mux();
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Work"}))
        .unwrap();
    create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","kind":"folder","title":"F",
               "bookmark":FOLDER}),
    );
    create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","kind":"url","title":"P",
               "url":"https://example.com","bookmark":PAGE}),
    );
    let long_title = "x".repeat(4097);
    let long_url = format!("https://example.com/{}", "a".repeat(65536));
    let invalid = [
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"nowhere","kind":"url","title":"t","url":"https://a.example"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"link","title":"t","url":"https://a.example"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"url","title":"t"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"url","title":"t","url":"relative/path"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"url","title":"t","url":long_url}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"folder","title":"t","url":"https://a.example"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"folder","title":long_title}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"folder","title":"t","bookmark":"bm_XYZ"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":PAGE,"kind":"folder","title":"t"}),
        json!({"cmd":"create-bookmark","browser_profile_id":WORK,"parent":FOLDER,"kind":"folder","title":"t"}),
        json!({"cmd":"create-bookmark","browser_profile_id":"Not A Profile","parent":"bar","kind":"folder","title":"t"}),
        json!({"cmd":"update-bookmark","bookmark":FOLDER,"url":"https://a.example"}),
        json!({"cmd":"update-bookmark","bookmark":PAGE,"url":"not a url"}),
        json!({"cmd":"move-bookmark","bookmark":PAGE,"parent":PAGE,"index":0}),
        json!({"cmd":"move-bookmark","bookmark":PAGE,"parent":"nowhere","index":0}),
        // source_key marks an imported folder; a URL never carries one.
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar","kind":"url","title":"t","url":"https://a.example","source_key":"chrome/Default"}),
    ];
    for bad in invalid {
        assert_eq!(error_code(run(&mux, bad.clone())), "invalid_params", "{bad}");
    }
    let unknown = "bm_ffffffffffffffffffffffffffffffff";
    let missing_profile = "11111111-1111-4111-8111-111111111111";
    for bad in [
        json!({"cmd":"update-bookmark","bookmark":unknown,"title":"t"}),
        json!({"cmd":"move-bookmark","bookmark":unknown,"parent":"bar","index":0}),
        json!({"cmd":"delete-bookmark","bookmark":unknown}),
        json!({"cmd":"list-bookmarks","browser_profile_id":missing_profile}),
        json!({"cmd":"create-bookmark","browser_profile_id":missing_profile,"parent":"bar","kind":"folder","title":"t"}),
    ] {
        assert_eq!(error_code(run(&mux, bad.clone())), "not_found", "{bad}");
    }
    // Nothing above changed the tree.
    let listing = listed(&mux, "default");
    assert_eq!(listing["bookmarks_revision"], 2);
    assert_eq!(ids(&listing), vec![FOLDER.to_string(), PAGE.to_string()]);
    assert_eq!(listed(&mux, WORK)["bookmarks"], json!([]));
}

#[test]
fn importing_bookmarks_writes_one_tree_and_replaces_by_source_key() {
    let mux = bookmarks_mux();
    let events = mux.subscribe();
    create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","kind":"url","title":"Mine",
               "url":"https://mine.example","bookmark":PAGE}),
    );
    let tree = json!([{
        "kind":"folder","title":"Imported from Chrome","children":[
            {"kind":"url","title":"A","url":"https://a.example","created_ms":42},
            {"kind":"folder","title":"Sub","children":[
                {"kind":"url","title":"B","url":"https://b.example"}
            ]}
        ]
    }]);
    let imported = run(
        &mux,
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"bar","index":0,
               "source_key":"chrome/Default","replace":true,"nodes":tree}),
    )
    .unwrap();
    assert_eq!(imported["count"], 4);
    let root = imported["root_ids"][0].as_str().unwrap().to_string();
    let listing = listed(&mux, "default");
    assert_eq!(listing["bookmarks_revision"], 2);
    let nodes = listing["bookmarks"].as_array().unwrap();
    assert_eq!(nodes.len(), 5);
    assert_eq!(nodes[0]["id"], root);
    assert_eq!(nodes[0]["index"], 0);
    assert_eq!(nodes[0]["source_key"], "chrome/Default");
    assert_eq!(nodes[1]["title"], "A");
    assert_eq!(nodes[1]["created_ms"], 42);
    assert_eq!(nodes[1]["parent"], root);
    assert_eq!(nodes[2]["title"], "Sub");
    assert_eq!(nodes[3]["title"], "B");
    assert_eq!(nodes[3]["parent"], nodes[2]["id"]);
    assert_eq!(nodes[4]["id"], PAGE);
    assert_eq!(nodes[4]["index"], 1);
    assert_eq!(bookmark_events(&events).len(), 2);

    // Move the import after the user's bookmark; a re-import refills it in
    // place: same id and position, new title and children.
    run(&mux, json!({"cmd":"move-bookmark","bookmark":root,"parent":"bar","index":2})).unwrap();
    let again = run(
        &mux,
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"other",
               "source_key":"chrome/Default","replace":true,
               "nodes":[{"kind":"folder","title":"Chrome","children":[
                   {"kind":"url","title":"C","url":"https://c.example"}]}]}),
    )
    .unwrap();
    assert_eq!(again["root_ids"], json!([root]));
    assert_eq!(again["count"], 2);
    let listing = listed(&mux, "default");
    let nodes = listing["bookmarks"].as_array().unwrap();
    assert_eq!(nodes.len(), 3);
    assert_eq!(nodes[0]["id"], PAGE);
    assert_eq!(nodes[1]["id"], root);
    assert_eq!(nodes[1]["parent"], "bar");
    assert_eq!(nodes[1]["index"], 1);
    assert_eq!(nodes[1]["title"], "Chrome");
    assert_eq!(nodes[2]["title"], "C");

    // Without replace, the nodes are added as new roots at parent/index.
    let plain = run(
        &mux,
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"other",
               "nodes":[{"kind":"url","title":"D","url":"https://d.example"},
                        {"kind":"url","title":"E","url":"https://e.example"}]}),
    )
    .unwrap();
    assert_eq!(plain["count"], 2);
    assert_eq!(plain["root_ids"].as_array().unwrap().len(), 2);

    // In replace mode only the first node (a folder) carries source_key;
    // the other nodes follow it.
    let safari = run(
        &mux,
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"other",
               "index":0,"source_key":"safari/x","replace":true,
               "nodes":[{"kind":"folder","title":"Safari"},
                        {"kind":"url","title":"Z","url":"https://z.example"}]}),
    )
    .unwrap();
    assert_eq!(safari["count"], 2);
    let listing = listed(&mux, "default");
    let other = listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|node| node["parent"] == "other")
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(other.len(), 4);
    assert_eq!(other[0]["id"], safari["root_ids"][0]);
    assert_eq!(other[0]["source_key"], "safari/x");
    assert_eq!(other[1]["id"], safari["root_ids"][1]);
    assert!(other[1].get("source_key").is_none());
    assert_eq!(other[2]["title"], "D");

    // One transaction: a bad node deep in the tree writes nothing.
    let revision = listed(&mux, "default")["bookmarks_revision"].clone();
    for bad in [
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"bar",
               "nodes":[{"kind":"folder","title":"X","children":[
                   {"kind":"url","title":"ok","url":"https://ok.example"},
                   {"kind":"url","title":"bad","url":"nope"}]}]}),
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"bar",
               "replace":true,"nodes":[{"kind":"folder","title":"X"}]}),
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"bar",
               "source_key":"s","replace":true,
               "nodes":[{"kind":"url","title":"X","url":"https://x.example"}]}),
        json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"bar",
               "nodes":[{"kind":"url","title":"X","url":"https://x.example",
                         "children":[]}]}),
    ] {
        assert_eq!(error_code(run(&mux, bad.clone())), "invalid_params", "{bad}");
    }
    assert_eq!(listed(&mux, "default")["bookmarks_revision"], revision);
}

#[test]
fn bookmark_trees_are_limited_in_depth_and_size() {
    let mux = bookmarks_mux();
    let chain = |depth: usize| {
        let mut node = json!({"kind":"folder","title":"f"});
        for _ in 1..depth {
            node = json!({"kind":"folder","title":"f","children":[node]});
        }
        node
    };
    let import_under = |parent: &str, nodes: Value| {
        run(
            &mux,
            json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":parent,
                   "nodes":nodes}),
        )
    };
    let import = |nodes: Value| import_under("bar", nodes);
    // Depth-first order lists the deepest folder of a chain last.
    let deepest = || ids(&listed(&mux, "default")).last().cloned().unwrap();
    assert_eq!(import(json!([chain(32)])).unwrap()["count"], 32);
    let middle = deepest();
    assert_eq!(error_code(import_under(&middle, json!([chain(33)]))), "invalid_params");
    assert_eq!(import_under(&middle, json!([chain(32)])).unwrap()["count"], 32);
    let bottom = deepest();
    assert_eq!(
        error_code(run(
            &mux,
            json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":bottom,
                   "kind":"folder","title":"too deep"})
        )),
        "invalid_params"
    );
    let top = ids(&listed(&mux, "default"))[0].clone();
    let other_top = import(json!([{"kind":"folder","title":"g"}])).unwrap()["root_ids"][0]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        error_code(run(
            &mux,
            json!({"cmd":"move-bookmark","bookmark":top,"parent":other_top,"index":0})
        )),
        "invalid_params"
    );
    run(&mux, json!({"cmd":"delete-bookmark","bookmark":other_top})).unwrap();
    let many = (0..100_000)
        .map(|_| json!({"kind":"url","title":"","url":"https://many.example"}))
        .collect::<Vec<_>>();
    assert_eq!(error_code(import(Value::Array(many))), "invalid_params");
    assert_eq!(listed(&mux, "default")["bookmarks"].as_array().unwrap().len(), 64);
}

#[test]
fn deleting_a_browser_profile_deletes_its_bookmarks() {
    let mux = bookmarks_mux();
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Work"}))
        .unwrap();
    create(
        &mux,
        json!({"browser_profile_id":WORK,"parent":"other","kind":"folder","title":"F","bookmark":FOLDER}),
    );
    create(
        &mux,
        json!({"browser_profile_id":WORK,"parent":FOLDER,"kind":"url","title":"P",
               "url":"https://example.com","bookmark":PAGE}),
    );
    create(
        &mux,
        json!({"browser_profile_id":"default","parent":"bar","kind":"url","title":"Keep",
               "url":"https://keep.example"}),
    );
    let events = mux.subscribe();
    run(&mux, json!({"cmd":"delete-browser-profile","browser_profile":WORK})).unwrap();
    let changed = bookmark_events(&events);
    assert_eq!(changed.len(), 1);
    assert_eq!(changed[0]["browser_profile_id"], WORK);
    assert_eq!(changed[0]["bookmarks_revision"], 4);
    assert_eq!(
        error_code(run(&mux, json!({"cmd":"delete-bookmark","bookmark":PAGE}))),
        "not_found"
    );
    assert_eq!(listed(&mux, "default")["bookmarks"].as_array().unwrap().len(), 1);
    // A new profile with the same id starts empty.
    run(&mux, json!({"cmd":"create-browser-profile","browser_profile":WORK,"name":"Work"}))
        .unwrap();
    assert_eq!(listed(&mux, WORK)["bookmarks"], json!([]));
}

/// The result without `replayed`, to compare an original and its replay.
fn without_replayed(result: &Value) -> Value {
    let mut result = result.clone();
    result.as_object_mut().unwrap().remove("replayed");
    result
}

#[test]
fn bookmark_operations_replay_by_origin_and_mutation_id() {
    let mux = bookmarks_mux();
    let events = mux.subscribe();
    let keyed = |request: Value, mutation: &str| {
        let mut request = request;
        request["origin"] = json!("bookmarks-test");
        request["mutation_id"] = json!(mutation);
        request
    };
    let create = keyed(
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar",
               "kind":"folder","title":"Folder"}),
        "m-create",
    );
    let first = run(&mux, create.clone()).unwrap();
    assert_eq!(first["changed"], true);
    assert_eq!(first["replayed"], false);
    // A lost-response retry returns the original result, generated id
    // included, and writes nothing.
    let replayed = run(&mux, create).unwrap();
    assert_eq!(replayed["replayed"], true);
    assert_eq!(without_replayed(&replayed), without_replayed(&first));
    let folder = first["bookmark"]["id"].as_str().unwrap().to_string();
    assert_eq!(ids(&listed(&mux, "default")), vec![folder.clone()]);
    assert_eq!(listed(&mux, "default")["bookmarks_revision"], 1);
    assert_eq!(bookmark_events(&events).len(), 1);
    // The same key with another payload is refused.
    assert_eq!(
        error_code(run(
            &mux,
            keyed(
                json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar",
                       "kind":"folder","title":"Other"}),
                "m-create",
            )
        )),
        "invalid_params"
    );
    let page = run(
        &mux,
        json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":"bar",
               "kind":"url","title":"Page","url":"https://page.example"}),
    )
    .unwrap()["bookmark"]["id"]
        .as_str()
        .unwrap()
        .to_string();
    for (request, mutation) in [
        (json!({"cmd":"update-bookmark","bookmark":page,"title":"Renamed"}), "m-update"),
        (json!({"cmd":"move-bookmark","bookmark":page,"parent":folder,"index":0}), "m-move"),
        (
            json!({"cmd":"import-bookmarks","browser_profile_id":"default","parent":"other",
                   "nodes":[{"kind":"url","title":"I","url":"https://i.example"}]}),
            "m-import",
        ),
        (json!({"cmd":"delete-bookmark","bookmark":folder}), "m-delete"),
    ] {
        let request = keyed(request, mutation);
        let original = run(&mux, request.clone()).unwrap();
        assert_eq!(original["replayed"], false, "{request}");
        let revision = listed(&mux, "default")["bookmarks_revision"].clone();
        bookmark_events(&events);
        let again = run(&mux, request.clone()).unwrap();
        assert_eq!(again["replayed"], true, "{request}");
        assert_eq!(without_replayed(&again), without_replayed(&original), "{request}");
        assert_eq!(listed(&mux, "default")["bookmarks_revision"], revision, "{request}");
        assert!(bookmark_events(&events).is_empty(), "{request}");
    }
    // A key needs both halves.
    assert_eq!(
        error_code(run(
            &mux,
            json!({"cmd":"delete-bookmark","bookmark":page,"mutation_id":"m-alone"})
        )),
        "invalid_params"
    );
}

/// A small seeded generator, so a failure reproduces from its seed.
struct Seeded(u64);

impl Seeded {
    fn below(&mut self, bound: usize) -> usize {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 % bound.max(1) as u64) as usize
    }
}

/// The tree invariants over a `list-bookmarks` listing: dense sibling
/// positions in order, every parent a root or an earlier folder, depth at
/// most 64, at most 100,000 nodes.
fn check_tree_invariants(listing: &Value, seed: u64, step: usize) {
    let nodes = listing["bookmarks"].as_array().unwrap();
    assert!(nodes.len() <= 100_000);
    let mut depth = HashMap::<String, usize>::new();
    let mut next_index = HashMap::<String, u64>::new();
    for node in nodes {
        let parent = node["parent"].as_str().unwrap().to_string();
        let parent_depth = match parent.as_str() {
            "bar" | "other" => 0,
            folder => *depth
                .get(folder)
                .unwrap_or_else(|| panic!("seed {seed} step {step}: orphan {node}")),
        };
        if parent != "bar" && parent != "other" {
            let folder = nodes.iter().find(|candidate| candidate["id"] == parent.as_str()).unwrap();
            assert_eq!(folder["kind"], "folder", "seed {seed} step {step}");
        }
        assert!(parent_depth < 64, "seed {seed} step {step}: too deep");
        let expected = next_index.entry(parent).or_insert(0);
        assert_eq!(node["index"].as_u64(), Some(*expected), "seed {seed} step {step}: {node}");
        *expected += 1;
        depth.insert(node["id"].as_str().unwrap().to_string(), parent_depth + 1);
    }
}

#[test]
fn random_bookmark_ops_keep_the_tree_invariants_and_replays_change_nothing() {
    for seed in [0x9e37_79b9_7f4a_7c15_u64, 0x2545_f491_4f6c_dd1d, 0xdead_beef_cafe_f00d] {
        let mux = bookmarks_mux();
        let mut random = Seeded(seed);
        for step in 0..150 {
            let before = listed(&mux, "default");
            let nodes = before["bookmarks"].as_array().unwrap().clone();
            let any_node = |random: &mut Seeded| {
                nodes.get(random.below(nodes.len())).map(|node| node["id"].clone())
            };
            let folders = nodes
                .iter()
                .filter(|node| node["kind"] == "folder")
                .map(|node| node["id"].clone())
                .collect::<Vec<_>>();
            let parent = |random: &mut Seeded| match random.below(folders.len() + 2) {
                0 => json!("bar"),
                1 => json!("other"),
                n => folders[n - 2].clone(),
            };
            let index = json!(random.below(6));
            let mut request = match random.below(6) {
                0 => json!({"cmd":"create-bookmark","browser_profile_id":"default",
                            "parent":parent(&mut random),"index":index,"kind":"folder",
                            "title":format!("f{step}")}),
                1 => json!({"cmd":"create-bookmark","browser_profile_id":"default",
                            "parent":parent(&mut random),"kind":"url","title":format!("u{step}"),
                            "url":format!("https://example.com/{step}")}),
                2 => match any_node(&mut random) {
                    Some(id) => json!({"cmd":"move-bookmark","bookmark":id,
                                       "parent":parent(&mut random),"index":index}),
                    None => continue,
                },
                3 => match any_node(&mut random) {
                    Some(id) => json!({"cmd":"delete-bookmark","bookmark":id}),
                    None => continue,
                },
                4 => match any_node(&mut random) {
                    Some(id) => json!({"cmd":"update-bookmark","bookmark":id,
                                       "title":format!("t{step}")}),
                    None => continue,
                },
                _ => json!({"cmd":"import-bookmarks","browser_profile_id":"default",
                            "parent":parent(&mut random),"index":index,
                            "nodes":[{"kind":"folder","title":"i","children":[
                                {"kind":"url","title":"a","url":"https://a.example"},
                                {"kind":"folder","title":"b"}]}]}),
            };
            let keyed = random.below(3) == 0;
            if keyed {
                request["origin"] = json!("property");
                request["mutation_id"] = json!(format!("{seed}-{step}"));
            }
            match run(&mux, request.clone()) {
                Ok(result) => {
                    let after = listed(&mux, "default");
                    check_tree_invariants(&after, seed, step);
                    if keyed {
                        let replayed = run(&mux, request.clone()).unwrap();
                        assert_eq!(replayed["replayed"], true, "seed {seed} step {step}");
                        assert_eq!(without_replayed(&replayed), without_replayed(&result));
                        assert_eq!(listed(&mux, "default"), after, "seed {seed} step {step}");
                    }
                }
                Err(error) => {
                    // A refused op is a cycle or a depth limit; it writes nothing.
                    assert_eq!(
                        response_error_code(&error).as_deref(),
                        Some("invalid_params"),
                        "seed {seed} step {step}: {request} {error}"
                    );
                    assert_eq!(listed(&mux, "default"), before, "seed {seed} step {step}");
                }
            }
        }
    }
}
