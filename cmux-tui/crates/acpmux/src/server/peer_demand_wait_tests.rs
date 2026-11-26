//! Listing never dials (`peer_demand_wait.rs`): with 130 saved machines nobody used since this
//! daemon started, a list's read of every row is answered from the last-known rows, and only
//! opening a chat dials, its own peer alone. Every dial is recorded and fails at once
//! (`peer::test_dial`), so no socket or ssh is opened.

use super::*;
use crate::peer::test_dial;

#[test]
fn row_false_info_is_not_answered_from_a_cached_row() {
    assert!(lists(method::MUX_INFO, &json!({"row": true})));
    assert!(lists(method::MUX_INFO, &json!({"waitLogs": false})));
    assert!(!lists(method::MUX_INFO, &json!({"row": false})));
}

#[tokio::test]
async fn a_list_of_a_hundred_and_thirty_idle_peers_rows_dials_none_and_an_open_dials_one() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-list-no-dial");
    test_dial::refuse_all();
    let hub = Hub::started_lazily_for_test(dir.path(), 130).await;
    // What a list asks of each row it shows: the phone's list (`waitLogs: false`), a list row
    // (`row: true`), a plain read.
    for i in 0..130 {
        let id = format!("m{i}-chat");
        let reads = [
            json!({"sessionId": id, "waitLogs": false}),
            json!({"sessionId": id, "row": true}),
            json!({"sessionId": id}),
        ];
        for params in reads {
            let Some(reply) = use_peer(&hub, method::MUX_INFO, &params).await else {
                panic!("{params} went on to an idle peer");
            };
            assert_eq!(reply["peer"], format!("m{i}"), "{reply}");
            assert_eq!(reply["sessionId"], id, "{reply}");
            assert_eq!(reply["stale"], true, "{reply}");
            assert_eq!(reply["link"], "idle", "{reply}");
        }
    }
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert_eq!(test_dial::attempts().len(), 0, "a listing dialed");
    let parked = |name: &str| hub.peer_by_name(name).is_some_and(|p| p.idle_parked());
    assert!((0..130).all(|i| parked(&format!("m{i}"))), "every machine still waits to be used");

    // Opening one chat dials its peer alone.
    let open = tokio::spawn({
        let hub = hub.clone();
        async move { use_peer(&hub, method::MUX_ATTACH, &json!({"sessionId": "m5-chat"})).await }
    });
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert!(!test_dial::attempts().is_empty(), "opening the chat dials its peer");
    let dialed: Vec<String> =
        (0..130).map(|i| format!("m{i}")).filter(|name| !parked(name)).collect();
    assert_eq!(dialed, ["m5"]);
    open.abort();
    test_dial::clear();
    hub.begin_shutdown();
}
