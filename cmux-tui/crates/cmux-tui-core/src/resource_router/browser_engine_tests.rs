//! A daemon with no cmux-browser provider attached (a headless Cloud
//! session) refuses a daemon-rendered browser at once (cx-r9ix): live probe,
//! `browser.create` through `cmux run` was accepted and the tab stayed
//! `starting` for good, and `browser.navigate` answered "browser is still
//! starting", because no provider ever publishes a CDP target for it.

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;

fn request(operation: &str, fields: Value, idempotency_key: &str) -> ParsedResourceRequest {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
        "idempotency_key":idempotency_key,
    });
    parse_resource_request(&serde_json::to_string(&envelope).unwrap()).unwrap()
}

fn assert_engine_unavailable(error: &ResourceError, operation: &str) {
    assert_eq!(error.code, "operation.failed", "{error:?}");
    assert_eq!(error.details["operation"], operation, "{error:?}");
    assert_eq!(error.details["extra"]["code"], "engine_unavailable", "{error:?}");
    assert!(
        error.details["reason"].as_str().is_some_and(|reason| reason.contains("cmux-browser")),
        "the reason names what is missing: {error:?}"
    );
}

fn kill_surfaces(mux: &Mux) {
    for surface in mux.with_state(|state| state.surfaces.values().cloned().collect::<Vec<_>>()) {
        surface.kill();
    }
}

#[test]
fn browser_create_without_a_provider_fails_fast_with_engine_unavailable() {
    let mux = Mux::new_for_test("browser-engine-create", SurfaceOptions::default());
    let before = mux.surface_count();
    let error = dispatch_resource_request(
        &mux,
        request("tab.create_browser", json!({"url":"https://example.com"}), "create-1"),
    )
    .expect_err("no provider can render the tab, so the create must not leave one starting");
    assert_engine_unavailable(&error, "tab.create_browser");
    assert_eq!(mux.surface_count(), before, "the refused create left no tab");
}

#[test]
fn browser_navigate_without_a_provider_fails_fast_with_engine_unavailable() {
    let mux = Mux::new_for_test("browser-engine-navigate", SurfaceOptions::default());
    // A tab made while a provider was attached, which then went away.
    mux.attach_test_browser_provider(1);
    let created = dispatch_resource_request(
        &mux,
        request("tab.create_browser", json!({"url":"about:blank"}), "create-1"),
    )
    .unwrap();
    assert!(mux.unregister_browser_provider(1));
    let browser = created["value"]["browser_id"].as_str().unwrap().to_string();
    let error = dispatch_resource_request(
        &mux,
        request(
            "browser.navigate",
            json!({"browser":browser,"url":"https://example.com"}),
            "navigate-1",
        ),
    )
    .expect_err("a starting browser with no provider cannot navigate");
    assert_engine_unavailable(&error, "browser.navigate");
    kill_surfaces(&mux);
}

#[test]
fn browser_create_with_a_provider_still_waits_for_its_target() {
    let mux = Mux::new_for_test("browser-engine-provider", SurfaceOptions::default());
    mux.attach_test_browser_provider(1);
    let created = dispatch_resource_request(
        &mux,
        request("tab.create_browser", json!({"url":"about:blank"}), "create-1"),
    )
    .unwrap();
    assert!(created["value"]["browser_id"].is_string(), "{created}");
    kill_surfaces(&mux);
}

#[test]
fn a_retried_browser_create_replays_after_its_provider_went_away() {
    let mux = Mux::new_for_test("browser-engine-replay", SurfaceOptions::default());
    mux.attach_test_browser_provider(1);
    let create = || {
        dispatch_resource_request(
            &mux,
            request("tab.create_browser", json!({"url":"about:blank"}), "create-1"),
        )
    };
    let created = create().unwrap();
    let tabs = mux.surface_count();
    assert!(mux.unregister_browser_provider(1));
    // The reply was lost, so the caller retries with the same key: it gets
    // the original tab, not a refusal that orphans it.
    let replayed = create().expect("a retry of a committed create replays its receipt");
    assert_eq!(replayed["value"]["browser_id"], created["value"]["browser_id"], "{replayed}");
    assert_eq!(mux.surface_count(), tabs, "the replay made no second tab");
    kill_surfaces(&mux);
}
