//! Seeded secrets through the hands engine's user socket, on the wire
//! (cmux_egress::capture): the bearer rides only in the upgrade's `Authorization`, never in
//! its URL or another header. tests/egress_seeded.json names this test for the
//! `cmux_tui::cli::cloud_hands::socket` gate site.

use cmux_egress::capture;

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn the_bearer_rides_only_in_the_upgrades_authorization() {
    capture::install().unwrap();
    cmux_build_space::init_process(Ok(None));
    let bearer = "SEEDcloudHandsBearer-6e19";
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        // The capture server answers the upgrade `200 {}`, so the session ends before any frame.
        let _ = super::session(
            &format!("https://{HOST}"),
            Some(bearer.to_owned()),
            Some("0.0.0-seeded"),
            || 0.0,
            |_| {},
        )
        .await;
    });
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| {
            request
                .headers
                .iter()
                .any(|(name, value)| name == "x-cmux-client-version" && value == "0.0.0-seeded")
        })
        .collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(
        sent[0].headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("upgrade")),
        "{sent:?}"
    );
    let places = capture::leaks(bearer);
    assert_eq!(
        places,
        [format!("{HOST} GET {}: header authorization", cmux_cloud_wire::hands::USER_SOCKET_PATH)]
    );
}
