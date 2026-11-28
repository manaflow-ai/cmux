//! `list-workspaces-limit-v1` (hq#8813): `limit: N` returns the first N
//! workspaces in sidebar order and `total`, so a phone draws its first screen
//! from a god session as fast as from a small one.

use super::super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

/// The workspace ids in sidebar order, as `workspace.list {order: "personal"}` lists them.
fn sidebar_ids(mux: &Arc<Mux>) -> Vec<String> {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"list",
                          "operation":"workspace.list",
                          "params":{"machine":"current","session":"current","order":"personal"}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["id"].as_str().unwrap().to_string())
        .collect()
}

fn ids(reply: &Value) -> Vec<String> {
    reply["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["resource_id"].as_str().unwrap().to_string())
        .collect()
}

fn five_workspaces(session: &str) -> Arc<Mux> {
    let mux = Mux::new_for_test(session, SurfaceOptions::default());
    for index in 0..5 {
        mux.create_empty_workspace(Some(format!("w{index}")), None, None).unwrap();
    }
    mux
}

#[test]
fn a_limit_lists_the_first_workspaces_in_sidebar_order_with_the_total() {
    let mux = five_workspaces("limit-first");
    let sidebar = sidebar_ids(&mux);
    assert_eq!(sidebar.len(), 5);
    let first = run(&mux, json!({"cmd": "list-workspaces", "limit": 2}));
    assert_eq!(first["total"], json!(5), "{first}");
    assert_eq!(ids(&first), sidebar[..2].to_vec());
    for field in ["registry_id", "generation", "workspace_revision", "pane_revision"] {
        assert!(!first[field].is_null(), "{field}: {first}");
    }
    // A row is the row the whole tree has.
    let whole = run(&mux, json!({"cmd": "list-workspaces"}));
    let row = whole["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["resource_id"] == json!(sidebar[0]))
        .unwrap();
    assert_eq!(&first["workspaces"][0], row);
    assert_eq!(run(&mux, json!({"cmd": "list-workspaces", "limit": 0}))["workspaces"], json!([]));
    mux.shutdown();
}

#[test]
fn a_part_of_the_tree_gives_no_revision_to_hold_and_a_whole_one_does() {
    let mux = five_workspaces("limit-known");
    let part = run(&mux, json!({"cmd": "list-workspaces", "known": {}, "limit": 2}));
    assert_eq!(part["workspaces"].as_array().unwrap().len(), 2);
    assert!(part.get("tree_revision").is_none(), "a part handed out a revision: {part}");

    let whole = run(&mux, json!({"cmd": "list-workspaces", "known": {}, "limit": 50}));
    assert_eq!(whole["workspaces"].as_array().unwrap().len(), 5);
    assert_eq!(whole["total"], json!(5));
    let revision = whole["tree_revision"].clone();
    assert!(revision.is_string(), "a whole list under the limit has a revision: {whole}");

    // The phone that holds the whole tree asks with its first-screen limit: unchanged.
    let known = json!({
        "registry_id": whole["registry_id"], "generation": whole["generation"],
        "workspace_revision": whole["workspace_revision"], "pane_revision": whole["pane_revision"],
        "terminal_revision": whole["terminal_revision"], "tree_revision": revision,
    });
    let again = run(&mux, json!({"cmd": "list-workspaces", "known": known, "limit": 2}));
    assert_eq!(again["unchanged"], json!(true), "{again}");
    mux.shutdown();
}

/// `list-workspaces-page-v1`: `after` and `next` walk the sidebar order page by page, each
/// row once, and the last page has no `next`.
#[test]
fn after_and_next_walk_every_workspace_once_in_sidebar_order() {
    let mux = five_workspaces("limit-after");
    let sidebar = sidebar_ids(&mux);
    let mut seen = Vec::new();
    let mut after = 0;
    let mut pages = 0;
    loop {
        let page = run(&mux, json!({"cmd": "list-workspaces", "limit": 2, "after": after}));
        assert_eq!(page["total"], json!(5), "{page}");
        seen.extend(ids(&page));
        pages += 1;
        match page.get("next").and_then(Value::as_u64) {
            Some(next) => after = next as usize,
            None => break,
        }
    }
    assert_eq!(pages, 3);
    assert_eq!(seen, sidebar);
    // A page past the end is empty, with the total and no `next`.
    let past = run(&mux, json!({"cmd": "list-workspaces", "limit": 2, "after": 9}));
    assert_eq!(past["workspaces"], json!([]), "{past}");
    assert!(past.get("next").is_none(), "{past}");
    // A later page is never a whole tree to hold.
    let later = run(&mux, json!({"cmd": "list-workspaces", "known": {}, "limit": 50, "after": 1}));
    assert!(later.get("tree_revision").is_none(), "{later}");
    // `after` without `limit` changes nothing: the whole tree, as before.
    let whole = run(&mux, json!({"cmd": "list-workspaces", "after": 3}));
    assert_eq!(whole["workspaces"].as_array().unwrap().len(), 5);
    assert!(whole.get("next").is_none() && whole.get("total").is_none(), "{whole}");
    mux.shutdown();
}

/// A `limit` page stops at `LIST_WORKSPACES_PAGE_BYTES` of rows, whatever `limit` asks, so the
/// phone's first window costs the same at any number of workspaces; `next` reads on.
#[test]
fn a_limit_page_stops_at_its_byte_budget_and_says_where_the_rest_starts() {
    let mux = Mux::new_for_test("limit-budget", SurfaceOptions::default());
    let count = 300;
    for index in 0..count {
        mux.create_empty_workspace(
            Some(format!("workspace {index} {}", "x".repeat(200))),
            None,
            None,
        )
        .unwrap();
    }
    let page = run(&mux, json!({"cmd": "list-workspaces", "limit": 10_000}));
    let rows = page["workspaces"].as_array().unwrap();
    let row_bytes: usize = rows.iter().map(|row| row.to_string().len() + 1).sum();
    assert!(rows.len() < count, "the page held all {count} rows ({row_bytes} bytes)");
    assert!(!rows.is_empty());
    assert!(row_bytes <= LIST_WORKSPACES_PAGE_BYTES, "{row_bytes} bytes of rows");
    assert_eq!(page["total"], json!(count));
    assert_eq!(page["next"], json!(rows.len()), "{}", page["next"]);
    // Walking `next` reads every workspace once, in sidebar order.
    let sidebar = sidebar_ids(&mux);
    let mut seen = ids(&page);
    let mut after = rows.len();
    while after < count {
        let next = run(&mux, json!({"cmd": "list-workspaces", "limit": 10_000, "after": after}));
        let got = ids(&next);
        assert!(!got.is_empty());
        after += got.len();
        seen.extend(got);
    }
    assert_eq!(seen, sidebar);
    mux.shutdown();
}

#[test]
fn paging_is_advertised() {
    let mux = Mux::new_for_test("page-capability", SurfaceOptions::default());
    let identify = run(&mux, json!({"cmd": "identify"}));
    let capabilities = identify["capabilities"].as_array().unwrap();
    for capability in [LIST_WORKSPACES_LIMIT_CAPABILITY, LIST_WORKSPACES_PAGE_CAPABILITY] {
        assert!(capabilities.iter().any(|value| value == capability), "{capability}: {identify}");
    }
    mux.shutdown();
}

/// The phone's first window costs the same at 10, 100 and 1,000 workspaces (the bench's rows:
/// one `/bin/cat` terminal per workspace), while the whole tree grows with them. Prints the
/// bytes and daemon time of each reply for the PR's before/after table.
#[test]
fn the_first_window_costs_the_same_at_every_scale() {
    let mux = Mux::new_for_test("first-window-scale", SurfaceOptions::default());
    let mut have = 0;
    let mut window_bytes = Vec::new();
    let mut whole_bytes = Vec::new();
    for scale in [10, 100, 1_000] {
        for index in have..scale {
            run(
                &mux,
                json!({"cmd": "run", "argv": ["/bin/cat"], "name": format!("open-path-{index}"),
                       "new_workspace": true}),
            );
        }
        have = scale;
        let timed = |request: Value| {
            let mut best = (usize::MAX, f64::MAX);
            for _ in 0..5 {
                let started = Instant::now();
                let reply = run(&mux, request.clone());
                let ms = started.elapsed().as_secs_f64() * 1000.0;
                best = (reply.to_string().len(), best.1.min(ms));
            }
            best
        };
        let (whole, whole_ms) = timed(json!({"cmd": "list-workspaces"}));
        let (window, window_ms) = timed(json!({"cmd": "list-workspaces", "limit": 40}));
        println!(
            "FIRST-WINDOW scale={scale} whole_bytes={whole} whole_ms={whole_ms:.2} \
             window_bytes={window} window_ms={window_ms:.2}"
        );
        whole_bytes.push(whole);
        window_bytes.push(window);
    }
    assert!(whole_bytes[2] > whole_bytes[1] * 5, "whole tree: {whole_bytes:?}");
    // Past the window only `total`'s digits (and a few longer ids) may grow it.
    assert!(
        window_bytes[2] <= window_bytes[1] + window_bytes[1] / 50,
        "first window: {window_bytes:?}"
    );
    mux.shutdown();
}

/// The full rows and the slim rows (`list-workspaces-slim-v1`) of the same page, as the phone
/// asks for them (`rows: "slim"` with `limit`).
fn slim_and_full(mux: &Arc<Mux>, request: Value) -> (Value, Value) {
    let full = run(mux, request.clone());
    let mut slim_request = request;
    slim_request.set("rows", json!("slim"));
    (run(mux, slim_request), full)
}

/// A slim page lists the same workspaces in the same order as the full page, each row with
/// what Home and the Workspaces list draw (title, color, unread, kind, the tabs' surfaces,
/// kinds, directories and branches) and none of the layouts and ids the whole tree carries.
#[test]
fn a_slim_page_lists_the_same_rows_with_only_what_home_draws() {
    let mux = Mux::new_for_test("limit-slim", SurfaceOptions::default());
    for index in 0..5 {
        run(
            &mux,
            json!({"cmd": "run", "argv": ["/bin/cat"], "name": format!("slim-{index}"),
                   "new_workspace": true}),
        );
    }
    let (slim, full) = slim_and_full(&mux, json!({"cmd": "list-workspaces", "limit": 3}));
    assert_eq!(ids(&slim), ids(&full));
    assert_eq!(slim["rows"], json!("slim"), "{slim}");
    assert!(full.get("rows").is_none(), "a full page says slim: {full}");
    for key in ["total", "next", "registry_id", "generation", "workspace_revision", "pane_revision"]
    {
        assert_eq!(slim[key], full[key], "{key}");
    }
    let (slim_rows, full_rows) =
        (slim["workspaces"].as_array().unwrap(), full["workspaces"].as_array().unwrap());
    for (slim_row, full_row) in slim_rows.iter().zip(full_rows) {
        for key in ["id", "resource_id", "key", "name", "kind", "unread_count", "active"] {
            assert_eq!(slim_row.get(key), full_row.get(key).filter(|value| !value.is_null()));
        }
        assert!(slim_row.get("screen_groups").is_none() && slim_row.get("short_id").is_none());
        let surfaces = |row: &Value| {
            let mut out = Vec::new();
            for screen in row["screens"].as_array().unwrap() {
                for pane in screen["panes"].as_array().unwrap() {
                    for tab in pane["tabs"].as_array().unwrap() {
                        out.push((tab["surface"].clone(), tab["kind"].clone(), tab["cwd"].clone()));
                    }
                }
            }
            out
        };
        assert!(!surfaces(full_row).is_empty());
        assert_eq!(surfaces(slim_row), surfaces(full_row));
        let screen = &slim_row["screens"][0];
        assert_eq!(screen["active_pane"], full_row["screens"][0]["active_pane"]);
        assert!(screen.get("layout").is_none() && screen.get("resource_id").is_none(), "{screen}");
        let tab = &screen["panes"][0]["tabs"][0];
        for gone in ["terminal_id", "tab_resource_id", "content_resource_id", "size", "short_id"] {
            assert!(tab.get(gone).is_none(), "{gone}: {tab}");
        }
        assert!(slim_row.to_string().len() * 2 < full_row.to_string().len(), "{slim_row}");
    }
    // Without `limit`, `rows` changes nothing: the whole tree, byte for byte.
    let whole = run(&mux, json!({"cmd": "list-workspaces"}));
    let asked = run(&mux, json!({"cmd": "list-workspaces", "rows": "slim"}));
    assert_eq!(asked["workspaces"], whole["workspaces"]);
    assert!(asked.get("rows").is_none());
    mux.shutdown();
}

/// A slim page is never a tree to hold, even when it holds every workspace: it carries no
/// `tree_revision`, so the phone's whole-tree refresh after it reads the whole tree.
#[test]
fn a_slim_page_gives_no_revision_to_hold() {
    let mux = five_workspaces("limit-slim-known");
    let page =
        run(&mux, json!({"cmd": "list-workspaces", "known": {}, "limit": 50, "rows": "slim"}));
    assert_eq!(page["workspaces"].as_array().unwrap().len(), 5);
    assert!(page.get("tree_revision").is_none(), "a slim page handed out a revision: {page}");
    let identify = run(&mux, json!({"cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == LIST_WORKSPACES_SLIM_CAPABILITY),
        "{identify}"
    );
    mux.shutdown();
}

/// How many workspaces the phone's first window (`limit` 40, 64 KiB of rows) holds with full
/// and with slim rows at 50, 200 and 1,000 workspaces (one `/bin/cat` terminal each), and its
/// bytes and daemon time. Slim rows fit the whole window at every scale; prints the numbers
/// for the PR's table.
#[test]
fn the_slim_first_window_holds_every_row_it_asks_for_at_every_scale() {
    let mux = Mux::new_for_test("slim-window-scale", SurfaceOptions::default());
    let mut have = 0;
    let mut slim_bytes = Vec::new();
    for scale in [50, 200, 1_000] {
        for index in have..scale {
            run(
                &mux,
                json!({"cmd": "run", "argv": ["/bin/cat"], "name": format!("open-path-{index}"),
                       "cwd": "/tmp", "new_workspace": true}),
            );
        }
        have = scale;
        let timed = |request: Value| {
            let mut best = (0usize, 0usize, f64::MAX);
            for _ in 0..5 {
                let started = Instant::now();
                let reply = run(&mux, request.clone());
                let ms = started.elapsed().as_secs_f64() * 1000.0;
                let rows = reply["workspaces"].as_array().map_or(0, Vec::len);
                best = (rows, reply.to_string().len(), best.2.min(ms));
            }
            best
        };
        let (full_rows, full, full_ms) = timed(json!({"cmd": "list-workspaces", "limit": 40}));
        let (slim_rows, slim, slim_ms) =
            timed(json!({"cmd": "list-workspaces", "limit": 40, "rows": "slim"}));
        // What 64 KiB holds at most, with no `limit` of rows.
        let (full_cap, _, _) = timed(json!({"cmd": "list-workspaces", "limit": 100_000}));
        let (slim_cap, _, _) =
            timed(json!({"cmd": "list-workspaces", "limit": 100_000, "rows": "slim"}));
        println!(
            "SLIM-WINDOW scale={scale} full_rows={full_rows} full_bytes={full} \
             full_ms={full_ms:.2} slim_rows={slim_rows} slim_bytes={slim} slim_ms={slim_ms:.2} \
             full_rows_in_64k={full_cap} slim_rows_in_64k={slim_cap}"
        );
        assert_eq!(slim_rows, 40, "scale {scale}");
        assert!(slim < full, "scale {scale}: slim {slim} full {full}");
        assert!(slim_cap >= full_cap, "scale {scale}: {slim_cap} < {full_cap}");
        slim_bytes.push(slim);
    }
    // Past the window only `total`'s digits (and a few longer ids) may grow it.
    assert!(slim_bytes[2] <= slim_bytes[1] + slim_bytes[1] / 50, "slim window: {slim_bytes:?}");
    mux.shutdown();
}
