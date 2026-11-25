//! Seeded secrets through the cloud API's one HTTP session, on the wire (cmux_egress::capture):
//! under `owner` and `worker` auth the refresh token never leaves, and the credential goes only
//! in `Authorization` (RULE cx-kvmz, hq-84: the Worker's log records every other header and the
//! URL). tests/egress_seeded.json names this test for the `cmux_cloud_api::http` gate site.

use std::time::Duration;

use cmux_egress::capture;
use serde_json::json;
use zeroize::Zeroizing;

use super::{Auth, Body, Http};
use crate::Request;

const HOST: &str = "cloud-api.cmux.dev";

fn seeded(auth: Auth, tag: &str) -> Request {
    Request {
        call: "seeded".into(),
        api: format!("https://{HOST}"),
        auth,
        credential: format!("SEEDcredential-{tag}"),
        refresh: Some(format!("SEEDrefresh-{tag}")),
        team: Some("team-seeded".into()),
        app_version: Some("cmux-next".into()),
        local_only: false,
        args: serde_json::Map::new(),
    }
}

#[test]
fn seeded_secrets_go_only_where_the_rule_allows() {
    capture::install().unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    for (auth, tag) in [(Auth::Owner, "owner-7d1e"), (Auth::Worker, "worker-3b9a")] {
        let request = seeded(auth, tag);
        let http = Http::new(&request).unwrap();
        let url = http.url(&["v1", "seeded", tag], &[]);
        let wait = Duration::from_secs(20);
        runtime
            .block_on(http.send(
                reqwest::Method::POST,
                url.clone(),
                Some(Body::Json(json!({"n": 1}))),
                Some("idem-1"),
                wait,
                "seeded",
            ))
            .unwrap();
        let bytes = Zeroizing::new(b"line\n".to_vec());
        runtime
            .block_on(http.send(
                reqwest::Method::PUT,
                url,
                Some(Body::Bytes(bytes, "application/octet-stream")),
                None,
                wait,
                "seeded",
            ))
            .unwrap();

        let sent: Vec<_> = capture::requests_to(HOST)
            .into_iter()
            .filter(|r| r.target.starts_with(&format!("/v1/seeded/{tag}")))
            .collect();
        assert_eq!(sent.len(), 2, "{sent:?}");
        let refresh = format!("SEEDrefresh-{tag}");
        assert!(capture::leaks(&refresh).is_empty(), "{:?}", capture::leaks(&refresh));
        let credential = format!("SEEDcredential-{tag}");
        let places = capture::leaks(&credential);
        assert_eq!(places.len(), 2, "{places:?}");
        assert!(places.iter().all(|p| p.ends_with(": header authorization")), "{places:?}");
        for request in &sent {
            assert!(!request.target.contains('?'), "no query: {}", request.target);
            let names: Vec<&str> = request.headers.iter().map(|(n, _)| n.as_str()).collect();
            for name in &names {
                assert!(
                    [
                        "authorization",
                        "content-type",
                        "content-length",
                        crate::session::TEAM_HEADER,
                        "x-cmux-build-space",
                        "idempotency-key",
                        "user-agent",
                        "accept",
                        "host",
                    ]
                    .iter()
                    .any(|allowed| allowed.eq_ignore_ascii_case(name)),
                    "{name} is not a header the rule allows: {names:?}"
                );
            }
        }
    }
}
