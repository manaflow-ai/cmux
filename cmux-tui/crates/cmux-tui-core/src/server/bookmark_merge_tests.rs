//! Wire tests for `merge-bookmarks` (`bookmarks-merge-v1`): the first sync
//! of a Chromium bookmark store keeps the bookmarks only Chromium has, and a
//! bookmark in both lists is not duplicated (plans/cmux-next/bookmarks.md
//! section 4, cx-d0d.92).

use super::super::*;

const SHARED: &str = "bm_00000000000000000000000000000011";
const WORK: &str = "bm_00000000000000000000000000000012";
const IN_WORK: &str = "bm_00000000000000000000000000000013";
const STORE: &str = "chromium-store:Profile-test";

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

fn create(mux: &Arc<Mux>, parent: &str, kind: &str, title: &str, url: Option<&str>, id: &str) {
    let mut request = json!({"cmd":"create-bookmark","browser_profile_id":"default","parent":parent,
                             "kind":kind,"title":title,"bookmark":id});
    if let Some(url) = url {
        request["url"] = json!(url);
    }
    run(mux, request).unwrap();
}

/// (parent, kind, title, url) of every node, pre-order.
fn tree(mux: &Arc<Mux>) -> Vec<(String, String, String, Option<String>)> {
    let listing = run(mux, json!({"cmd":"list-bookmarks","browser_profile_id":"default"})).unwrap();
    listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|node| {
            (
                node["parent"].as_str().unwrap().to_string(),
                node["kind"].as_str().unwrap().to_string(),
                node["title"].as_str().unwrap().to_string(),
                node["url"].as_str().map(str::to_string),
            )
        })
        .collect()
}

fn node(listing: &Value, title: &str) -> Value {
    listing["bookmarks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| node["title"] == title)
        .cloned()
        .unwrap_or(Value::Null)
}

fn merge(mux: &Arc<Mux>, key: &str, file: &Value) -> anyhow::Result<Value> {
    run(
        mux,
        json!({"cmd":"merge-bookmarks","browser_profile_id":"default","merge_key":key,
               "chromium_bookmarks":file.to_string()}),
    )
}

/// A Chromium `Bookmarks` file.
fn chromium_file(bar: Value, other: Value) -> Value {
    json!({"checksum":"0","version":1,"roots":{
        "bookmark_bar":{"type":"folder","name":"Bookmarks bar","guid":"0bc5d13f-2cba-5d74-951f-3f233fe6c908","children":bar},
        "other":{"type":"folder","name":"Other bookmarks","guid":"82b081ec-3dd3-529c-8475-ab6c344590dd","children":other},
        "synced":{"type":"folder","name":"Mobile bookmarks","children":[
            {"type":"url","name":"Phone only","url":"https://example.com/phone","guid":"6f1d1d7a-0000-4000-8000-000000000009"}]}}})
}

fn url(name: &str, href: &str, guid: &str) -> Value {
    json!({"type":"url","name":name,"url":href,"guid":guid,"date_added":"13370000000000000"})
}

#[test]
fn merge_keeps_chromium_only_bookmarks_and_never_duplicates() {
    let mux = bookmarks_mux();
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "bookmarks-merge-v1")
    );
    // cmux's tree: a bookmark on the bar, and a folder with one bookmark.
    create(&mux, "bar", "url", "Shared", Some("https://example.com"), SHARED);
    create(&mux, "bar", "folder", "Work", None, WORK);
    create(&mux, WORK, "url", "Wiki", Some("https://example.com/wiki"), IN_WORK);
    let events = mux.subscribe();

    // Chromium's store: the same bookmark under another guid (and a trailing
    // slash), a bookmark only Chromium has, the same folder with the same
    // bookmark and one more, and one in Other bookmarks.
    let file = chromium_file(
        json!([
            url("Shared in Chromium", "https://example.com/", "7a0c0c37-1111-4111-8111-000000000001"),
            url("Only Chromium", "https://example.com/only", "7a0c0c37-1111-4111-8111-000000000002"),
            {"type":"folder","name":"Work","guid":"7a0c0c37-1111-4111-8111-000000000003","children":[
                url("Wiki", "https://example.com/wiki", "7a0c0c37-1111-4111-8111-000000000004"),
                url("Tracker", "https://example.com/tracker", "7a0c0c37-1111-4111-8111-000000000005")]},
            {"type":"folder","name":"Reading","guid":"7a0c0c37-1111-4111-8111-000000000006","children":[
                url("Paper", "https://example.com/paper", "7a0c0c37-1111-4111-8111-000000000007")]}
        ]),
        json!([url("Later", "https://example.com/later", "7a0c0c37-1111-4111-8111-000000000008")]),
    );
    let result = merge(&mux, STORE, &file).unwrap();
    assert_eq!(result["merged"], true);
    assert_eq!(result["created"], 5, "{result}");
    assert_eq!(result["skipped"], 3, "{result}");
    assert_eq!(result["replayed"], false);
    assert_eq!(
        tree(&mux),
        vec![
            ("bar".into(), "url".into(), "Shared".into(), Some("https://example.com".into())),
            ("bar".into(), "folder".into(), "Work".into(), None),
            (WORK.into(), "url".into(), "Wiki".into(), Some("https://example.com/wiki".into())),
            (
                WORK.into(),
                "url".into(),
                "Tracker".into(),
                Some("https://example.com/tracker".into())
            ),
            (
                "bar".into(),
                "url".into(),
                "Only Chromium".into(),
                Some("https://example.com/only".into())
            ),
            ("bar".into(), "folder".into(), "Reading".into(), None),
            (
                "bm_7a0c0c37111141118111000000000006".into(),
                "url".into(),
                "Paper".into(),
                Some("https://example.com/paper".into())
            ),
            (
                "other".into(),
                "url".into(),
                "Later".into(),
                Some("https://example.com/later".into())
            ),
        ]
    );
    // A merged node keeps Chromium's guid as its id, so later bridge
    // events name it, and Chromium's date_added.
    let listing =
        run(&mux, json!({"cmd":"list-bookmarks","browser_profile_id":"default"})).unwrap();
    let only = node(&listing, "Only Chromium");
    assert_eq!(only["id"], "bm_7a0c0c37111141118111000000000002");
    assert_eq!(only["created_ms"], 13_370_000_000_000_000_u64 / 1000 - 11_644_473_600_000);
    let changed = events
        .try_iter()
        .map(|event| subscribed_event_json(&event))
        .filter(|event| event["event"] == "bookmarks-changed")
        .count();
    assert_eq!(changed, 1);

    // The key is recorded: a later merge of the store changes nothing, so a
    // bookmark deleted in cmux stays deleted.
    run(&mux, json!({"cmd":"delete-bookmark","bookmark":"bm_7a0c0c37111141118111000000000002"}))
        .unwrap();
    let before = tree(&mux);
    let again = merge(&mux, STORE, &file).unwrap();
    assert_eq!(again["merged"], false);
    assert_eq!(again["created"], 0);
    assert_eq!(tree(&mux), before);
}

