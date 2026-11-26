//! Seeded secrets through the loopback data plane (tests/egress_seeded.json,
//! site `cmux_coderouter`): the harness's scoped key never leaves the Mac, the
//! upstream bearer rides only in `authorization` toward the hosted router, and
//! the prompt only in the forwarded body.

use cmux_coderouter::{
    ApiFamily, KeyRing, KeyScope, StaticInstallSecretStore, Upstream, spawn_data_plane,
};
use cmux_egress::capture;
use std::collections::BTreeSet;
use std::sync::Arc;

const HOST: &str = "cloud-api.cmux.dev";

#[tokio::test]
async fn the_scoped_key_stays_local_and_the_bearer_rides_only_in_authorization() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
    let mut ring =
        KeyRing::new(Arc::new(StaticInstallSecretStore::new("seeded", vec![7; 32]))).unwrap();
    let key = ring
        .mint(
            "k1",
            KeyScope {
                harness: "codex".into(),
                session: "SEEDcoderouterSession-a41f".into(),
                surfaces: vec!["SEEDcoderouterSurface-90bd".into()],
                families: BTreeSet::from([ApiFamily::OpenAiChat]),
                expires_at: 0,
            },
        )
        .unwrap();
    let key = key.expose().clone();
    let bearer = "SEEDcoderouterUpstreamBearer-6c2e";
    let prompt = "SEEDcoderouterPrompt-1b7d";
    let upstream = Upstream::new(&format!("https://{HOST}/"), bearer.to_owned(), 0).unwrap();
    let (address, task) = spawn_data_plane(
        Arc::new(tokio::sync::RwLock::new(ring)),
        Arc::new(tokio::sync::RwLock::new(Some(upstream))),
    )
    .await
    .unwrap();

    // The harness side: loopback, not an egress site.
    let local = reqwest::Client::builder().no_proxy().build().unwrap();
    let response = local
        .post(format!("http://{address}/v1/chat/completions"))
        .bearer_auth(&key)
        .header("content-type", "application/json")
        .body(format!(r#"{{"model":"m","messages":[{{"role":"user","content":"{prompt}"}}]}}"#))
        .send()
        .await
        .unwrap();
    assert!(response.status().is_success(), "{}", response.status());
    let _ = response.bytes().await;
    task.abort();

    let sent = capture::requests_to(HOST);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(capture::leaks(&key).is_empty(), "{:?}", capture::leaks(&key));
    assert_eq!(
        capture::leaks(bearer),
        [format!("{HOST} POST /v1/inference/chat/completions: header authorization")]
    );
    assert_eq!(
        capture::leaks(prompt),
        [format!("{HOST} POST /v1/inference/chat/completions: body")]
    );
    for scoped in ["SEEDcoderouterSession-a41f", "SEEDcoderouterSurface-90bd"] {
        assert!(capture::leaks(scoped).is_empty(), "{scoped}: {:?}", capture::leaks(scoped));
    }
}
