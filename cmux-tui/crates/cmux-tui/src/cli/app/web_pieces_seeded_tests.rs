//! Seeded secrets through the web pieces switch-file fetch on the wire (cmux_egress::capture):
//! the GET carries only the published file's URL and the ETag the state holds, so nothing of the
//! person's (no credential, no cookie) rides along. tests/egress_seeded.json names this test for
//! the `cmux_tui::cli::app::web_pieces` gate site.

use cmux_egress::capture;

use super::{Fetched, fetch};

const HOST: &str = "pieces-seeded.cmux.dev";

#[test]
fn the_switch_fetch_carries_only_its_etag_and_no_credential() {
    capture::install().unwrap();
    let etag = "\"SEEDwebPiecesEtag-3e88\"";
    let url = format!("https://{HOST}/seeded/switch.json");
    let got = fetch(&url, Some(etag));
    assert!(matches!(got, Fetched::Body(..)), "the capture server answers 200");
    let sent = capture::requests_to(HOST);
    assert_eq!(sent.len(), 1, "one request, no retry: {sent:?}");
    let request = &sent[0];
    assert_eq!((request.method.as_str(), request.target.as_str()), ("GET", "/seeded/switch.json"));
    assert!(request.body.is_empty(), "{request:?}");
    assert_eq!(capture::leaks("SEEDwebPiecesEtag-3e88").len(), 1);
    assert!(capture::leaks("SEEDwebPiecesEtag-3e88")[0].ends_with(": header if-none-match"));
    for (name, _) in &request.headers {
        let name = name.to_ascii_lowercase();
        assert!(
            !matches!(
                name.as_str(),
                "authorization" | "cookie" | "x-cmux-team" | "proxy-authorization"
            ),
            "no credential header: {name}"
        );
    }
}
