//! A browser the cmux app draws itself (WebKit or CEF, a frontend record) has
//! no daemon CDP session. `browser.navigate` and the other browser effects
//! used to answer "browser is still starting" for it while its status was
//! `live`. The daemon cannot drive the app's page, so it refuses with the
//! code `browser_rendered_by_app` and the tab the app knows the page by;
//! the CLI and MCP then run the verb through the app (`browser.page.*`).

use std::sync::Arc;

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::mux::ProviderWorkspaceState;
use crate::workspace_registry::{FrontendBrowserRecord, WorkspaceRegistry};

struct Session {
    root: std::path::PathBuf,
}

impl Session {
    fn new(name: &str) -> (Self, Arc<Mux>) {
        let root = std::env::temp_dir()
            .join(format!("cmux-frontend-effect-{name}-{}", WorkspacePublicId::random().unwrap()));
        let registry = WorkspaceRegistry::open(&root, "frontend-effect").unwrap();
        let mux = Mux::from_workspace_registry(
            "frontend-effect".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        (Self { root }, mux)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

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

/// A frontend browser tab: its public browser and tab ids.
fn frontend_browser(mux: &Arc<Mux>) -> (String, String) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = FrontendBrowserRecord {
        engine: "webkit".into(),
        url: "https://example.com/".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let surface = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap();
    let identity = surface.resource_identity().unwrap().clone();
    let crate::resource::ContentPublicId::Browser(browser) = identity.content_id else {
        panic!("a frontend browser tab holds a browser")
    };
    (browser.as_str().to_string(), identity.tab_id.as_str().to_string())
}

#[test]
fn browser_effects_on_an_app_drawn_browser_name_the_app_and_its_tab() {
    let (_session, mux) = Session::new("refuse");
    let (browser, tab) = frontend_browser(&mux);
    let cases = [
        ("browser.navigate", json!({"url":"https://example.org/"})),
        ("browser.back", json!({})),
        ("browser.forward", json!({})),
        ("browser.reload", json!({})),
        ("browser.activate", json!({})),
        ("browser.input.text", json!({"text":"hi"})),
        ("browser.input.key", json!({"key":"Enter","kind":"press"})),
    ];
    for (index, (operation, fields)) in cases.into_iter().enumerate() {
        let mut fields = fields;
        fields["browser"] = json!(browser);
        let error =
            dispatch_resource_request(&mux, request(operation, fields, &format!("k-{index}")))
                .expect_err("the daemon has no session to drive an app-drawn page");
        assert_eq!(error.code, "operation.failed", "{operation}: {error:?}");
        assert_eq!(
            error.details["extra"]["code"], "browser_rendered_by_app",
            "{operation}: {error:?}"
        );
        assert_eq!(error.details["extra"]["tab_id"], tab, "{operation}: {error:?}");
        assert_eq!(error.details["extra"]["browser_id"], browser, "{operation}: {error:?}");
        assert!(
            !error.message.contains("still starting"),
            "{operation}: a live app-drawn browser is not starting: {error:?}"
        );
    }
}
