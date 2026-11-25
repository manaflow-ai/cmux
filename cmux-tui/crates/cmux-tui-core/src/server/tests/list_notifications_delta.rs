//! `list-notifications` with `since` (`notification-ledger-delta-v1`): a client that holds a
//! reply reads only what changed, so one notification costs it one row, not the whole ledger.

use super::*;
use crate::NotificationLevel;

fn list(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    limit: Option<usize>,
    since: Option<&Value>,
) -> Value {
    let since = since.map(|version| version.as_str().unwrap().to_string());
    handle_command(mux, client, Command::ListNotifications { limit, since, stats: false }, writer)
        .unwrap()
}

fn post(mux: &Arc<Mux>, title: &str) {
    mux.post_notification(title.into(), String::new(), NotificationLevel::Info, None).unwrap();
}

fn titles(reply: &Value) -> Vec<&str> {
    reply["notifications"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["title"].as_str().unwrap())
        .collect()
}

#[test]
fn one_post_answers_one_row_and_eviction_answers_a_removal() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    for index in 0..256 {
        post(&mux, &format!("notice-{index}"));
    }
    let whole = list(&mux, client, &writer, None, None);
    assert_eq!(titles(&whole).len(), 256);
    assert!(whole.get("delta").is_none());
    let oldest = whole["notifications"][255]["id"].clone();

    // The ledger is full: one more post evicts the oldest row.
    post(&mux, "notice-256");
    let delta = list(&mux, client, &writer, None, Some(&whole["version"]));
    assert_eq!(delta["delta"], true, "{delta}");
    assert_eq!(titles(&delta), ["notice-256"]);
    assert_eq!(delta["removed"], json!([oldest]));

    // Nothing changed: an empty delta, the same version.
    let again = list(&mux, client, &writer, None, Some(&delta["version"]));
    assert_eq!(again["version"], delta["version"]);
    assert_eq!(titles(&again), Vec::<&str>::new());
    assert_eq!(again["removed"], json!([]));
}

#[test]
fn old_clients_and_limited_reads_keep_the_whole_answer() {
    let mux = test_mux();
    let writer = test_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    post(&mux, "first");
    post(&mux, "second");
    let whole = list(&mux, client, &writer, None, None);
    assert_eq!(titles(&whole), ["second", "first"]);
    post(&mux, "third");
    // A limit under the ledger's size answers as before: no version, no delta.
    let limited = list(&mux, client, &writer, Some(1), Some(&whole["version"]));
    assert_eq!(titles(&limited), ["third"]);
    assert!(limited.get("version").is_none() && limited.get("delta").is_none(), "{limited}");
    // A version this daemon never answered: the whole ledger.
    let unknown = list(&mux, client, &writer, None, Some(&json!("elsewhere.3")));
    assert_eq!(titles(&unknown), ["third", "second", "first"]);
    assert!(unknown.get("delta").is_none());
    assert!(advertised_capabilities(false).contains(&crate::NOTIFICATION_LEDGER_DELTA_CAPABILITY));
}
