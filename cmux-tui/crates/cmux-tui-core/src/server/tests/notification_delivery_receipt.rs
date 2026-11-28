//! A poster can read whether its notice's desktop banner was shown: the app
//! records the outcome with `record-notification-delivery` and the
//! `list-notifications` row carries it as `delivery`.

use super::*;

type Conn = (u64, MessageWriter, Arc<BoundedOutbound>, Arc<ConnectionSurfaceScheduler>);

fn app(mux: &Arc<Mux>) -> Conn {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    (client, writer, outbound, scheduler)
}

fn line(mux: &Arc<Mux>, (client, writer, outbound, scheduler): &Conn, request: Value) -> Value {
    assert!(handle_connection_message(mux, *client, &request.to_string(), writer, scheduler));
    pop_json(outbound)
}

fn delivery_of(mux: &Arc<Mux>, conn: &Conn, title: &str) -> Value {
    let listed = line(mux, conn, json!({"id": "l", "cmd": "list-notifications"}));
    assert_eq!(listed["ok"], true, "{listed}");
    let rows = listed["data"]["notifications"].as_array().unwrap();
    let row = rows.iter().find(|row| row["title"] == title).unwrap_or_else(|| panic!("{listed}"));
    row["delivery"].clone()
}

#[test]
fn the_app_records_a_banner_outcome_and_list_notifications_returns_it() {
    let mux = test_mux();
    let app = app(&mux);
    let posted =
        line(&mux, &app, json!({"id": "n", "cmd": "notify", "title": "build done", "body": ""}));
    assert_eq!(posted["ok"], true, "{posted}");
    let notification = posted["data"]["notification"].as_u64().unwrap();
    assert_eq!(delivery_of(&mux, &app, "build done"), Value::Null, "no report yet");

    let recorded = line(
        &mux,
        &app,
        json!({"id": "r", "cmd": "record-notification-delivery", "notification": notification,
               "desktop": "suppressed", "reason": "viewed"}),
    );
    assert_eq!(recorded["ok"], true, "{recorded}");
    let delivery = delivery_of(&mux, &app, "build done");
    assert_eq!(delivery["desktop"], "suppressed", "{delivery}");
    assert_eq!(delivery["reason"], "viewed", "{delivery}");
    assert!(delivery["at_ms"].as_u64().unwrap() > 0, "{delivery}");

    let shown = line(
        &mux,
        &app,
        json!({"id": "s", "cmd": "record-notification-delivery", "notification": notification,
               "desktop": "shown"}),
    );
    assert_eq!(shown["ok"], true, "{shown}");
    let delivery = delivery_of(&mux, &app, "build done");
    assert_eq!(delivery["desktop"], "shown", "{delivery}");
    assert_eq!(delivery["reason"], Value::Null, "{delivery}");

    for bad in [
        json!({"id": "b1", "cmd": "record-notification-delivery", "notification": notification,
               "desktop": "maybe"}),
        json!({"id": "b2", "cmd": "record-notification-delivery", "notification": notification,
               "desktop": "suppressed", "reason": "made-up"}),
        json!({"id": "b3", "cmd": "record-notification-delivery", "notification": notification + 999,
               "desktop": "shown"}),
    ] {
        let reply = line(&mux, &app, bad.clone());
        assert_eq!(reply["ok"], false, "{bad} -> {reply}");
    }
    mux.shutdown();
}
