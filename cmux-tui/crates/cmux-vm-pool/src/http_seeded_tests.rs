//! Seeded secrets through `cmux vm pool`'s one client, on the wire (cmux_egress::capture):
//! the Freestyle key rides only in `Authorization`, never in the path, query or body.
//! tests/egress_seeded.json names this test for the `cmux_vm_pool::http` gate site.

use cmux_egress::capture;

#[test]
fn the_pool_key_rides_only_in_authorization() {
    capture::install().unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let key = "SEEDvmPoolFreestyleKey-41c7";
    let client = super::client().unwrap();
    let body = serde_json::json!({"name": "seeded-runner"});
    runtime.block_on(async {
        let _ = super::call(
            &client,
            reqwest::Method::GET,
            "https://api.freestyle.sh/v1/vms?seeded=1",
            key,
            &[],
            None,
        )
        .await;
        let _ = super::call(
            &client,
            reqwest::Method::POST,
            "https://api.freestyle.sh/v1/vms/seeded/start",
            key,
            &[("x-seeded", "1")],
            None,
        )
        .await;
        let _ = super::call(
            &client,
            reqwest::Method::POST,
            "https://api.freestyle.sh/v1/vms",
            key,
            &[],
            Some(&body),
        )
        .await;
    });
    let sent: Vec<_> = capture::requests_to("api.freestyle.sh")
        .into_iter()
        .filter(|request| request.target.starts_with("/v1/vms"))
        .collect();
    assert!(sent.len() >= 3, "{sent:?}");
    let places = capture::leaks(key);
    assert!(places.len() >= 3, "{places:?}");
    assert!(places.iter().all(|place| place.ends_with(": header authorization")), "{places:?}");
}
