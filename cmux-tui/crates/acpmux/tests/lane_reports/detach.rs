//! A lane stops reporting to the session that started it when the person takes it over, when
//! its tag `lane.reportsTo` is removed or it is detached (`acpmux session detach`), and one
//! started with no parent (`acpmux new --no-parent`) never reports. One started with
//! `--report-to` keeps reporting after a person's prompt.
//!
//! Leo, 2026-11-01: "why am i seeing their responses in you? that shouldn't happen."
use super::*;

/// The cmux app's connection: its prompts are the person's (`server/requests.rs` `person_asks`).
fn app(hub: &Arc<Hub>) -> Client {
    Client::with_origin(hub, Origin::LocalApp)
}

#[tokio::test]
async fn lane_detach_a_person_prompt_to_the_lane_stops_its_reports() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-p", json!({})).await;
    let mut from_coord = Client::as_session(&hub, &coord).await;
    from_coord.prompt(&lane, "the parent's task").await;
    person.exactly(&coord, 1).await;

    // The person talks to the lane in the app: it is theirs now.
    app(&hub).prompt(&lane, "the person's own question").await;
    person.exactly(&coord, 1).await;
    assert_eq!(tag(&hub, &lane), None);
    // Nor does a later turn the parent gives it report.
    from_coord.prompt(&lane, "another task").await;
    person.exactly(&coord, 1).await;
}

#[tokio::test]
async fn lane_detach_removing_the_tag_stops_its_reports() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-t", json!({})).await;
    person.ok("_acpmux/tag", json!({"sessionId": lane, "remove": [TAG]})).await;
    // Setting it back makes no link: the tag is shown, never trusted.
    person.ok("_acpmux/tag", json!({"sessionId": lane, "set": {TAG: coord}})).await;
    Client::as_session(&hub, &coord).await.prompt(&lane, "after the tag went").await;
    person.exactly(&coord, 0).await;
}

#[tokio::test]
async fn lane_detach_session_detach_stops_its_reports_and_removes_the_tag() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-d", json!({})).await;
    let r = person.ok("_acpmux/detach_parent", json!({"sessionId": "lane-d"})).await;
    assert_eq!(r, json!({"sessionId": lane, "detached": true}));
    assert_eq!(tag(&hub, &lane), None);
    Client::as_session(&hub, &coord).await.prompt(&lane, "after detach").await;
    person.exactly(&coord, 0).await;
    // Once more: it has no parent to detach from.
    let r = person.ok("_acpmux/detach_parent", json!({"sessionId": lane})).await;
    assert_eq!(r["detached"], false, "{r}");
}

#[tokio::test]
async fn lane_detach_a_session_started_with_no_parent_never_reports() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    // `acpmux new --no-parent` from inside coord (`client.rs` `request_parentless`).
    let free =
        Client::as_session(&hub, &coord).await.new_session("free", json!({"parent": null})).await;
    assert_eq!(tag(&hub, &free), None);
    Client::as_session(&hub, &coord).await.prompt(&free, "no parent here").await;
    person.exactly(&coord, 0).await;
}

#[tokio::test]
async fn lane_detach_a_report_to_lane_keeps_reporting_after_a_person_prompt() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    // `acpmux new --report-to coord` from inside coord.
    let helper = Client::as_session(&hub, &coord)
        .await
        .new_session("helper", json!({"reportTo": coord}))
        .await;
    app(&hub).prompt(&helper, "the person checks in").await;
    let got = person.exactly(&coord, 1).await;
    assert!(text(&got[0]).starts_with("[helper] "), "{}", got[0]);
    assert_eq!(tag(&hub, &helper).as_deref(), Some(coord.as_str()));
}