#[test]
fn a_refused_merge_writes_and_records_nothing() {
    let mux = bookmarks_mux();
    let bad = run(
        &mux,
        json!({"cmd":"merge-bookmarks","browser_profile_id":"default","merge_key":STORE,
               "chromium_bookmarks":"{not json"}),
    );
    let error = bad.expect_err("malformed JSON is refused");
    assert_eq!(response_error_code(&error).as_deref(), Some("invalid_params"));
    let no_roots = merge(&mux, STORE, &json!({"version":1}));
    assert!(no_roots.is_err());
    assert!(tree(&mux).is_empty());
    // Nothing was recorded: the same key merges once the file is good.
    let file = chromium_file(
        json!([url(
            "Only Chromium",
            "https://example.com/only",
            "7a0c0c37-1111-4111-8111-000000000002"
        )]),
        json!([]),
    );
    assert_eq!(merge(&mux, STORE, &file).unwrap()["merged"], true);
    assert_eq!(tree(&mux).len(), 1);
}

#[test]
fn a_long_chromium_title_is_kept_cut_to_the_limit() {
    let mux = bookmarks_mux();
    let long = "é".repeat(3000);
    let file = chromium_file(
        json!([url(&long, "https://example.com/long", "7a0c0c37-1111-4111-8111-00000000000a")]),
        json!([]),
    );
    assert_eq!(merge(&mux, STORE, &file).unwrap()["created"], 1);
    let nodes = tree(&mux);
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0].2.len(), 4096);
    assert!(long.starts_with(&nodes[0].2));
}

fn bookmarks_mux() -> Arc<Mux> {
    Mux::new_for_test("bookmark-merge", crate::SurfaceOptions::default())
}
