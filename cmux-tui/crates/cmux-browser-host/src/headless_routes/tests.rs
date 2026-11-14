use super::*;

fn dialog(target: &str, id: &str) -> DriverEvent {
    DriverEvent {
        name: "dialog.opened".into(),
        payload: json!({"targetId": target, "dialogId": id}),
    }
}

#[test]
fn a_handler_wins_then_the_creator_then_the_caller() {
    let all = |_| true;
    let mut routes = Routes::default();
    routes.created(1, "T");
    routes.handle_events(2, "T", vec!["dialog".into()]);
    assert_eq!(routes.route(&dialog("T", "d1"), &all), Route::Session(2));
    assert_eq!(routes.dialog_owner("d1"), Some(2));
    routes.handle_events(1, "T", vec!["dialog".into()]);
    assert_eq!(routes.route(&dialog("T", "d2"), &all), Route::Session(1), "creator first");
    routes.handle_events(1, "T", vec![]);
    routes.handle_events(2, "T", vec![]);
    assert_eq!(routes.route(&dialog("T", "d3"), &all), Route::Session(1), "the creator");
    routes.kept(1, "T");
    assert_eq!(routes.route(&dialog("T", "d4"), &all), Route::Unrouted("dialog"));
    assert_eq!(routes.log_session("T"), Some(1), "a kept tab still logs to its opener");
    routes.call_started(3, "T");
    assert_eq!(routes.route(&dialog("T", "d5"), &all), Route::Session(3), "the caller");
    routes.call_ended(3, "T");
    assert_eq!(routes.route(&dialog("T", "d6"), &|s| s != 3), Route::Unrouted("dialog"));
}

#[test]
fn entries_go_with_their_tab_session_and_log_bound() {
    let all = |_| true;
    let mut routes = Routes::default();
    routes.created(1, "T");
    routes.handle_events(2, "T", vec!["dialog".into()]);
    routes.route(&dialog("T", "d1"), &all);
    routes.session_ended(2);
    assert!(routes.dialogs.is_empty() && routes.handlers.is_empty());
    routes
        .route(&DriverEvent { name: "tab.closed".into(), payload: json!({"targetId": "T"}) }, &all);
    assert!(routes.creator.is_empty() && routes.opened_by.is_empty());
    for i in 0..LOG_KEPT + 5 {
        routes.log_unrouted(json!(i));
    }
    assert_eq!(routes.unrouted_log().len(), LOG_KEPT);
}
