//! Seeded secrets through an app's `net.fetch`, on the wire (cmux_egress::capture): a
//! credential header the app tries to send is stripped before the wire, and the app's own
//! header and body ride only where the app put them. tests/egress_seeded.json names this test
//! for the `cmux_tui_core::apps::egress` gate site.

use std::collections::BTreeSet;

use cmux_egress::capture;
use serde_json::json;

use super::{Fetcher as _, HttpFetcher, admit};

const HOST: &str = "share.cmux.dev";

#[test]
fn app_credentials_never_reach_the_wire() {
    capture::install().unwrap();
    let credential = "SEEDappEgressCredential-c4f2";
    let header = "SEEDappEgressHeader-0b9d";
    let body = "SEEDappEgressBody-61aa";
    let grants: BTreeSet<String> = [format!("net:{HOST}")].into_iter().collect();
    let params = json!({
        "url": format!("https://{HOST}/seeded-app/echo"),
        "method": "POST",
        "headers": {
            "Authorization": format!("Bearer {credential}"),
            "Cookie": format!("session={credential}"),
            "X-Seeded": header,
        },
        "body": body,
    });
    let request = admit(&params, &grants, false).unwrap();
    let _ = HttpFetcher.fetch(request);
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.starts_with("/seeded-app/"))
        .collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(capture::leaks(credential).is_empty(), "{:?}", capture::leaks(credential));
    let places = capture::leaks(header);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(": header x-seeded"), "{places:?}");
    let places = capture::leaks(body);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(": body"), "{places:?}");
}
