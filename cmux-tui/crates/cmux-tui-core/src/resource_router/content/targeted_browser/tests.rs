//! A browser metadata projection reads that browser's rows only, not the
//! whole session topology (nx-scale W2).

use super::*;
use crate::SurfaceOptions;
use crate::workspace_registry::full_topology_reads_for_test;

fn parsed_request(operation: &str, fields: Value, key: &str) -> ParsedResourceRequest {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    crate::resource_router::parse_resource_request(&serde_json::to_string(&envelope).unwrap())
        .unwrap()
}

#[test]
fn a_browser_projection_reads_no_full_topology() {
    let mux = Mux::new_for_test("targeted-browser-read", SurfaceOptions::default());
    let mut created = Vec::new();
    for index in 0..3 {
        let value = crate::resource_router::topology::dispatch(
            &mux,
            parsed_request(
                "tab.create_browser",
                json!({"url":"about:blank"}),
                &format!("create-browser-{index}"),
            ),
        )
        .unwrap();
        created
            .push(BrowserPublicId::parse(value["value"]["browser_id"].as_str().unwrap()).unwrap());
    }
    let browser_id = &created[1];
    let reads = full_topology_reads_for_test();
    let projection = mux
        .with_resource_projection(|registry, state| {
            targeted_browser_effect_projection(registry, state, browser_id, true)
        })
        .unwrap();
    assert_eq!(full_topology_reads_for_test(), reads, "the projection read the whole topology");
    assert!(matches!(
        &projection.patch.changes[..],
        [ResourceChange::UpsertBrowser(browser), ResourceChange::UpsertTab(tab)]
            if &browser.public_id == browser_id
                && tab.content_id == ContentPublicId::Browser(browser_id.clone())
    ));
    for browser in &created {
        if let Some((_, surface)) = browser_surface_for_id(&mux, browser) {
            surface.kill();
        }
    }
}
