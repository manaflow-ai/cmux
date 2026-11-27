//! Seeded secrets through `cmux hub`'s client, on the wire (cmux_egress::capture): the cmux
//! token rides only in `Authorization` on every hub request, and a linked Stripe key only in
//! the link request's body, never in a URL or header. tests/egress_seeded.json names this
//! test for the `cmux_tui::cli::hub` gate site.

use cmux_egress::capture;
use zeroize::Zeroizing;

use super::{Hub, Verb, hub_http, link_body, overview_requests, request_of};

const HOST: &str = "cloud-api.cmux.dev";

#[test]
fn the_token_rides_only_in_authorization_and_the_key_only_in_the_link_body() {
    capture::install().unwrap();
    let token = "SEEDhubCmuxToken-0c58";
    let key = "rk_test_SEEDhubStripeKey7e21";
    let hub = Hub {
        http: hub_http().unwrap(),
        platform: format!("https://{HOST}/seeded-hub"),
        token: Zeroizing::new(token.to_owned()),
        team: Some("team_seeded".into()),
    };
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        for request in overview_requests(5) {
            let _ = hub.send(&request, None).await;
        }
        let link =
            request_of(&Verb::Link { provider: "stripe".into(), sharing: None, policy: None });
        let body = link_body("stripe", Some(key), None, None);
        let _ = hub.send(&link, Some(body.as_str())).await;
    });
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-hub/"))
        .collect();
    assert_eq!(sent.len(), 5, "{sent:?}");
    let places = capture::leaks(token);
    assert_eq!(places.len(), 5, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
    let places = capture::leaks(key);
    assert_eq!(
        places,
        [format!("{HOST} POST /seeded-hub/v1/hub/connections?team=team_seeded: body")]
    );
}
