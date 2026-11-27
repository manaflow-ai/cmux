//! Hello service routing and feature negotiation (rd change C1).

use cmux_rd_core::service::{
    MAX_CAP_LEN, MAX_CAPS, Negotiated, SERVICE_DESKTOP, SERVICE_REMOTE_BROWSER, ServiceRefusal,
    caps, negotiate,
};

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| (*x).to_owned()).collect()
}

#[test]
fn the_host_routes_by_service_and_refuses_an_unknown_one() {
    let desktop_only = [SERVICE_DESKTOP];
    let got = negotiate(SERVICE_DESKTOP, &[], &desktop_only, &[]).expect("desktop");
    assert_eq!(got, Negotiated { service: SERVICE_DESKTOP.into(), caps: vec![] });
    assert_eq!(
        negotiate(SERVICE_REMOTE_BROWSER, &[], &desktop_only, &[]),
        Err(ServiceRefusal::Service)
    );
    assert_eq!(negotiate("", &[], &desktop_only, &[]), Err(ServiceRefusal::Service));
    let both = [SERVICE_DESKTOP, SERVICE_REMOTE_BROWSER];
    assert_eq!(
        negotiate(SERVICE_REMOTE_BROWSER, &[], &both, &[]).map(|n| n.service),
        Ok("rb/1".into())
    );
}

#[test]
fn accepted_caps_are_the_intersection_in_host_order_without_duplicates() {
    let host = [caps::STREAM_OPEN, caps::INPUT_SERVICE, caps::CLOCK];
    let offered = s(&[caps::CLOCK, "future.thing", caps::STREAM_OPEN, caps::CLOCK]);
    let got = negotiate(SERVICE_DESKTOP, &offered, &[SERVICE_DESKTOP], &host).expect("ok");
    assert_eq!(got.caps, s(&[caps::STREAM_OPEN, caps::CLOCK]));
}

#[test]
fn oversized_cap_lists_are_refused() {
    let many: Vec<String> = (0..=MAX_CAPS).map(|i| format!("c{i}")).collect();
    assert_eq!(
        negotiate(SERVICE_DESKTOP, &many, &[SERVICE_DESKTOP], &[]),
        Err(ServiceRefusal::Malformed)
    );
    let long = vec!["x".repeat(MAX_CAP_LEN + 1)];
    assert_eq!(
        negotiate(SERVICE_DESKTOP, &long, &[SERVICE_DESKTOP], &[]),
        Err(ServiceRefusal::Malformed)
    );
}

#[test]
fn every_named_cap_is_short_and_distinct() {
    let mut names = caps::ALL.to_vec();
    assert!(names.iter().all(|n| !n.is_empty() && n.len() <= MAX_CAP_LEN));
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), caps::ALL.len());
}
